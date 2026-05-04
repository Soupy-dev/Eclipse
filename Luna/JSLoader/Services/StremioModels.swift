//
//  StremioModels.swift
//  Luna
//
//  Created by Soupy on 2026.
//

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
    let behaviorHints: StremioManifestBehaviorHints?

    enum CodingKeys: String, CodingKey {
        case id, name, description, version, logo, types, resources, idPrefixes, behaviorHints
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
        _ = try? decoder.singleValueContainer().decode(String.self)
    }
    func encode(to encoder: Encoder) throws {}
}

struct StremioStream: Codable, Identifiable {
    let id: String

    let url: String?
    let infoHash: String?
    let title: String?
    let name: String?
    let description: String?
    let behaviorHints: StremioStreamBehaviorHints?
    let subtitles: [StremioSubtitle]?

    enum CodingKeys: String, CodingKey {
        case url, infoHash, title, name, description, behaviorHints, subtitles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        infoHash = try container.decodeIfPresent(String.self, forKey: .infoHash)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
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
}

struct StremioStreamBehaviorHints: Codable {
    let notWebReady: Bool?
    let bingeGroup: String?
    let proxyHeaders: StremioProxyHeaders?
    let filename: String?

    enum CodingKeys: String, CodingKey {
        case notWebReady, bingeGroup, proxyHeaders, filename
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
    }
}

struct StremioProxyHeaders: Codable {
    let request: [String: String]?
}

struct StremioSubtitle: Codable, Sendable {
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
        return id ?? "OpenSubtitles"
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
                configuredURL: configuredURL,
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
