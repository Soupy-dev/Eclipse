#if !os(tvOS)
import Foundation

/// Durable Reader route. The legacy Aidoku case is intentionally retained for
/// decoding old libraries, progress, downloads, CloudKit records, and backups,
/// but no code path may execute it or create new values with it.
enum MangaContentRoute: Codable, Equatable, Hashable {
    case legacyModule(moduleUUID: String, contentParams: String, isNovel: Bool)
    case readerExtension(source: ReaderExtensionSourceID, itemKey: String, legacyStableKey: String?)
    case aidoku(sourceId: String, mangaKey: String)

    enum RouteKind: String, Codable {
        case legacyModule
        case readerExtension
        case aidoku
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case moduleUUID
        case contentParams
        case isNovel
        case sourceId
        case mangaKey
        case source
        case itemKey
        case legacyStableKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(RouteKind.self, forKey: .kind) {
        case .legacyModule:
            self = .legacyModule(
                moduleUUID: try container.decode(String.self, forKey: .moduleUUID),
                contentParams: try container.decode(String.self, forKey: .contentParams),
                isNovel: try container.decodeIfPresent(Bool.self, forKey: .isNovel) ?? false
            )
        case .readerExtension:
            let sourceRaw = try container.decode(String.self, forKey: .source)
            let source = ReaderExtensionSourceID(rawValue: sourceRaw)
            let itemKey = try container.decode(String.self, forKey: .itemKey)
            guard sourceRaw.utf8.count == 64,
                  sourceRaw.allSatisfy(\.isHexDigit),
                  source.isValid else {
                throw DecodingError.dataCorruptedError(
                    forKey: .source,
                    in: container,
                    debugDescription: "Reader Extension source identities must be exact SHA-256 values."
                )
            }
            guard ReaderExtensionSecurityPolicy.persistableProviderContentKey(itemKey) != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .itemKey,
                    in: container,
                    debugDescription: "Reader Extension item identities cannot contain authorization data."
                )
            }
            let legacyStableKey = try container.decodeIfPresent(
                String.self,
                forKey: .legacyStableKey
            )
            if let legacyStableKey, !Self.isValidLegacyStableKey(legacyStableKey) {
                throw DecodingError.dataCorruptedError(
                    forKey: .legacyStableKey,
                    in: container,
                    debugDescription: "Reader Extension legacy identities must be bounded Aidoku stable keys."
                )
            }
            self = .readerExtension(
                source: source,
                itemKey: itemKey,
                legacyStableKey: legacyStableKey
            )
        case .aidoku:
            self = .aidoku(
                sourceId: try container.decode(String.self, forKey: .sourceId),
                mangaKey: try container.decode(String.self, forKey: .mangaKey)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .legacyModule(let moduleUUID, let contentParams, let isNovel):
            try container.encode(RouteKind.legacyModule, forKey: .kind)
            try container.encode(moduleUUID, forKey: .moduleUUID)
            try container.encode(contentParams, forKey: .contentParams)
            try container.encode(isNovel, forKey: .isNovel)
        case .readerExtension(let source, let itemKey, let legacyStableKey):
            if !source.isValid
                || ReaderExtensionSecurityPolicy.persistableProviderContentKey(itemKey) == nil {
                throw EncodingError.invalidValue(
                    itemKey,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Reader Extension item identities cannot contain authorization data."
                    )
                )
            }
            if let legacyStableKey, !Self.isValidLegacyStableKey(legacyStableKey) {
                throw EncodingError.invalidValue(
                    legacyStableKey,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Reader Extension legacy identities must be bounded Aidoku stable keys."
                    )
                )
            }
            try container.encode(RouteKind.readerExtension, forKey: .kind)
            try container.encode(source, forKey: .source)
            try container.encode(itemKey, forKey: .itemKey)
            try container.encodeIfPresent(legacyStableKey, forKey: .legacyStableKey)
        case .aidoku(let sourceId, let mangaKey):
            try container.encode(RouteKind.aidoku, forKey: .kind)
            try container.encode(sourceId, forKey: .sourceId)
            try container.encode(mangaKey, forKey: .mangaKey)
        }
    }

    var stableKey: String {
        switch self {
        case .legacyModule(let moduleUUID, let contentParams, _):
            return "module:\(moduleUUID):\(contentParams)"
        case .readerExtension(let source, let itemKey, let legacyStableKey):
            if let legacyStableKey, Self.isValidLegacyStableKey(legacyStableKey) {
                return legacyStableKey
            }
            return "readerExtension:\(source.rawValue):\(itemKey)"
        case .aidoku(let sourceId, let mangaKey):
            return "aidoku:\(sourceId):\(mangaKey)"
        }
    }

    var stableNegativeId: Int {
        let hash = stableKey.utf8.reduce(into: 5381) { value, byte in
            value = ((value &<< 5) &+ value) &+ Int(byte)
        }
        return hash < 0 ? hash : -hash - 1
    }

    var readerExtensionSourceID: ReaderExtensionSourceID? {
        guard case .readerExtension(let source, _, _) = self else { return nil }
        return source
    }

    private static func isValidLegacyStableKey(_ value: String) -> Bool {
        value.hasPrefix("aidoku:")
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= 32 * 1_024
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

}
#endif
