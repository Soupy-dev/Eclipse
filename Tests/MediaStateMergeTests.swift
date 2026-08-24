import CloudKit
import UIKit
import XCTest
@testable import Eclipse

private actor MediaStateCloudLaneProbe {
    private var activeCount = 0
    private var maximumActiveCount = 0

    func enter() {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
    }

    func leave() {
        activeCount -= 1
    }

    func maximum() -> Int {
        maximumActiveCount
    }
}

private enum MediaStateCloudKitTaskContextProbe {
    @TaskLocal static var isInsideDelegateCallback = false
}

final class MediaStateMergeTests: XCTestCase {
    private func wireEncode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func wireDecode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }

    @available(iOS 17.0, tvOS 17.0, *)
    func testCloudKitRecordRoundTripCarriesResetLineageInExistingPayloadField() throws {
        let name = MediaStateRecordName.make(
            kind: .movieProgress,
            identifier: "901",
            profileID: ProfileManager.defaultProfileID
        )
        var entry = MovieProgressEntry(id: 901, title: "CloudKit reset lineage")
        entry.currentTime = 12
        entry.totalDuration = 100
        entry.lastUpdated = Date(timeIntervalSince1970: 1_700_000_030)
        let payload = try wireEncode(entry)
        let resetAt = Date(timeIntervalSince1970: 1_700_000_020)
        let envelope = MediaStateEnvelope(
            recordName: name,
            kind: .movieProgress,
            payload: payload,
            modifiedAt: entry.lastUpdated,
            revision: 8,
            resetAt: resetAt
        )
        let zoneID = CKRecordZone.ID(
            zoneName: "EclipseMediaState",
            ownerName: CKCurrentUserDefaultName
        )
        let recordID = CKRecord.ID(recordName: name, zoneID: zoneID)

        let record = try XCTUnwrap(MediaStateCloudKitRecordCodec.record(
            from: envelope,
            recordID: recordID,
            recordType: "EclipseMediaState"
        ))
        XCTAssertEqual(Set(record.allKeys()), [
            "kind", "payload", "modifiedAt", "revision", "settingScope",
            "isCompleted", "isExplicitReset", "schemaVersion"
        ])
        XCTAssertFalse(
            record.allKeys().contains("resetAt"),
            "A new CKRecord field would require a Production schema deployment"
        )
        let wirePayload = try XCTUnwrap(record["payload"] as? Data)
        XCTAssertNotEqual(wirePayload, payload)
        let oldReaderValue = try wireDecode(MovieProgressEntry.self, from: wirePayload)
        XCTAssertEqual(oldReaderValue.currentTime, entry.currentTime)
        XCTAssertEqual(oldReaderValue.lastUpdated, entry.lastUpdated)

        let decoded = try XCTUnwrap(MediaStateCloudKitRecordCodec.envelope(from: record))
        XCTAssertEqual(decoded.payload, payload, "The private marker must not leak into canonical state")
        XCTAssertEqual(decoded.resetAt, resetAt)
        XCTAssertEqual(decoded.recordName, envelope.recordName)
        XCTAssertEqual(decoded.kind, envelope.kind)
        XCTAssertEqual(decoded.modifiedAt, envelope.modifiedAt)
        XCTAssertEqual(decoded.revision, envelope.revision)
        XCTAssertEqual(decoded.schemaVersion, envelope.schemaVersion)

        var archiveWrittenByOlderBuild = envelope
        archiveWrittenByOlderBuild.payload = wirePayload
        archiveWrittenByOlderBuild.resetAt = nil
        let migratedArchive = MediaStateCloudKitArchiveMigration.repaired(
            archiveWrittenByOlderBuild
        )
        XCTAssertEqual(migratedArchive.payload, payload)
        XCTAssertEqual(migratedArchive.resetAt, resetAt)

        let submillisecondReset = Date(
            timeIntervalSince1970: 1_700_000_060.1236
        )
        var resetEntry = entry
        resetEntry.currentTime = 0
        resetEntry.lastUpdated = submillisecondReset
        let explicitEnvelope = MediaStateEnvelope(
            recordName: name,
            kind: .movieProgress,
            payload: try wireEncode(resetEntry),
            modifiedAt: submillisecondReset,
            revision: 9,
            isExplicitReset: true,
            resetAt: submillisecondReset
        )
        let explicitRecord = try XCTUnwrap(MediaStateCloudKitRecordCodec.record(
            from: explicitEnvelope,
            recordID: recordID,
            recordType: "EclipseMediaState"
        ))
        let decodedExplicit = try XCTUnwrap(
            MediaStateCloudKitRecordCodec.envelope(from: explicitRecord)
        )
        XCTAssertEqual(
            decodedExplicit.resetAt,
            submillisecondReset,
            "Millisecond marker rounding must not make an explicit reset newer than its record"
        )

        var submillisecondArchiveWrittenByOlderBuild = explicitEnvelope
        submillisecondArchiveWrittenByOlderBuild.payload = try XCTUnwrap(
            explicitRecord["payload"] as? Data
        )
        submillisecondArchiveWrittenByOlderBuild.resetAt = nil
        let migratedSubmillisecondArchive = MediaStateCloudKitArchiveMigration.repaired(
            submillisecondArchiveWrittenByOlderBuild
        )
        XCTAssertEqual(migratedSubmillisecondArchive.payload, explicitEnvelope.payload)
        XCTAssertEqual(migratedSubmillisecondArchive.resetAt, submillisecondReset)
        XCTAssertNil(MediaStateEnvelopeValidator.rejectionReason(
            for: migratedSubmillisecondArchive,
            dictionaryKey: name,
            allowsSystemFields: true
        ))
    }

    @available(iOS 17.0, tvOS 17.0, *)
    func testCloudKitCodecUpgradesLegacyExplicitResetAndPreservesUnknownPayloadKeys() throws {
        let name = MediaStateRecordName.make(
            kind: .movieProgress,
            identifier: "902",
            profileID: ProfileManager.defaultProfileID
        )
        var entry = MovieProgressEntry(id: 902, title: "Legacy reset")
        entry.lastUpdated = Date(timeIntervalSince1970: 1_700_000_040)
        var payload = try wireEncode(entry)
        let collisionValue = "resetAtMilliseconds:1700000040000:payloadSHA256:"
            + String(repeating: "0", count: 64)
        let unknownMember = Data(
            "\"\(MediaStateCloudKitPayloadCodec.resetLineageKey)\":\"\(collisionValue)\",".utf8
        )
        payload.insert(contentsOf: unknownMember, at: payload.index(after: payload.startIndex))

        let zoneID = CKRecordZone.ID(
            zoneName: "EclipseMediaState",
            ownerName: CKCurrentUserDefaultName
        )
        let recordID = CKRecord.ID(recordName: name, zoneID: zoneID)
        let legacy = CKRecord(recordType: "EclipseMediaState", recordID: recordID)
        legacy["kind"] = MediaStateKind.movieProgress.rawValue as CKRecordValue
        legacy["payload"] = payload as CKRecordValue
        legacy["modifiedAt"] = entry.lastUpdated as CKRecordValue
        legacy["revision"] = NSNumber(value: 2)
        legacy["settingScope"] = MediaStateSettingScope.shared.rawValue as CKRecordValue
        legacy["isCompleted"] = NSNumber(value: false)
        legacy["isExplicitReset"] = NSNumber(value: true)
        legacy["schemaVersion"] = NSNumber(value: 1)

        let decodedLegacy = try XCTUnwrap(
            MediaStateCloudKitRecordCodec.envelope(from: legacy)
        )
        XCTAssertEqual(decodedLegacy.payload, payload)
        XCTAssertEqual(
            decodedLegacy.resetAt,
            entry.lastUpdated,
            "The existing explicit-reset flag and modifiedAt are the legacy lineage fallback"
        )

        let upgraded = try XCTUnwrap(MediaStateCloudKitRecordCodec.record(
            from: decodedLegacy,
            recordID: recordID,
            recordType: "EclipseMediaState"
        ))
        XCTAssertFalse(upgraded.allKeys().contains("resetAt"))
        let upgradedWirePayload = try XCTUnwrap(upgraded["payload"] as? Data)
        _ = try wireDecode(MovieProgressEntry.self, from: upgradedWirePayload)
        let roundTripped = try XCTUnwrap(
            MediaStateCloudKitRecordCodec.envelope(from: upgraded)
        )
        XCTAssertEqual(roundTripped.payload, payload)
        XCTAssertEqual(roundTripped.resetAt, entry.lastUpdated)
    }

    @available(iOS 17.0, tvOS 17.0, *)
    func testCloudKitResetMarkerHonorsTheExistingPerRecordPayloadCap() throws {
        var entry = MovieProgressEntry(id: 903, title: "Payload cap")
        entry.lastUpdated = Date(timeIntervalSince1970: 1_700_000_050)
        var payload = try wireEncode(entry)
        XCTAssertEqual(payload.last, UInt8(ascii: "}"))
        payload.removeLast()
        let paddingPrefix = Data(",\"padding\":\"".utf8)
        let paddingSuffix = Data("\"}".utf8)
        let paddingCount = MediaStateEnvelope.maximumPayloadBytes
            - payload.count
            - paddingPrefix.count
            - paddingSuffix.count
        XCTAssertGreaterThan(paddingCount, 0)
        payload.append(paddingPrefix)
        payload.append(contentsOf: Data(repeating: UInt8(ascii: "a"), count: paddingCount))
        payload.append(paddingSuffix)
        XCTAssertEqual(payload.count, MediaStateEnvelope.maximumPayloadBytes)
        _ = try wireDecode(MovieProgressEntry.self, from: payload)

        XCTAssertNotNil(MediaStateCloudKitPayloadCodec.encode(payload: payload, resetAt: nil))
        XCTAssertNil(
            MediaStateCloudKitPayloadCodec.encode(
                payload: payload,
                resetAt: entry.lastUpdated
            ),
            "Lineage metadata must not push the existing payload field over its bound"
        )

        let name = MediaStateRecordName.make(
            kind: .movieProgress,
            identifier: "903",
            profileID: ProfileManager.defaultProfileID
        )
        let zoneID = CKRecordZone.ID(
            zoneName: "EclipseMediaState",
            ownerName: CKCurrentUserDefaultName
        )
        XCTAssertNil(MediaStateCloudKitRecordCodec.record(
            from: MediaStateEnvelope(
                recordName: name,
                kind: .movieProgress,
                payload: payload,
                modifiedAt: entry.lastUpdated,
                isExplicitReset: true,
                resetAt: entry.lastUpdated
            ),
            recordID: CKRecord.ID(recordName: name, zoneID: zoneID),
            recordType: "EclipseMediaState"
        ))

        var oversizedWirePayload = payload
        oversizedWirePayload.append(UInt8(ascii: " "))
        XCTAssertNil(MediaStateCloudKitPayloadCodec.decode(oversizedWirePayload))

        let tinyObject = Data("{\"value\":1}".utf8)
        XCTAssertNil(
            MediaStateCloudKitPayloadCodec.encode(
                payload: Data("{}".utf8),
                resetAt: entry.lastUpdated
            ),
            "The codec must not create a trailing-comma object from an empty payload"
        )
        for invalidDate in [
            Date(timeIntervalSince1970: -.infinity),
            Date(timeIntervalSince1970: -1),
            Date(timeIntervalSince1970: .infinity),
            Date(timeIntervalSince1970: .nan),
            Date(timeIntervalSince1970: Double(Int64.max) / 1_000),
            Date(timeIntervalSince1970: Double(Int64.max).nextDown / 1_000)
        ] {
            XCTAssertNil(
                MediaStateCloudKitPayloadCodec.encode(
                    payload: tinyObject,
                    resetAt: invalidDate
                )
            )
        }
    }

    func testConnectedCloudAccountEmailIsDisplaySafeAndDeviceLocal() {
        XCTAssertEqual(
            ExperimentalCloudSyncManager.normalizedAccountEmail(
                "  viewer@example.com\n"
            ),
            "viewer@example.com"
        )
        XCTAssertNil(
            ExperimentalCloudSyncManager.normalizedAccountEmail(
                "viewer@example.com\nInjected"
            )
        )
        XCTAssertNil(
            ExperimentalCloudSyncManager.normalizedAccountEmail("not-an-email")
        )

        for provider in [CloudSyncProvider.googleDrive, .oneDrive] {
            XCTAssertEqual(
                EclipseSettingsRegistry.scope(for: provider.accountEmailKey),
                .device
            )
            XCTAssertFalse(
                BackupManager.carriesProfileScopedSetting(provider.accountEmailKey),
                "A connected account email is display-only device state and must not enter a profile backup"
            )
            XCTAssertFalse(
                MediaStateSettingRegistry.allKeys.contains(provider.accountEmailKey),
                "A connected account email must not become a cloud-synced setting"
            )
        }
    }

    func testWireRoundtrippedRecordsAreNotOwedToRemote() throws {
        let subMillisecondDate = Date(timeIntervalSince1970: 1_723_651_230.123456789)
        var records: [String: MediaStateEnvelope] = [:]
        for index in 0..<8 {
            let name = "setting|test-record-\(index)"
            records[name] = MediaStateEnvelope(
                recordName: name,
                kind: .setting,
                payload: Data("payload-\(index)".utf8),
                modifiedAt: subMillisecondDate.addingTimeInterval(Double(index) * 0.0001),
                settingScope: .shared
            )
        }

        let bundle = MediaStateEnvelopeBundle(records: records)
        let encoded = try MediaStateEnvelopeBundle.encoder().encode(bundle)
        let remote = try MediaStateEnvelopeBundle.decoder()
            .decode(MediaStateEnvelopeBundle.self, from: encoded)

        let outcome = MediaStateEnvelopeReconciler.reconcile(
            local: records,
            remote: remote.records
        )
        XCTAssertTrue(
            outcome.namesOwedToRemote.isEmpty,
            "A record that only differs from remote by wire date precision must not be re-pushed; owing \(outcome.namesOwedToRemote.count) records here is the signature of the endless full-bundle upload loop"
        )
        XCTAssertTrue(outcome.namesChangedLocally.isEmpty)

        let doubleRoundtripped = try MediaStateEnvelopeBundle.decoder().decode(
            MediaStateEnvelopeBundle.self,
            from: MediaStateEnvelopeBundle.encoder().encode(remote)
        )
        let secondPass = MediaStateEnvelopeReconciler.reconcile(
            local: records,
            remote: doubleRoundtripped.records
        )
        XCTAssertTrue(secondPass.namesOwedToRemote.isEmpty)

        var changed = records
        var mutated = try XCTUnwrap(changed["setting|test-record-0"])
        mutated.payload = Data("different".utf8)
        mutated.modifiedAt = subMillisecondDate.addingTimeInterval(60)
        changed["setting|test-record-0"] = mutated
        let realChange = MediaStateEnvelopeReconciler.reconcile(
            local: changed,
            remote: remote.records
        )
        XCTAssertEqual(realChange.namesOwedToRemote, ["setting|test-record-0"])
    }

    func testMangaProgressEncodesReadChaptersDeterministically() throws {
        var progress = MangaProgress()
        progress.readChapterNumbers = Set((1...40).map { "Chapter \($0)" } + ["c1.1", "c2", "c3.5"])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(progress)
        for _ in 0..<5 {
            let decoded = try JSONDecoder().decode(MangaProgress.self, from: first)
            XCTAssertEqual(
                try encoder.encode(decoded),
                first,
                "readChapterNumbers must encode in a stable order; a shuffling Set re-uploads an unchanged cloud snapshot every sync cycle"
            )
        }
    }

    func testCloudSyncTotalBudgetFallsBackToDefaultOnUnknownStoredValue() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: CloudSyncTotalBudget.storageKey)
        defer {
            if let original {
                defaults.set(original, forKey: CloudSyncTotalBudget.storageKey)
            } else {
                defaults.removeObject(forKey: CloudSyncTotalBudget.storageKey)
            }
        }

        defaults.removeObject(forKey: CloudSyncTotalBudget.storageKey)
        XCTAssertEqual(
            CloudSyncTotalBudget.current, .standard,
            "An unset budget must resolve to the 50 MB default; 0 is the unset sentinel and must never mean No Limit"
        )

        defaults.set(1_234, forKey: CloudSyncTotalBudget.storageKey)
        XCTAssertEqual(CloudSyncTotalBudget.current, .standard)

        defaults.set(CloudSyncTotalBudget.unlimited.rawValue, forKey: CloudSyncTotalBudget.storageKey)
        XCTAssertEqual(CloudSyncTotalBudget.current, .unlimited)
        XCTAssertTrue(CloudSyncTotalBudget.current.isUnlimited)
    }

    func testCloudRetryBudgetDoesNotSleepThroughLongProviderBackoff() {
        XCTAssertFalse(
            ExperimentalCloudRetryBudget.permits(
                delay: 300,
                after: 0
            )
        )
        XCTAssertTrue(
            ExperimentalCloudRetryBudget.permits(
                delay: 8,
                after: 12
            )
        )
        XCTAssertFalse(
            ExperimentalCloudRetryBudget.permits(
                delay: 11,
                after: 20
            )
        )
        XCTAssertFalse(
            ExperimentalCloudRetryBudget.shouldRetry(
                delay: 1,
                after: 0,
                isCancelled: true
            )
        )
        XCTAssertFalse(ExperimentalCloudRetryBudget.permits(delay: .nan, after: 0))
        XCTAssertFalse(ExperimentalCloudRetryBudget.permits(delay: .infinity, after: 0))
        XCTAssertFalse(ExperimentalCloudRetryBudget.permits(delay: 1, after: .nan))
    }

    func testPersistedCloudScheduleRejectsCorruptOrImplausibleDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(
            ExperimentalCloudPersistedSchedule.date(
                timestamp: now.timeIntervalSince1970,
                adding: 300,
                now: now
            ),
            now.addingTimeInterval(300)
        )
        XCTAssertNil(
            ExperimentalCloudPersistedSchedule.date(timestamp: .nan, now: now)
        )
        XCTAssertNil(
            ExperimentalCloudPersistedSchedule.date(timestamp: .infinity, now: now)
        )
        XCTAssertNil(
            ExperimentalCloudPersistedSchedule.date(timestamp: 1e300, now: now)
        )
        XCTAssertNil(
            ExperimentalCloudPersistedSchedule.date(
                timestamp: now.timeIntervalSince1970,
                adding: .infinity,
                now: now
            )
        )
        XCTAssertNil(
            ExperimentalCloudPersistedSchedule.date(
                timestamp: now.addingTimeInterval(8 * 24 * 60 * 60).timeIntervalSince1970,
                now: now
            ),
            "A corrupted timestamp must not disable automatic sync indefinitely"
        )
    }

    func testCanonicalMediaStateBundleKeepsAbsentDistinctFromEmpty() {
        XCTAssertEqual(
            ExperimentalCanonicalMediaStateBundlePresence.classify(nil),
            .absent
        )
        XCTAssertEqual(
            ExperimentalCanonicalMediaStateBundlePresence.classify(Data()),
            .invalidEmpty
        )
        XCTAssertEqual(
            ExperimentalCanonicalMediaStateBundlePresence.classify(Data([0x7B, 0x7D])),
            .present(Data([0x7B, 0x7D]))
        )
        XCTAssertFalse(
            ExperimentalCanonicalRestorePolicy.preservesCanonicalMediaState(
                transportIsAvailable: true,
                crossesAccountBoundary: true,
                canonicalBundleIsPresent: false
            )
        )
        XCTAssertTrue(
            ExperimentalCanonicalRestorePolicy.preservesCanonicalMediaState(
                transportIsAvailable: true,
                crossesAccountBoundary: true,
                canonicalBundleIsPresent: true
            )
        )
        XCTAssertTrue(
            ExperimentalCanonicalRestorePolicy.preservesCanonicalMediaState(
                transportIsAvailable: true,
                crossesAccountBoundary: false,
                canonicalBundleIsPresent: false
            )
        )
    }

    func testMediaStateTransportFailureOverridesSnapshotSuccessStatus() {
        let failure = ExperimentalCloudProviderStatusPolicy.mediaStateFailure(
            providerDisplayName: "Google Drive",
            detail: "The remote bundle is invalid."
        )
        XCTAssertEqual(
            ExperimentalCloudProviderStatusPolicy.visibleStatus(
                mediaStateFailure: failure,
                snapshotStatus: "Synced just now"
            ),
            failure
        )
        XCTAssertEqual(
            ExperimentalCloudProviderStatusPolicy.visibleStatus(
                mediaStateFailure: nil,
                snapshotStatus: "Synced just now"
            ),
            "Synced just now"
        )
    }

    func testGoogleDriveSnapshotWriteRejectsConcurrentSiblingCandidates() {
        XCTAssertTrue(
            ExperimentalGoogleDriveSnapshotWritePolicy.matchesExpectedCandidates(
                ["head", "history"],
                expected: ["history", "head"]
            )
        )
        XCTAssertFalse(
            ExperimentalGoogleDriveSnapshotWritePolicy.matchesExpectedCandidates(
                ["other-head", "head", "history"],
                expected: ["head", "history"]
            )
        )
        XCTAssertTrue(
            ExperimentalGoogleDriveSnapshotWritePolicy.confirmsUploadedCandidate(
                expected: ["head", "history"],
                uploadedID: "ours",
                observed: ["ours", "head", "history"],
                headID: "ours"
            )
        )
        XCTAssertFalse(
            ExperimentalGoogleDriveSnapshotWritePolicy.confirmsUploadedCandidate(
                expected: ["head", "history"],
                uploadedID: "ours",
                observed: ["theirs", "ours", "head", "history"],
                headID: "theirs"
            )
        )
    }

    func testMediaStateTransportCooldownDefersOnlyLimitedProviders() {
        let now = Date(timeIntervalSince1970: 1_000)
        let future = now.addingTimeInterval(60)
        XCTAssertTrue(
            MediaStateRemoteTransportCooldownPolicy.isReady(
                retryNotBefore: nil,
                now: now
            )
        )
        XCTAssertFalse(
            MediaStateRemoteTransportCooldownPolicy.isReady(
                retryNotBefore: future,
                now: now
            )
        )
        XCTAssertEqual(
            MediaStateRemoteTransportCooldownPolicy.nextRetryDate(
                [now.addingTimeInterval(-1), future, now.addingTimeInterval(120)],
                after: now
            ),
            future
        )
        XCTAssertTrue(
            MediaStateRemoteTransportCooldownPolicy.isReady(
                retryNotBefore: Date(timeIntervalSince1970: .infinity),
                now: now
            )
        )
        XCTAssertNil(
            MediaStateRemoteTransportCooldownPolicy.nextRetryDate(
                [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity)],
                after: now
            )
        )
    }

    func testMediaStateRequestBackoffHonorsServerDelayAndBoundsFallback() {
        XCTAssertNil(MediaStateSyncRequestBackoffPolicy.boundedServerDelay(.nan))
        XCTAssertNil(MediaStateSyncRequestBackoffPolicy.boundedServerDelay(-1))
        XCTAssertEqual(MediaStateSyncRequestBackoffPolicy.boundedServerDelay(0), 1)
        XCTAssertEqual(
            MediaStateSyncRequestBackoffPolicy.boundedServerDelay(1e300),
            MediaStateSyncRequestBackoffPolicy.maximumServerDelay
        )
        XCTAssertEqual(
            MediaStateCloudKitSaveFailurePolicy.retryDelay(
                for: .requestRateLimited,
                retryAfter: 120,
                consecutiveFailureCount: 20,
                jitterFraction: 1
            ),
            120
        )
        XCTAssertEqual(
            MediaStateCloudKitSaveFailurePolicy.retryDelay(
                for: .requestRateLimited,
                retryAfter: nil,
                consecutiveFailureCount: 3,
                jitterFraction: 0
            ),
            240
        )
        XCTAssertEqual(
            MediaStateSyncRequestBackoffPolicy.revisionConflictDelay(
                attempt: 0,
                jitterFraction: 0
            ),
            0.5
        )
    }

    func testProviderTerminalFailureBackoffBuildsAcrossPassesWithoutRetryAfter() {
        var count = 0
        var delays: [TimeInterval] = []
        for _ in 0..<4 {
            count = ExperimentalCloudTerminalFailureBackoffPolicy.nextCount(
                storedCount: count,
                storedGeneration: 7,
                currentGeneration: 7
            )
            delays.append(
                ExperimentalCloudTerminalFailureBackoffPolicy.delay(
                    serverSuggested: nil,
                    consecutiveFailureCount: count,
                    jitterFraction: 0
                )
            )
        }
        XCTAssertEqual(count, 4)
        XCTAssertEqual(delays, [60, 120, 240, 480])
        XCTAssertEqual(
            ExperimentalCloudTerminalFailureBackoffPolicy.nextCount(
                storedCount: count,
                storedGeneration: 7,
                currentGeneration: 8
            ),
            1
        )
    }

    func testProviderTerminalFailureBackoffUsesServerFloorAndCapsLocalDelay() {
        XCTAssertEqual(
            ExperimentalCloudTerminalFailureBackoffPolicy.delay(
                serverSuggested: 900,
                consecutiveFailureCount: 1,
                jitterFraction: 0
            ),
            900
        )
        XCTAssertEqual(
            ExperimentalCloudTerminalFailureBackoffPolicy.delay(
                serverSuggested: 30,
                consecutiveFailureCount: 3,
                jitterFraction: 0
            ),
            240
        )
        XCTAssertEqual(
            ExperimentalCloudTerminalFailureBackoffPolicy.delay(
                serverSuggested: nil,
                consecutiveFailureCount: 20,
                jitterFraction: 0
            ),
            3_600
        )
        XCTAssertEqual(
            ExperimentalCloudTerminalFailureBackoffPolicy.delay(
                serverSuggested: 1e300,
                consecutiveFailureCount: 20,
                jitterFraction: 0
            ),
            MediaStateSyncRequestBackoffPolicy.maximumServerDelay
        )
    }

    func testRateLimitsWithoutRetryAfterEndTheCurrentRequestPass() {
        XCTAssertFalse(
            ExperimentalCloudInPassRetryPolicy.permitsRetry(
                statusCode: 429,
                isGoogleQuotaFailure: false,
                serverSuggestedDelay: nil,
                hasRemainingAttempts: true
            )
        )
        XCTAssertFalse(
            ExperimentalCloudInPassRetryPolicy.permitsRetry(
                statusCode: 403,
                isGoogleQuotaFailure: true,
                serverSuggestedDelay: nil,
                hasRemainingAttempts: true
            )
        )
        XCTAssertTrue(
            ExperimentalCloudInPassRetryPolicy.permitsRetry(
                statusCode: 429,
                isGoogleQuotaFailure: false,
                serverSuggestedDelay: 15,
                hasRemainingAttempts: true
            )
        )
        XCTAssertTrue(
            ExperimentalCloudInPassRetryPolicy.permitsRetry(
                statusCode: 503,
                isGoogleQuotaFailure: false,
                serverSuggestedDelay: nil,
                hasRemainingAttempts: true
            )
        )
    }

    func testCloudProviderCooldownCannotBeShortenedOrClearedByConcurrentSuccess() {
        let now = Date(timeIntervalSince1970: 10_000)
        let existing = now.addingTimeInterval(300)
        let proposed = now.addingTimeInterval(10)
        XCTAssertEqual(
            MediaStateSyncRequestBackoffPolicy.laterDeadline(
                existing: existing,
                proposed: proposed,
                now: now
            ),
            existing
        )
        XCTAssertEqual(
            MediaStateSyncRequestBackoffPolicy.laterDeadline(
                existing: existing,
                proposed: Date(timeIntervalSince1970: .nan),
                now: now
            ),
            existing
        )
        XCTAssertFalse(
            MediaStateSyncRequestBackoffPolicy.shouldClear(
                retryNotBefore: existing,
                now: now
            )
        )
        XCTAssertTrue(
            MediaStateSyncRequestBackoffPolicy.shouldClear(
                retryNotBefore: now.addingTimeInterval(-1),
                now: now
            )
        )
    }

    func testRepeatedExplicitCloudKitSyncRequestsCoalesceWhileOnePassIsActive() {
        var gate = MediaStateSyncSingleFlightGate()
        XCTAssertTrue(gate.begin())
        for _ in 0..<250 {
            XCTAssertFalse(gate.begin())
        }
        gate.reset()
        XCTAssertTrue(gate.begin())
    }

    func testExplicitCloudKitSyncDoesNotInheritDelegateTaskContext() async throws {
        let inheritedContext = try await MediaStateCloudKitTaskContextProbe
            .$isInsideDelegateCallback.withValue(true) {
                try await MediaStateCloudKitTaskBoundary.detached {
                    MediaStateCloudKitTaskContextProbe.isInsideDelegateCallback
                }.value
            }
        XCTAssertFalse(inheritedContext)
    }

    func testRepeatedCloudKitEnqueueKeepsOnePendingBatchDuringActiveSend() {
        let batch = Set((0..<250).map { "record-\($0)" })
        var pending = Set<String>()
        var stagedCount = 0
        for _ in 0..<4 {
            let staged = MediaStateCloudKitPendingSavePolicy.namesToStage(
                requested: batch,
                alreadyPending: pending
            )
            stagedCount += staged.count
            pending.formUnion(staged)
        }
        XCTAssertEqual(pending, batch)
        XCTAssertEqual(stagedCount, 250)
    }

    func testCloudProviderLaneSerializesConcurrentPassesForOneProvider() async {
        let lane = ExperimentalCloudProviderSyncLane()
        let probe = MediaStateCloudLaneProbe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try? await lane.perform(provider: .googleDrive) {
                        await probe.enter()
                        try? await Task.sleep(nanoseconds: 2_000_000)
                        await probe.leave()
                    }
                }
            }
        }
        let maximum = await probe.maximum()
        XCTAssertEqual(maximum, 1)
    }

    func testSnapshotSafetyFailuresAwaitOverwriteDecisionInsteadOfAutomaticRetry() {
        let failures: [(ExperimentalCloudSyncManager.SyncError, String)] = [
            (
                .suspiciousLocalReduction(.googleDrive, 1, 10),
                "suspicious-local-reduction"
            ),
            (
                .suspiciousRemoteReduction(.oneDrive, 10, 1),
                "suspicious-remote-reduction"
            ),
            (
                .concurrentSnapshotConflict(.googleDrive, 4, 7),
                "concurrent-snapshot-conflict"
            )
        ]

        for (failure, expectedToken) in failures {
            XCTAssertEqual(failure.automaticFailureAction, .awaitOverwriteDecision)
            XCTAssertEqual(failure.diagnosticCaseToken, expectedToken)
        }

        XCTAssertEqual(
            ExperimentalCloudSyncManager.SyncError
                .suspiciousLocalReduction(.oneDrive, 999_999, 0)
                .diagnosticCaseToken,
            "suspicious-local-reduction",
            "The diagnostic token must identify only the safe error case, not provider data or counts"
        )
    }

    func testTransientAndRemoteChangedSnapshotFailuresStillRetryAutomatically() {
        let remoteChanged = ExperimentalCloudSyncManager.SyncError
            .remoteChangedDuringSync(.googleDrive)
        let transient = ExperimentalCloudSyncManager.SyncError
            .remoteRequestFailed(.oneDrive, 503, "provider response must not enter logs")

        XCTAssertEqual(remoteChanged.automaticFailureAction, .retry)
        XCTAssertEqual(remoteChanged.diagnosticCaseToken, "remote-changed-during-sync")
        XCTAssertEqual(transient.automaticFailureAction, .retry)
        XCTAssertEqual(transient.diagnosticCaseToken, "remote-request-failed")
    }

    func testPendingSnapshotDecisionSkipsOnlyItsProvider() {
        let orderedProviders: [CloudSyncProvider] = [
            .googleDrive,
            .oneDrive,
            .iCloud
        ]

        XCTAssertEqual(
            ExperimentalCloudAutomaticSyncPolicy.eligibleProviders(
                from: orderedProviders,
                pendingOverwriteDecisionProviders: [.googleDrive]
            ),
            [.oneDrive, .iCloud]
        )
        XCTAssertEqual(
            ExperimentalCloudAutomaticSyncPolicy.eligibleProviders(
                from: orderedProviders,
                pendingOverwriteDecisionProviders: []
            ),
            orderedProviders,
            "Transient failures have no pending decision and must keep the existing retry set"
        )
    }

    func testTheCloudKitSuspensionFlagCanNeverTravelToAnotherDevice() {
        let key = MediaStateCloudKitSuspension.storageKey

        XCTAssertEqual(
            EclipseSettingsRegistry.scope(for: key), .device,
            "Unregistered keys default to .profile, and a .profile key is swept into the backup settings dictionary. Deleting cloud data on one device would then plant the suspension on every device that restores and kill their CloudKit sync permanently."
        )
        XCTAssertFalse(
            BackupManager.carriesProfileScopedSetting(key),
            "The suspension is a per-device decision and must never be captured into a backup or cloud snapshot"
        )
        XCTAssertFalse(
            MediaStateSettingRegistry.allKeys.contains(key),
            "The record channel must not sync the suspension either"
        )
    }

    @MainActor
    func testICloudConsentDoesNotBypassThePostDeletionResumeGate() {
        let manager = ExperimentalCloudSyncManager.shared
        let defaults = UserDefaults.standard
        let enabledKey = CloudSyncProvider.iCloud.syncEnabledKey
        let previouslyEnabled = defaults.bool(forKey: enabledKey)
        defer {
            MediaStateCloudKitSuspension.resume()
            MediaStateSyncBootstrap.setCloudKitSyncEnabled(previouslyEnabled)
        }

        MediaStateSyncBootstrap.setCloudKitSyncEnabled(false)
        MediaStateCloudKitSuspension.suspend()

        XCTAssertTrue(
            MediaStateCloudKitSuspension.isSuspended,
            "Deleting the Apple-account copy has to stop this device re-creating the zone"
        )

        MediaStateSyncBootstrap.setCloudKitSyncEnabled(true)
        XCTAssertTrue(defaults.bool(forKey: enabledKey))
        XCTAssertTrue(
            MediaStateCloudKitSuspension.isSuspended,
            "Turning consent back on must not silently recreate data after the user explicitly deleted the iCloud copy"
        )
        XCTAssertFalse(MediaStateSyncBootstrap.isCloudKitSyncEnabled)

        manager.resumeAppleAccountMediaStateSync()

        XCTAssertFalse(
            MediaStateCloudKitSuspension.isSuspended,
            "Resume Library Sync must clear the separate deletion safety gate"
        )
        XCTAssertFalse(
            manager.isAppleAccountMediaStateSuspended,
            "The row that offers the resume must disappear once it has been taken"
        )
        XCTAssertEqual(
            MediaStateSyncBootstrap.isCloudKitSyncEnabled,
            MediaStateSyncBootstrap.hasCloudKitEntitlement
        )
    }

    func testAFailedDeletionMustNotClearASuspensionItDidNotCreate() {
        defer { MediaStateCloudKitSuspension.resume() }

        MediaStateCloudKitSuspension.suspend()
        let wasAlreadySuspended = MediaStateCloudKitSuspension.isSuspended
        MediaStateCloudKitSuspension.suspend()

        XCTAssertTrue(
            wasAlreadySuspended,
            "deleteAllRemoteMediaState reads this before it suspends, and the Delete Cloud Data row stays enabled while suspended, so a second attempt is an ordinary user action"
        )

        if !wasAlreadySuspended {
            MediaStateCloudKitSuspension.resume()
        }

        XCTAssertTrue(
            MediaStateCloudKitSuspension.isSuspended,
            "A deletion that reports failure must never turn Apple account sync back on. Resuming unconditionally would reverse the user's explicit decision, re-upload the library they just deleted, and remove the Resume Library Sync row that was their only sign sync was off."
        )
    }

    func testManualRestoreProviderPolicyKeepsLocalRestoresAndFailuresOffline() {
        XCTAssertTrue(ManualBackupRestoreScope.thisDeviceOnly.keepsChangesOnThisDevice)
        XCTAssertFalse(ManualBackupRestoreScope.replaceEverywhere.keepsChangesOnThisDevice)

        let enabled: Set<CloudSyncProvider> = [.iCloud, .googleDrive]
        let local = ExperimentalCloudManualRestoreSession(
            enabledProviders: enabled,
            primaryProvider: .googleDrive,
            keepsChangesOnThisDevice: true
        )
        let authoritative = ExperimentalCloudManualRestoreSession(
            enabledProviders: enabled,
            primaryProvider: .googleDrive,
            keepsChangesOnThisDevice: false
        )

        XCTAssertTrue(
            ExperimentalCloudManualRestorePolicy.enabledProvidersAfterRestore(
                local,
                succeeded: true
            ).isEmpty
        )
        XCTAssertTrue(
            ExperimentalCloudManualRestorePolicy.enabledProvidersAfterRestore(
                local,
                succeeded: false
            ).isEmpty
        )
        XCTAssertTrue(
            ExperimentalCloudManualRestorePolicy.enabledProvidersAfterRestore(
                authoritative,
                succeeded: false
            ).isEmpty
        )
        XCTAssertEqual(
            ExperimentalCloudManualRestorePolicy.enabledProvidersAfterRestore(
                authoritative,
                succeeded: true
            ),
            enabled
        )
        XCTAssertFalse(
            ExperimentalCloudManualRestorePolicy.queuesAuthoritativeSync(
                local,
                succeeded: true
            )
        )
        XCTAssertFalse(
            ExperimentalCloudManualRestorePolicy.queuesAuthoritativeSync(
                authoritative,
                succeeded: false
            )
        )
        XCTAssertTrue(
            ExperimentalCloudManualRestorePolicy.queuesAuthoritativeSync(
                authoritative,
                succeeded: true
            )
        )
    }

    @MainActor
    func testTheResumeAffordanceIsOfferedExactlyWhenTheDeletionCouldHaveHappened() {
        let manager = ExperimentalCloudSyncManager.shared
        defer { MediaStateCloudKitSuspension.resume() }

        MediaStateCloudKitSuspension.suspend()
        XCTAssertEqual(
            manager.isAppleAccountMediaStateSuspended,
            manager.canDeleteAppleAccountMediaState,
            "A build that cannot delete the Apple-account copy can never suspend itself, so offering it a resume row would be a control that does nothing"
        )

        guard manager.canDeleteAppleAccountMediaState else { return }
        XCTAssertTrue(
            manager.statusMessage(for: .iCloud).contains("Resume Library Sync"),
            "The status text must name a control that exists on the same screen"
        )
    }

    @MainActor
    func testRestoreAuthorityIsADevicePropertyNotAPerProviderOne() throws {
        try XCTSkipUnless(ExperimentalFeatureState.isEnabledAtLaunch)

        let defaults = UserDefaults.standard
        let iCloudKey = CloudSyncProvider.iCloud.syncEnabledKey
        let driveKey = CloudSyncProvider.googleDrive.syncEnabledKey
        let oneDriveKey = CloudSyncProvider.oneDrive.syncEnabledKey
        let previousICloud = defaults.bool(forKey: iCloudKey)
        let previousDrive = defaults.bool(forKey: driveKey)
        let previousOneDrive = defaults.bool(forKey: oneDriveKey)
        defer {
            MediaStateCloudKitSuspension.resume()
            defaults.set(previousICloud, forKey: iCloudKey)
            defaults.set(previousDrive, forKey: driveKey)
            defaults.set(previousOneDrive, forKey: oneDriveKey)
        }

        defaults.set(false, forKey: iCloudKey)
        defaults.set(true, forKey: driveKey)
        defaults.set(false, forKey: oneDriveKey)
        MediaStateCloudKitSuspension.suspend()

        XCTAssertTrue(
            ExperimentalCloudSyncManager.canonicalMediaStateTransportIsAvailable,
            "Library, progress and ratings live in one shared set of managers owned by whichever record channel is live on the DEVICE. Suspending the Apple-account channel does not stop the Google Drive envelope channel, so a restore must still preserve those domains or it overwrites the live channel from a stale snapshot and republishes the result to every other device."
        )

        defaults.set(false, forKey: driveKey)
        XCTAssertFalse(
            ExperimentalCloudSyncManager.canonicalMediaStateTransportIsAvailable,
            "With CloudKit suspended and no envelope provider enabled, nothing owns library and watch progress. Claiming otherwise drops them from the upload digest and discards them on every restore, silently."
        )

        MediaStateCloudKitSuspension.resume()
        defaults.set(true, forKey: iCloudKey)
        XCTAssertEqual(
            ExperimentalCloudSyncManager.canonicalMediaStateTransportIsAvailable,
            MediaStateSyncBootstrap.hasCloudKitEntitlement,
            "Without the entitlement CKSyncEngine never runs, so with no envelope provider the sideload lane must not defer media state to it either"
        )
    }

    func testDeletingTheCloudCopyLeavesThisDeviceStillCapturingItsOwnChanges() {
        XCTAssertFalse(
            MediaStateLocalCapturePolicy.capturesLocalChanges(
                initialFetchCompleted: false,
                isTrustedOfflineCacheActive: false,
                isRemoteTransportModeActive: false
            ),
            "This is the state a deletion used to leave behind: detachActiveEngineForAccountIsolation clears initialFetchCompleted, completeInitialFetch had already cleared isTrustedOfflineCacheActive, and a device without Google Drive or OneDrive has no transport mode. Capture is then dead."
        )

        XCTAssertTrue(
            MediaStateLocalCapturePolicy.capturesLocalChanges(
                initialFetchCompleted: false,
                isTrustedOfflineCacheActive: true,
                isRemoteTransportModeActive: false
            ),
            "adoptDeletedRemoteMediaState re-arms the trusted offline cache for an account-owned archive. Without it the archive freezes at deletion time and Resume Library Sync replays that frozen snapshot over everything watched since, resurrecting deleted profiles."
        )

        XCTAssertTrue(
            MediaStateLocalCapturePolicy.capturesLocalChanges(
                initialFetchCompleted: false,
                isTrustedOfflineCacheActive: false,
                isRemoteTransportModeActive: true
            ),
            "A Drive or OneDrive device keeps capturing through its own transport mode"
        )
    }

    func testAlreadyAbsentCloudKitItemsAreNotTreatedAsDeletionFailures() {
        XCTAssertTrue(
            MediaStateCloudKitDeletionPolicy.describesAlreadyAbsentItem(
                CKError(.zoneNotFound)
            ),
            "Deleting a zone that was never created is the goal state, not a failure"
        )
        XCTAssertTrue(
            MediaStateCloudKitDeletionPolicy.describesAlreadyAbsentItem(
                CKError(.unknownItem)
            ),
            "A subscription that does not exist is already deleted"
        )

        for code in [CKError.Code.notAuthenticated, .networkFailure, .permissionFailure, .quotaExceeded, .serverRejectedRequest] {
            XCTAssertFalse(
                MediaStateCloudKitDeletionPolicy.describesAlreadyAbsentItem(CKError(code)),
                "\(code) means Eclipse could not prove the cloud copy is gone and must report a failure"
            )
        }

        XCTAssertFalse(
            MediaStateCloudKitDeletionPolicy.describesAlreadyAbsentItem(
                CKError(.partialFailure, userInfo: [:])
            ),
            "A partial failure carrying no per-item errors proves nothing and must not read as success"
        )

        let zoneID = CKRecordZone.ID(zoneName: "EclipseMediaState", ownerName: CKCurrentUserDefaultName)
        let otherZoneID = CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName)
        XCTAssertTrue(
            MediaStateCloudKitDeletionPolicy.describesAlreadyAbsentItem(
                CKError(.partialFailure, userInfo: [
                    CKPartialErrorsByItemIDKey: [zoneID: CKError(.zoneNotFound)]
                ])
            )
        )
        XCTAssertFalse(
            MediaStateCloudKitDeletionPolicy.describesAlreadyAbsentItem(
                CKError(.partialFailure, userInfo: [
                    CKPartialErrorsByItemIDKey: [
                        zoneID: CKError(.zoneNotFound),
                        otherZoneID: CKError(.notAuthenticated)
                    ]
                ])
            ),
            "One genuinely failed item must sink the whole verdict; a user told 'deleted' must have had it deleted"
        )

        XCTAssertFalse(
            MediaStateCloudKitDeletionPolicy.describesAlreadyAbsentItem(
                CocoaError(.fileNoSuchFile)
            ),
            "A non-CloudKit error must never be read as an absent CloudKit item"
        )
    }

    func testSourceLoadingDeferralEscalatesOnlyAfterTheGraceWindow() {
        let grace: TimeInterval = 90
        let start = Date(timeIntervalSince1970: 1_723_651_200)

        XCTAssertEqual(
            CloudSyncSourceLoadingDeferral.action(streakStartedAt: nil, now: start, grace: grace),
            .retry(streakStartedAt: start),
            "The first deferral of a streak starts the clock at now and must retry"
        )

        XCTAssertEqual(
            CloudSyncSourceLoadingDeferral.action(
                streakStartedAt: start,
                now: start.addingTimeInterval(89),
                grace: grace
            ),
            .retry(streakStartedAt: start),
            "A continuing streak must keep its ORIGINAL start, or the window slides forever and never escalates"
        )

        XCTAssertEqual(
            CloudSyncSourceLoadingDeferral.action(
                streakStartedAt: start,
                now: start.addingTimeInterval(grace),
                grace: grace
            ),
            .escalate,
            "Sources that never finish loading must stop silently retrying and tell the user"
        )

        XCTAssertEqual(
            CloudSyncSourceLoadingDeferral.action(
                streakStartedAt: start,
                now: start.addingTimeInterval(-30),
                grace: grace
            ),
            .retry(streakStartedAt: start),
            "A backwards clock must not escalate early"
        )
    }

    func testSnapshotRetentionNeverFallsBelowTheRecoveryFloor() {
        let realisticSnapshot = 2_400_000

        XCTAssertEqual(
            CloudSyncTotalBudget.unlimited.retainedSnapshotCopies(forSnapshotBytes: realisticSnapshot),
            CloudSyncTotalBudget.defaultRetainedSnapshotCopies,
            "No Limit must reproduce the shipped retention exactly, not widen it"
        )

        for budget in CloudSyncTotalBudget.allCases {
            for bytes in [1, 2_400_000, 24_000_000, 240_000_000, 50_000_000] {
                let retained = budget.retainedSnapshotCopies(forSnapshotBytes: bytes)
                XCTAssertGreaterThanOrEqual(
                    retained, CloudSyncTotalBudget.reservedSnapshotCopies,
                    "Google Drive has no write precondition, so dropping below two copies can leave a user with no valid backup (budget \(budget.displayName), snapshot \(bytes))"
                )
                XCTAssertLessThanOrEqual(
                    retained, CloudSyncTotalBudget.defaultRetainedSnapshotCopies,
                    "A budget must never retain MORE copies than the shipped default"
                )
            }
        }

        XCTAssertEqual(
            CloudSyncTotalBudget.compact.retainedSnapshotCopies(forSnapshotBytes: 20_000_000),
            CloudSyncTotalBudget.reservedSnapshotCopies,
            "A snapshot larger than half the budget still keeps the two-copy recovery window"
        )
    }

    func testNoBaselineWithLocalDataStillRefusesToOverwriteSilently() throws {
        let localWithData = try footprint(services: 1, libraryItems: 12, digest: "local-bytes")
        let differingRemote = try footprint(services: 1, libraryItems: 12, digest: "remote-bytes")

        XCTAssertEqual(
            ExperimentalCloudReconciliationPolicy.actionForUnseenRemote(
                local: localWithData,
                remote: differingRemote,
                previous: nil
            ),
            .concurrentConflict,
            "A missing baseline means the local side is UNKNOWN, not unchanged. Treating it as unchanged silently restores the cloud over local edits that change no record count (manga chapters read, settings) on reconnect, on an upgrade, and after a failed wipe."
        )

        XCTAssertEqual(
            ExperimentalCloudReconciliationPolicy.actionForUnseenRemote(
                local: try footprint(services: 0, libraryItems: 0, digest: "empty"),
                remote: differingRemote,
                previous: nil
            ),
            .restoreRemote,
            "A genuinely empty device may adopt the remote without a prompt"
        )

        let fullerLocal = try footprint(services: 3, libraryItems: 40, digest: "local-bytes")
        XCTAssertEqual(
            ExperimentalCloudReconciliationPolicy.actionForUnseenRemote(
                local: fullerLocal,
                remote: differingRemote,
                previous: nil
            ),
            .concurrentConflict,
            "A fuller local side with no baseline must never silently lose data"
        )
    }

    func testSnapshotFootprintRejectsNegativeAndUnboundedWireCounts() throws {
        for value in [-1, Int.max] {
            let data = try JSONSerialization.data(withJSONObject: [
                "libraryItems": value
            ])
            XCTAssertThrowsError(
                try JSONDecoder().decode(ExperimentalCloudSnapshotFootprint.self, from: data)
            )
        }

        let bounded = ExperimentalCloudSnapshotFootprint(
            libraryItems: Int.max,
            movieProgress: Int.max,
            episodeProgress: Int.max,
            mangaLibraryItems: Int.max,
            mangaReadingProgress: Int.max,
            userRatings: Int.max,
            services: Int.max,
            stremioAddons: Int.max,
            skyStreamSources: Int.max,
            kanzenModules: Int.max,
            aidokuSources: Int.max,
            contentDigest: nil,
            contentDigestExcludingCloudKitMediaState: nil
        )
        XCTAssertEqual(
            bounded.libraryItems,
            ExperimentalCloudSnapshotFootprint.maximumDomainRecordCount
        )
        XCTAssertGreaterThan(bounded.meaningfulRecordCount, 0)
    }

    func testMediaStateRejectsUnboundedLibraryMembershipIdentity() throws {
        let collectionKey = "bookmarks"
        let identity = "movie-\(Int.max)"
        let name = MediaStateRecordName.make(
            kind: .libraryMembership,
            identifier: "\(collectionKey):\(identity)",
            profileID: ProfileManager.defaultProfileID
        )
        let payload = try JSONSerialization.data(withJSONObject: [
            "collectionKey": collectionKey,
            "item": [
                "searchResult": [
                    "id": Int.max,
                    "media_type": "movie",
                    "title": "Hostile",
                    "popularity": 1
                ],
                "dateAdded": 1_000
            ],
            "order": 0
        ])
        let envelope = MediaStateEnvelope(
            recordName: name,
            kind: .libraryMembership,
            payload: payload,
            modifiedAt: Date()
        )
        XCTAssertNotNil(MediaStateEnvelopeValidator.rejectionReason(
            for: [name: envelope],
            allowsSystemFields: false
        ))
    }

    private func footprint(
        services: Int,
        libraryItems: Int,
        digest: String
    ) throws -> ExperimentalCloudSnapshotFootprint {
        ExperimentalCloudSnapshotFootprint(
            libraryItems: libraryItems,
            movieProgress: 0,
            episodeProgress: 0,
            mangaLibraryItems: 0,
            mangaReadingProgress: 0,
            userRatings: 0,
            services: services,
            stremioAddons: 0,
            skyStreamSources: 0,
            kanzenModules: 0,
            aidokuSources: 0,
            contentDigest: digest,
            contentDigestExcludingCloudKitMediaState: digest
        )
    }

    func testArbitraryShapeValidPINDigestIsRejected() {
        let unusable = String(repeating: "0", count: 32) + ":" + String(repeating: "0", count: 64)

        XCTAssertTrue(ProfilePINHasher.isWellFormedHash(unusable))
        XCTAssertNil(
            ProfilePINHasher.sanitizedHash(unusable),
            "A digest that no accepted four-digit PIN can produce must not become a permanent lockout"
        )
    }

    func testGeneratedPINHashRemainsVerifiable() throws {
        let hash = try XCTUnwrap(ProfilePINHasher.makeHash(for: "0042"))

        XCTAssertEqual(ProfilePINHasher.sanitizedHash(hash), hash)
        XCTAssertTrue(ProfilePINHasher.verify(pin: "0042", against: hash))
        XCTAssertFalse(ProfilePINHasher.verify(pin: "42", against: hash))
        XCTAssertFalse(ProfilePINHasher.verify(pin: "１２３４", against: hash))
    }

    func testRejectedNewerPINFieldCannotMasqueradeAsUnlock() throws {
        let id = UUID()
        let invalid = String(repeating: "0", count: 32) + ":" + String(repeating: "0", count: 64)
        let raw: [String: Any] = [
            "id": id.uuidString,
            "name": "Remote",
            "avatarSymbol": "person",
            "avatarColorHex": "#000000",
            "pinHash": invalid,
            "isKidsProfile": false,
            "createdAt": 0.0,
            "pinChangedAt": 100.0
        ]
        let decoded = try JSONDecoder().decode(
            Profile.self,
            from: JSONSerialization.data(withJSONObject: raw)
        )
        XCTAssertNil(decoded.pinHash)
        XCTAssertTrue(decoded.hasRejectedPINHash)

        let localHash = try XCTUnwrap(ProfilePINHasher.makeHash(for: "1234"))
        let local = Profile(
            id: id,
            name: "Local",
            pinHash: localHash,
            pinChangedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let merged = local.applyingSyncedRecord(decoded)

        XCTAssertEqual(merged.pinHash, localHash)
        XCTAssertTrue(merged.isLocked)
    }

    func testProfileEnvelopeMergeRetainsLosingPayloadFieldClocks() throws {
        let id = UUID()
        let lockedHash = try XCTUnwrap(ProfilePINHasher.makeHash(for: "9876"))
        let restrictionWinner = Profile(
            id: id,
            name: "Old Name",
            avatarSymbol: "person",
            pinHash: lockedHash,
            pinChangedAt: Date(timeIntervalSinceReferenceDate: 30)
        )
        let generalWinner = Profile(
            id: id,
            name: "New Name",
            avatarSymbol: "star",
            pinHash: nil,
            pinChangedAt: Date(timeIntervalSinceReferenceDate: 20)
        )
        let name = MediaStateRecordName.make(
            kind: .profile,
            identifier: id.uuidString.lowercased()
        )
        let olderEnvelope = MediaStateEnvelope(
            recordName: name,
            kind: .profile,
            payload: try wireEncode(restrictionWinner),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            revision: 4
        )
        let newerEnvelope = MediaStateEnvelope(
            recordName: name,
            kind: .profile,
            payload: try wireEncode(generalWinner),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20),
            revision: 7
        )

        let mergedEnvelope = olderEnvelope.merged(with: newerEnvelope)
        let merged = try wireDecode(Profile.self, from: mergedEnvelope.payload)

        XCTAssertEqual(merged.name, "New Name")
        XCTAssertEqual(merged.avatarSymbol, "star")
        XCTAssertEqual(merged.pinHash, lockedHash)
        XCTAssertEqual(merged.pinChangedAt, restrictionWinner.pinChangedAt)
        XCTAssertEqual(mergedEnvelope.revision, 7)

        let initialMerge = MediaStateInitialMergePolicy.merge(
            fetchedRecords: [name: newerEnvelope],
            localSnapshot: [name: olderEnvelope]
        )
        XCTAssertEqual(
            initialMerge.pendingRecordNames,
            [name],
            "A novel per-field profile merge must be uploaded, not stranded only in the local archive"
        )
    }

    func testProfileEnvelopeMergePreservesNewerIntentionalUnlock() throws {
        let id = UUID()
        let lockedHash = try XCTUnwrap(ProfilePINHasher.makeHash(for: "1111"))
        let generalWinner = Profile(
            id: id,
            name: "Newest Avatar",
            avatarSymbol: "star",
            pinHash: lockedHash,
            pinChangedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let unlockWinner = Profile(
            id: id,
            name: "Older Avatar",
            avatarSymbol: "person",
            pinHash: nil,
            pinChangedAt: Date(timeIntervalSinceReferenceDate: 30)
        )
        let name = MediaStateRecordName.make(
            kind: .profile,
            identifier: id.uuidString.lowercased()
        )
        let newerEnvelope = MediaStateEnvelope(
            recordName: name,
            kind: .profile,
            payload: try wireEncode(generalWinner),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20)
        )
        let olderEnvelope = MediaStateEnvelope(
            recordName: name,
            kind: .profile,
            payload: try wireEncode(unlockWinner),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10)
        )

        let mergedEnvelope = newerEnvelope.merged(with: olderEnvelope)
        let merged = try wireDecode(Profile.self, from: mergedEnvelope.payload)

        XCTAssertEqual(merged.name, "Newest Avatar")
        XCTAssertNil(merged.pinHash)
        XCTAssertEqual(merged.pinChangedAt, unlockWinner.pinChangedAt)
    }

    func testEnvelopeValidatorRejectsDictionaryKindAndProfileIdentityMismatch() throws {
        let profile = Profile(name: "Valid")
        let profileName = MediaStateRecordName.make(
            kind: .profile,
            identifier: profile.id.uuidString.lowercased()
        )
        let envelope = MediaStateEnvelope(
            recordName: profileName,
            kind: .profile,
            payload: try wireEncode(profile),
            modifiedAt: Date()
        )

        XCTAssertNil(MediaStateEnvelopeValidator.rejectionReason(
            for: [profileName: envelope],
            allowsSystemFields: false
        ))
        XCTAssertNotNil(MediaStateEnvelopeValidator.rejectionReason(
            for: ["profile|\(UUID().uuidString.lowercased())": envelope],
            allowsSystemFields: false
        ))

        let wrongKind = MediaStateEnvelope(
            recordName: profileName,
            kind: .rating,
            payload: envelope.payload,
            modifiedAt: envelope.modifiedAt
        )
        XCTAssertNotNil(MediaStateEnvelopeValidator.rejectionReason(
            for: [profileName: wrongKind],
            allowsSystemFields: false
        ))

        let otherProfile = Profile(name: "Other")
        let wrongPayload = MediaStateEnvelope(
            recordName: profileName,
            kind: .profile,
            payload: try wireEncode(otherProfile),
            modifiedAt: envelope.modifiedAt
        )
        XCTAssertNotNil(MediaStateEnvelopeValidator.rejectionReason(
            for: [profileName: wrongPayload],
            allowsSystemFields: false
        ))
    }

    func testEnvelopeValidatorRejectsProfileSegmentOnServicesScopedSetting() throws {
        let payload = try PropertyListSerialization.data(
            fromPropertyList: true,
            format: .binary,
            options: 0
        )
        let key = "servicesAutoModeEnabled"
        let globalName = MediaStateRecordName.make(kind: .setting, identifier: key)
        let global = MediaStateEnvelope(
            recordName: globalName,
            kind: .setting,
            payload: payload,
            modifiedAt: Date()
        )
        XCTAssertNil(MediaStateEnvelopeValidator.rejectionReason(
            for: [globalName: global],
            allowsSystemFields: false
        ))

        let forgedName = MediaStateRecordName.make(
            kind: .setting,
            identifier: key,
            profileID: UUID()
        )
        let forged = MediaStateEnvelope(
            recordName: forgedName,
            kind: .setting,
            payload: payload,
            modifiedAt: Date()
        )
        XCTAssertNotNil(
            MediaStateEnvelopeValidator.rejectionReason(
                for: [forgedName: forged],
                allowsSystemFields: false
            ),
            "A services key must never carry a profile segment. The record namespace cannot depend on eclipseSharesServicesAcrossProfilesV1, which is device-scoped, never syncs, and is mutable at runtime."
        )
    }

    func testRescopedSettingKeysSyncOnIOSAndAdoptTheirPreviousScope() throws {
        XCTAssertEqual(
            MediaStateSettingRegistry.scope(for: "playerDoubleTapSeekSeconds"),
            .iOS,
            "Seek amount has live iOS UI, so a tvOS-only classification stopped it syncing between iPhone and iPad. It is iOS-only rather than shared because the iOS Stepper produces values such as 25 that no tvOS Picker tag matches, and the Apple TV would snap to a listed value and push it back."
        )
        XCTAssertTrue(
            MediaStateSettingRegistry.acceptsPreviousScope(.tvOS, for: "playerDoubleTapSeekSeconds"),
            "Records written before the rescope carry settingScope tvOS and must be adopted rather than rejected"
        )
        XCTAssertEqual(
            MediaStateSettingRegistry.scope(for: "playbackEngine"),
            .tvOS,
            "PlaybackEngine.availableSelections is derived from the device idiom and selected() writes the coerced value back, so syncing it would let one device overwrite another's engine"
        )
    }

    func testEveryNewlySyncedKeyAcceptsARealWrittenValue() throws {
        let archivedColor = try NSKeyedArchiver.archivedData(
            withRootObject: UIColor(red: 0.25, green: 0.12, blue: 0.45, alpha: 1),
            requiringSecureCoding: true
        )
        let archivedColorTriple = try NSKeyedArchiver.archivedData(
            withRootObject: [UIColor.red, UIColor.green, UIColor.blue],
            requiringSecureCoding: true
        )
        let filterJSON = try JSONSerialization.data(withJSONObject: ["minYear": 1990])

        let representatives: [String: Any] = [
            "localNotificationEpisodeReminders": "[]",
            "localNotificationEpisodeLeadTime": 3600,
            "localNotificationSeasonLeadTime": 86_400,
            "localNotificationIncludeAnimeSpecials": true,
            "selectedAppearance": "dark",
            "atmosphereSolidColorSource": "custom",
            "atmosphereSolidColor": archivedColor,
            "appearanceCustomColors": archivedColorTriple,
            "accentColor": archivedColor,
            "eclipseThemeGradientColor": archivedColor,
            "defaultScheduleMode": "combined",
            "scheduleWindowDays": 14,
            "showLocalScheduleTime": true,
            "libraryShowBookmarksSection": false,
            "showUnairedEpisodes": true,
            "mediaDetailAgeRatingEnabled": true,
            "browseFilterPreferences": filterJSON,
            "selectedSimilarityAlgorithm": "jaro_winkler",
            "highQualityThreshold": 0.9,
            "mpvPlayerSkin": "cypberpunk",
            "mpvPlayerSkinCustomPrimaryColor": archivedColor,
            "mpvPlayerSkinCustomSecondaryColor": archivedColor,
            "mpvPlayerSkinAnimationsEnabled": true,
            "mpvPlayerSkinAnimationStyle.default": "glow",
            "mpvPlayerSkinAnimationStyle.blackAndGold": "spectrum",
            "mpvPlayerSkinAnimationStyle.prismatic": "sweep",
            "mpvPlayerSkinAnimationStyle.cyberpunk": "aurora",
            "mpvPlayerSkinAnimationStyle.custom": "glow",
            "playerDoubleTapSeekEnabled": true,
            "playerDoubleTapSeekSeconds": 25.0,
            "playerBrightnessGestureEnabled": true,
            "playerVolumeGestureEnabled": false,
            "playerTwoFingerTapPlayPauseEnabled": true,
            "playerCenterTapPlayPauseEnabled": true,
            "playerPlaybackLockEnabled": false,
            "defaultPlaybackSpeed": 1.25,
            "holdSpeedPlayer": 2.0,
            "aniSkipEnabled": true,
            "skip85sEnabled": false,
            "skip85sAlwaysVisible": true,
            "showEpisodeBrowserButton": true,
            "showNextEpisodePosterButton": false,
            "nextEpisodeSkipFillerEnabled": true,
            "mpvAppExitPictureInPictureEnabled": false,
            "preferDownloadedMedia": true,
            "readerGlobalAppearanceEnabled": false,
            "readerAppearancePalette": "aurora",
            "readerAppearanceBleedStrength": 0.8,
            "readerAppearanceBackgroundIntensity": 1.0,
            "readerAppearanceMotion": 0.5,
            "readerAppearanceCustomColors": archivedColorTriple,
            "readerAtmosphereStyle": "solid",
            "readerAtmosphereSolidColorSource": "dominant",
            "readerAtmosphereSolidColor": archivedColor,
            "readerThemeGradientColor": archivedColor,
            "readerAccentColor": archivedColor,
            "readerSelectedAppearance": "light",
            "readerFontSize": 18.0,
            "readerFontFamily": "Charter",
            "readerFontWeight": "bold",
            "readerColorPreset": 2,
            "readerTextAlignment": "justify",
            "readerLineSpacing": 1.6,
            "readerMargin": 4.0,
            "readerDetailElementOrder": "overview,tags,ratingNotes,chapters",
            "readerDetailHiddenElements": "",
            "readerReadThresholdPercent": 85,
            "kanzenReaderMode": "webtoon",
            "Reader.downsampleImages": true,
            "Reader.cropBorders": false,
            "Reader.disableQuickActions": false,
            "Reader.disableDoubleTap": true,
            "Reader.liveText": false,
            "Reader.hideBarsOnSwipe": true,
            "Reader.backgroundColor": "auto",
            "Reader.tapZones": "l-shaped",
            "Reader.invertTapZones": false,
            "Reader.animatePageTransitions": true,
            "Reader.pagesToPreload": 3,
            "Reader.splitWideImages": true,
            "Reader.reverseSplitOrder": false,
            "Reader.verticalInfiniteScroll": true
        ]

        for (key, value) in representatives {
            XCTAssertNotNil(
                MediaStateSettingRegistry.scope(for: key),
                "\(key) fell out of MediaStateSettingRegistry, so it silently stopped syncing"
            )
            let payload = try PropertyListSerialization.data(
                fromPropertyList: value,
                format: .binary,
                options: 0
            )
            XCTAssertNotNil(
                MediaStateSettingValueValidator.validatedValue(from: payload, forKey: key),
                "\(key) rejected a value the app really writes (\(value)); the archive's stale value would snap back over the user's choice on every apply"
            )
        }
    }

    func testLegacyBooleanNumericSettingIsCoercedAtCaptureAndSurvivesValidation() throws {
        let coercedTrue = MediaStateSettingValueValidator.capturableLocalValue(
            true, forKey: "appearanceBleedStrength"
        )
        let coercedFalse = MediaStateSettingValueValidator.capturableLocalValue(
            false, forKey: "appearanceBleedStrength"
        )
        XCTAssertEqual((coercedTrue as? NSNumber)?.doubleValue, 1.0)
        XCTAssertEqual((coercedFalse as? NSNumber)?.doubleValue, 0.0)

        for coerced in [coercedTrue, coercedFalse] {
            let payload = try PropertyListSerialization.data(
                fromPropertyList: coerced,
                format: .binary,
                options: 0
            )
            XCTAssertNotNil(
                MediaStateSettingValueValidator.validatedValue(
                    from: payload,
                    forKey: "appearanceBleedStrength"
                ),
                "A legacy boolean bleed strength must capture as the number double(forKey:) reads, or the key never syncs from that container"
            )
        }

        let untouchedBoolean = MediaStateSettingValueValidator.capturableLocalValue(
            true, forKey: "showNextEpisodeButton"
        )
        XCTAssertTrue(
            (untouchedBoolean as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false,
            "Coercion must only touch numeric-range keys; a genuine boolean setting stays boolean"
        )

        let untouchedNumber = MediaStateSettingValueValidator.capturableLocalValue(
            0.85, forKey: "appearanceBleedStrength"
        )
        XCTAssertEqual((untouchedNumber as? NSNumber)?.doubleValue, 0.85)
    }

    func testIntegerSettingValidatorRejectsUnrepresentableFiniteNumbersWithoutTrapping() throws {
        let payload = try PropertyListSerialization.data(
            fromPropertyList: Double.greatestFiniteMagnitude,
            format: .binary,
            options: 0
        )

        XCTAssertNil(
            MediaStateSettingValueValidator.validatedValue(
                from: payload,
                forKey: "Reader.pagesToPreload"
            )
        )
    }

    func testSyncedDefaultPlaybackSpeedMatchesRuntimeMaximum() throws {
        let supported = try PropertyListSerialization.data(
            fromPropertyList: 3.0,
            format: .binary,
            options: 0
        )
        let unsupported = try PropertyListSerialization.data(
            fromPropertyList: 4.0,
            format: .binary,
            options: 0
        )

        XCTAssertNotNil(
            MediaStateSettingValueValidator.validatedValue(
                from: supported,
                forKey: "defaultPlaybackSpeed"
            )
        )
        XCTAssertNil(
            MediaStateSettingValueValidator.validatedValue(
                from: unsupported,
                forKey: "defaultPlaybackSpeed"
            ),
            "Cloud restore must not accept a speed above the player's 3x runtime limit"
        )
    }

    func testEnvelopeValidatorRejectsProfileSegmentOnDeviceScopedSetting() throws {
        let deviceScopedSyncedKeys = MediaStateSettingRegistry.allKeys.filter {
            EclipseSettingsRegistry.scope(for: $0) == .device
        }
        XCTAssertTrue(
            deviceScopedSyncedKeys.isEmpty,
            "A device-scoped key entered the sync registry: \(deviceScopedSyncedKeys.sorted()). Device-suite values are per-device by construction, so syncing one silently does nothing on the receiving device."
        )
    }

    func testMaximumRevisionRemainsValidAndSaturatesWithoutOverflow() throws {
        let profile = Profile(name: "Revision ceiling")
        let name = MediaStateRecordName.make(
            kind: .profile,
            identifier: profile.id.uuidString.lowercased()
        )
        let envelope = MediaStateEnvelope(
            recordName: name,
            kind: .profile,
            payload: try wireEncode(profile),
            modifiedAt: Date(),
            revision: Int64.max
        )

        XCTAssertNil(MediaStateEnvelopeValidator.rejectionReason(
            for: [name: envelope],
            allowsSystemFields: false
        ))
        XCTAssertEqual(MediaStateEnvelope.nextRevision(after: Int64.max - 1), Int64.max)
        XCTAssertEqual(MediaStateEnvelope.nextRevision(after: Int64.max), Int64.max)

        let tombstone = envelope.tombstone()
        XCTAssertEqual(tombstone.revision, Int64.max)
        XCTAssertNil(MediaStateEnvelopeValidator.rejectionReason(
            for: [name: tombstone],
            allowsSystemFields: false
        ))
    }

    func testKeepLocalAccountBoundaryTombstonesFetchedRemoteOnlyRecords() throws {
        let profileID = ProfileManager.defaultProfileID
        let localName = MediaStateRecordName.make(
            kind: .rating,
            identifier: "101",
            profileID: profileID
        )
        let remoteOnlyName = MediaStateRecordName.make(
            kind: .rating,
            identifier: "202",
            profileID: profileID
        )
        let local = MediaStateEnvelope(
            recordName: localName,
            kind: .rating,
            payload: try JSONSerialization.data(withJSONObject: [
                "tmdbID": 101,
                "rating": 8.0
            ]),
            modifiedAt: Date(timeIntervalSince1970: 1_000),
            revision: 3
        )
        let remoteOnly = MediaStateEnvelope(
            recordName: remoteOnlyName,
            kind: .rating,
            payload: try JSONSerialization.data(withJSONObject: [
                "tmdbID": 202,
                "rating": 9.0
            ]),
            modifiedAt: Date(timeIntervalSince1970: 2_000),
            revision: 41
        )

        let authority = try XCTUnwrap(MediaStateAccountBoundaryAuthority.replacing(
            existing: [localName: local],
            selected: [localName: local],
            rejected: [remoteOnlyName: remoteOnly],
            now: Date(timeIntervalSince1970: 3_000)
        ))

        XCTAssertFalse(try XCTUnwrap(authority[localName]).isDeleted)
        let rejected = try XCTUnwrap(authority[remoteOnlyName])
        XCTAssertTrue(rejected.isDeleted)
        XCTAssertTrue(rejected.payload.isEmpty)
        XCTAssertEqual(rejected.revision, 42)
        XCTAssertGreaterThan(rejected.modifiedAt, remoteOnly.modifiedAt)
    }

    func testValidatorRejectsCrossKindScopeFlagsAndSemanticallyEmptyPayloads() throws {
        let ratingName = MediaStateRecordName.make(
            kind: .rating,
            identifier: "123",
            profileID: ProfileManager.defaultProfileID
        )
        let validRatingPayload = try JSONSerialization.data(withJSONObject: [
            "tmdbID": 123,
            "rating": 8.5
        ])
        let validRating = MediaStateEnvelope(
            recordName: ratingName,
            kind: .rating,
            payload: validRatingPayload,
            modifiedAt: Date()
        )
        XCTAssertNil(MediaStateEnvelopeValidator.rejectionReason(
            for: [ratingName: validRating],
            allowsSystemFields: false
        ))

        var platformScopedRating = validRating
        platformScopedRating.settingScope = .tvOS
        XCTAssertNotNil(MediaStateEnvelopeValidator.rejectionReason(
            for: [ratingName: platformScopedRating],
            allowsSystemFields: false
        ))

        var flaggedRating = validRating
        flaggedRating.isCompleted = true
        XCTAssertNotNil(MediaStateEnvelopeValidator.rejectionReason(
            for: [ratingName: flaggedRating],
            allowsSystemFields: false
        ))

        let emptyRatingPayload = try JSONSerialization.data(withJSONObject: ["tmdbID": 123])
        var emptyRating = validRating
        emptyRating.payload = emptyRatingPayload
        XCTAssertNotNil(MediaStateEnvelopeValidator.rejectionReason(
            for: [ratingName: emptyRating],
            allowsSystemFields: false
        ))

        let catalogName = MediaStateRecordName.make(
            kind: .catalogOrder,
            identifier: "home",
            profileID: ProfileManager.defaultProfileID
        )
        let emptyCatalog = MediaStateEnvelope(
            recordName: catalogName,
            kind: .catalogOrder,
            payload: try JSONEncoder().encode([Catalog]()),
            modifiedAt: Date()
        )
        XCTAssertNotNil(MediaStateEnvelopeValidator.rejectionReason(
            for: [catalogName: emptyCatalog],
            allowsSystemFields: false
        ))

        let skyName = MediaStateRecordName.make(
            kind: .skyStreamMetadata,
            identifier: "safe-cloud-v1"
        )
        let invalidSky = MediaStateEnvelope(
            recordName: skyName,
            kind: .skyStreamMetadata,
            payload: Data([0x01]),
            modifiedAt: Date()
        )
        XCTAssertNotNil(MediaStateEnvelopeValidator.rejectionReason(
            for: [skyName: invalidSky],
            allowsSystemFields: false
        ))

        let movieName = MediaStateRecordName.make(
            kind: .movieProgress,
            identifier: "456",
            profileID: ProfileManager.defaultProfileID
        )
        let forgedReset = MediaStateEnvelope(
            recordName: movieName,
            kind: .movieProgress,
            payload: try wireEncode(
                MovieProgressEntry(
                    id: 456,
                    title: "Not reset",
                    currentTime: 40,
                    totalDuration: 100,
                    isWatched: false
                )
            ),
            modifiedAt: Date(),
            isExplicitReset: true
        )
        XCTAssertNotNil(MediaStateEnvelopeValidator.rejectionReason(
            for: [movieName: forgedReset],
            allowsSystemFields: false
        ))
    }

    func testExactClockTiesConvergeRegardlessOfMergeDirection() throws {
        let name = MediaStateRecordName.make(
            kind: .rating,
            identifier: "321",
            profileID: ProfileManager.defaultProfileID
        )
        let stamp = Date(timeIntervalSince1970: 1_750_000_000.123)
        let lhs = MediaStateEnvelope(
            recordName: name,
            kind: .rating,
            payload: try JSONSerialization.data(withJSONObject: [
                "tmdbID": 321,
                "rating": 7.0
            ]),
            modifiedAt: stamp,
            revision: 4
        )
        let rhs = MediaStateEnvelope(
            recordName: name,
            kind: .rating,
            payload: try JSONSerialization.data(withJSONObject: [
                "tmdbID": 321,
                "rating": 8.0
            ]),
            modifiedAt: stamp,
            revision: 4
        )

        XCTAssertEqual(lhs.merged(with: rhs), rhs.merged(with: lhs))

        let tombstone = lhs.tombstone(at: stamp)
        var tiedLive = rhs
        tiedLive.revision = tombstone.revision
        XCTAssertTrue(tombstone.merged(with: tiedLive).isDeleted)
        XCTAssertEqual(
            tombstone.merged(with: tiedLive),
            tiedLive.merged(with: tombstone)
        )
    }

    func testProfileMergeIsAssociativeAcrossGeneralAndRestrictionEdits() throws {
        let id = UUID()
        let hash = try XCTUnwrap(ProfilePINHasher.makeHash(for: "2468"))
        let name = MediaStateRecordName.make(
            kind: .profile,
            identifier: id.uuidString.lowercased()
        )
        func envelope(
            name profileName: String,
            modified: TimeInterval,
            revision: Int64,
            pinHash: String? = nil,
            pinClock: TimeInterval
        ) throws -> MediaStateEnvelope {
            let profile = Profile(
                id: id,
                name: profileName,
                pinHash: pinHash,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                pinChangedAt: Date(timeIntervalSince1970: pinClock)
            )
            return MediaStateEnvelope(
                recordName: name,
                kind: .profile,
                payload: try wireEncode(profile),
                modifiedAt: Date(timeIntervalSince1970: modified),
                revision: revision
            )
        }

        let a = try envelope(
            name: "Alpha",
            modified: 1_700_000_030,
            revision: 1,
            pinClock: 1_700_000_010
        )
        let b = try envelope(
            name: "Older general",
            modified: 1_700_000_020,
            revision: 10,
            pinHash: hash,
            pinClock: 1_700_000_040
        )
        let c = try envelope(
            name: "Charlie",
            modified: 1_700_000_030,
            revision: 1,
            pinClock: 1_700_000_010
        )

        let left = a.merged(with: b).merged(with: c)
        let right = a.merged(with: b.merged(with: c))
        XCTAssertEqual(left, right)
        XCTAssertEqual(b.merged(with: c).merged(with: a), left)
        XCTAssertEqual(c.merged(with: a).merged(with: b), left)
        let profile = try wireDecode(Profile.self, from: left.payload)
        XCTAssertEqual(profile.pinHash, hash)
        XCTAssertTrue(profile.name == "Alpha" || profile.name == "Charlie")
    }

    func testProgressResetLineageMakesThreeWayMergeAssociative() throws {
        let name = MediaStateRecordName.make(
            kind: .movieProgress,
            identifier: "900",
            profileID: ProfileManager.defaultProfileID
        )
        func envelope(
            current: Double,
            watched: Bool,
            modified: TimeInterval,
            explicitReset: Bool = false,
            resetAt: TimeInterval? = nil
        ) throws -> MediaStateEnvelope {
            var entry = MovieProgressEntry(id: 900, title: "Reset lineage")
            entry.currentTime = current
            entry.totalDuration = 100
            entry.isWatched = watched
            entry.lastUpdated = Date(timeIntervalSince1970: modified)
            return MediaStateEnvelope(
                recordName: name,
                kind: .movieProgress,
                payload: try wireEncode(entry),
                modifiedAt: Date(timeIntervalSince1970: modified),
                isCompleted: watched,
                isExplicitReset: explicitReset,
                resetAt: resetAt.map { Date(timeIntervalSince1970: $0) }
            )
        }

        let completed = try envelope(current: 100, watched: true, modified: 1_700_000_010)
        let reset = try envelope(
            current: 0,
            watched: false,
            modified: 1_700_000_020,
            explicitReset: true,
            resetAt: 1_700_000_020
        )
        let resumed = try envelope(
            current: 5,
            watched: false,
            modified: 1_700_000_030,
            resetAt: 1_700_000_020
        )

        let left = completed.merged(with: reset).merged(with: resumed)
        let right = completed.merged(with: reset.merged(with: resumed))
        XCTAssertEqual(left, right)
        XCTAssertFalse(left.isCompleted)
        XCTAssertEqual(left.resetAt, reset.resetAt)
        let entry = try wireDecode(MovieProgressEntry.self, from: left.payload)
        XCTAssertEqual(entry.currentTime, 5)
    }

    func testTraktHistoryReceiptCanonicalizesToMinuteForServerNormalization() {
        let minute = Date(timeIntervalSince1970: 1_700_000_040)
        let withSecondsAndMilliseconds = minute.addingTimeInterval(47.875)

        XCTAssertEqual(
            TraktHistoryReceiptReconciliationPolicy.canonicalMinute(withSecondsAndMilliseconds),
            minute
        )
    }

    func testTraktHistoryReceiptMatchesServerTimestampByCanonicalMinute() {
        let minute = Date(timeIntervalSince1970: 1_700_000_040)

        XCTAssertTrue(TraktHistoryReceiptReconciliationPolicy.containsReceipt(
            watchedAt: minute.addingTimeInterval(42.25),
            historyWatchedAt: [minute]
        ))
        XCTAssertFalse(TraktHistoryReceiptReconciliationPolicy.containsReceipt(
            watchedAt: minute.addingTimeInterval(42.25),
            historyWatchedAt: [minute.addingTimeInterval(60)]
        ))
    }

    func testTraktHistoryPendingReceiptWaitsBeforeAuthoritativeReconciliation() {
        let attemptedAt = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertEqual(
            TraktHistoryReceiptReconciliationPolicy.decision(
                lastAttemptAt: attemptedAt,
                confirmedAt: nil,
                now: attemptedAt.addingTimeInterval(119),
                reconciliationDelay: 120,
                confirmedInterval: 60
            ),
            .waitForReconciliation
        )
        XCTAssertEqual(
            TraktHistoryReceiptReconciliationPolicy.decision(
                lastAttemptAt: attemptedAt,
                confirmedAt: nil,
                now: attemptedAt.addingTimeInterval(120),
                reconciliationDelay: 120,
                confirmedInterval: 60
            ),
            .reconcile
        )
    }

    func testTraktHistoryConfirmedReceiptSuppressesRecentCallback() {
        let confirmedAt = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertEqual(
            TraktHistoryReceiptReconciliationPolicy.decision(
                lastAttemptAt: confirmedAt,
                confirmedAt: confirmedAt,
                now: confirmedAt.addingTimeInterval(59),
                reconciliationDelay: 120,
                confirmedInterval: 60
            ),
            .suppressConfirmed
        )
    }

    func testWatchSyncDedupeCoalescesInFlightAndReleasesFailureForRetry() {
        var gate = TrackerWatchSyncDedupeGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)

        let first = gate.begin(
            key: "profile|episode",
            now: startedAt,
            completedInterval: 60,
            staleInFlightInterval: 600
        )
        XCTAssertNotNil(first)
        XCTAssertNil(gate.begin(
            key: "profile|episode",
            now: startedAt.addingTimeInterval(1),
            completedInterval: 60,
            staleInFlightInterval: 600
        ), "A concurrent callback must coalesce while the first sync is in flight")

        gate.finish(
            registration: first!,
            succeeded: false,
            now: startedAt.addingTimeInterval(2)
        )
        XCTAssertNotNil(gate.begin(
            key: "profile|episode",
            now: startedAt.addingTimeInterval(3),
            completedInterval: 60,
            staleInFlightInterval: 600
        ), "A failed provider write or resolution must be immediately retryable")
    }

    func testWatchSyncDedupeSuppressesOnlyRecentSuccess() {
        var gate = TrackerWatchSyncDedupeGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)

        let first = gate.begin(
            key: "profile|episode",
            now: startedAt,
            completedInterval: 60,
            staleInFlightInterval: 600
        )
        XCTAssertNotNil(first)
        gate.finish(
            registration: first!,
            succeeded: true,
            now: startedAt.addingTimeInterval(5)
        )
        XCTAssertNil(gate.begin(
            key: "profile|episode",
            now: startedAt.addingTimeInterval(30),
            completedInterval: 60,
            staleInFlightInterval: 600
        ))
        XCTAssertNotNil(gate.begin(
            key: "profile|episode",
            now: startedAt.addingTimeInterval(66),
            completedInterval: 60,
            staleInFlightInterval: 600
        ))
    }

    func testWatchSyncDedupeRetainsSuccessPerProviderWhileRetryingFailure() throws {
        var gate = TrackerWatchSyncDedupeGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let trakt = try XCTUnwrap(gate.begin(
            key: "profile|trakt-account|episode",
            now: startedAt,
            completedInterval: 60,
            staleInFlightInterval: 600
        ))
        let mal = try XCTUnwrap(gate.begin(
            key: "profile|mal-account|episode",
            now: startedAt,
            completedInterval: 60,
            staleInFlightInterval: 600
        ))

        gate.finish(registration: trakt, succeeded: true, now: startedAt.addingTimeInterval(1))
        gate.finish(registration: mal, succeeded: false, now: startedAt.addingTimeInterval(1))

        XCTAssertNil(gate.begin(
            key: "profile|trakt-account|episode",
            now: startedAt.addingTimeInterval(2),
            completedInterval: 60,
            staleInFlightInterval: 600
        ), "A successful Trakt history write must not be resent when another provider fails")
        XCTAssertNotNil(gate.begin(
            key: "profile|mal-account|episode",
            now: startedAt.addingTimeInterval(2),
            completedInterval: 60,
            staleInFlightInterval: 600
        ), "Only the failed provider account should retry")
    }

    func testStaleWatchSyncCompletionCannotFinishNewerAttempt() throws {
        var gate = TrackerWatchSyncDedupeGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let stale = try XCTUnwrap(gate.begin(
            key: "profile|episode",
            now: startedAt,
            completedInterval: 60,
            staleInFlightInterval: 600
        ))
        let retry = try XCTUnwrap(gate.begin(
            key: "profile|episode",
            now: startedAt.addingTimeInterval(601),
            completedInterval: 60,
            staleInFlightInterval: 600
        ))

        gate.finish(
            registration: stale,
            succeeded: true,
            now: startedAt.addingTimeInterval(602)
        )
        XCTAssertNil(gate.begin(
            key: "profile|episode",
            now: startedAt.addingTimeInterval(603),
            completedInterval: 60,
            staleInFlightInterval: 600
        ), "The newer retry must remain in flight when an expired task finishes late")

        gate.finish(
            registration: retry,
            succeeded: false,
            now: startedAt.addingTimeInterval(604)
        )
        XCTAssertNotNil(gate.begin(
            key: "profile|episode",
            now: startedAt.addingTimeInterval(605),
            completedInterval: 60,
            staleInFlightInterval: 600
        ))
    }

    func testCatalogSnapshotDistinguishesMissingFromUnreadableStore() {
        let profileID = UUID()
        let key = CatalogManager.catalogsKey(for: profileID)
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: key) }

        defaults.removeObject(forKey: key)
        XCTAssertNotNil(
            CatalogManager.shared.catalogsForMediaStateSync(forProfile: profileID),
            "A missing store legitimately means the product baseline"
        )

        let corrupt = Data([0xff, 0x00, 0x7f])
        defaults.set(corrupt, forKey: key)
        XCTAssertNil(
            CatalogManager.shared.catalogsForMediaStateSync(forProfile: profileID),
            "Existing undecodable bytes must not become an authoritative baseline"
        )
        XCTAssertEqual(defaults.data(forKey: key), corrupt)

        defaults.set("wrong plist type", forKey: key)
        XCTAssertNil(
            CatalogManager.shared.catalogsForMediaStateSync(forProfile: profileID),
            "A present non-Data value is corruption, not an absent store"
        )

        defaults.set(try! JSONEncoder().encode([Catalog]()), forKey: key)
        XCTAssertFalse(
            CatalogManager.shared.catalogsForMediaStateSync(forProfile: profileID)?.isEmpty ?? true,
            "Inactive empty stores must normalize exactly like the active profile"
        )
        XCTAssertFalse(
            CatalogManager.shared.catalogsForBackup(forProfile: profileID)?.isEmpty ?? true
        )
    }

    func testBookmarksNameIsReservedCaseInsensitively() {
        XCTAssertTrue(LibraryManager.isBookmarksName("Bookmarks"))
        XCTAssertTrue(LibraryManager.isBookmarksName("  bOoKmArKs\n"))
        XCTAssertFalse(LibraryManager.isBookmarksName("My Bookmarks"))
    }

    func testDelayedProgressWriteRequiresOwnerGenerationAndDestination() throws {
        let profileA = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-4000-A000-000000000201")
        )
        let profileB = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-4000-A000-000000000202")
        )
        let destinationA = URL(fileURLWithPath: "/tmp/progress-a.json")
        let destinationB = URL(fileURLWithPath: "/tmp/progress-b.json")

        XCTAssertTrue(ProgressManager.storeWriteIdentityIsCurrent(
            requestProfileID: profileA,
            requestGeneration: 7,
            requestDestination: destinationA,
            requestSequence: 12,
            currentProfileID: profileA,
            currentGeneration: 7,
            currentDestination: destinationA,
            currentSequence: 12
        ))
        XCTAssertFalse(ProgressManager.storeWriteIdentityIsCurrent(
            requestProfileID: profileA,
            requestGeneration: 7,
            requestDestination: destinationA,
            requestSequence: 12,
            currentProfileID: profileB,
            currentGeneration: 8,
            currentDestination: destinationB,
            currentSequence: 13
        ))
        XCTAssertFalse(ProgressManager.storeWriteIdentityIsCurrent(
            requestProfileID: profileA,
            requestGeneration: 7,
            requestDestination: destinationA,
            requestSequence: 12,
            currentProfileID: profileA,
            currentGeneration: 9,
            currentDestination: destinationA,
            currentSequence: 14
        ), "A stale A → B → A task must still fail after the owner UUID matches again")
        XCTAssertFalse(ProgressManager.storeWriteIdentityIsCurrent(
            requestProfileID: profileA,
            requestGeneration: 7,
            requestDestination: destinationA,
            requestSequence: 11,
            currentProfileID: profileA,
            currentGeneration: 7,
            currentDestination: destinationA,
            currentSequence: 12
        ), "A cancelled debounce must not overwrite a newer same-profile flush")

        XCTAssertNil(ProgressManager.authorizedNextStoreWriteSequence(
            currentProfileID: profileB,
            expectedProfileID: profileA,
            currentSequence: 12
        ), "A stale restore must not consume the incoming profile's next sequence")
        XCTAssertEqual(ProgressManager.authorizedNextStoreWriteSequence(
            currentProfileID: profileB,
            expectedProfileID: profileB,
            currentSequence: 12
        ), 13)
    }

    func testDeferredProgressReservationIsSupersededBySameProfileMutation() throws {
        let profileID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-4000-A000-000000000203")
        )
        let destination = URL(fileURLWithPath: "/tmp/progress-same-profile.json")

        XCTAssertFalse(ProgressManager.storeWriteIdentityIsCurrent(
            requestProfileID: profileID,
            requestGeneration: 7,
            requestDestination: destination,
            requestSequence: 41,
            currentProfileID: profileID,
            currentGeneration: 7,
            currentDestination: destination,
            currentSequence: 42
        ))
        XCTAssertTrue(ProgressManager.storeWriteIdentityIsCurrent(
            requestProfileID: profileID,
            requestGeneration: 7,
            requestDestination: destination,
            requestSequence: 42,
            currentProfileID: profileID,
            currentGeneration: 7,
            currentDestination: destination,
            currentSequence: 42
        ))
    }

    func testDeferredProgressReservationCannotRegainAuthorityAfterProfileRoundTrip() throws {
        let profileID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-4000-A000-000000000204")
        )
        let destination = URL(fileURLWithPath: "/tmp/progress-profile-round-trip.json")

        XCTAssertFalse(ProgressManager.storeWriteIdentityIsCurrent(
            requestProfileID: profileID,
            requestGeneration: 7,
            requestDestination: destination,
            requestSequence: 42,
            currentProfileID: profileID,
            currentGeneration: 9,
            currentDestination: destination,
            currentSequence: 42
        ))
    }

    func testProgressDebounceGenerationAndMaximumLatencySemantics() {
        let firstGeneration = ProgressManager.nextDebounceGeneration(after: 8)
        let replacementGeneration = ProgressManager.nextDebounceGeneration(
            after: firstGeneration
        )
        let maximumLatencyGeneration = ProgressManager.nextDebounceGeneration(
            after: replacementGeneration
        )
        let firstChangeAt = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertFalse(ProgressManager.debounceGenerationIsCurrent(
            firstGeneration,
            current: replacementGeneration
        ))
        XCTAssertFalse(ProgressManager.debounceGenerationIsCurrent(
            replacementGeneration,
            current: maximumLatencyGeneration
        ))
        XCTAssertTrue(ProgressManager.debounceGenerationIsCurrent(
            maximumLatencyGeneration,
            current: maximumLatencyGeneration
        ))
        XCTAssertFalse(ProgressManager.debounceMaximumLatencyReached(
            firstChangeAt: firstChangeAt,
            now: firstChangeAt.addingTimeInterval(19.999),
            maximumLatency: 20
        ))
        XCTAssertTrue(ProgressManager.debounceMaximumLatencyReached(
            firstChangeAt: firstChangeAt,
            now: firstChangeAt.addingTimeInterval(20),
            maximumLatency: 20
        ))
    }

    func testProgressFlushSupersedesDebounceAndPreservesFlushWrite() throws {
        let profileID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-4000-A000-000000000205")
        )
        let destination = URL(fileURLWithPath: "/tmp/progress-flush.json")
        let reservationSequence: UInt64 = 42
        let reservationGeneration = ProgressManager.nextDebounceGeneration(after: 8)
        let flushGeneration = ProgressManager.nextDebounceGeneration(
            after: reservationGeneration
        )
        let flushSequence = try XCTUnwrap(
            ProgressManager.authorizedNextStoreWriteSequence(
                currentProfileID: profileID,
                expectedProfileID: nil,
                currentSequence: reservationSequence
            )
        )

        XCTAssertFalse(ProgressManager.debounceGenerationIsCurrent(
            reservationGeneration,
            current: flushGeneration
        ))
        XCTAssertFalse(ProgressManager.storeWriteIdentityIsCurrent(
            requestProfileID: profileID,
            requestGeneration: 7,
            requestDestination: destination,
            requestSequence: reservationSequence,
            currentProfileID: profileID,
            currentGeneration: 7,
            currentDestination: destination,
            currentSequence: flushSequence
        ))
        XCTAssertTrue(ProgressManager.storeWriteIdentityIsCurrent(
            requestProfileID: profileID,
            requestGeneration: 7,
            requestDestination: destination,
            requestSequence: flushSequence,
            currentProfileID: profileID,
            currentGeneration: 7,
            currentDestination: destination,
            currentSequence: flushSequence
        ))
    }

    func testPeriodicProgressPublicationCoalescesOnlyWithinOneProfileGeneration() throws {
        let profileID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-4000-A000-000000000206")
        )

        XCTAssertTrue(ProgressManager.periodicProgressPublicationCanReuseScheduledTask(
            scheduledProfileID: profileID,
            scheduledStoreGeneration: 7,
            currentProfileID: profileID,
            currentStoreGeneration: 7
        ))
        XCTAssertFalse(ProgressManager.periodicProgressPublicationCanReuseScheduledTask(
            scheduledProfileID: profileID,
            scheduledStoreGeneration: 7,
            currentProfileID: profileID,
            currentStoreGeneration: 9
        ))
    }

    func testPeriodicProgressPublicationRejectsSupersededTaskAndFlushSnapshot() throws {
        let profileID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-4000-A000-000000000207")
        )
        let taskToken = ProgressManager.nextPeriodicProgressPublicationGeneration(after: 11)
        let replacementToken = ProgressManager.nextPeriodicProgressPublicationGeneration(
            after: taskToken
        )
        let snapshotGeneration = ProgressManager.nextPeriodicProgressPublicationGeneration(after: 20)
        let flushGeneration = ProgressManager.nextPeriodicProgressPublicationGeneration(
            after: snapshotGeneration
        )

        XCTAssertTrue(ProgressManager.periodicProgressPublicationTaskIsCurrent(
            taskProfileID: profileID,
            taskStoreGeneration: 7,
            taskToken: taskToken,
            currentProfileID: profileID,
            currentStoreGeneration: 7,
            currentToken: taskToken
        ))
        XCTAssertFalse(ProgressManager.periodicProgressPublicationTaskIsCurrent(
            taskProfileID: profileID,
            taskStoreGeneration: 7,
            taskToken: taskToken,
            currentProfileID: profileID,
            currentStoreGeneration: 7,
            currentToken: replacementToken
        ))
        XCTAssertFalse(ProgressManager.periodicProgressPublicationTaskIsCurrent(
            taskProfileID: profileID,
            taskStoreGeneration: 7,
            taskToken: taskToken,
            currentProfileID: profileID,
            currentStoreGeneration: 9,
            currentToken: taskToken
        ))
        XCTAssertFalse(ProgressManager.periodicProgressPublicationSnapshotIsCurrent(
            publicationProfileID: profileID,
            publicationStoreGeneration: 7,
            publicationInvalidationGeneration: snapshotGeneration,
            currentProfileID: profileID,
            currentStoreGeneration: 7,
            currentInvalidationGeneration: flushGeneration
        ))
        XCTAssertTrue(ProgressManager.periodicProgressPublicationSnapshotIsCurrent(
            publicationProfileID: profileID,
            publicationStoreGeneration: 7,
            publicationInvalidationGeneration: flushGeneration,
            currentProfileID: profileID,
            currentStoreGeneration: 7,
            currentInvalidationGeneration: flushGeneration
        ))
    }

    func testPlaybackLeaseDefersAutomaticCaptureAndSynchronization() {
        let starting = MediaStatePlaybackLeaseSnapshot(generation: 7, isActive: false)
        XCTAssertFalse(
            MediaStatePlaybackLeaseLifecyclePolicy.allowsAutomaticSynchronization(
                isPlaybackLeaseActive: true
            )
        )
        XCTAssertTrue(
            MediaStatePlaybackLeaseLifecyclePolicy.allowsAutomaticSynchronization(
                isPlaybackLeaseActive: false
            )
        )
        XCTAssertTrue(
            MediaStatePlaybackLeaseLifecyclePolicy.automaticSynchronizationAuthorityIsCurrent(
                starting: starting,
                current: starting
            )
        )
        XCTAssertFalse(
            MediaStatePlaybackLeaseLifecyclePolicy.automaticSynchronizationAuthorityIsCurrent(
                starting: starting,
                current: MediaStatePlaybackLeaseSnapshot(generation: 8, isActive: true)
            )
        )
        XCTAssertFalse(
            MediaStatePlaybackLeaseLifecyclePolicy.automaticSynchronizationAuthorityIsCurrent(
                starting: starting,
                current: MediaStatePlaybackLeaseSnapshot(generation: 8, isActive: false)
            )
        )
    }

    func testDelayedTrackerSyncRequiresOriginatingProfileAndProgressGeneration() throws {
        let profileA = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-4000-A000-000000000211")
        )
        let profileB = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-4000-A000-000000000212")
        )

        XCTAssertTrue(ProgressManager.profileMutationAuthorityIsCurrent(
            authorityProfileID: profileA,
            authorityGeneration: 7,
            currentProfileID: profileA,
            currentGeneration: 7
        ))
        XCTAssertFalse(ProgressManager.profileMutationAuthorityIsCurrent(
            authorityProfileID: profileA,
            authorityGeneration: 7,
            currentProfileID: profileB,
            currentGeneration: 8
        ))
        XCTAssertFalse(ProgressManager.profileMutationAuthorityIsCurrent(
            authorityProfileID: profileA,
            authorityGeneration: 7,
            currentProfileID: profileA,
            currentGeneration: 9
        ), "A delayed A → B → A callback must not regain authority")

        let postRestoreGeneration = ProgressManager.storeGenerationAfterAuthoritativeRestore(7)
        XCTAssertFalse(ProgressManager.profileMutationAuthorityIsCurrent(
            authorityProfileID: profileA,
            authorityGeneration: 7,
            currentProfileID: profileA,
            currentGeneration: postRestoreGeneration
        ), "A same-profile authoritative restore must revoke pre-restore playback work")

        XCTAssertTrue(TrackerManager.trackerOperationAuthorityIsCurrent(
            authorityGeneration: 12,
            currentGeneration: 12
        ))
        XCTAssertFalse(TrackerManager.trackerOperationAuthorityIsCurrent(
            authorityGeneration: 12,
            currentGeneration: 14
        ), "A direct player operation queued before A → B → A must not regain tracker authority")
        XCTAssertFalse(TrackerManager.traktScrobbleCompletionRecordsFailure(
            sent: false,
            cancelled: true
        ), "A stale scrobble must clear only its pending marker, not suppress fresh work with a failure cooldown")
        XCTAssertTrue(TrackerManager.traktScrobbleCompletionRecordsFailure(
            sent: false,
            cancelled: false
        ))
        let oldPendingScrobble = UUID()
        let replacementPendingScrobble = UUID()
        XCTAssertTrue(TrackerManager.traktScrobblePendingCompletionIsCurrent(
            expectedID: oldPendingScrobble,
            currentID: oldPendingScrobble
        ))
        XCTAssertFalse(TrackerManager.traktScrobblePendingCompletionIsCurrent(
            expectedID: oldPendingScrobble,
            currentID: replacementPendingScrobble
        ), "An old completion must not clear or stamp a replacement same-key scrobble")
        XCTAssertFalse(TrackerManager.traktScrobblePendingCompletionIsCurrent(
            expectedID: oldPendingScrobble,
            currentID: nil
        ))
        XCTAssertNil(TrackerManager.normalizedWatchSyncProgress(.infinity))
        XCTAssertNil(TrackerManager.normalizedWatchSyncProgress(.nan))
        XCTAssertEqual(TrackerManager.normalizedWatchSyncProgress(0.9), 90)
        XCTAssertEqual(TrackerManager.watchSyncLogPercent(Double.greatestFiniteMagnitude), 100)
        XCTAssertEqual(TrackerManager.watchSyncLogPercent(-Double.greatestFiniteMagnitude), 0)
        XCTAssertEqual(TrackerManager.boundedPaginationInteger("5", in: 0...5), 5)
        XCTAssertNil(TrackerManager.boundedPaginationInteger("6", in: 0...5))
        XCTAssertNil(TrackerManager.boundedPaginationInteger("1.5", in: 0...5))
        XCTAssertNil(TrackerManager.boundedPaginationInteger(
            String(repeating: "9", count: 1_000),
            in: 0...5
        ))

        XCTAssertEqual(
            TrackerManager.resolvedPlaybackOperationOwner(
                requiredOwner: profileA,
                progressAuthorityOwner: profileA,
                progressAuthorityIsCurrent: true,
                trackerProfileID: profileA,
                activeProfileID: profileA
            ),
            profileA
        )
        XCTAssertNil(TrackerManager.resolvedPlaybackOperationOwner(
            requiredOwner: profileA,
            progressAuthorityOwner: profileA,
            progressAuthorityIsCurrent: true,
            trackerProfileID: profileB,
            activeProfileID: profileB
        ), "Profile A progress must never select profile B's tracker state")
        XCTAssertNil(TrackerManager.resolvedPlaybackOperationOwner(
            requiredOwner: profileA,
            progressAuthorityOwner: profileA,
            progressAuthorityIsCurrent: false,
            trackerProfileID: profileA,
            activeProfileID: profileA
        ), "A stale generation must stay rejected after switching back to profile A")
        XCTAssertNil(TrackerManager.resolvedPlaybackOperationOwner(
            requiredOwner: profileB,
            progressAuthorityOwner: profileA,
            progressAuthorityIsCurrent: true,
            trackerProfileID: profileB,
            activeProfileID: profileB
        ), "A caller cannot relabel profile A progress as profile B work")

        XCTAssertEqual(
            TrackerManager.resolvedPlaybackOperationOwner(
                requiredOwner: nil,
                progressAuthorityOwner: nil,
                progressAuthorityIsCurrent: true,
                trackerProfileID: profileB,
                activeProfileID: profileB
            ),
            profileB,
            "Existing current-profile callers keep their previous behavior"
        )
    }

    func testTrackerRateLimitHeadersCannotCreateUnrepresentableDelays() {
        for hostile in ["nan", "inf", "-inf"] {
            XCTAssertEqual(TrackerRateLimitHeaderPolicy.retryDelay(hostile), 5)
            XCTAssertNil(TrackerRateLimitHeaderPolicy.minimumSpacing(hostile))
            XCTAssertNil(
                TrackerRateLimitHeaderPolicy.resetDelay(
                    hostile,
                    now: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
        }

        XCTAssertEqual(TrackerRateLimitHeaderPolicy.retryDelay("1e300"), 120)
        XCTAssertEqual(TrackerRateLimitHeaderPolicy.minimumSpacing("1e300"), 0.8)
        XCTAssertEqual(TrackerRateLimitHeaderPolicy.minimumSpacing("1e-300"), 120)
        XCTAssertNil(
            TrackerRateLimitHeaderPolicy.resetDelay(
                "1e300",
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        XCTAssertEqual(TrackerRateLimitHeaderPolicy.retryDelay("30"), 30)
        XCTAssertEqual(TrackerRateLimitHeaderPolicy.sleepNanoseconds(for: 30), 30_000_000_000)
        XCTAssertEqual(TrackerRateLimitHeaderPolicy.displaySeconds(for: 30.1), 31)
        XCTAssertNil(TrackerRateLimitHeaderPolicy.sleepNanoseconds(for: .infinity))
        XCTAssertNil(TrackerRateLimitHeaderPolicy.sleepNanoseconds(for: 1e300))
        XCTAssertNil(TrackerRateLimitHeaderPolicy.displaySeconds(for: .nan))
    }

    func testMissingProfileBookmarksBaselineIsByteStableAcrossReadOnlySnapshots() throws {
        let firstProfileID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-4000-A000-000000000101")
        )
        let secondProfileID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-4000-A000-000000000102")
        )

        let firstRead = LibraryManager.normalizedCollections([], forProfile: firstProfileID)
        let secondRead = LibraryManager.normalizedCollections([], forProfile: firstProfileID)
        let otherProfile = LibraryManager.normalizedCollections([], forProfile: secondProfileID)

        XCTAssertEqual(firstRead.count, 1)
        XCTAssertEqual(firstRead[0].id, secondRead[0].id)
        XCTAssertEqual(
            firstRead[0].id,
            LibraryManager.bookmarksCollectionID(forProfile: firstProfileID)
        )
        XCTAssertNotEqual(
            firstRead[0].id,
            otherProfile[0].id,
            "Each profile gets its own stable baseline identity"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            try encoder.encode(firstRead),
            try encoder.encode(secondRead),
            "A read-only snapshot must not synthesize a fresh UUID on every sync pass"
        )
    }

    func testLegacyBookmarkDuplicatesMergeDeterministicallyWithoutItemLoss() throws {
        let canonicalID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-A000-000000000002"))
        let duplicateID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-A000-000000000001"))
        let ordinaryID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-A000-000000000003"))

        let olderMovie = libraryItem(
            id: 10,
            mediaType: "movie",
            dateAdded: Date(timeIntervalSinceReferenceDate: 10)
        )
        let newerMovie = libraryItem(
            id: 10,
            mediaType: "movie",
            dateAdded: Date(timeIntervalSinceReferenceDate: 30)
        )
        let sameNumericTV = libraryItem(
            id: 10,
            mediaType: "tv",
            dateAdded: Date(timeIntervalSinceReferenceDate: 20)
        )
        let otherMovie = libraryItem(
            id: 11,
            mediaType: "movie",
            dateAdded: Date(timeIntervalSinceReferenceDate: 15)
        )

        let canonical = LibraryCollection(
            id: canonicalID,
            name: "Bookmarks",
            items: [olderMovie, otherMovie],
            description: "Your bookmarked items"
        )
        let legacyDuplicate = LibraryCollection(
            id: duplicateID,
            name: " bookmarks ",
            items: [newerMovie, sameNumericTV]
        )
        let ordinary = LibraryCollection(id: ordinaryID, name: "Favorites")

        let first = LibraryManager.normalizedCollections([
            legacyDuplicate,
            ordinary,
            canonical
        ])
        let second = LibraryManager.normalizedCollections([
            canonical,
            legacyDuplicate,
            ordinary
        ])

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0].id, canonicalID, "The exact canonical row remains pinned")
        XCTAssertEqual(first[0].name, "Bookmarks")
        XCTAssertEqual(first[1].id, ordinaryID)
        XCTAssertEqual(Set(first[0].items.map(\.id)), ["movie-10", "movie-11", "tv-10"])
        XCTAssertEqual(
            first[0].items.first(where: { $0.id == "movie-10" })?.dateAdded,
            newerMovie.dateAdded,
            "Duplicate membership keeps the freshest payload without moving its established position"
        )
        XCTAssertEqual(first[0].items.map(\.id), second[0].items.map(\.id))
        XCTAssertEqual(first[0].id, second[0].id)
    }

    func testOversizedRosterIsCarriedInsteadOfBrickingEveryRead() throws {
        let liveCount = MediaStateEnvelopeValidator.maximumRemoteLiveProfileRecords + 3
        var records: [String: MediaStateEnvelope] = [:]
        for index in 0..<liveCount {
            let profile = Profile(name: "Profile \(index)")
            let name = MediaStateRecordName.make(
                kind: .profile,
                identifier: profile.id.uuidString.lowercased()
            )
            records[name] = MediaStateEnvelope(
                recordName: name,
                kind: .profile,
                payload: try wireEncode(profile),
                modifiedAt: Date()
            )
        }

        XCTAssertNil(
            MediaStateEnvelopeValidator.aggregateRejectionReason(
                for: records,
                allowsSystemFields: false
            ),
            "A roster larger than one device can hold must not make every future read of that bundle fail"
        )
        XCTAssertNotNil(
            MediaStateEnvelopeValidator.rosterOverflowDescription(in: records),
            "The overflow still has to be reported so the roster merge is known to be doing the capping"
        )
        XCTAssertEqual(
            MediaStateEnvelopeValidator.liveProfileRecordCount(in: records),
            liveCount
        )
    }

    func testDeletedProfilesDoNotCountTowardRosterOverflow() throws {
        var records: [String: MediaStateEnvelope] = [:]
        for index in 0..<(MediaStateEnvelopeValidator.maximumRemoteLiveProfileRecords + 4) {
            let profile = Profile(name: "Profile \(index)")
            let name = MediaStateRecordName.make(
                kind: .profile,
                identifier: profile.id.uuidString.lowercased()
            )
            var envelope = MediaStateEnvelope(
                recordName: name,
                kind: .profile,
                payload: try wireEncode(profile),
                modifiedAt: Date()
            )
            if index >= 2 {
                envelope.payload = Data()
                envelope.deletedAt = Date()
            }
            records[name] = envelope
        }

        XCTAssertEqual(MediaStateEnvelopeValidator.liveProfileRecordCount(in: records), 2)
        XCTAssertNil(MediaStateEnvelopeValidator.rosterOverflowDescription(in: records))
    }

    func testOneBadRecordDoesNotDiscardTheRestOfARemoteBundle() throws {
        let profile = Profile(name: "Keeper")
        let goodName = MediaStateRecordName.make(
            kind: .profile,
            identifier: profile.id.uuidString.lowercased()
        )
        let good = MediaStateEnvelope(
            recordName: goodName,
            kind: .profile,
            payload: try wireEncode(profile),
            modifiedAt: Date()
        )
        let badName = MediaStateRecordName.make(
            kind: .profile,
            identifier: UUID().uuidString.lowercased()
        )
        let bad = MediaStateEnvelope(
            recordName: badName,
            kind: .rating,
            payload: Data(),
            modifiedAt: Date()
        )

        let usable = MediaStateEnvelopeValidator.structurallyValidRemoteRecords(
            [goodName: good, badName: bad]
        )

        XCTAssertEqual(usable.droppedRecordNames, [badName])
        XCTAssertEqual(Set(usable.records.keys), [goodName])
    }

    func testStreamURLDeliveryDefectsAreDetectedWithoutFlaggingLegalURLs() {
        XCTAssertNil(
            SkyStreamRemoteURLPolicy.deliveryDefect(
                in: "https://host.example/dir/file(2024).mkv?token=abc&x=1#frag"
            ),
            "Parentheses and query delimiters are legal URI characters and must not be reported as defects"
        )
        XCTAssertNil(
            SkyStreamRemoteURLPolicy.deliveryDefect(in: "https://host.example/%E3%81%82/file.mkv")
        )

        let spaced = try? XCTUnwrap(
            SkyStreamRemoteURLPolicy.deliveryDefect(
                in: "https://host.example/file.mkv) 1080p 2.5GB"
            )
        )
        XCTAssertEqual(spaced, "whitespace")

        XCTAssertEqual(
            SkyStreamRemoteURLPolicy.deliveryDefect(in: "https://host.example/a<b>c"),
            "illegal:<>"
        )
        XCTAssertTrue(
            SkyStreamRemoteURLPolicy.defectEvidence(
                of: "https://host.example/file.mkv) 1080p?token=secret"
            ).contains("\u{2423}"),
            "Whitespace has to stay visible in the evidence, and the query must be stripped"
        )
        XCTAssertFalse(
            SkyStreamRemoteURLPolicy.defectEvidence(
                of: "https://host.example/file.mkv) 1080p?token=secret"
            ).contains("secret")
        )
    }

    func testCloudKitPreparationAuthorityRejectsSupersededAndDisabledPasses() {
        XCTAssertTrue(
            MediaStateCloudKitPreparationAuthorityPolicy.mayInstallEngine(
                preparationGeneration: 8,
                currentGeneration: 8,
                isSyncEnabled: true,
                isRecoveryBlocked: false,
                isDeletingRemoteState: false
            )
        )
        XCTAssertFalse(
            MediaStateCloudKitPreparationAuthorityPolicy.mayInstallEngine(
                preparationGeneration: 7,
                currentGeneration: 8,
                isSyncEnabled: true,
                isRecoveryBlocked: false,
                isDeletingRemoteState: false
            )
        )
        XCTAssertFalse(
            MediaStateCloudKitPreparationAuthorityPolicy.mayInstallEngine(
                preparationGeneration: 8,
                currentGeneration: 8,
                isSyncEnabled: false,
                isRecoveryBlocked: false,
                isDeletingRemoteState: false
            )
        )
    }

    func testCloudKitSyncPreferenceRegistersOffByDefault() throws {
        let suiteName = "MediaStateCloudKitOptInTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        ExperimentalFeatureState.registerDefaults(defaults: defaults)
        XCTAssertFalse(
            defaults.bool(forKey: ExperimentalFeatureState.iCloudSyncEnabledKey)
        )
    }

    func testUseThisDeviceRequiresLocalCaptureAuthority() {
        XCTAssertFalse(
            MediaStateLocalCapturePolicy.capturesLocalChanges(
                initialFetchCompleted: false,
                isTrustedOfflineCacheActive: false,
                isRemoteTransportModeActive: false
            )
        )
        XCTAssertTrue(
            MediaStateLocalCapturePolicy.capturesLocalChanges(
                initialFetchCompleted: true,
                isTrustedOfflineCacheActive: false,
                isRemoteTransportModeActive: false
            )
        )
    }

    func testFinalizedTVPlaybackCannotBeginOrLeakALease() {
        XCTAssertFalse(
            MediaStatePlaybackLeaseLifecyclePolicy.shouldBegin(
                hasFinalizedPlayback: true,
                hasBegunLease: false
            )
        )
        XCTAssertTrue(
            MediaStatePlaybackLeaseLifecyclePolicy.shouldEnd(
                hasBegunLease: true,
                hasEndedLease: false
            )
        )
    }

    func testUnchangedAccountNotificationKeepsLocalMigrationAuthority() {
        XCTAssertTrue(
            MediaStateSameAccountRevalidationPolicy.shouldMigrateLocalState(
                isRevalidationInProgress: true,
                hadPendingIsolation: false,
                isAccountNeutralLocalStateActive: false,
                hasDeliberateLocalCacheReset: false,
                previousAccountRecordName: "account-a",
                currentAccountRecordName: "account-a"
            )
        )
        XCTAssertFalse(
            MediaStateSameAccountRevalidationPolicy.shouldMigrateLocalState(
                isRevalidationInProgress: true,
                hadPendingIsolation: false,
                isAccountNeutralLocalStateActive: false,
                hasDeliberateLocalCacheReset: false,
                previousAccountRecordName: "account-a",
                currentAccountRecordName: "account-b"
            )
        )
    }

    func testDeferredRemoteApplyFlushesLocalCaptureBeforeOwnedArchiveApply() {
        XCTAssertTrue(
            MediaStateDeferredApplyPolicy.shouldFlushPendingCapture(
                isSignedOutIdentityConfirmed: false,
                verifiedOwnerMatchesArchive: true,
                isTrustedOfflineCacheActive: false,
                hasArchiveOwner: true
            )
        )
        XCTAssertFalse(
            MediaStateDeferredApplyPolicy.shouldFlushPendingCapture(
                isSignedOutIdentityConfirmed: true,
                verifiedOwnerMatchesArchive: true,
                isTrustedOfflineCacheActive: true,
                hasArchiveOwner: true
            )
        )
    }

    func testCloudKitSaveFailurePolicySeparatesPermanentFailuresFromBackoff() {
        XCTAssertNotNil(
            MediaStateCloudKitSaveFailurePolicy.permanentFailureMessage(
                for: .quotaExceeded
            )
        )
        XCTAssertNotNil(
            MediaStateCloudKitSaveFailurePolicy.permanentFailureMessage(
                for: .invalidArguments
            )
        )
        XCTAssertNil(
            MediaStateCloudKitSaveFailurePolicy.permanentFailureMessage(
                for: .requestRateLimited
            )
        )
        XCTAssertTrue(
            MediaStateCloudKitSaveFailurePolicy.shouldRetryAutomatically(
                .requestRateLimited
            )
        )
        XCTAssertFalse(
            MediaStateCloudKitSaveFailurePolicy.shouldRetryAutomatically(
                .quotaExceeded
            )
        )
    }

    func testInvalidLocalProgressForcesDomainPreservation() {
        let profileID = UUID()
        let name = MediaStateRecordName.make(
            kind: .movieProgress,
            identifier: "42",
            profileID: profileID
        )
        XCTAssertTrue(
            MediaStateInvalidLocalDomainPolicy.shouldPreserveLocalDomain(
                invalidRecordNames: [name],
                domainKinds: [.movieProgress, .episodeProgress],
                profileID: profileID
            )
        )
        XCTAssertFalse(
            MediaStateInvalidLocalDomainPolicy.shouldPreserveLocalDomain(
                invalidRecordNames: [name],
                domainKinds: [.rating],
                profileID: profileID
            )
        )
    }

    func testPendingIsolationCancellationReturnsToVerifiedOwnerRegardlessOfLease() {
        XCTAssertTrue(
            MediaStatePendingIsolationCancellationPolicy.canReturnToOwnerWithoutCleanup(
                archiveOwnerRecordName: "account-a",
                currentAccountRecordName: "account-a",
                isAccountNeutralLocalStateActive: false,
                hasPendingProfiles: true,
                pendingTargetMatchesCurrentAccount: false
            )
        )
        XCTAssertFalse(
            MediaStatePendingIsolationCancellationPolicy.canReturnToOwnerWithoutCleanup(
                archiveOwnerRecordName: "account-a",
                currentAccountRecordName: "account-a",
                isAccountNeutralLocalStateActive: false,
                hasPendingProfiles: true,
                pendingTargetMatchesCurrentAccount: true
            )
        )
        XCTAssertFalse(
            MediaStatePendingIsolationCancellationPolicy.canReturnToOwnerWithoutCleanup(
                archiveOwnerRecordName: "account-b",
                currentAccountRecordName: "account-a",
                isAccountNeutralLocalStateActive: false,
                hasPendingProfiles: true,
                pendingTargetMatchesCurrentAccount: false
            )
        )
        XCTAssertFalse(
            MediaStatePendingIsolationCancellationPolicy.canReturnToOwnerWithoutCleanup(
                archiveOwnerRecordName: nil,
                currentAccountRecordName: "account-a",
                isAccountNeutralLocalStateActive: false,
                hasPendingProfiles: true,
                pendingTargetMatchesCurrentAccount: false
            )
        )
        XCTAssertFalse(
            MediaStatePendingIsolationCancellationPolicy.canReturnToOwnerWithoutCleanup(
                archiveOwnerRecordName: "account-a",
                currentAccountRecordName: "account-a",
                isAccountNeutralLocalStateActive: true,
                hasPendingProfiles: true,
                pendingTargetMatchesCurrentAccount: false
            )
        )
        XCTAssertFalse(
            MediaStatePendingIsolationCancellationPolicy.canReturnToOwnerWithoutCleanup(
                archiveOwnerRecordName: "account-a",
                currentAccountRecordName: "account-a",
                isAccountNeutralLocalStateActive: false,
                hasPendingProfiles: false,
                pendingTargetMatchesCurrentAccount: false
            )
        )
    }

    func testPrivateServicesSettingsDoNotEnterGlobalSyncChannel() {
        XCTAssertTrue(
            MediaStateServicesSettingSyncPolicy.participatesInGlobalSync(
                sharesServices: true
            )
        )
        XCTAssertFalse(
            MediaStateServicesSettingSyncPolicy.participatesInGlobalSync(
                sharesServices: false
            )
        )
    }

    func testSkyStreamMetadataUsesSharedDefaultAndDistinctPrivateProfileRecords() throws {
        let secondProfileID = UUID()
        XCTAssertEqual(
            MediaStateSkyStreamScopePolicy.profileIDs(
                from: [ProfileManager.defaultProfileID, secondProfileID],
                sharesServices: true
            ),
            [ProfileManager.defaultProfileID]
        )
        XCTAssertEqual(
            MediaStateSkyStreamScopePolicy.profileIDs(
                from: [ProfileManager.defaultProfileID, secondProfileID, secondProfileID],
                sharesServices: false
            ),
            [ProfileManager.defaultProfileID, secondProfileID]
        )

        let defaultRecordName = MediaStateSkyStreamScopePolicy.recordName(
            for: ProfileManager.defaultProfileID
        )
        let privateRecordName = MediaStateSkyStreamScopePolicy.recordName(
            for: secondProfileID
        )
        XCTAssertEqual(defaultRecordName, "skyStreamMetadata|safe-cloud-v1")
        XCTAssertNotEqual(defaultRecordName, privateRecordName)
        XCTAssertEqual(MediaStateRecordName.profileID(from: privateRecordName), secondProfileID)

        let payload = try SkyStreamMediaStateDocument.encodeMetadataOnly(
            SkyStreamBackupSnapshot(
                repositories: [],
                plugins: [],
                createdAt: Date(timeIntervalSince1970: 0),
                isSafeCloudSnapshot: true,
                privateCloudConfigurationIsComplete: true
            )
        )
        for recordName in [defaultRecordName, privateRecordName] {
            let envelope = MediaStateEnvelope(
                recordName: recordName,
                kind: .skyStreamMetadata,
                payload: payload,
                modifiedAt: Date(timeIntervalSince1970: 100)
            )
            XCTAssertNil(
                MediaStateEnvelopeValidator.rejectionReason(
                    for: [recordName: envelope],
                    allowsSystemFields: false
                )
            )
        }
    }

    func testRemoteProgressRepairStripsInvalidNestedContextWithoutDroppingProgress() throws {
        let profileID = UUID()
        var episode = EpisodeProgressEntry(showId: 800, seasonNumber: 1, episodeNumber: 2)
        episode.currentTime = 45
        episode.totalDuration = 100
        episode.lastUpdated = Date(timeIntervalSince1970: 100)
        episode.playbackContext = EpisodePlaybackContext(
            localSeasonNumber: 1,
            localEpisodeNumber: 2,
            anilistMediaId: Int.min,
            tmdbSeasonNumber: nil,
            tmdbEpisodeNumber: nil,
            tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: nil,
            animeSeasonEpisodeCount: nil,
            isSpecial: false,
            titleOnlySearch: false
        )
        let name = MediaStateRecordName.make(
            kind: .episodeProgress,
            identifier: episode.id,
            profileID: profileID
        )
        let envelope = MediaStateEnvelope(
            recordName: name,
            kind: .episodeProgress,
            payload: try wireEncode(episode),
            modifiedAt: episode.lastUpdated,
            isCompleted: false
        )

        let result = MediaStateEnvelopeValidator.structurallyValidRemoteRecords([name: envelope])
        XCTAssertTrue(result.droppedRecordNames.isEmpty)
        XCTAssertEqual(result.repairedRecordNames, [name])
        let repaired = try XCTUnwrap(result.records[name])
        let decoded = try wireDecode(EpisodeProgressEntry.self, from: repaired.payload)
        XCTAssertEqual(decoded.currentTime, 45)
        XCTAssertEqual(decoded.totalDuration, 100)
        XCTAssertNil(decoded.playbackContext)
    }

    func testRemoteProgressRejectsExtremeFiniteDuration() throws {
        let profileID = UUID()
        var movie = MovieProgressEntry(id: 801, title: "Extreme")
        movie.currentTime = 1
        movie.totalDuration = .greatestFiniteMagnitude
        movie.lastUpdated = Date(timeIntervalSince1970: 100)
        let name = MediaStateRecordName.make(
            kind: .movieProgress,
            identifier: "801",
            profileID: profileID
        )
        let envelope = MediaStateEnvelope(
            recordName: name,
            kind: .movieProgress,
            payload: try wireEncode(movie),
            modifiedAt: movie.lastUpdated
        )
        let result = MediaStateEnvelopeValidator.structurallyValidRemoteRecords([name: envelope])
        XCTAssertEqual(result.droppedRecordNames, [name])
        XCTAssertTrue(result.records.isEmpty)
    }

    func testCloudPaginationRejectsCyclesOversizedCursorsAndNoncanonicalGraphLinks() {
        var pagination = ExperimentalCloudPaginationGuard()
        XCTAssertTrue(pagination.beginPage(cursor: nil))
        XCTAssertTrue(pagination.recordObjects(100))
        XCTAssertTrue(pagination.beginPage(cursor: "next-1"))
        XCTAssertFalse(pagination.beginPage(cursor: "next-1"))

        var oversized = ExperimentalCloudPaginationGuard()
        XCTAssertTrue(oversized.beginPage(cursor: nil))
        XCTAssertFalse(
            oversized.beginPage(
                cursor: String(repeating: "x", count: ExperimentalCloudPaginationGuard.maximumCursorBytes + 1)
            )
        )

        XCTAssertNotNil(ExperimentalCloudPaginationGuard.exactOneDriveNextURL(
            "https://graph.microsoft.com/v1.0/me/drive/special/approot/children?$skiptoken=abc"
        ))
        XCTAssertNil(ExperimentalCloudPaginationGuard.exactOneDriveNextURL(
            "http://graph.microsoft.com/v1.0/me/drive/special/approot/children?$skiptoken=abc"
        ))
        XCTAssertNil(ExperimentalCloudPaginationGuard.exactOneDriveNextURL(
            "https://graph.microsoft.com.evil.test/v1.0/me/drive/special/approot/children"
        ))
        XCTAssertNil(ExperimentalCloudPaginationGuard.exactOneDriveNextURL(
            "https://graph.microsoft.com/v1.0/me/drive/root/children"
        ))
        XCTAssertNil(ExperimentalCloudPaginationGuard.addingNonnegativeUsage(-1, to: 0))
        XCTAssertNil(ExperimentalCloudPaginationGuard.addingNonnegativeUsage(1, to: .max))
    }

    func testIncompleteRemoteAuthorityAndAllIncompleteCompactionFailClosed() {
        let incomplete = MediaStateRemoteRevision(isComplete: false)
        XCTAssertFalse(incomplete.isComplete)
        XCTAssertFalse(
            ExperimentalCanonicalRemoteAuthorityPolicy.permitsAccountBoundaryUse(incomplete)
        )
        XCTAssertTrue(
            ExperimentalCanonicalRemoteAuthorityPolicy.permitsAccountBoundaryUse(nil)
        )
        XCTAssertFalse(
            ExperimentalGoogleDriveMediaStateCompactionPolicy
                .canReplaceAndReduceCandidateSet(completeCandidateCount: 0)
        )
        XCTAssertFalse(
            ExperimentalGoogleDriveMediaStateCompactionPolicy
                .canReplaceAndReduceCandidateSet(completeCandidateCount: 1)
        )
        XCTAssertTrue(
            ExperimentalGoogleDriveMediaStateCompactionPolicy
                .canReplaceAndReduceCandidateSet(completeCandidateCount: 2)
        )
        XCTAssertFalse(
            ExperimentalGoogleDriveListingCompletenessPolicy.isComplete(
                listedObjectCount: 3,
                recognizedCandidateCount: 0
            ),
            "An all-malformed listing must not be treated as absent authority"
        )
        XCTAssertFalse(
            ExperimentalGoogleDriveListingCompletenessPolicy.isComplete(
                listedObjectCount: 3,
                recognizedCandidateCount: 2
            ),
            "A valid sibling must remain usable salvage without authorizing mutation of an unknown sibling"
        )
        XCTAssertTrue(
            ExperimentalGoogleDriveListingCompletenessPolicy.isComplete(
                listedObjectCount: 2,
                recognizedCandidateCount: 2
            )
        )
        XCTAssertFalse(
            ExperimentalGoogleDriveListingCompletenessPolicy.permitsMutation(isComplete: false)
        )
        XCTAssertTrue(
            ExperimentalGoogleDriveListingCompletenessPolicy.permitsMutation(isComplete: true)
        )
    }

    func testOneDriveETagOAuthExpiryAndGenerationPoliciesAreBounded() {
        XCTAssertNil(ExperimentalOneDriveWritePolicy.usableETag(nil))
        XCTAssertNil(ExperimentalOneDriveWritePolicy.usableETag("  "))
        XCTAssertEqual(ExperimentalOneDriveWritePolicy.usableETag("  etag  "), "etag")
        XCTAssertTrue(ExperimentalOneDriveWritePolicy.isConflictStatus(409))
        XCTAssertTrue(ExperimentalOneDriveWritePolicy.isConflictStatus(412))
        XCTAssertTrue(ExperimentalOneDriveWritePolicy.isConflictStatus(428))
        XCTAssertFalse(ExperimentalOneDriveWritePolicy.isConflictStatus(500))
        XCTAssertFalse(ExperimentalOneDriveBundleCompletenessPolicy.isComplete(
            metadataIsComplete: true,
            contentByteCount: 0
        ))
        XCTAssertFalse(ExperimentalOneDriveBundleCompletenessPolicy.isComplete(
            metadataIsComplete: false,
            contentByteCount: 128
        ))
        XCTAssertTrue(ExperimentalOneDriveBundleCompletenessPolicy.isComplete(
            metadataIsComplete: true,
            contentByteCount: 128
        ))

        XCTAssertEqual(ExperimentalOAuthExpiryPolicy.normalized(.infinity), 3_600)
        XCTAssertEqual(ExperimentalOAuthExpiryPolicy.normalized(-1), 3_600)
        XCTAssertEqual(
            ExperimentalOAuthExpiryPolicy.normalized(
                ExperimentalOAuthExpiryPolicy.maximum + 1
            ),
            3_600
        )
        XCTAssertEqual(ExperimentalOAuthExpiryPolicy.normalized(7_200), 7_200)
        XCTAssertEqual(ExperimentalCloudAccountGenerationPolicy.next(after: .max), .min)
    }

    func testCanonicalServiceSourcesCarryPrivateConfigurationOnlyInPayload() throws {
        let serviceID = UUID()
        let addonID = UUID()
        let serviceSecret = "SERVICE-SETTING-FIXTURE"
        let addonSecret = "STREMIO-CAPABILITY-FIXTURE"
        let service = MediaStateServiceSource(
            id: serviceID,
            url: "https://services.example/anime.json?token=\(serviceSecret)",
            jsonMetadata: #"{"sourceName":"Anime Fixture"}"#,
            jsScript: "const session = '\(serviceSecret)'; const authorization = 'Bearer fixture';",
            isActive: true,
            sortIndex: 1
        )
        let addon = MediaStateStremioAddon(
            id: addonID,
            configuredURL: "https://torrentio.example/realdebrid=\(addonSecret),qualityfilter=all",
            manifestJSON: #"{"id":"torrentio.fixture","name":"Torrentio Fixture"}"#,
            isActive: true,
            sortIndex: 2
        )

        let payload = MediaStateServiceSourcesPayload.sanitized(
            services: [service],
            stremioAddons: [addon],
            nuvioPluginsData: nil
        )
        XCTAssertEqual(payload.services, [service])
        XCTAssertEqual(payload.stremioAddons, [addon])
        XCTAssertTrue(payload.isCanonicalAndCloudSafe)

        let encoded = try XCTUnwrap(MediaStateServiceSourcesPayload.canonicalData(payload))
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains(serviceSecret))
        XCTAssertTrue(text.contains(addonSecret))

        let recordName = MediaStateRecordName.make(
            kind: .setting,
            identifier: MediaStateServiceSourcesPayload.settingKey,
            profileID: ProfileManager.defaultProfileID
        )
        XCTAssertFalse(recordName.contains(serviceSecret))
        XCTAssertFalse(recordName.contains(addonSecret))
    }

    func testCanonicalServiceSourceMergeHonorsCloudUpdatesAndDeletions() {
        let updatedID = UUID()
        let deletedID = UUID()
        let localOnlyID = UUID()
        let current = [
            MediaStateServiceSource(
                id: updatedID,
                url: "https://services.example/updated.json",
                jsonMetadata: "{}",
                jsScript: "const api_key = 'old';",
                isActive: false,
                sortIndex: 0
            ),
            MediaStateServiceSource(
                id: deletedID,
                url: "https://services.example/deleted.json",
                jsonMetadata: "{}",
                jsScript: "deleted",
                isActive: true,
                sortIndex: 1
            ),
            MediaStateServiceSource(
                id: localOnlyID,
                url: "file:///device-only.json",
                jsonMetadata: "{}",
                jsScript: "local",
                isActive: true,
                sortIndex: 2
            )
        ]
        let incoming = MediaStateServiceSource(
            id: updatedID,
            url: "https://services.example/updated.json",
            jsonMetadata: "{}",
            jsScript: "const api_key = 'new-cloud-value';",
            isActive: true,
            sortIndex: 4
        )

        let merged = MediaStateServiceSourcesPayload.mergedServices(
            current: current,
            incoming: [incoming]
        )
        XCTAssertEqual(Set(merged.map(\.id)), Set([updatedID, localOnlyID]))
        XCTAssertEqual(merged.first { $0.id == updatedID }?.jsScript, incoming.jsScript)
        XCTAssertEqual(merged.first { $0.id == updatedID }?.isActive, true)

        let configuredID = UUID()
        let localAddon = MediaStateStremioAddon(
            id: configuredID,
            configuredURL: "https://addon.example/config=old",
            manifestJSON: "{}",
            isActive: false,
            sortIndex: 0
        )
        let cloudAddon = MediaStateStremioAddon(
            id: configuredID,
            configuredURL: "https://addon.example/config=new-private-value",
            manifestJSON: "{}",
            isActive: true,
            sortIndex: 0
        )
        XCTAssertEqual(
            MediaStateServiceSourcesPayload.mergedStremioAddons(
                current: [localAddon],
                incoming: [cloudAddon]
            ),
            [cloudAddon]
        )
        XCTAssertTrue(
            MediaStateServiceSourcesPayload.mergedStremioAddons(
                current: [localAddon],
                incoming: []
            ).isEmpty,
            "A configured private-cloud addon remains representable, so omission has deletion authority"
        )
    }

    func testCanonicalServiceSourcesRejectUnboundedConfiguration() {
        let valid = MediaStateServiceSource(
            id: UUID(),
            url: "https://services.example/valid.json",
            jsonMetadata: "{}",
            jsScript: "valid",
            isActive: true,
            sortIndex: 0
        )
        let oversized = MediaStateServiceSource(
            id: UUID(),
            url: "https://services.example/large.json",
            jsonMetadata: "{}",
            jsScript: String(repeating: "x", count: 512 * 1_024 + 1),
            isActive: true,
            sortIndex: 0
        )
        let payload = MediaStateServiceSourcesPayload.sanitized(
            services: [oversized],
            stremioAddons: [],
            nuvioPluginsData: nil
        )
        XCTAssertTrue(payload.services.isEmpty)
        XCTAssertNil(
            MediaStateServiceSourcesPayload.captured(
                services: [valid, oversized],
                stremioAddons: [],
                nuvioPluginsData: nil
            ),
            "A rejected present row cannot publish a partial replacement"
        )
    }

    private func libraryItem(id: Int, mediaType: String, dateAdded: Date) -> Eclipse.LibraryItem {
        Eclipse.LibraryItem(
            searchResult: TMDBSearchResult(
                id: id,
                mediaType: mediaType,
                title: mediaType == "movie" ? "Movie \(id)" : nil,
                name: mediaType == "tv" ? "Show \(id)" : nil,
                overview: nil,
                posterPath: nil,
                backdropPath: nil,
                releaseDate: nil,
                firstAirDate: nil,
                voteAverage: nil,
                popularity: 0,
                adult: nil,
                genreIds: nil
            ),
            dateAdded: dateAdded
        )
    }
}
