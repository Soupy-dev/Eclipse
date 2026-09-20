import CryptoKit
import CoreFoundation
import Foundation

enum MangayomiMediaPreferencePolicy {
    static let maximumBytes = 1_024 * 1_024

    static func validatedData(_ data: Data) throws -> Data {
        guard data.count <= maximumBytes,
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
              raw.count <= 128 else { throw MangayomiMediaError.invalidData }
        var normalized: [String: [String: Any]] = [:]
        for (sourceKey, values) in raw {
            guard let sourceID = UUID(uuidString: sourceKey),
                  normalized[sourceID.uuidString] == nil,
                  values.count <= 128 else { throw MangayomiMediaError.invalidData }
            for (key, value) in values {
                guard !key.isEmpty, key.utf8.count <= 256 else { throw MangayomiMediaError.invalidData }
                if let list = value as? [Any] {
                    guard list.count <= 128, list.allSatisfy(validScalar) else { throw MangayomiMediaError.invalidData }
                } else {
                    guard validScalar(value) else { throw MangayomiMediaError.invalidData }
                }
            }
            normalized[sourceID.uuidString] = values
        }
        let result = try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
        guard result.count <= maximumBytes else { throw MangayomiMediaError.invalidData }
        return result
    }

    private static func validScalar(_ value: Any) -> Bool {
        if let string = value as? String { return string.utf8.count <= 8_192 }
        if let number = value as? NSNumber { return number.doubleValue.isFinite }
        return false
    }
}

struct MangayomiMediaSource: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let repositoryURL: String
    let extensionID: Int64
    let name: String
    let baseURL: String
    let apiURL: String
    let language: String
    let version: String
    let scriptURL: String
    let iconURL: String
    let scriptLanguage: Int
    let isNSFW: Bool
    let metadataJSON: String
    var enabled: Bool
    var scriptDigest: String?

    var sourceID: String { "service:\(id.uuidString)" }

    var service: Service {
        Service(
            id: id,
            metadata: ServiceMetadata(
                sourceName: name,
                author: .init(name: "Mangayomi", icon: ""),
                iconUrl: iconURL,
                version: version,
                language: language,
                baseUrl: baseURL,
                streamType: "HLS",
                quality: "Auto",
                searchBaseUrl: baseURL,
                scriptUrl: scriptURL,
                softsub: true,
                multiStream: true,
                multiSubs: true,
                type: "anime",
                novel: false,
                settings: false
            ),
            jsScript: "",
            url: repositoryURL,
            isActive: enabled,
            sortIndex: Int64.max,
            mangayomiSource: self
        )
    }

    static func stableID(repositoryURL: String, extensionID: Int64) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("mangayomi-media\u{0}\(repositoryURL)\u{0}\(extensionID)".utf8)))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
            (bytes[6] & 15) | 80, bytes[7], (bytes[8] & 63) | 128,
            bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

struct MangayomiMediaRepository: Codable, Identifiable, Hashable, Sendable {
    var id: String { url }
    let url: String
    var sources: [MangayomiMediaSource]
}

struct MangayomiMediaState: Codable, Equatable {
    var version = 1
    var repositories: [MangayomiMediaRepository] = []
    var installed: [MangayomiMediaSource] = []

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8 * 1_024 * 1_024 else { throw MangayomiMediaError.invalidData }
        let state = try JSONDecoder().decode(Self.self, from: data)
        guard state.version == 1,
              state.repositories.count <= 40,
              state.installed.count <= 1_000,
              Set(state.repositories.map(\.id)).count == state.repositories.count,
              Set(state.installed.map(\.id)).count == state.installed.count else {
            throw MangayomiMediaError.invalidData
        }
        for repository in state.repositories {
            guard MangayomiMediaRepositoryParser.validURL(repository.url) != nil,
                  repository.sources.count <= 2_000,
                  Set(repository.sources.map(\.id)).count == repository.sources.count,
                  repository.sources.allSatisfy({ $0.repositoryURL == repository.url }) else {
                throw MangayomiMediaError.invalidData
            }
        }
        for source in state.installed + state.repositories.flatMap(\.sources) {
            guard source.id == MangayomiMediaSource.stableID(repositoryURL: source.repositoryURL, extensionID: source.extensionID),
                  MangayomiMediaRepositoryParser.validURL(source.repositoryURL) != nil,
                  MangayomiMediaRepositoryParser.validURL(source.scriptURL) != nil,
                  MangayomiMediaRepositoryParser.validURL(source.baseURL) != nil,
                  [0, 1].contains(source.scriptLanguage),
                  !source.name.isEmpty, source.name.utf8.count <= 256,
                  source.language.utf8.count <= 128, source.version.utf8.count <= 128,
                  source.apiURL.isEmpty || MangayomiMediaRepositoryParser.validURL(source.apiURL) != nil,
                  source.iconURL.isEmpty || MangayomiMediaRepositoryParser.validURL(source.iconURL) != nil,
                  source.metadataJSON.utf8.count <= 32 * 1_024,
                  (try? JSONSerialization.jsonObject(with: Data(source.metadataJSON.utf8))) is [String: Any],
                  source.scriptDigest.map({ $0.count == 64 && $0.allSatisfy({ $0.isHexDigit }) }) ?? true else {
                throw MangayomiMediaError.invalidData
            }
        }
        return state
    }
}

struct MangayomiMediaLocalSelectionSnapshot {
    static let keys: Set<String> = [
        "servicesAutoModeSourceIds", "servicesAutoModeSourceOrderIds", "servicesExtraRulesSourceIds"
    ]

    private let store: UserDefaults
    private let original: [String: Any]
    let sourceIDs: Set<String>?

    init(store: UserDefaults) {
        self.store = store
        original = Self.keys.reduce(into: [:]) { values, key in
            if let value = store.object(forKey: key) { values[key] = value }
        }
        if let raw = store.object(forKey: "mangayomiMedia.state.v1") {
            if let data = raw as? Data, let state = try? MangayomiMediaState.decode(data) {
                sourceIDs = Set(state.installed.map(\.sourceID))
            } else {
                sourceIDs = nil
            }
        } else {
            sourceIDs = []
        }
    }

    func cloudValue(_ value: Any, forKey key: String, preservesAbsentSelection: Bool = false) -> Any? {
        guard Self.keys.contains(key) else { return value }
        guard let sourceIDs else { return nil }
        guard let values = value as? [String] else { return value }
        let shared = values.filter { !sourceIDs.contains($0) }
        if preservesAbsentSelection, key != "servicesExtraRulesSourceIds",
           !sourceIDs.isEmpty, shared.isEmpty { return nil }
        return shared
    }

    func cloudSettings(_ settings: [String: Data]) -> [String: Data] {
        var result = settings
        for key in Self.keys {
            guard let data = settings[key],
                  let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let original = value as? [String],
                  let projected = cloudValue(original, forKey: key) as? [String],
                  projected != original,
                  let encoded = try? PropertyListSerialization.data(fromPropertyList: projected, format: .binary, options: 0) else { continue }
            result[key] = encoded
        }
        return result
    }

    func restore() {
        guard let sourceIDs else {
            for key in Self.keys {
                if let value = original[key] { store.set(value, forKey: key) }
                else { store.removeObject(forKey: key) }
            }
            return
        }
        guard !sourceIDs.isEmpty else { return }
        let orderKey = "servicesAutoModeSourceOrderIds"
        let currentOrder = original[orderKey] as? [String] ?? []
        let incomingOrder = store.stringArray(forKey: orderKey) ?? []
        for key in Self.keys.sorted() {
            let current = original[key] as? [String] ?? []
            let incoming = store.stringArray(forKey: key) ?? []
            if key == "servicesExtraRulesSourceIds", store.object(forKey: key) == nil { continue }
            var seen = Set<String>()
            var restored: [String]
            if key == orderKey {
                var remaining = incoming.filter { !sourceIDs.contains($0) }.makeIterator()
                restored = currentOrder.compactMap { value in
                    let next = sourceIDs.contains(value) ? value : remaining.next()
                    guard let next, seen.insert(next).inserted else { return nil }
                    return next
                }
                while let next = remaining.next() {
                    if seen.insert(next).inserted { restored.append(next) }
                }
            } else {
                restored = incoming.filter { !sourceIDs.contains($0) && seen.insert($0).inserted }
                let currentValues = key == "servicesExtraRulesSourceIds" && original[key] == nil
                    ? Array(sourceIDs).sorted() : current
                restored.append(contentsOf: currentValues.filter {
                    sourceIDs.contains($0) && seen.insert($0).inserted
                })
            }
            if restored.isEmpty, original[key] == nil, store.object(forKey: key) == nil { continue }
            store.set(restored, forKey: key)
        }
    }
}

enum MangayomiMediaError: LocalizedError {
    case invalidData
    case unavailable
    case stale
    case administrativeAccess
    case network(Int)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .invalidData: return "The Mangayomi data is invalid or exceeds Eclipse's limits."
        case .unavailable: return "This Mangayomi source needs to be installed or repaired."
        case .stale: return "The profile or source changed. Please try again."
        case .administrativeAccess: return "Source administration is unavailable in a kids profile."
        case .network(let status): return "The source request failed with HTTP \(status)."
        case .runtime(let message): return message
        }
    }
}

enum MangayomiMediaRepositoryParser {
    static func validURL(_ value: String) -> URL? {
        guard value.utf8.count <= 8 * 1_024,
              let url = try? SkyStreamRemoteURLPolicy.shared.validateSyntactic(
                value, purpose: .nuvioRequest
              ).url,
              url.fragment == nil else { return nil }
        return url
    }

    private static func exactInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.decimalValue == Decimal(number.int64Value) else { return nil }
        return number.int64Value
    }

    static func parse(_ data: Data, repositoryURL: String) throws -> [MangayomiMediaSource] {
        guard data.count <= 4 * 1_024 * 1_024,
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.count <= 2_000 else { throw MangayomiMediaError.invalidData }
        var result: [MangayomiMediaSource] = []
        var identifiers = Set<UUID>()
        for row in rows {
            guard let itemType = exactInteger(row["itemType"]) else { throw MangayomiMediaError.invalidData }
            guard itemType == 1 else { continue }
            guard let extensionID = exactInteger(row["id"]),
                  let name = row["name"] as? String, !name.isEmpty, name.utf8.count <= 256,
                  let baseURL = row["baseUrl"] as? String, validURL(baseURL) != nil,
                  let scriptURL = row["sourceCodeUrl"] as? String, validURL(scriptURL) != nil,
                  let rawScriptLanguage = exactInteger(row["sourceCodeLanguage"]),
                  let scriptLanguage = Int(exactly: rawScriptLanguage),
                  [0, 1].contains(scriptLanguage) else { throw MangayomiMediaError.invalidData }
            let id = MangayomiMediaSource.stableID(repositoryURL: repositoryURL, extensionID: extensionID)
            guard identifiers.insert(id).inserted else { throw MangayomiMediaError.invalidData }
            let metadata = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            guard metadata.count <= 32 * 1_024 else { throw MangayomiMediaError.invalidData }
            result.append(MangayomiMediaSource(
                id: id,
                repositoryURL: repositoryURL,
                extensionID: extensionID,
                name: name,
                baseURL: baseURL,
                apiURL: row["apiUrl"] as? String ?? "",
                language: row["lang"] as? String ?? "all",
                version: row["version"] as? String ?? (row["version"] as? NSNumber)?.stringValue ?? "0",
                scriptURL: scriptURL,
                iconURL: row["iconUrl"] as? String ?? "",
                scriptLanguage: scriptLanguage,
                isNSFW: row["isNsfw"] as? Bool ?? false,
                metadataJSON: String(decoding: metadata, as: UTF8.self),
                enabled: true,
                scriptDigest: nil
            ))
        }
        return result
    }
}

struct MangayomiMediaKey: Codable, Hashable {
    let source: UUID
    let kind: String
    let value: String
    var number: String?
    var audio: String?

    var encoded: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard value.utf8.count <= 4_096,
              let data = try? encoder.encode(self), data.count <= 6_000 else { return nil }
        return "mangayomi:" + data.base64EncodedString()
    }

    static func decode(_ text: String, source: UUID, kind: String) throws -> Self {
        guard text.hasPrefix("mangayomi:"), text.utf8.count <= 8_192,
              let data = Data(base64Encoded: String(text.dropFirst(10))),
              let key = try? JSONDecoder().decode(Self.self, from: data),
              key.source == source, key.kind == kind,
              key.value.utf8.count <= 4_096 else { throw MangayomiMediaError.invalidData }
        return key
    }
}
