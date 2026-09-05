import CloudKit
import Combine
import CryptoKit
import Darwin
import Foundation

struct TrackerCloudSyncAuthority: Equatable {
    let ownerRecordName: String
    let generation: Int
}

enum TrackerCloudMutationKind: String, Codable {
    case authorization
    case refresh
    case disconnect
}

struct TrackerCloudAccountRecord: Codable {
    static let maximumPayloadBytes = 32 * 1_024
    static let maximumRecordCount = 512

    var schemaVersion = 1
    let profileID: UUID
    let service: TrackerService
    let account: TrackerAccount?
    let epoch: UInt64
    let revision: UInt64
    let mutationID: UUID
    let modifiedAt: Date

    enum CodingKeys: String, CodingKey {
        case schemaVersion, profileID, service, account, epoch, revision, mutationID, modifiedAt
    }

    init(
        schemaVersion: Int = 1,
        profileID: UUID,
        service: TrackerService,
        account: TrackerAccount?,
        epoch: UInt64,
        revision: UInt64,
        mutationID: UUID,
        modifiedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.service = service
        self.account = account
        self.epoch = epoch
        self.revision = revision
        self.mutationID = mutationID
        self.modifiedAt = modifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.account) else { throw TrackerCloudSyncError.invalidPayload }
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        service = try container.decode(TrackerService.self, forKey: .service)
        account = try container.decodeIfPresent(TrackerAccount.self, forKey: .account)
        epoch = try container.decode(UInt64.self, forKey: .epoch)
        revision = try container.decode(UInt64.self, forKey: .revision)
        mutationID = try container.decode(UUID.self, forKey: .mutationID)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(profileID, forKey: .profileID)
        try container.encode(service, forKey: .service)
        try container.encode(account, forKey: .account)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(revision, forKey: .revision)
        try container.encode(mutationID, forKey: .mutationID)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }

    var recordName: String {
        Self.recordName(profileID: profileID, service: service)
    }

    static func recordName(profileID: UUID, service: TrackerService) -> String {
        let identity = profileID.uuidString.lowercased() + ":" + service.rawValue
        return "tracker-" + digest(Data(identity.utf8))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func accountsMatch(_ lhs: TrackerAccount?, _ rhs: TrackerAccount?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.service == rhs.service
            && lhs.username == rhs.username
            && lhs.userId == rhs.userId
            && lhs.accessToken == rhs.accessToken
            && lhs.refreshToken == rhs.refreshToken
            && lhs.expiresAt == rhs.expiresAt
            && lhs.isConnected == rhs.isConnected
    }

    static func credentialMatches(_ lhs: TrackerAccount?, _ rhs: TrackerAccount?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.service == rhs.service
            && lhs.userId == rhs.userId
            && lhs.accessToken == rhs.accessToken
            && lhs.refreshToken == rhs.refreshToken
            && lhs.isConnected && rhs.isConnected
    }

    static func recordsMatch(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.profileID == rhs.profileID
            && lhs.service == rhs.service
            && accountsMatch(lhs.account, rhs.account)
            && lhs.epoch == rhs.epoch
            && lhs.revision == rhs.revision
            && lhs.mutationID == rhs.mutationID
            && lhs.modifiedAt == rhs.modifiedAt
    }

    static func validated(_ value: Self) -> Bool {
        guard value.schemaVersion == 1,
              value.epoch < UInt64(Int64.max),
              value.revision > 0,
              value.revision < UInt64(Int64.max),
              validDate(value.modifiedAt) else { return false }
        guard let account = value.account else { return true }
        return account.service == value.service
            && account.isConnected
            && boundedString(account.username, maximum: 1_024, permitsEmpty: true)
            && boundedString(account.userId, maximum: 1_024, permitsEmpty: false)
            && boundedString(account.accessToken, maximum: 8_192, permitsEmpty: false)
            && (account.refreshToken.map {
                boundedString($0, maximum: 8_192, permitsEmpty: false)
            } ?? true)
            && (account.expiresAt.map(validDate) ?? true)
    }

    static func preferred(_ lhs: Self, _ rhs: Self) -> Self {
        guard lhs.recordName == rhs.recordName else { return lhs }
        if lhs.epoch != rhs.epoch { return lhs.epoch > rhs.epoch ? lhs : rhs }
        if (lhs.account == nil) != (rhs.account == nil) {
            return lhs.account == nil ? lhs : rhs
        }
        if lhs.revision != rhs.revision { return lhs.revision > rhs.revision ? lhs : rhs }
        if lhs.mutationID != rhs.mutationID {
            return lhs.mutationID.uuidString > rhs.mutationID.uuidString ? lhs : rhs
        }
        let left = (try? encoded(lhs)) ?? Data()
        let right = (try? encoded(rhs)) ?? Data()
        return left.lexicographicallyPrecedes(right) ? rhs : lhs
    }

    static func authoring(
        profileID: UUID,
        service: TrackerService,
        account: TrackerAccount?,
        previous: Self?,
        kind: TrackerCloudMutationKind,
        previousAccount: TrackerAccount?,
        now: Date = Date()
    ) -> Self? {
        guard previous.map(validated) ?? true,
              previous == nil || previous?.recordName == recordName(
            profileID: profileID,
            service: service
        ) else { return nil }
        let nextEpoch: UInt64
        switch kind {
        case .authorization, .disconnect:
            guard (previous?.epoch ?? 0) < UInt64(Int64.max) - 1 else { return nil }
            nextEpoch = (previous?.epoch ?? 0) + 1
        case .refresh:
            guard let previous,
                  let account,
                  let previousAccount,
                  account.service == previousAccount.service,
                  account.userId == previousAccount.userId,
                  credentialMatches(previous.account, previousAccount) else {
                return nil
            }
            nextEpoch = previous.epoch
        }
        guard (previous?.revision ?? 0) < UInt64(Int64.max) - 1,
              (kind == .disconnect) == (account == nil) else { return nil }
        let value = Self(
            profileID: profileID,
            service: service,
            account: account,
            epoch: nextEpoch,
            revision: (previous?.revision ?? 0) + 1,
            mutationID: UUID(),
            modifiedAt: wireDate(now)
        )
        return validated(value) ? value : nil
    }

    static func bootstrap(
        profileID: UUID,
        account: TrackerAccount,
        now: Date = Date()
    ) -> Self? {
        let value = Self(
            profileID: profileID,
            service: account.service,
            account: account,
            epoch: 0,
            revision: 1,
            mutationID: UUID(),
            modifiedAt: wireDate(now)
        )
        return validated(value) ? value : nil
    }

    static func encoded(_ value: Self) throws -> Data {
        guard validated(value) else { throw TrackerCloudSyncError.invalidPayload }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumPayloadBytes else {
            throw TrackerCloudSyncError.invalidPayload
        }
        return data
    }

    static func decoded(_ data: Data) throws -> Self {
        guard data.count <= maximumPayloadBytes else {
            throw TrackerCloudSyncError.invalidPayload
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard validated(value) else { throw TrackerCloudSyncError.invalidPayload }
        return value
    }

    static func wireDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    private static func boundedString(_ value: String, maximum: Int, permitsEmpty: Bool) -> Bool {
        value.utf8.count <= maximum
            && (permitsEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite
            && date.timeIntervalSince1970 >= 0
            && date.timeIntervalSince1970 <= 4_102_444_800
    }
}

struct TrackerCloudRemoteRecord {
    let value: TrackerCloudAccountRecord
    var systemFields: Data?

    init(value: TrackerCloudAccountRecord, systemFields: Data? = nil) {
        self.value = value
        self.systemFields = systemFields
    }
}

enum TrackerCloudSaveResult {
    case saved(TrackerCloudRemoteRecord)
    case conflict(TrackerCloudRemoteRecord)
}

@MainActor
protocol TrackerCloudSyncTransport {
    func fetchAll() async throws -> [String: TrackerCloudRemoteRecord]
    func save(
        record: TrackerCloudAccountRecord,
        expected: TrackerCloudRemoteRecord?
    ) async throws -> TrackerCloudSaveResult
    func deleteZone() async throws
}

extension TrackerCloudSyncTransport {
    func deleteZone() async throws {
        throw TrackerCloudSyncError.unavailable
    }
}

enum TrackerCloudSyncError: Error {
    case invalidPayload
    case unavailable
    case storageUnavailable
    case staleAuthority
    case incompleteApply
    case concurrentChanges
}

@MainActor
final class TrackerCloudKitTransport: TrackerCloudSyncTransport {
    static let zoneName = "EclipseTrackerAccountsV1"
    static let recordType = "EclipseMediaState"
    private let database: CKDatabase
    private let zoneID = CKRecordZone.ID(
        zoneName: zoneName,
        ownerName: CKCurrentUserDefaultName
    )

    init(database: CKDatabase = CKContainer(identifier: "iCloud.Eclipse.Soupy").privateCloudDatabase) {
        self.database = database
    }

    func fetchAll() async throws -> [String: TrackerCloudRemoteRecord] {
        var records: [String: TrackerCloudRemoteRecord] = [:]
        var token: CKServerChangeToken?
        var receivedCount = 0
        for _ in 0..<32 {
            try Task.checkCancellation()
            let page: (
                modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                deletions: [CKDatabase.RecordZoneChange.Deletion],
                changeToken: CKServerChangeToken,
                moreComing: Bool
            )
            do {
                page = try await database.recordZoneChanges(
                    inZoneWith: zoneID,
                    since: token,
                    resultsLimit: 64
                )
            } catch let error as CKError where error.code == .zoneNotFound {
                guard token == nil else { throw error }
                _ = try await database.save(CKRecordZone(zoneID: zoneID))
                return [:]
            }
            receivedCount += page.modificationResultsByID.count + page.deletions.count
            guard receivedCount <= TrackerCloudAccountRecord.maximumRecordCount * 2 else {
                throw TrackerCloudSyncError.invalidPayload
            }
            for (id, result) in page.modificationResultsByID {
                let record = try result.get().record
                guard id == record.recordID else { throw TrackerCloudSyncError.invalidPayload }
                records[id.recordName] = try decode(record)
            }
            for deletion in page.deletions {
                guard deletion.recordID.zoneID == zoneID,
                      deletion.recordType == Self.recordType else {
                    throw TrackerCloudSyncError.invalidPayload
                }
                records.removeValue(forKey: deletion.recordID.recordName)
            }
            guard records.count <= TrackerCloudAccountRecord.maximumRecordCount else {
                throw TrackerCloudSyncError.invalidPayload
            }
            guard page.moreComing else { return records }
            token = page.changeToken
        }
        throw TrackerCloudSyncError.invalidPayload
    }

    func save(
        record: TrackerCloudAccountRecord,
        expected: TrackerCloudRemoteRecord?
    ) async throws -> TrackerCloudSaveResult {
        try Task.checkCancellation()
        let id = CKRecord.ID(recordName: record.recordName, zoneID: zoneID)
        let cloudRecord = try encode(record, expected: expected)
        do {
            let response = try await database.modifyRecords(
                saving: [cloudRecord],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            guard let result = response.saveResults[id] else {
                throw TrackerCloudSyncError.unavailable
            }
            return .saved(try decode(result.get()))
        } catch let error as CKError where error.code == .serverRecordChanged {
            guard let server = error.serverRecord else { throw error }
            return .conflict(try decode(server))
        }
    }

    func encode(
        _ record: TrackerCloudAccountRecord,
        expected: TrackerCloudRemoteRecord? = nil
    ) throws -> CKRecord {
        let id = CKRecord.ID(recordName: record.recordName, zoneID: zoneID)
        let cloudRecord: CKRecord
        if let systemFields = expected?.systemFields {
            guard systemFields.count <= 64 * 1_024,
                  let decoded = try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: CKRecord.self,
                    from: systemFields
                  ), decoded.recordID == id,
                  decoded.recordType == Self.recordType else {
                throw TrackerCloudSyncError.invalidPayload
            }
            cloudRecord = decoded
        } else {
            cloudRecord = CKRecord(recordType: Self.recordType, recordID: id)
        }
        cloudRecord["kind"] = "trackerAccount" as CKRecordValue
        cloudRecord["payload"] = try TrackerCloudAccountRecord.encoded(record) as CKRecordValue
        cloudRecord["modifiedAt"] = TrackerCloudAccountRecord.wireDate(record.modifiedAt) as CKRecordValue
        cloudRecord["revision"] = NSNumber(value: record.revision)
        cloudRecord["schemaVersion"] = NSNumber(value: 1)
        cloudRecord["settingScope"] = "shared" as CKRecordValue
        cloudRecord["isCompleted"] = NSNumber(value: false)
        cloudRecord["isExplicitReset"] = NSNumber(value: false)
        cloudRecord["deletedAt"] = record.account == nil
            ? TrackerCloudAccountRecord.wireDate(record.modifiedAt) as CKRecordValue : nil
        return cloudRecord
    }

    func deleteZone() async throws {
        do {
            _ = try await database.deleteRecordZone(withID: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            return
        }
    }

    func decode(_ record: CKRecord) throws -> TrackerCloudRemoteRecord {
        guard record.recordType == Self.recordType,
              record.recordID.zoneID == zoneID,
              record["kind"] as? String == "trackerAccount",
              (record["schemaVersion"] as? NSNumber)?.intValue == 1,
              let data = record["payload"] as? Data else {
            throw TrackerCloudSyncError.invalidPayload
        }
        let value = try TrackerCloudAccountRecord.decoded(data)
        guard value.recordName == record.recordID.recordName,
              (record["revision"] as? NSNumber)?.uint64Value == value.revision,
              (record["modifiedAt"] as? Date) == TrackerCloudAccountRecord.wireDate(value.modifiedAt),
              (record["deletedAt"] as? Date) == (value.account == nil
                ? TrackerCloudAccountRecord.wireDate(value.modifiedAt) : nil),
              record["settingScope"] as? String == "shared",
              (record["isCompleted"] as? NSNumber)?.boolValue == false,
              (record["isExplicitReset"] as? NSNumber)?.boolValue == false else {
            throw TrackerCloudSyncError.invalidPayload
        }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        guard archiver.encodedData.count <= 64 * 1_024 else {
            throw TrackerCloudSyncError.invalidPayload
        }
        return TrackerCloudRemoteRecord(value: value, systemFields: archiver.encodedData)
    }
}

private struct TrackerCloudPendingMutation: Codable {
    let kind: TrackerCloudMutationKind
    let previousAccount: TrackerAccount?
    let requiresRemoteBase: Bool
}

private struct TrackerCloudArchive: Codable {
    var schemaVersion = 1
    let ownerRecordName: String
    var records: [String: TrackerCloudAccountRecord] = [:]
    var pending: [String: TrackerCloudPendingMutation] = [:]
    var bootstrapCompletedKeys = Set<String>()
    var bootstrapSuppressed = false
    var remoteDeletionPending = false
    var retryNotBefore: Date?
    var retryCount = 0
}

@MainActor
final class TrackerCloudSyncManager: ObservableObject {
    static let shared = TrackerCloudSyncManager(
        transport: TrackerCloudKitTransport(),
        archiveURL: (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("TrackerCloudAccounts", isDirectory: true)
    )

    @Published private(set) var isSyncing = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastSyncDate: Date?
    var nextRetryDate: Date? { archive?.retryNotBefore }

    private let transport: TrackerCloudSyncTransport
    private let archiveURL: URL
    private var archive: TrackerCloudArchive?
    private var unavailableOwners = Set<String>()
    private var unsavedArchives: [String: TrackerCloudArchive] = [:]
    private var passID: UUID?
    private static let maximumArchiveBytes = 24 * 1_024 * 1_024

    init(transport: TrackerCloudSyncTransport, archiveURL: URL) {
        self.transport = transport
        self.archiveURL = archiveURL
    }

    func suspend() {
        passID = nil
        isSyncing = false
    }

    @discardableResult
    func noteLocalChange(
        profileID: UUID,
        service: TrackerService,
        account: TrackerAccount?,
        previousAccount: TrackerAccount? = nil,
        kind: TrackerCloudMutationKind,
        authority: TrackerCloudSyncAuthority
    ) -> Bool {
        guard loadArchive(authority: authority), var current = archive else { return false }
        let key = TrackerCloudAccountRecord.recordName(profileID: profileID, service: service)
        let persistedPrevious = current.records[key]
        guard kind != .refresh || !current.bootstrapSuppressed || persistedPrevious != nil else {
            return false
        }
        let previous = persistedPrevious ?? {
            guard kind == .refresh, let previousAccount else { return nil }
            return TrackerCloudAccountRecord.bootstrap(profileID: profileID, account: previousAccount)
        }()
        guard let value = TrackerCloudAccountRecord.authoring(
            profileID: profileID,
            service: service,
            account: account,
            previous: previous,
            kind: kind,
            previousAccount: previousAccount
        ) else {
            if kind == .refresh { return false }
            lastErrorMessage = "This tracker change could not be prepared for iCloud. Your local account is unchanged by cloud sync."
            return false
        }
        current.records[key] = value
        let priorPending = current.pending[key]
        let preservesUnbasedAuthorization = kind == .refresh
            && priorPending?.requiresRemoteBase == true
            && priorPending?.kind == .authorization
        current.pending[key] = TrackerCloudPendingMutation(
            kind: preservesUnbasedAuthorization ? .authorization : kind,
            previousAccount: preservesUnbasedAuthorization ? priorPending?.previousAccount : previousAccount,
            requiresRemoteBase: priorPending?.requiresRemoteBase == true || persistedPrevious == nil
        )
        current.bootstrapCompletedKeys.insert(key)
        current.retryNotBefore = nil
        archive = current
        guard persist(current) else {
            unsavedArchives[authority.ownerRecordName] = current
            return false
        }
        unsavedArchives.removeValue(forKey: authority.ownerRecordName)
        return true
    }

    func preservingSynchronizedAccounts(
        in state: TrackerState,
        profileID: UUID,
        authority: TrackerCloudSyncAuthority
    ) -> TrackerState? {
        guard loadArchive(authority: authority), let archive else { return nil }
        var preserved = state
        for service in TrackerService.allCases {
            let key = TrackerCloudAccountRecord.recordName(profileID: profileID, service: service)
            guard let record = archive.records[key] else { continue }
            preserved.accounts.removeAll { $0.service == service }
            if let account = record.account { preserved.accounts.append(account) }
        }
        return preserved
    }

    func synchronize(
        authority: TrackerCloudSyncAuthority,
        profileIDs: Set<UUID>,
        deletedProfileIDs: Set<UUID> = [],
        capture: @escaping (UUID) -> TrackerState?,
        apply: @escaping (UUID, TrackerService, TrackerAccount?) -> Bool,
        isCurrent: @escaping () -> Bool
    ) async {
        guard !isSyncing, isCurrent(),
              profileIDs.count <= ProfileManager.maximumProfiles,
              deletedProfileIDs.count <= TrackerCloudAccountRecord.maximumRecordCount,
              profileIDs.isDisjoint(with: deletedProfileIDs),
              loadArchive(authority: authority) else { return }
        if let unsaved = unsavedArchives[authority.ownerRecordName] {
            guard persist(unsaved) else { return }
            unsavedArchives.removeValue(forKey: authority.ownerRecordName)
        }
        guard archive?.remoteDeletionPending != true else {
            lastErrorMessage = "Tracker cloud deletion is waiting to finish. Existing tracker sign-ins remain on this device."
            return
        }
        if let retry = archive?.retryNotBefore, retry > Date() { return }
        let token = UUID()
        passID = token
        isSyncing = true
        defer {
            if passID == token {
                passID = nil
                isSyncing = false
            }
        }
        func requireAuthority() throws {
            guard !Task.isCancelled,
                  passID == token,
                  archive?.ownerRecordName == authority.ownerRecordName,
                  isCurrent() else { throw TrackerCloudSyncError.staleAuthority }
            guard unsavedArchives[authority.ownerRecordName] == nil else {
                throw TrackerCloudSyncError.storageUnavailable
            }
        }
        do {
            var remote = try await transport.fetchAll()
            try requireAuthority()
            guard remote.count <= TrackerCloudAccountRecord.maximumRecordCount,
                  remote.allSatisfy({ key, record in
                    key == record.value.recordName && TrackerCloudAccountRecord.validated(record.value)
                  }) else { throw TrackerCloudSyncError.invalidPayload }
            guard var current = archive else { throw TrackerCloudSyncError.storageUnavailable }
            for (key, fetched) in remote {
                if let local = current.records[key], let pending = current.pending[key] {
                    let candidate = rebased(local, pending: pending, remote: fetched.value)
                    let winner = TrackerCloudAccountRecord.preferred(candidate, fetched.value)
                    current.records[key] = winner
                    if TrackerCloudAccountRecord.recordsMatch(winner, fetched.value) {
                        current.pending.removeValue(forKey: key)
                    } else {
                        current.pending[key] = TrackerCloudPendingMutation(
                            kind: pending.kind,
                            previousAccount: pending.previousAccount,
                            requiresRemoteBase: false
                        )
                    }
                } else {
                    current.records[key] = fetched.value
                }
            }
            for (key, pending) in current.pending where pending.requiresRemoteBase && remote[key] == nil {
                current.pending[key] = TrackerCloudPendingMutation(
                    kind: pending.kind,
                    previousAccount: pending.previousAccount,
                    requiresRemoteBase: false
                )
            }
            for (key, record) in current.records where deletedProfileIDs.contains(record.profileID) {
                guard let account = record.account else { continue }
                guard let tombstone = TrackerCloudAccountRecord.authoring(
                    profileID: record.profileID,
                    service: record.service,
                    account: nil,
                    previous: record,
                    kind: .disconnect,
                    previousAccount: account
                ) else { throw TrackerCloudSyncError.invalidPayload }
                current.records[key] = tombstone
                current.pending[key] = TrackerCloudPendingMutation(
                    kind: .disconnect,
                    previousAccount: account,
                    requiresRemoteBase: false
                )
                current.bootstrapCompletedKeys.insert(key)
            }
            for profileID in profileIDs {
                guard let state = capture(profileID) else { continue }
                guard state.accounts.count <= TrackerService.allCases.count,
                      Set(state.accounts.map(\.service)).count == state.accounts.count else {
                    throw TrackerCloudSyncError.invalidPayload
                }
                for service in TrackerService.allCases {
                    let key = TrackerCloudAccountRecord.recordName(profileID: profileID, service: service)
                    guard !current.bootstrapCompletedKeys.contains(key) else { continue }
                    if !current.bootstrapSuppressed,
                       current.records[key] == nil,
                       remote[key] == nil,
                       let account = state.accounts.first(where: { $0.service == service && $0.isConnected }),
                       let seeded = TrackerCloudAccountRecord.bootstrap(profileID: profileID, account: account) {
                        current.records[key] = seeded
                        current.pending[key] = TrackerCloudPendingMutation(
                            kind: .authorization,
                            previousAccount: nil,
                            requiresRemoteBase: false
                        )
                    }
                    if current.bootstrapSuppressed || current.records[key] != nil {
                        current.bootstrapCompletedKeys.insert(key)
                    }
                }
            }
            try requireAuthority()
            guard persist(current) else { throw TrackerCloudSyncError.storageUnavailable }
            archive = current
            try applyRecords(profileIDs: profileIDs, capture: capture, apply: apply, requireAuthority: requireAuthority)
            let uploadKeys = current.pending.keys.filter { key in
                guard let record = current.records[key] else { return false }
                return record.account == nil || profileIDs.contains(record.profileID)
            }.sorted()
            for key in uploadKeys {
                for attempt in 0..<4 {
                    try requireAuthority()
                    guard let candidate = archive?.records[key], archive?.pending[key] != nil else { break }
                    let result = try await transport.save(record: candidate, expected: remote[key])
                    try requireAuthority()
                    let saved: TrackerCloudRemoteRecord
                    let isConflict: Bool
                    switch result {
                    case .saved(let value):
                        saved = value
                        isConflict = false
                    case .conflict(let value):
                        saved = value
                        isConflict = true
                    }
                    guard saved.value.recordName == key,
                          TrackerCloudAccountRecord.validated(saved.value),
                          var latest = archive else { throw TrackerCloudSyncError.invalidPayload }
                    remote[key] = saved
                    let winner = latest.records[key].map {
                        if isConflict, $0.epoch == 0,
                           latest.pending[key]?.kind == .authorization {
                            return saved.value
                        }
                        return TrackerCloudAccountRecord.preferred($0, saved.value)
                    } ?? saved.value
                    latest.records[key] = winner
                    if TrackerCloudAccountRecord.recordsMatch(winner, saved.value) {
                        latest.pending.removeValue(forKey: key)
                    }
                    guard persist(latest) else { throw TrackerCloudSyncError.storageUnavailable }
                    archive = latest
                    try applyRecords(profileIDs: profileIDs, capture: capture, apply: apply, requireAuthority: requireAuthority)
                    if !isConflict || latest.pending[key] == nil { break }
                    if attempt == 3 { throw TrackerCloudSyncError.concurrentChanges }
                }
            }
            try requireAuthority()
            guard var completed = archive else { throw TrackerCloudSyncError.storageUnavailable }
            completed.retryCount = 0
            let hasEligiblePending = completed.pending.keys.contains { key in
                guard let record = completed.records[key] else { return false }
                return record.account == nil || profileIDs.contains(record.profileID)
            }
            completed.retryNotBefore = hasEligiblePending ? Date().addingTimeInterval(2) : nil
            guard persist(completed) else { throw TrackerCloudSyncError.storageUnavailable }
            archive = completed
            lastSyncDate = Date()
            lastErrorMessage = nil
        } catch TrackerCloudSyncError.staleAuthority {
            return
        } catch is CancellationError {
            return
        } catch {
            guard passID == token,
                  archive?.ownerRecordName == authority.ownerRecordName,
                  isCurrent() else { return }
            recordFailure(error)
        }
    }

    func deleteRemoteRecords(
        authority: TrackerCloudSyncAuthority,
        isCurrent: @escaping () -> Bool
    ) async -> Bool {
        guard isCurrent() else { return false }
        suspend()
        let deletionArchive: TrackerCloudArchive?
        if loadArchive(authority: authority) {
            deletionArchive = archive
        } else {
            deletionArchive = preserveUnreadableArchiveForExplicitDeletion(authority: authority)
        }
        guard isCurrent(), var pendingDeletion = deletionArchive else { return false }
        pendingDeletion.bootstrapSuppressed = true
        pendingDeletion.remoteDeletionPending = true
        pendingDeletion.pending.removeAll()
        archive = pendingDeletion
        guard persist(pendingDeletion) else {
            unsavedArchives[authority.ownerRecordName] = pendingDeletion
            return false
        }
        unsavedArchives.removeValue(forKey: authority.ownerRecordName)
        unavailableOwners.remove(authority.ownerRecordName)
        let token = UUID()
        passID = token
        isSyncing = true
        defer {
            if passID == token {
                passID = nil
                isSyncing = false
            }
        }
        do {
            try await transport.deleteZone()
            guard !Task.isCancelled, passID == token, isCurrent(),
                  archive?.ownerRecordName == authority.ownerRecordName else { return false }
            var cleared = TrackerCloudArchive(ownerRecordName: authority.ownerRecordName)
            cleared.bootstrapSuppressed = true
            archive = cleared
            guard persist(cleared) else {
                unsavedArchives[authority.ownerRecordName] = cleared
                return false
            }
            lastErrorMessage = nil
            return true
        } catch {
            guard passID == token, isCurrent() else { return false }
            recordFailure(error)
            return false
        }
    }

    private func preserveUnreadableArchiveForExplicitDeletion(
        authority: TrackerCloudSyncAuthority
    ) -> TrackerCloudArchive? {
        guard !authority.ownerRecordName.isEmpty,
              authority.ownerRecordName.utf8.count <= 1_024 else { return nil }
        do {
            let url = ownerArchiveURL(authority.ownerRecordName)
            if FileManager.default.fileExists(atPath: url.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw TrackerCloudSyncError.storageUnavailable
                }
                let quarantineURL = archiveURL.appendingPathComponent(
                    url.deletingPathExtension().lastPathComponent
                        + ".unreadable-" + UUID().uuidString + ".json"
                )
                try FileManager.default.linkItem(at: url, to: quarantineURL)
                let fileDescriptor = Darwin.open(quarantineURL.path, O_RDONLY)
                guard fileDescriptor >= 0 else { throw TrackerCloudSyncError.storageUnavailable }
                defer { Darwin.close(fileDescriptor) }
                guard Darwin.fsync(fileDescriptor) == 0 else {
                    throw TrackerCloudSyncError.storageUnavailable
                }
                let directoryDescriptor = Darwin.open(archiveURL.path, O_RDONLY)
                guard directoryDescriptor >= 0 else { throw TrackerCloudSyncError.storageUnavailable }
                defer { Darwin.close(directoryDescriptor) }
                guard Darwin.fsync(directoryDescriptor) == 0 else {
                    throw TrackerCloudSyncError.storageUnavailable
                }
            }
            return TrackerCloudArchive(ownerRecordName: authority.ownerRecordName)
        } catch {
            lastErrorMessage = "The unreadable tracker journal could not be preserved safely. No tracker cloud data was deleted."
            return nil
        }
    }

    private func rebased(
        _ local: TrackerCloudAccountRecord,
        pending: TrackerCloudPendingMutation,
        remote: TrackerCloudAccountRecord
    ) -> TrackerCloudAccountRecord {
        guard pending.requiresRemoteBase else { return local }
        switch pending.kind {
        case .authorization:
            break
        case .disconnect:
            guard remote.account == nil
                    || (pending.previousAccount?.userId == remote.account?.userId
                        && pending.previousAccount?.service == remote.service) else { return local }
        case .refresh:
            guard TrackerCloudAccountRecord.credentialMatches(
                pending.previousAccount,
                remote.account
            ) else { return remote }
        }
        return TrackerCloudAccountRecord.authoring(
            profileID: local.profileID,
            service: local.service,
            account: local.account,
            previous: remote,
            kind: pending.kind,
            previousAccount: pending.previousAccount,
            now: local.modifiedAt
        ) ?? local
    }

    private func applyRecords(
        profileIDs: Set<UUID>,
        capture: (UUID) -> TrackerState?,
        apply: (UUID, TrackerService, TrackerAccount?) -> Bool,
        requireAuthority: () throws -> Void
    ) throws {
        guard let archive else { throw TrackerCloudSyncError.storageUnavailable }
        for profileID in profileIDs {
            try requireAuthority()
            guard let state = capture(profileID) else {
                throw TrackerCloudSyncError.incompleteApply
            }
            for service in TrackerService.allCases {
                try requireAuthority()
                let key = TrackerCloudAccountRecord.recordName(profileID: profileID, service: service)
                guard let record = archive.records[key] else { continue }
                let local = state.accounts.first { $0.service == service && $0.isConnected }
                guard !TrackerCloudAccountRecord.accountsMatch(local, record.account) else { continue }
                guard apply(profileID, service, record.account) else {
                    throw TrackerCloudSyncError.incompleteApply
                }
            }
        }
    }

    private func loadArchive(authority: TrackerCloudSyncAuthority) -> Bool {
        guard !authority.ownerRecordName.isEmpty,
              authority.ownerRecordName.utf8.count <= 1_024,
              !unavailableOwners.contains(authority.ownerRecordName) else {
            lastErrorMessage = "Tracker iCloud storage is unavailable. Existing accounts were preserved."
            return false
        }
        if archive?.ownerRecordName == authority.ownerRecordName { return true }
        if archive != nil { suspend() }
        lastSyncDate = nil
        lastErrorMessage = nil
        if let unsaved = unsavedArchives[authority.ownerRecordName] {
            archive = unsaved
            return true
        }
        let url = ownerArchiveURL(authority.ownerRecordName)
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                archive = TrackerCloudArchive(ownerRecordName: authority.ownerRecordName)
                return true
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue <= Self.maximumArchiveBytes else {
                throw TrackerCloudSyncError.storageUnavailable
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= Self.maximumArchiveBytes else {
                throw TrackerCloudSyncError.storageUnavailable
            }
            let decoded = try JSONDecoder().decode(TrackerCloudArchive.self, from: data)
            guard validArchive(decoded), decoded.ownerRecordName == authority.ownerRecordName else {
                throw TrackerCloudSyncError.storageUnavailable
            }
            archive = decoded
            return true
        } catch {
            unavailableOwners.insert(authority.ownerRecordName)
            archive = nil
            lastErrorMessage = "Tracker iCloud storage could not be read. Existing accounts and the saved journal were preserved."
            return false
        }
    }

    private func persist(_ value: TrackerCloudArchive) -> Bool {
        do {
            guard validArchive(value) else { throw TrackerCloudSyncError.storageUnavailable }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            guard data.count <= Self.maximumArchiveBytes else {
                throw TrackerCloudSyncError.storageUnavailable
            }
            try FileManager.default.createDirectory(
                at: archiveURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var directory = archiveURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let url = ownerArchiveURL(value.ownerRecordName)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
            let descriptor = Darwin.open(archiveURL.path, O_RDONLY)
            guard descriptor >= 0 else { throw TrackerCloudSyncError.storageUnavailable }
            defer { Darwin.close(descriptor) }
            guard Darwin.fsync(descriptor) == 0 else { throw TrackerCloudSyncError.storageUnavailable }
            return true
        } catch {
            lastErrorMessage = "Tracker iCloud changes could not be saved safely. Existing accounts were preserved; retry when device storage is available."
            return false
        }
    }

    private func validArchive(_ value: TrackerCloudArchive) -> Bool {
        value.schemaVersion == 1
            && !value.ownerRecordName.isEmpty
            && value.ownerRecordName.utf8.count <= 1_024
            && value.records.count <= TrackerCloudAccountRecord.maximumRecordCount
            && value.bootstrapCompletedKeys.count <= TrackerCloudAccountRecord.maximumRecordCount
            && value.pending.count <= value.records.count
            && value.retryCount >= 0 && value.retryCount <= 16
            && (value.retryNotBefore.map { $0.timeIntervalSince1970.isFinite } ?? true)
            && value.records.allSatisfy { key, record in
                key == record.recordName && TrackerCloudAccountRecord.validated(record)
            }
            && value.pending.allSatisfy { key, pending in
                guard let record = value.records[key],
                      (pending.kind == .disconnect) == (record.account == nil) else { return false }
                if let previous = pending.previousAccount {
                    guard previous.service == record.service,
                          TrackerCloudAccountRecord.bootstrap(
                            profileID: record.profileID,
                            account: previous
                          ) != nil else { return false }
                } else if pending.kind == .refresh {
                    return false
                }
                return true
            }
            && value.bootstrapCompletedKeys.allSatisfy {
                $0.hasPrefix("tracker-") && $0.utf8.count == 72
            }
    }

    private func ownerArchiveURL(_ owner: String) -> URL {
        archiveURL.appendingPathComponent(
            TrackerCloudAccountRecord.digest(Data(owner.utf8)) + ".json"
        )
    }

    private func recordFailure(_ error: Error) {
        var message = "Tracker accounts could not sync through iCloud. Existing accounts and pending changes were preserved; Eclipse will retry."
        var retryDelay: TimeInterval = 30
        if let cloudError = error as? CKError {
            switch cloudError.code {
            case .notAuthenticated:
                message = "Sign in to iCloud to sync tracker accounts. Existing tracker sign-ins stay on this device."
            case .quotaExceeded:
                message = "iCloud storage is full. Tracker account changes are waiting to upload."
            case .permissionFailure:
                message = "iCloud did not permit tracker account sync. Existing accounts were preserved."
            default:
                break
            }
            if let retry = cloudError.retryAfterSeconds, retry.isFinite {
                retryDelay = min(86_400, max(30, retry))
            }
        }
        if let failure = error as? TrackerCloudSyncError {
            switch failure {
            case .invalidPayload:
                message = "The tracker iCloud copy is incomplete or from an unsupported version. Existing accounts were preserved."
            case .storageUnavailable:
                message = "Tracker iCloud storage is unavailable. Existing accounts and pending changes were preserved."
            case .incompleteApply:
                message = "A tracker account could not be restored safely. Eclipse will retry without discarding its saved cloud copy."
            case .staleAuthority, .unavailable, .concurrentChanges:
                break
            }
        }
        lastErrorMessage = message
        guard var current = archive else { return }
        current.retryCount = min(16, current.retryCount + 1)
        retryDelay = max(retryDelay, min(3_600, 30 * pow(2, Double(current.retryCount - 1))))
        current.retryNotBefore = Date().addingTimeInterval(retryDelay)
        if persist(current) {
            archive = current
            unsavedArchives.removeValue(forKey: current.ownerRecordName)
        }
    }
}
