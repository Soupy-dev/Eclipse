import Foundation
import CoreData

// MARK: - Stremio Manifest

struct StremioManifest: Codable {
    let id: String
    let name: String
    let description: String?
    let version: String?
    let logo: String?
    let types: [String]?
    let resources: [StremioResource]?
    let idPrefixes: [String]?
    let catalogs: [StremioCatalog]?
    let behaviorHints: StremioManifestBehaviorHints?

    enum CodingKeys: String, CodingKey {
        case id, name, description, version, logo, types, resources, idPrefixes, catalogs, behaviorHints
    }

    /// Whether this addon supports a given ID prefix (e.g. "tt", "tmdb:", "kitsu:")
    func supportsPrefix(_ prefix: String) -> Bool {
        guard let prefixes = idPrefixes, !prefixes.isEmpty else { return true }
        return prefixes.contains(where: { prefix.hasPrefix($0) })
    }

    /// Whether this addon supports the "stream" resource
    var supportsStreams: Bool {
        guard let resources = resources else { return false }
        return resources.contains { $0.isStream }
    }

    /// Whether this addon supports the "subtitles" resource
    var supportsSubtitles: Bool {
        guard let resources = resources else { return false }
        return resources.contains { $0.isSubtitles }
    }

    var supportsCatalogs: Bool {
        guard let resources = resources else { return false }
        return resources.contains { $0.isCatalog }
    }

    var supportsPlayableResources: Bool {
        supportsStreams || supportsSubtitles
    }

    var supportsInstallableResources: Bool {
        supportsPlayableResources || supportsCatalogs
    }

    var supportsMeta: Bool {
        guard let resources = resources else { return false }
        return resources.contains { $0.isMeta }
    }

    var searchableCatalogs: [StremioCatalog] {
        catalogs?.filter { $0.canSearchWithQueryOnly } ?? []
    }

    var homeCatalogs: [StremioCatalog] {
        guard supportsCatalogs else { return [] }
        return catalogs?.filter { $0.isHomeFeedCapable && $0.eclipseMediaType != nil } ?? []
    }

    var streamIdPrefixes: [String]? {
        let resourcePrefixes = resources?
            .flatMap { $0.idPrefixes(for: "stream") }
            .filter { !$0.isEmpty } ?? []
        return resourcePrefixes.isEmpty ? idPrefixes : resourcePrefixes
    }

    var subtitleIdPrefixes: [String]? {
        let resourcePrefixes = resources?
            .flatMap { $0.idPrefixes(for: "subtitles") }
            .filter { !$0.isEmpty } ?? []
        return resourcePrefixes.isEmpty ? idPrefixes : resourcePrefixes
    }

    func supportsResource(_ resourceName: String, type requestedType: String) -> Bool {
        let resourceTypes = resources?
            .flatMap { $0.types(for: resourceName) }
            .filter { !$0.isEmpty } ?? []
        let allowedTypes = resourceTypes.isEmpty ? (types ?? []) : resourceTypes
        guard !allowedTypes.isEmpty else { return true }
        return allowedTypes.contains { manifestTypeMatches($0, requestedType) }
    }

    private func manifestTypeMatches(_ allowedType: String, _ requestedType: String) -> Bool {
        let allowed = allowedType.lowercased()
        let requested = requestedType.lowercased()
        return allowed == requested ||
            (allowed == "tv" && requested == "series") ||
            (allowed == "series" && requested == "tv")
    }
}

struct StremioManifestBehaviorHints: Codable {
    let configurable: Bool?
    let configurationRequired: Bool?
}

// MARK: - Resource (can be a string or an object)

enum StremioResource: Codable {
    case simple(String)
    case detailed(StremioResourceDetail)

    var isStream: Bool {
        switch self {
        case .simple(let name): return name == "stream"
        case .detailed(let detail): return detail.name == "stream"
        }
    }

    var isSubtitles: Bool {
        switch self {
        case .simple(let name): return name == "subtitles"
        case .detailed(let detail): return detail.name == "subtitles"
        }
    }

    var isCatalog: Bool {
        switch self {
        case .simple(let name): return name == "catalog"
        case .detailed(let detail): return detail.name == "catalog"
        }
    }

    var isMeta: Bool {
        switch self {
        case .simple(let name): return name == "meta"
        case .detailed(let detail): return detail.name == "meta"
        }
    }

    func idPrefixes(for resourceName: String) -> [String] {
        switch self {
        case .simple:
            return []
        case .detailed(let detail):
            return detail.name == resourceName ? (detail.idPrefixes ?? []) : []
        }
    }

    func types(for resourceName: String) -> [String] {
        switch self {
        case .simple:
            return []
        case .detailed(let detail):
            return detail.name == resourceName ? (detail.types ?? []) : []
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .simple(string)
        } else {
            let detail = try container.decode(StremioResourceDetail.self)
            self = .detailed(detail)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .simple(let name):
            try container.encode(name)
        case .detailed(let detail):
            try container.encode(detail)
        }
    }
}

struct StremioResourceDetail: Codable {
    let name: String
    let types: [String]?
    let idPrefixes: [String]?

    enum CodingKeys: String, CodingKey {
        case name, types, type, idPrefixes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        if let values = try? container.decodeIfPresent([String].self, forKey: .types) {
            types = values
        } else if let value = try? container.decodeIfPresent(String.self, forKey: .type) {
            types = [value]
        } else {
            types = nil
        }
        idPrefixes = try? container.decodeIfPresent([String].self, forKey: .idPrefixes)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(types, forKey: .types)
        try container.encodeIfPresent(idPrefixes, forKey: .idPrefixes)
    }
}

// MARK: - Catalog and Meta Responses

struct StremioCatalog: Codable, Hashable {
    let type: String
    let id: String
    let name: String?
    let extra: [StremioCatalogExtra]?

    var supportsSearch: Bool {
        extra?.contains { $0.name == "search" } ?? false
    }

    var canSearchWithQueryOnly: Bool {
        guard supportsSearch else { return false }
        return extra?.allSatisfy { extra in
            extra.isRequired != true || extra.name == "search"
        } ?? true
    }

    var isHomeFeedCapable: Bool {
        let required = extra?.filter { $0.isRequired == true } ?? []
        return required.allSatisfy { $0.name == "skip" }
    }

    var shouldSendInitialSkip: Bool {
        extra?.contains { $0.name == "skip" && $0.isRequired == true } ?? false
    }

    var eclipseMediaType: String? {
        let normalized = type.lowercased()
        if normalized == "movie" { return "movie" }
        if normalized == "series" || normalized == "tv" { return "tv" }
        return nil
    }

    func supportsType(_ requestedType: String) -> Bool {
        type == requestedType || (requestedType == "series" && type == "tv")
    }
}

struct StremioCatalogExtra: Codable, Hashable {
    let name: String
    let isRequired: Bool?
    let options: [String]?
    let optionsLimit: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            self.name = name
            self.isRequired = nil
            self.options = nil
            self.optionsLimit = nil
            return
        }

        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? keyed.decode(String.self, forKey: .name)) ?? ""
        isRequired = try? keyed.decodeIfPresent(Bool.self, forKey: .isRequired)
        options = try? keyed.decodeIfPresent([String].self, forKey: .options)
        optionsLimit = try? keyed.decodeIfPresent(Int.self, forKey: .optionsLimit)
    }
}

struct StremioCatalogResponse: Codable {
    let metas: [StremioMetaPreview]

    enum CodingKeys: String, CodingKey {
        case metas
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metas = Self.decodeLossyArray(from: container, forKey: .metas)
    }

    private static func decodeLossyArray(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [StremioMetaPreview] {
        guard var unkeyedContainer = try? container.nestedUnkeyedContainer(forKey: key) else {
            return []
        }

        var decoded = [StremioMetaPreview]()
        while !unkeyedContainer.isAtEnd {
            if let meta = try? unkeyedContainer.decode(StremioMetaPreview.self) {
                decoded.append(meta)
            } else {
                _ = try? unkeyedContainer.decode(AnyCodable.self)
            }
        }
        return decoded
    }
}

struct StremioMetaResponse: Codable {
    let meta: StremioMetaPreview?

    enum CodingKeys: String, CodingKey {
        case meta
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let single = try? container.decodeIfPresent(StremioMetaPreview.self, forKey: .meta) {
            meta = single
        } else if let array = try? container.decodeIfPresent([StremioMetaPreview].self, forKey: .meta) {
            meta = array.first
        } else {
            meta = nil
        }
    }
}

struct StremioMetaPreview: Codable, Identifiable, Hashable {
    let id: String
    let type: String?
    let name: String
    let imdbId: String?
    let tmdbId: Int?
    let poster: String?
    let background: String?
    let description: String?
    let releaseInfo: String?
    let released: String?
    let imdbRating: String?
    let videos: [StremioVideo]?
    let behaviorHints: StremioMetaBehaviorHints?

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, description, releaseInfo, released, imdbRating, videos, behaviorHints
        case imdbId = "imdb_id"
        case imdbIdCamel = "imdbId"
        case tmdbId = "tmdb_id"
        case tmdbIdCamel = "tmdbId"
        case moviedbId = "moviedb_id"
        case moviedbIdCamel = "moviedbId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        name = try container.decode(String.self, forKey: .name)
        imdbId = container.decodeIfPresentLossyString(forKey: .imdbId)
            ?? container.decodeIfPresentLossyString(forKey: .imdbIdCamel)
        tmdbId = Self.decodeFlexibleInt(from: container, forKey: .tmdbId)
            ?? Self.decodeFlexibleInt(from: container, forKey: .tmdbIdCamel)
            ?? Self.decodeFlexibleInt(from: container, forKey: .moviedbId)
            ?? Self.decodeFlexibleInt(from: container, forKey: .moviedbIdCamel)
        poster = try container.decodeIfPresent(String.self, forKey: .poster)
        background = try container.decodeIfPresent(String.self, forKey: .background)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        releaseInfo = try container.decodeIfPresent(String.self, forKey: .releaseInfo)
        released = try container.decodeIfPresent(String.self, forKey: .released)
        imdbRating = try container.decodeIfPresent(String.self, forKey: .imdbRating)
        videos = try container.decodeIfPresent([StremioVideo].self, forKey: .videos)
        behaviorHints = try container.decodeIfPresent(StremioMetaBehaviorHints.self, forKey: .behaviorHints)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(imdbId, forKey: .imdbId)
        try container.encodeIfPresent(tmdbId, forKey: .tmdbId)
        try container.encodeIfPresent(poster, forKey: .poster)
        try container.encodeIfPresent(background, forKey: .background)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(releaseInfo, forKey: .releaseInfo)
        try container.encodeIfPresent(released, forKey: .released)
        try container.encodeIfPresent(imdbRating, forKey: .imdbRating)
        try container.encodeIfPresent(videos, forKey: .videos)
        try container.encodeIfPresent(behaviorHints, forKey: .behaviorHints)
    }

    private static func decodeFlexibleInt(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                return intValue
            }
            let numericRuns = trimmed.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            if numericRuns.count == 1 {
                return Int(numericRuns[0])
            }
        }
        return nil
    }
}

private extension KeyedDecodingContainer where Key == StremioMetaPreview.CodingKeys {
    func decodeIfPresentLossyString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        return nil
    }
}

struct StremioMetaBehaviorHints: Codable, Hashable {
    let defaultVideoId: String?
}

struct StremioVideo: Codable, Identifiable, Hashable {
    let id: String
    let title: String?
    let released: String?
    let season: Int?
    let episode: Int?
    let streams: [StremioStream]?

    enum CodingKeys: String, CodingKey {
        case id, title, released, season, episode, streams
    }
}

// MARK: - Stream Response

struct StremioStreamResponse: Codable {
    let streams: [StremioStream]?

    enum CodingKeys: String, CodingKey {
        case streams
    }

    /// Lossy decoding: skips individual streams that fail to decode instead of
    /// dropping the entire array (the default Codable behaviour).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Try decoding each element individually; skip failures
        if var unkeyedContainer = try? container.nestedUnkeyedContainer(forKey: .streams) {
            var decoded = [StremioStream]()
            while !unkeyedContainer.isAtEnd {
                if let stream = try? unkeyedContainer.decode(StremioStream.self) {
                    decoded.append(stream)
                } else {
                    // Skip the bad element so the container advances
                    _ = try? unkeyedContainer.decode(AnyCodable.self)
                }
            }
            streams = decoded.isEmpty ? nil : decoded
        } else {
            streams = nil
        }
    }
}

struct StremioSubtitleResponse: Codable, Sendable {
    let subtitles: [StremioSubtitle]?

    enum CodingKeys: String, CodingKey {
        case subtitles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if var unkeyedContainer = try? container.nestedUnkeyedContainer(forKey: .subtitles) {
            var decoded = [StremioSubtitle]()
            while !unkeyedContainer.isAtEnd {
                if let subtitle = try? unkeyedContainer.decode(StremioSubtitle.self) {
                    decoded.append(subtitle)
                } else {
                    _ = try? unkeyedContainer.decode(AnyCodable.self)
                }
            }
            subtitles = decoded.isEmpty ? nil : decoded
        } else {
            subtitles = nil
        }
    }
}

/// Throwaway type used only to advance the unkeyed container past a bad element.
private struct AnyCodable: Codable {
    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd {
                if (try? array.decodeNil()) == true { continue }
                _ = try array.decode(AnyCodable.self)
            }
            return
        }

        if let object = try? decoder.container(keyedBy: AnyCodingKey.self) {
            for key in object.allKeys {
                if (try? object.decodeNil(forKey: key)) == true { continue }
                _ = try object.decode(AnyCodable.self, forKey: key)
            }
            return
        }

        let value = try decoder.singleValueContainer()
        if value.decodeNil() { return }
        if (try? value.decode(Bool.self)) != nil { return }
        if (try? value.decode(Double.self)) != nil { return }
        if (try? value.decode(String.self)) != nil { return }
        throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unsupported JSON value")
    }
    func encode(to encoder: Encoder) throws {}
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

struct StremioStream: Codable, Identifiable, Hashable {
    let id: String

    let url: String?
    let infoHash: String?
    let title: String?
    let name: String?
    let description: String?
    let lang: String?
    let language: String?
    let languages: [String]?
    let behaviorHints: StremioStreamBehaviorHints?
    let subtitles: [StremioSubtitle]?

    enum CodingKeys: String, CodingKey {
        case url, infoHash, title, name, description, lang, language, languages, behaviorHints, subtitles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        infoHash = try container.decodeIfPresent(String.self, forKey: .infoHash)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        lang = try? container.decodeIfPresent(String.self, forKey: .lang)
        language = try? container.decodeIfPresent(String.self, forKey: .language)
        if let values = try? container.decodeIfPresent([String].self, forKey: .languages) {
            languages = values
        } else if let value = try? container.decodeIfPresent(String.self, forKey: .languages) {
            languages = [value]
        } else {
            languages = nil
        }
        // Use try? so unexpected shapes don't kill the whole stream
        behaviorHints = try? container.decodeIfPresent(StremioStreamBehaviorHints.self, forKey: .behaviorHints)
        subtitles = try? container.decodeIfPresent([StremioSubtitle].self, forKey: .subtitles)
        id = url ?? infoHash ?? UUID().uuidString
    }

    /// Whether this stream is a direct HTTP(S) link (safe, no torrent)
    var isDirectHTTP: Bool {
        guard let url = url, !url.isEmpty else { return false }
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// Display name for the stream (prefers name, falls back to title)
    var displayName: String {
        if let name = name, !name.isEmpty { return name }
        if let title = title, !title.isEmpty { return title }
        return "Stream"
    }

    /// Extracts proxy headers from behaviorHints if available
    var proxyHeaders: [String: String]? {
        behaviorHints?.proxyHeaders?.request
    }

    var formattedVideoSize: String? {
        guard let videoSize = behaviorHints?.videoSize, videoSize > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: videoSize, countStyle: .file)
    }

    var languageHints: [String] {
        [lang, language]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            + (languages ?? [])
    }
}

struct StremioStreamBehaviorHints: Codable, Hashable {
    let notWebReady: Bool?
    let bingeGroup: String?
    let proxyHeaders: StremioProxyHeaders?
    let filename: String?
    let videoSize: Int64?

    enum CodingKeys: String, CodingKey {
        case notWebReady, bingeGroup, proxyHeaders, filename, videoSize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // notWebReady can arrive as Bool, Int, or String from various addons
        if let b = try? container.decodeIfPresent(Bool.self, forKey: .notWebReady) {
            notWebReady = b
        } else if let i = try? container.decodeIfPresent(Int.self, forKey: .notWebReady) {
            notWebReady = i != 0
        } else {
            notWebReady = nil
        }
        bingeGroup = try? container.decodeIfPresent(String.self, forKey: .bingeGroup)
        proxyHeaders = try? container.decodeIfPresent(StremioProxyHeaders.self, forKey: .proxyHeaders)
        filename = try? container.decodeIfPresent(String.self, forKey: .filename)
        if let size = try? container.decodeIfPresent(Int64.self, forKey: .videoSize) {
            videoSize = size
        } else if let size = try? container.decodeIfPresent(Double.self, forKey: .videoSize) {
            videoSize = Int64(size)
        } else if let size = try? container.decodeIfPresent(String.self, forKey: .videoSize) {
            videoSize = Int64(size)
        } else {
            videoSize = nil
        }
    }
}

struct StremioProxyHeaders: Codable, Hashable {
    let request: [String: String]?
}

struct StremioSubtitle: Codable, Sendable, Hashable {
    let id: String?
    let url: String?
    let lang: String?
    let name: String?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case id, url, lang, name, title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Some addons return subtitle id as an integer
        if let s = try? container.decodeIfPresent(String.self, forKey: .id) {
            id = s
        } else if let i = try? container.decodeIfPresent(Int.self, forKey: .id) {
            id = String(i)
        } else {
            id = nil
        }
        url = try? container.decodeIfPresent(String.self, forKey: .url)
        lang = try? container.decodeIfPresent(String.self, forKey: .lang)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let title, !title.isEmpty { return title }
        if let lang, !lang.isEmpty { return lang.uppercased() }
        return id ?? "Subtitle"
    }
}

// MARK: - Stremio Addon Model (persisted)

struct StremioAddon: Identifiable, Hashable {
    let id: UUID
    let configuredURL: String
    let manifest: StremioManifest
    let isActive: Bool
    let sortIndex: Int64

    static func == (lhs: StremioAddon, rhs: StremioAddon) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - StremioAddonEntity (CoreData)

@objc(StremioAddonEntity)
public class StremioAddonEntity: NSManagedObject { }

extension StremioAddonEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<StremioAddonEntity> {
        return NSFetchRequest<StremioAddonEntity>(entityName: "StremioAddonEntity")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var configuredURL: String?
    @NSManaged public var manifestJSON: String?
    @NSManaged public var isActive: Bool
    @NSManaged public var sortIndex: Int64

    override public func awakeFromInsert() {
        super.awakeFromInsert()
        if id == nil {
            let temp = UUID()
            id = temp
            Logger.shared.log("Added empty StremioAddonEntity: \(temp)", type: "Stremio")
        }
    }
}

extension StremioAddonEntity: Identifiable { }

extension StremioAddonEntity {
    var asModel: StremioAddon? {
        guard
            let id = self.id,
            let configuredURL = self.configuredURL,
            let manifestJSON = self.manifestJSON,
            let data = manifestJSON.data(using: .utf8)
        else {
            return nil
        }

        do {
            let manifest = try JSONDecoder().decode(StremioManifest.self, from: data)
            return StremioAddon(
                id: id,
                configuredURL: StremioConfiguredURLVault.resolve(addonID: id, persistedURL: configuredURL),
                manifest: manifest,
                isActive: isActive,
                sortIndex: sortIndex
            )
        } catch {
            Logger.shared.log("Failed to decode StremioManifest for \(id.uuidString): \(error.localizedDescription)", type: "Stremio")
            return nil
        }
    }
}
