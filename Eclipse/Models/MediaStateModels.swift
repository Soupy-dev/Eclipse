import CoreFoundation
import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum MediaStateKind: String, Codable, CaseIterable, Sendable {
    case libraryCollection
    case libraryMembership
    case movieProgress
    case episodeProgress
    case showMetadata
    case hiddenUpNext
    case rating
    case setting
    case catalogOrder
    case skyStreamMetadata
    case profile

    var isProfileScoped: Bool {
        switch self {
        case .libraryCollection, .libraryMembership, .movieProgress, .episodeProgress,
             .showMetadata, .hiddenUpNext, .rating, .catalogOrder, .setting,
             .skyStreamMetadata:
            return true
        case .profile:
            return false
        }
    }
}

enum MediaStateSettingScope: String, Codable, Sendable {
    case shared
    case iOS
    case tvOS
    case macOS

    var appliesToCurrentPlatform: Bool {
        switch self {
        case .shared:
            return true
        case .iOS:
#if os(iOS)
            return true
#else
            return false
#endif
        case .tvOS:
#if os(tvOS)
            return true
#else
            return false
#endif
        case .macOS:
            return false
        }
    }
}

struct MediaStateEnvelope: Codable, Equatable, Sendable {

    static let schemaVersion = 3
    static let maximumPayloadBytes = 800 * 1024

    static func nextRevision(after revision: Int64) -> Int64 {
        revision < Int64.max ? revision + 1 : Int64.max
    }

    let recordName: String
    let kind: MediaStateKind
    var payload: Data
    var modifiedAt: Date
    var deletedAt: Date?
    var revision: Int64
    var settingScope: MediaStateSettingScope
    var isCompleted: Bool
    var isExplicitReset: Bool

    var resetAt: Date?
    var schemaVersion: Int
    var systemFields: Data?

    init(
        recordName: String,
        kind: MediaStateKind,
        payload: Data,
        modifiedAt: Date,
        deletedAt: Date? = nil,
        revision: Int64 = 1,
        settingScope: MediaStateSettingScope = .shared,
        isCompleted: Bool = false,
        isExplicitReset: Bool = false,
        resetAt: Date? = nil,
        schemaVersion: Int = MediaStateEnvelope.schemaVersion,
        systemFields: Data? = nil
    ) {
        self.recordName = recordName
        self.kind = kind
        self.payload = payload
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
        self.revision = revision
        self.settingScope = settingScope
        self.isCompleted = isCompleted
        self.isExplicitReset = isExplicitReset
        self.resetAt = resetAt
        self.schemaVersion = schemaVersion
        self.systemFields = systemFields
    }

    var isDeleted: Bool { deletedAt != nil }

    private var progressResetAt: Date? {
        resetAt ?? (isExplicitReset ? modifiedAt : nil)
    }

    private func isDeterministicallyAfter(_ other: MediaStateEnvelope) -> Bool {
        if modifiedAt != other.modifiedAt { return modifiedAt > other.modifiedAt }
        if revision != other.revision { return revision > other.revision }
        if isDeleted != other.isDeleted { return isDeleted }
        if deletedAt != other.deletedAt {
            return (deletedAt ?? .distantPast) > (other.deletedAt ?? .distantPast)
        }
        if isExplicitReset != other.isExplicitReset { return isExplicitReset }
        if resetAt != other.resetAt {
            return (resetAt ?? .distantPast) > (other.resetAt ?? .distantPast)
        }
        if isCompleted != other.isCompleted { return isCompleted }
        if schemaVersion != other.schemaVersion { return schemaVersion > other.schemaVersion }
        if settingScope.rawValue != other.settingScope.rawValue {
            return settingScope.rawValue > other.settingScope.rawValue
        }
        if recordName != other.recordName { return recordName > other.recordName }
        if kind.rawValue != other.kind.rawValue { return kind.rawValue > other.kind.rawValue }
        if payload != other.payload {
            return other.payload.lexicographicallyPrecedes(payload)
        }
        if systemFields != other.systemFields {
            switch (systemFields, other.systemFields) {
            case (.some(let lhs), .some(let rhs)):
                return rhs.lexicographicallyPrecedes(lhs)
            case (.some(_), .none):
                return true
            case (.none, .some(_)), (.none, .none):
                return false
            }
        }
        return false
    }

    func merged(with candidate: MediaStateEnvelope) -> MediaStateEnvelope {
        guard recordName == candidate.recordName, kind == candidate.kind else {
            return candidate.isDeterministicallyAfter(self) ? candidate : self
        }

        if isDeleted || candidate.isDeleted {
            let lhsDate = deletedAt ?? modifiedAt
            let rhsDate = candidate.deletedAt ?? candidate.modifiedAt
            if rhsDate != lhsDate { return rhsDate > lhsDate ? candidate : self }

            if isDeleted != candidate.isDeleted { return candidate.isDeleted ? candidate : self }
            return candidate.isDeterministicallyAfter(self) ? candidate : self
        }

        if kind == .profile,
           let localProfile = try? Self.payloadDecoder().decode(Profile.self, from: payload),
           let candidateProfile = try? Self.payloadDecoder().decode(Profile.self, from: candidate.payload),
           localProfile.id == candidateProfile.id,
           !localProfile.hasRejectedPINHash,
           !candidateProfile.hasRejectedPINHash {
            let winner: MediaStateEnvelope
            let loserProfile: Profile
            let winnerProfile: Profile
            if candidate.profileGeneralValueIsAfter(
                self,
                ownProfile: candidateProfile,
                otherProfile: localProfile
            ) {
                winner = candidate
                loserProfile = localProfile
                winnerProfile = candidateProfile
            } else {
                winner = self
                loserProfile = candidateProfile
                winnerProfile = localProfile
            }
            let mergedProfile = loserProfile.applyingSyncedRecord(winnerProfile)
            guard let mergedPayload = Self.stableProfileData(mergedProfile),
                  mergedPayload.count <= Self.maximumPayloadBytes else {
                return winner
            }
            var result = winner
            result.payload = mergedPayload
            return result
        }

        if kind == .movieProgress || kind == .episodeProgress {
            let newestReset = [progressResetAt, candidate.progressResetAt].compactMap { $0 }.max()
            let completedCandidates = [self, candidate].filter(\.isCompleted)
            if let completedWinner = completedCandidates.max(by: { lhs, rhs in
                rhs.isDeterministicallyAfter(lhs)
            }), newestReset.map({ completedWinner.modifiedAt > $0 }) ?? true {
                var result = completedWinner
                result.resetAt = nil
                result.isExplicitReset = false
                return result
            }
            let eligible = newestReset == nil
                ? [self, candidate]
                : [self, candidate].filter { !$0.isCompleted }
            guard var winner = eligible.max(by: { lhs, rhs in
                rhs.isDeterministicallyAfter(lhs)
            }) else {
                return candidate.isDeterministicallyAfter(self) ? candidate : self
            }
            if let newestReset {
                winner.resetAt = newestReset

                if winner.modifiedAt != newestReset {
                    winner.isExplicitReset = false
                }
            }
            return winner
        }

        if candidate.modifiedAt != modifiedAt {
            return candidate.modifiedAt > modifiedAt ? candidate : self
        }
        if candidate.revision != revision {
            return candidate.revision > revision ? candidate : self
        }
        return candidate.isDeterministicallyAfter(self) ? candidate : self
    }

    func tombstone(at date: Date = Date()) -> MediaStateEnvelope {
        var result = self
        result.payload = Data()
        result.modifiedAt = date
        result.deletedAt = date
        result.revision = Self.nextRevision(after: result.revision)
        result.isCompleted = false
        result.isExplicitReset = false
        result.resetAt = nil
        return result
    }

    static func stableProfileData(_ profile: Profile) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(profile)
    }

    private static func payloadDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func profileGeneralData(_ profile: Profile) -> Data {
        var general = profile
        general.pinHash = nil
        general.pinChangedAt = nil
        general.isKidsProfile = false
        general.kidsFlagChangedAt = nil
        return stableProfileData(general) ?? Data()
    }

    private func profileGeneralValueIsAfter(
        _ other: MediaStateEnvelope,
        ownProfile: Profile,
        otherProfile: Profile
    ) -> Bool {
        if modifiedAt != other.modifiedAt { return modifiedAt > other.modifiedAt }
        if revision != other.revision { return revision > other.revision }
        let ownGeneral = Self.profileGeneralData(ownProfile)
        let otherGeneral = Self.profileGeneralData(otherProfile)
        if ownGeneral != otherGeneral {
            return otherGeneral.lexicographicallyPrecedes(ownGeneral)
        }
        if systemFields != other.systemFields {
            switch (systemFields, other.systemFields) {
            case (.some(let lhs), .some(let rhs)):
                return rhs.lexicographicallyPrecedes(lhs)
            case (.some(_), .none):
                return true
            case (.none, .some(_)), (.none, .none):
                return false
            }
        }
        return false
    }
}

/// CloudKit has to remain writable against the already-deployed Production
/// schema. Reset lineage therefore travels inside the existing opaque payload
/// field instead of requiring a new CKRecord field. The marker is a valid,
/// unknown JSON member, so older Eclipse builds can still decode progress
/// payloads. Removing the exact prefix restores the original payload bytes.
enum MediaStateCloudKitPayloadCodec {
    struct Decoded: Equatable {
        let payload: Data
        let resetAt: Date?
    }

    static let resetLineageKey = "__eclipseMediaStateCloudKitV1"

    private static let markerValuePrefix = "resetAtMilliseconds:"
    private static let payloadHashSeparator = ":payloadSHA256:"
    private static let jsonMarkerPrefix = Data(
        "\"\(resetLineageKey)\":\"\(markerValuePrefix)".utf8
    )
    private static let quote = UInt8(ascii: "\"")
    private static let comma = UInt8(ascii: ",")
    private static let openingBrace = UInt8(ascii: "{")
    private static let closingBrace = UInt8(ascii: "}")

    static func wirePrecisionDate(_ date: Date) -> Date {
        Date(
            timeIntervalSince1970:
                (date.timeIntervalSince1970 * 1_000).rounded() / 1_000
        )
    }

    static func resetAtClampedForWirePrecision(
        _ resetAt: Date?,
        modifiedAt: Date
    ) -> Date? {
        guard let resetAt else { return nil }
        if resetAt > modifiedAt,
           resetAt.timeIntervalSince(modifiedAt) < 0.001 {
            // A reset and its progress record share millisecond wire
            // precision. Clamp only a rounding-sized inversion; a genuinely
            // newer lineage remains invalid and is rejected by validation.
            return modifiedAt
        }
        return resetAt
    }

    static func encode(payload: Data, resetAt: Date?) -> Data? {
        guard let resetAt else {
            return payload.count <= MediaStateEnvelope.maximumPayloadBytes
                ? payload
                : nil
        }
        guard MediaStateEnvelopeValidator.isPlausibleClock(resetAt) else {
            return nil
        }
        let millisecondsValue = wirePrecisionDate(resetAt).timeIntervalSince1970 * 1_000
        guard millisecondsValue.isFinite,
              millisecondsValue >= 0,
              let milliseconds = Int64(exactly: millisecondsValue.rounded()) else {
            return nil
        }
        guard let openingBraceIndex = firstNonWhitespaceIndex(in: payload),
              payload[openingBraceIndex] == openingBrace,
              let firstContentIndex = payload[payload.index(after: openingBraceIndex)...]
                .firstIndex(where: { !isJSONWhitespace($0) }),
              payload[firstContentIndex] != closingBrace else {
            return nil
        }

        var marker = jsonMarkerPrefix
        marker.append(contentsOf: String(milliseconds).utf8)
        marker.append(contentsOf: payloadHashSeparator.utf8)
        marker.append(contentsOf: payloadSHA256(payload).utf8)
        marker.append(quote)
        marker.append(comma)

        var encoded = payload
        encoded.insert(contentsOf: marker, at: payload.index(after: openingBraceIndex))
        guard encoded.count <= MediaStateEnvelope.maximumPayloadBytes else {
            return nil
        }
        return encoded
    }

    static func decode(_ wirePayload: Data) -> Decoded? {
        guard wirePayload.count <= MediaStateEnvelope.maximumPayloadBytes else {
            return nil
        }
        guard let openingBraceIndex = firstNonWhitespaceIndex(in: wirePayload),
              wirePayload[openingBraceIndex] == openingBrace else {
            return Decoded(payload: wirePayload, resetAt: nil)
        }

        let markerStart = wirePayload.index(after: openingBraceIndex)
        guard wirePayload[markerStart...].starts(with: jsonMarkerPrefix) else {
            return Decoded(payload: wirePayload, resetAt: nil)
        }
        let valueStart = wirePayload.index(markerStart, offsetBy: jsonMarkerPrefix.count)
        guard let quoteIndex = wirePayload[valueStart...].firstIndex(of: quote),
              quoteIndex > valueStart,
              let markerValue = String(
                data: wirePayload[valueStart..<quoteIndex],
                encoding: .utf8
              ) else {
            return Decoded(payload: wirePayload, resetAt: nil)
        }
        let commaIndex = wirePayload.index(after: quoteIndex)
        let components = markerValue.components(separatedBy: payloadHashSeparator)
        guard commaIndex < wirePayload.endIndex,
              wirePayload[commaIndex] == comma,
              components.count == 2 else {
            return Decoded(payload: wirePayload, resetAt: nil)
        }
        let millisecondsText = components[0]
        let expectedPayloadHash = components[1]
        guard expectedPayloadHash.count == 64,
              expectedPayloadHash.allSatisfy({ $0.isHexDigit }),
              !millisecondsText.isEmpty,
              millisecondsText.allSatisfy(\.isNumber),
              let milliseconds = Int64(millisecondsText) else {
            return Decoded(payload: wirePayload, resetAt: nil)
        }

        var payload = wirePayload
        payload.removeSubrange(markerStart...commaIndex)
        guard payloadSHA256(payload) == expectedPayloadHash else {
            return Decoded(payload: wirePayload, resetAt: nil)
        }
        return Decoded(
            payload: payload,
            resetAt: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        )
    }

    private static func firstNonWhitespaceIndex(in data: Data) -> Data.Index? {
        data.firstIndex { !isJSONWhitespace($0) }
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x09, 0x0A, 0x0D, 0x20:
            return true
        default:
            return false
        }
    }

    private static func payloadSHA256(_ payload: Data) -> String {
        SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum MediaStateCloudKitArchiveMigration {
    static func repaired(_ envelope: MediaStateEnvelope) -> MediaStateEnvelope {
        var repaired = envelope
        if let decoded = MediaStateCloudKitPayloadCodec.decode(envelope.payload),
           let resetAt = decoded.resetAt {
            repaired.payload = decoded.payload
            repaired.resetAt = MediaStateCloudKitPayloadCodec.resetAtClampedForWirePrecision(
                resetAt,
                modifiedAt: repaired.modifiedAt
            )
        }
        if repaired.resetAt == nil,
           (repaired.kind == .movieProgress || repaired.kind == .episodeProgress),
           repaired.isExplicitReset {
            repaired.resetAt = repaired.modifiedAt
        }
        return repaired
    }
}

enum MediaStateEnvelopeValidator {

    static let maximumRemoteRecordCount = 100_000
    static let maximumRemoteLiveProfileRecords = ProfileManager.maximumProfiles * 2
    static let maximumRecordNameBytes = 1_024
    static let maximumFutureClockSkew: TimeInterval = 30 * 24 * 60 * 60

    static let plausibleClockFloor = Date(timeIntervalSince1970: 0)

    static func isPlausibleClock(_ date: Date, now: Date = Date()) -> Bool {
        let value = date.timeIntervalSince1970
        return value.isFinite
            && value >= 0
            && value <= now.timeIntervalSince1970 + maximumFutureClockSkew
    }

    static func normalizingImplausibleClocks(
        of envelope: MediaStateEnvelope,
        now: Date = Date()
    ) -> MediaStateEnvelope {
        var result = envelope
        if !isPlausibleClock(result.modifiedAt, now: now) {
            let seconds = result.modifiedAt.timeIntervalSince1970
            result.modifiedAt = seconds.isFinite && seconds >= 0
                ? now
                : (payloadClock(of: result, now: now) ?? plausibleClockFloor)
        }
        if let deletedAt = result.deletedAt, !isPlausibleClock(deletedAt, now: now) {
            result.deletedAt = result.modifiedAt
        }
        if let resetAt = result.resetAt, !isPlausibleClock(resetAt, now: now) {
            result.resetAt = result.modifiedAt
        }
        return result
    }

    private static func payloadClock(of envelope: MediaStateEnvelope, now: Date) -> Date? {
        guard !envelope.isDeleted, !envelope.payload.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let clock: Date?
        switch envelope.kind {
        case .movieProgress:
            clock = (try? decoder.decode(MovieProgressEntry.self, from: envelope.payload))?.lastUpdated
        case .episodeProgress:
            clock = (try? decoder.decode(EpisodeProgressEntry.self, from: envelope.payload))?.lastUpdated
        case .libraryMembership:
            clock = (try? decoder.decode(LibraryMembershipIdentity.self, from: envelope.payload))?.item.dateAdded
        case .profile:
            clock = (try? decoder.decode(Profile.self, from: envelope.payload))?.createdAt
        default:
            clock = nil
        }
        guard let clock, isPlausibleClock(clock, now: now) else { return nil }
        return clock
    }

    static func rejectionReason(
        for records: [String: MediaStateEnvelope],
        allowsSystemFields: Bool
    ) -> String? {
        if let reason = aggregateRejectionReason(
            for: records,
            allowsSystemFields: allowsSystemFields
        ) {
            return reason
        }
        for key in records.keys.sorted() {
            guard let envelope = records[key] else { continue }
            if let reason = rejectionReason(
                for: envelope,
                dictionaryKey: key,
                allowsSystemFields: allowsSystemFields
            ) {
                return "\(key): \(reason)"
            }
        }
        return nil
    }

    static func aggregateRejectionReason(
        for records: [String: MediaStateEnvelope],
        allowsSystemFields: Bool
    ) -> String? {
        guard !allowsSystemFields else { return nil }
        guard records.count <= maximumRemoteRecordCount else {
            return "record count exceeds \(maximumRemoteRecordCount)"
        }
        return nil
    }

    static func liveProfileRecordCount(in records: [String: MediaStateEnvelope]) -> Int {
        records.values.lazy
            .filter { $0.kind == .profile && !$0.isDeleted }
            .count
    }

    static func rosterOverflowDescription(
        in records: [String: MediaStateEnvelope]
    ) -> String? {
        let live = liveProfileRecordCount(in: records)
        guard live > maximumRemoteLiveProfileRecords else { return nil }
        return "\(live) live profile records, above the \(maximumRemoteLiveProfileRecords) a merged bundle is expected to carry"
    }

    static func structurallyValidRemoteRecords(
        _ records: [String: MediaStateEnvelope]
    ) -> (
        records: [String: MediaStateEnvelope],
        droppedRecordNames: [String],
        repairedRecordNames: [String]
    ) {
        var accepted: [String: MediaStateEnvelope] = [:]
        var dropped: [String] = []
        var repaired: [String] = []
        accepted.reserveCapacity(records.count)
        for (key, envelope) in records {
            if rejectionReason(
                for: envelope,
                dictionaryKey: key,
                allowsSystemFields: false
            ) == nil {
                accepted[key] = envelope
            } else if let safe = repairingInvalidNestedProgressContext(
                in: envelope,
                dictionaryKey: key
            ) {
                accepted[key] = safe
                repaired.append(key)
            } else {
                dropped.append(key)
            }
        }
        return (accepted, dropped.sorted(), repaired.sorted())
    }

    private static func repairingInvalidNestedProgressContext(
        in envelope: MediaStateEnvelope,
        dictionaryKey: String
    ) -> MediaStateEnvelope? {
        guard envelope.kind == .episodeProgress,
              !envelope.isDeleted else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard var episode = try? decoder.decode(EpisodeProgressEntry.self, from: envelope.payload),
              let context = episode.playbackContext,
              ProgressPersistencePolicy.sanitizedPlaybackContext(
                context,
                expectedLocalEpisodeNumber: episode.episodeNumber
              ) == nil else {
            return nil
        }
        episode.playbackContext = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let payload = try? encoder.encode(episode),
              payload.count <= MediaStateEnvelope.maximumPayloadBytes else { return nil }
        var repaired = envelope
        repaired.payload = payload
        guard rejectionReason(
            for: repaired,
            dictionaryKey: dictionaryKey,
            allowsSystemFields: false
        ) == nil else { return nil }
        return repaired
    }

    static func rejectionReason(
        for envelope: MediaStateEnvelope,
        dictionaryKey: String,
        allowsSystemFields: Bool
    ) -> String? {
        guard dictionaryKey == envelope.recordName else {
            return "dictionary key does not match recordName"
        }
        guard !envelope.recordName.isEmpty,
              envelope.recordName.utf8.count <= maximumRecordNameBytes else {
            return "recordName is empty or oversized"
        }
        guard MediaStateRecordName.kind(from: envelope.recordName) == envelope.kind else {
            return "recordName kind does not match envelope kind"
        }
        guard envelope.schemaVersion >= 1,
              envelope.schemaVersion <= MediaStateEnvelope.schemaVersion else {
            return "unsupported schema version"
        }
        guard envelope.revision >= 0 else {
            return "invalid revision"
        }
        guard isPlausibleClock(envelope.modifiedAt),
              envelope.deletedAt.map({ isPlausibleClock($0) }) ?? true,
              envelope.resetAt.map({ isPlausibleClock($0) }) ?? true else {
            return "invalid or implausible timestamp"
        }
        guard envelope.payload.count <= MediaStateEnvelope.maximumPayloadBytes else {
            return "payload exceeds the per-record limit"
        }
        guard envelope.kind == .setting || envelope.settingScope == .shared else {
            return "non-setting record carries a platform setting scope"
        }
        if envelope.kind != .movieProgress && envelope.kind != .episodeProgress,
           envelope.isCompleted || envelope.isExplicitReset || envelope.resetAt != nil {
            return "non-progress record carries progress flags"
        }
        guard !(envelope.isCompleted && envelope.isExplicitReset) else {
            return "progress record is both completed and explicitly reset"
        }
        guard !envelope.isCompleted || envelope.resetAt == nil else {
            return "completed progress retains a reset lineage"
        }
        if let resetAt = envelope.resetAt {
            guard resetAt <= envelope.modifiedAt else {
                return "progress reset lineage is newer than the record"
            }
        }
        if envelope.schemaVersion >= 3, envelope.isExplicitReset {
            guard let resetAt = envelope.resetAt,
                  abs(resetAt.timeIntervalSince(envelope.modifiedAt)) < 0.001 else {
                return "explicit reset has no matching reset lineage"
            }
        }
        guard allowsSystemFields || envelope.systemFields == nil else {
            return "remote bundle contains CloudKit system fields"
        }
        guard let identifier = MediaStateRecordName.identifier(from: envelope.recordName),
              !identifier.isEmpty else {
            return "recordName has no identifier"
        }
        let canonicalName: String
        if envelope.kind == .profile {
            canonicalName = MediaStateRecordName.make(kind: .profile, identifier: identifier)
        } else if envelope.kind.isProfileScoped {
            canonicalName = MediaStateRecordName.make(
                kind: envelope.kind,
                identifier: identifier,
                profileID: MediaStateRecordName.profileID(from: envelope.recordName)
            )
        } else {
            canonicalName = MediaStateRecordName.make(kind: envelope.kind, identifier: identifier)
        }
        guard canonicalName == envelope.recordName else {
            return "recordName is not canonical"
        }

        if envelope.isDeleted {
            guard envelope.payload.isEmpty,
                  !envelope.isCompleted,
                  !envelope.isExplicitReset,
                  envelope.resetAt == nil,
                  envelope.deletedAt == envelope.modifiedAt else {
                return "tombstone carries live payload or progress flags"
            }
            if envelope.kind == .profile,
               UUID(uuidString: identifier)?.uuidString.lowercased() != identifier {
                return "profile tombstone identifier is not a canonical UUID"
            }
            return nil
        }
        guard !envelope.payload.isEmpty else { return "live record has an empty payload" }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        switch envelope.kind {
        case .profile:
            guard let profileID = UUID(uuidString: identifier),
                  profileID.uuidString.lowercased() == identifier,
                  let profile = try? decoder.decode(Profile.self, from: envelope.payload),
                  profile.id == profileID,
                  !profile.hasRejectedPINHash,
                  !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  isPlausibleClock(profile.createdAt),
                  profile.pinChangedAt.map({ isPlausibleClock($0) }) ?? true,
                  profile.kidsFlagChangedAt.map({ isPlausibleClock($0) }) ?? true,
                  (profile.avatarPhotoData?.count ?? 0) <= ProfileAvatar.maximumPhotoBytes else {
                return "profile payload identity or invariants are invalid"
            }
        case .libraryCollection:
            guard let value = try? decoder.decode(LibraryCollectionIdentity.self, from: envelope.payload),
                  value.key == identifier else {
                return "collection payload does not match its record identifier"
            }
        case .libraryMembership:
            guard let value = try? decoder.decode(LibraryMembershipIdentity.self, from: envelope.payload) else {
                return "membership payload does not decode"
            }
            guard let sanitizedResult = value.item.searchResult.sanitizedForPersistence,
                  sanitizedResult.id == value.item.searchResult.id,
                  sanitizedResult.mediaType == value.item.searchResult.mediaType else {
                return "membership payload contains an invalid media identity"
            }
            let currentIdentifier = "\(value.collectionKey):\(value.item.searchResult.stableIdentity)"
            let legacyIdentifier = "\(value.collectionKey):\(value.item.searchResult.id)"
            guard identifier == currentIdentifier || identifier == legacyIdentifier else {
                return "membership payload does not match its record identifier"
            }
        case .movieProgress:
            guard let value = try? decoder.decode(MovieProgressEntry.self, from: envelope.payload),
                  ProgressPersistencePolicy.validPositiveIdentifier(value.id),
                  identifier == String(value.id),
                  value.currentTime.isFinite,
                  value.totalDuration.isFinite,
                  isPlausibleClock(value.lastUpdated),
                  value.currentTime >= 0,
                  value.totalDuration >= 0,
                  value.currentTime <= ProgressPersistencePolicy.maximumDuration,
                  value.totalDuration <= ProgressPersistencePolicy.maximumDuration,
                  value.totalDuration > 0 || value.currentTime == 0,
                  value.currentTime <= value.totalDuration || value.totalDuration == 0,
                  value.lastHref == nil,
                  value.lastContentReference == nil,
                  !envelope.isExplicitReset || (value.currentTime == 0 && !value.isWatched),
                  envelope.isCompleted == (value.isWatched || value.progress >= 0.85) else {
                return "movie progress payload does not match its record identifier"
            }
        case .episodeProgress:
            guard let value = try? decoder.decode(EpisodeProgressEntry.self, from: envelope.payload),
                  ProgressPersistencePolicy.validPositiveIdentifier(value.showId),
                  ProgressPersistencePolicy.validSeasonCoordinate(value.seasonNumber),
                  (1...ProgressPersistencePolicy.maximumCoordinate).contains(value.episodeNumber),
                  value.id == "ep_\(value.showId)_s\(value.seasonNumber)_e\(value.episodeNumber)",
                  identifier == value.id,
                  value.currentTime.isFinite,
                  value.totalDuration.isFinite,
                  isPlausibleClock(value.lastUpdated),
                  value.currentTime >= 0,
                  value.totalDuration >= 0,
                  value.currentTime <= ProgressPersistencePolicy.maximumDuration,
                  value.totalDuration <= ProgressPersistencePolicy.maximumDuration,
                  value.totalDuration > 0 || value.currentTime == 0,
                  value.currentTime <= value.totalDuration || value.totalDuration == 0,
                  value.lastHref == nil,
                  value.lastContentReference == nil,
                  value.playbackContext.map({ context in
                      ProgressPersistencePolicy.sanitizedPlaybackContext(
                        context,
                        expectedLocalEpisodeNumber: value.episodeNumber
                      ) == context
                  }) ?? true,
                  !envelope.isExplicitReset || (value.currentTime == 0 && !value.isWatched),
                  envelope.isCompleted == (value.isWatched || value.progress >= 0.85) else {
                return "episode progress payload does not match its record identifier"
            }
        case .showMetadata:
            guard let value = try? decoder.decode(ShowMetadata.self, from: envelope.payload),
                  ProgressPersistencePolicy.validPositiveIdentifier(value.showId),
                  identifier == String(value.showId) else {
                return "show metadata payload does not match its record identifier"
            }
        case .hiddenUpNext:
            guard let hiddenID = Int(identifier),
                  ProgressPersistencePolicy.validPositiveIdentifier(hiddenID),
                  let value = try? decoder.decode(BooleanIdentity.self, from: envelope.payload),
                  value.value else {
                return "hidden Up Next payload is invalid"
            }
        case .rating:
            guard let value = try? decoder.decode(RatingIdentity.self, from: envelope.payload),
                  ProgressPersistencePolicy.validPositiveIdentifier(value.tmdbID),
                  identifier == String(value.tmdbID),
                  value.rating != nil || value.note != nil,
                  value.rating.map({ rating in
                      rating.isFinite && rating >= 0.5 && rating <= 10
                          && (rating * 2).rounded() == rating * 2
                  }) ?? true,
                  value.note.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true else {
                return "rating payload does not match its record identifier"
            }
        case .setting:
            let recordSegments = envelope.recordName.split(
                separator: "|",
                omittingEmptySubsequences: false
            )
            let hasExplicitProfileSegment = recordSegments.count == 3 &&
                UUID(uuidString: String(recordSegments[1])) != nil
            let storageScope = EclipseSettingsRegistry.scope(for: identifier)
            let profileShapeIsValid = storageScope == .profile || !hasExplicitProfileSegment
            guard MediaStateSettingRegistry.allKeys.contains(identifier),
                  profileShapeIsValid,
                  (MediaStateSettingRegistry.scope(for: identifier) == envelope.settingScope ||
                    MediaStateSettingRegistry.acceptsPreviousScope(
                        envelope.settingScope,
                        for: identifier
                    ) ||
                    (envelope.schemaVersion == 1 && envelope.settingScope == .shared)),
                  MediaStateSettingValueValidator.validatedValue(
                    from: envelope.payload,
                    forKey: identifier
                  ) != nil else {
                return "setting key, scope or payload is invalid"
            }
        case .catalogOrder:
            guard identifier == "home",
                  let catalogs = try? decoder.decode([Catalog].self, from: envelope.payload),
                  !catalogs.isEmpty,
                  Set(catalogs.map(\.id)).count == catalogs.count else {
                return "catalog payload is invalid"
            }
        case .skyStreamMetadata:
            guard identifier == "safe-cloud-v1",
                  (try? SkyStreamMediaStateDocument.decodeMetadataOnly(envelope.payload)) != nil else {
                return "SkyStream metadata identifier is invalid"
            }
        }
        return nil
    }

    private struct LibraryCollectionIdentity: Decodable {
        let key: String
    }

    private struct LibraryMembershipIdentity: Decodable {
        let collectionKey: String
        let item: LibraryItem
    }

    private struct RatingIdentity: Decodable {
        let tmdbID: Int
        let rating: Double?
        let note: String?
    }

    private struct BooleanIdentity: Decodable {
        let value: Bool
    }
}

enum MediaStateAccountBoundaryAuthority {
    static func replacing(
        existing: [String: MediaStateEnvelope],
        selected: [String: MediaStateEnvelope],
        rejected: [String: MediaStateEnvelope] = [:],
        now: Date = Date()
    ) -> [String: MediaStateEnvelope]? {
        guard MediaStateEnvelopeValidator.rejectionReason(
            for: selected,
            allowsSystemFields: false
        ) == nil,
        MediaStateEnvelopeValidator.rejectionReason(
            for: rejected,
            allowsSystemFields: false
        ) == nil else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]

        func authorityRelevantClock(_ envelope: MediaStateEnvelope) -> Date {
            var clock = max(
                envelope.modifiedAt,
                max(envelope.deletedAt ?? .distantPast, envelope.resetAt ?? .distantPast)
            )
            if envelope.kind == .profile,
               !envelope.isDeleted,
               let profile = try? decoder.decode(Profile.self, from: envelope.payload) {
                clock = max(clock, profile.pinChangedAt ?? .distantPast)
                clock = max(clock, profile.kidsFlagChangedAt ?? .distantPast)
            }
            return clock
        }

        let existingMaximum = existing.values.reduce(now) { partial, envelope in
            max(partial, authorityRelevantClock(envelope))
        }
        let selectedMaximum = selected.values.reduce(existingMaximum) { partial, envelope in
            max(partial, authorityRelevantClock(envelope))
        }
        let maximumObservedClock = rejected.values.reduce(selectedMaximum) { partial, envelope in
            max(partial, authorityRelevantClock(envelope))
        }

        let authorityTime = maximumObservedClock.addingTimeInterval(0.001)
        let horizon = now.addingTimeInterval(
            MediaStateEnvelopeValidator.maximumFutureClockSkew
        )
        guard authorityTime <= horizon else { return nil }

        var authoritative: [String: MediaStateEnvelope] = [:]
        authoritative.reserveCapacity(max(existing.count, selected.count + rejected.count))

        for (name, incoming) in selected {
            var adopted = incoming
            adopted.modifiedAt = authorityTime
            adopted.revision = MediaStateEnvelope.nextRevision(
                after: max(existing[name]?.revision ?? 0, incoming.revision)
            )
            adopted.schemaVersion = MediaStateEnvelope.schemaVersion
            adopted.systemFields = existing[name]?.systemFields
            if adopted.isDeleted {
                adopted.payload = Data()
                adopted.deletedAt = authorityTime
                adopted.isCompleted = false
                adopted.isExplicitReset = false
                adopted.resetAt = nil
            } else if adopted.isExplicitReset {
                adopted.resetAt = authorityTime
            }
            if !adopted.isDeleted,
               adopted.kind == .profile,
               var profile = try? decoder.decode(Profile.self, from: adopted.payload) {
                profile.pinChangedAt = authorityTime
                profile.kidsFlagChangedAt = authorityTime
                if let payload = try? encoder.encode(profile),
                   payload.count <= MediaStateEnvelope.maximumPayloadBytes {
                    adopted.payload = payload
                }
            }
            authoritative[name] = adopted
        }

        let namesToReject = Set(existing.keys).union(rejected.keys).subtracting(selected.keys)
        for name in namesToReject {
            guard var base = existing[name] ?? rejected[name] else { continue }
            let maximumRevision = max(
                existing[name]?.revision ?? 0,
                rejected[name]?.revision ?? 0
            )
            base = base.tombstone(at: authorityTime)
            base.revision = MediaStateEnvelope.nextRevision(after: maximumRevision)
            base.schemaVersion = MediaStateEnvelope.schemaVersion
            base.systemFields = existing[name]?.systemFields
            authoritative[name] = base
        }

        guard MediaStateEnvelopeValidator.rejectionReason(
            for: authoritative,
            allowsSystemFields: true
        ) == nil else {
            return nil
        }
        return authoritative
    }
}

enum MediaStatePendingAccountIsolationTarget: Codable, Equatable, Sendable {
    private static let maximumAccountRecordNameBytes = 1_024

    case account(recordName: String)
    case signedOut

    private enum Kind: String, Codable {
        case account
        case signedOut
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case accountRecordName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .account:
            let recordName = try container.decode(String.self, forKey: .accountRecordName)
            guard !recordName.isEmpty,
                  recordName.utf8.count <= Self.maximumAccountRecordNameBytes else {
                throw DecodingError.dataCorruptedError(
                    forKey: .accountRecordName,
                    in: container,
                    debugDescription: "Account-isolation target is empty or oversized"
                )
            }
            self = .account(recordName: recordName)
        case .signedOut:
            guard !container.contains(.accountRecordName) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .accountRecordName,
                    in: container,
                    debugDescription: "Signed-out isolation target carries an account identity"
                )
            }
            self = .signedOut
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .account(let recordName):
            guard !recordName.isEmpty,
                  recordName.utf8.count <= Self.maximumAccountRecordNameBytes else {
                throw EncodingError.invalidValue(
                    recordName,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Account-isolation target is empty or oversized"
                    )
                )
            }
            try container.encode(Kind.account, forKey: .kind)
            try container.encode(recordName, forKey: .accountRecordName)
        case .signedOut:
            try container.encode(Kind.signedOut, forKey: .kind)
        }
    }
}

struct MediaStateLocalArchive: Codable, Sendable {

    static let maximumPendingAccountIsolationProfileIDs =
        (ProfileManager.maximumProfiles * 2)
            + MediaStateEnvelopeValidator.maximumRemoteLiveProfileRecords
            + 1
    static let maximumDeferredApplyManagerPayloadHashes = 50_000

    var records: [String: MediaStateEnvelope]
    var lastLocalRecordNames: Set<String>

    var accountOwnerRecordName: String? = nil

    var ubiquityIdentityTokenData: Data? = nil

    var pendingLocalRecordNames: Set<String> = []

    var suppressedLocalRecordPayloadHashes: [String: String] = [:]
    var deferredApplyManagerPayloadHashes: [String: String] = [:]

    var isAccountNeutralLocalStateActive = false

    var hasDeliberateLocalCacheReset = false

    var pendingAccountIsolationProfileIDs: Set<UUID> = []

    var pendingAccountIsolationTarget: MediaStatePendingAccountIsolationTarget? = nil

    init(
        records: [String: MediaStateEnvelope],
        lastLocalRecordNames: Set<String>,
        accountOwnerRecordName: String? = nil,
        ubiquityIdentityTokenData: Data? = nil,
        pendingLocalRecordNames: Set<String> = [],
        suppressedLocalRecordPayloadHashes: [String: String] = [:],
        deferredApplyManagerPayloadHashes: [String: String] = [:],
        isAccountNeutralLocalStateActive: Bool = false,
        pendingAccountIsolationProfileIDs: Set<UUID> = [],
        pendingAccountIsolationTarget: MediaStatePendingAccountIsolationTarget? = nil
    ) {
        self.records = records
        self.lastLocalRecordNames = lastLocalRecordNames
        self.accountOwnerRecordName = accountOwnerRecordName
        self.ubiquityIdentityTokenData = ubiquityIdentityTokenData
        self.pendingLocalRecordNames = pendingLocalRecordNames
        self.suppressedLocalRecordPayloadHashes = suppressedLocalRecordPayloadHashes
        self.deferredApplyManagerPayloadHashes = deferredApplyManagerPayloadHashes
        self.isAccountNeutralLocalStateActive = isAccountNeutralLocalStateActive
        self.pendingAccountIsolationProfileIDs = pendingAccountIsolationProfileIDs
        self.pendingAccountIsolationTarget = pendingAccountIsolationTarget
    }

    private enum CodingKeys: String, CodingKey {
        case records
        case lastLocalRecordNames
        case accountOwnerRecordName
        case ubiquityIdentityTokenData
        case pendingLocalRecordNames
        case suppressedLocalRecordPayloadHashes
        case deferredApplyManagerPayloadHashes
        case isAccountNeutralLocalStateActive
        case pendingAccountIsolationProfileIDs
        case pendingAccountIsolationTarget
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decode([String: MediaStateEnvelope].self, forKey: .records)
        lastLocalRecordNames = try container.decode(Set<String>.self, forKey: .lastLocalRecordNames)
        accountOwnerRecordName = try container.decodeIfPresent(String.self, forKey: .accountOwnerRecordName)
        ubiquityIdentityTokenData = try container.decodeIfPresent(Data.self, forKey: .ubiquityIdentityTokenData)
        pendingLocalRecordNames = try container.decodeIfPresent(Set<String>.self, forKey: .pendingLocalRecordNames) ?? []
        let decodedSuppressedHashes = try container.decodeIfPresent(
            [String: String].self,
            forKey: .suppressedLocalRecordPayloadHashes
        ) ?? [:]
        let acceptedSuppressedHashes = decodedSuppressedHashes.filter { name, hash in
            guard MediaStateRecordName.kind(from: name) == .skyStreamMetadata,
                  MediaStateRecordName.identifier(from: name) == "safe-cloud-v1" else {
                return false
            }
            return name == MediaStateRecordName.make(
                kind: .skyStreamMetadata,
                identifier: "safe-cloud-v1",
                profileID: MediaStateRecordName.profileID(from: name)
            ) && Self.isCanonicalPayloadHash(hash)
        }
        suppressedLocalRecordPayloadHashes = acceptedSuppressedHashes.count
            <= Self.maximumPendingAccountIsolationProfileIDs
            ? acceptedSuppressedHashes
            : [:]
        let decodedDeferredApplyHashes: [String: String]
        do {
            decodedDeferredApplyHashes = try container.decodeIfPresent(
                [String: String].self,
                forKey: .deferredApplyManagerPayloadHashes
            ) ?? [:]
        } catch {
            decodedDeferredApplyHashes = [:]
        }
        let acceptedDeferredApplyHashes = decodedDeferredApplyHashes.filter { name, hash in
            !name.isEmpty
                && name.utf8.count <= MediaStateEnvelopeValidator.maximumRecordNameBytes
                && Self.isCanonicalPayloadHash(hash)
        }
        deferredApplyManagerPayloadHashes =
            acceptedDeferredApplyHashes.count <= Self.maximumDeferredApplyManagerPayloadHashes
            ? acceptedDeferredApplyHashes
            : [:]
        isAccountNeutralLocalStateActive = try container.decodeIfPresent(
            Bool.self,
            forKey: .isAccountNeutralLocalStateActive
        ) ?? false
        pendingAccountIsolationProfileIDs = try container.decodeIfPresent(
            Set<UUID>.self,
            forKey: .pendingAccountIsolationProfileIDs
        ) ?? []
        guard pendingAccountIsolationProfileIDs.count
                <= Self.maximumPendingAccountIsolationProfileIDs else {
            throw DecodingError.dataCorruptedError(
                forKey: .pendingAccountIsolationProfileIDs,
                in: container,
                debugDescription: "Account-isolation profile journal exceeds the profile limit"
            )
        }

        do {
            pendingAccountIsolationTarget = try container.decodeIfPresent(
                MediaStatePendingAccountIsolationTarget.self,
                forKey: .pendingAccountIsolationTarget
            )
        } catch {
            pendingAccountIsolationTarget = nil
        }
        if pendingAccountIsolationProfileIDs.isEmpty {
            pendingAccountIsolationTarget = nil
        }
    }

    static func isCanonicalPayloadHash(_ hash: String) -> Bool {
        hash.count == 64 && hash.unicodeScalars.allSatisfy(
            CharacterSet(charactersIn: "0123456789abcdef").contains
        )
    }

    static let empty = MediaStateLocalArchive(
        records: [:],
        lastLocalRecordNames: [],
        accountOwnerRecordName: nil,
        ubiquityIdentityTokenData: nil,
        pendingLocalRecordNames: [],
        suppressedLocalRecordPayloadHashes: [:],
        deferredApplyManagerPayloadHashes: [:],
        isAccountNeutralLocalStateActive: false,
        pendingAccountIsolationProfileIDs: [],
        pendingAccountIsolationTarget: nil
    )
}

struct MediaStateInitialMergeResult: Equatable, Sendable {
    let records: [String: MediaStateEnvelope]
    let pendingRecordNames: [String]
}

enum MediaStateInitialLocalStatePolicy: Equatable, Sendable {
    case migrateLocalState
    case isolateIncomingAccount
}

enum MediaStateLocalMigrationPolicy {
    static func recordsEligibleForMigration(
        localSnapshot: [String: MediaStateEnvelope],
        defaultRecordNames: Set<String>
    ) -> [String: MediaStateEnvelope] {
        localSnapshot.filter { !defaultRecordNames.contains($0.key) }
    }

    static func shouldSuppressNewRecord(
        named recordName: String,
        suppressedDefaultRecordNames: Set<String>,
        currentDefaultRecordNames: Set<String>
    ) -> Bool {
        suppressedDefaultRecordNames.contains(recordName) &&
            currentDefaultRecordNames.contains(recordName)
    }

    static func shouldSuppressTombstoneResurrection(
        named recordName: String,
        currentDefaultRecordNames: Set<String>
    ) -> Bool {
        currentDefaultRecordNames.contains(recordName)
    }
}

enum MediaStateLibraryRestorePolicy {
    static func hasCollectionDefinitionHistory(
        in records: [MediaStateEnvelope]
    ) -> Bool {
        records.contains { $0.kind == .libraryCollection }
    }
}

enum MediaStateCatalogRestorePolicy {
    static func hasCatalogOrderHistory(
        in records: [MediaStateEnvelope]
    ) -> Bool {
        records.contains { $0.kind == .catalogOrder }
    }
}

enum MediaStateProgressRestorePolicy {
    static func hasWatchHistory(
        in records: [MediaStateEnvelope]
    ) -> Bool {
        records.contains { $0.kind == .movieProgress || $0.kind == .episodeProgress }
    }
}

enum MediaStateRatingRestorePolicy {
    static func hasRatingHistory(
        in records: [MediaStateEnvelope]
    ) -> Bool {
        records.contains { $0.kind == .rating }
    }
}

enum MediaStateAccountTransitionPolicy {
    static func signInPolicy(
        lastKnownAccountRecordName: String?,
        currentAccountRecordName: String,
        requiresIsolation: Bool
    ) -> MediaStateInitialLocalStatePolicy {
        if requiresIsolation {
            return .isolateIncomingAccount
        }
        guard let lastKnownAccountRecordName else {
            return .migrateLocalState
        }
        return lastKnownAccountRecordName == currentAccountRecordName
            ? .migrateLocalState
            : .isolateIncomingAccount
    }
}

enum MediaStateLaunchIdentityEvidence: Equatable, Sendable {
    case sameAccount
    case differentAccountOrSignedOut
    case unavailable
}

enum MediaStateLaunchCacheAction: Equatable, Sendable {
    case restoreOwnedCache
    case isolateLoadedState
    case awaitCloudKitVerification
}

enum MediaStateLaunchCachePolicy {
    static func action(
        hasAccountOwner: Bool,
        evidence: MediaStateLaunchIdentityEvidence
    ) -> MediaStateLaunchCacheAction {
        guard hasAccountOwner else {
            return .awaitCloudKitVerification
        }
        switch evidence {
        case .sameAccount:
            return .restoreOwnedCache
        case .differentAccountOrSignedOut, .unavailable:

            return .awaitCloudKitVerification
        }
    }
}

struct MediaStatePlaybackLeaseCounter: Equatable, Sendable {
    private(set) var activeSessionCount = 0

    mutating func begin() {
        activeSessionCount += 1
    }

    @discardableResult
    mutating func end() -> Bool {
        guard activeSessionCount > 0 else { return false }
        activeSessionCount -= 1
        return activeSessionCount == 0
    }
}

enum MediaStateInitialMergePolicy {
    static func merge(
        fetchedRecords: [String: MediaStateEnvelope],
        localSnapshot: [String: MediaStateEnvelope],
        localStatePolicy: MediaStateInitialLocalStatePolicy = .migrateLocalState
    ) -> MediaStateInitialMergeResult {

        guard localStatePolicy == .migrateLocalState else {
            return MediaStateInitialMergeResult(
                records: fetchedRecords,
                pendingRecordNames: []
            )
        }

        var records = fetchedRecords
        var pendingRecordNames: [String] = []

        for (recordName, localEnvelope) in localSnapshot {
            if let fetchedEnvelope = records[recordName] {
                var merged = fetchedEnvelope.merged(with: localEnvelope)
                merged.systemFields = fetchedEnvelope.systemFields
                records[recordName] = merged
                if merged != fetchedEnvelope {
                    pendingRecordNames.append(recordName)
                }
            } else {
                records[recordName] = localEnvelope
                pendingRecordNames.append(recordName)
            }
        }

        return MediaStateInitialMergeResult(
            records: records,
            pendingRecordNames: pendingRecordNames.sorted()
        )
    }
}

enum MediaStateSyncPhase: Equatable, Sendable {
    case idle
    case checkingAccount
    case fetching
    case ready
    case localOnly(String)

    var title: String {
        switch self {
        case .idle: return "Not Started"
        case .checkingAccount: return "Checking iCloud"
        case .fetching: return "Restoring Media State"
        case .ready: return "Synced with iCloud"
        case .localOnly: return "Using Local State"
        }
    }

    var message: String {
        switch self {
        case .idle:
            return "Media state sync has not started."
        case .checkingAccount:
            return "Checking the signed-in iCloud account."
        case .fetching:
            return "Fetching remote state before this device is allowed to upload changes."
        case .ready:
            return "Library, progress, ratings, and safe settings are current."
        case .localOnly(let reason):
            return reason
        }
    }
}

enum MediaStateRecordName {

    static func make(kind: MediaStateKind, identifier: String, profileID: UUID? = nil) -> String {
        let safeIdentifier = sanitized(identifier)
        guard let profileID,
              kind.isProfileScoped,
              profileID != ProfileManager.defaultProfileID else {
            return "\(kind.rawValue)|\(safeIdentifier)"
        }
        return "\(kind.rawValue)|\(profileID.uuidString.lowercased())|\(safeIdentifier)"
    }

    static func sanitized(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "#", with: "_")
            .replacingOccurrences(of: "|", with: "_")
    }

    static func identifier(from recordName: String) -> String? {
        let segments = recordName.split(separator: "|", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }

        if segments.count >= 3, UUID(uuidString: String(segments[1])) != nil {
            return segments.dropFirst(2).joined(separator: "|")
        }
        guard let separator = recordName.firstIndex(of: "|") else { return nil }
        return String(recordName[recordName.index(after: separator)...])
    }

    static func profileID(from recordName: String) -> UUID {
        let segments = recordName.split(separator: "|", omittingEmptySubsequences: false)
        guard segments.count >= 3, let parsed = UUID(uuidString: String(segments[1])) else {
            return ProfileManager.defaultProfileID
        }
        return parsed
    }

    static func kind(from recordName: String) -> MediaStateKind? {
        guard let separator = recordName.firstIndex(of: "|") else { return nil }
        return MediaStateKind(rawValue: String(recordName[recordName.startIndex..<separator]))
    }
}

struct MediaStateServiceSource: Codable, Equatable {
    let id: UUID
    let url: String
    let jsonMetadata: String
    let jsScript: String
    let isActive: Bool
    let sortIndex: Int64
}

struct MediaStateStremioAddon: Codable, Equatable {
    let id: UUID
    let configuredURL: String
    let manifestJSON: String
    let isActive: Bool
    let sortIndex: Int64
}

enum PrivateCloudSourceURLPolicy {
    static let maximumURLBytes = 16 * 1_024

    static func validatedHTTPURLString(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumURLBytes,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

struct MediaStateServiceSourcesPayload: Codable, Equatable {
    static let settingKey = "mediaStateServiceSourcesV1"
    static let schemaVersion = 1
    static let maximumServices = 256
    static let maximumStremioAddons = 256
    static let maximumNuvioMetadataBytes = 512 * 1_024

    var schemaVersion: Int = Self.schemaVersion
    var services: [MediaStateServiceSource]
    var stremioAddons: [MediaStateStremioAddon]

    var nuvioPluginsData: Data?

    static func sanitized(
        services: [MediaStateServiceSource],
        stremioAddons: [MediaStateStremioAddon],
        nuvioPluginsData: Data?
    ) -> Self {
        let safeServices = services
            .compactMap(serviceForCloudSync)
            .sorted(by: serviceOrder)
            .prefix(maximumServices)
        let safeAddons = stremioAddons
            .compactMap(stremioAddonForCloudSync)
            .sorted(by: addonOrder)
            .prefix(maximumStremioAddons)
        let safeNuvioData = nuvioPluginsData.flatMap {
            $0.isEmpty || $0.count > maximumNuvioMetadataBytes ? nil : $0
        }
        return Self(
            services: Array(safeServices),
            stremioAddons: Array(safeAddons),
            nuvioPluginsData: safeNuvioData
        )
    }

    static func captured(
        services: [MediaStateServiceSource],
        stremioAddons: [MediaStateStremioAddon],
        nuvioPluginsData: Data?
    ) -> Self? {
        guard services.count <= maximumServices,
              stremioAddons.count <= maximumStremioAddons,
              Set(services.map(\.id)).count == services.count,
              Set(stremioAddons.map(\.id)).count == stremioAddons.count,
              services.allSatisfy({ serviceForCloudSync($0) != nil }),
              stremioAddons.allSatisfy({ stremioAddonForCloudSync($0) != nil }),
              nuvioPluginsData == nil
                || (nuvioPluginsData?.isEmpty == false
                    && (nuvioPluginsData?.count ?? 0) <= maximumNuvioMetadataBytes) else {
            return nil
        }
        let payload = sanitized(
            services: services,
            stremioAddons: stremioAddons,
            nuvioPluginsData: nuvioPluginsData
        )
        guard payload.services.count == services.count,
              payload.stremioAddons.count == stremioAddons.count,
              (nuvioPluginsData == nil || payload.nuvioPluginsData != nil) else {
            return nil
        }
        return payload
    }

    var isCanonicalAndCloudSafe: Bool {
        schemaVersion == Self.schemaVersion
            && services.count <= Self.maximumServices
            && stremioAddons.count <= Self.maximumStremioAddons
            && Set(services.map(\.id)).count == services.count
            && Set(stremioAddons.map(\.id)).count == stremioAddons.count
            && self == Self.sanitized(
                services: services,
                stremioAddons: stremioAddons,
                nuvioPluginsData: nuvioPluginsData
            )
    }

    static func canonicalData(_ payload: Self) -> Data? {
        guard payload.isCanonicalAndCloudSafe else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(payload)
    }

    static func mergedServices(
        current: [MediaStateServiceSource],
        incoming: [MediaStateServiceSource]
    ) -> [MediaStateServiceSource] {
        let deviceLocal = current.filter { serviceForCloudSync($0) == nil }
        let deviceLocalIDs = Set(deviceLocal.map(\.id))
        return (incoming.filter { !deviceLocalIDs.contains($0.id) } + deviceLocal)
            .sorted(by: serviceOrder)
    }

    static func mergedStremioAddons(
        current: [MediaStateStremioAddon],
        incoming: [MediaStateStremioAddon]
    ) -> [MediaStateStremioAddon] {
        let deviceLocal = current.filter { stremioAddonForCloudSync($0) == nil }
        let deviceLocalIDs = Set(deviceLocal.map(\.id))
        return (incoming.filter { !deviceLocalIDs.contains($0.id) } + deviceLocal)
            .sorted(by: addonOrder)
    }

    private static func serviceForCloudSync(
        _ service: MediaStateServiceSource
    ) -> MediaStateServiceSource? {
        guard service.jsonMetadata.utf8.count <= 128 * 1_024,
              service.jsScript.utf8.count <= 512 * 1_024,
              let safeURL = PrivateCloudSourceURLPolicy.validatedHTTPURLString(
                service.url
              ) else {
            return nil
        }
        return MediaStateServiceSource(
            id: service.id,
            url: safeURL,
            jsonMetadata: service.jsonMetadata,
            jsScript: service.jsScript,
            isActive: service.isActive,
            sortIndex: service.sortIndex
        )
    }

    private static func stremioAddonForCloudSync(
        _ addon: MediaStateStremioAddon
    ) -> MediaStateStremioAddon? {
        guard addon.manifestJSON.utf8.count <= 256 * 1_024,
              let configuredURL = PrivateCloudSourceURLPolicy.validatedHTTPURLString(
                addon.configuredURL
              ) else {
            return nil
        }
        return MediaStateStremioAddon(
            id: addon.id,
            configuredURL: configuredURL,
            manifestJSON: addon.manifestJSON,
            isActive: addon.isActive,
            sortIndex: addon.sortIndex
        )
    }

    private static func serviceOrder(
        _ lhs: MediaStateServiceSource,
        _ rhs: MediaStateServiceSource
    ) -> Bool {
        lhs.sortIndex == rhs.sortIndex
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.sortIndex < rhs.sortIndex
    }

    private static func addonOrder(
        _ lhs: MediaStateStremioAddon,
        _ rhs: MediaStateStremioAddon
    ) -> Bool {
        lhs.sortIndex == rhs.sortIndex
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.sortIndex < rhs.sortIndex
    }
}

enum MediaStateSettingRegistry {
    private static let sharedKeys: Set<String> = [
        MediaStateServiceSourcesPayload.settingKey,
        "tmdbLanguage",
        "enableSubtitlesByDefault",
        "defaultSubtitleLanguage",
        "preferredAutoAudioLanguage",
        "preferredAnimeAudioLanguage",
        "defaultPlaybackSpeed",
        "playerOpenSubtitlesEnabled",
        "playerOpenSubtitlesAutoFallbackEnabled",
        "playerSubtitleAppearanceEnabled",
        "audioComfortMode",
        "audioComfortScopeCategories",
        "mpvSurroundSoundEnabled",
        "watchTogetherEnabled",
        "mpvPictureInPictureEnabled",
        "introDBEnabled",
        "introDBAppEnabled",
        "aniSkipAutoSkip",
        "showNextEpisodeButton",
        "showPlayerServicesButton",
        "nextEpisodeThreshold",
        "servicesAutoModeEnabled",
        "servicesAutoSelectEpisodesEnabled",
        "servicesAutoModeErrorIntelligenceEnabled",
        "servicesAutoModeQualityPreference",
        "servicesAutoModeSourceIds",
        "servicesAutoModeSourceOrderIds",
        "servicesIncludedStreamLanguages",
        "servicesHiddenStreamLanguages",
        "servicesHideStreamsWithoutLanguageData",
        "servicesHiddenStreamQualities",
        "servicesHideStreamsWithoutDetectedQuality",
        "servicesAssumeOriginalAudio",
        "servicesTreatDubbedAnimeAsEnglish",
        "servicesStremioStyleSheetEnabled",
        "servicesResultMinimumSimilarity",
        "servicesDropMismatchedResults",
        "servicesExtraRulesSourceIds",
        "mediaDetailElementOrder",
        "mediaDetailHiddenElements",
        "mediaDetailSimilarTitlesEnabled",
        "mediaDetailTitleArtworkEnabled",
        "mediaDetailAlternatePosterEnabled",
        "homeCatalogLayoutOverrides",
        "appearancePalette",
        "appearanceBleedStrength",
        "appearanceBackgroundIntensity",
        "appearanceMotion",
        "atmosphereStyle",
        "homeAnimatedBackgroundEnabled",
        "homeAnimatedBackgroundQuality",
        "homeAnimatedBackgroundFrameRate",
        "mpvPlayerSkinTintControlsOnly",
        "experimentalMediaDesignPreset",
        "experimentalHomeCardShape",
        "experimentalHeroHeightScale",
        "experimentalSectionSpacingScale",
        "experimentalCardRadiusScale",
        "experimentalMediaCardScale",
        "heroBannerCatalogId",
        "heroBannerBehavior",
        "subtitles_fontSize",
        "subtitles_strokeWidth",
        "subtitles_foregroundColor",
        "subtitles_strokeColor",
        "subtitles_closedCaptionBackground",
        "playerSubtitleOverlayBottomConstant",
        "performanceModeEnabled",
        "performanceModeSkipAniListTraversalForAnimeDetails",
        "performanceModeFastAnimeCatalogOverrides",

        "atmosphereSolidColorSource",
        "atmosphereSolidColor",
        "appearanceCustomColors",
        "accentColor",
        "eclipseThemeGradientColor",

        "defaultScheduleMode",
        "scheduleWindowDays",
        "showLocalScheduleTime",
        "libraryShowBookmarksSection",
        "showUnairedEpisodes",
        "mediaDetailAgeRatingEnabled",
        "browseFilterPreferences",
        "selectedSimilarityAlgorithm",
        "highQualityThreshold"
    ]

    private static let tvOSKeys: Set<String> = [
        "tvCardDensity",
        "playbackEngine",
        "tvServicesActiveSourceIds",
        "tvOSServiceSourceActivationOverrides"
    ]

    private static let iOSKeys: Set<String> = [

        "localNotificationSubscriptions",
        "playerDoubleTapSeekSeconds",

        "localNotificationEpisodeReminders",
        "localNotificationEpisodeLeadTime",
        "localNotificationSeasonLeadTime",
        "localNotificationIncludeAnimeSpecials",

        "selectedAppearance",

        "mpvPlayerSkin",
        "mpvPlayerSkinCustomPrimaryColor",
        "mpvPlayerSkinCustomSecondaryColor",
        "mpvPlayerSkinAnimationsEnabled",
        "mpvPlayerSkinAnimationStyle.default",
        "mpvPlayerSkinAnimationStyle.blackAndGold",
        "mpvPlayerSkinAnimationStyle.prismatic",
        "mpvPlayerSkinAnimationStyle.cyberpunk",
        "mpvPlayerSkinAnimationStyle.custom",

        "playerDoubleTapSeekEnabled",
        "playerBrightnessGestureEnabled",
        "playerVolumeGestureEnabled",
        "playerTwoFingerTapPlayPauseEnabled",
        "playerCenterTapPlayPauseEnabled",
        "playerPlaybackLockEnabled",
        "holdSpeedPlayer",
        "aniSkipEnabled",
        "skip85sEnabled",
        "skip85sAlwaysVisible",
        "showEpisodeBrowserButton",
        "showNextEpisodePosterButton",
        "nextEpisodeSkipFillerEnabled",
        "mpvAppExitPictureInPictureEnabled",
        "preferDownloadedMedia",

        "readerGlobalAppearanceEnabled",
        "readerAppearancePalette",
        "readerAppearanceBleedStrength",
        "readerAppearanceBackgroundIntensity",
        "readerAppearanceMotion",
        "readerAppearanceCustomColors",
        "readerAtmosphereStyle",
        "readerAtmosphereSolidColorSource",
        "readerAtmosphereSolidColor",
        "readerThemeGradientColor",
        "readerAccentColor",
        "readerSelectedAppearance",

        "readerFontSize",
        "readerFontFamily",
        "readerFontWeight",
        "readerColorPreset",
        "readerTextAlignment",
        "readerLineSpacing",
        "readerMargin",

        "readerDetailElementOrder",
        "readerDetailHiddenElements",
        "readerReadThresholdPercent",
        "kanzenReaderMode",

        "Reader.downsampleImages",
        "Reader.cropBorders",
        "Reader.disableQuickActions",
        "Reader.disableDoubleTap",
        "Reader.liveText",
        "Reader.hideBarsOnSwipe",
        "Reader.backgroundColor",
        "Reader.tapZones",
        "Reader.invertTapZones",
        "Reader.animatePageTransitions",
        "Reader.pagesToPreload",
        "Reader.splitWideImages",
        "Reader.reverseSplitOrder",
        "Reader.verticalInfiniteScroll"
    ]

    private static let previousScopes: [String: MediaStateSettingScope] = [
        "playerDoubleTapSeekSeconds": .tvOS
    ]

    static var allKeys: Set<String> { sharedKeys.union(tvOSKeys).union(iOSKeys) }

    static func scope(for key: String) -> MediaStateSettingScope? {
        if sharedKeys.contains(key) { return .shared }
        if tvOSKeys.contains(key) { return .tvOS }
        if iOSKeys.contains(key) { return .iOS }
        return nil
    }

    static func acceptsPreviousScope(
        _ scope: MediaStateSettingScope,
        for key: String
    ) -> Bool {
        previousScopes[key] == scope
    }
}

enum MediaStateSettingValueValidator {
    private static let booleanKeys: Set<String> = [
        "enableSubtitlesByDefault", "playerOpenSubtitlesEnabled",
        "playerOpenSubtitlesAutoFallbackEnabled", "playerSubtitleAppearanceEnabled",
        "mpvSurroundSoundEnabled", "watchTogetherEnabled",
        "mpvPictureInPictureEnabled", "introDBEnabled", "introDBAppEnabled",
        "aniSkipAutoSkip", "showNextEpisodeButton", "showPlayerServicesButton",
        "servicesAutoModeEnabled", "servicesAutoSelectEpisodesEnabled",
        "servicesAutoModeErrorIntelligenceEnabled",
        "servicesHideStreamsWithoutLanguageData", "servicesHideStreamsWithoutDetectedQuality",
        "servicesAssumeOriginalAudio", "servicesTreatDubbedAnimeAsEnglish",
        "servicesStremioStyleSheetEnabled", "servicesDropMismatchedResults",
        "mediaDetailSimilarTitlesEnabled", "mediaDetailTitleArtworkEnabled",
        "mediaDetailAlternatePosterEnabled", "homeAnimatedBackgroundEnabled",
        "mpvPlayerSkinTintControlsOnly", "performanceModeEnabled",
        "performanceModeSkipAniListTraversalForAnimeDetails",
        "subtitles_closedCaptionBackground",
        "localNotificationIncludeAnimeSpecials", "mediaDetailAgeRatingEnabled",
        "showUnairedEpisodes", "libraryShowBookmarksSection",
        "showLocalScheduleTime", "mpvPlayerSkinAnimationsEnabled",
        "playerDoubleTapSeekEnabled", "playerBrightnessGestureEnabled",
        "playerVolumeGestureEnabled", "playerTwoFingerTapPlayPauseEnabled",
        "playerCenterTapPlayPauseEnabled", "playerPlaybackLockEnabled",
        "aniSkipEnabled", "skip85sEnabled", "skip85sAlwaysVisible",
        "showEpisodeBrowserButton", "showNextEpisodePosterButton",
        "nextEpisodeSkipFillerEnabled", "mpvAppExitPictureInPictureEnabled",
        "preferDownloadedMedia", "modeSwitchAnimationEnabled",
        "readerGlobalAppearanceEnabled",
        "Reader.downsampleImages", "Reader.cropBorders",
        "Reader.disableQuickActions", "Reader.disableDoubleTap",
        "Reader.liveText", "Reader.hideBarsOnSwipe", "Reader.invertTapZones",
        "Reader.animatePageTransitions", "Reader.splitWideImages",
        "Reader.reverseSplitOrder", "Reader.verticalInfiniteScroll"
    ]

    private static let stringAllowLists: [String: Set<String>] = [
        "atmosphereSolidColorSource": ["dominant", "custom"],
        "readerAtmosphereSolidColorSource": ["dominant", "custom"],
        "readerAtmosphereStyle": ["gradient", "multiGradient", "aurora", "ember", "solid"],
        "selectedAppearance": ["system", "light", "dark"],
        "readerSelectedAppearance": ["system", "light", "dark"],
        "defaultScheduleMode": ["anime", "western", "combined"],
        "selectedSimilarityAlgorithm": ["hybrid", "jaro_winkler", "levenshtein"],
        "mpvPlayerSkin": ["default", "blackAndGold", "prismatic", "cyberpunk", "custom", "cypberpunk"],
        "mpvPlayerSkinAnimationStyle.default": ["glow", "spectrum", "sweep", "aurora"],
        "mpvPlayerSkinAnimationStyle.blackAndGold": ["glow", "spectrum", "sweep", "aurora"],
        "mpvPlayerSkinAnimationStyle.prismatic": ["glow", "spectrum", "sweep", "aurora"],
        "mpvPlayerSkinAnimationStyle.cyberpunk": ["glow", "spectrum", "sweep", "aurora"],
        "mpvPlayerSkinAnimationStyle.custom": ["glow", "spectrum", "sweep", "aurora"],
        "readerFontFamily": [
            "-apple-system", "Georgia", "Menlo", "ui-rounded",
            "Times New Roman", "Helvetica", "Charter", "New York"
        ],
        "readerFontWeight": ["300", "normal", "500", "600", "700", "bold"],
        "readerTextAlignment": ["left", "center", "right", "justify"],
        "Reader.backgroundColor": ["black", "white", "system", "auto"],
        "Reader.tapZones": ["auto", "left-right", "l-shaped", "kindle", "edge", "disabled"],
        "kanzenReaderMode": ["ltr", "rtl", "vertical", "webtoon"]
    ]

    private static let integerMemberSets: [String: Set<Int>] = [
        "localNotificationEpisodeLeadTime": [0, 900, 3600, 86_400],
        "localNotificationSeasonLeadTime": [0, 86_400, 604_800],
        "scheduleWindowDays": [7, 14, 21, 30],
        "readerColorPreset": [0, 1, 2, 3, 4],
        "Reader.pagesToPreload": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    ]

    private static let stringArrayKeys: Set<String> = [
        "audioComfortScopeCategories", "servicesAutoModeSourceIds",
        "servicesAutoModeSourceOrderIds", "servicesIncludedStreamLanguages",
        "servicesHiddenStreamLanguages", "servicesExtraRulesSourceIds",
        "tvServicesActiveSourceIds"
    ]

    private static let integerArrayKeys: Set<String> = [
        "servicesHiddenStreamQualities"
    ]

    private static let booleanDictionaryKeys: Set<String> = [
        "tvOSServiceSourceActivationOverrides"
    ]

    private static let dataKeys: Set<String> = [
        MediaStateServiceSourcesPayload.settingKey,
        "subtitles_foregroundColor", "subtitles_strokeColor",
        "homeCatalogLayoutOverrides",
        "performanceModeFastAnimeCatalogOverrides",
        "browseFilterPreferences"
    ]

    private static let archivedColorKeys: Set<String> = [
        "atmosphereSolidColor", "accentColor", "eclipseThemeGradientColor",
        "mpvPlayerSkinCustomPrimaryColor", "mpvPlayerSkinCustomSecondaryColor",
        "readerAtmosphereSolidColor", "readerThemeGradientColor", "readerAccentColor",
        "appearanceCustomColors", "readerAppearanceCustomColors"
    ]

    private static let maximumArchivedColorBytes = 4_096

    private static let numericRanges: [String: ClosedRange<Double>] = [
        "defaultPlaybackSpeed": 0.25...3,
        "servicesResultMinimumSimilarity": 0.50...1.00,
        "nextEpisodeThreshold": 0.50...0.99,
        "appearanceBleedStrength": 0...1.2,
        "appearanceBackgroundIntensity": 0.6...1.3,
        "appearanceMotion": 0...1.2,
        "experimentalHeroHeightScale": 0.75...1.15,
        "experimentalSectionSpacingScale": 0.75...1.35,
        "experimentalCardRadiusScale": 0.7...1.4,
        "experimentalMediaCardScale": 0.7...1.4,
        "subtitles_fontSize": 8...96,
        "subtitles_strokeWidth": 0...10,
        "playerSubtitleOverlayBottomConstant": -24...24,
        "playerDoubleTapSeekSeconds": 5...60,
        "holdSpeedPlayer": 0.1...3,
        "highQualityThreshold": 0...1,
        "readerAppearanceBleedStrength": 0...1.2,
        "readerAppearanceBackgroundIntensity": 0.6...1.3,
        "readerAppearanceMotion": 0...1.2,
        "readerFontSize": 12...32,
        "readerLineSpacing": 1...3,
        "readerMargin": 0...30,
        "readerReadThresholdPercent": 50...100
    ]

    static func validatedValue(from data: Data, forKey key: String) -> Any? {
        guard data.count <= MediaStateEnvelope.maximumPayloadBytes,
              let value = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ), isValid(value, forKey: key) else {
            return nil
        }
        return value
    }

    private static func isValid(_ value: Any, forKey key: String) -> Bool {
        if booleanKeys.contains(key) {
            return (value as? NSNumber).map(isBoolean) ?? false
        }
        if let allowed = stringAllowLists[key] {
            guard let string = value as? String else { return false }
            return allowed.contains(string)
        }
        if let allowed = integerMemberSets[key] {
            guard let number = value as? NSNumber, !isBoolean(number) else { return false }
            let double = number.doubleValue
            guard double.isFinite,
                  double.rounded() == double,
                  let integer = Int(exactly: double) else {
                return false
            }
            return allowed.contains(integer)
        }
        if archivedColorKeys.contains(key) {
            guard let data = value as? Data,
                  !data.isEmpty,
                  data.count <= maximumArchivedColorBytes else {
                return false
            }
            return decodesAsArchivedColorPayload(data, forKey: key)
        }
        if let range = numericRanges[key] {
            guard let number = value as? NSNumber, !isBoolean(number) else { return false }
            let double = number.doubleValue
            return double.isFinite && range.contains(double)
        }
        if stringArrayKeys.contains(key) {
            guard let values = value as? [Any], values.count <= 512 else { return false }
            return values.allSatisfy {
                guard let string = $0 as? String else { return false }
                return !string.isEmpty && string.utf8.count <= 2_048
            }
        }
        if integerArrayKeys.contains(key) {
            guard let values = value as? [Any], values.count <= 128 else { return false }
            return values.allSatisfy {
                guard let number = $0 as? NSNumber, !isBoolean(number) else { return false }
                let double = number.doubleValue
                return double.isFinite && double.rounded() == double
                    && (0.0...10_000.0).contains(double)
            }
        }
        if booleanDictionaryKeys.contains(key) {
            guard let values = value as? [String: Any], values.count <= 512 else { return false }
            return values.allSatisfy { entry in
                !entry.key.isEmpty && entry.key.utf8.count <= 2_048
                    && ((entry.value as? NSNumber).map(isBoolean) ?? false)
            }
        }
        if dataKeys.contains(key) {
            guard let value = value as? Data else { return false }
            guard !value.isEmpty && value.count <= 1_000_000 else { return false }
            if key == MediaStateServiceSourcesPayload.settingKey {
                guard let decoded = try? JSONDecoder().decode(
                    MediaStateServiceSourcesPayload.self,
                    from: value
                ), let canonical = MediaStateServiceSourcesPayload.canonicalData(decoded) else {
                    return false
                }
                return canonical == value
            }
            if key == "homeCatalogLayoutOverrides" {
                guard value.count <= 262_144,
                      let overrides = try? JSONDecoder().decode(
                        [String: CatalogLayoutOverride].self,
                        from: value
                      ),
                      overrides.count <= 512 else { return false }
                return overrides.allSatisfy { entry in
                    !entry.key.isEmpty && entry.key.utf8.count <= 2_048
                        && (entry.value.sizeScale.map {
                            $0.isFinite && HomeCatalogLayoutStore.sizeRange.contains($0)
                        } ?? true)
                }
            }
            if key == "performanceModeFastAnimeCatalogOverrides" {
                guard value.count <= 8_192,
                      let overrides = try? JSONDecoder().decode(
                        [String: Bool].self,
                        from: value
                      ) else { return false }
                return Set(overrides.keys).isSubset(
                    of: PerformanceModeSettings.animeCatalogIds
                )
            }
            if key == "browseFilterPreferences" {
                guard value.count <= 16_384,
                      let decoded = try? JSONSerialization.jsonObject(with: value),
                      decoded is [String: Any] else { return false }
                return true
            }
            return true
        }

        if key == "readerDetailElementOrder" || key == "readerDetailHiddenElements" {
            guard let string = value as? String, string.utf8.count <= 8_192 else { return false }
            guard !string.isEmpty else { return key == "readerDetailHiddenElements" }
            let allowed: Set<String> = ["overview", "tags", "ratingNotes", "chapters"]
            return string.split(separator: ",").allSatisfy { allowed.contains(String($0)) }
        }

        guard let string = value as? String else { return false }
        let maximum = key == "homeCatalogLayoutOverrides"
            || key == "localNotificationSubscriptions"
            || key == "localNotificationEpisodeReminders" ? 262_144 : 8_192
        return string.utf8.count <= maximum
    }

    private static func decodesAsArchivedColorPayload(_ data: Data, forKey key: String) -> Bool {
#if canImport(UIKit)
        switch key {
        case "appearanceCustomColors":
            guard let colors = try? NSKeyedUnarchiver.unarchivedArrayOfObjects(
                ofClass: UIColor.self,
                from: data
            ) else { return false }
            return colors.count == 3
        case "readerAppearanceCustomColors":
            guard let colors = try? NSKeyedUnarchiver.unarchivedArrayOfObjects(
                ofClass: UIColor.self,
                from: data
            ) else { return false }
            return !colors.isEmpty
        default:
            return (try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: UIColor.self,
                from: data
            )) != nil
        }
#else
        return false
#endif
    }

    static func capturableLocalValue(_ value: Any, forKey key: String) -> Any {
        guard numericRanges[key] != nil,
              let number = value as? NSNumber,
              isBoolean(number) else {
            return value
        }
        return NSNumber(value: number.boolValue ? 1.0 : 0.0)
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

enum MediaStateSettingRestorePolicy {
    static func apply(
        records: [MediaStateEnvelope],
        to defaults: UserDefaults
    ) {
        apply(records: records) { _, _ in defaults }
    }

    static func apply(
        records: [MediaStateEnvelope],
        resolveStore: (_ key: String, _ profileID: UUID) -> UserDefaults
    ) {
        for envelope in records where envelope.kind == .setting {
            guard let key = MediaStateRecordName.identifier(from: envelope.recordName),
                  let currentScope = MediaStateSettingRegistry.scope(for: key),
                  currentScope == envelope.settingScope
                    || MediaStateSettingRegistry.acceptsPreviousScope(
                        envelope.settingScope,
                        for: key
                    ),
                  currentScope.appliesToCurrentPlatform else {
                continue
            }
            let defaults = resolveStore(
                key,
                MediaStateRecordName.profileID(from: envelope.recordName)
            )

            if envelope.isDeleted {
                defaults.removeObject(forKey: key)
                continue
            }

            guard let value = MediaStateSettingValueValidator.validatedValue(
                from: envelope.payload,
                forKey: key
            ) else {
                continue
            }
            defaults.set(value, forKey: key)
        }
    }
}

struct MediaStateLegacyRestoreSettingSnapshot {
    private let persistedValues: [String: Any]
    private let missingKeys: Set<String>

    init(persistentDomain: [String: Any]) {
        let applicableKeys = Set(MediaStateSettingRegistry.allKeys.filter {
            MediaStateSettingRegistry.scope(for: $0)?.appliesToCurrentPlatform == true
        })
        persistedValues = persistentDomain.filter { applicableKeys.contains($0.key) }
        missingKeys = applicableKeys.subtracting(persistedValues.keys)
    }

    func restore(to defaults: UserDefaults) {
        for key in missingKeys {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in persistedValues {
            defaults.set(value, forKey: key)
        }
    }
}

extension Notification.Name {
    static let libraryDataDidChange = Notification.Name("libraryDataDidChange")
    static let userRatingDataDidChange = Notification.Name("userRatingDataDidChange")
    static let catalogDataDidChange = Notification.Name("catalogDataDidChange")
    static let mediaStateDidRestore = Notification.Name("mediaStateDidRestore")
    static let mediaStatePlaybackLeaseDidEnd = Notification.Name("mediaStatePlaybackLeaseDidEnd")

    static let mediaStateWillChangeCurrentUser = Notification.Name("mediaStateWillChangeCurrentUser")
}

enum MediaStateAccountPlaybackBoundary {

    static func notifyWillChangeUser(
        notificationCenter: NotificationCenter = .default,
        sender: Any? = nil
    ) {
        notificationCenter.post(
            name: .mediaStateWillChangeCurrentUser,
            object: sender
        )
    }
}
