import Foundation

struct NuvioPluginManifest: Decodable {
    let name: String
    let version: String
    let description: String?
    let author: String?

    var scrapers: [NuvioPluginManifestScraper]

    enum CodingKeys: String, CodingKey {
        case name, version, description, author, scrapers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        let rows = try container.decodeIfPresent(
            [NuvioLossyManifestScraper].self,
            forKey: .scrapers
        ) ?? []
        scrapers = rows.compactMap(\.scraper)
    }
}

private struct NuvioLossyManifestScraper: Decodable {
    let scraper: NuvioPluginManifestScraper?

    init(from decoder: Decoder) throws {
        scraper = try? NuvioPluginManifestScraper(from: decoder)
    }
}

struct NuvioPluginManifestScraper: Decodable {
    let id: String
    let name: String
    let description: String?
    let author: String?
    let version: String
    let filename: String
    let supportedTypes: [String]
    let enabled: Bool
    let hasSettings: Bool
    let logo: String?
    let contentLanguage: [String]?
    let supportedPlatforms: [String]?
    let disabledPlatforms: [String]?
    let formats: [String]?
    let supportedFormats: [String]?
    let supportsExternalPlayer: Bool?
    let limited: Bool?
    let resources: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, description, author, version, filename, enabled, logo, formats, limited, resources
        case hasSettings
        case supportedTypes, contentLanguage, supportedPlatforms, disabledPlatforms, supportedFormats, supportsExternalPlayer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        filename = try container.decode(String.self, forKey: .filename)
        supportedTypes = try container.decodeIfPresent([String].self, forKey: .supportedTypes) ?? ["movie", "tv"]
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        hasSettings = try container.decodeIfPresent(Bool.self, forKey: .hasSettings) ?? false
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        contentLanguage = try container.decodeIfPresent([String].self, forKey: .contentLanguage)
        supportedPlatforms = try container.decodeIfPresent([String].self, forKey: .supportedPlatforms)
        disabledPlatforms = try container.decodeIfPresent([String].self, forKey: .disabledPlatforms)
        formats = try container.decodeIfPresent([String].self, forKey: .formats)
        supportedFormats = try container.decodeIfPresent([String].self, forKey: .supportedFormats)
        supportsExternalPlayer = try container.decodeIfPresent(Bool.self, forKey: .supportsExternalPlayer)
        limited = try container.decodeIfPresent(Bool.self, forKey: .limited)
        resources = try container.decodeIfPresent([String].self, forKey: .resources)
    }
}

struct NuvioRepositoryProviderInventory: Codable, Hashable {
    var advertisedProviderCount: Int
    var eligibleProviderCount: Int
}

struct NuvioPluginRepository: Codable, Identifiable, Hashable {
    let id: String
    let manifestUrl: String
    var name: String
    var description: String?
    var version: String?
    var scraperCount: Int
    var lastUpdated: TimeInterval
    var sortIndex: Int64
    var isEnabled: Bool = true
    var isRefreshing: Bool = false
    var errorMessage: String? = nil
    var providerInventory: NuvioRepositoryProviderInventory? = nil

    var hostLabel: String {
        URL(string: manifestUrl)?.host ?? manifestUrl
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? hostLabel : trimmed
    }
}

struct NuvioRepositoryRepairLedger: Codable, Hashable {
    var failedProviderKeysByRepository: [String: [String]] = [:]

    func failedProviderKeys(for repositoryID: String) -> Set<String> {
        Set(failedProviderKeysByRepository[repositoryID] ?? [])
    }

    mutating func setFailedProviderKeys(_ providerKeys: Set<String>, for repositoryID: String) {
        if providerKeys.isEmpty {
            failedProviderKeysByRepository.removeValue(forKey: repositoryID)
        } else {
            failedProviderKeysByRepository[repositoryID] = providerKeys.sorted()
        }
    }

    mutating func removeRepository(_ repositoryID: String) {
        failedProviderKeysByRepository.removeValue(forKey: repositoryID)
    }

    var isEmpty: Bool { failedProviderKeysByRepository.isEmpty }
}

struct NuvioRepositoryProviderStatus: Equatable {
    let advertisedProviderCount: Int
    let eligibleProviderCount: Int
    let installedProviderCount: Int
    let pendingProviderCount: Int
    let failedProviderCount: Int

    var excludedProviderCount: Int {
        max(advertisedProviderCount - eligibleProviderCount, 0)
    }

    var isPartial: Bool { pendingProviderCount > 0 || failedProviderCount > 0 }
    var needsRetry: Bool { isPartial }

    static func resolved(
        repository: NuvioPluginRepository,
        representedProviderCount: Int,
        installedProviderCount: Int,
        failedProviderCount: Int
    ) -> NuvioRepositoryProviderStatus {
        let represented = max(representedProviderCount, 0)
        let installed = min(max(installedProviderCount, 0), represented)
        let storedEligible = repository.providerInventory?.eligibleProviderCount
            ?? max(repository.scraperCount, represented)
        let eligible = max(storedEligible, represented)
        let advertised = max(
            repository.providerInventory?.advertisedProviderCount ?? eligible,
            eligible
        )
        return NuvioRepositoryProviderStatus(
            advertisedProviderCount: advertised,
            eligibleProviderCount: eligible,
            installedProviderCount: installed,
            pendingProviderCount: max(eligible - installed, 0),
            failedProviderCount: min(max(failedProviderCount, 0), eligible)
        )
    }
}

enum NuvioRepositoryRepairPolicy {
    static func providerKeysToRetry(
        eligibleProviderKeys: Set<String>,
        representedProviderKeys: Set<String>,
        codeReadyProviderKeys: Set<String>,
        failedProviderKeys: Set<String>
    ) -> Set<String> {
        eligibleProviderKeys.filter { providerKey in
            failedProviderKeys.contains(providerKey)
                || !representedProviderKeys.contains(providerKey)
                || !codeReadyProviderKeys.contains(providerKey)
        }
    }

    static func reconciledFailedProviderKeys(
        eligibleProviderKeys: Set<String>,
        previousFailedProviderKeys: Set<String>,
        attemptedProviderKeys: Set<String>,
        failedProviderKeys: Set<String>
    ) -> Set<String> {
        let unattemptedFailures = previousFailedProviderKeys
            .intersection(eligibleProviderKeys)
            .subtracting(attemptedProviderKeys)
        let currentFailures = failedProviderKeys
            .intersection(eligibleProviderKeys)
            .intersection(attemptedProviderKeys)
        return unattemptedFailures.union(currentFailures)
    }
}

struct NuvioRepositoryHTTPFailure: LocalizedError, Equatable, Sendable {
    let statusCode: Int
    let retryAfterSeconds: TimeInterval?

    var errorDescription: String? {
        "The repository request failed with status \(statusCode)."
    }
}

enum NuvioManifestFetchRetryPolicy {
    static let maximumRetryAfterSeconds: TimeInterval = 5
    static let defaultRetryDelaySeconds: TimeInterval = 0.5

    static func run<T>(
        operation: () async throws -> T,
        sleep: (TimeInterval) async throws -> Void
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard let delay = retryDelaySeconds(for: error) else { throw error }
            try Task.checkCancellation()
            try await sleep(delay)
            try Task.checkCancellation()
            return try await operation()
        }
    }

    static func retryDelaySeconds(for error: Error) -> TimeInterval? {
        guard let failure = error as? NuvioRepositoryHTTPFailure,
              failure.statusCode == 429
                || [500, 502, 503, 504].contains(failure.statusCode) else {
            return nil
        }
        guard let requested = failure.retryAfterSeconds, requested.isFinite else {
            return defaultRetryDelaySeconds
        }
        return min(max(requested, 0), maximumRetryAfterSeconds)
    }

    static func retryAfterSeconds(
        from rawValue: String?,
        now: Date = Date()
    ) -> TimeInterval? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else { return nil }
        if let seconds = TimeInterval(rawValue), seconds.isFinite {
            return min(max(seconds, 0), maximumRetryAfterSeconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "EEE',' dd MMM yyyy HH':'mm':'ss z",
            "EEEE',' dd-MMM-yy HH':'mm':'ss z",
            "EEE MMM d HH':'mm':'ss yyyy"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: rawValue) {
                let seconds = date.timeIntervalSince(now)
                guard seconds.isFinite else { return nil }
                return min(max(seconds, 0), maximumRetryAfterSeconds)
            }
        }
        return nil
    }
}

enum NuvioRepositoryRequestPolicy {
    static func requestURL(_ validatedURL: URL) -> URL {
        validatedURL
    }
}

struct NuvioPluginScraper: Codable, Identifiable, Hashable {

    let id: String

    let providerKey: String
    let repositoryId: String
    let repositoryUrl: String
    let name: String
    let description: String
    let author: String?
    let version: String
    let filename: String
    let codeFileName: String
    let supportedTypes: [String]
    var enabled: Bool
    let manifestEnabled: Bool
    let declaresSettings: Bool
    let logo: String?
    let contentLanguage: [String]
    let formats: [String]?

    func supportsType(_ type: String) -> Bool {
        let normalized = NuvioPluginSupport.normalizeType(type)
        return supportedTypes.map(NuvioPluginSupport.normalizeType).contains(normalized)
    }

    var isRunnable: Bool { enabled && manifestEnabled }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? providerKey : trimmed
    }

    init(
        id: String,
        providerKey: String,
        repositoryId: String,
        repositoryUrl: String,
        name: String,
        description: String,
        author: String?,
        version: String,
        filename: String,
        codeFileName: String,
        supportedTypes: [String],
        enabled: Bool,
        manifestEnabled: Bool,
        declaresSettings: Bool,
        logo: String?,
        contentLanguage: [String],
        formats: [String]?
    ) {
        self.id = id
        self.providerKey = providerKey
        self.repositoryId = repositoryId
        self.repositoryUrl = repositoryUrl
        self.name = name
        self.description = description
        self.author = author
        self.version = version
        self.filename = filename
        self.codeFileName = codeFileName
        self.supportedTypes = supportedTypes
        self.enabled = enabled
        self.manifestEnabled = manifestEnabled
        self.declaresSettings = declaresSettings
        self.logo = logo
        self.contentLanguage = contentLanguage
        self.formats = formats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        repositoryId = try container.decode(String.self, forKey: .repositoryId)
        repositoryUrl = try container.decodeIfPresent(String.self, forKey: .repositoryUrl) ?? ""
        filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? ""
        providerKey = try container.decodeIfPresent(String.self, forKey: .providerKey)
            ?? URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? providerKey
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        codeFileName = try container.decodeIfPresent(String.self, forKey: .codeFileName)
            ?? NuvioPluginSupport.codeFileName(forScraperID: id)
        supportedTypes = try container.decodeIfPresent([String].self, forKey: .supportedTypes) ?? ["movie", "tv"]
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        manifestEnabled = try container.decodeIfPresent(Bool.self, forKey: .manifestEnabled) ?? true
        declaresSettings = try container.decodeIfPresent(Bool.self, forKey: .declaresSettings) ?? false
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        contentLanguage = try container.decodeIfPresent([String].self, forKey: .contentLanguage) ?? []
        formats = try container.decodeIfPresent([String].self, forKey: .formats)
    }
}

enum NuvioSettingsFieldKind: String, Codable, Hashable {
    case header
    case toggle
    case select
    case text
}

struct NuvioSettingsOption: Codable, Hashable, Identifiable {
    var id: String { value }
    let label: String
    let value: String
}

struct NuvioSettingsField: Codable, Hashable, Identifiable {
    var id: String { key.isEmpty ? "\(kind.rawValue)-\(label)" : key }
    let kind: NuvioSettingsFieldKind
    let key: String
    let label: String
    let description: String?
    let options: [NuvioSettingsOption]
    let defaultValue: NuvioSettingsValue?
}

enum NuvioSettingsValue: Codable, Hashable {
    case bool(Bool)
    case string(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported plugin setting value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        }
    }

    var jsonObject: Any {
        switch self {
        case .bool(let value): return value
        case .string(let value): return value
        case .number(let value): return value
        }
    }

    var boolValue: Bool {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value.isFinite && value != 0
        case .string(let value): return ["true", "yes", "1"].contains(value.lowercased())
        }
    }

    var stringValue: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .string(let value): return value
        case .number(let value):
            guard value.isFinite else { return "" }
            if value == value.rounded(), let integer = Int(exactly: value) {
                return String(integer)
            }
            return String(value)
        }
    }

    var sanitizedForPersistence: NuvioSettingsValue? {
        if case .number(let value) = self, !value.isFinite { return nil }
        return self
    }
}

struct NuvioPluginSubtitle: Codable, Hashable {
    let url: String
    let language: String
    let name: String?
    let headers: [String: String]?

    var displayName: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty { return trimmedName }

        let trimmedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedLanguage.isEmpty ? "Subtitle" : trimmedLanguage
    }

    var sanitizedHeaders: [String: String]? {
        NuvioPluginSupport.sanitizedHeaders(headers)
    }
}

struct NuvioSubtitleTrackAccumulator {
    private(set) var tracks: [NuvioPluginSubtitle] = []
    private var seenURLs = Set<String>()

    var seenURLValues: Set<String> { seenURLs }
    let limit: Int

    init(limit: Int = NuvioSubtitleBoundary.maximumTracksPerStream) {
        self.limit = max(0, limit)
        tracks.reserveCapacity(min(self.limit, 16))
    }

    var isFull: Bool { tracks.count >= limit }

    private(set) var refusedWhenFull = 0

    mutating func noteRefused(_ count: Int) {
        guard count > 0 else { return }
        refusedWhenFull += count
    }

    mutating func noteRefusedURLs(_ urls: [String]) {
        for url in urls {
            let normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seenURLs.insert(normalized).inserted else { continue }
            refusedWhenFull += 1
        }
    }

    mutating func append(_ subtitle: NuvioPluginSubtitle) {
        guard !isFull else { return }
        let normalizedURL = subtitle.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty, seenURLs.insert(normalizedURL).inserted else { return }
        tracks.append(subtitle)
    }

    mutating func append<S: Sequence>(contentsOf subtitles: S)
    where S.Element == NuvioPluginSubtitle {
        for subtitle in subtitles {
            guard !isFull else {
                noteRefusedURLs([subtitle.url])
                continue
            }
            append(subtitle)
        }
    }
}

enum NuvioSubtitleBoundary {
    static let maximumTracksPerStream = 64
    static let maximumTracksPerValidationBatch = 512

    static func boundedForNetworkValidation(
        _ streams: [NuvioPluginStream]
    ) -> (streams: [NuvioPluginStream], droppedByBatchBudget: Int) {
        let carryingSubtitles = streams.reduce(into: 0) { total, stream in
            total += (stream.subtitles?.isEmpty == false) ? 1 : 0
        }
        guard carryingSubtitles > 0 else { return (streams.map { $0.withSubtitles(nil) }, 0) }

        let fairShare = max(1, maximumTracksPerValidationBatch / carryingSubtitles)
        var remaining = maximumTracksPerValidationBatch
        var refusedByCap = 0
        var streamsServed = 0
        var bounded: [NuvioPluginStream] = []
        bounded.reserveCapacity(streams.count)
        for stream in streams {
            guard let subtitles = stream.subtitles, !subtitles.isEmpty else {
                bounded.append(stream.withSubtitles(nil))
                continue
            }
            guard remaining > 0 else {
                var distinct = Set<String>()
                for subtitle in subtitles {
                    let normalized = subtitle.url.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalized.isEmpty else { continue }
                    distinct.insert(normalized)
                }
                refusedByCap += min(distinct.count, maximumTracksPerStream)
                bounded.append(stream.withSubtitles(nil))
                continue
            }
            let streamsStillNeedingShare = max(1, carryingSubtitles - streamsServed)
            let share = max(fairShare, remaining / streamsStillNeedingShare)
            var accumulator = NuvioSubtitleTrackAccumulator(
                limit: min(maximumTracksPerStream, share, remaining)
            )
            accumulator.append(contentsOf: subtitles)
            refusedByCap += accumulator.refusedWhenFull
            remaining -= accumulator.tracks.count
            streamsServed += 1
            bounded.append(stream.withSubtitles(accumulator.tracks.isEmpty ? nil : accumulator.tracks))
        }

        return (bounded, refusedByCap)
    }
}

struct NuvioPluginStream: Identifiable, Codable, Hashable {
    let id: String
    let scraperId: String
    let scraperName: String
    let sourceId: String
    let sourceName: String
    let title: String
    let name: String?
    let url: String
    let quality: String?
    let size: String?
    let language: String?
    let provider: String?
    let type: String?
    let headers: [String: String]?
    let subtitles: [NuvioPluginSubtitle]?

    func withSubtitles(_ subtitles: [NuvioPluginSubtitle]?) -> NuvioPluginStream {
        NuvioPluginStream(
            id: id,
            scraperId: scraperId,
            scraperName: scraperName,
            sourceId: sourceId,
            sourceName: sourceName,
            title: title,
            name: name,
            url: url,
            quality: quality,
            size: size,
            language: language,
            provider: provider,
            type: type,
            headers: headers,
            subtitles: subtitles
        )
    }

    var displayName: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty { return trimmedName }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "Stream" : trimmedTitle
    }

    var metadataLabel: String {
        [quality, size, language, provider]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            .joined(separator: " - ")
    }

    var isDirectHTTP: Bool {
        NuvioPluginSupport.isDirectHTTPURL(url)
    }

    var sanitizedHeaders: [String: String]? {
        NuvioPluginSupport.sanitizedHeaders(headers)
    }

    var subtitleURLs: [String] {
        (subtitles ?? [])
            .map(\.url)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var subtitleNames: [String]? {
        let names = (subtitles ?? []).map(\.displayName)
        return names.isEmpty ? nil : names
    }

    var subtitleHeadersByURL: [String: [String: String]]? {
        let pairs = (subtitles ?? []).compactMap { subtitle -> (String, [String: String])? in
            guard let headers = subtitle.sanitizedHeaders, !headers.isEmpty else { return nil }
            return (subtitle.url, headers)
        }
        return pairs.isEmpty ? nil : Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    var languageHints: [String] {
        [language, provider]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
    }

    var metadataHints: [String] {
        [quality, size, language, provider, type, scraperName]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
    }

    var qualitySearchLabel: String {
        [displayName, metadataLabel, type ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct NuvioStreamBatch {
    let streams: [NuvioPluginStream]
    let unplayableCount: Int

    var torrentCount: Int = 0
    var unreadableURLCount: Int = 0
    var discardedRowCount: Int = 0
    var requestCount: Int = 0

    var ownSourceRequestCount: Int = 0
    var ownSourceFailureCount: Int = 0

    var malformedURLCount: Int = 0
    var ledgerDescription: String = "fetches=0"
    var interference: NuvioEclipseInterference = .none

    var everyRequestFailed: Bool {
        ownSourceRequestCount > 0 && ownSourceFailureCount == ownSourceRequestCount
    }

    var madeNoRequests: Bool { requestCount == 0 }

    var unplayableKind: NuvioUnplayableKind {
        if unreadableURLCount == 0 { return .torrent }
        if torrentCount == 0 { return .unreadableLink }
        return .mixed
    }
}

enum NuvioUnplayableKind: Equatable {
    case torrent
    case unreadableLink
    case mixed
}

enum NuvioOutcomeBlame {
    case none
    case provider
    case eclipse
}

enum NuvioProviderOutcome: Equatable {
    case results([NuvioPluginStream])
    case noResults

    case unplayableOnly(count: Int, kind: NuvioUnplayableKind)
    case unsupportedMediaType(String)

    case unresolvedCoordinate

    case notEnabled(String)

    case sourceUnreachable

    case needsSetup
    case providerError(String)
    case timedOut
    case appFailure(String)

    var streams: [NuvioPluginStream] {
        if case .results(let streams) = self { return streams }
        return []
    }

    var blame: NuvioOutcomeBlame {
        switch self {
        case .results, .noResults, .unsupportedMediaType, .notEnabled, .needsSetup, .unresolvedCoordinate:

            return .none
        case .unplayableOnly, .providerError, .timedOut, .sourceUnreachable:
            return .provider
        case .appFailure:
            return .eclipse
        }
    }

    var isFailure: Bool {
        switch self {
        case .providerError, .timedOut, .appFailure, .sourceUnreachable:
            return true
        case .results, .noResults, .unplayableOnly, .unsupportedMediaType, .notEnabled, .needsSetup, .unresolvedCoordinate:
            return false
        }
    }

    var displayMessage: String {
        switch self {
        case .results(let streams):
            return "\(streams.count) result\(streams.count == 1 ? "" : "s")"
        case .noResults:
            return "No results found"
        case .unplayableOnly(let count, let kind):
            switch kind {
            case .torrent:
                return count == 1
                    ? "1 result, but it is a torrent link Eclipse cannot play"
                    : "\(count) results, but they are torrent links Eclipse cannot play"
            case .unreadableLink:
                return count == 1
                    ? "1 result, but Eclipse could not read its link"
                    : "\(count) results, but Eclipse could not read their links"
            case .mixed:
                return count == 1
                    ? "1 result, but Eclipse cannot play its link"
                    : "\(count) results, but Eclipse cannot play their links"
            }
        case .unresolvedCoordinate:
            return "Episode not identified"
        case .unsupportedMediaType(let mediaType):
            return "This provider does not support \(mediaType)"
        case .notEnabled(let message):
            return message
        case .sourceUnreachable:
            return "This provider's source is not responding"
        case .needsSetup:
            return "This provider needs to be set up"
        case .providerError:
            return "Provider error"
        case .timedOut:
            return "Provider timed out"
        case .appFailure:
            return "Eclipse could not run this provider"
        }
    }

    var displayDetail: String? {
        switch self {
        case .results, .noResults:
            return nil
        case .unplayableOnly(_, let kind):
            switch kind {
            case .torrent, .mixed:
                return "Eclipse plays direct links only."
            case .unreadableLink:
                return "The provider delivered a link that is not a valid web address."
            }
        case .unresolvedCoordinate:
            return "Eclipse could not map this episode to a TMDB season and episode, and will not guess."
        case .unsupportedMediaType, .notEnabled:
            return nil
        case .sourceUnreachable:
            return "Every request it made was refused or unanswered. This is the plugin's source, not Eclipse."
        case .needsSetup:
            return "It did not contact its source at all. Check its settings for a required login or token."
        case .providerError(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "The plugin reported an error." : trimmed
        case .timedOut:
            return "The plugin's source did not respond in time."
        case .appFailure(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "This is an Eclipse problem, not a plugin problem." : trimmed
        }
    }

    var diagnosticToken: String {
        switch self {
        case .results: return "results"
        case .noResults: return "empty"
        case .unplayableOnly: return "unplayable-only"
        case .unsupportedMediaType: return "unsupported-type"
        case .unresolvedCoordinate: return "unresolved-coordinate"
        case .notEnabled: return "not-enabled"
        case .sourceUnreachable: return "source-unreachable"
        case .needsSetup: return "needs-setup"
        case .providerError: return "provider-error"
        case .timedOut: return "timed-out"
        case .appFailure: return "app-failure"
        }
    }
}

struct NuvioStoredPluginsState: Codable, Hashable {
    var pluginsEnabled: Bool = true
    var repositories: [NuvioPluginRepository] = []
    var scrapers: [NuvioPluginScraper] = []
    var scraperSettings: [String: [String: NuvioSettingsValue]] = [:]

    var runnableScraperSourceIDs: [String] {
        scrapers.filter(\.isRunnable).map(\.id)
    }

    func codeReadiness(
        isCodeUsable: (_ repositoryID: String, _ codeFileName: String) -> Bool
    ) -> NuvioCodeReadiness {
        var readyProviderCount = 0
        var pendingProviderIDs: [String] = []
        var pendingProviderCountByRepository: [String: Int] = [:]
        var representedProviderCountByRepository: [String: Int] = [:]
        for scraper in scrapers {
            representedProviderCountByRepository[scraper.repositoryId, default: 0] += 1
            if isCodeUsable(scraper.repositoryId, scraper.codeFileName) {
                readyProviderCount += 1
            } else {
                pendingProviderIDs.append(scraper.id)
                pendingProviderCountByRepository[scraper.repositoryId, default: 0] += 1
            }
        }
        for repository in repositories {
            guard let eligible = repository.providerInventory?.eligibleProviderCount else { continue }
            let represented = representedProviderCountByRepository[repository.id, default: 0]
            let catalogGap = max(eligible - represented, 0)
            if catalogGap > 0 {
                pendingProviderCountByRepository[repository.id, default: 0] += catalogGap
            }
        }
        let pendingRepositoryIDs = repositories.compactMap { repository in
            if representedProviderCountByRepository[repository.id, default: 0] == 0
                || pendingProviderCountByRepository[repository.id, default: 0] > 0 {
                return repository.id
            }
            return nil
        }
        return NuvioCodeReadiness(
            readyProviderCount: readyProviderCount,
            pendingProviderIDs: pendingProviderIDs,
            pendingProviderCountByRepository: pendingProviderCountByRepository,
            pendingRepositoryIDs: pendingRepositoryIDs
        )
    }
}

struct NuvioCodeReadiness: Equatable {
    var readyProviderCount = 0
    var pendingProviderIDs: [String] = []
    var pendingProviderCountByRepository: [String: Int] = [:]
    var pendingRepositoryIDs: [String] = []

    var pendingProviderCount: Int {
        pendingProviderCountByRepository.values.reduce(0, +)
    }
    var retryPending: Bool { !pendingRepositoryIDs.isEmpty }
    var isComplete: Bool { !retryPending }
}

struct NuvioCodeRepairResult: Equatable {
    let readiness: NuvioCodeReadiness
    let attemptedRepositoryIDs: [String]
    let wasInterrupted: Bool
    let restoreWasPersisted: Bool

    init(
        readiness: NuvioCodeReadiness,
        attemptedRepositoryIDs: [String],
        wasInterrupted: Bool,
        restoreWasPersisted: Bool = false
    ) {
        self.readiness = readiness
        self.attemptedRepositoryIDs = attemptedRepositoryIDs
        self.wasInterrupted = wasInterrupted
        self.restoreWasPersisted = restoreWasPersisted
    }
}

enum NuvioPluginError: LocalizedError {
    case invalidRepositoryURL
    case emptyRepositoryURL
    case duplicateRepository
    case manifestNameMissing
    case manifestVersionMissing
    case manifestHasNoProviders
    case repositoryInstallFailed(String)
    case storedStateUnreadable
    case requiresGrownUpProfile
    case repositoryNotFound
    case providerNotFound
    case getStreamsNotFound
    case runtimeTimeout

    case runtimeUnavailable
    case runtimeFailed(String)
    case runtimeLimitExceeded(String)
    case runtimeBootstrapFailed(String)
    case invalidResponse
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryURL:
            return "Enter a valid plugin repository URL."
        case .emptyRepositoryURL:
            return "Enter a plugin repository URL."
        case .duplicateRepository:
            return "That plugin repository is already installed."
        case .manifestNameMissing:
            return "Plugin manifest is missing a name."
        case .manifestVersionMissing:
            return "Plugin manifest is missing a version."
        case .manifestHasNoProviders:
            return "Plugin manifest does not contain any providers."
        case .repositoryInstallFailed(let message):
            return message.isEmpty ? "Plugin repository install failed." : message
        case .storedStateUnreadable:
            return "Installed plugin data could not be read. Eclipse preserved it and blocked changes until a valid backup is restored or the plugin data is explicitly reset."
        case .requiresGrownUpProfile:
            return "Switch to a grown-up profile to change Nuvio plugins."
        case .repositoryNotFound:
            return "Plugin repository was not found."
        case .providerNotFound:
            return "Plugin provider was not found."
        case .getStreamsNotFound:
            return "Plugin does not export getStreams."
        case .runtimeTimeout:
            return "Plugin timed out while fetching streams."
        case .runtimeUnavailable:
            return "Too many plugins have stopped responding. Eclipse will let plugins run again in a few minutes."
        case .runtimeFailed(let message):
            return message.isEmpty ? "Plugin runtime failed." : message
        case .runtimeLimitExceeded(let message):
            return message.isEmpty
                ? "Eclipse stopped this plugin at one of its own limits."
                : message
        case .runtimeBootstrapFailed(let message):
            return message.isEmpty
                ? "Eclipse's plugin runtime failed to start."
                : "Eclipse's plugin runtime failed to start: \(message)"
        case .invalidResponse:
            return "Plugin returned an invalid stream response."
        case .unavailable:
            return "Plugins are unavailable in this build."
        }
    }
}

enum NuvioPluginSupport {
    static let sourceIDPrefix = "nuvio:"

    static func normalizeType(_ value: String) -> String {
        switch value.lowercased() {
        case "series", "show", "other":
            return "tv"
        default:
            return value.lowercased()
        }
    }

    static func isDirectHTTPURL(_ value: String?) -> Bool {
        guard let value, value.utf8.count <= 16 * 1_024 else { return false }
        return ServiceSandboxState.validatedHTTPURL(value) != nil
    }

    static func repairedDeliveryURL(_ value: String) -> String? {
        guard value.contains(" ") else { return nil }
        let repaired = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "%20")
        guard repaired != value, isDirectHTTPURL(repaired) else { return nil }
        return repaired
    }

    static func isUnreachableHostError(_ error: Error) -> Bool {
        guard let securityError = error as? SkyStreamSecurityError else { return false }
        switch securityError {
        case .dnsResolutionFailed, .dnsReturnedNoAddresses:
            return true
        default:
            return false
        }
    }

    static func urlDeliveryDefect(_ value: String) -> String? {
        SkyStreamRemoteURLPolicy.deliveryDefect(in: value)
    }

    static func urlDefectEvidence(_ value: String) -> String {
        SkyStreamRemoteURLPolicy.defectEvidence(of: value)
    }

    static func sanitizedHeaders(_ headers: [String: String]?) -> [String: String]? {
        guard let headers else { return nil }
        let maximumCount = 64
        let maximumTotalBytes = 32 * 1024
        let managedNames: Set<String> = [
            "accept-encoding", "connection", "content-length", "host", "keep-alive",
            "proxy-authenticate", "proxy-authorization", "proxy-connection", "range", "te",
            "trailer", "transfer-encoding", "upgrade"
        ]
        let validNameCharacters = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        )
        var accepted: [String: String] = [:]
        var totalBytes = 0
        for (rawName, rawValue) in headers.sorted(by: {
            let lhs = $0.key.lowercased()
            let rhs = $1.key.lowercased()
            let priority: [String: Int] = [
                "authorization": 0, "cookie": 1, "referer": 2,
                "origin": 3, "user-agent": 4
            ]
            let lhsPriority = priority[lhs] ?? 5
            let rhsPriority = priority[rhs] ?? 5
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs == rhs ? $0.key < $1.key : lhs < rhs
        }) {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedName = name.lowercased()
            let nameIsValid = !name.isEmpty && name.unicodeScalars.allSatisfy {
                $0.value < 128 && validNameCharacters.contains($0)
            }
            let valueIsValid = !value.isEmpty && value.unicodeScalars.allSatisfy {
                $0.value == 9 || $0.value >= 32 && $0.value != 127
            }
            guard accepted.count < maximumCount,
                  name.utf8.count <= 128,
                  value.utf8.count <= 16 * 1_024,
                  nameIsValid,
                  valueIsValid,
                  !managedNames.contains(normalizedName),
                  accepted[normalizedName] == nil else {
                continue
            }
            let size = name.utf8.count + value.utf8.count + 4
            guard size <= maximumTotalBytes - totalBytes else { continue }
            accepted[normalizedName] = value
            totalBytes += size
        }
        return accepted.isEmpty ? nil : accepted
    }

    static func isSourceID(_ value: String) -> Bool {
        guard value.hasPrefix(sourceIDPrefix) else { return false }
        return !value.dropFirst(sourceIDPrefix.count).isEmpty
    }

    static func repositoryID(forManifestURL manifestURL: String) -> String {
        sourceIDPrefix + String(manifestURL.lowercased().sha256.prefix(32))
    }

    static func scraperSourceID(manifestURL: String, providerKey: String) -> String {
        sourceIDPrefix + String("\(manifestURL.lowercased())::\(providerKey)".sha256.prefix(32))
    }

    static func streamID(scraperId: String, sourceId: String, url: String, title: String, index: Int) -> String {
        "\(sourceId)|\(scraperId)|\(index)|\(url)|\(title)".sha256
    }

    static func fallbackRepositoryLabel(for repositoryUrl: String) -> String {
        guard let url = URL(string: repositoryUrl) else { return repositoryUrl }
        return url.host ?? repositoryUrl
    }

    static func normalizeManifestURL(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NuvioPluginError.emptyRepositoryURL }

        var candidate = trimmed
        if !candidate.lowercased().hasPrefix("http://"), !candidate.lowercased().hasPrefix("https://") {
            candidate = "https://" + candidate
        }
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            throw NuvioPluginError.invalidRepositoryURL
        }
        components.fragment = nil

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.lowercased().hasSuffix("/manifest.json") {
            path += "/manifest.json"
        }
        components.path = path

        guard let normalized = components.string else {
            throw NuvioPluginError.invalidRepositoryURL
        }
        guard normalized.count <= NuvioPluginStore.Bounds.textLength else {
            throw NuvioPluginError.invalidRepositoryURL
        }
        return normalized
    }

    static func executableOrigin(of urlString: String) -> URL? {
        guard let parsed = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = parsed.port ?? (scheme == "https" ? 443 : 80)
        return origin.url
    }

    static func sharesExecutableOrigin(_ candidate: String, with origin: URL) -> Bool {
        sharesExecutableOrigin(candidate, withAny: [origin])
    }

    static func sharesExecutableOrigin(_ candidate: String, withAny origins: [URL]) -> Bool {
        guard let candidateOrigin = executableOrigin(of: candidate) else { return false }
        return origins.contains(candidateOrigin)
    }

    static func authorizedExecutableOrigins(typed: String, delivered: String) -> [URL] {
        let candidates = [typed, delivered].compactMap(executableOrigin)
        let secureHosts = Set(
            candidates
                .filter { $0.scheme?.lowercased() == "https" }
                .compactMap { $0.host?.lowercased() }
        )
        var authorized: [URL] = []
        for origin in candidates {
            if origin.scheme?.lowercased() == "http",
               let host = origin.host?.lowercased(),
               secureHosts.contains(host) {
                continue
            }
            if !authorized.contains(origin) { authorized.append(origin) }
        }
        return authorized
    }

    static func isExecutableSchemeDowngrade(from typed: String, to delivered: String) -> Bool {
        guard let typedOrigin = executableOrigin(of: typed),
              let deliveredOrigin = executableOrigin(of: delivered) else {
            return false
        }
        return typedOrigin.scheme?.lowercased() == "https"
            && deliveredOrigin.scheme?.lowercased() == "http"
    }

    static func codeURL(manifestURL: String, filename: String) -> String {
        let trimmedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmedFilename.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return trimmedFilename
        }
        guard var manifestComponents = URLComponents(string: manifestURL) else { return "" }
        let manifestQuery = manifestComponents.percentEncodedQuery
        manifestComponents.percentEncodedQuery = nil
        manifestComponents.fragment = nil
        if manifestComponents.path.lowercased().hasSuffix("/manifest.json") {
            manifestComponents.path.removeLast("/manifest.json".count)
        }
        while manifestComponents.path.hasSuffix("/") {
            manifestComponents.path.removeLast()
        }
        manifestComponents.path += "/"
        guard let baseURL = manifestComponents.url,
              let resolved = URL(
                  string: String(trimmedFilename.drop(while: { $0 == "/" })),
                  relativeTo: baseURL
              )?.absoluteURL,
              var result = URLComponents(
                  url: resolved,
                  resolvingAgainstBaseURL: false
              ) else {
            return ""
        }
        if result.percentEncodedQuery == nil {
            result.percentEncodedQuery = manifestQuery
        }
        result.fragment = nil
        return result.string ?? ""
    }

    static func manifestScraperIsPersistable(_ scraper: NuvioPluginManifestScraper) -> Bool {
        let textValues = [
            scraper.id,
            scraper.name,
            scraper.description ?? "",
            scraper.author ?? "",
            scraper.version,
            scraper.filename,
            scraper.logo ?? ""
        ]
        guard !scraper.id.isEmpty,
              scraper.id == scraper.id.trimmingCharacters(in: .whitespacesAndNewlines),
              !scraper.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              textValues.allSatisfy({ $0.count <= NuvioPluginStore.Bounds.textLength }),
              scraper.supportedTypes.count <= NuvioPluginStore.Bounds.supportedTypes,
              (scraper.contentLanguage?.count ?? 0) <= NuvioPluginStore.Bounds.contentLanguages,
              ((scraper.formats ?? scraper.supportedFormats)?.count ?? 0)
                <= NuvioPluginStore.Bounds.formats else {
            return false
        }
        let tokens = scraper.supportedTypes
            + (scraper.contentLanguage ?? [])
            + (scraper.formats ?? scraper.supportedFormats ?? [])
        return tokens.allSatisfy { $0.count <= NuvioPluginStore.Bounds.tokenLength }
    }

    static func persistableManifestScrapers(
        _ scrapers: [NuvioPluginManifestScraper]
    ) -> [NuvioPluginManifestScraper] {
        var providerIDs = Set<String>()
        var usable: [NuvioPluginManifestScraper] = []
        for scraper in scrapers {
            guard manifestScraperIsPersistable(scraper),
                  providerIDs.insert(scraper.id).inserted else {
                continue
            }
            usable.append(scraper)
        }
        return usable
    }

    static func manifestScrapersAreComplete(_ scrapers: [NuvioPluginManifestScraper]) -> Bool {
        var providerIDs = Set<String>()
        for scraper in scrapers {
            guard manifestScraperIsPersistable(scraper),
                  providerIDs.insert(scraper.id).inserted else {
                return false
            }
        }
        return true
    }

    static func codeFileName(forScraperID scraperID: String) -> String {
        String(scraperID.sha256.prefix(40)) + ".js"
    }
}
