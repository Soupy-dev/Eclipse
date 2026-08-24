import CloudKit
import XCTest
@testable import Eclipse

private enum MediaStateCloudKitTaskContextProbe {
    @TaskLocal static var isInsideDelegateCallback = false
}

final class MediaStateMergeTests: XCTestCase {
    func testLegacySnapshotRestorePreservesExplicitMediaSettingsAndMissingKeys() {
        let suiteName = "MediaStateLegacyRestoreSettingSnapshotTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("fr-FR", forKey: "tmdbLanguage")
        defaults.set("reader-current", forKey: "readerSelectedAppearance")
        let persistentDomain = defaults.persistentDomain(forName: suiteName) ?? [:]
        let authority = MediaStateLegacyRestoreSettingSnapshot(persistentDomain: persistentDomain)

        // Simulate the legacy whole-app snapshot applying stale streaming values
        // and an unrelated reader value.
        defaults.set("ja-JP", forKey: "tmdbLanguage")
        defaults.set("eng", forKey: "defaultSubtitleLanguage")
        defaults.set("reader-restored", forKey: "readerSelectedAppearance")

        authority.restore(to: defaults)

        XCTAssertEqual(defaults.string(forKey: "tmdbLanguage"), "fr-FR")
        XCTAssertNil(defaults.object(forKey: "defaultSubtitleLanguage"))
        XCTAssertEqual(defaults.string(forKey: "readerSelectedAppearance"), "reader-restored")
    }

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testCompletionWinsOverNewerPartialProgress() {
        let completed = envelope(
            payload: Data("complete".utf8),
            modifiedAt: baseDate,
            completed: true
        )
        let newerPartial = envelope(
            payload: Data("partial".utf8),
            modifiedAt: baseDate.addingTimeInterval(60),
            completed: false
        )

        XCTAssertEqual(completed.merged(with: newerPartial), completed)
    }

    func testNewerExplicitResetOverridesCompletion() {
        let completed = envelope(
            payload: Data("complete".utf8),
            modifiedAt: baseDate,
            completed: true
        )
        let reset = envelope(
            payload: Data("reset".utf8),
            modifiedAt: baseDate.addingTimeInterval(60),
            completed: false,
            explicitReset: true
        )

        XCTAssertEqual(completed.merged(with: reset), reset)
    }

    func testOlderResetCannotOverrideNewerCompletion() {
        let reset = envelope(
            payload: Data("reset".utf8),
            modifiedAt: baseDate,
            completed: false,
            explicitReset: true
        )
        let completed = envelope(
            payload: Data("complete".utf8),
            modifiedAt: baseDate.addingTimeInterval(60),
            completed: true
        )

        XCTAssertEqual(completed.merged(with: reset), completed)
    }

    func testTombstoneIsExplicitAndDoesNotChangeAnotherRecord() {
        let first = envelope(recordName: "libraryMembership|movie_1")
        let second = envelope(recordName: "libraryMembership|movie_2")
        let tombstoneDate = baseDate.addingTimeInterval(120)

        let deleted = first.tombstone(at: tombstoneDate)

        XCTAssertTrue(deleted.isDeleted)
        XCTAssertEqual(deleted.deletedAt, tombstoneDate)
        XCTAssertEqual(deleted.payload, Data())
        XCTAssertEqual(deleted.revision, first.revision + 1)
        XCTAssertFalse(second.isDeleted)
        XCTAssertEqual(second.payload, Data("payload".utf8))
    }

    func testNewestCompleteOrderingSnapshotWins() {
        let oldOrder = envelope(
            recordName: "catalogOrder|catalogs",
            kind: .catalogOrder,
            payload: Data("old-order".utf8),
            modifiedAt: baseDate
        )
        let newOrder = envelope(
            recordName: "catalogOrder|catalogs",
            kind: .catalogOrder,
            payload: Data("new-complete-order".utf8),
            modifiedAt: baseDate.addingTimeInterval(1)
        )

        XCTAssertEqual(oldOrder.merged(with: newOrder), newOrder)
    }

    func testEmptyFreshDeviceNeverDeletesOrUploadsFetchedRemoteState() {
        let remote = envelope(
            recordName: "libraryMembership|bookmarks:movie_42",
            kind: .libraryMembership,
            modifiedAt: baseDate
        )

        let result = MediaStateInitialMergePolicy.merge(
            fetchedRecords: [remote.recordName: remote],
            localSnapshot: [:]
        )

        XCTAssertEqual(result.records, [remote.recordName: remote])
        XCTAssertTrue(result.pendingRecordNames.isEmpty)
    }

    func testFirstSyncUploadsOnlyNewLocalRecordsWithoutTouchingRemoteSiblings() {
        let remote = envelope(
            recordName: "libraryMembership|bookmarks:movie_1",
            kind: .libraryMembership,
            modifiedAt: baseDate
        )
        let local = envelope(
            recordName: "libraryMembership|bookmarks:movie_2",
            kind: .libraryMembership,
            modifiedAt: baseDate.addingTimeInterval(1)
        )

        let result = MediaStateInitialMergePolicy.merge(
            fetchedRecords: [remote.recordName: remote],
            localSnapshot: [local.recordName: local]
        )

        XCTAssertEqual(Set(result.records.keys), [remote.recordName, local.recordName])
        XCTAssertEqual(result.pendingRecordNames, [local.recordName])
    }

    func testAccountSwitchDoesNotUploadAnyOutgoingAccountDomainIntoEmptyDatabase() {
        let outgoingRecords = [
            envelope(recordName: "libraryCollection|bookmarks", kind: .libraryCollection),
            envelope(recordName: "libraryMembership|bookmarks:movie_1", kind: .libraryMembership),
            envelope(recordName: "movieProgress|1", kind: .movieProgress),
            envelope(recordName: "rating|1", kind: .rating),
            envelope(recordName: "setting|tmdbLanguage", kind: .setting),
            envelope(recordName: "catalogOrder|home", kind: .catalogOrder)
        ]
        let outgoingSnapshot = Dictionary(
            uniqueKeysWithValues: outgoingRecords.map { ($0.recordName, $0) }
        )

        let result = MediaStateInitialMergePolicy.merge(
            fetchedRecords: [:],
            localSnapshot: outgoingSnapshot,
            localStatePolicy: .isolateIncomingAccount
        )

        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.pendingRecordNames.isEmpty)
    }

    func testAccountSwitchKeepsIncomingRecordVerbatimInsteadOfMergingOutgoingCopy() {
        let incoming = envelope(
            recordName: "setting|tmdbLanguage",
            kind: .setting,
            payload: Data("incoming".utf8),
            modifiedAt: baseDate
        )
        let outgoing = envelope(
            recordName: incoming.recordName,
            kind: incoming.kind,
            payload: Data("outgoing".utf8),
            modifiedAt: baseDate.addingTimeInterval(300)
        )

        let result = MediaStateInitialMergePolicy.merge(
            fetchedRecords: [incoming.recordName: incoming],
            localSnapshot: [outgoing.recordName: outgoing],
            localStatePolicy: .isolateIncomingAccount
        )

        XCTAssertEqual(result.records, [incoming.recordName: incoming])
        XCTAssertTrue(result.pendingRecordNames.isEmpty)
    }

    func testFreshProductDefaultsAreExcludedFromFirstMigration() {
        let defaultBookmarks = envelope(
            recordName: "libraryCollection|bookmarks",
            kind: .libraryCollection
        )
        let registeredSetting = envelope(
            recordName: "setting|tmdbLanguage",
            kind: .setting
        )
        let defaultCatalog = envelope(
            recordName: "catalogOrder|home",
            kind: .catalogOrder
        )
        let snapshot = Dictionary(uniqueKeysWithValues: [
            defaultBookmarks,
            registeredSetting,
            defaultCatalog
        ].map { ($0.recordName, $0) })

        let eligible = MediaStateLocalMigrationPolicy.recordsEligibleForMigration(
            localSnapshot: snapshot,
            defaultRecordNames: Set(snapshot.keys)
        )
        let result = MediaStateInitialMergePolicy.merge(
            fetchedRecords: [:],
            localSnapshot: eligible
        )

        XCTAssertTrue(eligible.isEmpty)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.pendingRecordNames.isEmpty)
    }

    func testMeaningfulExistingLocalDomainsRemainEligibleForFirstMigration() {
        let defaultBookmarks = envelope(
            recordName: "libraryCollection|bookmarks",
            kind: .libraryCollection
        )
        let registeredSetting = envelope(
            recordName: "setting|tmdbLanguage",
            kind: .setting
        )
        let meaningful = [
            envelope(recordName: "libraryCollection|custom", kind: .libraryCollection),
            envelope(recordName: "libraryMembership|custom:movie_1", kind: .libraryMembership),
            envelope(recordName: "movieProgress|1", kind: .movieProgress),
            envelope(recordName: "rating|1", kind: .rating),
            envelope(recordName: "setting|playbackEngine", kind: .setting),
            envelope(recordName: "catalogOrder|home", kind: .catalogOrder)
        ]
        let allRecords = [defaultBookmarks, registeredSetting] + meaningful
        let snapshot = Dictionary(uniqueKeysWithValues: allRecords.map { ($0.recordName, $0) })

        let eligible = MediaStateLocalMigrationPolicy.recordsEligibleForMigration(
            localSnapshot: snapshot,
            defaultRecordNames: [defaultBookmarks.recordName, registeredSetting.recordName]
        )

        XCTAssertEqual(Set(eligible.keys), Set(meaningful.map(\.recordName)))
    }

    func testSuppressedDefaultUploadsOnlyAfterItBecomesMeaningfullyDirty() {
        let catalogName = "catalogOrder|home"

        XCTAssertTrue(
            MediaStateLocalMigrationPolicy.shouldSuppressNewRecord(
                named: catalogName,
                suppressedDefaultRecordNames: [catalogName],
                currentDefaultRecordNames: [catalogName]
            )
        )
        XCTAssertFalse(
            MediaStateLocalMigrationPolicy.shouldSuppressNewRecord(
                named: catalogName,
                suppressedDefaultRecordNames: [catalogName],
                currentDefaultRecordNames: []
            )
        )
    }

    func testRegisteredDefaultDoesNotResurrectRemoteSettingTombstone() throws {
        let suiteName = "MediaStateSettingTombstoneTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.register(defaults: ["tmdbLanguage": "en-US"])
        defaults.set("ja-JP", forKey: "tmdbLanguage")

        let livePayload = try PropertyListSerialization.data(
            fromPropertyList: "fr-FR",
            format: .binary,
            options: 0
        )
        let live = MediaStateEnvelope(
            recordName: "setting|tmdbLanguage",
            kind: .setting,
            payload: livePayload,
            modifiedAt: baseDate,
            settingScope: .shared
        )
        MediaStateSettingRestorePolicy.apply(records: [live], to: defaults)
        XCTAssertEqual(defaults.string(forKey: "tmdbLanguage"), "fr-FR")

        let tombstone = live.tombstone(at: baseDate.addingTimeInterval(1))
        MediaStateSettingRestorePolicy.apply(records: [tombstone], to: defaults)

        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["tmdbLanguage"])
        XCTAssertEqual(defaults.string(forKey: "tmdbLanguage"), "en-US")
        XCTAssertTrue(
            MediaStateLocalMigrationPolicy.shouldSuppressTombstoneResurrection(
                named: tombstone.recordName,
                currentDefaultRecordNames: [tombstone.recordName]
            )
        )
        XCTAssertFalse(
            MediaStateLocalMigrationPolicy.shouldSuppressTombstoneResurrection(
                named: tombstone.recordName,
                currentDefaultRecordNames: []
            )
        )
    }

    func testAllTombstonedCollectionDefinitionsRemainAuthoritative() {
        let collection = envelope(
            recordName: "libraryCollection|custom",
            kind: .libraryCollection
        )
        let tombstone = collection.tombstone(at: baseDate.addingTimeInterval(1))

        XCTAssertTrue(
            MediaStateLibraryRestorePolicy.hasCollectionDefinitionHistory(in: [tombstone])
        )
        XCTAssertFalse(
            MediaStateLibraryRestorePolicy.hasCollectionDefinitionHistory(
                in: [envelope(recordName: "movieProgress|1", kind: .movieProgress)]
            )
        )
    }

    func testTombstonedCatalogOrderRemainsAuthoritative() {
        let catalogOrder = envelope(
            recordName: "catalogOrder|home",
            kind: .catalogOrder
        )
        let tombstone = catalogOrder.tombstone(at: baseDate.addingTimeInterval(1))

        XCTAssertTrue(
            MediaStateCatalogRestorePolicy.hasCatalogOrderHistory(in: [tombstone])
        )
        XCTAssertFalse(
            MediaStateCatalogRestorePolicy.hasCatalogOrderHistory(
                in: [envelope(recordName: "movieProgress|1", kind: .movieProgress)]
            )
        )
        XCTAssertTrue(
            MediaStateLocalMigrationPolicy.shouldSuppressTombstoneResurrection(
                named: tombstone.recordName,
                currentDefaultRecordNames: [tombstone.recordName]
            )
        )
    }

    func testSameAccountSignInMigratesSignedOutEditsButDifferentAccountIsolatesThem() {
        XCTAssertEqual(
            MediaStateAccountTransitionPolicy.signInPolicy(
                lastKnownAccountRecordName: "account-a",
                currentAccountRecordName: "account-a",
                requiresIsolation: false
            ),
            .migrateLocalState
        )
        XCTAssertEqual(
            MediaStateAccountTransitionPolicy.signInPolicy(
                lastKnownAccountRecordName: "account-a",
                currentAccountRecordName: "account-b",
                requiresIsolation: false
            ),
            .isolateIncomingAccount
        )
    }

    func testFirstEverSignInMigratesMeaningfulLocalStateButUnsafePlaybackForcesIsolation() {
        XCTAssertEqual(
            MediaStateAccountTransitionPolicy.signInPolicy(
                lastKnownAccountRecordName: nil,
                currentAccountRecordName: "account-a",
                requiresIsolation: false
            ),
            .migrateLocalState
        )
        XCTAssertEqual(
            MediaStateAccountTransitionPolicy.signInPolicy(
                lastKnownAccountRecordName: "account-a",
                currentAccountRecordName: "account-a",
                requiresIsolation: true
            ),
            .isolateIncomingAccount
        )
    }

    func testLegacyArchiveWithoutAccountOwnerStillDecodes() throws {
        let legacy = Data(#"{"records":{},"lastLocalRecordNames":[]}"#.utf8)

        let archive = try JSONDecoder().decode(MediaStateLocalArchive.self, from: legacy)

        XCTAssertNil(archive.accountOwnerRecordName)
        XCTAssertNil(archive.ubiquityIdentityTokenData)
        XCTAssertTrue(archive.pendingLocalRecordNames.isEmpty)
        XCTAssertFalse(archive.isAccountNeutralLocalStateActive)
    }

    func testLaunchCacheRequiresOwnedMatchingIdentityBeforeOfflineRestore() {
        XCTAssertEqual(
            MediaStateLaunchCachePolicy.action(
                hasAccountOwner: true,
                evidence: .sameAccount
            ),
            .restoreOwnedCache
        )
        XCTAssertEqual(
            MediaStateLaunchCachePolicy.action(
                hasAccountOwner: true,
                evidence: .differentAccountOrSignedOut
            ),
            .awaitCloudKitVerification
        )
        XCTAssertEqual(
            MediaStateLaunchCachePolicy.action(
                hasAccountOwner: true,
                evidence: .unavailable
            ),
            .awaitCloudKitVerification
        )
        XCTAssertEqual(
            MediaStateLaunchCachePolicy.action(
                hasAccountOwner: false,
                evidence: .sameAccount
            ),
            .awaitCloudKitVerification
        )
    }

    func testPlaybackLeaseCounterNotifiesOnlyWhenFinalSessionEnds() {
        var counter = MediaStatePlaybackLeaseCounter()

        XCTAssertFalse(counter.end())
        counter.begin()
        counter.begin()
        XCTAssertEqual(counter.activeSessionCount, 2)
        XCTAssertFalse(counter.end())
        XCTAssertEqual(counter.activeSessionCount, 1)
        XCTAssertTrue(counter.end())
        XCTAssertEqual(counter.activeSessionCount, 0)
        XCTAssertFalse(counter.end())
    }

    func testFinalizedPlaybackCannotBeginOrLeakALease() {
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
        XCTAssertFalse(
            MediaStatePlaybackLeaseLifecyclePolicy.shouldEnd(
                hasBegunLease: true,
                hasEndedLease: true
            )
        )
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

    func testPendingOfflineRecordJournalSurvivesArchiveRoundTrip() throws {
        let record = envelope(recordName: "movieProgress|42", kind: .movieProgress)
        let archive = MediaStateLocalArchive(
            records: [record.recordName: record],
            lastLocalRecordNames: [record.recordName],
            accountOwnerRecordName: "account-a",
            ubiquityIdentityTokenData: Data("identity-a".utf8),
            pendingLocalRecordNames: [record.recordName],
            suppressedLocalRecordPayloadHashes: [
                "skyStreamMetadata|safe-cloud-v1": String(repeating: "a", count: 64)
            ],
            isAccountNeutralLocalStateActive: true
        )

        let restored = try JSONDecoder().decode(
            MediaStateLocalArchive.self,
            from: JSONEncoder().encode(archive)
        )

        XCTAssertEqual(restored.accountOwnerRecordName, "account-a")
        XCTAssertEqual(restored.ubiquityIdentityTokenData, Data("identity-a".utf8))
        XCTAssertEqual(restored.pendingLocalRecordNames, [record.recordName])
        XCTAssertEqual(
            restored.suppressedLocalRecordPayloadHashes,
            ["skyStreamMetadata|safe-cloud-v1": String(repeating: "a", count: 64)]
        )
        XCTAssertTrue(restored.isAccountNeutralLocalStateActive)
    }

    func testSimulatorNeverStartsCloudKitBeforeSignedDeviceEntitlement() {
        XCTAssertFalse(MediaStateSyncBootstrap.hasCloudKitEntitlement)
    }

    func testDeviceLocalStremioCatalogsAreExcludedFromCloudMediaState() {
        let shared = Catalog(id: "trending", name: "Trending", source: .tmdb, isEnabled: true, order: 0)
        let provider = Catalog(
            id: "stremio:device-local",
            name: "Private Addon",
            source: .stremio,
            isEnabled: true,
            order: 1,
            stremioAddonId: UUID()
        )

        XCTAssertTrue(shared.isMediaStateSyncEligible)
        XCTAssertFalse(provider.isMediaStateSyncEligible)
    }

    func testCloudKitPreparationAuthorityRejectsSupersededAndDisabledPasses() {
        XCTAssertTrue(
            MediaStateCloudKitPreparationAuthorityPolicy.mayInstallEngine(
                preparationGeneration: 4,
                currentGeneration: 4,
                isSyncEnabled: true,
                isRecoveryBlocked: false,
                isDeletingRemoteState: false
            )
        )
        XCTAssertFalse(
            MediaStateCloudKitPreparationAuthorityPolicy.mayInstallEngine(
                preparationGeneration: 3,
                currentGeneration: 4,
                isSyncEnabled: true,
                isRecoveryBlocked: false,
                isDeletingRemoteState: false
            )
        )
        XCTAssertFalse(
            MediaStateCloudKitPreparationAuthorityPolicy.mayInstallEngine(
                preparationGeneration: 4,
                currentGeneration: 4,
                isSyncEnabled: false,
                isRecoveryBlocked: false,
                isDeletingRemoteState: false
            )
        )
        XCTAssertFalse(
            MediaStateCloudKitPreparationAuthorityPolicy.mayInstallEngine(
                preparationGeneration: 4,
                currentGeneration: 4,
                isSyncEnabled: true,
                isRecoveryBlocked: true,
                isDeletingRemoteState: false
            )
        )
        XCTAssertFalse(
            MediaStateCloudKitPreparationAuthorityPolicy.mayInstallEngine(
                preparationGeneration: 4,
                currentGeneration: 4,
                isSyncEnabled: true,
                isRecoveryBlocked: false,
                isDeletingRemoteState: true
            )
        )
    }

    func testCloudKitSyncPreferenceRegistersOffByDefault() throws {
        let suiteName = "TVMediaStateCloudKitOptInTests.\(UUID().uuidString)"
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
                initialFetchCompleted: false,
                isTrustedOfflineCacheActive: false,
                isRemoteTransportModeActive: true
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
        XCTAssertFalse(
            MediaStateSameAccountRevalidationPolicy.shouldMigrateLocalState(
                isRevalidationInProgress: true,
                hadPendingIsolation: true,
                isAccountNeutralLocalStateActive: false,
                hasDeliberateLocalCacheReset: false,
                previousAccountRecordName: "account-a",
                currentAccountRecordName: "account-a"
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
        XCTAssertTrue(
            MediaStateDeferredApplyPolicy.shouldFlushPendingCapture(
                isSignedOutIdentityConfirmed: false,
                verifiedOwnerMatchesArchive: false,
                isTrustedOfflineCacheActive: true,
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
                for: .permissionFailure
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

    func testInvalidLocalProgressForcesDomainPreservation() {
        let profileID = UUID()
        let name = MediaStateRecordName.make(
            kind: .episodeProgress,
            identifier: "ep_42_s1_e2",
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
                domainKinds: [.movieProgress, .episodeProgress],
                profileID: UUID()
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

    private func envelope(
        recordName: String = "episodeProgress|tv_42_s1_e2",
        kind: MediaStateKind = .episodeProgress,
        payload: Data = Data("payload".utf8),
        modifiedAt: Date? = nil,
        completed: Bool = false,
        explicitReset: Bool = false
    ) -> MediaStateEnvelope {
        let resolvedModifiedAt = modifiedAt ?? baseDate
        return MediaStateEnvelope(
            recordName: recordName,
            kind: kind,
            payload: payload,
            modifiedAt: resolvedModifiedAt,
            revision: 7,
            isCompleted: completed,
            isExplicitReset: explicitReset,
            resetAt: explicitReset ? resolvedModifiedAt : nil
        )
    }
}
