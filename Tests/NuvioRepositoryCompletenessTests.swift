import XCTest
@testable import Eclipse

#if os(iOS)

final class NuvioRepositoryCompletenessTests: XCTestCase {
    private let manifestURL = "https://example.com/plugins/manifest.json"
    private let stateKey = "nuvioPluginsState.v2"
    private let injectedRepairLedgerKey = "provider.nuvioRepositoryRepairLedger.v1.injected"

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "NuvioRepositoryCompletenessTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func repository(
        advertised: Int = 61,
        eligible: Int = 61,
        scraperCount: Int = 61,
        manifestURL: String? = nil
    ) -> NuvioPluginRepository {
        let manifestURL = manifestURL ?? self.manifestURL
        return NuvioPluginRepository(
            id: NuvioPluginSupport.repositoryID(forManifestURL: manifestURL),
            manifestUrl: manifestURL,
            name: "Fixture",
            description: nil,
            version: "1",
            scraperCount: scraperCount,
            lastUpdated: 1,
            sortIndex: 0,
            providerInventory: NuvioRepositoryProviderInventory(
                advertisedProviderCount: advertised,
                eligibleProviderCount: eligible
            )
        )
    }

    private func scraper(
        index: Int,
        repositoryID: String,
        manifestURL: String? = nil,
        codeFileName: String? = nil,
        enabled: Bool = true,
        manifestEnabled: Bool = true
    ) -> NuvioPluginScraper {
        let manifestURL = manifestURL ?? self.manifestURL
        let providerKey = "provider-\(index)"
        return NuvioPluginScraper(
            id: NuvioPluginSupport.scraperSourceID(
                manifestURL: manifestURL,
                providerKey: providerKey
            ),
            providerKey: providerKey,
            repositoryId: repositoryID,
            repositoryUrl: manifestURL,
            name: providerKey,
            description: "",
            author: nil,
            version: "1",
            filename: "\(providerKey).js",
            codeFileName: codeFileName ?? "\(providerKey)-code.js",
            supportedTypes: ["movie", "tv"],
            enabled: enabled,
            manifestEnabled: manifestEnabled,
            declaresSettings: false,
            logo: nil,
            contentLanguage: ["en"],
            formats: nil
        )
    }

    private func persistableStateExceedingByteLimit() -> NuvioStoredPluginsState {
        let repository = repository(advertised: 7, eligible: 7, scraperCount: 7)
        let scrapers = (0..<7).map { scraper(index: $0, repositoryID: repository.id) }
        let value = String(repeating: "x", count: NuvioPluginStore.Bounds.settingValueLength)
        let settings = Dictionary(
            uniqueKeysWithValues: scrapers.map { scraper in
                (
                    scraper.id,
                    Dictionary(
                        uniqueKeysWithValues: (0..<NuvioPluginStore.Bounds.settingsKeysPerScraper).map {
                            ("setting-\($0)", NuvioSettingsValue.string(value))
                        }
                    )
                )
            }
        )
        return NuvioStoredPluginsState(
            repositories: [repository],
            scrapers: scrapers,
            scraperSettings: settings
        )
    }

    private func manifestScraper(id: String, name: String = "Provider") throws -> NuvioPluginManifestScraper {
        let object: [String: Any] = [
            "id": id,
            "name": name,
            "filename": "provider.js",
            "supportedTypes": ["movie", "tv"]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(NuvioPluginManifestScraper.self, from: data)
    }

    func testReadinessCountsManifestProvidersMissingFromPartialInstall() {
        let repository = repository()
        let scrapers = (0..<45).map { scraper(index: $0, repositoryID: repository.id) }
        let state = NuvioStoredPluginsState(repositories: [repository], scrapers: scrapers)

        let readiness = state.codeReadiness { _, _ in true }

        XCTAssertEqual(readiness.readyProviderCount, 45)
        XCTAssertEqual(readiness.pendingProviderCount, 16)
        XCTAssertEqual(readiness.pendingProviderCountByRepository[repository.id], 16)
        XCTAssertEqual(readiness.pendingRepositoryIDs, [repository.id])
    }

    func testReadinessCombinesCatalogGapAndMissingInstalledCode() {
        let repository = repository()
        let scrapers = (0..<45).map { scraper(index: $0, repositoryID: repository.id) }
        let missingCodeNames = Set(scrapers.prefix(5).map(\.codeFileName))
        let state = NuvioStoredPluginsState(repositories: [repository], scrapers: scrapers)

        let readiness = state.codeReadiness { _, codeFileName in
            !missingCodeNames.contains(codeFileName)
        }

        XCTAssertEqual(readiness.readyProviderCount, 40)
        XCTAssertEqual(readiness.pendingProviderIDs.count, 5)
        XCTAssertEqual(readiness.pendingProviderCount, 21)
    }

    @MainActor
    func testPartialInstallKeepsEveryEligibleProviderVisiblePendingNonActiveAndRetryable() throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = NuvioPluginStore(defaults: defaults)
        let uniqueManifestURL = "https://example.com/plugins/\(UUID().uuidString)/manifest.json"
        let repository = repository(
            advertised: 2,
            eligible: 2,
            scraperCount: 2,
            manifestURL: uniqueManifestURL
        )
        let readyFixture = scraper(
            index: 0,
            repositoryID: repository.id,
            manifestURL: uniqueManifestURL
        )
        let readyCodeFileName = try store.writeCode(
            "function getStreams() { return []; }",
            repositoryID: repository.id,
            scraperID: readyFixture.id
        )
        let support = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let codeDirectory = support
            .appendingPathComponent("NuvioPlugins", isDirectory: true)
            .appendingPathComponent(String(repository.id.dropFirst("nuvio:".count)), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codeDirectory) }

        let ready = scraper(
            index: 0,
            repositoryID: repository.id,
            manifestURL: uniqueManifestURL,
            codeFileName: readyCodeFileName
        )
        let pending = scraper(
            index: 1,
            repositoryID: repository.id,
            manifestURL: uniqueManifestURL,
            codeFileName: ""
        )
        let partialState = NuvioStoredPluginsState(
            repositories: [repository],
            scrapers: [ready, pending]
        )
        let bounded = NuvioPluginStore.bounded(partialState)
        XCTAssertFalse(bounded.wasBounded)
        XCTAssertEqual(Set(bounded.state.scrapers.map(\.providerKey)), [ready.providerKey, pending.providerKey])
        XCTAssertTrue(store.save(partialState))
        var ledger = NuvioRepositoryRepairLedger()
        ledger.setFailedProviderKeys([pending.providerKey], for: repository.id)
        store.saveRepairLedger(ledger, validRepositoryIDs: [repository.id])

        do {
            let manager = NuvioPluginManager(store: store)
            let pendingIDs = Set(manager.codeReadiness.pendingProviderIDs)
            let representedProviderKeys = Set(manager.scrapers.map(\.providerKey))
            let readyProviderKeys = Set(
                manager.scrapers.compactMap { scraper in
                    pendingIDs.contains(scraper.id) ? nil : scraper.providerKey
                }
            )
            let retryProviderKeys = NuvioRepositoryRepairPolicy.providerKeysToRetry(
                eligibleProviderKeys: [ready.providerKey, pending.providerKey],
                representedProviderKeys: representedProviderKeys,
                codeReadyProviderKeys: readyProviderKeys,
                failedProviderKeys: [pending.providerKey]
            )
            let status = try XCTUnwrap(manager.providerStatus(forRepository: repository.id))

            XCTAssertEqual(manager.scrapers.count, 2)
            XCTAssertEqual(manager.codeReadiness.readyProviderCount, 1)
            XCTAssertEqual(pendingIDs, [pending.id])
            XCTAssertEqual(manager.activeScrapers.map(\.id), [ready.id])
            XCTAssertEqual(status.installedProviderCount, 1)
            XCTAssertEqual(status.pendingProviderCount, 1)
            XCTAssertEqual(status.failedProviderCount, 1)
            XCTAssertTrue(status.needsRetry)
            XCTAssertEqual(retryProviderKeys, [pending.providerKey])
        }
    }

    @MainActor
    func testUserDisablePersistsAndManifestDisabledCarriedCodeStaysNonRunnable() throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let servicesDefaults = ProfileSettingsStore.services
        let orderKey = "servicesAutoModeSourceOrderIds"
        let previousOrder = servicesDefaults.object(forKey: orderKey)
        defer {
            if let previousOrder {
                servicesDefaults.set(previousOrder, forKey: orderKey)
            } else {
                servicesDefaults.removeObject(forKey: orderKey)
            }
        }
        let unrelatedSourceID = "service:keep"
        servicesDefaults.set([unrelatedSourceID], forKey: orderKey)
        let store = NuvioPluginStore(defaults: defaults)
        let uniqueManifestURL = "https://example.com/plugins/\(UUID().uuidString)/manifest.json"
        let repository = repository(
            advertised: 2,
            eligible: 2,
            scraperCount: 2,
            manifestURL: uniqueManifestURL
        )
        let userControlledFixture = scraper(
            index: 0,
            repositoryID: repository.id,
            manifestURL: uniqueManifestURL
        )
        let manifestDisabledFixture = scraper(
            index: 1,
            repositoryID: repository.id,
            manifestURL: uniqueManifestURL
        )
        let userControlledCodeFileName = try store.writeCode(
            "function getStreams() { return [{ url: 'https://example.com/a.mp4' }]; }",
            repositoryID: repository.id,
            scraperID: userControlledFixture.id
        )
        let carriedCodeFileName = try store.writeCode(
            "function getStreams() { return [{ url: 'https://example.com/b.mp4' }]; }",
            repositoryID: repository.id,
            scraperID: manifestDisabledFixture.id
        )
        let support = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let codeDirectory = support
            .appendingPathComponent("NuvioPlugins", isDirectory: true)
            .appendingPathComponent(String(repository.id.dropFirst("nuvio:".count)), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codeDirectory) }

        let userControlled = scraper(
            index: 0,
            repositoryID: repository.id,
            manifestURL: uniqueManifestURL,
            codeFileName: userControlledCodeFileName
        )
        let manifestDisabled = scraper(
            index: 1,
            repositoryID: repository.id,
            manifestURL: uniqueManifestURL,
            codeFileName: carriedCodeFileName,
            enabled: false,
            manifestEnabled: false
        )
        XCTAssertTrue(
            store.save(
                NuvioStoredPluginsState(
                    repositories: [repository],
                    scrapers: [userControlled, manifestDisabled]
                )
            )
        )

        do {
            let manager = NuvioPluginManager(store: store)
            manager.setScraperEnabled(userControlled.id, enabled: false)
            manager.setScraperEnabled(manifestDisabled.id, enabled: true)
            manager.load()

            XCTAssertTrue(
                store.hasCode(
                    repositoryID: repository.id,
                    codeFileName: carriedCodeFileName
                )
            )
            XCTAssertFalse(try XCTUnwrap(manager.scraper(withID: userControlled.id)).enabled)
            let disabledAfterReload = try XCTUnwrap(manager.scraper(withID: manifestDisabled.id))
            XCTAssertFalse(disabledAfterReload.enabled)
            XCTAssertFalse(disabledAfterReload.manifestEnabled)
            XCTAssertFalse(disabledAfterReload.isRunnable)
            XCTAssertTrue(manager.activeScrapers.isEmpty)
            XCTAssertEqual(
                AutoModeSourceSelection.sourceOrderIds(defaults: servicesDefaults),
                [unrelatedSourceID]
            )
        }
    }

    @MainActor
    func testRefreshCommitUsesCurrentEnablementAndLatestManifestKillSwitch() {
        let repository = repository(advertised: 2, eligible: 2, scraperCount: 2)
        let currentUserDisabled = scraper(
            index: 0,
            repositoryID: repository.id,
            enabled: false
        )
        let fetchedBeforeUserToggle = scraper(
            index: 0,
            repositoryID: repository.id,
            enabled: true
        )
        let currentManifestProvider = scraper(
            index: 1,
            repositoryID: repository.id,
            enabled: true
        )
        let fetchedManifestDisabled = scraper(
            index: 1,
            repositoryID: repository.id,
            enabled: false,
            manifestEnabled: false
        )

        let reconciled = NuvioPluginManager.reconciledRefreshScrapers(
            [fetchedBeforeUserToggle, fetchedManifestDisabled],
            withCurrent: [currentUserDisabled, currentManifestProvider]
        )
        let byID = Dictionary(uniqueKeysWithValues: reconciled.map { ($0.id, $0) })

        XCTAssertFalse(byID[currentUserDisabled.id]?.enabled ?? true)
        XCTAssertTrue(byID[currentUserDisabled.id]?.manifestEnabled ?? false)
        XCTAssertFalse(byID[currentManifestProvider.id]?.enabled ?? true)
        XCTAssertFalse(byID[currentManifestProvider.id]?.manifestEnabled ?? true)
    }

    @MainActor
    func testRestorePrunesRemovedProviderDefaultsButPreservesIncomingPendingProvider() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let servicesDefaults = ProfileSettingsStore.services
        let sourceDefaultsKeys = [
            "servicesAutoModeSourceIds",
            "servicesAutoModeSourceOrderIds",
            StreamLanguageFilter.extraRulesSourceIdsKey
        ]
        let previousSourceDefaults = sourceDefaultsKeys.map {
            ($0, servicesDefaults.object(forKey: $0))
        }
        defer {
            for (key, value) in previousSourceDefaults {
                if let value {
                    servicesDefaults.set(value, forKey: key)
                } else {
                    servicesDefaults.removeObject(forKey: key)
                }
            }
        }

        let store = NuvioPluginStore(defaults: defaults)
        let uniqueManifestURL = "https://example.com/plugins/\(UUID().uuidString)/manifest.json"
        let currentRepository = repository(
            advertised: 2,
            eligible: 2,
            scraperCount: 2,
            manifestURL: uniqueManifestURL
        )
        let removedFixture = scraper(
            index: 0,
            repositoryID: currentRepository.id,
            manifestURL: uniqueManifestURL
        )
        let pendingFixture = scraper(
            index: 1,
            repositoryID: currentRepository.id,
            manifestURL: uniqueManifestURL
        )
        let removedCodeFileName = try store.writeCode(
            "function getStreams() { return [{ url: 'https://example.com/removed.mp4' }]; }",
            repositoryID: currentRepository.id,
            scraperID: removedFixture.id
        )
        let pendingOldCodeFileName = try store.writeCode(
            "function getStreams() { return [{ url: 'https://example.com/pending.mp4' }]; }",
            repositoryID: currentRepository.id,
            scraperID: pendingFixture.id
        )
        let support = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let codeDirectory = support
            .appendingPathComponent("NuvioPlugins", isDirectory: true)
            .appendingPathComponent(String(currentRepository.id.dropFirst("nuvio:".count)), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codeDirectory) }

        let removed = scraper(
            index: 0,
            repositoryID: currentRepository.id,
            manifestURL: uniqueManifestURL,
            codeFileName: removedCodeFileName
        )
        let pendingBeforeRestore = scraper(
            index: 1,
            repositoryID: currentRepository.id,
            manifestURL: uniqueManifestURL,
            codeFileName: pendingOldCodeFileName
        )
        XCTAssertTrue(
            store.save(
                NuvioStoredPluginsState(
                    repositories: [currentRepository],
                    scrapers: [removed, pendingBeforeRestore]
                )
            )
        )

        let unrelatedSourceID = "service:keep"
        servicesDefaults.set(
            [unrelatedSourceID, removed.id, pendingBeforeRestore.id],
            forKey: "servicesAutoModeSourceIds"
        )
        servicesDefaults.set(
            [unrelatedSourceID, removed.id, pendingBeforeRestore.id],
            forKey: "servicesAutoModeSourceOrderIds"
        )
        StreamLanguageFilter.setExtraRulesSourceIds(
            [unrelatedSourceID, removed.id, pendingBeforeRestore.id],
            defaults: servicesDefaults
        )

        var incomingRepository = currentRepository
        incomingRepository.scraperCount = 1
        incomingRepository.providerInventory = NuvioRepositoryProviderInventory(
            advertisedProviderCount: 1,
            eligibleProviderCount: 1
        )
        let incomingPending = scraper(
            index: 1,
            repositoryID: currentRepository.id,
            manifestURL: uniqueManifestURL,
            codeFileName: ""
        )
        let incoming = NuvioStoredPluginsState(
            repositories: [incomingRepository],
            scrapers: [incomingPending]
        )

        do {
            let manager = NuvioPluginManager(store: store)
            let restoreTask = Task { @MainActor in
                await manager.restoreBackupState(incoming)
            }
            restoreTask.cancel()
            let result = await restoreTask.value
            manager.load()

            XCTAssertTrue(result.wasInterrupted)
            XCTAssertEqual(
                AutoModeSourceSelection.selectedSourceIds(defaults: servicesDefaults),
                [unrelatedSourceID, incomingPending.id]
            )
            XCTAssertEqual(
                AutoModeSourceSelection.sourceOrderIds(defaults: servicesDefaults),
                [unrelatedSourceID, incomingPending.id]
            )
            XCTAssertEqual(
                try XCTUnwrap(
                    StreamLanguageFilter.extraRulesSourceIds(defaults: servicesDefaults)
                ),
                [unrelatedSourceID, incomingPending.id]
            )
            XCTAssertEqual(manager.scrapers.map(\.id), [incomingPending.id])
            XCTAssertEqual(manager.codeReadiness.pendingProviderIDs, [incomingPending.id])
            XCTAssertTrue(manager.activeScrapers.isEmpty)
        }
    }

    func testRepairTargetsOnlyFailedAbsentOrMissingCodeProviders() {
        let retry = NuvioRepositoryRepairPolicy.providerKeysToRetry(
            eligibleProviderKeys: ["healthy", "failed-update", "missing-code", "absent"],
            representedProviderKeys: ["healthy", "failed-update", "missing-code"],
            codeReadyProviderKeys: ["healthy", "failed-update"],
            failedProviderKeys: ["failed-update"]
        )

        XCTAssertEqual(retry, ["failed-update", "missing-code", "absent"])
    }

    @MainActor
    func testRestoreRejectsStaleServicesScopeBeforeMutation() async {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = NuvioPluginStore(defaults: defaults)
        let current = NuvioStoredPluginsState(pluginsEnabled: false)
        XCTAssertTrue(store.save(current))

        let incomingRepository = repository(
            advertised: 1,
            eligible: 1,
            scraperCount: 1,
            manifestURL: "https://example.com/stale-scope/manifest.json"
        )
        let incoming = NuvioStoredPluginsState(
            repositories: [incomingRepository],
            scrapers: [
                scraper(
                    index: 0,
                    repositoryID: incomingRepository.id,
                    manifestURL: incomingRepository.manifestUrl,
                    codeFileName: ""
                )
            ]
        )
        let manager = NuvioPluginManager(store: store)
        let staleGeneration = ServiceStoreScope.generation &- 1

        let result = await manager.restoreBackupState(
            incoming,
            expectedScopeGeneration: staleGeneration
        )

        XCTAssertTrue(result.wasInterrupted)
        XCTAssertFalse(result.restoreWasPersisted)
        XCTAssertFalse(store.load().pluginsEnabled)
        XCTAssertTrue(store.load().repositories.isEmpty)
        XCTAssertTrue(manager.repositories.isEmpty)
    }

    func testRetryReconciliationKeepsUnattemptedFailuresAndClearsSuccesses() {
        let failures = NuvioRepositoryRepairPolicy.reconciledFailedProviderKeys(
            eligibleProviderKeys: ["a", "b", "c", "d"],
            previousFailedProviderKeys: ["a", "b", "c", "removed"],
            attemptedProviderKeys: ["a", "b", "d"],
            failedProviderKeys: ["b", "d", "not-eligible"]
        )

        XCTAssertEqual(failures, ["b", "c", "d"])
    }

    func testCompletedRetryHasNoFurtherWorkOrDuplicateCandidates() {
        let eligible: Set<String> = ["a", "b", "c"]
        let retry = NuvioRepositoryRepairPolicy.providerKeysToRetry(
            eligibleProviderKeys: eligible,
            representedProviderKeys: eligible,
            codeReadyProviderKeys: eligible,
            failedProviderKeys: []
        )

        XCTAssertTrue(retry.isEmpty)
    }

    func testProviderStatusReportsAdvertisedEligibleInstalledPendingAndFailed() {
        let status = NuvioRepositoryProviderStatus.resolved(
            repository: repository(),
            representedProviderCount: 45,
            installedProviderCount: 45,
            failedProviderCount: 16
        )

        XCTAssertEqual(status.advertisedProviderCount, 61)
        XCTAssertEqual(status.eligibleProviderCount, 61)
        XCTAssertEqual(status.installedProviderCount, 45)
        XCTAssertEqual(status.pendingProviderCount, 16)
        XCTAssertEqual(status.failedProviderCount, 16)
        XCTAssertEqual(status.excludedProviderCount, 0)
        XCTAssertTrue(status.needsRetry)
    }

    func testProviderStatusDistinguishesAdvertisedFromPlatformEligible() {
        let status = NuvioRepositoryProviderStatus.resolved(
            repository: repository(advertised: 61, eligible: 55, scraperCount: 55),
            representedProviderCount: 45,
            installedProviderCount: 45,
            failedProviderCount: 10
        )

        XCTAssertEqual(status.advertisedProviderCount, 61)
        XCTAssertEqual(status.eligibleProviderCount, 55)
        XCTAssertEqual(status.installedProviderCount, 45)
        XCTAssertEqual(status.pendingProviderCount, 10)
        XCTAssertEqual(status.failedProviderCount, 10)
        XCTAssertEqual(status.excludedProviderCount, 6)
    }

    func testManifestAdmissionRejectsAnyDuplicateOrOverLimitProvider() throws {
        let first = try manifestScraper(id: "first")
        let second = try manifestScraper(id: "second")
        let duplicate = try manifestScraper(id: "first")
        let oversized = try manifestScraper(
            id: "oversized",
            name: String(repeating: "x", count: NuvioPluginStore.Bounds.textLength + 1)
        )

        XCTAssertTrue(NuvioPluginSupport.manifestScrapersAreComplete([first, second]))
        XCTAssertFalse(NuvioPluginSupport.manifestScrapersAreComplete([first, duplicate]))
        XCTAssertFalse(NuvioPluginSupport.manifestScrapersAreComplete([first, oversized]))
    }

    func testRepairLedgerScopePartitionsProfilesButCollapsesSharedServices() throws {
        let first = try XCTUnwrap(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let second = try XCTUnwrap(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))

        XCTAssertNotEqual(
            NuvioPluginStore.repairLedgerScopeToken(profileID: first, sharesServices: false),
            NuvioPluginStore.repairLedgerScopeToken(profileID: second, sharesServices: false)
        )
        XCTAssertEqual(
            NuvioPluginStore.repairLedgerScopeToken(profileID: first, sharesServices: true),
            NuvioPluginStore.repairLedgerScopeToken(profileID: second, sharesServices: true)
        )
        XCTAssertEqual(
            EclipseSettingsRegistry.scope(for: "provider.nuvioRepositoryRepairLedger.v1.shared"),
            .device
        )
    }

    func testRepairLedgerIsBoundedAndDropsOtherRepositoryState() {
        let repositoryID = "nuvio:abc"
        var ledger = NuvioRepositoryRepairLedger()
        ledger.failedProviderKeysByRepository[repositoryID] =
            (0..<205).map { "provider-\($0)" } + ["provider-1", "", String(repeating: "x", count: 2_049)]
        ledger.failedProviderKeysByRepository["nuvio:other"] = ["must-not-cross-scope"]

        let bounded = NuvioPluginStore.boundedRepairLedger(
            ledger,
            validRepositoryIDs: [repositoryID]
        )

        XCTAssertEqual(bounded.failedProviderKeysByRepository.keys.sorted(), [repositoryID])
        XCTAssertEqual(bounded.failedProviderKeys(for: repositoryID).count, 200)
        XCTAssertFalse(bounded.failedProviderKeys(for: repositoryID).contains(""))
    }

    func testStoredInventoryCountsAreBoundedAndInternallyConsistent() {
        var invalid = repository(advertised: -1, eligible: 9_999, scraperCount: -3)
        invalid.providerInventory = NuvioRepositoryProviderInventory(
            advertisedProviderCount: -1,
            eligibleProviderCount: 9_999
        )

        let bounded = NuvioPluginStore.bounded(
            NuvioStoredPluginsState(repositories: [invalid])
        ).state
        let stored = bounded.repositories.first

        XCTAssertEqual(stored?.scraperCount, 0)
        XCTAssertEqual(stored?.providerInventory?.eligibleProviderCount, 200)
        XCTAssertEqual(stored?.providerInventory?.advertisedProviderCount, 200)
    }

    func testCorruptStoredStatePreservesBytesAndBlocksOrdinarySave() throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let original = Data([0xFF, 0x00, 0x7B])
        let legacy = Data("legacy rescue".utf8)
        let repositoryID = "nuvio:corrupt-state"
        let repairLedger = NuvioRepositoryRepairLedger(
            failedProviderKeysByRepository: [repositoryID: ["provider-a"]]
        )
        defaults.set(original, forKey: stateKey)
        defaults.set(legacy, forKey: "nuvioPluginsState.v1")
        defaults.set(try JSONEncoder().encode(repairLedger), forKey: injectedRepairLedgerKey)
        let store = NuvioPluginStore(defaults: defaults)

        let loaded = store.load()
        let preservedLedger = store.loadRepairLedgerPreservingRepositoryIDs()
        store.purgeLegacyState()
        XCTAssertFalse(store.save(NuvioStoredPluginsState(pluginsEnabled: false)))

        XCTAssertTrue(loaded.repositories.isEmpty)
        XCTAssertTrue(store.stateWritesSuspended)
        XCTAssertEqual(defaults.data(forKey: stateKey), original)
        XCTAssertEqual(defaults.data(forKey: "nuvioPluginsState.v1"), legacy)
        XCTAssertEqual(preservedLedger.failedProviderKeys(for: repositoryID), ["provider-a"])
        XCTAssertNotNil(defaults.data(forKey: injectedRepairLedgerKey))
    }

    func testWrongTypedStoredStateIsPreservedAndBlocksOrdinarySave() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("not encoded plugin state", forKey: stateKey)
        let store = NuvioPluginStore(defaults: defaults)

        _ = store.load()
        XCTAssertFalse(store.save(NuvioStoredPluginsState(pluginsEnabled: false)))

        XCTAssertTrue(store.stateWritesSuspended)
        XCTAssertEqual(defaults.string(forKey: stateKey), "not encoded plugin state")
    }

    func testOversizedStoredStatePreservesBytesUntilAuthoritativeRestore() throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let original = Data(
            repeating: 0x20,
            count: NuvioPluginStore.Bounds.persistedStateBytes + 1
        )
        defaults.set(original, forKey: stateKey)
        let store = NuvioPluginStore(defaults: defaults)

        _ = store.load()
        XCTAssertFalse(store.save(NuvioStoredPluginsState(pluginsEnabled: false)))
        XCTAssertEqual(defaults.data(forKey: stateKey), original)

        let authoritative = NuvioStoredPluginsState(pluginsEnabled: false)
        XCTAssertTrue(store.replaceStateAuthoritatively(authoritative))
        XCTAssertFalse(store.stateWritesSuspended)
        let encoded = try XCTUnwrap(defaults.data(forKey: stateKey))
        XCTAssertEqual(
            try JSONDecoder().decode(NuvioStoredPluginsState.self, from: encoded),
            authoritative
        )
    }

    func testSemanticallyInvalidStoredStateCannotBecomePartialAuthority() throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var invalidRepository = repository()
        invalidRepository.name = String(
            repeating: "x",
            count: NuvioPluginStore.Bounds.textLength + 1
        )
        let invalid = NuvioStoredPluginsState(repositories: [invalidRepository])
        let original = try JSONEncoder().encode(invalid)
        defaults.set(original, forKey: stateKey)
        let store = NuvioPluginStore(defaults: defaults)

        _ = store.load()
        XCTAssertFalse(store.save(NuvioStoredPluginsState()))

        XCTAssertTrue(store.stateWritesSuspended)
        XCTAssertEqual(defaults.data(forKey: stateKey), original)
        XCTAssertFalse(store.replaceStateAuthoritatively(invalid))
        XCTAssertEqual(defaults.data(forKey: stateKey), original)
        XCTAssertNil(BackupData.nuvioStateForExperimentalCloudSync(invalid))
    }

    func testOversizedCandidateSaveReturnsFalseWithoutReplacingPriorBytes() throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = NuvioPluginStore(defaults: defaults)
        let initial = NuvioStoredPluginsState(pluginsEnabled: false)

        XCTAssertTrue(store.save(initial))
        let original = try XCTUnwrap(defaults.data(forKey: stateKey))
        let oversized = persistableStateExceedingByteLimit()

        XCTAssertFalse(store.canSave(oversized))
        XCTAssertFalse(store.save(oversized))
        XCTAssertEqual(defaults.data(forKey: stateKey), original)
        XCTAssertEqual(
            try JSONDecoder().decode(NuvioStoredPluginsState.self, from: original),
            initial
        )
    }

    func testSemanticallyInvalidCandidateSaveReturnsFalseWithoutReplacingPriorBytes() throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = NuvioPluginStore(defaults: defaults)
        XCTAssertTrue(store.save(NuvioStoredPluginsState(pluginsEnabled: false)))
        let original = try XCTUnwrap(defaults.data(forKey: stateKey))
        var invalidRepository = repository()
        invalidRepository.name = String(
            repeating: "x",
            count: NuvioPluginStore.Bounds.textLength + 1
        )
        let invalid = NuvioStoredPluginsState(repositories: [invalidRepository])

        XCTAssertFalse(store.canSave(invalid))
        XCTAssertFalse(store.save(invalid))
        XCTAssertEqual(defaults.data(forKey: stateKey), original)
    }

    func testDormantProfileServicesScopeRetainsRepositoryAndCodeOwnership() throws {
        let (shared, sharedSuite) = isolatedDefaults()
        let (dormant, dormantSuite) = isolatedDefaults()
        defer {
            shared.removePersistentDomain(forName: sharedSuite)
            dormant.removePersistentDomain(forName: dormantSuite)
        }
        let repository = repository(advertised: 1, eligible: 1, scraperCount: 1)
        let dormantScraper = scraper(index: 0, repositoryID: repository.id)
        shared.set(try JSONEncoder().encode(NuvioStoredPluginsState()), forKey: stateKey)
        dormant.set(
            try JSONEncoder().encode(
                NuvioStoredPluginsState(
                    repositories: [repository],
                    scrapers: [dormantScraper]
                )
            ),
            forKey: stateKey
        )

        XCTAssertEqual(
            NuvioPluginStore.repositoryIsReferenced(
                repositoryID: repository.id,
                in: [shared, dormant, shared]
            ),
            true
        )
        XCTAssertEqual(
            NuvioPluginStore.referencedCodeFileNames(
                repositoryID: repository.id,
                in: [shared, dormant, shared]
            ),
            Set([dormantScraper.codeFileName])
        )
    }

    func testUnreadableServicesScopeBlocksRepositoryAndCodeOwnershipDecisions() throws {
        let (readable, readableSuite) = isolatedDefaults()
        let (unreadable, unreadableSuite) = isolatedDefaults()
        defer {
            readable.removePersistentDomain(forName: readableSuite)
            unreadable.removePersistentDomain(forName: unreadableSuite)
        }
        let repository = repository(advertised: 1, eligible: 1, scraperCount: 1)
        readable.set(
            try JSONEncoder().encode(NuvioStoredPluginsState(repositories: [repository])),
            forKey: stateKey
        )
        unreadable.set("not plugin state", forKey: stateKey)

        XCTAssertNil(
            NuvioPluginStore.repositoryIsReferenced(
                repositoryID: repository.id,
                in: [readable, unreadable]
            )
        )
        XCTAssertNil(
            NuvioPluginStore.referencedCodeFileNames(
                repositoryID: repository.id,
                in: [readable, unreadable]
            )
        )
    }

    @MainActor
    func testSemanticallyInvalidStoredStateCannotRunBoundedProjection() throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var invalidRepository = repository(scraperCount: 1)
        invalidRepository.name = String(
            repeating: "x",
            count: NuvioPluginStore.Bounds.textLength + 1
        )
        let installedScraper = scraper(index: 0, repositoryID: invalidRepository.id)
        let invalid = NuvioStoredPluginsState(
            repositories: [invalidRepository],
            scrapers: [installedScraper],
            scraperSettings: [installedScraper.id: ["token": .string("private")]]
        )
        defaults.set(try JSONEncoder().encode(invalid), forKey: stateKey)

        let manager = NuvioPluginManager(store: NuvioPluginStore(defaults: defaults))

        XCTAssertTrue(manager.storedStateIsUnreadable)
        XCTAssertTrue(manager.activeScrapers.isEmpty)
        XCTAssertTrue(manager.enabledRepositories.isEmpty)
        XCTAssertTrue(manager.settingsValues(scraperID: installedScraper.id).isEmpty)
    }

    func testContentAddressedCodeRepairsCorruptionAndRejectsExpandedOversize() throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = NuvioPluginStore(defaults: defaults)
        let repositoryID = "nuvio:" + String(UUID().uuidString.sha256.prefix(32))
        let scraperID = "nuvio:" + String(UUID().uuidString.sha256.prefix(32))
        let code = "function getStreams() { return []; }"
        let fileName = try store.writeCode(
            code,
            repositoryID: repositoryID,
            scraperID: scraperID
        )
        let support = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let directory = support
            .appendingPathComponent("NuvioPlugins", isDirectory: true)
            .appendingPathComponent(String(repositoryID.dropFirst("nuvio:".count)), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)

        XCTAssertTrue(store.hasCode(repositoryID: repositoryID, codeFileName: fileName))
        XCTAssertEqual(store.readCode(repositoryID: repositoryID, codeFileName: fileName), code)

        try Data("corrupt".utf8).write(to: destination, options: .atomic)
        XCTAssertFalse(store.hasCode(repositoryID: repositoryID, codeFileName: fileName))

        XCTAssertEqual(
            try store.writeCode(code, repositoryID: repositoryID, scraperID: scraperID),
            fileName
        )
        XCTAssertTrue(store.hasCode(repositoryID: repositoryID, codeFileName: fileName))
        XCTAssertEqual(store.readCode(repositoryID: repositoryID, codeFileName: fileName), code)

        let oversized = String(
            repeating: "\u{FFFD}",
            count: NuvioPluginStore.Bounds.codeBytes / 2
        )
        XCTAssertThrowsError(
            try store.writeCode(
                oversized,
                repositoryID: repositoryID,
                scraperID: scraperID
            )
        )
    }

    func testAuthoritativeResetClearsOnlyCurrentDefaultsScope() throws {
        let (current, currentSuite) = isolatedDefaults()
        let (other, otherSuite) = isolatedDefaults()
        defer {
            current.removePersistentDomain(forName: currentSuite)
            other.removePersistentDomain(forName: otherSuite)
        }
        let currentState = try JSONEncoder().encode(NuvioStoredPluginsState(pluginsEnabled: false))
        let otherState = try JSONEncoder().encode(NuvioStoredPluginsState(pluginsEnabled: true))
        current.set(currentState, forKey: stateKey)
        current.set(Data("legacy-current".utf8), forKey: "nuvioPluginsState.v1")
        other.set(otherState, forKey: stateKey)
        let store = NuvioPluginStore(defaults: current)

        _ = store.load()
        store.resetStateAuthoritatively()

        XCTAssertNil(current.data(forKey: stateKey))
        XCTAssertNil(current.data(forKey: "nuvioPluginsState.v1"))
        XCTAssertEqual(other.data(forKey: stateKey), otherState)
        XCTAssertFalse(store.stateWritesSuspended)
    }

    func testManifestRetrySucceedsOnceAfterRateLimit() async throws {
        var attempts = 0
        var delays: [TimeInterval] = []

        let value = try await NuvioManifestFetchRetryPolicy.run(
            operation: {
                attempts += 1
                if attempts == 1 {
                    throw NuvioRepositoryHTTPFailure(
                        statusCode: 429,
                        retryAfterSeconds: 30
                    )
                }
                return "manifest"
            },
            sleep: { delays.append($0) }
        )

        XCTAssertEqual(value, "manifest")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(delays, [NuvioManifestFetchRetryPolicy.maximumRetryAfterSeconds])
    }

    func testManifestRetryStopsAfterSecondTransientFailure() async {
        var attempts = 0
        var delays: [TimeInterval] = []

        do {
            let _: String = try await NuvioManifestFetchRetryPolicy.run(
                operation: {
                    attempts += 1
                    throw NuvioRepositoryHTTPFailure(
                        statusCode: 503,
                        retryAfterSeconds: nil
                    )
                },
                sleep: { delays.append($0) }
            )
            XCTFail("Expected the persistent manifest failure to propagate")
        } catch let error as NuvioRepositoryHTTPFailure {
            XCTAssertEqual(error.statusCode, 503)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(delays, [NuvioManifestFetchRetryPolicy.defaultRetryDelaySeconds])
    }

    func testRepositoryRequestPolicyPreservesExistingQueryWithoutCacheBuster() throws {
        let rawURL = "https://raw.githubusercontent.com/example/repo/main/manifest.json?token=a%2Bb&mode=full"
        let url = try XCTUnwrap(URL(string: rawURL))
        let requestURL = NuvioRepositoryRequestPolicy.requestURL(url)

        XCTAssertEqual(requestURL.absoluteString, rawURL)
        XCTAssertNil(
            URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "t" })
        )
    }

    func testRelativeProviderCodeURLPreservesManifestCapabilityQuery() throws {
        let manifest = "https://plugins.example/private/manifest.json?token=a%2Bb&mode=full"
        let codeURL = NuvioPluginSupport.codeURL(
            manifestURL: manifest,
            filename: "providers/movie.js"
        )
        let components = try XCTUnwrap(URLComponents(string: codeURL))
        let values = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        XCTAssertEqual(components.host, "plugins.example")
        XCTAssertEqual(components.path, "/private/providers/movie.js")
        XCTAssertEqual(values, ["token": "a+b", "mode": "full"])
    }

    func testRuntimeResponseCapRefusalBlamesEclipseWithoutCountingATransportFailure() {
        let tally = NuvioFetchTally()
        tally.recordEclipseRefusal(.responseTooLarge)

        let interference = tally.interference
        XCTAssertTrue(interference.blocksScraping)
        XCTAssertEqual(interference.refusalsByReason["response-too-large"], 1)
        XCTAssertTrue(interference.blockingSummary.contains("response-too-largex1"))

        let ledger = tally.ledgerDescription
        XCTAssertTrue(ledger.contains("transportFailures=0"))
        XCTAssertTrue(ledger.contains("eclipseRefused=[response-too-largex1]"))
    }

    func testTransportFailureAloneStaysProviderBlame() {
        let tally = NuvioFetchTally()
        tally.recordTransportFailure()

        XCTAssertFalse(tally.interference.blocksScraping)

        let ledger = tally.ledgerDescription
        XCTAssertTrue(ledger.contains("transportFailures=1"))
        XCTAssertTrue(ledger.contains("eclipseRefused=[none]"))
    }

    func testLegacyRepositoryWithoutInventoryStillDecodes() throws {
        let repositoryID = NuvioPluginSupport.repositoryID(forManifestURL: manifestURL)
        let payload = """
        {
          "pluginsEnabled": true,
          "repositories": [{
            "id": "\(repositoryID)",
            "manifestUrl": "\(manifestURL)",
            "name": "Legacy",
            "version": "1",
            "scraperCount": 0,
            "lastUpdated": 1,
            "sortIndex": 0,
            "isEnabled": true,
            "isRefreshing": false
          }],
          "scrapers": [],
          "scraperSettings": {}
        }
        """

        let state = try JSONDecoder().decode(
            NuvioStoredPluginsState.self,
            from: Data(payload.utf8)
        )

        XCTAssertNil(try XCTUnwrap(state.repositories.first).providerInventory)
    }
}

#endif
