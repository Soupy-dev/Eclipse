import Foundation

/// Bounded, versioned, device-local provider state used to re-resolve content. References may
/// include a short-lived content URL, but never headers, cookies, or JavaScript values; cloud
/// serialization deliberately strips the whole reference. Legacy Service call sites can continue
/// to use `serviceContentHref`; new code should prefer this reference.
struct ProviderContentReference: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case service
        case stremio
        case skyStream
    }

    var schemaVersion: Int
    var kind: Kind
    var sourceID: String
    var serviceHref: String?
    var stremioContentID: String?
    var skyStream: SkyStreamProviderContentReference?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, sourceID, serviceHref, stremioContentID, skyStream
    }

    init(
        schemaVersion: Int = 1,
        kind: Kind,
        sourceID: String,
        serviceHref: String? = nil,
        stremioContentID: String? = nil,
        skyStream: SkyStreamProviderContentReference? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.sourceID = sourceID
        self.serviceHref = Self.bounded(serviceHref, maximumUTF8Bytes: 8 * 1_024)
        self.stremioContentID = Self.bounded(stremioContentID, maximumUTF8Bytes: 2 * 1_024)
        self.skyStream = skyStream
    }

    static func service(sourceID: String, href: String) -> Self {
        Self(kind: .service, sourceID: sourceID, serviceHref: href)
    }

    static func skyStream(_ reference: SkyStreamProviderContentReference) -> Self {
        Self(kind: .skyStream, sourceID: reference.sourceID, skyStream: reference)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported provider content-reference version"
            )
        }
        kind = try container.decode(Kind.self, forKey: .kind)
        let rawSourceID = try container.decode(String.self, forKey: .sourceID)
        guard let boundedSourceID = Self.bounded(rawSourceID, maximumUTF8Bytes: 320) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceID,
                in: container,
                debugDescription: "Invalid provider source identifier"
            )
        }
        sourceID = boundedSourceID
        serviceHref = Self.bounded(
            try container.decodeIfPresent(String.self, forKey: .serviceHref),
            maximumUTF8Bytes: 8 * 1_024
        )
        stremioContentID = Self.bounded(
            try container.decodeIfPresent(String.self, forKey: .stremioContentID),
            maximumUTF8Bytes: 2 * 1_024
        )
        skyStream = try container.decodeIfPresent(SkyStreamProviderContentReference.self, forKey: .skyStream)

        switch kind {
        case .service where serviceHref == nil || !sourceID.hasPrefix("service:"),
             .stremio where stremioContentID == nil || !sourceID.hasPrefix("stremio:"),
             .skyStream where skyStream == nil
                || skyStream?.sourceID != sourceID
                || skyStream?.isStructurallyValid != true:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Provider reference payload does not match its kind"
            )
        default:
            break
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(kind, forKey: .kind)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encodeIfPresent(serviceHref, forKey: .serviceHref)
        try container.encodeIfPresent(stremioContentID, forKey: .stremioContentID)
        try container.encodeIfPresent(skyStream, forKey: .skyStream)
    }

    private static func bounded(_ value: String?, maximumUTF8Bytes: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumUTF8Bytes else { return nil }
        return trimmed
    }
}
