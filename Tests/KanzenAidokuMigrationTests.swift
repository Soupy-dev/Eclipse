import XCTest
@testable import Eclipse

#if os(iOS)

final class KanzenAidokuMigrationTests: XCTestCase {

    private var suiteNames: [String] = []
    private var capturedStandardKeys: Set<String> = []
    private var restoredStandardValues: [String: Any] = [:]
    private var removedStandardKeys: Set<String> = []

    private let ownerProfileID = UUID(uuidString: "A1D0C0DE-0000-4000-A000-000000000001") ?? UUID()

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        for (key, value) in restoredStandardValues {
            UserDefaults.standard.set(value, forKey: key)
        }
        for key in removedStandardKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        restoredStandardValues.removeAll()
        removedStandardKeys.removeAll()
        capturedStandardKeys.removeAll()
        super.tearDown()
    }

    // MARK: - restore boundary

    func testAnInertReaderRuntimeNeverSinksACloudRestore() {
        XCTAssertTrue(
            ReaderExtensionRestoreReloadPolicy.restoreSurvives(
                ReaderExtensionError.runtimeUnavailable
            ),
            "A quarantined Aidoku store makes the reader runtime inert for the whole session. Failing the restore on it rolls back every other domain and wedges MediaStateAccountBoundaryRecoveryGate, which silently freezes ALL cloud sync forever."
        )

        for error in [
            ReaderExtensionError.sourceNotFound,
            .unsupportedSource,
            .insecureURL,
            .contentTooLarge,
            .persistenceFailed("Blocked source metadata is unreadable")
        ] {
            XCTAssertFalse(
                ReaderExtensionRestoreReloadPolicy.restoreSurvives(error),
                "\(error) means the reload itself went wrong, so the restore must still roll back"
            )
        }

        XCTAssertFalse(
            ReaderExtensionRestoreReloadPolicy.restoreSurvives(
                CocoaError(.fileWriteOutOfSpace)
            ),
            "A non-reader error must never be excused"
        )
    }

    func testAccountBoundaryReloadSurvivesAnInertReaderRuntime() async {
        let boundarySucceeded = await BackupManager.shared
            .reloadSourceManagersAfterAccountBoundary()

        let readerRuntimeIsAvailable = await ReaderExtensionManager.shared.isAvailableForTesting
        guard !readerRuntimeIsAvailable else { return }

        XCTAssertTrue(
            boundarySucceeded,
            "The account boundary clears reader credentials and metadata through stores that never need the runtime, and an inert runtime already publishes an empty source list, so nothing crosses accounts. Failing here instead aborts after the wipe has committed: the sources stay gone and the archive rolls back to the outgoing account, which is the isolation failure this guard was meant to prevent."
        )
    }

    func testAnInertReaderRuntimePublishesNoSources() async {
        let readerRuntimeIsAvailable = await ReaderExtensionManager.shared.isAvailableForTesting
        guard !readerRuntimeIsAvailable else { return }

        let sources = await ReaderExtensionManager.shared.installedSources
        let repositories = await ReaderExtensionManager.shared.repositories

        XCTAssertTrue(
            sources.isEmpty && repositories.isEmpty,
            "Tolerating an inert runtime at the account boundary is only safe because every path that makes the runtime inert empties these lists first."
        )
    }

    // MARK: - detection

    func testCleanInstallDetectsNothingToMigrate() {
        let scan = KanzenAidokuLeftoverScanner.scan(
            legacySources: [],
            libraryData: nil,
            progressData: nil
        )
        XCTAssertEqual(scan.summary, .empty)
        XCTAssertFalse(
            scan.summary.hasLeftoverData,
            "a clean install must never be offered the Aidoku migration prompt"
        )
        XCTAssertTrue(scan.entries.isEmpty)
        XCTAssertFalse(scan.summary.isBlocked)
    }

    func testLibraryWithoutAidokuRoutesDetectsNothingToMigrate() throws {
        let installed = makeInstalledSource()
        let item = MangaLibraryItem.fromReaderExtension(
            sourceID: installed.id,
            itemKey: "/manga/modern",
            title: "Modern Title",
            coverURL: "https://example.test/cover.jpg"
        )
        let libraryData = try encodedLibrary([item])
        var progress = MangaProgress()
        progress.route = .readerExtension(
            source: installed.id,
            itemKey: "/manga/modern",
            legacyStableKey: nil
        )
        progress.readChapterNumbers = ["1"]
        let progressData = try JSONEncoder().encode([item.id: progress])

        let scan = KanzenAidokuLeftoverScanner.scan(
            legacySources: [],
            libraryData: libraryData,
            progressData: progressData
        )
        XCTAssertFalse(scan.summary.hasLeftoverData)
        XCTAssertEqual(scan.summary.libraryEntryCount, 0)
        XCTAssertTrue(scan.entries.isEmpty)
    }

    func testTitleMentioningAidokuIsNotMistakenForLeftoverData() throws {
        let installed = makeInstalledSource()
        let item = MangaLibraryItem.fromReaderExtension(
            sourceID: installed.id,
            itemKey: "/manga/aidoku-the-manga",
            title: "Aidoku: The Manga",
            coverURL: nil
        )
        let libraryData = try encodedLibrary([item])

        let scan = KanzenAidokuLeftoverScanner.scan(
            legacySources: [],
            libraryData: libraryData,
            progressData: nil
        )
        XCTAssertFalse(
            scan.summary.hasLeftoverData,
            "the cheap byte marker may cause a decode, but it must never invent leftover entries"
        )
        XCTAssertTrue(scan.entries.isEmpty)
    }

    func testDetectionCountsEntriesSourcesAndReadingProgress() throws {
        let legacy = try makeLegacySource(id: "en.testsource", name: "Test Source")
        let read = aidokuItem(sourceID: "en.testsource", key: "read-title", title: "Read Title")
        let unread = aidokuItem(sourceID: "en.testsource", key: "unread-title", title: "Unread Title")
        let libraryData = try encodedLibrary([read, unread])

        var readProgress = MangaProgress()
        readProgress.route = .aidoku(sourceId: "en.testsource", mangaKey: "read-title")
        readProgress.readChapterNumbers = ["1", "2"]
        readProgress.lastReadChapter = "2"
        var orphanProgress = MangaProgress()
        orphanProgress.route = .aidoku(sourceId: "en.other", mangaKey: "history-only")
        orphanProgress.lastReadDate = Date()
        let orphanID = MangaContentRoute
            .aidoku(sourceId: "en.other", mangaKey: "history-only")
            .stableNegativeId
        let progressData = try JSONEncoder().encode([
            read.id: readProgress,
            orphanID: orphanProgress
        ])

        let scan = KanzenAidokuLeftoverScanner.scan(
            legacySources: [legacy],
            libraryData: libraryData,
            progressData: progressData
        )
        XCTAssertTrue(scan.summary.hasLeftoverData)
        XCTAssertEqual(scan.summary.legacySourceCount, 1)
        XCTAssertEqual(scan.summary.libraryEntryCount, 2)
        XCTAssertEqual(scan.summary.libraryEntriesWithProgress, 1)
        XCTAssertEqual(scan.summary.progressOnlyEntryCount, 1)
        XCTAssertEqual(scan.summary.referencedSourceIDs, ["en.other", "en.testsource"])
        XCTAssertEqual(scan.entries.count, 3)
    }

    func testUnreadableLibraryStoreBlocksInsteadOfReportingNothing() throws {
        let legacy = try makeLegacySource(id: "en.testsource", name: "Test Source")
        let corrupt = Data("{ this is not a library but it mentions aidoku".utf8)

        let scan = KanzenAidokuLeftoverScanner.scan(
            legacySources: [legacy],
            libraryData: corrupt,
            progressData: nil
        )
        XCTAssertTrue(scan.summary.isBlocked)
        XCTAssertFalse(
            scan.summary.hasLeftoverData,
            "a store that cannot be read must never be presented as a migratable set"
        )
        XCTAssertTrue(scan.entries.isEmpty)
    }

    // MARK: - matching

    func testIdentifierAndHostAgreementProducesAConfidentMatch() throws {
        let legacy = try makeLegacySource(
            id: "en.mangadex",
            name: "MangaDex",
            originHost: "raw.githubusercontent.com"
        )
        let installed = makeInstalledSource(
            name: "MangaDex",
            upstreamID: "2499283573021220255",
            baseURL: "https://mangadex.org"
        )
        let candidates = ReaderExtensionLegacyReconnectManager.candidates(
            legacySources: [legacy],
            installedSources: [installed]
        )
        XCTAssertFalse(candidates.isEmpty)
        let match = KanzenAidokuSourceMatcher.classify(candidates: candidates)
        let confident = try XCTUnwrap(
            match.confidentCandidate,
            "an Aidoku identifier whose provider token matches the installed host must reconnect automatically"
        )
        XCTAssertEqual(confident.installedSource.id, installed.id)
        XCTAssertTrue(confident.hasAuthoritativeEvidence)
    }

    func testCommunityPackageHostAloneIsNotAuthoritative() throws {
        let legacy = try makeLegacySource(
            id: "en.somesource",
            name: "Different Name",
            originHost: "raw.githubusercontent.com"
        )
        let installed = makeInstalledSource(
            name: "Different Name",
            upstreamID: "42",
            baseURL: "https://unrelated.test",
            repositoryURL: "https://raw.githubusercontent.com/example/index.json"
        )
        let scored = KanzenAidokuSourceMatcher.score(
            ReaderExtensionLegacyReconnectCandidate(
                legacySource: legacy,
                installedSource: installed,
                matchesUpstreamSourceID: false,
                matchesOriginHost: true,
                matchesLanguage: true,
                matchesSourceName: true
            )
        )
        XCTAssertFalse(
            scored.evidence.contains(.providerHost),
            "a shared code-hosting host is a packaging coincidence, not provider evidence"
        )
        XCTAssertFalse(scored.hasAuthoritativeEvidence)
    }

    func testNameAndLanguageAloneStayAmbiguous() throws {
        let legacy = try makeLegacySource(id: "en.zzz", name: "Reader One")
        let installed = makeInstalledSource(
            name: "Reader One",
            upstreamID: "7",
            baseURL: "https://unrelated-provider.test"
        )
        let candidates = ReaderExtensionLegacyReconnectManager.candidates(
            legacySources: [legacy],
            installedSources: [installed]
        )
        XCTAssertFalse(candidates.isEmpty)
        let match = KanzenAidokuSourceMatcher.classify(candidates: candidates)
        XCTAssertNil(match.confidentCandidate)
        XCTAssertTrue(match.hasCandidate)
    }

    func testTiedAuthoritativeCandidatesStayAmbiguous() throws {
        let legacy = try makeLegacySource(id: "en.weebcentral", name: "WeebCentral")
        let first = makeInstalledSource(
            name: "WeebCentral",
            upstreamID: "1",
            baseURL: "https://weebcentral.com",
            repositoryURL: "https://one.test/index.json"
        )
        let second = makeInstalledSource(
            name: "WeebCentral",
            upstreamID: "2",
            baseURL: "https://weebcentral.com",
            repositoryURL: "https://two.test/index.json"
        )
        let candidates = ReaderExtensionLegacyReconnectManager.candidates(
            legacySources: [legacy],
            installedSources: [first, second]
        )
        let match = KanzenAidokuSourceMatcher.classify(candidates: candidates)
        XCTAssertNil(
            match.confidentCandidate,
            "two equally strong replacements must be resolved by the user, never guessed"
        )
        XCTAssertEqual(match.reviewCandidates.count, 2)
    }

    func testNovelExtensionIsNeverPickedAutomaticallyForALegacyMangaSource() throws {
        let legacy = try makeLegacySource(id: "en.weebcentral", name: "WeebCentral")
        let novel = makeInstalledSource(
            name: "WeebCentral",
            upstreamID: "3",
            baseURL: "https://weebcentral.com",
            mediaType: .novel
        )
        let candidates = ReaderExtensionLegacyReconnectManager.candidates(
            legacySources: [legacy],
            installedSources: [novel]
        )
        let match = KanzenAidokuSourceMatcher.classify(candidates: candidates)
        XCTAssertNil(
            match.confidentCandidate,
            "reconnecting a manga library to a novel extension silently flips isNovel on downloads"
        )
    }

    // MARK: - item identity

    func testItemIdentityGeneralizesBeyondMangaDex() {
        let mangadex = makeInstalledSource(name: "MangaDex", baseURL: "https://mangadex.org")
        let uuid = "3f4a5f10-1111-4222-8333-444455556666"
        XCTAssertTrue(
            KanzenAidokuItemIdentity.refersToSameIdentity(
                "https://mangadex.org/title/\(uuid)/one-piece",
                "/manga/\(uuid)",
                installedSource: mangadex
            )
        )

        let weebcentral = makeInstalledSource(name: "WeebCentral", baseURL: "https://weebcentral.com")
        let ulid = "01J0Q1RSTVWXYZ0123456789AB"
        XCTAssertTrue(
            KanzenAidokuItemIdentity.refersToSameIdentity(
                "https://weebcentral.com/series/\(ulid)",
                ulid,
                installedSource: weebcentral
            )
        )
        XCTAssertTrue(
            KanzenAidokuItemIdentity.refersToSameIdentity(
                "https://weebcentral.com/series/\(ulid)/",
                "/series/\(ulid)",
                installedSource: weebcentral
            )
        )
        XCTAssertFalse(
            KanzenAidokuItemIdentity.refersToSameIdentity(
                "https://weebcentral.com/series/\(ulid)",
                "https://weebcentral.com/series/01J0Q1RSTVWXYZ0123456789ZZ",
                installedSource: weebcentral
            )
        )
    }

    func testCandidateKeysStayBoundedAndDeduplicated() {
        let source = makeInstalledSource(name: "MangaDex", baseURL: "https://mangadex.org")
        let keys = KanzenAidokuItemIdentity.candidateKeys(
            for: "https://mangadex.org/title/3f4a5f10-1111-4222-8333-444455556666",
            installedSource: source
        )
        XCTAssertLessThanOrEqual(keys.count, KanzenAidokuItemIdentity.maximumCandidateKeys)
        XCTAssertEqual(keys.first, "https://mangadex.org/title/3f4a5f10-1111-4222-8333-444455556666")
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    // MARK: - marking and idempotency

    @MainActor
    func testUnmatchedEntryIsMarkedButKeepsItsTitleAndProgress() async throws {
        let fixture = try makeStubFixture()
        let coordinator = KanzenAidokuMigrationCoordinator(environment: fixture.environment)

        let outcome = await coordinator.apply(choices: [:])

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertTrue(outcome.reconnectedSourceIDs.isEmpty)
        XCTAssertEqual(outcome.markedEntryCount, 2)

        let mark = try XCTUnwrap(
            coordinator.mark(forLegacyStableKey: "aidoku:en.testsource:read-title")
        )
        XCTAssertEqual(mark.legacySourceID, "en.testsource")
        XCTAssertEqual(mark.title, "Read Title")
        XCTAssertEqual(mark.legacySourceName, "Test Source")
        XCTAssertFalse(mark.hasReconnectCandidate)

        let reloaded = MangaLibraryManager.persistedCollections(from: fixture.libraryData)
        XCTAssertFalse(reloaded.unreadable)
        let preserved = reloaded.collections.flatMap(\.items)
        XCTAssertEqual(
            preserved.map(\.title).sorted(),
            ["Read Title", "Unread Title"],
            "marking an entry unavailable must leave the saved title in place"
        )
        XCTAssertEqual(
            preserved.compactMap(\.route),
            fixture.items.compactMap(\.route),
            "an unavailable entry keeps its original route so a later reconnect can still find it"
        )
        XCTAssertEqual(preserved.map(\.coverURL), fixture.items.map(\.coverURL))

        let progress = try JSONDecoder().decode(
            [Int: MangaProgress].self,
            from: try XCTUnwrap(fixture.progressData)
        )
        XCTAssertEqual(progress[fixture.items[0].id]?.readChapterNumbers, ["1", "2"])
    }

    @MainActor
    func testMigrationIsIdempotentAcrossTwoRuns() async throws {
        let fixture = try makeStubFixture()
        let coordinator = KanzenAidokuMigrationCoordinator(environment: fixture.environment)

        let first = await coordinator.apply(choices: [:])
        let marksAfterFirstRun = coordinator.unavailableMarks
        let summaryAfterFirstRun = coordinator.summary

        let second = await coordinator.apply(choices: [:])

        XCTAssertEqual(first.status, second.status)
        XCTAssertEqual(second.markedEntryCount, 0, "a second run must not re-mark the same entries")
        XCTAssertEqual(second.clearedMarkCount, 0)
        XCTAssertEqual(
            coordinator.unavailableMarks,
            marksAfterFirstRun,
            "re-running the migration must not restamp markedAt or otherwise churn stored marks"
        )
        XCTAssertEqual(coordinator.summary, summaryAfterFirstRun)

        let persisted = KanzenAidokuUnavailableMarkStore.load(
            from: fixture.markStore,
            profileID: ownerProfileID
        )
        XCTAssertEqual(persisted, marksAfterFirstRun)
    }

    @MainActor
    func testInstallingAMatchingExtensionMakesMarkedEntriesReconnectable() async throws {
        let fixture = try makeStubFixture()
        let coordinator = KanzenAidokuMigrationCoordinator(environment: fixture.environment)
        _ = await coordinator.apply(choices: [:])
        XCTAssertEqual(coordinator.plan.unmatchedSources.count, 1)
        let originalMark = try XCTUnwrap(
            coordinator.mark(forLegacyStableKey: "aidoku:en.testsource:read-title")
        )
        XCTAssertFalse(originalMark.hasReconnectCandidate)

        fixture.installedSourcesBox.value = [
            makeInstalledSource(
                name: "Test Source",
                upstreamID: "99",
                baseURL: "https://testsource.test"
            )
        ]

        let outcome = await coordinator.reevaluateAfterInstalledSourcesChanged(
            automaticallyReconnect: false
        )

        XCTAssertEqual(outcome.status, .completed)
        let sourcePlan = try XCTUnwrap(coordinator.plan.sources.first)
        XCTAssertNotNil(
            sourcePlan.match.confidentCandidate,
            "a newly installed extension must make previously unmatched entries reconnectable"
        )
        let mark = try XCTUnwrap(
            coordinator.mark(forLegacyStableKey: "aidoku:en.testsource:read-title")
        )
        XCTAssertTrue(mark.hasReconnectCandidate)
        XCTAssertEqual(
            mark.markedAt,
            originalMark.markedAt,
            "re-evaluating must not restamp when an entry was already marked"
        )
        XCTAssertEqual(mark.title, originalMark.title)
    }

    @MainActor
    func testKidsModeFailsClosed() async throws {
        var fixture = try makeStubFixture()
        fixture.environment.isKidsModeActive = { true }
        let coordinator = KanzenAidokuMigrationCoordinator(environment: fixture.environment)

        let summary = await coordinator.detect()
        XCTAssertEqual(summary, .empty)
        XCTAssertFalse(coordinator.shouldOfferMigrationPrompt)

        let outcome = await coordinator.apply(choices: [:])
        XCTAssertEqual(outcome.status, .blockedByKidsMode)
        XCTAssertTrue(coordinator.unavailableMarks.isEmpty)
        XCTAssertNil(
            fixture.markStore.data(
                forKey: KanzenAidokuUnavailableMarkStore.storageKey(for: ownerProfileID)
            ),
            "a kids profile must not administer or annotate legacy Reader data"
        )
    }

    @MainActor
    func testPromptIsOfferedOnceAndStaysReachableAfterDismissal() async throws {
        let fixture = try makeStubFixture()
        let coordinator = KanzenAidokuMigrationCoordinator(environment: fixture.environment)

        _ = await coordinator.detect()
        XCTAssertTrue(coordinator.shouldOfferMigrationPrompt)

        coordinator.dismissMigrationPrompt()
        XCTAssertFalse(coordinator.shouldOfferMigrationPrompt)
        XCTAssertTrue(coordinator.canOpenMigrationFromSettings)

        coordinator.restoreMigrationPrompt()
        XCTAssertTrue(coordinator.shouldOfferMigrationPrompt)
    }

    // MARK: - stored schema

    func testPreMigrationLibraryDataStillDecodes() throws {
        let legacyJSON = """
        [
          {
            "id": "1B4B4E2E-0000-4000-A000-0000000000AA",
            "name": "Bookmarks",
            "description": "Your bookmarked manga",
            "items": [
              {
                "aniListId": -12345,
                "title": "Saved Before The Migration",
                "coverURL": "https://example.test/cover.jpg",
                "format": "MANGA",
                "totalChapters": 12,
                "dateAdded": 700000000,
                "route": {
                  "kind": "aidoku",
                  "sourceId": "en.testsource",
                  "mangaKey": "saved-title"
                }
              }
            ]
          }
        ]
        """
        let data = Data(legacyJSON.utf8)
        let decoded = MangaLibraryManager.persistedCollections(from: data)
        XCTAssertFalse(
            decoded.unreadable,
            "library data written before the migration engine existed must still decode"
        )
        let item = try XCTUnwrap(decoded.collections.first?.items.first)
        XCTAssertEqual(item.title, "Saved Before The Migration")
        XCTAssertEqual(item.id, -12345)
        XCTAssertEqual(item.route, .aidoku(sourceId: "en.testsource", mangaKey: "saved-title"))
        XCTAssertTrue(MangaLibraryManager.persistedCollectionsSchemaIsValid(data))

        let scan = KanzenAidokuLeftoverScanner.scan(
            legacySources: [],
            libraryData: data,
            progressData: nil
        )
        XCTAssertEqual(scan.summary.libraryEntryCount, 1)
        XCTAssertEqual(scan.entries.first?.legacyStableKey, "aidoku:en.testsource:saved-title")
    }

    func testUnavailableMarkDecodesRecordsWrittenWithoutTheOptionalFields() throws {
        let json = """
        {
          "aidoku:en.testsource:saved-title": {
            "legacyStableKey": "aidoku:en.testsource:saved-title",
            "legacySourceID": "en.testsource"
          }
        }
        """
        let decoded = try JSONDecoder().decode(
            [String: KanzenAidokuUnavailableMark].self,
            from: Data(json.utf8)
        )
        let mark = try XCTUnwrap(decoded["aidoku:en.testsource:saved-title"])
        XCTAssertEqual(mark.legacySourceID, "en.testsource")
        XCTAssertNil(mark.title)
        XCTAssertFalse(mark.hasReconnectCandidate)
        XCTAssertNil(mark.libraryItemID)

        let roundTripped = try JSONDecoder().decode(
            KanzenAidokuUnavailableMark.self,
            from: try JSONEncoder().encode(mark)
        )
        XCTAssertEqual(roundTripped, mark)
    }

    func testUnavailableMarkRejectsAForeignStableKey() {
        let json = """
        { "legacyStableKey": "readerExtension:abc:def", "legacySourceID": "en.testsource" }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(KanzenAidokuUnavailableMark.self, from: Data(json.utf8))
        )
    }

    // MARK: - end to end reconnect

    @MainActor
    func testConfidentMatchReconnectsAndRepointsTheLibraryEntry() async throws {
        try XCTSkipUnless(
            ProfileManager.shared.rosterStoreIsReadable,
            "the reconnect transaction refuses to run against an unreadable profile roster"
        )
        try XCTSkipIf(
            ProfileManager.shared.isKidsModeActive,
            "a kids profile administers no Reader sources"
        )

        let owner = ProfileManager.shared.activeProfileID
        let libraryKey = MangaLibraryManager.storageKey(for: owner)
        let progressKey = MangaReadingProgressManager.storageKey(for: owner)
        let originalLibrary = UserDefaults.standard.data(forKey: libraryKey)
        let originalProgress = UserDefaults.standard.data(forKey: progressKey)
        captureStandardValue(forKey: libraryKey)
        captureStandardValue(forKey: progressKey)
        defer {
            MangaLibraryManager.shared.applyRestoredCollections(
                MangaLibraryManager.persistedCollections(from: originalLibrary).collections,
                forProfile: owner
            )
            let restoredProgress = originalProgress.flatMap {
                try? JSONDecoder().decode([Int: MangaProgress].self, from: $0)
            } ?? [:]
            MangaReadingProgressManager.shared.applyRestoredProgress(
                restoredProgress,
                forProfile: owner
            )
        }

        let legacySourceID = "en.eclipsemigrationfixture"
        let legacyItemKey = "/series/01J0Q1RSTVWXYZ0123456789AB"
        let item = aidokuItem(
            sourceID: legacySourceID,
            key: legacyItemKey,
            title: "Reconnected Fixture"
        )
        var progress = MangaProgress()
        progress.route = .aidoku(sourceId: legacySourceID, mangaKey: legacyItemKey)
        progress.readChapterNumbers = ["1", "2", "3"]
        progress.lastReadChapter = "3"
        progress.title = "Reconnected Fixture"

        UserDefaults.standard.set(try encodedLibrary([item]), forKey: libraryKey)
        UserDefaults.standard.set(
            try JSONEncoder().encode([item.id: progress]),
            forKey: progressKey
        )

        let servicesStore = makeStore(named: "services")
        let legacySource = try makeLegacySource(
            id: legacySourceID,
            name: "Eclipse Migration Fixture"
        )
        servicesStore.set(
            try JSONEncoder().encode([legacySource]),
            forKey: BackupReaderExtensionState.legacyAidokuSourcesStorageKey
        )
        let installed = makeInstalledSource(
            name: "Eclipse Migration Fixture",
            upstreamID: "31337",
            baseURL: "https://eclipsemigrationfixture.test"
        )

        var environment = KanzenAidokuMigrationEnvironment.live
        environment.servicesStore = { servicesStore }
        let markStore = makeStore(named: "marks")
        environment.markStore = { markStore }
        environment.installedSources = { [installed] }
        environment.verifyItemKey = { legacyItem, _ in .resolved(legacyItem.legacyItemKey) }

        let coordinator = KanzenAidokuMigrationCoordinator(environment: environment)
        let detected = await coordinator.detect()
        XCTAssertTrue(detected.hasLeftoverData)
        XCTAssertNotNil(
            coordinator.plan.sources.first?.match.confidentCandidate,
            "the fixture identifier, host and language all agree"
        )

        let outcome = await coordinator.apply(choices: [:])

        XCTAssertEqual(outcome.failures.map(\.message), [])
        XCTAssertEqual(outcome.reconnectedSourceIDs, [legacySourceID])
        XCTAssertEqual(outcome.status, .completed)

        let rewritten = MangaLibraryManager.persistedCollections(
            from: UserDefaults.standard.data(forKey: libraryKey)
        )
        XCTAssertFalse(rewritten.unreadable)
        let reconnected = try XCTUnwrap(
            rewritten.collections.flatMap(\.items).first { $0.title == "Reconnected Fixture" },
            "the saved title must survive the reconnect"
        )
        XCTAssertEqual(
            reconnected.route,
            .readerExtension(
                source: installed.id,
                itemKey: legacyItemKey,
                legacyStableKey: "aidoku:\(legacySourceID):\(legacyItemKey)"
            )
        )
        XCTAssertEqual(
            reconnected.id,
            item.id,
            "the preserved legacy stable key is what keeps library membership and progress joined"
        )

        let rewrittenProgress = try JSONDecoder().decode(
            [Int: MangaProgress].self,
            from: try XCTUnwrap(UserDefaults.standard.data(forKey: progressKey))
        )
        let preserved = try XCTUnwrap(rewrittenProgress[item.id])
        XCTAssertEqual(preserved.readChapterNumbers, ["1", "2", "3"])
        XCTAssertEqual(preserved.lastReadChapter, "3")
        XCTAssertEqual(preserved.route?.readerExtensionSourceID, installed.id)

        XCTAssertTrue(
            ReaderExtensionAidokuMigration.legacySources(in: servicesStore).isEmpty,
            "a reconnected legacy source must stop being offered"
        )
        XCTAssertTrue(coordinator.unavailableMarks.isEmpty)
        XCTAssertFalse(coordinator.summary.hasLeftoverData)
    }

    // MARK: - resumable verification

    private final class VerifierLog {
        var asked: [String] = []
        var answers: [String: ReaderExtensionLegacyItemVerification] = [:]

        func answer(for key: String) -> ReaderExtensionLegacyItemVerification {
            asked.append(key)
            return answers[key] ?? .resolved(key)
        }
    }

    @MainActor
    private func makeResumableFixture(
        itemKeys: [String],
        label: String
    ) throws -> (
        environment: KanzenAidokuMigrationEnvironment,
        servicesStore: UserDefaults,
        installed: ReaderExtensionInstalledSource,
        legacySourceID: String,
        items: [MangaLibraryItem],
        libraryKey: String,
        owner: UUID
    ) {
        let owner = ProfileManager.shared.activeProfileID
        let libraryKey = MangaLibraryManager.storageKey(for: owner)
        let legacySourceID = "en.eclipsemigrationfixture"
        let items = itemKeys.map {
            aidokuItem(sourceID: legacySourceID, key: $0, title: "Fixture \($0)")
        }
        UserDefaults.standard.set(try encodedLibrary(items), forKey: libraryKey)

        let servicesStore = makeStore(named: "services-\(label)")
        servicesStore.set(
            try JSONEncoder().encode([
                try makeLegacySource(id: legacySourceID, name: "Eclipse Migration Fixture")
            ]),
            forKey: BackupReaderExtensionState.legacyAidokuSourcesStorageKey
        )
        let installed = makeInstalledSource(
            name: "Eclipse Migration Fixture",
            upstreamID: "31337",
            baseURL: "https://eclipsemigrationfixture.test"
        )

        let markStore = makeStore(named: "marks-\(label)")
        var environment = KanzenAidokuMigrationEnvironment.live
        environment.servicesStore = { servicesStore }
        environment.markStore = { markStore }
        environment.installedSources = { [installed] }

        return (environment, servicesStore, installed, legacySourceID, items, libraryKey, owner)
    }

    @MainActor
    private func prepareStandardStoresForReconnect(owner: UUID) {
        let libraryKey = MangaLibraryManager.storageKey(for: owner)
        let progressKey = MangaReadingProgressManager.storageKey(for: owner)
        let ledgerKey = ReaderExtensionReconnectLedgerStore.storageKey(for: owner)
        let originalLibrary = UserDefaults.standard.data(forKey: libraryKey)
        let originalProgress = UserDefaults.standard.data(forKey: progressKey)
        captureStandardValue(forKey: libraryKey)
        captureStandardValue(forKey: progressKey)
        captureStandardValue(forKey: ledgerKey)
        UserDefaults.standard.removeObject(forKey: ledgerKey)
        addTeardownBlock { @MainActor in
            MangaLibraryManager.shared.applyRestoredCollections(
                MangaLibraryManager.persistedCollections(from: originalLibrary).collections,
                forProfile: owner
            )
            let restoredProgress = originalProgress.flatMap {
                try? JSONDecoder().decode([Int: MangaProgress].self, from: $0)
            } ?? [:]
            MangaReadingProgressManager.shared.applyRestoredProgress(
                restoredProgress,
                forProfile: owner
            )
        }
    }

    @MainActor
    func testASourceThatStopsAnsweringKeepsEveryTitleItAlreadyMatched() async throws {
        try XCTSkipUnless(ProfileManager.shared.rosterStoreIsReadable)
        try XCTSkipIf(ProfileManager.shared.isKidsModeActive)

        let keys = ["/series/aaa", "/series/bbb", "/series/ccc"]
        let fixture = try makeResumableFixture(itemKeys: keys, label: "interrupted")
        prepareStandardStoresForReconnect(owner: fixture.owner)

        let log = VerifierLog()
        log.answers["/series/bbb"] = .interrupted
        var environment = fixture.environment
        environment.verifyItemKey = { legacyItem, _ in log.answer(for: legacyItem.legacyItemKey) }

        let coordinator = KanzenAidokuMigrationCoordinator(environment: environment)
        _ = await coordinator.detect()
        let first = await coordinator.apply(choices: [:])

        XCTAssertTrue(first.reconnectedSourceIDs.isEmpty, "an interrupted sweep must commit nothing")
        XCTAssertTrue(first.hasResumableFailure)
        XCTAssertEqual(
            log.asked,
            ["/series/aaa", "/series/bbb", "/series/ccc"],
            "one title the source will not answer for must not hide every title sorted after it"
        )

        let stillLegacy = MangaLibraryManager.persistedCollections(
            from: UserDefaults.standard.data(forKey: fixture.libraryKey)
        )
        XCTAssertFalse(stillLegacy.unreadable)
        XCTAssertTrue(
            stillLegacy.collections.flatMap(\.items).allSatisfy {
                if case .aidoku = $0.route { return true }
                return false
            },
            "nothing may be rewritten while a title is still unverified"
        )

        let ledger = ReaderExtensionReconnectLedgerStore.load(
            from: .standard,
            profileID: fixture.owner
        )
        let record = ReaderExtensionReconnectLedgerStore.record(
            in: ledger,
            legacySourceID: fixture.legacySourceID,
            installedSourceID: fixture.installed.id
        )
        XCTAssertEqual(
            record.resolved,
            ["/series/aaa": "/series/aaa", "/series/ccc": "/series/ccc"],
            "every title that already matched has to survive the interruption"
        )
        XCTAssertEqual(
            record.interruptions["/series/bbb"],
            1,
            "the source answered for other titles, so this one's failure counts against it"
        )

        log.asked = []
        log.answers = [:]
        let second = await coordinator.apply(choices: [:])

        XCTAssertEqual(second.failures.map(\.message), [])
        XCTAssertEqual(second.reconnectedSourceIDs, [fixture.legacySourceID])
        XCTAssertEqual(
            log.asked,
            ["/series/bbb"],
            "the retry asks only about what is still unknown, never re-running the whole sweep"
        )
        XCTAssertEqual(second.reconnectedItemCount, 3)
        XCTAssertEqual(second.retainedItemCount, 0)
    }

    @MainActor
    func testTitlesTheNewSourceDoesNotCarryStopBlockingEveryOtherTitle() async throws {
        try XCTSkipUnless(ProfileManager.shared.rosterStoreIsReadable)
        try XCTSkipIf(ProfileManager.shared.isKidsModeActive)

        let keys = ["/series/aaa", "/series/bbb"]
        let fixture = try makeResumableFixture(itemKeys: keys, label: "absent")
        prepareStandardStoresForReconnect(owner: fixture.owner)

        let log = VerifierLog()
        log.answers["/series/bbb"] = .absent
        var environment = fixture.environment
        environment.verifyItemKey = { legacyItem, _ in log.answer(for: legacyItem.legacyItemKey) }

        let coordinator = KanzenAidokuMigrationCoordinator(environment: environment)
        _ = await coordinator.detect()
        let outcome = await coordinator.apply(choices: [:])

        XCTAssertEqual(outcome.failures.map(\.message), [])
        XCTAssertEqual(outcome.reconnectedSourceIDs, [fixture.legacySourceID])
        XCTAssertEqual(outcome.reconnectedItemCount, 1)
        XCTAssertEqual(outcome.retainedItemCount, 1)

        let rewritten = MangaLibraryManager.persistedCollections(
            from: UserDefaults.standard.data(forKey: fixture.libraryKey)
        )
        XCTAssertFalse(rewritten.unreadable)
        let rows = rewritten.collections.flatMap(\.items)
        let migrated = try XCTUnwrap(rows.first { $0.title == "Fixture /series/aaa" })
        XCTAssertEqual(migrated.route?.readerExtensionSourceID, fixture.installed.id)
        let kept = try XCTUnwrap(rows.first { $0.title == "Fixture /series/bbb" })
        guard case .aidoku(let sourceId, let mangaKey)? = kept.route else {
            return XCTFail("a title the new source does not carry keeps its original route")
        }
        XCTAssertEqual(sourceId, fixture.legacySourceID)
        XCTAssertEqual(mangaKey, "/series/bbb")

        XCTAssertFalse(
            ReaderExtensionAidokuMigration.legacySources(in: fixture.servicesStore).isEmpty,
            "the legacy source has to stay listed while one of its routes survives, or the retry has nothing to match"
        )
        XCTAssertEqual(
            coordinator.unavailableMarks.keys
                .filter { $0.hasPrefix("aidoku:\(fixture.legacySourceID):") }
                .sorted(),
            ["aidoku:\(fixture.legacySourceID):/series/bbb"],
            "Only the title the new source does not carry may be marked. Scoped to the fixture's own source because the marks store is global: a device whose reader sources were cleared by an account boundary legitimately carries marks for its real library."
        )
    }

    @MainActor
    func testASourceCarryingNoneOfTheSavedTitlesChangesNothing() async throws {
        try XCTSkipUnless(ProfileManager.shared.rosterStoreIsReadable)
        try XCTSkipIf(ProfileManager.shared.isKidsModeActive)

        let keys = ["/series/aaa", "/series/bbb"]
        let fixture = try makeResumableFixture(itemKeys: keys, label: "all-absent")
        prepareStandardStoresForReconnect(owner: fixture.owner)

        var environment = fixture.environment
        environment.verifyItemKey = { _, _ in .absent }

        let coordinator = KanzenAidokuMigrationCoordinator(environment: environment)
        _ = await coordinator.detect()
        let outcome = await coordinator.apply(choices: [:])

        XCTAssertTrue(outcome.reconnectedSourceIDs.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertFalse(
            outcome.failures[0].isResumable,
            "a source that answered about every title is not something retrying fixes"
        )
        let untouched = MangaLibraryManager.persistedCollections(
            from: UserDefaults.standard.data(forKey: fixture.libraryKey)
        )
        XCTAssertTrue(
            untouched.collections.flatMap(\.items).allSatisfy {
                if case .aidoku = $0.route { return true }
                return false
            }
        )
        XCTAssertFalse(
            ReaderExtensionAidokuMigration.legacySources(in: fixture.servicesStore).isEmpty
        )
    }

    @MainActor
    func testARepeatRunOverAPartiallyMigratedSourceIsANoOpNotAFailure() async throws {
        try XCTSkipUnless(ProfileManager.shared.rosterStoreIsReadable)
        try XCTSkipIf(ProfileManager.shared.isKidsModeActive)

        let keys = ["/series/aaa", "/series/bbb"]
        let fixture = try makeResumableFixture(itemKeys: keys, label: "repeat")
        prepareStandardStoresForReconnect(owner: fixture.owner)

        let log = VerifierLog()
        log.answers["/series/bbb"] = .absent
        var environment = fixture.environment
        environment.verifyItemKey = { legacyItem, _ in log.answer(for: legacyItem.legacyItemKey) }

        let coordinator = KanzenAidokuMigrationCoordinator(environment: environment)
        _ = await coordinator.detect()
        _ = await coordinator.apply(choices: [:])

        let libraryBefore = UserDefaults.standard.data(forKey: fixture.libraryKey)
        log.asked = []
        let second = await coordinator.apply(choices: [:])

        XCTAssertEqual(
            second.failures.map(\.message),
            [],
            "a source that finished what it could must not be reported as broken every time"
        )
        XCTAssertEqual(second.reconnectedSourceIDs, [fixture.legacySourceID])
        XCTAssertEqual(second.reconnectedItemCount, 0)
        XCTAssertEqual(second.retainedItemCount, 1)
        XCTAssertTrue(log.asked.isEmpty, "the absent verdict is still inside its recheck window")
        XCTAssertEqual(
            UserDefaults.standard.data(forKey: fixture.libraryKey),
            libraryBefore,
            "a no-op run must not touch a single byte"
        )
    }

    @MainActor
    func testAConfirmedAbsentTitleStopsOfferingAnImpossibleReconnect() async throws {
        try XCTSkipUnless(ProfileManager.shared.rosterStoreIsReadable)
        try XCTSkipIf(ProfileManager.shared.isKidsModeActive)

        let fixture = try makeResumableFixture(
            itemKeys: ["/series/aaa", "/series/bbb"],
            label: "badge"
        )
        prepareStandardStoresForReconnect(owner: fixture.owner)

        let log = VerifierLog()
        log.answers["/series/bbb"] = .absent
        var environment = fixture.environment
        environment.verifyItemKey = { legacyItem, _ in log.answer(for: legacyItem.legacyItemKey) }

        let coordinator = KanzenAidokuMigrationCoordinator(environment: environment)
        _ = await coordinator.detect()
        _ = await coordinator.apply(choices: [:])

        let mark = try XCTUnwrap(
            coordinator.mark(forLegacyStableKey: "aidoku:\(fixture.legacySourceID):/series/bbb")
        )
        XCTAssertTrue(mark.confirmedAbsentOnReplacement)

        let roundTripped = try JSONDecoder().decode(
            KanzenAidokuUnavailableMark.self,
            from: try JSONEncoder().encode(mark)
        )
        XCTAssertEqual(roundTripped, mark, "the badge state has to survive a reload")
    }

    func testAMarkPredatingTheConfirmedAbsentFlagDecodesAsNotYetAttempted() throws {
        let json = """
        {
          "legacyStableKey": "aidoku:en.testsource:saved-title",
          "legacySourceID": "en.testsource"
        }
        """
        let mark = try JSONDecoder().decode(
            KanzenAidokuUnavailableMark.self,
            from: Data(json.utf8)
        )
        XCTAssertFalse(
            mark.confirmedAbsentOnReplacement,
            "an older mark carries no evidence that any source was ever asked"
        )
    }

    func testATitlePageThatEchoesTheKeyBackIsNotEvidenceTheTitleExists() {
        XCTAssertFalse(
            KanzenAidokuItemVerification.carriesARealTitle("", for: "/series/one-piece")
        )
        XCTAssertFalse(
            KanzenAidokuItemVerification.carriesARealTitle("/series/one-piece", for: "/series/one-piece")
        )
        XCTAssertFalse(
            KanzenAidokuItemVerification.carriesARealTitle("one-piece", for: "/series/one-piece"),
            "a soft 404 that renders the slug as its heading proves nothing"
        )
        XCTAssertTrue(
            KanzenAidokuItemVerification.carriesARealTitle("One Piece", for: "/series/one-piece")
        )
        XCTAssertTrue(
            KanzenAidokuItemVerification.carriesARealTitle(
                "Chainsaw Man",
                for: "01J0Q1RSTVWXYZ0123456789AB"
            )
        )
    }

    func testAVerificationCacheFromADifferentBuildOfTheSourceIsDiscarded() {
        let source = makeInstalledSource(
            name: "Fixture",
            upstreamID: "31337",
            baseURL: "https://fixture.test"
        )
        var other = source
        other.version = "\(source.version)-1"

        var record = ReaderExtensionReconnectLedger.SourceRecord()
        record.resolved = ["legacy": "current"]
        record.sourceFingerprint = ReaderExtensionReconnectLedgerStore.fingerprint(of: source)
        var ledger = ReaderExtensionReconnectLedger()
        ledger.records[
            ReaderExtensionReconnectLedgerStore.pairKey(
                legacySourceID: "en.testsource",
                installedSourceID: source.id
            )
        ] = record

        XCTAssertEqual(
            ReaderExtensionReconnectLedgerStore.record(
                in: ledger,
                legacySourceID: "en.testsource",
                installedSourceID: source.id,
                matching: source
            ).resolved,
            ["legacy": "current"]
        )
        XCTAssertTrue(
            ReaderExtensionReconnectLedgerStore.record(
                in: ledger,
                legacySourceID: "en.testsource",
                installedSourceID: other.id,
                matching: other
            ).resolved.isEmpty,
            "the source id survives a version bump, so the fingerprint is what stops a stale replay"
        )
    }

    func testAbsentVerdictsExpireSoATitleAddedLaterIsCheckedAgain() {
        var record = ReaderExtensionReconnectLedger.SourceRecord()
        let now = Date()
        record.absent["fresh"] = now.addingTimeInterval(-60)
        record.absent["stale"] = now.addingTimeInterval(
            -(ReaderExtensionReconnectLedgerStore.absentRecheckInterval + 60)
        )
        record.absent["clockSkewed"] = now.addingTimeInterval(3_600)

        XCTAssertTrue(ReaderExtensionReconnectLedgerStore.isKnownAbsent("fresh", in: record, now: now))
        XCTAssertFalse(ReaderExtensionReconnectLedgerStore.isKnownAbsent("stale", in: record, now: now))
        XCTAssertFalse(
            ReaderExtensionReconnectLedgerStore.isKnownAbsent("clockSkewed", in: record, now: now),
            "a future timestamp is not evidence; recheck rather than trust a skewed clock"
        )
        XCTAssertFalse(ReaderExtensionReconnectLedgerStore.isKnownAbsent("unknown", in: record, now: now))
    }

    func testTheVerificationLedgerIsNotSweptIntoTheProfileSettingsDictionary() {
        let profileID = UUID()
        let key = ReaderExtensionReconnectLedgerStore.storageKey(for: profileID)
        XCTAssertFalse(
            BackupManager.carriesProfileScopedSetting(key),
            "a per-device verification cache must never travel in a backup and land on another device's profile"
        )
        XCTAssertFalse(
            BackupManager.carriesProfileScopedSetting(
                ReaderExtensionReconnectLedgerStore.storageBase
            )
        )
        XCTAssertFalse(
            BackupManager.carriesProfileScopedSetting(
                KanzenAidokuUnavailableMarkStore.storageKey(for: profileID)
            ),
            "unavailability marks are keyed to one device's library rows"
        )
    }

    func testOnlyASourceThatCannotAnswerPausesASweep() {
        for transient: Error in [
            ReaderExtensionError.runtimeTimedOut,
            ReaderExtensionError.runtimeUnavailable,
            ReaderExtensionError.sourceQuarantined,
            ReaderExtensionError.browserVerificationRequired("example.test"),
            ReaderExtensionError.domainConsentRequired("example.test"),
            ReaderExtensionError.runtimeFailed("HTTP 429 Too Many Requests"),
            ReaderExtensionError.runtimeFailed("The request timed out."),
            URLError(.notConnectedToInternet),
            CancellationError()
        ] {
            XCTAssertTrue(
                KanzenAidokuItemVerification.sourceCannotAnswer(transient),
                "\(transient) means the source is not answering, not that the title is gone"
            )
        }

        for definitive: Error in [
            ReaderExtensionError.resultInvalid("no manga"),
            ReaderExtensionError.runtimeFailed("TypeError: cannot read property 'title' of null"),
            ReaderExtensionError.unsupportedSource,
            ReaderExtensionError.contentTooLarge,
            URLError(.unsupportedURL)
        ] {
            XCTAssertFalse(
                KanzenAidokuItemVerification.sourceCannotAnswer(definitive),
                "\(definitive) is an answer about this title, so the sweep must carry on"
            )
        }
    }

    // MARK: - fixtures

    private struct StubFixture {
        var environment: KanzenAidokuMigrationEnvironment
        var items: [MangaLibraryItem]
        var libraryData: Data?
        var progressData: Data?
        var markStore: UserDefaults
        var installedSourcesBox: InstalledSourcesBox
    }

    private final class InstalledSourcesBox {
        var value: [ReaderExtensionInstalledSource] = []
    }

    private func makeStubFixture() throws -> StubFixture {
        let legacy = try makeLegacySource(id: "en.testsource", name: "Test Source")
        let read = aidokuItem(sourceID: "en.testsource", key: "read-title", title: "Read Title")
        let unread = aidokuItem(sourceID: "en.testsource", key: "unread-title", title: "Unread Title")
        let items = [read, unread]
        let libraryData = try encodedLibrary(items)
        var readProgress = MangaProgress()
        readProgress.route = .aidoku(sourceId: "en.testsource", mangaKey: "read-title")
        readProgress.readChapterNumbers = ["1", "2"]
        let progressData = try JSONEncoder().encode([read.id: readProgress])

        let servicesStore = makeStore(named: "services")
        servicesStore.set(
            try JSONEncoder().encode([legacy]),
            forKey: BackupReaderExtensionState.legacyAidokuSourcesStorageKey
        )
        let markStore = makeStore(named: "marks")
        let box = InstalledSourcesBox()
        let owner = ownerProfileID

        var environment = KanzenAidokuMigrationEnvironment.live
        environment.servicesStore = { servicesStore }
        environment.markStore = { markStore }
        environment.activeProfileID = { owner }
        environment.isProfileStillActive = { $0 == owner }
        environment.isKidsModeActive = { false }
        environment.libraryData = { _ in libraryData }
        environment.progressData = { _ in progressData }
        environment.installedSources = { box.value }
        environment.verifyItemKey = { legacyItem, _ in .resolved(legacyItem.legacyItemKey) }
        environment.reconnect = { _, _, _, _, _, _ in
            throw ReaderExtensionLegacyReconnectError.installedSourceNotFound
        }

        return StubFixture(
            environment: environment,
            items: items,
            libraryData: libraryData,
            progressData: progressData,
            markStore: markStore,
            installedSourcesBox: box
        )
    }

    private func makeStore(named label: String) -> UserDefaults {
        let name = "KanzenAidokuMigrationTests.\(label).\(UUID().uuidString)"
        suiteNames.append(name)
        guard let store = UserDefaults(suiteName: name) else {
            XCTFail("could not create an isolated defaults suite")
            return .standard
        }
        return store
    }

    private func captureStandardValue(forKey key: String) {
        guard capturedStandardKeys.insert(key).inserted else { return }
        if let value = UserDefaults.standard.object(forKey: key) {
            restoredStandardValues[key] = value
        } else {
            removedStandardKeys.insert(key)
        }
    }

    private func aidokuItem(sourceID: String, key: String, title: String) -> MangaLibraryItem {
        let route = MangaContentRoute.aidoku(sourceId: sourceID, mangaKey: key)
        return MangaLibraryItem(
            aniListId: route.stableNegativeId,
            title: title,
            coverURL: "https://example.test/\(key).jpg",
            format: "MANGA",
            totalChapters: 3,
            route: route,
            sourceName: "Test Source",
            latestChapterNumbers: ["1", "2", "3"]
        )
    }

    private func encodedLibrary(_ items: [MangaLibraryItem]) throws -> Data {
        let collection = MangaLibraryCollection(
            id: UUID(uuidString: "1B4B4E2E-0000-4000-A000-0000000000AA") ?? UUID(),
            name: "Bookmarks",
            items: items,
            description: "Your bookmarked manga"
        )
        return try JSONEncoder().encode([collection])
    }

    private func makeLegacySource(
        id: String,
        name: String,
        languages: [String] = ["en"],
        originHost: String? = "raw.githubusercontent.com",
        order: Int = 0,
        isEnabled: Bool = true
    ) throws -> BackupLegacyAidokuSourceMetadata {
        var payload: [String: Any] = [
            "id": id,
            "name": name,
            "version": 1,
            "languages": languages,
            "contentRatingRawValue": 0,
            "isEnabled": isEnabled,
            "order": order
        ]
        if let originHost { payload["originHost"] = originHost }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(BackupLegacyAidokuSourceMetadata.self, from: data)
    }

    private func makeInstalledSource(
        name: String = "Fixture Source",
        upstreamID: String = "1234567890",
        baseURL: String = "https://fixture-provider.test",
        repositoryURL: String = "https://fixture-repository.test/index.json",
        language: String = "en",
        mediaType: ReaderExtensionMediaType = .manga
    ) -> ReaderExtensionInstalledSource {
        let base = URL(string: baseURL) ?? URL(fileURLWithPath: "/")
        let repository = URL(string: repositoryURL) ?? URL(fileURLWithPath: "/")
        let catalog = ReaderExtensionCatalogSource(
            id: ReaderExtensionSourceID(
                repositoryURL: repository,
                upstreamID: upstreamID,
                language: language,
                mediaType: mediaType
            ),
            upstreamID: upstreamID,
            repositoryID: "kanzen-aidoku-migration-fixture",
            repositoryURL: repository,
            name: name,
            baseURL: base,
            apiURL: nil,
            language: language,
            mediaType: mediaType,
            implementation: .madara,
            sourceCodeURL: nil,
            version: "1.0.0",
            maturity: .safe,
            hasCloudflare: false,
            dateFormat: nil,
            dateFormatLocale: nil,
            additionalParameters: nil,
            notes: nil,
            license: ReaderExtensionLicense(
                kind: .mit,
                name: "MIT License",
                url: nil,
                textSHA256: nil,
                detectedAt: Date()
            )
        )
        return ReaderExtensionInstalledSource(catalog: catalog, sortIndex: 0)
    }
}

#endif
