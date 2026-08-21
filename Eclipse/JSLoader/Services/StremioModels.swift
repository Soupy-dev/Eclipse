//
//  StremioModels.swift
//  Eclipse
//
//  Created by Soupy on 2026.
//

import Foundation
import CoreData

enum StremioJSONBoundary {
    static let limits = SkyStreamJSONEnvelopeValidator.Limits(
        maximumDepth: 16,
        maximumTokens: 100_000,
        maximumValuesPerContainer: 4_096,
        maximumStringBytes: 16 * 1_024,
        maximumScalarTokenBytes: 128
    )

    static func validate(_ data: Data) throws {
        try SkyStreamJSONEnvelopeValidator.validate(data, limits: limits)
    }
}

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try StremioDecodedFieldBoundary.requiredString(
            container.decode(String.self, forKey: .id),
            maximumUTF8Bytes: 512,
            decoder: decoder
        )
        name = try StremioDecodedFieldBoundary.requiredString(
            container.decode(String.self, forKey: .name),
            maximumUTF8Bytes: 1_024,
            decoder: decoder
        )
        description = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .description),
            maximumUTF8Bytes: 16 * 1_024
        )
        version = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .version),
            maximumUTF8Bytes: 128
        )
        logo = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .logo),
            maximumUTF8Bytes: 16 * 1_024
        )
        types = StremioDecodedFieldBoundary.boundedStrings(
            try container.decodeIfPresent([String].self, forKey: .types),
            maximumCount: StremioDecodingLimits.manifestTypes,
            maximumUTF8Bytes: 64
        )
        resources = try container.decodeIfPresent([StremioResource].self, forKey: .resources)
            .map { Array($0.prefix(StremioDecodingLimits.manifestResources)) }
        idPrefixes = StremioDecodedFieldBoundary.boundedStrings(
            try container.decodeIfPresent([String].self, forKey: .idPrefixes),
            maximumCount: StremioDecodingLimits.manifestIDPrefixes,
            maximumUTF8Bytes: 256
        )
        catalogs = try container.decodeIfPresent([StremioCatalog].self, forKey: .catalogs)
            .map { Array($0.prefix(StremioDecodingLimits.manifestCatalogs)) }
        behaviorHints = try container.decodeIfPresent(
            StremioManifestBehaviorHints.self,
            forKey: .behaviorHints
        )
    }

    func supportsPrefix(_ prefix: String) -> Bool {
        guard let prefixes = idPrefixes, !prefixes.isEmpty else { return true }
        return prefixes.contains(where: { prefix.hasPrefix($0) })
    }

    var supportsStreams: Bool {
        guard let resources = resources else { return false }
        return resources.contains { $0.isStream }
    }

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

        return Array(
            (catalogs?.filter { $0.isHomeFeedCapable && $0.eclipseMediaType != nil } ?? [])
                .prefix(maximumHomeCatalogs)
        )
    }

    private var maximumHomeCatalogs: Int { 512 }

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
            self = .simple(try StremioDecodedFieldBoundary.requiredString(
                string,
                maximumUTF8Bytes: 64,
                decoder: decoder
            ))
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
        name = try StremioDecodedFieldBoundary.requiredString(
            (try? container.decode(String.self, forKey: .name)) ?? "",
            maximumUTF8Bytes: 64,
            decoder: decoder
        )
        if let values = try? container.decodeIfPresent([String].self, forKey: .types) {
            types = StremioDecodedFieldBoundary.boundedStrings(
                values,
                maximumCount: StremioDecodingLimits.manifestTypes,
                maximumUTF8Bytes: 64
            )
        } else if let value = try? container.decodeIfPresent(String.self, forKey: .type) {
            types = StremioDecodedFieldBoundary.boundedStrings(
                [value],
                maximumCount: 1,
                maximumUTF8Bytes: 64
            )
        } else {
            types = nil
        }
        idPrefixes = StremioDecodedFieldBoundary.boundedStrings(
            try? container.decodeIfPresent([String].self, forKey: .idPrefixes),
            maximumCount: StremioDecodingLimits.manifestIDPrefixes,
            maximumUTF8Bytes: 256
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(types, forKey: .types)
        try container.encodeIfPresent(idPrefixes, forKey: .idPrefixes)
    }
}

struct StremioCatalog: Codable, Hashable {
    let type: String
    let id: String
    let name: String?
    let extra: [StremioCatalogExtra]?

    enum CodingKeys: String, CodingKey { case type, id, name, extra, extraSupported, extraRequired }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try StremioDecodedFieldBoundary.requiredString(
            container.decode(String.self, forKey: .type),
            maximumUTF8Bytes: 64,
            decoder: decoder
        )
        id = try StremioDecodedFieldBoundary.requiredString(
            container.decode(String.self, forKey: .id),
            maximumUTF8Bytes: 512,
            decoder: decoder
        )
        name = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .name),
            maximumUTF8Bytes: 1_024
        )
        if let declared = try container.decodeIfPresent([StremioCatalogExtra].self, forKey: .extra) {
            extra = Array(declared.prefix(StremioDecodingLimits.catalogExtras))
        } else {
            extra = Self.synthesizedExtra(from: container)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(extra, forKey: .extra)
    }

    private static func synthesizedExtra(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [StremioCatalogExtra]? {
        let supported = StremioDecodedFieldBoundary.boundedStrings(
            try? container.decodeIfPresent([String].self, forKey: .extraSupported),
            maximumCount: StremioDecodingLimits.catalogExtras,
            maximumUTF8Bytes: 64
        ) ?? []
        let required = StremioDecodedFieldBoundary.boundedStrings(
            try? container.decodeIfPresent([String].self, forKey: .extraRequired),
            maximumCount: StremioDecodingLimits.catalogExtras,
            maximumUTF8Bytes: 64
        ) ?? []
        guard !supported.isEmpty || !required.isEmpty else { return nil }

        let requiredNames = Set(required)
        var seen = Set<String>()
        var synthesized: [StremioCatalogExtra] = []
        for name in supported + required where seen.insert(name).inserted {
            synthesized.append(
                StremioCatalogExtra(name: name, isRequired: requiredNames.contains(name))
            )
        }
        return synthesized.isEmpty ? nil : Array(synthesized.prefix(StremioDecodingLimits.catalogExtras))
    }

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
        if normalized == "series" || normalized == "tv" || normalized == "anime" { return "tv" }
        return nil
    }

    func supportsType(_ requestedType: String) -> Bool {
        type == requestedType
            || (requestedType == "series" && (type == "tv" || type == "anime"))
    }
}

struct StremioCatalogExtra: Codable, Hashable {
    let name: String
    let isRequired: Bool?
    let options: [String]?
    let optionsLimit: Int?

    init(name: String, isRequired: Bool?) {
        self.name = name
        self.isRequired = isRequired
        self.options = nil
        self.optionsLimit = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            self.name = try StremioDecodedFieldBoundary.requiredString(
                name,
                maximumUTF8Bytes: 64,
                decoder: decoder
            )
            self.isRequired = nil
            self.options = nil
            self.optionsLimit = nil
            return
        }

        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        name = try StremioDecodedFieldBoundary.requiredString(
            (try? keyed.decode(String.self, forKey: .name)) ?? "",
            maximumUTF8Bytes: 64,
            decoder: decoder
        )
        isRequired = try? keyed.decodeIfPresent(Bool.self, forKey: .isRequired)
        options = StremioDecodedFieldBoundary.boundedStrings(
            try? keyed.decodeIfPresent([String].self, forKey: .options),
            maximumCount: StremioDecodingLimits.catalogExtraOptions,
            maximumUTF8Bytes: 512
        )
        if let rawLimit = try? keyed.decodeIfPresent(Int.self, forKey: .optionsLimit),
           (0...10_000).contains(rawLimit) {
            optionsLimit = rawLimit
        } else {
            optionsLimit = nil
        }
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
        var inspected = 0
        while !unkeyedContainer.isAtEnd,
              inspected < StremioDecodingLimits.catalogMetasPerResponse {
            inspected += 1
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
    let genres: [String]?
    let videos: [StremioVideo]?
    let behaviorHints: StremioMetaBehaviorHints?

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, description, releaseInfo, released, imdbRating, genres, videos, behaviorHints
        case imdbId = "imdb_id"
        case imdbIdCamel = "imdbId"
        case tmdbId = "tmdb_id"
        case tmdbIdCamel = "tmdbId"
        case moviedbId = "moviedb_id"
        case moviedbIdCamel = "moviedbId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try StremioDecodedFieldBoundary.requiredString(
            container.decode(String.self, forKey: .id),
            maximumUTF8Bytes: 2 * 1_024,
            decoder: decoder
        )
        type = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .type),
            maximumUTF8Bytes: 64
        )
        name = try StremioDecodedFieldBoundary.requiredString(
            container.decode(String.self, forKey: .name),
            maximumUTF8Bytes: 1_024,
            decoder: decoder
        )
        imdbId = StremioDecodedFieldBoundary.optionalString(
            container.decodeIfPresentLossyString(forKey: .imdbId)
                ?? container.decodeIfPresentLossyString(forKey: .imdbIdCamel),
            maximumUTF8Bytes: 64
        )
        tmdbId = Self.decodeFlexibleInt(from: container, forKey: .tmdbId)
            ?? Self.decodeFlexibleInt(from: container, forKey: .tmdbIdCamel)
            ?? Self.decodeFlexibleInt(from: container, forKey: .moviedbId)
            ?? Self.decodeFlexibleInt(from: container, forKey: .moviedbIdCamel)
        poster = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .poster),
            maximumUTF8Bytes: 16 * 1_024
        )
        background = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .background),
            maximumUTF8Bytes: 16 * 1_024
        )
        description = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .description),
            maximumUTF8Bytes: 16 * 1_024
        )
        releaseInfo = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .releaseInfo),
            maximumUTF8Bytes: 512
        )
        released = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .released),
            maximumUTF8Bytes: 128
        )
        imdbRating = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .imdbRating),
            maximumUTF8Bytes: 128
        )
        if let values = try? container.decodeIfPresent([String].self, forKey: .genres) {
            genres = StremioDecodedFieldBoundary.boundedStrings(
                values,
                maximumCount: StremioDecodingLimits.genresPerMeta,
                maximumUTF8Bytes: 256
            )
        } else if let value = try? container.decodeIfPresent(String.self, forKey: .genres) {
            genres = StremioDecodedFieldBoundary.boundedStrings(
                value.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                },
                maximumCount: StremioDecodingLimits.genresPerMeta,
                maximumUTF8Bytes: 256
            )
        } else {
            genres = nil
        }
        if var videoContainer = try? container.nestedUnkeyedContainer(forKey: .videos) {
            var decodedVideos: [StremioVideo] = []
            var inspected = 0
            while !videoContainer.isAtEnd,
                  inspected < StremioDecodingLimits.videosPerMeta {
                inspected += 1
                if let video = try? videoContainer.decode(StremioVideo.self) {
                    decodedVideos.append(video)
                } else {
                    _ = try? videoContainer.decode(AnyCodable.self)
                }
            }
            videos = decodedVideos.isEmpty ? nil : decodedVideos
        } else {
            videos = nil
        }
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
        try container.encodeIfPresent(genres, forKey: .genres)
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
            return Int(exactly: value)
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try StremioDecodedFieldBoundary.requiredString(
            container.decode(String.self, forKey: .id),
            maximumUTF8Bytes: 2 * 1_024,
            decoder: decoder
        )
        title = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .title),
            maximumUTF8Bytes: 1_024
        )
        released = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .released),
            maximumUTF8Bytes: 128
        )
        season = try? container.decodeIfPresent(Int.self, forKey: .season)
        episode = try? container.decodeIfPresent(Int.self, forKey: .episode)
        if var streamContainer = try? container.nestedUnkeyedContainer(forKey: .streams) {
            var decodedStreams: [StremioStream] = []
            var inspected = 0
            while !streamContainer.isAtEnd,
                  inspected < StremioDecodingLimits.streamsPerVideo {
                inspected += 1
                if let stream = try? streamContainer.decode(StremioStream.self) {
                    decodedStreams.append(stream)
                } else {
                    _ = try? streamContainer.decode(AnyCodable.self)
                }
            }
            streams = decodedStreams.isEmpty ? nil : decodedStreams
        } else {
            streams = nil
        }
    }
}

enum StremioDecodingLimits {
    // Stream payloads are already byte-bounded by StremioClient. These item
    // limits additionally prevent a compact hostile array from constructing an
    // unbounded number of Swift models before the UI applies its own cap.
    static let streamsPerResponse = 300
    static let subtitlesPerStream = 64
    static let subtitlesPerResponse = 2_048
    static let catalogMetasPerResponse = 300
    static let videosPerMeta = 128
    static let streamsPerVideo = 64
    static let genresPerMeta = 32
    static let manifestTypes = 32
    static let manifestResources = 64
    static let manifestIDPrefixes = 128
    static let manifestCatalogs = 512
    static let catalogExtras = 32
    static let catalogExtraOptions = 64
}

enum StremioAddonOutcome: Equatable {
    case results(count: Int)
    case noResults
    case unplayableOnly(count: Int)
    case externalOnly(count: Int)
    case addonError(String)

    var isFailure: Bool {
        if case .addonError = self { return true }
        return false
    }

    var displayMessage: String {
        switch self {
        case .results(let count):
            return "\(count) result\(count == 1 ? "" : "s")"
        case .noResults:
            return "No results found"
        case .unplayableOnly(let count):
            return count == 1
                ? "1 result, but it is a torrent link Eclipse cannot play"
                : "\(count) results, but they are torrent links Eclipse cannot play"
        case .externalOnly(let count):
            return count == 1
                ? "1 result, but it opens in another service"
                : "\(count) results, but they open in another service"
        case .addonError:
            return "Addon error"
        }
    }

    var displayDetail: String? {
        switch self {
        case .results, .noResults:
            return nil
        case .unplayableOnly:
            return "Eclipse plays direct links only."
        case .externalOnly:
            return "This addon links out to another app instead of handing Eclipse a stream."
        case .addonError(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "This addon did not answer. This is the addon, not Eclipse." : trimmed
        }
    }

    var diagnosticToken: String {
        switch self {
        case .results: return "results"
        case .noResults: return "empty"
        case .unplayableOnly: return "unplayable-only"
        case .externalOnly: return "external-only"
        case .addonError: return "addon-error"
        }
    }
}

struct StremioStreamResponse: Codable {
    let streams: [StremioStream]?

    enum CodingKeys: String, CodingKey {
        case streams
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if var unkeyedContainer = try? container.nestedUnkeyedContainer(forKey: .streams) {
            var decoded = [StremioStream]()
            var seen = Set<String>()
            var inspected = 0
            while !unkeyedContainer.isAtEnd,
                  inspected < StremioDecodingLimits.streamsPerResponse,
                  decoded.count < StremioDecodingLimits.streamsPerResponse {
                inspected += 1
                if let stream = try? unkeyedContainer.decode(StremioStream.self) {
                    let key = stream.url?.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? stream.infoHash?.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? stream.externalUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let key, !key.isEmpty {
                        if seen.insert(key).inserted {
                            decoded.append(stream)
                        }
                    } else {
                        decoded.append(stream)
                    }
                } else {

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
            let decoded = StremioBoundedSubtitleDecoder.decode(
                from: &unkeyedContainer,
                maximumInspected: StremioDecodingLimits.subtitlesPerResponse
            )
            subtitles = decoded.isEmpty ? nil : decoded
        } else {
            subtitles = nil
        }
    }
}

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
    let externalUrl: String?
    let ytId: String?
    let title: String?
    let name: String?
    let description: String?
    let lang: String?
    let language: String?
    let languages: [String]?
    let behaviorHints: StremioStreamBehaviorHints?
    let subtitles: [StremioSubtitle]?

    // Ephemeral resolution provenance. These fields are intentionally absent
    // from CodingKeys so signed media URLs/headers never become durable state.
    // They let a download persist only the bounded addon request and a stable
    // selection intent, then ask the addon for fresh transport data later.
    private(set) var resolvedContentType: String?
    private(set) var resolvedContentID: String?
    private(set) var resolvedStreamOrdinal: Int?

    enum CodingKeys: String, CodingKey {
        case url, infoHash, externalUrl, ytId, title, name, description, lang, language, languages, behaviorHints, subtitles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .url),
            maximumUTF8Bytes: 16 * 1_024
        )
        infoHash = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .infoHash),
            maximumUTF8Bytes: 256
        )
        externalUrl = StremioDecodedFieldBoundary.optionalString(
            try? container.decodeIfPresent(String.self, forKey: .externalUrl),
            maximumUTF8Bytes: 4 * 1_024
        )
        ytId = StremioDecodedFieldBoundary.optionalString(
            try? container.decodeIfPresent(String.self, forKey: .ytId),
            maximumUTF8Bytes: 128
        )
        title = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .title),
            maximumUTF8Bytes: 1_024
        )
        name = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .name),
            maximumUTF8Bytes: 1_024
        )
        description = StremioDecodedFieldBoundary.optionalString(
            try container.decodeIfPresent(String.self, forKey: .description),
            maximumUTF8Bytes: 2 * 1_024
        )
        lang = StremioDecodedFieldBoundary.optionalString(
            try? container.decodeIfPresent(String.self, forKey: .lang),
            maximumUTF8Bytes: 64
        )
        language = StremioDecodedFieldBoundary.optionalString(
            try? container.decodeIfPresent(String.self, forKey: .language),
            maximumUTF8Bytes: 64
        )
        if let values = try? container.decodeIfPresent([String].self, forKey: .languages) {
            languages = StremioDecodedFieldBoundary.boundedStrings(
                values,
                maximumCount: 16,
                maximumUTF8Bytes: 64
            )
        } else if let value = try? container.decodeIfPresent(String.self, forKey: .languages) {
            languages = StremioDecodedFieldBoundary.boundedStrings(
                [value],
                maximumCount: 1,
                maximumUTF8Bytes: 64
            )
        } else {
            languages = nil
        }

        behaviorHints = try? container.decodeIfPresent(StremioStreamBehaviorHints.self, forKey: .behaviorHints)

        if var subtitleContainer = try? container.nestedUnkeyedContainer(forKey: .subtitles) {
            let decodedSubtitles = StremioBoundedSubtitleDecoder.decode(
                from: &subtitleContainer,
                maximumInspected: StremioDecodingLimits.subtitlesPerStream
            )
            subtitles = decodedSubtitles.isEmpty ? nil : decodedSubtitles
        } else {
            subtitles = nil
        }
        resolvedContentType = nil
        resolvedContentID = nil
        resolvedStreamOrdinal = nil
        id = url ?? infoHash ?? externalUrl ?? ytId ?? UUID().uuidString
    }

    func withResolutionProvenance(
        contentType: String,
        contentID: String,
        streamOrdinal: Int
    ) -> Self {
        var copy = self
        let trimmedType = contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = contentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedType.isEmpty, trimmedType.utf8.count <= 64,
              !trimmedID.isEmpty, trimmedID.utf8.count <= 2 * 1_024,
              (0..<StremioDecodingLimits.streamsPerResponse).contains(streamOrdinal) else {
            return copy
        }
        copy.resolvedContentType = trimmedType
        copy.resolvedContentID = trimmedID
        copy.resolvedStreamOrdinal = streamOrdinal
        return copy
    }

    var isDirectHTTP: Bool {
        guard let url = url, !url.isEmpty else { return false }
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    var usesTorrentTransport: Bool {
        if let infoHash = infoHash?.trimmingCharacters(in: .whitespacesAndNewlines),
           !infoHash.isEmpty {
            return true
        }
        guard let url = url?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !url.isEmpty else {
            return false
        }
        return url.hasPrefix("magnet:")
    }

    var hasExternalDestination: Bool {
        if let externalUrl = externalUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           !externalUrl.isEmpty {
            return true
        }
        guard let ytId = ytId?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !ytId.isEmpty
    }

    var displayName: String {
        if let name = name, !name.isEmpty { return name }
        if let title = title, !title.isEmpty { return title }
        return "Stream"
    }

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

        if let b = try? container.decodeIfPresent(Bool.self, forKey: .notWebReady) {
            notWebReady = b
        } else if let i = try? container.decodeIfPresent(Int.self, forKey: .notWebReady) {
            notWebReady = i != 0
        } else {
            notWebReady = nil
        }
        bingeGroup = StremioDecodedFieldBoundary.optionalString(
            try? container.decodeIfPresent(String.self, forKey: .bingeGroup),
            maximumUTF8Bytes: 1_024
        )
        proxyHeaders = try? container.decodeIfPresent(StremioProxyHeaders.self, forKey: .proxyHeaders)
        filename = StremioDecodedFieldBoundary.optionalString(
            try? container.decodeIfPresent(String.self, forKey: .filename),
            maximumUTF8Bytes: 1_024
        )
        if let size = try? container.decodeIfPresent(Int64.self, forKey: .videoSize) {
            videoSize = size
        } else if let size = try? container.decodeIfPresent(Double.self, forKey: .videoSize) {
            let truncated = size.rounded(.towardZero)
            videoSize = size.isFinite ? Int64(exactly: truncated) : nil
        } else if let size = try? container.decodeIfPresent(String.self, forKey: .videoSize) {
            videoSize = Int64(size)
        } else {
            videoSize = nil
        }
    }
}

struct StremioProxyHeaders: Codable, Hashable {
    let request: [String: String]?

    enum CodingKeys: String, CodingKey { case request }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([String: String].self, forKey: .request) ?? [:]
        let bounded = raw.sorted { lhs, rhs in
            lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }.prefix(64).reduce(into: [String: String]()) { result, pair in
            guard pair.key.utf8.count <= 128,
                  pair.value.utf8.count <= 16 * 1_024 else { return }
            result[pair.key] = pair.value
        }
        request = bounded.isEmpty ? nil : bounded
    }
}

struct StremioSubtitle: Codable, Sendable, Hashable {
    let id: String?
    let url: String?
    let lang: String?
    let name: String?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case id, url, file, src, lang, language, name, label, title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let s = try? container.decodeIfPresent(String.self, forKey: .id) {
            id = StremioDecodedFieldBoundary.optionalString(s, maximumUTF8Bytes: 256)
        } else if let i = try? container.decodeIfPresent(Int.self, forKey: .id) {
            id = String(i)
        } else {
            id = nil
        }
        url = Self.firstNonemptyString(
            in: container,
            keys: [.url, .file, .src],
            maximumUTF8Bytes: 16 * 1_024
        )
        lang = Self.firstNonemptyString(
            in: container,
            keys: [.lang, .language],
            maximumUTF8Bytes: 64
        )
        name = Self.firstNonemptyString(
            in: container,
            keys: [.name, .label],
            maximumUTF8Bytes: 512
        )
        title = Self.firstNonemptyString(
            in: container,
            keys: [.title],
            maximumUTF8Bytes: 512
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(lang, forKey: .lang)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(title, forKey: .title)
    }

    private static func firstNonemptyString(
        in container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys],
        maximumUTF8Bytes: Int
    ) -> String? {
        for key in keys {
            guard let value = try? container.decodeIfPresent(String.self, forKey: key) else {
                continue
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.utf8.count <= maximumUTF8Bytes {
                return trimmed
            }
        }
        return nil
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let title, !title.isEmpty { return title }
        if let lang, !lang.isEmpty { return lang.uppercased() }
        return id ?? "Subtitle"
    }

    var playbackDisplayName: String {
        if let name, !name.isEmpty { return name }
        if let title, !title.isEmpty { return title }
        if let lang, !lang.isEmpty { return lang }
        return id ?? "Subtitle"
    }
}

private enum StremioDecodedFieldBoundary {
    static func requiredString(
        _ rawValue: String,
        maximumUTF8Bytes: Int,
        decoder: Decoder
    ) throws -> String {
        guard let value = optionalString(rawValue, maximumUTF8Bytes: maximumUTF8Bytes) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Stremio string exceeded its model boundary"
                )
            )
        }
        return value
    }

    static func optionalString(
        _ rawValue: String?,
        maximumUTF8Bytes: Int
    ) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximumUTF8Bytes else { return nil }
        return value
    }

    static func boundedStrings(
        _ rawValues: [String]?,
        maximumCount: Int,
        maximumUTF8Bytes: Int
    ) -> [String]? {
        guard let rawValues else { return nil }
        var values: [String] = []
        values.reserveCapacity(min(rawValues.count, maximumCount))
        for rawValue in rawValues.prefix(maximumCount) {
            guard let value = optionalString(
                rawValue,
                maximumUTF8Bytes: maximumUTF8Bytes
            ) else { continue }
            values.append(value)
        }
        return values.isEmpty ? nil : values
    }
}

private enum StremioBoundedSubtitleDecoder {
    static func decode(
        from container: inout UnkeyedDecodingContainer,
        maximumInspected: Int
    ) -> [StremioSubtitle] {
        var decoded: [StremioSubtitle] = []
        var seenURLs = Set<String>()
        var inspected = 0
        while !container.isAtEnd, inspected < maximumInspected {
            inspected += 1
            if let subtitle = try? container.decode(StremioSubtitle.self) {
                guard let url = subtitle.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !url.isEmpty,
                      seenURLs.insert(url.lowercased()).inserted else {
                    continue
                }
                decoded.append(subtitle)
            } else {
                _ = try? container.decode(AnyCodable.self)
            }
        }
        return decoded
    }
}

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
