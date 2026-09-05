import CloudKit
import Foundation
import XCTest
@testable import Eclipse

@MainActor
private final class TrackerCloudTransportProbe: TrackerCloudSyncTransport {
    enum ProbeError: Error {
        case unavailable
    }

    var records: [String: TrackerCloudRemoteRecord] = [:]
    var fetchError: Error?
    var fetchCount = 0
    var saveCount = 0
    var didFetch: (() -> Void)?
    var didSave: (() -> Void)?
    var nextSaveConflict: TrackerCloudAccountRecord?
    var deleteCount = 0
    var deleteError: Error?
    var willDelete: (() -> Void)?

    func fetchAll() async throws -> [String: TrackerCloudRemoteRecord] {
        fetchCount += 1
        didFetch?()
        if let fetchError { throw fetchError }
        return records
    }

    func save(
        record: TrackerCloudAccountRecord,
        expected: TrackerCloudRemoteRecord?
    ) async throws -> TrackerCloudSaveResult {
        saveCount += 1
        if let conflict = nextSaveConflict {
            nextSaveConflict = nil
            let remote = TrackerCloudRemoteRecord(value: conflict)
            records[conflict.recordName] = remote
            return .conflict(remote)
        }
        if let current = records[record.recordName],
           current.value.mutationID != expected?.value.mutationID {
            return .conflict(current)
        }
        let saved = TrackerCloudRemoteRecord(value: record, systemFields: nil)
        records[record.recordName] = saved
        didSave?()
        return .saved(saved)
    }

    func deleteZone() async throws {
        deleteCount += 1
        willDelete?()
        if let deleteError { throw deleteError }
        records.removeAll()
    }
}

@MainActor
private final class TrackerCloudDeviceProbe {
    var state = TrackerState()

    func apply(service: TrackerService, account: TrackerAccount?) -> Bool {
        state.accounts.removeAll { $0.service == service }
        if let account { state.accounts.append(account) }
        return true
    }
}

final class TrackerCloudSyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func account(
        service: TrackerService = .trakt,
        suffix: String = "initial"
    ) -> TrackerAccount {
        TrackerAccount(
            service: service,
            username: "fixture-user",
            accessToken: "fixture-access-\(suffix)",
            refreshToken: "fixture-refresh-\(suffix)",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            userId: "fixture-provider-user"
        )
    }

    private func authorizedRecord(
        profileID: UUID = UUID(),
        service: TrackerService = .trakt,
        suffix: String = "initial"
    ) throws -> TrackerCloudAccountRecord {
        try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: profileID,
            service: service,
            account: account(service: service, suffix: suffix),
            previous: nil,
            kind: .authorization,
            previousAccount: nil,
            now: now
        ))
    }

    private func archiveURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackerCloudSyncTests-\(UUID().uuidString)")
            .appendingPathComponent("accounts", isDirectory: true)
    }

    @MainActor
    private func synchronize(
        _ manager: TrackerCloudSyncManager,
        device: TrackerCloudDeviceProbe,
        profileID: UUID,
        authority: TrackerCloudSyncAuthority
    ) async {
        await manager.synchronize(
            authority: authority,
            profileIDs: [profileID],
            capture: { _ in device.state },
            apply: { _, service, account in
                device.apply(service: service, account: account)
            },
            isCurrent: { true }
        )
    }

    func testCredentialRefreshCannotReviveAConcurrentDisconnect() throws {
        let connected = try authorizedRecord()
        let refreshed = try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: connected.profileID,
            service: .trakt,
            account: account(suffix: "rotated"),
            previous: connected,
            kind: .refresh,
            previousAccount: connected.account,
            now: now.addingTimeInterval(100)
        ))
        let disconnected = try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: connected.profileID,
            service: .trakt,
            account: nil,
            previous: connected,
            kind: .disconnect,
            previousAccount: connected.account,
            now: now.addingTimeInterval(10)
        ))

        XCTAssertNil(TrackerCloudAccountRecord.preferred(refreshed, disconnected).account)
        XCTAssertNil(TrackerCloudAccountRecord.preferred(disconnected, refreshed).account)
        XCTAssertEqual(refreshed.epoch, connected.epoch)
        XCTAssertGreaterThan(disconnected.epoch, refreshed.epoch)
    }

    func testSuccessfulSignInAfterDisconnectCreatesANewConnection() throws {
        let connected = try authorizedRecord()
        let disconnected = try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: connected.profileID,
            service: .trakt,
            account: nil,
            previous: connected,
            kind: .disconnect,
            previousAccount: connected.account,
            now: now.addingTimeInterval(1)
        ))
        let signedInAgain = try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: connected.profileID,
            service: .trakt,
            account: account(suffix: "signed-in-again"),
            previous: disconnected,
            kind: .authorization,
            previousAccount: nil,
            now: now.addingTimeInterval(2)
        ))

        XCTAssertEqual(
            TrackerCloudAccountRecord.preferred(disconnected, signedInAgain).account?.accessToken,
            "fixture-access-signed-in-again"
        )
        XCTAssertGreaterThan(signedInAgain.epoch, disconnected.epoch)
    }

    func testConcurrentSignInDoesNotOverrideADeletionItHasNotObserved() throws {
        let connected = try authorizedRecord()
        let disconnected = try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: connected.profileID,
            service: .trakt,
            account: nil,
            previous: connected,
            kind: .disconnect,
            previousAccount: connected.account,
            now: now.addingTimeInterval(1)
        ))
        let concurrentSignIn = try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: connected.profileID,
            service: .trakt,
            account: account(suffix: "concurrent-sign-in"),
            previous: connected,
            kind: .authorization,
            previousAccount: nil,
            now: now.addingTimeInterval(100)
        ))

        XCTAssertEqual(disconnected.epoch, concurrentSignIn.epoch)
        XCTAssertNil(TrackerCloudAccountRecord.preferred(disconnected, concurrentSignIn).account)
        XCTAssertNil(TrackerCloudAccountRecord.preferred(concurrentSignIn, disconnected).account)
    }

    func testARefreshFromAnOlderCredentialCannotReplaceTheCurrentCredential() throws {
        let connected = try authorizedRecord()
        let firstRefresh = try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: connected.profileID,
            service: .trakt,
            account: account(suffix: "first-refresh"),
            previous: connected,
            kind: .refresh,
            previousAccount: connected.account,
            now: now.addingTimeInterval(1)
        ))

        XCTAssertNil(TrackerCloudAccountRecord.authoring(
            profileID: connected.profileID,
            service: .trakt,
            account: account(suffix: "late-refresh"),
            previous: firstRefresh,
            kind: .refresh,
            previousAccount: connected.account,
            now: now.addingTimeInterval(2)
        ))
    }

    func testRefreshCannotAuthorizeAnAbsentOrDisconnectedAccount() throws {
        let connected = try authorizedRecord()
        let disconnected = try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: connected.profileID,
            service: .trakt,
            account: nil,
            previous: connected,
            kind: .disconnect,
            previousAccount: connected.account,
            now: now
        ))

        for previous in [nil, disconnected] as [TrackerCloudAccountRecord?] {
            XCTAssertNil(TrackerCloudAccountRecord.authoring(
                profileID: connected.profileID,
                service: .trakt,
                account: account(suffix: "rotated"),
                previous: previous,
                kind: .refresh,
                previousAccount: connected.account,
                now: now
            ))
        }
    }

    func testCredentialRecordsRejectCrossProfileAndCrossServiceAuthorship() throws {
        let connected = try authorizedRecord()

        XCTAssertNil(TrackerCloudAccountRecord.authoring(
            profileID: UUID(),
            service: .trakt,
            account: account(),
            previous: connected,
            kind: .authorization,
            previousAccount: nil,
            now: now
        ))
        XCTAssertNil(TrackerCloudAccountRecord.authoring(
            profileID: connected.profileID,
            service: .myAnimeList,
            account: account(service: .myAnimeList),
            previous: connected,
            kind: .authorization,
            previousAccount: nil,
            now: now
        ))
        XCTAssertNil(TrackerCloudAccountRecord.authoring(
            profileID: connected.profileID,
            service: .trakt,
            account: account(service: .anilist),
            previous: connected,
            kind: .authorization,
            previousAccount: nil,
            now: now
        ))
    }

    func testConcurrentCredentialsConvergeRegardlessOfMergeOrder() throws {
        let base = try authorizedRecord()
        let left = try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: base.profileID,
            service: .trakt,
            account: account(suffix: "left"),
            previous: base,
            kind: .refresh,
            previousAccount: base.account,
            now: now
        ))
        let right = try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: base.profileID,
            service: .trakt,
            account: account(suffix: "right"),
            previous: base,
            kind: .refresh,
            previousAccount: base.account,
            now: now
        ))

        XCTAssertEqual(
            TrackerCloudAccountRecord.preferred(left, right).mutationID,
            TrackerCloudAccountRecord.preferred(right, left).mutationID
        )
        XCTAssertEqual(
            TrackerCloudAccountRecord.preferred(left, left).mutationID,
            left.mutationID
        )
    }

    func testRecordNamesContainNoAccountIdentityOrCredential() throws {
        let record = try authorizedRecord()
        let credential = try XCTUnwrap(record.account)

        for privateValue in [
            credential.username,
            credential.userId,
            credential.accessToken,
            credential.refreshToken ?? "fixture-refresh"
        ] {
            XCTAssertFalse(record.recordName.contains(privateValue))
        }
        XCTAssertNotEqual(record.recordName, try authorizedRecord().recordName)
    }

    func testEmptyOrOversizedConnectedCredentialsCannotBePublished() throws {
        var invalid = account()
        invalid.accessToken = ""
        XCTAssertNil(TrackerCloudAccountRecord.authoring(
            profileID: UUID(),
            service: .trakt,
            account: invalid,
            previous: nil,
            kind: .authorization,
            previousAccount: nil,
            now: now
        ))

        invalid.accessToken = String(repeating: "x", count: 1_048_576)
        XCTAssertNil(TrackerCloudAccountRecord.authoring(
            profileID: UUID(),
            service: .trakt,
            account: invalid,
            previous: nil,
            kind: .authorization,
            previousAccount: nil,
            now: now
        ))
    }

    func testOneUnavailableKeychainItemInvalidatesTheEntireCapture() {
        var state = TrackerState()
        state.accounts = [account(service: .anilist), account(service: .trakt)]

        let materialized = TrackerPrivateCloudExportPolicy.materializedState(
            from: state,
            hydrate: { account in
                account.service == .trakt ? .unavailable : .found(account)
            }
        )

        XCTAssertNil(materialized)
    }

    func testMissingAccountPayloadIsRejectedButExplicitDisconnectRoundTrips() throws {
        let connected = try authorizedRecord()
        let disconnected = try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: connected.profileID,
            service: .trakt,
            account: nil,
            previous: connected,
            kind: .disconnect,
            previousAccount: connected.account,
            now: now
        ))
        let data = try TrackerCloudAccountRecord.encoded(disconnected)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object["account"] is NSNull)
        XCTAssertNil(try TrackerCloudAccountRecord.decoded(data).account)

        object.removeValue(forKey: "account")
        let incomplete = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try TrackerCloudAccountRecord.decoded(incomplete))
    }

    @available(iOS 17.0, tvOS 17.0, *)
    func testExplicitSnapshotRestoreCannotAuthorChangesFromAnUnreadableState() {
        var connected = TrackerState()
        connected.accounts = [account()]

        XCTAssertTrue(MediaStateTrackerSnapshotRestorePolicy.changes(before: nil, after: connected).isEmpty)
        XCTAssertTrue(MediaStateTrackerSnapshotRestorePolicy.changes(before: connected, after: nil).isEmpty)
    }

    @available(iOS 17.0, tvOS 17.0, *)
    func testExplicitSnapshotRestoreIgnoresUnchangedCredentialsAndUnrelatedPreferences() {
        var before = TrackerState()
        before.accounts = [account()]
        var after = before
        after.autoSyncRatings = !before.autoSyncRatings

        XCTAssertTrue(MediaStateTrackerSnapshotRestorePolicy.changes(before: before, after: after).isEmpty)
    }

    @available(iOS 17.0, tvOS 17.0, *)
    func testExplicitSnapshotRestoreAuthorsReplacedCredentialsAndDisconnections() throws {
        var before = TrackerState()
        before.accounts = [account(), account(service: .anilist)]
        var after = TrackerState()
        after.accounts = [account(suffix: "restored")]

        let changes = MediaStateTrackerSnapshotRestorePolicy.changes(before: before, after: after)
        XCTAssertEqual(changes.count, 2)
        let authorization = try XCTUnwrap(changes.first { $0.service == .trakt })
        XCTAssertEqual(authorization.kind, .authorization)
        XCTAssertEqual(authorization.account?.accessToken, "fixture-access-restored")
        XCTAssertEqual(authorization.previousAccount?.accessToken, "fixture-access-initial")
        let disconnect = try XCTUnwrap(changes.first { $0.service == .anilist })
        XCTAssertEqual(disconnect.kind, .disconnect)
        XCTAssertNil(disconnect.account)
        XCTAssertNotNil(disconnect.previousAccount)
    }

    @available(iOS 17.0, tvOS 17.0, *)
    func testExplicitSnapshotRestoreRejectsDuplicateProviderAccounts() {
        var invalid = TrackerState()
        invalid.accounts = [account(), account(suffix: "duplicate")]
        var connected = TrackerState()
        connected.accounts = [account()]

        XCTAssertTrue(MediaStateTrackerSnapshotRestorePolicy.changes(before: invalid, after: connected).isEmpty)
        XCTAssertTrue(MediaStateTrackerSnapshotRestorePolicy.changes(before: connected, after: invalid).isEmpty)
    }

    @MainActor
    func testColdEmptyTVFetchesConnectedCloudAccountWithoutPublishingDeletion() async throws {
        let remote = try authorizedRecord()
        let transport = TrackerCloudTransportProbe()
        transport.records[remote.recordName] = TrackerCloudRemoteRecord(value: remote, systemFields: nil)
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        let authority = TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1)
        var state = TrackerState()
        var appliedProfiles: [UUID] = []

        await manager.synchronize(
            authority: authority,
            profileIDs: [remote.profileID],
            capture: { _ in state },
            apply: { profileID, service, account in
                appliedProfiles.append(profileID)
                state.accounts.removeAll { $0.service == service }
                if let account { state.accounts.append(account) }
                return true
            },
            isCurrent: { true }
        )

        XCTAssertEqual(state.getAccount(for: .trakt)?.accessToken, remote.account?.accessToken)
        XCTAssertEqual(appliedProfiles, [remote.profileID])
        XCTAssertEqual(transport.saveCount, 0)
    }

    @MainActor
    func testUnavailableLocalCaptureCannotEraseRemoteAccounts() async throws {
        let remote = try authorizedRecord()
        let transport = TrackerCloudTransportProbe()
        transport.records[remote.recordName] = TrackerCloudRemoteRecord(value: remote, systemFields: nil)
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        var applyCount = 0

        await manager.synchronize(
            authority: TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1),
            profileIDs: [remote.profileID],
            capture: { _ in nil },
            apply: { _, _, _ in
                applyCount += 1
                return true
            },
            isCurrent: { true }
        )

        XCTAssertEqual(transport.saveCount, 0)
        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(transport.records[remote.recordName]?.value.account?.accessToken, remote.account?.accessToken)
    }

    @MainActor
    func testCloudFetchFailurePreservesLocalCredentialsAndPublishesNothing() async throws {
        let profileID = UUID()
        let transport = TrackerCloudTransportProbe()
        transport.fetchError = TrackerCloudTransportProbe.ProbeError.unavailable
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        var state = TrackerState()
        state.accounts = [account()]
        var applyCount = 0

        await manager.synchronize(
            authority: TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1),
            profileIDs: [profileID],
            capture: { _ in state },
            apply: { _, _, _ in
                applyCount += 1
                return true
            },
            isCurrent: { true }
        )

        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(transport.saveCount, 0)
        XCTAssertEqual(state.getAccount(for: .trakt)?.accessToken, "fixture-access-initial")
        XCTAssertNotNil(manager.lastErrorMessage)
    }

    @MainActor
    func testAccountABABoundaryDuringFetchCannotApplyOrPublish() async throws {
        let remote = try authorizedRecord()
        let transport = TrackerCloudTransportProbe()
        transport.records[remote.recordName] = TrackerCloudRemoteRecord(value: remote, systemFields: nil)
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        var currentGeneration: UInt64 = 1
        transport.didFetch = { currentGeneration = 3 }
        var applyCount = 0

        await manager.synchronize(
            authority: TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1),
            profileIDs: [remote.profileID],
            capture: { _ in TrackerState() },
            apply: { _, _, _ in
                applyCount += 1
                return true
            },
            isCurrent: { currentGeneration == 1 }
        )

        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(transport.saveCount, 0)
    }

    @MainActor
    func testAuthoritativeCloudDisconnectClearsOnlyItsTracker() async throws {
        let connected = try authorizedRecord()
        let disconnected = try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: connected.profileID,
            service: .trakt,
            account: nil,
            previous: connected,
            kind: .disconnect,
            previousAccount: connected.account,
            now: now
        ))
        let transport = TrackerCloudTransportProbe()
        transport.records[disconnected.recordName] = TrackerCloudRemoteRecord(value: disconnected, systemFields: nil)
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        var state = TrackerState()
        state.accounts = [account(), account(service: .anilist)]

        await manager.synchronize(
            authority: TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1),
            profileIDs: [connected.profileID],
            capture: { _ in state },
            apply: { _, service, account in
                state.accounts.removeAll { $0.service == service }
                if let account { state.accounts.append(account) }
                return true
            },
            isCurrent: { true }
        )

        XCTAssertNil(state.getAccount(for: .trakt))
        XCTAssertNotNil(state.getAccount(for: .anilist))
        XCTAssertNil(transport.records[disconnected.recordName]?.value.account)
    }

    @MainActor
    func testUnreadableJournalPreservesItsBytesAndLocalCredentials() async throws {
        let remote = try authorizedRecord()
        let transport = TrackerCloudTransportProbe()
        transport.records[remote.recordName] = TrackerCloudRemoteRecord(value: remote, systemFields: nil)
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let journalURL = url.appendingPathComponent(
            TrackerCloudAccountRecord.digest(Data("fixture-owner".utf8)) + ".json"
        )
        let unreadable = Data("unfinished tracker journal fixture".utf8)
        try unreadable.write(to: journalURL)
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        var applyCount = 0

        await manager.synchronize(
            authority: TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1),
            profileIDs: [remote.profileID],
            capture: { _ in TrackerState() },
            apply: { _, _, _ in
                applyCount += 1
                return true
            },
            isCurrent: { true }
        )

        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(transport.saveCount, 0)
        XCTAssertEqual(try Data(contentsOf: journalURL), unreadable)
        XCTAssertNotNil(manager.lastErrorMessage)
    }

    @MainActor
    func testFailedCredentialApplyCannotReportSuccessfulSynchronization() async throws {
        let remote = try authorizedRecord()
        let transport = TrackerCloudTransportProbe()
        transport.records[remote.recordName] = TrackerCloudRemoteRecord(value: remote, systemFields: nil)
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        var state = TrackerState()
        state.accounts = [account(suffix: "preserved")]

        await manager.synchronize(
            authority: TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1),
            profileIDs: [remote.profileID],
            capture: { _ in state },
            apply: { _, _, _ in false },
            isCurrent: { true }
        )

        XCTAssertNil(manager.lastSyncDate)
        XCTAssertNotNil(manager.lastErrorMessage)
        XCTAssertEqual(transport.saveCount, 0)
        XCTAssertEqual(state.getAccount(for: .trakt)?.accessToken, "fixture-access-preserved")
    }

    @MainActor
    func testConcurrentCloudDisconnectDefeatsAnInitialDeviceUpload() async throws {
        let connected = try authorizedRecord()
        let disconnected = try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: connected.profileID,
            service: .trakt,
            account: nil,
            previous: connected,
            kind: .disconnect,
            previousAccount: connected.account,
            now: now
        ))
        let transport = TrackerCloudTransportProbe()
        transport.nextSaveConflict = disconnected
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        var state = TrackerState()
        state.accounts = [account()]

        await manager.synchronize(
            authority: TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1),
            profileIDs: [connected.profileID],
            capture: { _ in state },
            apply: { _, service, account in
                state.accounts.removeAll { $0.service == service }
                if let account { state.accounts.append(account) }
                return true
            },
            isCurrent: { true }
        )

        XCTAssertEqual(transport.saveCount, 1)
        XCTAssertNil(state.getAccount(for: .trakt))
        XCTAssertNil(transport.records[disconnected.recordName]?.value.account)
    }

    @MainActor
    func testLegacySnapshotCannotReplaceCloudCredentialsOrReconnectDeletedService() async throws {
        let connected = try authorizedRecord(service: .myAnimeList, suffix: "cloud-rotated")
        let previousTrakt = try authorizedRecord(profileID: connected.profileID)
        let disconnected = try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: connected.profileID,
            service: .trakt,
            account: nil,
            previous: previousTrakt,
            kind: .disconnect,
            previousAccount: previousTrakt.account,
            now: now
        ))
        let transport = TrackerCloudTransportProbe()
        for record in [connected, disconnected] {
            transport.records[record.recordName] = TrackerCloudRemoteRecord(value: record)
        }
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        let authority = TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1)
        var state = TrackerState()

        await manager.synchronize(
            authority: authority,
            profileIDs: [connected.profileID],
            capture: { _ in state },
            apply: { _, service, account in
                state.accounts.removeAll { $0.service == service }
                if let account { state.accounts.append(account) }
                return true
            },
            isCurrent: { true }
        )

        var legacySnapshot = TrackerState()
        legacySnapshot.accounts = [account(service: .myAnimeList), account(service: .trakt)]
        legacySnapshot.autoSyncRatings = true
        let preserved = try XCTUnwrap(manager.preservingSynchronizedAccounts(
            in: legacySnapshot,
            profileID: connected.profileID,
            authority: authority
        ))

        XCTAssertEqual(preserved.getAccount(for: .myAnimeList)?.accessToken, "fixture-access-cloud-rotated")
        XCTAssertNil(preserved.getAccount(for: .trakt))
        XCTAssertTrue(preserved.autoSyncRatings)
        let otherProfile = try XCTUnwrap(manager.preservingSynchronizedAccounts(
            in: legacySnapshot,
            profileID: UUID(),
            authority: authority
        ))
        XCTAssertNotNil(otherProfile.getAccount(for: .trakt))
    }

    @MainActor
    func testMalformedRemoteIdentityPreventsAnyPartialApplyOrUpload() async throws {
        let remote = try authorizedRecord()
        let transport = TrackerCloudTransportProbe()
        transport.records[remote.recordName] = TrackerCloudRemoteRecord(value: remote)
        transport.records["wrong-record-identity"] = TrackerCloudRemoteRecord(value: remote)
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        var applyCount = 0

        await manager.synchronize(
            authority: TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1),
            profileIDs: [remote.profileID],
            capture: { _ in TrackerState() },
            apply: { _, _, _ in
                applyCount += 1
                return true
            },
            isCurrent: { true }
        )

        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(transport.saveCount, 0)
        XCTAssertNotNil(manager.lastErrorMessage)
    }

    @MainActor
    func testFailedJournalWriteRetainsConcreteRotationUntilStorageRecovers() async throws {
        let remote = try authorizedRecord()
        let transport = TrackerCloudTransportProbe()
        transport.records[remote.recordName] = TrackerCloudRemoteRecord(value: remote)
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("directory obstruction fixture".utf8).write(to: url)
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        let authority = TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1)
        var state = TrackerState()
        state.accounts = [account(suffix: "rotated")]
        var applyCount = 0

        XCTAssertFalse(manager.noteLocalChange(
            profileID: remote.profileID,
            service: .trakt,
            account: account(suffix: "rotated"),
            previousAccount: remote.account,
            kind: .refresh,
            authority: authority
        ))
        await manager.synchronize(
            authority: authority,
            profileIDs: [remote.profileID],
            capture: { _ in state },
            apply: { _, _, _ in
                applyCount += 1
                return true
            },
            isCurrent: { true }
        )

        XCTAssertEqual(transport.fetchCount, 0)
        XCTAssertEqual(applyCount, 0)
        XCTAssertNotNil(manager.lastErrorMessage)

        try FileManager.default.removeItem(at: url)
        await manager.synchronize(
            authority: authority,
            profileIDs: [remote.profileID],
            capture: { _ in state },
            apply: { _, service, account in
                state.accounts.removeAll { $0.service == service }
                if let account { state.accounts.append(account) }
                return true
            },
            isCurrent: { true }
        )

        XCTAssertEqual(transport.records[remote.recordName]?.value.account?.accessToken, "fixture-access-rotated")
        XCTAssertEqual(state.getAccount(for: .trakt)?.accessToken, "fixture-access-rotated")
        XCTAssertNotNil(manager.lastSyncDate)
    }

    @MainActor
    func testDeletingCloudCopySuppressesRefreshAndBootstrapUntilExplicitSignIn() async throws {
        let remote = try authorizedRecord()
        let transport = TrackerCloudTransportProbe()
        transport.records[remote.recordName] = TrackerCloudRemoteRecord(value: remote)
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let authority = TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1)
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        let deleted = await manager.deleteRemoteRecords(authority: authority, isCurrent: { true })
        XCTAssertTrue(deleted)
        var state = TrackerState()
        state.accounts = [account()]
        XCTAssertFalse(manager.noteLocalChange(
            profileID: remote.profileID,
            service: .trakt,
            account: account(suffix: "background-refresh"),
            previousAccount: account(),
            kind: .refresh,
            authority: authority
        ))

        await manager.synchronize(
            authority: authority,
            profileIDs: [remote.profileID],
            capture: { _ in state },
            apply: { _, service, account in
                state.accounts.removeAll { $0.service == service }
                if let account { state.accounts.append(account) }
                return true
            },
            isCurrent: { true }
        )

        XCTAssertEqual(transport.deleteCount, 1)
        XCTAssertEqual(transport.saveCount, 0)
        XCTAssertTrue(transport.records.isEmpty)
        XCTAssertNotNil(state.getAccount(for: .trakt))

        let signedIn = account(suffix: "explicit-sign-in")
        state.addOrUpdateAccount(signedIn)
        XCTAssertTrue(manager.noteLocalChange(
            profileID: remote.profileID,
            service: .trakt,
            account: signedIn,
            kind: .authorization,
            authority: authority
        ))
        await manager.synchronize(
            authority: authority,
            profileIDs: [remote.profileID],
            capture: { _ in state },
            apply: { _, service, account in
                state.accounts.removeAll { $0.service == service }
                if let account { state.accounts.append(account) }
                return true
            },
            isCurrent: { true }
        )
        XCTAssertEqual(transport.records[remote.recordName]?.value.account?.accessToken, "fixture-access-explicit-sign-in")
    }

    @MainActor
    func testCloudKitCodecReusesDeployedFieldsAndKeepsCredentialsInPayload() throws {
        let value = try authorizedRecord()
        let transport = TrackerCloudKitTransport()
        let encoded = try transport.encode(value)

        XCTAssertEqual(encoded.recordType, "EclipseMediaState")
        XCTAssertEqual(encoded.recordID.zoneID.zoneName, "EclipseTrackerAccountsV1")
        XCTAssertEqual(Set(encoded.allKeys()), [
            "kind", "payload", "modifiedAt", "revision", "schemaVersion",
            "settingScope", "isCompleted", "isExplicitReset"
        ])
        for key in encoded.allKeys() where key != "payload" {
            let description = String(describing: encoded[key])
            XCTAssertFalse(description.contains("fixture-access"))
            XCTAssertFalse(description.contains("fixture-refresh"))
            XCTAssertFalse(description.contains("fixture-user"))
            XCTAssertFalse(description.contains("fixture-provider-user"))
        }
        let decoded = try transport.decode(encoded)
        XCTAssertEqual(decoded.value.account?.accessToken, value.account?.accessToken)
        XCTAssertEqual(decoded.value.profileID, value.profileID)
    }

    @MainActor
    func testCloudKitCodecRejectsForeignZoneAndMetadataPayloadDisagreement() throws {
        let value = try authorizedRecord()
        let transport = TrackerCloudKitTransport()
        let foreign = CKRecord(
            recordType: "EclipseMediaState",
            recordID: CKRecord.ID(
                recordName: value.recordName,
                zoneID: CKRecordZone.ID(zoneName: "EclipseMediaState", ownerName: CKCurrentUserDefaultName)
            )
        )
        let original = try transport.encode(value)
        for key in original.allKeys() { foreign[key] = original[key] }
        XCTAssertThrowsError(try transport.decode(foreign))

        let mismatched = try transport.encode(value)
        mismatched["revision"] = NSNumber(value: value.revision + 1)
        XCTAssertThrowsError(try transport.decode(mismatched))

        let wrongPayload = try transport.encode(value)
        wrongPayload["payload"] = try TrackerCloudAccountRecord.encoded(authorizedRecord()) as CKRecordValue
        XCTAssertThrowsError(try transport.decode(wrongPayload))
    }

    @MainActor
    func testMobileAndTVMigrateConnectRefreshAndDisconnectAcrossIndependentJournals() async throws {
        let profileID = UUID()
        let authority = TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1)
        let transport = TrackerCloudTransportProbe()
        let mobileURL = archiveURL()
        let tvURL = archiveURL()
        defer {
            try? FileManager.default.removeItem(at: mobileURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: tvURL.deletingLastPathComponent())
        }
        let mobileManager = TrackerCloudSyncManager(transport: transport, archiveURL: mobileURL)
        let tvManager = TrackerCloudSyncManager(transport: transport, archiveURL: tvURL)
        let mobile = TrackerCloudDeviceProbe()
        let television = TrackerCloudDeviceProbe()
        mobile.state.accounts = [account()]
        mobile.state.autoSyncRatings = true
        television.state.autoSyncRatings = false

        await synchronize(mobileManager, device: mobile, profileID: profileID, authority: authority)
        await synchronize(tvManager, device: television, profileID: profileID, authority: authority)
        XCTAssertEqual(television.state.getAccount(for: .trakt)?.accessToken, "fixture-access-initial")

        let malAccount = account(service: .myAnimeList, suffix: "tv-connected")
        television.state.addOrUpdateAccount(malAccount)
        XCTAssertTrue(tvManager.noteLocalChange(
            profileID: profileID,
            service: .myAnimeList,
            account: malAccount,
            kind: .authorization,
            authority: authority
        ))
        await synchronize(tvManager, device: television, profileID: profileID, authority: authority)
        await synchronize(mobileManager, device: mobile, profileID: profileID, authority: authority)
        XCTAssertEqual(mobile.state.getAccount(for: .myAnimeList)?.accessToken, "fixture-access-tv-connected")

        let previousTrakt = try XCTUnwrap(mobile.state.getAccount(for: .trakt))
        let rotatedTrakt = account(suffix: "mobile-rotated")
        mobile.state.addOrUpdateAccount(rotatedTrakt)
        XCTAssertTrue(mobileManager.noteLocalChange(
            profileID: profileID,
            service: .trakt,
            account: rotatedTrakt,
            previousAccount: previousTrakt,
            kind: .refresh,
            authority: authority
        ))
        await synchronize(mobileManager, device: mobile, profileID: profileID, authority: authority)
        await synchronize(tvManager, device: television, profileID: profileID, authority: authority)
        XCTAssertEqual(television.state.getAccount(for: .trakt)?.accessToken, "fixture-access-mobile-rotated")
        XCTAssertEqual(television.state.getAccount(for: .trakt)?.refreshToken, "fixture-refresh-mobile-rotated")

        television.state.accounts.removeAll { $0.service == .trakt }
        XCTAssertTrue(tvManager.noteLocalChange(
            profileID: profileID,
            service: .trakt,
            account: nil,
            previousAccount: rotatedTrakt,
            kind: .disconnect,
            authority: authority
        ))
        await synchronize(tvManager, device: television, profileID: profileID, authority: authority)
        await synchronize(mobileManager, device: mobile, profileID: profileID, authority: authority)

        XCTAssertNil(mobile.state.getAccount(for: .trakt))
        XCTAssertNil(television.state.getAccount(for: .trakt))
        XCTAssertNotNil(mobile.state.getAccount(for: .myAnimeList))
        XCTAssertNotNil(television.state.getAccount(for: .myAnimeList))
        XCTAssertTrue(mobile.state.autoSyncRatings)
        XCTAssertFalse(television.state.autoSyncRatings)
        XCTAssertNil(mobileManager.lastErrorMessage)
        XCTAssertNil(tvManager.lastErrorMessage)
    }

    @MainActor
    func testOfflineRotationSurvivesManagerRestartAndUploadsItsPersistedLineage() async throws {
        let profileID = UUID()
        let authority = TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1)
        let transport = TrackerCloudTransportProbe()
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let initialManager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        let device = TrackerCloudDeviceProbe()
        device.state.accounts = [account()]
        await synchronize(initialManager, device: device, profileID: profileID, authority: authority)
        let fetchesBeforeOfflineChange = transport.fetchCount
        let rotated = account(suffix: "persisted-offline")
        device.state.addOrUpdateAccount(rotated)
        XCTAssertTrue(initialManager.noteLocalChange(
            profileID: profileID,
            service: .trakt,
            account: rotated,
            previousAccount: account(),
            kind: .refresh,
            authority: authority
        ))
        XCTAssertEqual(transport.fetchCount, fetchesBeforeOfflineChange)
        let restartedManager = TrackerCloudSyncManager(transport: transport, archiveURL: url)

        await synchronize(restartedManager, device: device, profileID: profileID, authority: authority)

        let key = TrackerCloudAccountRecord.recordName(profileID: profileID, service: .trakt)
        XCTAssertEqual(transport.records[key]?.value.account?.accessToken, "fixture-access-persisted-offline")
        XCTAssertEqual(transport.records[key]?.value.account?.refreshToken, "fixture-refresh-persisted-offline")
        XCTAssertEqual(device.state.getAccount(for: .trakt)?.accessToken, "fixture-access-persisted-offline")
        XCTAssertNil(restartedManager.lastErrorMessage)
    }

    @MainActor
    func testUnrosteredPendingCredentialsWaitForExplicitDeletionAuthority() async throws {
        let profileID = UUID()
        let authority = TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1)
        let transport = TrackerCloudTransportProbe()
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        XCTAssertTrue(manager.noteLocalChange(
            profileID: profileID,
            service: .trakt,
            account: account(),
            kind: .authorization,
            authority: authority
        ))

        await manager.synchronize(
            authority: authority,
            profileIDs: [],
            capture: { _ in nil },
            apply: { _, _, _ in false },
            isCurrent: { true }
        )
        XCTAssertEqual(transport.saveCount, 0)
        XCTAssertNil(manager.nextRetryDate)

        await manager.synchronize(
            authority: authority,
            profileIDs: [],
            deletedProfileIDs: [profileID],
            capture: { _ in nil },
            apply: { _, _, _ in false },
            isCurrent: { true }
        )

        let key = TrackerCloudAccountRecord.recordName(profileID: profileID, service: .trakt)
        XCTAssertEqual(transport.saveCount, 1)
        XCTAssertNotNil(transport.records[key])
        XCTAssertNil(transport.records[key]?.value.account)
    }

    @MainActor
    func testProfileAuthorityChangingDuringApplyStopsTheRemainingAccounts() async throws {
        let first = try authorizedRecord(service: .anilist)
        let second = try authorizedRecord(profileID: first.profileID, service: .trakt)
        let transport = TrackerCloudTransportProbe()
        for record in [first, second] {
            transport.records[record.recordName] = TrackerCloudRemoteRecord(value: record)
        }
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        var generation = 1
        var applied: [TrackerService] = []

        await manager.synchronize(
            authority: TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1),
            profileIDs: [first.profileID],
            capture: { _ in TrackerState() },
            apply: { _, service, _ in
                applied.append(service)
                generation = 3
                return true
            },
            isCurrent: { generation == 1 }
        )

        XCTAssertEqual(applied, [.anilist])
        XCTAssertEqual(transport.saveCount, 0)
        XCTAssertNil(manager.lastSyncDate)
    }

    @MainActor
    func testAuthorizationFollowedByRefreshBeforeFirstFetchRetainsTheSignInIntent() async throws {
        let original = try authorizedRecord()
        let remote = try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: original.profileID,
            service: .trakt,
            account: account(suffix: "older-remote-sign-in"),
            previous: original,
            kind: .authorization,
            previousAccount: nil,
            now: now
        ))
        let transport = TrackerCloudTransportProbe()
        transport.records[remote.recordName] = TrackerCloudRemoteRecord(value: remote)
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        let authority = TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1)
        let signedIn = account(suffix: "new-local-sign-in")
        let rotated = account(suffix: "new-local-rotated")
        let device = TrackerCloudDeviceProbe()
        device.state.accounts = [rotated]
        XCTAssertTrue(manager.noteLocalChange(
            profileID: remote.profileID,
            service: .trakt,
            account: signedIn,
            kind: .authorization,
            authority: authority
        ))
        XCTAssertTrue(manager.noteLocalChange(
            profileID: remote.profileID,
            service: .trakt,
            account: rotated,
            previousAccount: signedIn,
            kind: .refresh,
            authority: authority
        ))

        await synchronize(manager, device: device, profileID: remote.profileID, authority: authority)

        XCTAssertEqual(transport.records[remote.recordName]?.value.account?.accessToken, "fixture-access-new-local-rotated")
        XCTAssertEqual(transport.records[remote.recordName]?.value.account?.refreshToken, "fixture-refresh-new-local-rotated")
        XCTAssertEqual(device.state.getAccount(for: .trakt)?.accessToken, "fixture-access-new-local-rotated")
        XCTAssertNil(manager.lastErrorMessage)
    }

    @MainActor
    func testLegacyCredentialsArrivingAfterAnEmptyFirstPassMigrateToTV() async throws {
        let profileID = UUID()
        let authority = TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1)
        let transport = TrackerCloudTransportProbe()
        let mobileURL = archiveURL()
        let tvURL = archiveURL()
        defer {
            try? FileManager.default.removeItem(at: mobileURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: tvURL.deletingLastPathComponent())
        }
        let mobileManager = TrackerCloudSyncManager(transport: transport, archiveURL: mobileURL)
        let mobile = TrackerCloudDeviceProbe()

        await synchronize(mobileManager, device: mobile, profileID: profileID, authority: authority)
        XCTAssertTrue(transport.records.isEmpty)
        XCTAssertEqual(transport.saveCount, 0)

        mobile.state.accounts = [account(suffix: "late-legacy-snapshot")]
        await synchronize(mobileManager, device: mobile, profileID: profileID, authority: authority)
        let television = TrackerCloudDeviceProbe()
        let tvManager = TrackerCloudSyncManager(transport: transport, archiveURL: tvURL)
        await synchronize(tvManager, device: television, profileID: profileID, authority: authority)

        XCTAssertEqual(transport.saveCount, 1)
        XCTAssertEqual(television.state.getAccount(for: .trakt)?.accessToken, "fixture-access-late-legacy-snapshot")
        XCTAssertEqual(television.state.getAccount(for: .trakt)?.refreshToken, "fixture-refresh-late-legacy-snapshot")
        XCTAssertNil(mobileManager.lastErrorMessage)
        XCTAssertNil(tvManager.lastErrorMessage)
    }

    @MainActor
    func testLateLegacyCredentialsCannotOverrideAnObservedCloudDisconnect() async throws {
        let connected = try authorizedRecord()
        let disconnected = try XCTUnwrap(TrackerCloudAccountRecord.authoring(
            profileID: connected.profileID,
            service: .trakt,
            account: nil,
            previous: connected,
            kind: .disconnect,
            previousAccount: connected.account,
            now: now
        ))
        let transport = TrackerCloudTransportProbe()
        transport.records[disconnected.recordName] = TrackerCloudRemoteRecord(value: disconnected)
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        let authority = TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1)
        let device = TrackerCloudDeviceProbe()
        await synchronize(manager, device: device, profileID: connected.profileID, authority: authority)

        device.state.accounts = [account(suffix: "stale-legacy-snapshot")]
        await synchronize(manager, device: device, profileID: connected.profileID, authority: authority)

        XCTAssertEqual(transport.saveCount, 0)
        XCTAssertNil(device.state.getAccount(for: .trakt))
        XCTAssertNil(transport.records[disconnected.recordName]?.value.account)
    }

    @MainActor
    func testChangingCloudOwnerClearsThePreviousOwnersSuccessAndErrorStatus() async throws {
        let profileID = UUID()
        let transport = TrackerCloudTransportProbe()
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        let firstOwner = TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner-a", generation: 1)
        let secondOwner = TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner-b", generation: 2)
        let device = TrackerCloudDeviceProbe()
        await synchronize(manager, device: device, profileID: profileID, authority: firstOwner)
        XCTAssertNotNil(manager.lastSyncDate)

        transport.fetchError = TrackerCloudTransportProbe.ProbeError.unavailable
        await synchronize(manager, device: device, profileID: profileID, authority: firstOwner)
        XCTAssertNotNil(manager.lastErrorMessage)
        var statusWasClearedBeforeFetching = false
        transport.didFetch = {
            statusWasClearedBeforeFetching = manager.lastSyncDate == nil
                && manager.lastErrorMessage == nil
        }

        await synchronize(manager, device: device, profileID: profileID, authority: secondOwner)

        XCTAssertTrue(statusWasClearedBeforeFetching)
        XCTAssertNil(manager.lastSyncDate)
        XCTAssertNotNil(manager.lastErrorMessage)
    }

    func testFreshDeviceCanDeleteTheVerifiedCloudCopyWithoutClaimingItsLocalArchive() {
        XCTAssertTrue(MediaStateCloudKitDeletionAuthorityPolicy.canDelete(
            verifiedCurrentOwnerRecordName: "fixture-verified-owner",
            startingGeneration: 7,
            currentGeneration: 7,
            isDeletionInProgress: true,
            isBlocked: false
        ))
        XCTAssertFalse(MediaStateCloudKitDeletionAuthorityPolicy.shouldResetArchive(
            archiveOwnerRecordName: nil,
            deletedOwnerRecordName: "fixture-verified-owner"
        ))
    }

    func testCloudDeletionRejectsTheSameOwnerAfterAnAccountABABoundary() {
        XCTAssertFalse(MediaStateCloudKitDeletionAuthorityPolicy.canDelete(
            verifiedCurrentOwnerRecordName: "fixture-verified-owner",
            startingGeneration: 7,
            currentGeneration: 9,
            isDeletionInProgress: true,
            isBlocked: false
        ))
    }

    func testCloudDeletionRequiresVerifiedIdentityAndAnUnblockedActiveOperation() {
        for owner in [nil, "", String(repeating: "x", count: 1_025)] as [String?] {
            XCTAssertFalse(MediaStateCloudKitDeletionAuthorityPolicy.canDelete(
                verifiedCurrentOwnerRecordName: owner,
                startingGeneration: 7,
                currentGeneration: 7,
                isDeletionInProgress: true,
                isBlocked: false
            ))
        }
        XCTAssertFalse(MediaStateCloudKitDeletionAuthorityPolicy.canDelete(
            verifiedCurrentOwnerRecordName: "fixture-verified-owner",
            startingGeneration: 7,
            currentGeneration: 7,
            isDeletionInProgress: false,
            isBlocked: false
        ))
        XCTAssertFalse(MediaStateCloudKitDeletionAuthorityPolicy.canDelete(
            verifiedCurrentOwnerRecordName: "fixture-verified-owner",
            startingGeneration: 7,
            currentGeneration: 7,
            isDeletionInProgress: true,
            isBlocked: true
        ))
    }

    func testDeletingOneCloudAccountResetsOnlyItsMatchingLocalArchive() {
        XCTAssertTrue(MediaStateCloudKitDeletionAuthorityPolicy.shouldResetArchive(
            archiveOwnerRecordName: "fixture-deleted-owner",
            deletedOwnerRecordName: "fixture-deleted-owner"
        ))
        for archiveOwner in [nil, "", "fixture-other-owner"] as [String?] {
            XCTAssertFalse(MediaStateCloudKitDeletionAuthorityPolicy.shouldResetArchive(
                archiveOwnerRecordName: archiveOwner,
                deletedOwnerRecordName: "fixture-deleted-owner"
            ))
        }
        XCTAssertFalse(MediaStateCloudKitDeletionAuthorityPolicy.shouldResetArchive(
            archiveOwnerRecordName: "",
            deletedOwnerRecordName: ""
        ))
    }

    @MainActor
    func testExplicitCloudDeletionPreservesUnreadableJournalAndDurablySuppressesRestartUploads() async throws {
        let remote = try authorizedRecord()
        let authority = TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1)
        let transport = TrackerCloudTransportProbe()
        transport.records[remote.recordName] = TrackerCloudRemoteRecord(value: remote)
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let ownerHash = TrackerCloudAccountRecord.digest(Data(authority.ownerRecordName.utf8))
        let journalURL = url.appendingPathComponent(ownerHash + ".json")
        let original = Data("unreadable tracker journal fixture".utf8)
        try original.write(to: journalURL)
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        let device = TrackerCloudDeviceProbe()
        device.state.accounts = [account()]

        await synchronize(manager, device: device, profileID: remote.profileID, authority: authority)
        XCTAssertEqual(transport.fetchCount, 0)
        XCTAssertEqual(transport.saveCount, 0)
        XCTAssertEqual(try Data(contentsOf: journalURL), original)

        var deletionWasDurablySuppressedBeforeRequest = false
        transport.willDelete = {
            guard let data = try? Data(contentsOf: journalURL),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            deletionWasDurablySuppressedBeforeRequest = object["bootstrapSuppressed"] as? Bool == true
                && object["remoteDeletionPending"] as? Bool == true
                && object["ownerRecordName"] as? String == authority.ownerRecordName
                && (object["pending"] as? [String: Any])?.isEmpty == true
        }
        let deleted = await manager.deleteRemoteRecords(authority: authority, isCurrent: { true })

        XCTAssertTrue(deleted)
        XCTAssertTrue(deletionWasDurablySuppressedBeforeRequest)
        XCTAssertEqual(transport.deleteCount, 1)
        XCTAssertTrue(transport.records.isEmpty)
        let preserved = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(ownerHash + ".unreadable-") }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preserved.first)), original)
        XCTAssertNotNil(device.state.getAccount(for: .trakt))

        let restarted = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        XCTAssertFalse(restarted.noteLocalChange(
            profileID: remote.profileID,
            service: .trakt,
            account: account(suffix: "background-refresh"),
            previousAccount: account(),
            kind: .refresh,
            authority: authority
        ))
        await synchronize(restarted, device: device, profileID: remote.profileID, authority: authority)

        XCTAssertEqual(transport.saveCount, 0)
        XCTAssertTrue(transport.records.isEmpty)
        XCTAssertNotNil(device.state.getAccount(for: .trakt))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preserved.first)), original)
    }

    @MainActor
    func testCloudDeletionDoesNotProceedWhenTheUnreadableJournalCannotBePreserved() async throws {
        let remote = try authorizedRecord()
        let authority = TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1)
        let transport = TrackerCloudTransportProbe()
        transport.records[remote.recordName] = TrackerCloudRemoteRecord(value: remote)
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journalURL = url.appendingPathComponent(
            TrackerCloudAccountRecord.digest(Data(authority.ownerRecordName.utf8)) + ".json"
        )
        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true)
        let originalURL = journalURL.appendingPathComponent("preserved-fixture")
        let original = Data("existing unreadable directory contents".utf8)
        try original.write(to: originalURL)
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)

        let deleted = await manager.deleteRemoteRecords(authority: authority, isCurrent: { true })

        XCTAssertFalse(deleted)
        XCTAssertEqual(transport.deleteCount, 0)
        XCTAssertEqual(transport.records[remote.recordName]?.value.account?.accessToken, remote.account?.accessToken)
        XCTAssertEqual(try Data(contentsOf: originalURL), original)
        XCTAssertNotNil(manager.lastErrorMessage)
    }

    @MainActor
    func testStaleExplicitDeletionDoesNotQuarantineOrReplaceTheJournal() async throws {
        let remote = try authorizedRecord()
        let authority = TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1)
        let transport = TrackerCloudTransportProbe()
        transport.records[remote.recordName] = TrackerCloudRemoteRecord(value: remote)
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let journalURL = url.appendingPathComponent(
            TrackerCloudAccountRecord.digest(Data(authority.ownerRecordName.utf8)) + ".json"
        )
        let original = Data("unreadable original authority fixture".utf8)
        try original.write(to: journalURL)
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)

        let deleted = await manager.deleteRemoteRecords(authority: authority, isCurrent: { false })

        XCTAssertFalse(deleted)
        XCTAssertEqual(transport.deleteCount, 0)
        XCTAssertEqual(try Data(contentsOf: journalURL), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.path), [journalURL.lastPathComponent])
        XCTAssertNotNil(transport.records[remote.recordName]?.value.account)
    }

    @MainActor
    func testFailedCloudDeletionKeepsItsDurableSuppressionAcrossRestart() async throws {
        let remote = try authorizedRecord()
        let authority = TrackerCloudSyncAuthority(ownerRecordName: "fixture-owner", generation: 1)
        let transport = TrackerCloudTransportProbe()
        transport.records[remote.recordName] = TrackerCloudRemoteRecord(value: remote)
        transport.deleteError = TrackerCloudTransportProbe.ProbeError.unavailable
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let journalURL = url.appendingPathComponent(
            TrackerCloudAccountRecord.digest(Data(authority.ownerRecordName.utf8)) + ".json"
        )
        try Data("unreadable deletion retry fixture".utf8).write(to: journalURL)
        let manager = TrackerCloudSyncManager(transport: transport, archiveURL: url)

        let deleted = await manager.deleteRemoteRecords(authority: authority, isCurrent: { true })
        XCTAssertFalse(deleted)
        XCTAssertEqual(transport.deleteCount, 1)
        XCTAssertNotNil(transport.records[remote.recordName]?.value.account)
        let restarted = TrackerCloudSyncManager(transport: transport, archiveURL: url)
        let device = TrackerCloudDeviceProbe()
        device.state.accounts = [account()]
        await synchronize(restarted, device: device, profileID: remote.profileID, authority: authority)

        XCTAssertEqual(transport.fetchCount, 0)
        XCTAssertEqual(transport.saveCount, 0)
        XCTAssertNotNil(device.state.getAccount(for: .trakt))
        XCTAssertNotNil(restarted.lastErrorMessage)
    }
}
