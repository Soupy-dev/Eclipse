import CryptoKit
import Foundation

struct ProviderContentReference: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case service
        case stremio
        case skyStream
        case nuvio
    }

    var schemaVersion: Int
    var kind: Kind
    var sourceID: String
    var serviceHref: String?
    var stremioContentID: String?
    var stremioContentType: String?
    var stremioStreamOrdinal: Int?
    var stremioStreamFingerprint: String?
    var stremioSubtitleOrdinal: Int?
    var stremioSubtitleFingerprint: String?
    var skyStream: SkyStreamProviderContentReference?
    var nuvio: NuvioProviderContentReference?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, sourceID, serviceHref
        case stremioContentID, stremioContentType, stremioStreamOrdinal
        case stremioStreamFingerprint, stremioSubtitleOrdinal, stremioSubtitleFingerprint
        case skyStream, nuvio
    }

    init(
        schemaVersion: Int = 1,
        kind: Kind,
        sourceID: String,
        serviceHref: String? = nil,
        stremioContentID: String? = nil,
        stremioContentType: String? = nil,
        stremioStreamOrdinal: Int? = nil,
        stremioStreamFingerprint: String? = nil,
        stremioSubtitleOrdinal: Int? = nil,
        stremioSubtitleFingerprint: String? = nil,
        skyStream: SkyStreamProviderContentReference? = nil,
        nuvio: NuvioProviderContentReference? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.sourceID = sourceID
        self.serviceHref = Self.bounded(serviceHref, maximumUTF8Bytes: 8 * 1_024)
        self.stremioContentID = Self.bounded(stremioContentID, maximumUTF8Bytes: 2 * 1_024)
        self.stremioContentType = Self.validatedStremioContentType(stremioContentType)
        self.stremioStreamOrdinal = Self.validatedOrdinal(
            stremioStreamOrdinal,
            upperBound: StremioDecodingLimits.streamsPerResponse
        )
        self.stremioStreamFingerprint = Self.validatedFingerprint(stremioStreamFingerprint)
        self.stremioSubtitleOrdinal = Self.validatedOrdinal(
            stremioSubtitleOrdinal,
            upperBound: StremioDecodingLimits.subtitlesPerStream
        )
        self.stremioSubtitleFingerprint = Self.validatedFingerprint(
            stremioSubtitleFingerprint
        )
        self.skyStream = skyStream
        self.nuvio = nuvio
    }

    static func service(sourceID: String, href: String) -> Self {
        Self(kind: .service, sourceID: sourceID, serviceHref: href)
    }

    static func stremio(
        addonID: UUID,
        stream: StremioStream,
        subtitleOrdinal: Int?
    ) -> Self? {
        guard let contentType = stream.resolvedContentType,
              let contentID = stream.resolvedContentID,
              let streamOrdinal = stream.resolvedStreamOrdinal else {
            return nil
        }
        let reference = Self(
            kind: .stremio,
            sourceID: "stremio:\(addonID.uuidString)",
            stremioContentID: contentID,
            stremioContentType: contentType,
            stremioStreamOrdinal: streamOrdinal,
            stremioStreamFingerprint: stremioSelectionFingerprint(for: stream),
            stremioSubtitleOrdinal: subtitleOrdinal,
            stremioSubtitleFingerprint: subtitleOrdinal.flatMap { ordinal in
                guard let subtitles = stream.subtitles,
                      subtitles.indices.contains(ordinal) else { return nil }
                return stremioSubtitleSelectionFingerprint(for: subtitles[ordinal])
            }
        )
        return reference.hasValidStremioSelection ? reference : nil
    }

    static func skyStream(_ reference: SkyStreamProviderContentReference) -> Self {
        Self(kind: .skyStream, sourceID: reference.sourceID, skyStream: reference)
    }

    static func nuvio(_ reference: NuvioProviderContentReference) -> Self {
        Self(kind: .nuvio, sourceID: reference.sourceID, nuvio: reference)
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
        let rawStremioContentType = try container.decodeIfPresent(
            String.self,
            forKey: .stremioContentType
        )
        stremioContentType = Self.validatedStremioContentType(rawStremioContentType)
        let rawStremioStreamOrdinal = try container.decodeIfPresent(
            Int.self,
            forKey: .stremioStreamOrdinal
        )
        stremioStreamOrdinal = Self.validatedOrdinal(
            rawStremioStreamOrdinal,
            upperBound: StremioDecodingLimits.streamsPerResponse
        )
        let rawStremioFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .stremioStreamFingerprint
        )
        stremioStreamFingerprint = Self.validatedFingerprint(rawStremioFingerprint)
        let rawStremioSubtitleOrdinal = try container.decodeIfPresent(
            Int.self,
            forKey: .stremioSubtitleOrdinal
        )
        stremioSubtitleOrdinal = Self.validatedOrdinal(
            rawStremioSubtitleOrdinal,
            upperBound: StremioDecodingLimits.subtitlesPerStream
        )
        let rawStremioSubtitleFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .stremioSubtitleFingerprint
        )
        stremioSubtitleFingerprint = Self.validatedFingerprint(
            rawStremioSubtitleFingerprint
        )
        guard rawStremioContentType == nil || stremioContentType != nil,
              rawStremioStreamOrdinal == nil || stremioStreamOrdinal != nil,
              rawStremioFingerprint == nil || stremioStreamFingerprint != nil,
              rawStremioSubtitleOrdinal == nil || stremioSubtitleOrdinal != nil,
              rawStremioSubtitleFingerprint == nil || stremioSubtitleFingerprint != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .stremioContentID,
                in: container,
                debugDescription: "Invalid Stremio selection payload"
            )
        }
        skyStream = try container.decodeIfPresent(SkyStreamProviderContentReference.self, forKey: .skyStream)
        nuvio = try container.decodeIfPresent(NuvioProviderContentReference.self, forKey: .nuvio)

        switch kind {
        case .service where serviceHref == nil || !sourceID.hasPrefix("service:"),
             .stremio where !hasValidStremioSelection,
             .skyStream where skyStream == nil
                || skyStream?.sourceID != sourceID
                || skyStream?.isStructurallyValid != true,
             .nuvio where nuvio == nil
                || nuvio?.sourceID != sourceID
                || nuvio?.isStructurallyValid != true:
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
        try container.encodeIfPresent(stremioContentType, forKey: .stremioContentType)
        try container.encodeIfPresent(stremioStreamOrdinal, forKey: .stremioStreamOrdinal)
        try container.encodeIfPresent(stremioStreamFingerprint, forKey: .stremioStreamFingerprint)
        try container.encodeIfPresent(stremioSubtitleOrdinal, forKey: .stremioSubtitleOrdinal)
        try container.encodeIfPresent(
            stremioSubtitleFingerprint,
            forKey: .stremioSubtitleFingerprint
        )
        try container.encodeIfPresent(skyStream, forKey: .skyStream)
        try container.encodeIfPresent(nuvio, forKey: .nuvio)
    }

    private static func bounded(_ value: String?, maximumUTF8Bytes: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumUTF8Bytes else { return nil }
        return trimmed
    }

    var hasValidStremioSelection: Bool {
        guard kind == .stremio,
              sourceID.hasPrefix("stremio:"),
              UUID(uuidString: String(sourceID.dropFirst("stremio:".count))) != nil,
              stremioContentID != nil,
              stremioContentType != nil,
              stremioStreamOrdinal != nil,
              stremioSubtitleFingerprint == nil || stremioSubtitleOrdinal != nil else {
            return false
        }
        return stremioStreamFingerprint == nil
            || Self.validatedFingerprint(stremioStreamFingerprint) != nil
    }

    func selects(stremio stream: StremioStream, ordinal: Int) -> Bool {
        if let expected = stremioStreamFingerprint {
            return Self.stremioSelectionFingerprint(for: stream) == expected
        }
        return ordinal == stremioStreamOrdinal
    }

    func selectStremioStream(from streams: [StremioStream]) -> StremioStream? {
        guard let preferredOrdinal = stremioStreamOrdinal else { return nil }
        guard stremioStreamFingerprint != nil else {
            return streams.indices.contains(preferredOrdinal) ? streams[preferredOrdinal] : nil
        }
        let matches = streams.enumerated().filter { index, stream in
            selects(stremio: stream, ordinal: index)
        }
        if let exact = matches.first(where: { $0.offset == preferredOrdinal }) {
            return exact.element
        }
        return matches.min { lhs, rhs in
            let lhsDistance = abs(lhs.offset - preferredOrdinal)
            let rhsDistance = abs(rhs.offset - preferredOrdinal)
            return lhsDistance == rhsDistance
                ? lhs.offset < rhs.offset
                : lhsDistance < rhsDistance
        }?.element
    }

    func selectStremioSubtitleIndex(from subtitles: [StremioSubtitle]) -> Int? {
        guard let preferredOrdinal = stremioSubtitleOrdinal else { return nil }
        guard let expectedFingerprint = stremioSubtitleFingerprint else {
            return subtitles.indices.contains(preferredOrdinal) ? preferredOrdinal : nil
        }
        let matches = subtitles.indices.filter {
            Self.stremioSubtitleSelectionFingerprint(for: subtitles[$0])
                == expectedFingerprint
        }
        if matches.contains(preferredOrdinal) { return preferredOrdinal }
        return matches.min { lhs, rhs in
            let lhsDistance = abs(lhs - preferredOrdinal)
            let rhsDistance = abs(rhs - preferredOrdinal)
            return lhsDistance == rhsDistance ? lhs < rhs : lhsDistance < rhsDistance
        }
    }

    private static func validatedStremioContentType(_ value: String?) -> String? {
        guard let value = bounded(value, maximumUTF8Bytes: 64) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }

    private static func validatedOrdinal(_ value: Int?, upperBound: Int) -> Int? {
        guard let value, (0..<upperBound).contains(value) else { return nil }
        return value
    }

    private static func validatedFingerprint(_ value: String?) -> String? {
        guard let value = bounded(value, maximumUTF8Bytes: 64), value.count == 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value)
                      || (97...102).contains(scalar.value)
              }) else {
            return nil
        }
        return value
    }

    private static func stremioSelectionFingerprint(for stream: StremioStream) -> String? {
        let rawFields = [
            stream.name,
            stream.title,
            stream.description,
            stream.behaviorHints?.bingeGroup,
            stream.behaviorHints?.filename,
            stream.lang,
            stream.language
        ] + Array((stream.languages ?? []).prefix(8)).map(Optional.some)
        var fields: [String] = []
        var totalBytes = 0
        for raw in rawFields {
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  value.utf8.count <= 1_024 else { continue }
            totalBytes += value.utf8.count
            guard totalBytes <= 8 * 1_024 else { break }
            fields.append(value.lowercased())
        }
        guard !fields.isEmpty else { return nil }
        return SHA256.hash(data: Data(fields.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func stremioSubtitleSelectionFingerprint(
        for subtitle: StremioSubtitle
    ) -> String? {
        let fields = [subtitle.id, subtitle.lang, subtitle.name, subtitle.title]
            .compactMap { rawValue -> String? in
                guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty,
                      value.utf8.count <= 1_024 else { return nil }
                return value.lowercased()
            }
        guard !fields.isEmpty else { return nil }
        return SHA256.hash(data: Data(fields.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
