import Foundation
import CryptoKit

// MARK: - Forward-compatible JSON

/// A lossless-enough JSON value used to retain fields introduced by newer
/// SkyStream repository, manifest, and preference schema revisions.
public indirect enum SkyStreamJSONValue: Codable, Sendable, Hashable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([SkyStreamJSONValue])
    case object([String: SkyStreamJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SkyStreamJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: SkyStreamJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .boolean(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

enum SkyStreamJSONEnvelopeError: Error, Sendable, Equatable {
    case empty
    case malformedStructure
    case excessiveDepth
    case excessiveTokens
    case excessiveContainerValues
    case excessiveTokenBytes
}

/// A non-allocating-in-shape preflight for untrusted JSON. `JSONDecoder` still owns complete
/// syntax/schema validation; this scanner runs first so a small remote document cannot make it
/// recursively materialize hundreds of thousands of enum/container nodes before field limits run.
enum SkyStreamJSONEnvelopeValidator {
    struct Limits: Sendable, Hashable {
        let maximumDepth: Int
        let maximumTokens: Int
        let maximumValuesPerContainer: Int
        let maximumStringBytes: Int
        let maximumScalarTokenBytes: Int

        static let repository = Limits(
            maximumDepth: 32,
            maximumTokens: 150_000,
            maximumValuesPerContainer: 4_096,
            maximumStringBytes: 64 * 1_024,
            maximumScalarTokenBytes: 128
        )
        static let packageManifest = Limits(
            maximumDepth: 24,
            maximumTokens: 50_000,
            maximumValuesPerContainer: 2_048,
            maximumStringBytes: 64 * 1_024,
            maximumScalarTokenBytes: 128
        )
        static let runtimePreference = Limits(
            maximumDepth: 12,
            maximumTokens: 8_192,
            maximumValuesPerContainer: 1_024,
            maximumStringBytes: 64 * 1_024,
            maximumScalarTokenBytes: 128
        )
    }

    private struct Frame {
        let closingByte: UInt8
        var valueCount: Int
    }

    static func validate(_ data: Data, limits: Limits) throws {
        guard !data.isEmpty else { throw SkyStreamJSONEnvelopeError.empty }
        let bytes = [UInt8](data)
        var frames: [Frame] = []
        frames.reserveCapacity(min(limits.maximumDepth, 32))
        var tokenCount = 0
        var index = 0

        func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d
        }
        func isDelimiter(_ byte: UInt8) -> Bool {
            isWhitespace(byte) || byte == 0x2c || byte == 0x3a
                || byte == 0x5d || byte == 0x7d
        }
        func isHex(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte)
                || (0x41...0x46).contains(byte)
                || (0x61...0x66).contains(byte)
        }
        func recordToken() throws {
            tokenCount += 1
            guard tokenCount <= limits.maximumTokens else {
                throw SkyStreamJSONEnvelopeError.excessiveTokens
            }
            guard !frames.isEmpty else { return }
            frames[frames.count - 1].valueCount += 1
            guard frames[frames.count - 1].valueCount <= limits.maximumValuesPerContainer else {
                throw SkyStreamJSONEnvelopeError.excessiveContainerValues
            }
        }

        while index < bytes.count {
            let byte = bytes[index]
            if isWhitespace(byte) || byte == 0x2c || byte == 0x3a {
                index += 1
                continue
            }

            switch byte {
            case 0x7b, 0x5b: // { [
                try recordToken()
                guard frames.count < limits.maximumDepth else {
                    throw SkyStreamJSONEnvelopeError.excessiveDepth
                }
                frames.append(Frame(
                    closingByte: byte == 0x7b ? 0x7d : 0x5d,
                    valueCount: 0
                ))
                index += 1

            case 0x7d, 0x5d: // } ]
                guard frames.last?.closingByte == byte else {
                    throw SkyStreamJSONEnvelopeError.malformedStructure
                }
                frames.removeLast()
                index += 1

            case 0x22: // quoted string/key
                try recordToken()
                index += 1
                var rawByteCount = 0
                var didClose = false
                while index < bytes.count {
                    let current = bytes[index]
                    if current == 0x22 {
                        didClose = true
                        index += 1
                        break
                    }
                    guard current >= 0x20 else {
                        throw SkyStreamJSONEnvelopeError.malformedStructure
                    }
                    if current == 0x5c { // escape
                        index += 1
                        guard index < bytes.count else {
                            throw SkyStreamJSONEnvelopeError.malformedStructure
                        }
                        if bytes[index] == 0x75 {
                            guard index + 4 < bytes.count,
                                  bytes[(index + 1)...(index + 4)].allSatisfy(isHex) else {
                                throw SkyStreamJSONEnvelopeError.malformedStructure
                            }
                            rawByteCount += 5
                            index += 5
                        } else {
                            rawByteCount += 1
                            index += 1
                        }
                    } else {
                        rawByteCount += 1
                        index += 1
                    }
                    guard rawByteCount <= limits.maximumStringBytes else {
                        throw SkyStreamJSONEnvelopeError.excessiveTokenBytes
                    }
                }
                guard didClose else { throw SkyStreamJSONEnvelopeError.malformedStructure }

            default:
                try recordToken()
                let start = index
                while index < bytes.count, !isDelimiter(bytes[index]) {
                    // Container openers may not be embedded in a scalar token. Let the decoder
                    // validate exact literal/number grammar after this cheap structural check.
                    guard bytes[index] != 0x7b, bytes[index] != 0x5b,
                          bytes[index] != 0x22 else {
                        throw SkyStreamJSONEnvelopeError.malformedStructure
                    }
                    index += 1
                }
                guard index > start,
                      index - start <= limits.maximumScalarTokenBytes else {
                    throw SkyStreamJSONEnvelopeError.excessiveTokenBytes
                }
            }
        }

        guard frames.isEmpty else { throw SkyStreamJSONEnvelopeError.malformedStructure }
    }
}

enum SkyStreamJSONValueShapePolicy {
    struct Limits: Sendable, Hashable {
        let maximumDepth: Int
        let maximumNodes: Int
        let maximumChildrenPerContainer: Int
        let maximumStringBytes: Int
        let maximumAggregateStringBytes: Int

        static let runtimePreference = Limits(
            maximumDepth: 12,
            maximumNodes: 8_192,
            maximumChildrenPerContainer: 1_024,
            maximumStringBytes: 64 * 1_024,
            maximumAggregateStringBytes: 256 * 1_024
        )
    }

    static func validate(_ value: SkyStreamJSONValue, limits: Limits) throws {
        var stack: [(value: SkyStreamJSONValue, depth: Int)] = [(value, 1)]
        var nodeCount = 0
        var stringBytes = 0
        while let item = stack.popLast() {
            nodeCount += 1
            guard nodeCount <= limits.maximumNodes,
                  item.depth <= limits.maximumDepth else {
                throw SkyStreamJSONEnvelopeError.excessiveTokens
            }
            switch item.value {
            case .null, .boolean, .integer:
                break
            case .number(let number):
                guard number.isFinite else {
                    throw SkyStreamJSONEnvelopeError.malformedStructure
                }
            case .string(let string):
                guard string.utf8.count <= limits.maximumStringBytes else {
                    throw SkyStreamJSONEnvelopeError.excessiveTokenBytes
                }
                stringBytes += string.utf8.count
            case .array(let values):
                guard values.count <= limits.maximumChildrenPerContainer else {
                    throw SkyStreamJSONEnvelopeError.excessiveContainerValues
                }
                stack.append(contentsOf: values.map { ($0, item.depth + 1) })
            case .object(let object):
                guard object.count <= limits.maximumChildrenPerContainer else {
                    throw SkyStreamJSONEnvelopeError.excessiveContainerValues
                }
                for (key, child) in object {
                    guard !key.isEmpty, key.utf8.count <= 256 else {
                        throw SkyStreamJSONEnvelopeError.excessiveTokenBytes
                    }
                    stringBytes += key.utf8.count
                    stack.append((child, item.depth + 1))
                }
            }
            guard stringBytes <= limits.maximumAggregateStringBytes else {
                throw SkyStreamJSONEnvelopeError.excessiveTokenBytes
            }
        }
    }
}

/// Forward-compatible fields remain round-trippable, but they are metadata—not a second unbounded
/// object graph. The iterative walk avoids adding native recursion on top of decoded plugin data.
enum SkyStreamAdditionalFieldPolicy {
    static func validate(_ fields: [String: SkyStreamJSONValue]) throws {
        guard fields.count <= 32 else { throw SkyStreamJSONEnvelopeError.excessiveContainerValues }
        var stack = fields.map { (key: Optional($0.key), value: $0.value, depth: 1) }
        var nodeCount = 0
        var totalUTF8Bytes = 0

        while let item = stack.popLast() {
            nodeCount += 1
            guard nodeCount <= 256, item.depth <= 4 else {
                throw SkyStreamJSONEnvelopeError.excessiveTokens
            }
            if let key = item.key {
                guard !key.isEmpty, key.utf8.count <= 256 else {
                    throw SkyStreamJSONEnvelopeError.excessiveTokenBytes
                }
                totalUTF8Bytes += key.utf8.count
            }
            switch item.value {
            case .null, .boolean, .integer:
                break
            case .number(let value):
                guard value.isFinite else { throw SkyStreamJSONEnvelopeError.malformedStructure }
            case .string(let value):
                guard value.utf8.count <= 16 * 1_024 else {
                    throw SkyStreamJSONEnvelopeError.excessiveTokenBytes
                }
                totalUTF8Bytes += value.utf8.count
            case .array(let values):
                guard values.count <= 64 else {
                    throw SkyStreamJSONEnvelopeError.excessiveContainerValues
                }
                stack.append(contentsOf: values.map { (nil, $0, item.depth + 1) })
            case .object(let object):
                guard object.count <= 64 else {
                    throw SkyStreamJSONEnvelopeError.excessiveContainerValues
                }
                stack.append(contentsOf: object.map {
                    (Optional($0.key), $0.value, item.depth + 1)
                })
            }
            guard totalUTF8Bytes <= 64 * 1_024 else {
                throw SkyStreamJSONEnvelopeError.excessiveTokenBytes
            }
        }
    }
}

private struct SkyStreamDynamicCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func skyStreamAdditionalFields(
    from decoder: Decoder,
    excluding knownKeys: Set<String>
) throws -> [String: SkyStreamJSONValue] {
    let container = try decoder.container(keyedBy: SkyStreamDynamicCodingKey.self)
    var result: [String: SkyStreamJSONValue] = [:]
    for key in container.allKeys where !knownKeys.contains(key.stringValue) {
        result[key.stringValue] = try container.decode(SkyStreamJSONValue.self, forKey: key)
    }
    try SkyStreamAdditionalFieldPolicy.validate(result)
    return result
}

private func skyStreamEncodeAdditionalFields(
    _ fields: [String: SkyStreamJSONValue],
    excluding knownKeys: Set<String>,
    to encoder: Encoder
) throws {
    try SkyStreamAdditionalFieldPolicy.validate(fields)
    var container = encoder.container(keyedBy: SkyStreamDynamicCodingKey.self)
    for (name, value) in fields where !knownKeys.contains(name) {
        try container.encode(value, forKey: SkyStreamDynamicCodingKey(stringValue: name))
    }
}

/// SkyStream's app accepts either a list or a single string for its historical
/// language/category aliases. Keep that compatibility at the manifest boundary
/// while continuing to expose one canonical `[String]` shape everywhere else.
private func skyStreamDecodeStringList<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    keys: [Key]
) -> [String] {
    for key in keys where container.contains(key) {
        if let values = try? container.decode([String].self, forKey: key) {
            return values
        }
        if let value = try? container.decode(String.self, forKey: key),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [value]
        }
    }
    return []
}

/// Retain decodable map entries and ignore legacy scalars or malformed maps,
/// matching SkyStream's tolerant object-list parsing. Consuming a rejected
/// value as `SkyStreamJSONValue` advances the unkeyed container while the
/// surrounding envelope validator continues to enforce size/depth limits.
private func skyStreamDecodeObjectList<Element: Decodable, Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    key: Key
) -> [Element]? {
    guard container.contains(key),
          (try? container.decodeNil(forKey: key)) != true,
          var values = try? container.nestedUnkeyedContainer(forKey: key) else {
        return nil
    }

    var result: [Element] = []
    while !values.isAtEnd {
        if let value = try? values.decode(Element.self) {
            result.append(value)
        } else if (try? values.decode(SkyStreamJSONValue.self)) == nil {
            return result
        }
    }
    return result
}

// MARK: - Stable identifiers

public enum SkyStreamStableID {
    public static let prefix = "skystream:"
    private static let encodedProviderPrefix = "encoded-"
    private static let maximumProviderIDBytes = 256

    public enum ValidationError: Error, Sendable, Equatable {
        case invalidPackageName(String)
        case invalidProviderID(String)
    }

    /// Official package IDs require at least five characters. Eclipse also
    /// bounds every stable-ID component to 128 ASCII characters and disallows
    /// punctuation at either end and ambiguous empty (`..`) segments.
    public static func isValidPackageName(_ packageName: String) -> Bool {
        isValidComponent(packageName, minimumLength: 5)
            && !packageName.utf8.contains(where: { (0x41...0x5A).contains($0) })
    }

    public static func isValidProviderID(_ providerID: String) -> Bool {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              providerID.utf8.count <= maximumProviderIDBytes,
              !providerID.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      || CharacterSet.illegalCharacters.contains($0)
                      || isBidirectionalFormattingControl($0.value)
              }) else {
            return false
        }
        return true
    }

    public static func validatedRootProvider(packageName: String) throws -> String {
        guard isValidPackageName(packageName) else {
            throw ValidationError.invalidPackageName(packageName)
        }
        return rootProvider(packageName: packageName)
    }

    public static func validatedProvider(packageName: String, providerID: String) throws -> String {
        guard isValidPackageName(packageName) else {
            throw ValidationError.invalidPackageName(packageName)
        }
        guard isValidProviderID(providerID) else {
            throw ValidationError.invalidProviderID(providerID)
        }
        return provider(packageName: packageName, providerID: providerID)
    }

    public static func plugin(_ packageName: String) -> String {
        packageName
    }

    public static func validatedPlugin(_ packageName: String) throws -> String {
        guard isValidPackageName(packageName) else {
            throw ValidationError.invalidPackageName(packageName)
        }
        return packageName
    }

    public static func rootProvider(packageName: String) -> String {
        prefix + packageName
    }

    public static func provider(packageName: String, providerID: String) -> String {
        rootProvider(packageName: packageName) + "::" + stableProviderComponent(providerID)
    }

    public static func sourceID(packageName: String, providerID: String?) -> String {
        guard let providerID, !providerID.isEmpty else {
            return rootProvider(packageName: packageName)
        }
        return provider(packageName: packageName, providerID: providerID)
    }

    public static func validatedSourceID(packageName: String, providerID: String?) throws -> String {
        guard let providerID, !providerID.isEmpty else {
            return try validatedRootProvider(packageName: packageName)
        }
        return try validatedProvider(packageName: packageName, providerID: providerID)
    }

    private static func isValidComponent(_ value: String, minimumLength: Int) -> Bool {
        let bytes = Array(value.utf8)
        guard (minimumLength...128).contains(bytes.count),
              !value.contains(".."),
              let first = bytes.first,
              let last = bytes.last,
              isASCIIAlphanumeric(first),
              isASCIIAlphanumeric(last) else {
            return false
        }
        return bytes.allSatisfy {
            isASCIIAlphanumeric($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }
    }

    /// SkyStream treats provider IDs as opaque non-empty strings and exposes the
    /// exact value to JavaScript as `manifest.providerId`. Eclipse uses a separate
    /// delimiter-safe component for persistence and source ordering. Keep legacy
    /// IDs unchanged, but hash everything else (and reserve the hash prefix) so
    /// spaces, Unicode, slashes, or `::` can never alter the stable-ID structure.
    private static func stableProviderComponent(_ providerID: String) -> String {
        if isValidComponent(providerID, minimumLength: 1),
           !providerID.hasPrefix(encodedProviderPrefix) {
            return providerID
        }
        let digest = SHA256.hash(data: Data(providerID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return encodedProviderPrefix + digest
    }

    private static func isBidirectionalFormattingControl(_ value: UInt32) -> Bool {
        value == 0x061C
            || value == 0x200E
            || value == 0x200F
            || (0x202A...0x202E).contains(value)
            || (0x2066...0x2069).contains(value)
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
    }
}

// MARK: - Repository and package manifests

public struct SkyStreamRepositoryManifest: Codable, Sendable, Hashable {
    public var name: String
    public var packageName: String
    public var description: String
    public var manifestVersion: Int
    /// Entries may be absolute or relative to the repository document URL.
    public var pluginLists: [String]
    /// Repository-of-repositories entries used by SkyStream megarepos.
    public var includedRepositories: [String]
    /// Enterprise/V2 repositories may place spread plugin entries directly in repo.json.
    public var plugins: [SkyStreamPluginListEntry]
    public var authors: [String]?
    public var iconURL: String?
    public var websiteURL: String?
    public var additionalFields: [String: SkyStreamJSONValue]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, packageName, id, description, manifestVersion, pluginLists, authors
        case includedRepositories = "repos"
        case plugins
        case iconURL = "iconUrl"
        case websiteURL = "websiteUrl"
    }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    /// SkyStream treats positive repository manifest versions as
    /// forward-compatible metadata. Executable package ABI versions are
    /// validated separately when a `.sky` archive is installed.
    public static func isSupportedManifestVersion(_ version: Int) -> Bool {
        version > 0
    }

    public init(
        name: String,
        packageName: String,
        description: String = "",
        manifestVersion: Int = 1,
        pluginLists: [String] = [],
        includedRepositories: [String] = [],
        plugins: [SkyStreamPluginListEntry] = [],
        authors: [String]? = nil,
        iconURL: String? = nil,
        websiteURL: String? = nil,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.name = name
        self.packageName = packageName
        self.description = description
        self.manifestVersion = manifestVersion
        self.pluginLists = pluginLists
        self.includedRepositories = includedRepositories
        self.plugins = plugins
        self.authors = authors
        self.iconURL = iconURL
        self.websiteURL = websiteURL
        self.additionalFields = additionalFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        guard let decodedPackageName = try container.decodeIfPresent(String.self, forKey: .packageName)
                ?? container.decodeIfPresent(String.self, forKey: .id) else {
            throw DecodingError.keyNotFound(
                CodingKeys.packageName,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected packageName or id")
            )
        }
        packageName = decodedPackageName
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        manifestVersion = try container.decodeIfPresent(Int.self, forKey: .manifestVersion) ?? 1
        pluginLists = try container.decodeIfPresent([String].self, forKey: .pluginLists) ?? []
        includedRepositories = try container.decodeIfPresent(
            [String].self,
            forKey: .includedRepositories
        ) ?? []
        plugins = try container.decodeIfPresent(
            [SkyStreamPluginListEntry].self,
            forKey: .plugins
        ) ?? []
        authors = try container.decodeIfPresent([String].self, forKey: .authors)
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
        websiteURL = try container.decodeIfPresent(String.self, forKey: .websiteURL)
        additionalFields = try skyStreamAdditionalFields(from: decoder, excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        try skyStreamEncodeAdditionalFields(additionalFields, excluding: Self.knownKeys, to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(packageName, forKey: .packageName)
        try container.encode(description, forKey: .description)
        try container.encode(manifestVersion, forKey: .manifestVersion)
        if !pluginLists.isEmpty { try container.encode(pluginLists, forKey: .pluginLists) }
        if !includedRepositories.isEmpty {
            try container.encode(includedRepositories, forKey: .includedRepositories)
        }
        if !plugins.isEmpty { try container.encode(plugins, forKey: .plugins) }
        try container.encodeIfPresent(authors, forKey: .authors)
        try container.encodeIfPresent(iconURL, forKey: .iconURL)
        try container.encodeIfPresent(websiteURL, forKey: .websiteURL)
    }
}

public struct SkyStreamPluginDomain: Codable, Sendable, Hashable {
    public var name: String
    public var url: String
    public var additionalFields: [String: SkyStreamJSONValue]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, url
    }

    public init(
        name: String,
        url: String,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.name = name
        self.url = url
        self.additionalFields = additionalFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? url
        additionalFields = try skyStreamAdditionalFields(
            from: decoder,
            excluding: Set(CodingKeys.allCases.map(\.rawValue))
        )
    }

    public func encode(to encoder: Encoder) throws {
        let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
        try skyStreamEncodeAdditionalFields(additionalFields, excluding: knownKeys, to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
    }
}

public struct SkyStreamPluginProvider: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var baseURL: String?
    public var iconURL: String?
    public var languages: [String]?
    public var categories: [String]?
    public var additionalFields: [String: SkyStreamJSONValue]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, languages, language, lang, categories, types, tvTypes
        case baseURL = "baseUrl"
        case iconURL = "iconUrl"
    }

    public init(
        id: String,
        name: String,
        baseURL: String? = nil,
        iconURL: String? = nil,
        languages: [String]? = nil,
        categories: [String]? = nil,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.iconURL = iconURL
        self.languages = languages
        self.categories = categories
        self.additionalFields = additionalFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
        let decodedLanguages = skyStreamDecodeStringList(
            from: container,
            keys: [.languages, .language, .lang]
        )
        languages = decodedLanguages.isEmpty ? nil : decodedLanguages
        let decodedCategories = skyStreamDecodeStringList(
            from: container,
            keys: [.categories, .types, .tvTypes]
        )
        categories = decodedCategories.isEmpty ? nil : decodedCategories
        additionalFields = try skyStreamAdditionalFields(
            from: decoder,
            excluding: Set(CodingKeys.allCases.map(\.rawValue))
        )
    }

    public func encode(to encoder: Encoder) throws {
        let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
        try skyStreamEncodeAdditionalFields(additionalFields, excluding: knownKeys, to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(iconURL, forKey: .iconURL)
        try container.encodeIfPresent(languages, forKey: .languages)
        try container.encodeIfPresent(categories, forKey: .categories)
    }
}

public struct SkyStreamPluginManifest: Codable, Sendable, Hashable, Identifiable {
    public var packageName: String
    public var name: String
    public var version: Int
    public var authors: [String]
    public var baseURL: String
    public var description: String?
    public var iconURL: String?
    public var languages: [String]
    public var categories: [String]
    public var domains: [SkyStreamPluginDomain]?
    public var providers: [SkyStreamPluginProvider]?
    /// Runtime-only in the official ABI, retained when encountered for round trips.
    public var providerID: String?
    /// Optional future package format markers. Version 1 is currently supported.
    public var manifestVersion: Int?
    public var apiVersion: Int?
    public var additionalFields: [String: SkyStreamJSONValue]

    public var id: String { packageName }
    public var rootSourceID: String { SkyStreamStableID.rootProvider(packageName: packageName) }

    public var sourceIDs: [String] {
        guard let providers, !providers.isEmpty else { return [rootSourceID] }
        return providers.map { SkyStreamStableID.provider(packageName: packageName, providerID: $0.id) }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case packageName, name, version, authors, description
        case languages, language, lang, categories, types, tvTypes
        case domains, providers, manifestVersion, apiVersion
        case baseURL = "baseUrl"
        case iconURL = "iconUrl"
        case providerID = "providerId"
    }

    public init(
        packageName: String,
        name: String,
        version: Int,
        authors: [String],
        baseURL: String,
        description: String? = nil,
        iconURL: String? = nil,
        languages: [String],
        categories: [String],
        domains: [SkyStreamPluginDomain]? = nil,
        providers: [SkyStreamPluginProvider]? = nil,
        providerID: String? = nil,
        manifestVersion: Int? = nil,
        apiVersion: Int? = nil,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.packageName = packageName
        self.name = name
        self.version = version
        self.authors = authors
        self.baseURL = baseURL
        self.description = description
        self.iconURL = iconURL
        self.languages = languages
        self.categories = categories
        self.domains = domains
        self.providers = providers
        self.providerID = providerID
        self.manifestVersion = manifestVersion
        self.apiVersion = apiVersion
        self.additionalFields = additionalFields
    }

    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, additionalKnownKeys: [])
    }

    fileprivate init(
        from decoder: Decoder,
        additionalKnownKeys: Set<String>
    ) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packageName = try container.decode(String.self, forKey: .packageName)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown Plugin"
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        authors = try container.decodeIfPresent([String].self, forKey: .authors) ?? []
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description)
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
        languages = skyStreamDecodeStringList(
            from: container,
            keys: [.languages, .language, .lang]
        )
        categories = skyStreamDecodeStringList(
            from: container,
            keys: [.categories, .types, .tvTypes]
        )
        // SkyStream uses `whereType<Map>()` for these lists. Published catalogs
        // can contain legacy scalar entries, which the official app ignores
        // instead of rejecting the plugin or its entire repository.
        domains = skyStreamDecodeObjectList(from: container, key: .domains)
        providers = skyStreamDecodeObjectList(from: container, key: .providers)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        manifestVersion = try container.decodeIfPresent(Int.self, forKey: .manifestVersion)
        apiVersion = try container.decodeIfPresent(Int.self, forKey: .apiVersion)
        additionalFields = try skyStreamAdditionalFields(
            from: decoder,
            excluding: Set(CodingKeys.allCases.map(\.rawValue)).union(additionalKnownKeys)
        )
    }

    public func encode(to encoder: Encoder) throws {
        let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
        try skyStreamEncodeAdditionalFields(additionalFields, excluding: knownKeys, to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(packageName, forKey: .packageName)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(authors, forKey: .authors)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(iconURL, forKey: .iconURL)
        try container.encode(languages, forKey: .languages)
        try container.encode(categories, forKey: .categories)
        try container.encodeIfPresent(domains, forKey: .domains)
        try container.encodeIfPresent(providers, forKey: .providers)
        try container.encodeIfPresent(providerID, forKey: .providerID)
        try container.encodeIfPresent(manifestVersion, forKey: .manifestVersion)
        try container.encodeIfPresent(apiVersion, forKey: .apiVersion)
    }
}

/// An entry from the official `plugins.json` raw array. SkyStream's CLI spreads
/// the plugin manifest into the entry and adds `url`.
public struct SkyStreamPluginListEntry: Codable, Sendable, Hashable, Identifiable {
    public var manifest: SkyStreamPluginManifest
    public var url: String
    public var sha256: String?
    public var checksum: String?
    public var archiveSHA256: String?
    public var scriptSHA256: String?
    public var additionalFields: [String: SkyStreamJSONValue]

    public var id: String { manifest.packageName }
    public var expectedArchiveSHA256: String? { archiveSHA256 ?? sha256 ?? checksum }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case url, sha256, checksum
        case archiveSHA256 = "archiveSha256"
        case scriptSHA256 = "scriptSha256"
    }

    public init(
        manifest: SkyStreamPluginManifest,
        url: String,
        sha256: String? = nil,
        checksum: String? = nil,
        archiveSHA256: String? = nil,
        scriptSHA256: String? = nil,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.manifest = manifest
        self.url = url
        self.sha256 = sha256
        self.checksum = checksum
        self.archiveSHA256 = archiveSHA256
        self.scriptSHA256 = scriptSHA256
        self.additionalFields = additionalFields
    }

    public init(from decoder: Decoder) throws {
        let entryKnownKeys = Set(CodingKeys.allCases.map(\.rawValue))
        var decodedManifest = try SkyStreamPluginManifest(
            from: decoder,
            additionalKnownKeys: entryKnownKeys
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        checksum = try container.decodeIfPresent(String.self, forKey: .checksum)
        archiveSHA256 = try container.decodeIfPresent(String.self, forKey: .archiveSHA256)
        scriptSHA256 = try container.decodeIfPresent(String.self, forKey: .scriptSHA256)

        // A spread plugin-list object cannot distinguish a future manifest
        // field from a future catalog-entry field. Keep all such fields on the
        // embedded manifest (the source of truth) so installing from a list
        // does not discard them. The entry mirrors them for callers that treat
        // the list row as its own forward-compatible document.
        additionalFields = decodedManifest.additionalFields
        for key in CodingKeys.allCases {
            additionalFields.removeValue(forKey: key.rawValue)
            decodedManifest.additionalFields.removeValue(forKey: key.rawValue)
        }
        manifest = decodedManifest
    }

    public func encode(to encoder: Encoder) throws {
        try manifest.encode(to: encoder)
        let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
        try skyStreamEncodeAdditionalFields(additionalFields, excluding: knownKeys, to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(sha256, forKey: .sha256)
        try container.encodeIfPresent(checksum, forKey: .checksum)
        try container.encodeIfPresent(archiveSHA256, forKey: .archiveSHA256)
        try container.encodeIfPresent(scriptSHA256, forKey: .scriptSHA256)
    }
}

public struct SkyStreamPluginListDocument: Codable, Sendable, Hashable {
    public enum ContainerKind: String, Codable, Sendable, Hashable {
        case array
        case plugins
        case items
        case data
    }

    public var plugins: [SkyStreamPluginListEntry]
    public var containerKind: ContainerKind
    public var additionalFields: [String: SkyStreamJSONValue]

    public init(
        plugins: [SkyStreamPluginListEntry],
        containerKind: ContainerKind = .array,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.plugins = plugins
        self.containerKind = containerKind
        self.additionalFields = additionalFields
    }

    public init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            var entries: [SkyStreamPluginListEntry] = []
            while !unkeyed.isAtEnd {
                entries.append(try unkeyed.decode(SkyStreamPluginListEntry.self))
            }
            plugins = entries
            containerKind = .array
            additionalFields = [:]
            return
        }

        let container = try decoder.container(keyedBy: SkyStreamDynamicCodingKey.self)
        let supportedKeys: [ContainerKind] = [.plugins, .items, .data]
        let present = supportedKeys.filter {
            container.contains(SkyStreamDynamicCodingKey(stringValue: $0.rawValue))
        }
        guard present.count == 1, let selected = present.first else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected exactly one plugin list envelope key"
                )
            )
        }

        let key = SkyStreamDynamicCodingKey(stringValue: selected.rawValue)
        plugins = try container.decode([SkyStreamPluginListEntry].self, forKey: key)
        containerKind = selected
        let excluded = Set(supportedKeys.map(\.rawValue))
        additionalFields = try skyStreamAdditionalFields(from: decoder, excluding: excluded)
    }

    public func encode(to encoder: Encoder) throws {
        if containerKind == .array {
            var container = encoder.unkeyedContainer()
            for plugin in plugins {
                try container.encode(plugin)
            }
            return
        }

        let acceptedKeys = Set([ContainerKind.plugins, .items, .data].map(\.rawValue))
        try skyStreamEncodeAdditionalFields(additionalFields, excluding: acceptedKeys, to: encoder)
        var container = encoder.container(keyedBy: SkyStreamDynamicCodingKey.self)
        try container.encode(
            plugins,
            forKey: SkyStreamDynamicCodingKey(stringValue: containerKind.rawValue)
        )
    }
}

public enum SkyStreamRepositoryDocument: Codable, Sendable, Hashable {
    case repository(SkyStreamRepositoryManifest)
    case pluginList(SkyStreamPluginListDocument)

    public init(from decoder: Decoder) throws {
        let repository = try? SkyStreamRepositoryManifest(from: decoder)
        let pluginList = try? SkyStreamPluginListDocument(from: decoder)
        switch (repository, pluginList) {
        case (.some(let repository), nil):
            self = .repository(repository)
        case (nil, .some(let pluginList)):
            self = .pluginList(pluginList)
        case (.some(let repository), .some):
            // A repository with directly embedded `plugins` intentionally also
            // has the shape of a plugin-list envelope. SkyStream identifies it
            // as a repository by its required repository metadata.
            self = .repository(repository)
        case (nil, nil):
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a repository or plugin-list document"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .repository(let repository):
            try repository.encode(to: encoder)
        case .pluginList(let pluginList):
            try pluginList.encode(to: encoder)
        }
    }

    public static func decode(from data: Data, using decoder: JSONDecoder = JSONDecoder()) throws -> Self {
        try decoder.decode(Self.self, from: data)
    }
}

// MARK: - Compatibility and installed state

public enum SkyStreamCompatibilityStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case compatible = "Compatible"
    case untested = "Untested"
    case limited = "Limited"
    case incompatible = "Incompatible"
}

public struct SkyStreamCompatibilityReasonCode: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let notSmokeTested = Self(rawValue: "not_smoke_tested")
    public static let unsupportedManifestVersion = Self(rawValue: "unsupported_manifest_version")
    public static let genericCaptchaRequired = Self(rawValue: "generic_captcha_required")
    public static let unsupportedRuntimeFeature = Self(rawValue: "unsupported_runtime_feature")
    public static let liveOnly = Self(rawValue: "live_only")
    public static let drmOnly = Self(rawValue: "drm_only")
    public static let torrentOnly = Self(rawValue: "torrent_only")
    public static let invalidPackage = Self(rawValue: "invalid_package")
}

public struct SkyStreamCompatibilityReason: Codable, Sendable, Hashable {
    public var code: SkyStreamCompatibilityReasonCode
    public var message: String
    public var detail: String?
    public var field: String?
    public var additionalFields: [String: SkyStreamJSONValue]

    public init(
        code: SkyStreamCompatibilityReasonCode,
        message: String,
        detail: String? = nil,
        field: String? = nil,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.code = code
        self.message = message
        self.detail = detail
        self.field = field
        self.additionalFields = additionalFields
    }
}

public struct SkyStreamCompatibilityResult: Codable, Sendable, Hashable {
    public var status: SkyStreamCompatibilityStatus
    public var reasons: [SkyStreamCompatibilityReason]
    public var evaluatedAt: Date?
    public var evaluatorVersion: Int

    public init(
        status: SkyStreamCompatibilityStatus,
        reasons: [SkyStreamCompatibilityReason] = [],
        evaluatedAt: Date? = nil,
        evaluatorVersion: Int = 1
    ) {
        self.status = status
        self.reasons = reasons
        self.evaluatedAt = evaluatedAt
        self.evaluatorVersion = evaluatorVersion
    }

    public static let untested = SkyStreamCompatibilityResult(
        status: .untested,
        reasons: [
            SkyStreamCompatibilityReason(
                code: .notSmokeTested,
                message: "This package has not completed Eclipse compatibility testing."
            )
        ]
    )
}

public struct SkyStreamInstallProvenance: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case repository
        case directArchive
        case backup
    }

    public var kind: Kind
    public var sourceURL: String
    public var repositoryURL: String?
    public var pluginListURL: String?
    public var repositoryPackageName: String?
    public var expectedArchiveSHA256: String?
    public var pinnedAt: Date
    public var frozenAt: Date?
    public var additionalFields: [String: SkyStreamJSONValue]

    public init(
        kind: Kind,
        sourceURL: String,
        repositoryURL: String? = nil,
        pluginListURL: String? = nil,
        repositoryPackageName: String? = nil,
        expectedArchiveSHA256: String? = nil,
        pinnedAt: Date = Date(),
        frozenAt: Date? = nil,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.kind = kind
        self.sourceURL = sourceURL
        self.repositoryURL = repositoryURL
        self.pluginListURL = pluginListURL
        self.repositoryPackageName = repositoryPackageName
        self.expectedArchiveSHA256 = expectedArchiveSHA256
        self.pinnedAt = pinnedAt
        self.frozenAt = frozenAt
        self.additionalFields = additionalFields
    }
}

public struct SkyStreamProviderState: Codable, Sendable, Hashable, Identifiable {
    public var packageName: String
    public var providerID: String?
    public var isEnabled: Bool
    public var sourceOrder: Int?
    public var isAutoModeSelected: Bool
    public var isExplicitlySelectedForExtraRules: Bool?
    public var lastSeenPluginVersion: Int
    public var removedAt: Date?
    public var additionalFields: [String: SkyStreamJSONValue]

    public var id: String { SkyStreamStableID.sourceID(packageName: packageName, providerID: providerID) }

    public init(
        packageName: String,
        providerID: String? = nil,
        isEnabled: Bool = true,
        sourceOrder: Int? = nil,
        isAutoModeSelected: Bool = false,
        isExplicitlySelectedForExtraRules: Bool? = nil,
        lastSeenPluginVersion: Int,
        removedAt: Date? = nil,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.packageName = packageName
        self.providerID = providerID
        self.isEnabled = isEnabled
        self.sourceOrder = sourceOrder
        self.isAutoModeSelected = isAutoModeSelected
        self.isExplicitlySelectedForExtraRules = isExplicitlySelectedForExtraRules
        self.lastSeenPluginVersion = lastSeenPluginVersion
        self.removedAt = removedAt
        self.additionalFields = additionalFields
    }
}

public struct SkyStreamInstalledPluginState: Codable, Sendable, Hashable, Identifiable {
    public var manifest: SkyStreamPluginManifest
    public var archiveSHA256: String
    public var scriptSHA256: String
    public var payloadRelativePath: String
    public var provenance: SkyStreamInstallProvenance
    public var selectedDomainURL: String?
    public var compatibility: SkyStreamCompatibilityResult
    public var providers: [SkyStreamProviderState]
    /// True when the archive declared `providers: []` and the stored manifest's
    /// provider rows were obtained through the documented `getProviders` ABI.
    public var usesDynamicProviders: Bool?
    /// Package-scoped localStorage values used by the documented runtime. This
    /// remains optional for backup/persistence compatibility with older builds.
    public var runtimeStorage: [String: String]?
    public var preferences: [String: SkyStreamPreferenceValue]
    public var installedAt: Date
    public var updatedAt: Date
    public var additionalFields: [String: SkyStreamJSONValue]

    public var id: String { manifest.packageName }

    public init(
        manifest: SkyStreamPluginManifest,
        archiveSHA256: String,
        scriptSHA256: String,
        payloadRelativePath: String,
        provenance: SkyStreamInstallProvenance,
        selectedDomainURL: String? = nil,
        compatibility: SkyStreamCompatibilityResult = .untested,
        providers: [SkyStreamProviderState] = [],
        usesDynamicProviders: Bool? = nil,
        runtimeStorage: [String: String]? = nil,
        preferences: [String: SkyStreamPreferenceValue] = [:],
        installedAt: Date = Date(),
        updatedAt: Date = Date(),
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.manifest = manifest
        self.archiveSHA256 = archiveSHA256
        self.scriptSHA256 = scriptSHA256
        self.payloadRelativePath = payloadRelativePath
        self.provenance = provenance
        self.selectedDomainURL = selectedDomainURL
        self.compatibility = compatibility
        self.providers = providers
        self.usesDynamicProviders = usesDynamicProviders
        self.runtimeStorage = runtimeStorage
        self.preferences = preferences
        self.installedAt = installedAt
        self.updatedAt = updatedAt
        self.additionalFields = additionalFields
    }
}

// MARK: - Normalized runtime records

/// Open-string wrappers keep newer official values decodable while providing
/// stable constants for values Eclipse currently understands.
public struct SkyStreamContentType: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }

    public static let movie = Self(rawValue: "movie")
    public static let series = Self(rawValue: "series")
    public static let anime = Self(rawValue: "anime")
    public static let livestream = Self(rawValue: "livestream")
    public static let other = Self(rawValue: "other")
}

public struct SkyStreamShowStatus: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }

    public static let completed = Self(rawValue: "completed")
    public static let ongoing = Self(rawValue: "ongoing")
    public static let upcoming = Self(rawValue: "upcoming")
}

public struct SkyStreamDubStatus: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }

    public static let none = Self(rawValue: "none")
    public static let dubbed = Self(rawValue: "dubbed")
    public static let subbed = Self(rawValue: "subbed")
}

public struct SkyStreamVoiceActorRecord: Codable, Sendable, Hashable {
    public var name: String
    public var imageURL: String?
    public var role: String?
    public var additionalFields: [String: SkyStreamJSONValue]

    public init(
        name: String,
        imageURL: String? = nil,
        role: String? = nil,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.name = name
        self.imageURL = imageURL
        self.role = role
        self.additionalFields = additionalFields
    }
}

public struct SkyStreamActorRecord: Codable, Sendable, Hashable {
    public var name: String
    public var imageURL: String?
    public var role: String?
    public var voiceActor: SkyStreamVoiceActorRecord?
    public var additionalFields: [String: SkyStreamJSONValue]

    public init(
        name: String,
        imageURL: String? = nil,
        role: String? = nil,
        voiceActor: SkyStreamVoiceActorRecord? = nil,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.name = name
        self.imageURL = imageURL
        self.role = role
        self.voiceActor = voiceActor
        self.additionalFields = additionalFields
    }
}

public struct SkyStreamTrailerRecord: Codable, Sendable, Hashable {
    public var url: String
    public var headers: [String: String]
    public var additionalFields: [String: SkyStreamJSONValue]

    public init(
        url: String,
        headers: [String: String] = [:],
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.url = url
        self.headers = headers
        self.additionalFields = additionalFields
    }
}

public struct SkyStreamNextAiringRecord: Codable, Sendable, Hashable {
    public var episode: Int
    public var season: Int?
    public var unixTime: Int64
    public var additionalFields: [String: SkyStreamJSONValue]

    public init(
        episode: Int,
        season: Int? = nil,
        unixTime: Int64,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.episode = episode
        self.season = season
        self.unixTime = unixTime
        self.additionalFields = additionalFields
    }
}

public struct SkyStreamSubtitleRecord: Codable, Sendable, Hashable, Identifiable {
    public var url: String
    public var label: String?
    public var language: String?
    public var headers: [String: String]
    public var additionalFields: [String: SkyStreamJSONValue]

    public var id: String {
        // Subtitle headers can carry authentication and make two otherwise identical URLs
        // playback-distinct. Include their canonical contents in the identity, but expose only
        // a digest so SwiftUI identifiers and diagnostics never contain credential values.
        var components = [url, language ?? "", label ?? ""]
        for key in headers.keys.sorted(by: Self.canonicalHeaderOrder) {
            components.append(key.lowercased())
            components.append(headers[key] ?? "")
        }
        return SHA256.hash(data: Data(components.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func canonicalHeaderOrder(_ lhs: String, _ rhs: String) -> Bool {
        let lhsKey = lhs.lowercased()
        let rhsKey = rhs.lowercased()
        return lhsKey == rhsKey ? lhs < rhs : lhsKey < rhsKey
    }

    public init(
        url: String,
        label: String? = nil,
        language: String? = nil,
        headers: [String: String] = [:],
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.url = url
        self.label = label
        self.language = language
        self.headers = headers
        self.additionalFields = additionalFields
    }
}

public struct SkyStreamStreamRecord: Codable, Sendable, Hashable, Identifiable {
    public var url: String
    public var source: String?
    public var name: String?
    public var qualityLabel: String?
    public var quality: Int?
    public var mediaType: String?
    public var referer: String?
    public var headers: [String: String]
    public var subtitles: [SkyStreamSubtitleRecord]
    public var drmKeyID: String?
    public var drmKey: String?
    public var licenseURL: String?
    public var additionalFields: [String: SkyStreamJSONValue]

    public var id: String {
        // Runtime providers sometimes return the same CDN URL more than once with different
        // authorization/cookie values or subtitle routes. Those are playback-distinct choices,
        // but raw credentials must not become a SwiftUI/logging identifier. Hash a canonical
        // in-memory identity so mapper and resolver deduplication retain every usable variant.
        var components = [
            url,
            source ?? "",
            name ?? "",
            qualityLabel ?? "",
            quality.map(String.init) ?? "",
            mediaType ?? "",
            referer ?? "",
            drmKeyID ?? "",
            drmKey ?? "",
            licenseURL ?? ""
        ]
        for key in headers.keys.sorted(by: Self.canonicalHeaderOrder) {
            components.append(key.lowercased())
            components.append(headers[key] ?? "")
        }
        for subtitle in subtitles {
            components.append(subtitle.url)
            components.append(subtitle.label ?? "")
            components.append(subtitle.language ?? "")
            for key in subtitle.headers.keys.sorted(by: Self.canonicalHeaderOrder) {
                components.append(key.lowercased())
                components.append(subtitle.headers[key] ?? "")
            }
        }
        if !additionalFields.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let encodedAdditionalFields = try? encoder.encode(additionalFields) {
                components.append(
                    SHA256.hash(data: encodedAdditionalFields)
                        .map { String(format: "%02x", $0) }
                        .joined()
                )
            }
        }
        let material = components.joined(separator: "\u{0}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func canonicalHeaderOrder(_ lhs: String, _ rhs: String) -> Bool {
        let lhsKey = lhs.lowercased()
        let rhsKey = rhs.lowercased()
        return lhsKey == rhsKey ? lhs < rhs : lhsKey < rhsKey
    }

    public var hasDRM: Bool {
        drmKeyID != nil || drmKey != nil || licenseURL != nil
    }

    public init(
        url: String,
        source: String? = nil,
        name: String? = nil,
        qualityLabel: String? = nil,
        quality: Int? = nil,
        mediaType: String? = nil,
        referer: String? = nil,
        headers: [String: String] = [:],
        subtitles: [SkyStreamSubtitleRecord] = [],
        drmKeyID: String? = nil,
        drmKey: String? = nil,
        licenseURL: String? = nil,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.url = url
        self.source = source
        self.name = name
        self.qualityLabel = qualityLabel
        self.quality = quality
        self.mediaType = mediaType
        self.referer = referer
        self.headers = headers
        self.subtitles = subtitles
        self.drmKeyID = drmKeyID
        self.drmKey = drmKey
        self.licenseURL = licenseURL
        self.additionalFields = additionalFields
    }
}

public struct SkyStreamEpisodeRecord: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var url: String
    public var season: Int?
    public var episode: Int?
    public var description: String?
    public var posterURL: String?
    public var headers: [String: String]
    public var rating: Double?
    public var runtimeMinutes: Int?
    public var airDate: String?
    public var dubStatus: SkyStreamDubStatus?
    public var playbackPolicy: String?
    public var streams: [SkyStreamStreamRecord]
    public var additionalFields: [String: SkyStreamJSONValue]

    /// Episode page URLs are not unique in the documented ABI: a provider may embed streams
    /// with an empty URL or reuse one show page for multiple explicit coordinates.
    public var id: String {
        let components = [
            url,
            season.map(String.init) ?? "",
            episode.map(String.init) ?? "",
            name,
            streams.map(\.id).joined(separator: ",")
        ]
        let digest = SHA256.hash(data: Data(components.joined(separator: "\u{1f}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public init(
        name: String,
        url: String,
        season: Int? = nil,
        episode: Int? = nil,
        description: String? = nil,
        posterURL: String? = nil,
        headers: [String: String] = [:],
        rating: Double? = nil,
        runtimeMinutes: Int? = nil,
        airDate: String? = nil,
        dubStatus: SkyStreamDubStatus? = nil,
        playbackPolicy: String? = nil,
        streams: [SkyStreamStreamRecord] = [],
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.name = name
        self.url = url
        self.season = season
        self.episode = episode
        self.description = description
        self.posterURL = posterURL
        self.headers = headers
        self.rating = rating
        self.runtimeMinutes = runtimeMinutes
        self.airDate = airDate
        self.dubStatus = dubStatus
        self.playbackPolicy = playbackPolicy
        self.streams = streams
        self.additionalFields = additionalFields
    }
}

public struct SkyStreamSearchRecord: Codable, Sendable, Hashable, Identifiable {
    public var title: String
    public var url: String
    public var posterURL: String?
    public var contentType: SkyStreamContentType?
    public var year: Int?
    public var score: Double?
    public var durationMinutes: Int?
    public var status: SkyStreamShowStatus?
    public var description: String?
    public var providerName: String?
    public var alternateTitles: [String]
    public var headers: [String: String]
    public var syncData: [String: String]
    public var streams: [SkyStreamStreamRecord]
    public var additionalFields: [String: SkyStreamJSONValue]

    public var id: String { url }

    public init(
        title: String,
        url: String,
        posterURL: String? = nil,
        contentType: SkyStreamContentType? = nil,
        year: Int? = nil,
        score: Double? = nil,
        durationMinutes: Int? = nil,
        status: SkyStreamShowStatus? = nil,
        description: String? = nil,
        providerName: String? = nil,
        alternateTitles: [String] = [],
        headers: [String: String] = [:],
        syncData: [String: String] = [:],
        streams: [SkyStreamStreamRecord] = [],
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.title = title
        self.url = url
        self.posterURL = posterURL
        self.contentType = contentType
        self.year = year
        self.score = score
        self.durationMinutes = durationMinutes
        self.status = status
        self.description = description
        self.providerName = providerName
        self.alternateTitles = alternateTitles
        self.headers = headers
        self.syncData = syncData
        self.streams = streams
        self.additionalFields = additionalFields
    }
}

public struct SkyStreamLoadedItemRecord: Codable, Sendable, Hashable, Identifiable {
    public var title: String
    public var url: String
    public var posterURL: String?
    public var bannerURL: String?
    public var logoURL: String?
    public var contentType: SkyStreamContentType?
    public var year: Int?
    public var score: Double?
    public var durationMinutes: Int?
    public var status: SkyStreamShowStatus?
    public var description: String?
    public var tags: [String]
    public var contentRating: String?
    public var playbackPolicy: String?
    public var isAdult: Bool?
    public var providerName: String?
    public var alternateTitles: [String]
    public var headers: [String: String]
    public var syncData: [String: String]
    public var cast: [SkyStreamActorRecord]
    public var trailers: [SkyStreamTrailerRecord]
    public var nextAiring: SkyStreamNextAiringRecord?
    public var recommendations: [SkyStreamSearchRecord]
    public var episodes: [SkyStreamEpisodeRecord]
    public var streams: [SkyStreamStreamRecord]
    public var additionalFields: [String: SkyStreamJSONValue]

    public var id: String { url }

    public init(
        title: String,
        url: String,
        posterURL: String? = nil,
        bannerURL: String? = nil,
        logoURL: String? = nil,
        contentType: SkyStreamContentType? = nil,
        year: Int? = nil,
        score: Double? = nil,
        durationMinutes: Int? = nil,
        status: SkyStreamShowStatus? = nil,
        description: String? = nil,
        tags: [String] = [],
        contentRating: String? = nil,
        playbackPolicy: String? = nil,
        isAdult: Bool? = nil,
        providerName: String? = nil,
        alternateTitles: [String] = [],
        headers: [String: String] = [:],
        syncData: [String: String] = [:],
        cast: [SkyStreamActorRecord] = [],
        trailers: [SkyStreamTrailerRecord] = [],
        nextAiring: SkyStreamNextAiringRecord? = nil,
        recommendations: [SkyStreamSearchRecord] = [],
        episodes: [SkyStreamEpisodeRecord] = [],
        streams: [SkyStreamStreamRecord] = [],
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.title = title
        self.url = url
        self.posterURL = posterURL
        self.bannerURL = bannerURL
        self.logoURL = logoURL
        self.contentType = contentType
        self.year = year
        self.score = score
        self.durationMinutes = durationMinutes
        self.status = status
        self.description = description
        self.tags = tags
        self.contentRating = contentRating
        self.playbackPolicy = playbackPolicy
        self.isAdult = isAdult
        self.providerName = providerName
        self.alternateTitles = alternateTitles
        self.headers = headers
        self.syncData = syncData
        self.cast = cast
        self.trailers = trailers
        self.nextAiring = nextAiring
        self.recommendations = recommendations
        self.episodes = episodes
        self.streams = streams
        self.additionalFields = additionalFields
    }
}

public struct SkyStreamProviderContentReference: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var packageName: String
    public var providerID: String?
    /// Installed payload identity. New references populate both fields so refresh never crosses
    /// a silent plugin-code replacement; nil remains decodable for forward migration only.
    public var scriptSHA256: String?
    public var pluginVersion: Int?
    public var loadedItemURL: String
    public var selectedEpisodeURL: String?
    public var season: Int?
    public var episode: Int?
    public var preferredStreamLabel: String?
    public var contentType: SkyStreamContentType?
    public var title: String?
    public var year: Int?
    public var syncData: [String: String]
    public var additionalFields: [String: SkyStreamJSONValue]

    public var sourceID: String {
        SkyStreamStableID.sourceID(packageName: packageName, providerID: providerID)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, packageName, providerID, scriptSHA256, pluginVersion
        case loadedItemURL, selectedEpisodeURL, season, episode, preferredStreamLabel
        case contentType, title, year, syncData, additionalFields
    }

    public init(
        packageName: String,
        providerID: String? = nil,
        scriptSHA256: String? = nil,
        pluginVersion: Int? = nil,
        loadedItemURL: String = "",
        selectedEpisodeURL: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        preferredStreamLabel: String? = nil,
        contentType: SkyStreamContentType? = nil,
        title: String? = nil,
        year: Int? = nil
    ) {
        // URLs are bounded provider content identifiers, not trusted playback URLs. They remain
        // device-local because MediaStateSync removes the complete content reference before a
        // cloud write. Keeping them avoids a full search round-trip for normal signed-URL,
        // download, and next-episode refreshes while the resolver still re-runs load/VOD checks.
        self.schemaVersion = 2
        self.packageName = packageName
        self.providerID = providerID
        self.scriptSHA256 = Self.normalizedSHA256(scriptSHA256)
        self.pluginVersion = pluginVersion
        self.loadedItemURL = Self.bounded(loadedItemURL, maximumBytes: 16_384) ?? ""
        self.selectedEpisodeURL = Self.bounded(selectedEpisodeURL, maximumBytes: 16_384)
        self.season = season
        self.episode = episode
        self.preferredStreamLabel = Self.bounded(preferredStreamLabel, maximumBytes: 512)
        self.contentType = contentType
        self.title = Self.bounded(title, maximumBytes: 512)
        self.year = year
        self.syncData = [:]
        self.additionalFields = [:]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        let decodedPackageName = try container.decode(String.self, forKey: .packageName)
        let decodedProviderID = try container.decodeIfPresent(String.self, forKey: .providerID)
        let decodedScriptHash = try container.decodeIfPresent(String.self, forKey: .scriptSHA256)
        let decodedPluginVersion = try container.decodeIfPresent(Int.self, forKey: .pluginVersion)
        let decodedLoadedURL = try container.decodeIfPresent(String.self, forKey: .loadedItemURL) ?? ""
        let decodedEpisodeURL = try container.decodeIfPresent(String.self, forKey: .selectedEpisodeURL)
        let decodedSeason = try container.decodeIfPresent(Int.self, forKey: .season)
        let decodedEpisode = try container.decodeIfPresent(Int.self, forKey: .episode)
        let decodedLabel = try container.decodeIfPresent(String.self, forKey: .preferredStreamLabel)
        let decodedContentType = try container.decodeIfPresent(SkyStreamContentType.self, forKey: .contentType)
        let decodedTitle = try container.decodeIfPresent(String.self, forKey: .title)
        let decodedYear = try container.decodeIfPresent(Int.self, forKey: .year)
        let decodedSyncData = try container.decodeIfPresent([String: String].self, forKey: .syncData) ?? [:]
        let decodedAdditional = try container.decodeIfPresent(
            [String: SkyStreamJSONValue].self,
            forKey: .additionalFields
        ) ?? [:]

        guard decodedSchemaVersion == 1 || decodedSchemaVersion == 2,
              Self.bounded(decodedLoadedURL, maximumBytes: 16_384) != nil || decodedLoadedURL.isEmpty,
              Self.bounded(decodedEpisodeURL, maximumBytes: 16_384) != nil || decodedEpisodeURL == nil,
              Self.sanitizedSyncData(decodedSyncData) == decodedSyncData,
              Self.sanitizedAdditionalFields(decodedAdditional) == decodedAdditional else {
            throw DecodingError.dataCorruptedError(
                forKey: .packageName,
                in: container,
                debugDescription: "Invalid or oversized SkyStream content reference"
            )
        }

        // Version 1 mixed URLs with unbounded opaque state. Validate that legacy payload, but
        // migrate it to a lookup-only v2 record. Version 2 URLs were created by the bounded,
        // device-local initializer above and can safely retain the fast refresh path.
        self.init(
            packageName: decodedPackageName,
            providerID: decodedProviderID,
            scriptSHA256: decodedScriptHash,
            pluginVersion: decodedPluginVersion,
            loadedItemURL: decodedSchemaVersion == 2 ? decodedLoadedURL : "",
            selectedEpisodeURL: decodedSchemaVersion == 2 ? decodedEpisodeURL : nil,
            season: decodedSeason,
            episode: decodedEpisode,
            preferredStreamLabel: decodedLabel,
            contentType: decodedContentType,
            title: decodedTitle,
            year: decodedYear
        )
        guard isStructurallyValid,
              (decodedScriptHash == nil || Self.normalizedSHA256(decodedScriptHash) != nil),
              scriptSHA256 == Self.normalizedSHA256(decodedScriptHash) else {
            throw DecodingError.dataCorruptedError(
                forKey: .packageName,
                in: container,
                debugDescription: "Invalid or oversized SkyStream content reference"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard isStructurallyValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid SkyStream content reference")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(packageName, forKey: .packageName)
        try container.encodeIfPresent(providerID, forKey: .providerID)
        try container.encodeIfPresent(scriptSHA256, forKey: .scriptSHA256)
        try container.encodeIfPresent(pluginVersion, forKey: .pluginVersion)
        if !loadedItemURL.isEmpty {
            try container.encode(loadedItemURL, forKey: .loadedItemURL)
        }
        try container.encodeIfPresent(selectedEpisodeURL, forKey: .selectedEpisodeURL)
        try container.encodeIfPresent(season, forKey: .season)
        try container.encodeIfPresent(episode, forKey: .episode)
        try container.encodeIfPresent(preferredStreamLabel, forKey: .preferredStreamLabel)
        try container.encodeIfPresent(contentType, forKey: .contentType)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(year, forKey: .year)
    }

    public var isStructurallyValid: Bool {
        guard schemaVersion == 2,
              SkyStreamStableID.isValidPackageName(packageName),
              providerID.map(SkyStreamStableID.isValidProviderID) ?? true,
              (loadedItemURL.isEmpty
                || Self.bounded(loadedItemURL, maximumBytes: 16_384) == loadedItemURL),
              (selectedEpisodeURL.map {
                  Self.bounded($0, maximumBytes: 16_384) == $0
              } ?? true),
              (preferredStreamLabel?.utf8.count ?? 0) <= 512,
              (title?.utf8.count ?? 0) <= 512,
              (contentType?.rawValue.utf8.count ?? 0) <= 64,
              season.map({ (0...100_000).contains($0) }) ?? true,
              episode.map({ (0...100_000).contains($0) }) ?? true,
              year.map({ (1800...3000).contains($0) }) ?? true,
              pluginVersion.map({ $0 > 0 }) ?? true else { return false }
        if let scriptSHA256, Self.normalizedSHA256(scriptSHA256) != scriptSHA256.lowercased() {
            return false
        }
        return syncData.isEmpty && additionalFields.isEmpty
    }

    private static func bounded(_ value: String?, maximumBytes: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumBytes,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return trimmed
    }

    private static func normalizedSHA256(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard normalized.count == 64,
              normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return normalized
    }

    private static func sanitizedSyncData(_ values: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        var byteCount = 0
        for key in values.keys.sorted().prefix(64) {
            guard let value = values[key],
                  let boundedKey = bounded(key, maximumBytes: 128),
                  let boundedValue = bounded(value, maximumBytes: 4_096) else { continue }
            let next = byteCount + boundedKey.utf8.count + boundedValue.utf8.count
            guard next <= 64 * 1_024 else { break }
            result[boundedKey] = boundedValue
            byteCount = next
        }
        return result
    }

    private static func sanitizedAdditionalFields(
        _ values: [String: SkyStreamJSONValue]
    ) -> [String: SkyStreamJSONValue] {
        var boundedKeys: [String: SkyStreamJSONValue] = [:]
        for key in values.keys.sorted().prefix(64) {
            guard let boundedKey = bounded(key, maximumBytes: 128),
                  boundedKeys[boundedKey] == nil,
                  let value = values[key] else { continue }
            boundedKeys[boundedKey] = value
        }
        guard let data = try? JSONEncoder().encode(boundedKeys), data.count <= 64 * 1_024 else {
            return [:]
        }
        return boundedKeys
    }
}

// MARK: - Preferences

public struct SkyStreamPreferenceKind: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }

    public static let string = Self(rawValue: "string")
    public static let boolean = Self(rawValue: "boolean")
    public static let integer = Self(rawValue: "integer")
    public static let number = Self(rawValue: "number")
    public static let selection = Self(rawValue: "selection")
    public static let multiSelection = Self(rawValue: "multiSelection")
    public static let secret = Self(rawValue: "secret")
}

public struct SkyStreamPreferenceOption: Codable, Sendable, Hashable {
    public var label: String
    public var value: SkyStreamJSONValue
    public var additionalFields: [String: SkyStreamJSONValue]

    public init(
        label: String,
        value: SkyStreamJSONValue,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.label = label
        self.value = value
        self.additionalFields = additionalFields
    }
}

public struct SkyStreamPreferenceSchema: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var kind: SkyStreamPreferenceKind
    public var title: String
    public var description: String?
    public var defaultValue: SkyStreamJSONValue?
    public var options: [SkyStreamPreferenceOption]
    public var minimum: Double?
    public var maximum: Double?
    public var step: Double?
    public var isRequired: Bool
    public var isSecret: Bool
    public var additionalFields: [String: SkyStreamJSONValue]

    public var id: String { key }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case key, title, description, options, minimum, maximum, step
        case kind = "type"
        case defaultValue = "default"
        case isRequired = "required"
        case isSecret = "secret"
    }

    public init(
        key: String,
        kind: SkyStreamPreferenceKind,
        title: String,
        description: String? = nil,
        defaultValue: SkyStreamJSONValue? = nil,
        options: [SkyStreamPreferenceOption] = [],
        minimum: Double? = nil,
        maximum: Double? = nil,
        step: Double? = nil,
        isRequired: Bool = false,
        isSecret: Bool = false,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.key = key
        self.kind = kind
        self.title = title
        self.description = description
        self.defaultValue = defaultValue
        self.options = options
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.isRequired = isRequired
        self.isSecret = isSecret
        self.additionalFields = additionalFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        kind = try container.decode(SkyStreamPreferenceKind.self, forKey: .kind)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? key
        description = try container.decodeIfPresent(String.self, forKey: .description)
        defaultValue = try container.decodeIfPresent(SkyStreamJSONValue.self, forKey: .defaultValue)
        options = try container.decodeIfPresent([SkyStreamPreferenceOption].self, forKey: .options) ?? []
        minimum = try container.decodeIfPresent(Double.self, forKey: .minimum)
        maximum = try container.decodeIfPresent(Double.self, forKey: .maximum)
        step = try container.decodeIfPresent(Double.self, forKey: .step)
        isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired) ?? false
        isSecret = try container.decodeIfPresent(Bool.self, forKey: .isSecret) ?? (kind == .secret)
        additionalFields = try skyStreamAdditionalFields(
            from: decoder,
            excluding: Set(CodingKeys.allCases.map(\.rawValue))
        )
    }

    public func encode(to encoder: Encoder) throws {
        let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
        try skyStreamEncodeAdditionalFields(additionalFields, excluding: knownKeys, to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
        if !options.isEmpty { try container.encode(options, forKey: .options) }
        try container.encodeIfPresent(minimum, forKey: .minimum)
        try container.encodeIfPresent(maximum, forKey: .maximum)
        try container.encodeIfPresent(step, forKey: .step)
        if isRequired { try container.encode(true, forKey: .isRequired) }
        if isSecret { try container.encode(true, forKey: .isSecret) }
    }
}

public struct SkyStreamPreferenceValue: Codable, Sendable, Hashable {
    public var value: SkyStreamJSONValue
    public var isSecret: Bool
    public var isRedacted: Bool
    public var updatedAt: Date?

    public init(
        value: SkyStreamJSONValue,
        isSecret: Bool = false,
        isRedacted: Bool = false,
        updatedAt: Date? = nil
    ) {
        self.value = value
        self.isSecret = isSecret
        self.isRedacted = isRedacted
        self.updatedAt = updatedAt
    }
}

// MARK: - Backup snapshots

public struct SkyStreamRepositoryBackupSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var sourceURL: String
    public var kind: SkyStreamSavedRepository.Kind
    public var name: String
    public var manifest: SkyStreamRepositoryManifest?
    public var pluginListURLs: [String]
    public var lastRefreshedAt: Date?
    public var frozenAt: Date?
    public var additionalFields: [String: SkyStreamJSONValue]

    public var id: String { sourceURL }

    public init(
        sourceURL: String,
        kind: SkyStreamSavedRepository.Kind = .repository,
        name: String? = nil,
        manifest: SkyStreamRepositoryManifest? = nil,
        pluginListURLs: [String] = [],
        lastRefreshedAt: Date? = nil,
        frozenAt: Date? = nil,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.sourceURL = sourceURL
        self.kind = kind
        self.name = name ?? manifest?.name ?? "Plugin List"
        self.manifest = manifest
        self.pluginListURLs = pluginListURLs.isEmpty
            ? (manifest?.pluginLists ?? (kind == .pluginList ? [sourceURL] : []))
            : pluginListURLs
        self.lastRefreshedAt = lastRefreshedAt
        self.frozenAt = frozenAt
        self.additionalFields = additionalFields
    }

    private enum CodingKeys: String, CodingKey {
        case sourceURL, kind, name, manifest, pluginListURLs
        case lastRefreshedAt, frozenAt, additionalFields
    }

    /// `kind`, `name`, and `pluginListURLs` were added after the first backup schema shipped.
    /// Derive them from the formerly-required repository manifest so old backups remain valid.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceURL = try container.decode(String.self, forKey: .sourceURL)
        manifest = try container.decodeIfPresent(SkyStreamRepositoryManifest.self, forKey: .manifest)
        kind = try container.decodeIfPresent(SkyStreamSavedRepository.Kind.self, forKey: .kind)
            ?? (manifest == nil ? .pluginList : .repository)
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? manifest?.name
            ?? "Plugin List"
        pluginListURLs = try container.decodeIfPresent([String].self, forKey: .pluginListURLs)
            ?? manifest?.pluginLists
            ?? (kind == .pluginList ? [sourceURL] : [])
        lastRefreshedAt = try container.decodeIfPresent(Date.self, forKey: .lastRefreshedAt)
        frozenAt = try container.decodeIfPresent(Date.self, forKey: .frozenAt)
        additionalFields = try container.decodeIfPresent(
            [String: SkyStreamJSONValue].self,
            forKey: .additionalFields
        ) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceURL, forKey: .sourceURL)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(manifest, forKey: .manifest)
        try container.encode(pluginListURLs, forKey: .pluginListURLs)
        try container.encodeIfPresent(lastRefreshedAt, forKey: .lastRefreshedAt)
        try container.encodeIfPresent(frozenAt, forKey: .frozenAt)
        if !additionalFields.isEmpty {
            try container.encode(additionalFields, forKey: .additionalFields)
        }
    }
}

public struct SkyStreamPluginBackupSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var state: SkyStreamInstalledPluginState
    /// The original `.sky` bytes for a full manual backup. Safe cloud backups
    /// may leave this nil without implying deletion on restore.
    public var archivePayload: Data?
    public var payloadWasRedacted: Bool
    public var preferencesWereRedacted: Bool
    public var additionalFields: [String: SkyStreamJSONValue]

    public var id: String { state.id }

    public init(
        state: SkyStreamInstalledPluginState,
        archivePayload: Data? = nil,
        payloadWasRedacted: Bool = false,
        preferencesWereRedacted: Bool = false,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.state = state
        self.archivePayload = archivePayload
        self.payloadWasRedacted = payloadWasRedacted
        self.preferencesWereRedacted = preferencesWereRedacted
        self.additionalFields = additionalFields
    }
}

public struct SkyStreamBackupSnapshot: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var repositories: [SkyStreamRepositoryBackupSnapshot]
    public var plugins: [SkyStreamPluginBackupSnapshot]
    public var createdAt: Date
    public var isSafeCloudSnapshot: Bool
    public var additionalFields: [String: SkyStreamJSONValue]

    public init(
        schemaVersion: Int = 1,
        repositories: [SkyStreamRepositoryBackupSnapshot] = [],
        plugins: [SkyStreamPluginBackupSnapshot] = [],
        createdAt: Date = Date(),
        isSafeCloudSnapshot: Bool = false,
        additionalFields: [String: SkyStreamJSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.repositories = repositories
        self.plugins = plugins
        self.createdAt = createdAt
        self.isSafeCloudSnapshot = isSafeCloudSnapshot
        self.additionalFields = additionalFields
    }
}

/// Shared structural quotas for repository/plugin metadata crossing backup and cloud boundaries.
/// Archive validation remains the package validator's responsibility; this policy prevents a
/// bounded outer JSON document from hiding pathological per-source strings, collections, or
/// runtime values that normal installs could never persist.
public enum SkyStreamBackupMetadataPolicy {
    public static let maximumProviderStates = 256
    public static let maximumPreferenceKeys = 256
    public static let maximumRuntimeKeys = 256
    public static let maximumPreferenceBytes = 512 * 1_024
    public static let maximumRuntimeBytes = 1 * 1_024 * 1_024
    public static let maximumValueBytes = 64 * 1_024

    public static func isBounded(repository: SkyStreamRepositoryBackupSnapshot) -> Bool {
        guard boundedNonempty(repository.name, maximumBytes: 256),
              repository.sourceURL.utf8.count <= 8 * 1_024,
              !repository.pluginListURLs.isEmpty,
              repository.pluginListURLs.count <= 32,
              repository.pluginListURLs.allSatisfy({ $0.utf8.count <= 8 * 1_024 }) else {
            return false
        }
        if let manifest = repository.manifest {
            guard SkyStreamRepositoryManifest.isSupportedManifestVersion(
                manifest.manifestVersion
            ),
                  SkyStreamStableID.isValidPackageName(manifest.packageName),
                  boundedNonempty(manifest.name, maximumBytes: 256),
                  manifest.description.utf8.count <= 4 * 1_024,
                  manifest.pluginLists.count <= 32,
                  manifest.pluginLists.allSatisfy({ $0.utf8.count <= 8 * 1_024 }),
                  manifest.includedRepositories.count <= 32,
                  manifest.includedRepositories.allSatisfy({ $0.utf8.count <= 8 * 1_024 }),
                  manifest.plugins.count <= 2_000,
                  boundedOptionalStrings(manifest.authors, maximumCount: 64),
                  (manifest.iconURL?.utf8.count ?? 0) <= 8 * 1_024,
                  (manifest.websiteURL?.utf8.count ?? 0) <= 8 * 1_024 else {
                return false
            }
        }
        return encodedSize(repository).map { $0 <= 1 * 1_024 * 1_024 } ?? false
    }

    public static func isBounded(pluginState state: SkyStreamInstalledPluginState) -> Bool {
        let manifest = state.manifest
        guard SkyStreamStableID.isValidPackageName(state.id),
              manifest.packageName == state.id,
              manifest.version > 0,
              manifest.manifestVersion.map({ $0 == 1 }) ?? true,
              boundedNonempty(manifest.name, maximumBytes: 256),
              manifest.description.map({ boundedNonempty($0, maximumBytes: 4 * 1_024) }) ?? true,
              boundedStrings(manifest.authors, maximumCount: 64),
              boundedStrings(manifest.languages, maximumCount: 64),
              boundedStrings(manifest.categories, maximumCount: 64),
              manifest.baseURL.utf8.count <= 8 * 1_024,
              (manifest.iconURL?.utf8.count ?? 0) <= 8 * 1_024,
              (manifest.domains?.count ?? 0) <= 64,
              (manifest.providers?.count ?? 0) <= 64,
              manifest.providerID.map(SkyStreamStableID.isValidProviderID) ?? true,
              state.providers.count <= maximumProviderStates,
              preferencesAreBounded(state.preferences),
              runtimeStorageIsBounded(state.runtimeStorage ?? [:]),
              state.selectedDomainURL.map({ $0.utf8.count <= 8 * 1_024 }) ?? true,
              state.provenance.sourceURL.utf8.count <= 8 * 1_024,
              (state.provenance.repositoryURL?.utf8.count ?? 0) <= 8 * 1_024,
              (state.provenance.pluginListURL?.utf8.count ?? 0) <= 8 * 1_024,
              state.provenance.repositoryPackageName.map(SkyStreamStableID.isValidPackageName) ?? true,
              state.compatibility.reasons.count <= 64 else {
            return false
        }

        var domainNames = Set<String>()
        var domainURLs = Set<String>()
        guard (manifest.domains ?? []).allSatisfy({ domain in
            boundedNonempty(domain.name, maximumBytes: 256)
                && domain.url.utf8.count <= 8 * 1_024
                && domainNames.insert(domain.name.lowercased()).inserted
                && domainURLs.insert(domain.url.lowercased()).inserted
        }) else { return false }

        var providerIDs = Set<String>()
        guard (manifest.providers ?? []).allSatisfy({ provider in
            SkyStreamStableID.isValidProviderID(provider.id)
                && providerIDs.insert(provider.id).inserted
                && boundedNonempty(provider.name, maximumBytes: 256)
                && (provider.baseURL?.utf8.count ?? 0) <= 8 * 1_024
                && (provider.iconURL?.utf8.count ?? 0) <= 8 * 1_024
                && boundedOptionalStrings(provider.languages, maximumCount: 64)
                && boundedOptionalStrings(provider.categories, maximumCount: 64)
        }) else { return false }

        var stateIDs = Set<String>()
        guard state.providers.allSatisfy({ provider in
            provider.packageName == state.id
                && (provider.providerID.map(SkyStreamStableID.isValidProviderID) ?? true)
                && stateIDs.insert(provider.id).inserted
        }) else { return false }

        guard state.compatibility.reasons.allSatisfy({ reason in
            boundedNonempty(reason.message, maximumBytes: 4 * 1_024)
                && (reason.detail.map({ $0.utf8.count <= 4 * 1_024 }) ?? true)
                && (reason.field.map({ $0.utf8.count <= 256 }) ?? true)
        }) else { return false }

        return encodedSize(state).map { $0 <= 8 * 1_024 * 1_024 } ?? false
    }

    public static func preferencesAreBounded(
        _ preferences: [String: SkyStreamPreferenceValue]
    ) -> Bool {
        guard preferences.count <= maximumPreferenceKeys,
              preferences.allSatisfy({ key, value in
                  validRuntimeKey(key)
                      && (encodedSize(value.value).map { $0 <= maximumValueBytes } ?? false)
              }) else { return false }
        return encodedSize(preferences.mapValues(\.value))
            .map { $0 <= maximumPreferenceBytes } ?? false
    }

    public static func runtimeStorageIsBounded(_ storage: [String: String]) -> Bool {
        guard storage.count <= maximumRuntimeKeys,
              storage.allSatisfy({ key, value in
                  validRuntimeKey(key) && value.utf8.count <= maximumValueBytes
              }) else { return false }
        let bytes = storage.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        return bytes <= maximumRuntimeBytes
    }

    private static func boundedStrings(_ values: [String], maximumCount: Int) -> Bool {
        values.count <= maximumCount
            && values.allSatisfy { boundedNonempty($0, maximumBytes: 256) }
    }

    private static func boundedOptionalStrings(_ values: [String]?, maximumCount: Int) -> Bool {
        guard let values else { return true }
        return values.count <= maximumCount
            && values.allSatisfy { boundedNonempty($0, maximumBytes: 256) }
    }

    private static func boundedNonempty(_ value: String, maximumBytes: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximumBytes
    }

    private static func validRuntimeKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed == key
            && key.utf8.count <= 256
            && !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func encodedSize<T: Encodable>(_ value: T) -> Int? {
        try? JSONEncoder().encode(value).count
    }
}

/// Non-iOS targets keep the user-exportable opaque backup, the larger experimental-cloud backup,
/// and the CloudKit metadata shadow in separate files. The legacy shared name remains a read-only
/// fallback for manual backup recovery; cloud paths must never write or delete either manual file.
public enum SkyStreamOpaqueStorageLayout {
    public static let manualBackupFilename = "opaque-manual-backup-v1.json"
    public static let experimentalCloudBackupFilename = "opaque-cloud-backup-v1.json"
    public static let mediaStateFilename = "opaque-media-state-v1.json"
    public static let legacySharedFilename = "opaque-backup-v1.json"

    /// A newer full manual import supersedes any derived experimental-cloud shadow. Removing only
    /// that shadow makes the next upload sanitize the newly imported full document instead of
    /// relaying stale cloud metadata; manual and CloudKit media-state files are never invalidated.
    public static func filenamesInvalidatedAfterWrite(
        isSafeCloudSnapshot: Bool
    ) -> [String] {
        isSafeCloudSnapshot ? [] : [experimentalCloudBackupFilename]
    }
}

/// The CloudKit media-state bridge carries only reconstructable, non-secret SkyStream metadata.
/// Package archives remain in the existing bounded backup channel: copying even one 20 MB archive
/// into a CKRecord would exceed CloudKit's record budget and make Apple TV a denial-of-service
/// relay. This document deliberately stays below the media-state store's 800 KiB payload limit.
public enum SkyStreamMediaStateDocument {
    public static let maximumPayloadBytes = 700 * 1_024

    public enum ValidationError: Error, Sendable, Equatable {
        case invalidSnapshot
        case payloadTooLarge
    }

    /// `snapshot` must already have crossed the normal safe-cloud redaction boundary. This final
    /// pass removes archive bytes, fixes the otherwise ever-changing capture timestamp, and then
    /// validates every field Apple TV is allowed to preserve.
    public static func encodeMetadataOnly(
        _ snapshot: SkyStreamBackupSnapshot
    ) throws -> Data {
        var metadata = snapshot
        let canonicalDate = Date(timeIntervalSince1970: 0)
        metadata.createdAt = canonicalDate
        for index in metadata.repositories.indices {
            // Refresh time is a device-local cache clock. Keeping it would make two devices with
            // identical pinned repository state alternately re-upload their own timestamp.
            metadata.repositories[index].lastRefreshedAt = nil
            metadata.repositories[index].frozenAt = nil
        }
        for index in metadata.plugins.indices {
            metadata.plugins[index].archivePayload = nil
            metadata.plugins[index].payloadWasRedacted = true
            // Installation bookkeeping is device-local and restore itself updates `updatedAt`.
            // Excluding those volatile clocks prevents two devices from endlessly rewriting an
            // otherwise identical CloudKit document after each successful merge.
            metadata.plugins[index].state.installedAt = canonicalDate
            metadata.plugins[index].state.updatedAt = canonicalDate
            metadata.plugins[index].state.provenance.pinnedAt = canonicalDate
            metadata.plugins[index].state.provenance.frozenAt = nil
            metadata.plugins[index].state.provenance.expectedArchiveSHA256 =
                metadata.plugins[index].state.archiveSHA256
            metadata.plugins[index].state.compatibility.evaluatedAt = nil
            metadata.plugins[index].state.compatibility = .untested
            let usesDynamicProviders =
                metadata.plugins[index].state.usesDynamicProviders == true
                || metadata.plugins[index].state.manifest.providers?.isEmpty == true
            metadata.plugins[index].state.usesDynamicProviders = usesDynamicProviders
            if usesDynamicProviders {
                metadata.plugins[index].state.manifest.providers = []
            }
            metadata.plugins[index].state.preferences = metadata.plugins[index]
                .state.preferences.mapValues { value in
                    var canonical = value
                    canonical.updatedAt = nil
                    return canonical
                }
            // Removed dynamic-provider rows are device-local reconciliation tombstones. Restore
            // deliberately ignores them, so uploading their locally stamped `removedAt` values can
            // only make equivalent devices disagree. Active state has a stable identity/order.
            metadata.plugins[index].state.providers = metadata.plugins[index].state.providers
                .filter { $0.removedAt == nil }
                .sorted { $0.id < $1.id }
            // This bit must not reveal whether one device has a local secret or make otherwise
            // identical public state diverge across devices.
            metadata.plugins[index].preferencesWereRedacted = true
        }
        // Installation and repository insertion order are device-local. Canonical identity order
        // keeps devices with the same logical state from alternately rewriting one CloudKit record.
        metadata.repositories.sort { $0.sourceURL < $1.sourceURL }
        metadata.plugins.sort { $0.id < $1.id }
        guard isValid(metadata) else { throw ValidationError.invalidSnapshot }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(metadata)
        guard data.count <= maximumPayloadBytes else {
            throw ValidationError.payloadTooLarge
        }
        return data
    }

    public static func decodeMetadataOnly(_ data: Data) throws -> SkyStreamBackupSnapshot {
        guard data.count <= maximumPayloadBytes else {
            throw ValidationError.payloadTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(SkyStreamBackupSnapshot.self, from: data)
        guard isValid(snapshot) else { throw ValidationError.invalidSnapshot }
        return snapshot
    }

    private static func isValid(_ snapshot: SkyStreamBackupSnapshot) -> Bool {
        guard snapshot.schemaVersion == 1,
              snapshot.isSafeCloudSnapshot,
              snapshot.repositories.count <= 64,
              snapshot.plugins.count <= 128,
              snapshot.additionalFields.isEmpty,
              Set(snapshot.repositories.map(\.sourceURL)).count == snapshot.repositories.count,
              Set(snapshot.plugins.map(\.id)).count == snapshot.plugins.count else {
            return false
        }

        for repository in snapshot.repositories {
            guard SkyStreamBackupMetadataPolicy.isBounded(repository: repository),
                  isCloudSafeHTTPSURL(repository.sourceURL),
                  !repository.pluginListURLs.isEmpty,
                  repository.pluginListURLs.count <= 32,
                  repository.pluginListURLs.allSatisfy(isCloudSafeHTTPSURL),
                  repository.additionalFields.isEmpty else { return false }
            switch repository.kind {
            case .repository:
                guard let manifest = repository.manifest,
                      SkyStreamRepositoryManifest.isSupportedManifestVersion(
                          manifest.manifestVersion
                      ),
                      manifest.additionalFields.isEmpty,
                      manifest.pluginLists == repository.pluginListURLs,
                      manifest.iconURL.map(isCloudSafeHTTPSURL) ?? true,
                      manifest.websiteURL.map(isCloudSafeHTTPSURL) ?? true else { return false }
            case .pluginList:
                guard repository.manifest == nil else { return false }
            }
        }

        for plugin in snapshot.plugins {
            let state = plugin.state
            guard plugin.archivePayload == nil,
                  plugin.payloadWasRedacted,
                  plugin.additionalFields.isEmpty,
                  SkyStreamBackupMetadataPolicy.isBounded(pluginState: state),
                  SkyStreamStableID.isValidPackageName(state.id),
                  state.payloadRelativePath.isEmpty,
                  state.runtimeStorage == nil,
                  state.additionalFields.isEmpty,
                  state.manifest.packageName == state.id,
                  normalizedSHA256(state.archiveSHA256) != nil,
                  normalizedSHA256(state.scriptSHA256) != nil,
                  state.providers.count <= 256,
                  (state.manifest.providers?.count ?? 0) <= 64,
                  (state.manifest.domains?.count ?? 0) <= 64,
                  isCloudSafeHTTPSURL(state.provenance.sourceURL),
                  state.provenance.repositoryURL.map(isCloudSafeHTTPSURL) ?? true,
                  state.provenance.pluginListURL.map(isCloudSafeHTTPSURL) ?? true,
                  state.provenance.additionalFields.isEmpty,
                  state.selectedDomainURL.map(isCloudSafeHTTPSURL) ?? true,
                  state.manifest.additionalFields.isEmpty,
                  (state.manifest.baseURL.isEmpty || isCloudSafeHTTPSURL(state.manifest.baseURL)),
                  state.manifest.iconURL.map(isCloudSafeHTTPSURL) ?? true,
                  state.manifest.domains?.allSatisfy({
                      isCloudSafeHTTPSURL($0.url) && $0.additionalFields.isEmpty
                  }) ?? true,
                  state.manifest.providers?.allSatisfy({
                      SkyStreamStableID.isValidProviderID($0.id)
                          && ($0.baseURL.map(isCloudSafeHTTPSURL) ?? true)
                          && ($0.iconURL.map(isCloudSafeHTTPSURL) ?? true)
                          && $0.additionalFields.isEmpty
                  }) ?? true,
                  state.providers.allSatisfy({
                      $0.packageName == state.id
                          && ($0.providerID.map(SkyStreamStableID.isValidProviderID) ?? true)
                          && $0.additionalFields.isEmpty
                  }),
                  state.preferences.allSatisfy({ key, value in
                      !value.isSecret && !value.isRedacted && !containsSecretMarker(key)
                  }),
                  state.compatibility.reasons.allSatisfy(\.additionalFields.isEmpty) else {
                return false
            }
            if let selectedDomainURL = state.selectedDomainURL {
                guard state.manifest.domains?.contains(where: { $0.url == selectedDomainURL }) == true else {
                    return false
                }
            }
        }
        return true
    }

    private static func isCloudSafeHTTPSURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.host?.isEmpty == false,
              components.percentEncodedQuery == nil,
              components.fragment == nil else { return false }
        return true
    }

    private static func normalizedSHA256(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64,
              normalized.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789abcdef").contains
              ) else { return nil }
        return normalized
    }

    private static func containsSecretMarker(_ value: String) -> Bool {
        let lowercase = value.lowercased()
        return [
            "access_token", "refresh_token", "authorization", "api_key", "apikey",
            "password", "passwd", "session", "secret", "token"
        ].contains { lowercase.contains($0) }
    }
}

public extension Notification.Name {
    static let skyStreamMetadataDidChange = Notification.Name("skyStreamMetadataDidChange")
}

// MARK: - Package validation result

public struct SkyStreamValidatedPackage: Codable, Sendable, Hashable {
    public var manifest: SkyStreamPluginManifest
    public var archiveSHA256: String
    public var scriptSHA256: String
    public var stagingDirectory: URL
    public var archiveByteCount: UInt64
    public var expandedByteCount: UInt64
    public var entryCount: Int

    public init(
        manifest: SkyStreamPluginManifest,
        archiveSHA256: String,
        scriptSHA256: String,
        stagingDirectory: URL,
        archiveByteCount: UInt64,
        expandedByteCount: UInt64,
        entryCount: Int
    ) {
        self.manifest = manifest
        self.archiveSHA256 = archiveSHA256
        self.scriptSHA256 = scriptSHA256
        self.stagingDirectory = stagingDirectory
        self.archiveByteCount = archiveByteCount
        self.expandedByteCount = expandedByteCount
        self.entryCount = entryCount
    }
}
