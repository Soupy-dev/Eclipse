import Foundation

struct NuvioPluginManifest: Decodable {
    let name: String
    let version: String
    let description: String?
    let author: String?

    var scrapers: [NuvioPluginManifestScraper]
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

    var hostLabel: String {
        URL(string: manifestUrl)?.host ?? manifestUrl
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? hostLabel : trimmed
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
        case .number(let value): return value != 0
        case .string(let value): return ["true", "yes", "1"].contains(value.lowercased())
        }
    }

    var stringValue: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .string(let value): return value
        case .number(let value):
            return value == value.rounded() ? String(Int(value)) : String(value)
        }
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
}

enum NuvioOutcomeBlame {
    case none
    case provider
    case eclipse
}

enum NuvioProviderOutcome: Equatable {
    case results([NuvioPluginStream])
    case noResults

    case unplayableOnly(count: Int)
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
        case .unplayableOnly(let count):
            return count == 1
                ? "1 result, but it is a torrent link Eclipse cannot play"
                : "\(count) results, but they are torrent links Eclipse cannot play"
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
        case .unplayableOnly:
            return "Eclipse plays direct links only."
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
}

enum NuvioPluginError: LocalizedError {
    case invalidRepositoryURL
    case emptyRepositoryURL
    case duplicateRepository
    case manifestNameMissing
    case manifestVersionMissing
    case manifestHasNoProviders
    case repositoryInstallFailed(String)
    case repositoryNotFound
    case providerNotFound
    case getStreamsNotFound
    case runtimeTimeout

    case runtimeUnavailable
    case runtimeFailed(String)
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
        case .repositoryNotFound:
            return "Plugin repository was not found."
        case .providerNotFound:
            return "Plugin provider was not found."
        case .getStreamsNotFound:
            return "Plugin does not export getStreams."
        case .runtimeTimeout:
            return "Plugin timed out while fetching streams."
        case .runtimeUnavailable:
            return "Too many plugins have stopped responding. Restart Eclipse to run plugins again."
        case .runtimeFailed(let message):
            return message.isEmpty ? "Plugin runtime failed." : message
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
    static let maxHeaderValueCharacters = 8 * 1024

    static func normalizeType(_ value: String) -> String {
        switch value.lowercased() {
        case "series", "show", "other":
            return "tv"
        default:
            return value.lowercased()
        }
    }

    static func isDirectHTTPURL(_ value: String?) -> Bool {

        guard let value else { return false }
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
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
        let cleaned = headers.compactMap { key, value -> (String, String)? in
            let headerName = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let headerValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !headerName.isEmpty,
                  !headerValue.isEmpty,
                  headerName.caseInsensitiveCompare("Range") != .orderedSame else {
                return nil
            }
            return (headerName, String(headerValue.prefix(maxHeaderValueCharacters)))
        }
        return cleaned.isEmpty ? nil : Dictionary(cleaned, uniquingKeysWith: { first, _ in first })
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
        return normalized
    }

    static func codeURL(manifestURL: String, filename: String) -> String {
        let trimmedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmedFilename.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return trimmedFilename
        }
        var base = manifestURL.components(separatedBy: "?").first ?? manifestURL
        if base.lowercased().hasSuffix("/manifest.json") {
            base = String(base.dropLast("/manifest.json".count))
        }
        while base.hasSuffix("/") { base.removeLast() }
        return base + "/" + trimmedFilename.drop(while: { $0 == "/" })
    }

    static func codeFileName(forScraperID scraperID: String) -> String {
        String(scraperID.sha256.prefix(40)) + ".js"
    }
}
