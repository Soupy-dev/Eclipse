import XCTest
@testable import Eclipse

#if os(iOS)

final class KanzenLegacyJavaScriptIsolationTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeStore() -> KanzenLegacyJavaScriptQuarantineStore {
        let name = "KanzenLegacyJavaScriptIsolationTests.\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return KanzenLegacyJavaScriptQuarantineStore(defaults: defaults)
    }

    private func makeTimeouts() -> KanzenModuleRunner.Timeouts {
        KanzenModuleRunner.Timeouts(
            loadNanoseconds: 150_000_000,
            functionNanoseconds: 150_000_000,
            callbackNanoseconds: 150_000_000,
            promiseNanoseconds: 120_000_000
        )
    }

    @discardableResult
    private func capturedError(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Error {
        do {
            try await operation()
            XCTFail("expected operation to throw", file: file, line: line)
            return KanzenLegacyJavaScriptError.invalidResult
        } catch {
            return error
        }
    }

    func testTopLevelInfiniteLoopDoesNotBlockMainActorAndQuarantinesFirstRunningStrike() async {
        let pool = KanzenLegacyJavaScriptWorkerPool()
        let store = makeStore()
        let engine = KanzenEngine(
            workerPool: pool,
            quarantineStore: store,
            timeouts: makeTimeouts()
        )
        let moduleID = UUID()
        let mainActorMoved = expectation(description: "main actor remained responsive")

        let loadTask = Task { @MainActor in
            try await engine.loadScript(
                "while (true) {}",
                moduleID: moduleID,
                moduleName: "top-level-loop"
            )
        }
        await MainActor.run {
            DispatchQueue.main.async {
                mainActorMoved.fulfill()
            }
        }
        await fulfillment(of: [mainActorMoved], timeout: 0.1)
        _ = await capturedError { try await loadTask.value }

        XCTAssertTrue(store.isQuarantined(moduleID: moduleID))
        XCTAssertEqual(pool.availableLaneCount, 1)
        XCTAssertEqual(pool.physicalLaneCount, 2)
    }

    func testFunctionInfiniteLoopQuarantineSurvivesScriptUpdateUntilExplicitClear() async throws {
        let pool = KanzenLegacyJavaScriptWorkerPool()
        let store = makeStore()
        let moduleID = UUID()
        let engine = KanzenEngine(
            workerPool: pool,
            quarantineStore: store,
            timeouts: makeTimeouts()
        )
        try await engine.loadScript(
            "function searchResults() { while (true) {} }",
            moduleID: moduleID,
            moduleName: "function-loop"
        )
        _ = await capturedError {
            _ = try await engine.searchInput("query")
        }
        XCTAssertTrue(store.isQuarantined(moduleID: moduleID))

        let updated = KanzenEngine(
            workerPool: pool,
            quarantineStore: store,
            timeouts: makeTimeouts()
        )
        _ = await capturedError {
            try await updated.loadScript(
                "function searchResults() { return []; }",
                moduleID: moduleID,
                moduleName: "function-loop-updated"
            )
        }
        store.clear(moduleID: moduleID)
        try await updated.loadScript(
            "function searchResults() { return []; }",
            moduleID: moduleID,
            moduleName: "function-loop-updated"
        )
        let healthyCount = try await updated.searchInput("healthy")?.count
        XCTAssertEqual(healthyCount, 0)
    }

    func testQueuedHealthyControllerRehomesThenItsOwnHangRetiresReplacementWithoutThirdLane() async throws {
        let pool = KanzenLegacyJavaScriptWorkerPool()
        let store = makeStore()
        let badID = UUID()
        let healthyID = UUID()
        let laneZeroOwner = KanzenEngine(
            workerPool: pool,
            quarantineStore: store,
            timeouts: makeTimeouts()
        )
        let laneOneOwner = KanzenEngine(
            workerPool: pool,
            quarantineStore: store,
            timeouts: makeTimeouts()
        )
        let queuedLaneZeroController = KanzenEngine(
            workerPool: pool,
            quarantineStore: store,
            timeouts: makeTimeouts()
        )

        try await laneOneOwner.loadScript(
            "function searchResults() { return []; }",
            moduleID: UUID(),
            moduleName: "lane-one-benign"
        )
        let poisonLaneZero = Task {
            try await laneZeroOwner.loadScript(
                "while (true) {}",
                moduleID: badID,
                moduleName: "lane-zero-loop"
            )
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        let queuedLoad = Task {
            try await queuedLaneZeroController.loadScript(
                "function searchResults() { while (true) {} }",
                moduleID: healthyID,
                moduleName: "rehomed-controller"
            )
        }
        _ = await capturedError { try await poisonLaneZero.value }
        try await queuedLoad.value
        XCTAssertFalse(store.isQuarantined(moduleID: healthyID))
        XCTAssertEqual(pool.availableLaneCount, 1)

        _ = await capturedError {
            _ = try await queuedLaneZeroController.searchInput("now-hang")
        }
        XCTAssertTrue(store.isQuarantined(moduleID: healthyID))
        XCTAssertEqual(pool.availableLaneCount, 0)
        XCTAssertEqual(pool.physicalLaneCount, 2)

        let noThirdLane = KanzenEngine(
            workerPool: pool,
            quarantineStore: store,
            timeouts: makeTimeouts()
        )
        _ = await capturedError {
            try await noThirdLane.loadScript(
                "function searchResults() { return []; }",
                moduleID: UUID(),
                moduleName: "must-fail-closed"
            )
        }
        XCTAssertEqual(pool.physicalLaneCount, 2)
    }

    func testUnresolvedPromiseTimesOutWithoutQuarantineOrLaneLoss() async throws {
        let pool = KanzenLegacyJavaScriptWorkerPool()
        let store = makeStore()
        let moduleID = UUID()
        let engine = KanzenEngine(
            workerPool: pool,
            quarantineStore: store,
            timeouts: makeTimeouts()
        )
        try await engine.loadScript(
            "function searchResults() { return new Promise(function() {}); }",
            moduleID: moduleID,
            moduleName: "unresolved-promise"
        )
        _ = await capturedError {
            _ = try await engine.searchInput("pending")
        }
        XCTAssertFalse(store.isQuarantined(moduleID: moduleID))
        XCTAssertEqual(pool.availableLaneCount, 2)
    }

    func testOversizedLegacyResultIsRejectedBeforeFoundationFanout() async throws {
        let pool = KanzenLegacyJavaScriptWorkerPool()
        let store = makeStore()
        let moduleID = UUID()
        let engine = KanzenEngine(
            workerPool: pool,
            quarantineStore: store,
            timeouts: makeTimeouts()
        )
        try await engine.loadScript(
            "function searchResults() { return new Array(513).fill({title:'x', id:'y'}); }",
            moduleID: moduleID,
            moduleName: "oversized-result"
        )
        _ = await capturedError {
            _ = try await engine.searchInput("oversized")
        }
        XCTAssertFalse(store.isQuarantined(moduleID: moduleID))
        XCTAssertEqual(pool.availableLaneCount, 2)
    }

    func testFailedModuleRemovalCannotClearQuarantineBeforeMetadataIsDurable() {
        let store = makeStore()
        let moduleID = UUID()
        let identity = KanzenLegacyJavaScriptIdentity(
            moduleID: moduleID,
            script: "while (true) {}",
            moduleName: "removal-order"
        )
        store.recordNonYieldingBoundary(identity: identity, operation: "loadScript")

        XCTAssertFalse(
            store.clearAfterDurableModuleRemoval(
                moduleID: moduleID,
                metadataRemovalPersisted: false
            )
        )
        XCTAssertTrue(store.isQuarantined(moduleID: moduleID))

        XCTAssertTrue(
            store.clearAfterDurableModuleRemoval(
                moduleID: moduleID,
                metadataRemovalPersisted: true
            )
        )
        XCTAssertFalse(store.isQuarantined(moduleID: moduleID))
    }
}

final class KanzenCustomCatalogTests: XCTestCase {

    private var suiteNames: [String] = []

    private func makeStore() -> UserDefaults {
        let name = "KanzenCustomCatalogTests.\(UUID().uuidString)"
        suiteNames.append(name)
        guard let store = UserDefaults(suiteName: name) else {
            XCTFail("could not create an isolated defaults suite")
            return .standard
        }
        return store
    }

    private func makeManager() -> KanzenCustomCatalogManager {
        KanzenCustomCatalogManager(defaults: makeStore(), profileID: UUID())
    }

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func sourceID(_ seed: String) -> ReaderExtensionSourceID {
        ReaderExtensionSourceID(rawValue: String(String(repeating: seed, count: 64).prefix(64)))
    }

    private func sortFilter(
        selectedIndex: Int,
        ascending: Bool,
        declaredIndex: Int = 0,
        declaredAscending: Bool = false
    ) -> ReaderExtensionFilter {
        ReaderExtensionFilter(
            key: "sort",
            title: "Sort",
            kind: .sort,
            options: [
                ReaderExtensionFilterOption(label: "Best Match", value: "desc"),
                ReaderExtensionFilterOption(
                    label: "Popularity",
                    value: "desc",
                    abiExtras: ["param": .string("rating")]
                ),
                ReaderExtensionFilterOption(label: "Newest", value: "desc")
            ],
            value: .string("desc"),
            abiType: "SortFilter",
            abiState: .object([
                "index": .number(Double(declaredIndex)),
                "ascending": .bool(declaredAscending)
            ]),
            sortAscending: ascending,
            selectedOptionIndex: selectedIndex
        )
    }

    private func genreGroup(action: Double, ecchi: Double) -> ReaderExtensionFilter {
        ReaderExtensionFilter(
            key: "genres",
            title: "Genres",
            kind: .group,
            options: [],
            value: .stringList([]),
            children: [
                ReaderExtensionFilter(
                    key: "genre-action",
                    title: "Action",
                    kind: .triState,
                    options: [],
                    value: .number(action)
                ),
                ReaderExtensionFilter(
                    key: "genre-ecchi",
                    title: "Ecchi",
                    kind: .triState,
                    options: [],
                    value: .number(ecchi)
                )
            ]
        )
    }

    func testDigestDescribesEverySelectedFilterAndSkipsDeclaredDefaults() {
        let filters = [
            sortFilter(selectedIndex: 1, ascending: false, declaredIndex: 0),
            genreGroup(action: 1, ecchi: 2),
            ReaderExtensionFilter(
                key: "author",
                title: "Author",
                kind: .text,
                options: [],
                value: .string(" Oda ")
            ),
            ReaderExtensionFilter(
                key: "completed",
                title: "Completed",
                kind: .toggle,
                options: [],
                value: .bool(true)
            ),
            ReaderExtensionFilter(
                key: "status",
                title: "Status",
                kind: .select,
                options: [
                    ReaderExtensionFilterOption(label: "Any", value: "any"),
                    ReaderExtensionFilterOption(label: "Ongoing", value: "ongoing")
                ],
                value: .string("any"),
                abiState: .number(0),
                selectedOptionIndex: 0
            )
        ]

        let digest = KanzenCustomCatalog.digest(query: "  pirates ", filters: filters)

        XCTAssertEqual(digest.query, "pirates")
        XCTAssertEqual(digest.selections.map(\.label), ["Popularity \u{2193}"])
        XCTAssertEqual(
            digest.selections.map(\.title),
            ["Sort"],
            "a select still sitting on the state the extension declared is not a user choice and must not be described"
        )
        XCTAssertEqual(digest.included, ["Action", "Completed"])
        XCTAssertEqual(digest.excluded, ["Ecchi"])
        XCTAssertEqual(digest.texts.map(\.label), ["Oda"])

        let catalog = KanzenCustomCatalog(
            title: "",
            sourceID: sourceID("a"),
            query: "pirates",
            filters: filters
        )
        XCTAssertTrue(catalog.summary.contains("Exclude Ecchi"))
        XCTAssertTrue(catalog.summary.contains("Include Action, Completed"))
    }

    func testSortStillCountsWhenOnlyItsDirectionMovedAwayFromTheDeclaredState() {
        let digest = KanzenCustomCatalog.digest(
            query: "",
            filters: [sortFilter(selectedIndex: 0, ascending: true, declaredIndex: 0, declaredAscending: false)]
        )
        XCTAssertEqual(digest.selections.map(\.label), ["Best Match \u{2191}"])
    }

    func testUnrepresentableProviderSortStateIsNotTreatedAsTheDeclaredDefault() {
        var filter = sortFilter(selectedIndex: 0, ascending: false)
        filter.abiState = .object([
            "index": .number(Double.greatestFiniteMagnitude),
            "ascending": .bool(false)
        ])

        let digest = KanzenCustomCatalog.digest(query: "", filters: [filter])

        XCTAssertEqual(digest.selections.map(\.label), ["Best Match \u{2193}"])
    }

    func testSuggestedTitlePrefersIncludedTagsThenSortThenQuery() {
        XCTAssertEqual(
            KanzenCustomCatalog.suggestedTitle(
                query: "pirates",
                filters: [sortFilter(selectedIndex: 1, ascending: false), genreGroup(action: 1, ecchi: 0)]
            ),
            "Action"
        )
        XCTAssertEqual(
            KanzenCustomCatalog.suggestedTitle(
                query: "pirates",
                filters: [sortFilter(selectedIndex: 1, ascending: false)]
            ),
            "Popularity \u{2193}"
        )
        XCTAssertEqual(KanzenCustomCatalog.suggestedTitle(query: "pirates", filters: []), "pirates")
        XCTAssertEqual(KanzenCustomCatalog.suggestedTitle(query: "", filters: []), "New Catalog")
    }

    func testAnUnnamedCatalogFallsBackToItsSuggestedTitle() {
        let catalog = KanzenCustomCatalog(
            title: "   ",
            sourceID: sourceID("b"),
            query: "",
            filters: [genreGroup(action: 1, ecchi: 0)]
        )
        XCTAssertEqual(catalog.displayTitle, "Action")
    }

    func testSavedCatalogRoundTripsEveryFilterFieldThroughStorage() throws {
        let store = makeStore()
        let profileID = UUID()
        let manager = KanzenCustomCatalogManager(defaults: store, profileID: profileID)
        let source = sourceID("c")

        try manager.save(
            KanzenCustomCatalog(
                title: "Top Rated",
                sourceID: source,
                query: "pirates",
                filters: [sortFilter(selectedIndex: 1, ascending: false), genreGroup(action: 1, ecchi: 2)]
            )
        )

        let reloaded = KanzenCustomCatalogManager(defaults: store, profileID: profileID)
        let restored = try XCTUnwrap(reloaded.catalogs(for: source).first)

        XCTAssertEqual(restored.title, "Top Rated")
        XCTAssertEqual(restored.query, "pirates")
        let sort = try XCTUnwrap(restored.filters.first)
        XCTAssertEqual(
            sort.selectedOptionIndex,
            1,
            "the positional selection is the only thing that distinguishes options sharing a value string"
        )
        XCTAssertEqual(sort.sortAscending, false)
        XCTAssertEqual(
            sort.options[1].abiExtras?["param"],
            .string("rating"),
            "option-level provider fields must survive persistence or a saved catalog searches differently than the search that made it"
        )
        XCTAssertEqual(restored.filters.last?.children.map(\.value), [.number(1), .number(2)])
    }

    func testPerSourceLimitIsEnforcedWithoutBlockingOtherSources() throws {
        let manager = makeManager()
        let crowded = sourceID("d")
        let spare = sourceID("e")

        for index in 0..<KanzenCustomCatalogManager.maximumCatalogsPerSource {
            try manager.save(
                KanzenCustomCatalog(title: "Row \(index)", sourceID: crowded, query: "", filters: [])
            )
        }
        XCTAssertFalse(manager.canAddCatalog(for: crowded))
        XCTAssertThrowsError(
            try manager.save(KanzenCustomCatalog(title: "Overflow", sourceID: crowded, query: "", filters: []))
        ) { error in
            XCTAssertEqual(
                error as? KanzenCustomCatalogError,
                .sourceLimitReached(KanzenCustomCatalogManager.maximumCatalogsPerSource)
            )
        }

        XCTAssertTrue(manager.canAddCatalog(for: spare))
        try manager.save(KanzenCustomCatalog(title: "Elsewhere", sourceID: spare, query: "", filters: []))
        XCTAssertEqual(manager.catalogs(for: spare).count, 1)
        XCTAssertEqual(manager.catalogs(for: crowded).count, KanzenCustomCatalogManager.maximumCatalogsPerSource)
    }

    func testResavingAnExistingCatalogUpdatesInPlaceAndKeepsItsPosition() throws {
        let manager = makeManager()
        let source = sourceID("f")
        let first = try manager.save(
            KanzenCustomCatalog(title: "First", sourceID: source, query: "", filters: [])
        )
        try manager.save(KanzenCustomCatalog(title: "Second", sourceID: source, query: "", filters: []))

        var renamed = first
        renamed.title = "Renamed"
        try manager.save(renamed)

        XCTAssertEqual(manager.catalogs(for: source).map(\.title), ["Renamed", "Second"])
        XCTAssertEqual(manager.catalogs(for: source).count, 2)
    }

    func testMoveReordersOnlyTheTargetSource() throws {
        let manager = makeManager()
        let moved = sourceID("1")
        let untouched = sourceID("2")

        for title in ["A", "B", "C"] {
            try manager.save(KanzenCustomCatalog(title: title, sourceID: moved, query: "", filters: []))
        }
        for title in ["X", "Y"] {
            try manager.save(KanzenCustomCatalog(title: title, sourceID: untouched, query: "", filters: []))
        }

        manager.move(from: IndexSet(integer: 2), to: 0, within: moved)

        XCTAssertEqual(manager.catalogs(for: moved).map(\.title), ["C", "A", "B"])
        XCTAssertEqual(manager.catalogs(for: untouched).map(\.title), ["X", "Y"])
    }

    func testDisablingACatalogKeepsItStoredButOutOfTheHomeFeed() throws {
        let manager = makeManager()
        let source = sourceID("3")
        let catalog = try manager.save(
            KanzenCustomCatalog(title: "Hidden", sourceID: source, query: "", filters: [])
        )

        manager.setEnabled(false, id: catalog.id)
        XCTAssertEqual(manager.catalogs(for: source).count, 1)
        XCTAssertTrue(manager.enabledCatalogs(for: source).isEmpty)

        manager.setEnabled(true, id: catalog.id)
        XCTAssertEqual(manager.enabledCatalogs(for: source).count, 1)
    }

    func testUnreadableStoreIsQuarantinedRatherThanSilentlyOverwritten() throws {
        let store = makeStore()
        let profileID = UUID()
        let key = KanzenCustomCatalogManager.storageKey(for: profileID)
        let corrupt = Data("not a catalog list".utf8)
        store.set(corrupt, forKey: key)

        let manager = KanzenCustomCatalogManager(defaults: store, profileID: profileID)
        XCTAssertTrue(manager.catalogs.isEmpty)
        XCTAssertNil(store.data(forKey: key))

        let quarantined = store.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("\(key)-unreadable-")
        }
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertEqual(store.data(forKey: try XCTUnwrap(quarantined.first)), corrupt)
    }

    func testDiscardingAnotherProfileNeverTouchesTheActiveStore() throws {
        let store = makeStore()
        let active = UUID()
        let other = UUID()
        let manager = KanzenCustomCatalogManager(defaults: store, profileID: active)
        try manager.save(KanzenCustomCatalog(title: "Mine", sourceID: sourceID("4"), query: "", filters: []))

        let otherProfile = KanzenCustomCatalogManager(defaults: store, profileID: other)
        try otherProfile.save(
            KanzenCustomCatalog(title: "Theirs", sourceID: sourceID("5"), query: "", filters: [])
        )
        XCTAssertNotNil(store.data(forKey: KanzenCustomCatalogManager.storageKey(for: other)))

        manager.discardStore(forProfile: other)
        XCTAssertNil(store.data(forKey: KanzenCustomCatalogManager.storageKey(for: other)))
        XCTAssertEqual(manager.catalogs.map(\.title), ["Mine"])

        manager.discardStore(forProfile: active)
        XCTAssertNotNil(
            store.data(forKey: KanzenCustomCatalogManager.storageKey(for: active)),
            "the active profile's own catalogs must never be reclaimed as a foreign store"
        )
    }

    func testSwitchingProfilesSwapsTheVisibleCatalogSet() throws {
        let store = makeStore()
        let first = UUID()
        let second = UUID()
        let manager = KanzenCustomCatalogManager(defaults: store, profileID: first)
        try manager.save(KanzenCustomCatalog(title: "First profile", sourceID: sourceID("6"), query: "", filters: []))

        manager.switchProfile(to: second)
        XCTAssertTrue(manager.catalogs.isEmpty)
        try manager.save(KanzenCustomCatalog(title: "Second profile", sourceID: sourceID("6"), query: "", filters: []))

        manager.switchProfile(to: first)
        XCTAssertEqual(manager.catalogs.map(\.title), ["First profile"])
    }

    @MainActor
    func testHomeSectionDispatchesTheSavedQueryAndFiltersVerbatim() async throws {
        let source = try installedSource()
        let provider = RecordingCatalogProvider(source: source)
        let catalog = KanzenCustomCatalog(
            title: "Top Rated",
            sourceID: source.id,
            query: "pirates",
            filters: [sortFilter(selectedIndex: 1, ascending: false), genreGroup(action: 1, ecchi: 2)]
        )

        let section = await MangaHomeViewModel.customCatalogSection(
            provider: provider,
            sourceID: source.id,
            catalog: catalog
        )

        XCTAssertEqual(provider.recordedQueries, ["pirates"])
        XCTAssertEqual(provider.recordedPages, [1])
        XCTAssertEqual(
            provider.recordedFilters.first,
            catalog.filters,
            "the home feed must hand the provider exactly the filter tree the user saved"
        )
        XCTAssertEqual(section.title, "Top Rated")
        XCTAssertEqual(section.id, catalog.sectionID)
        XCTAssertEqual(section.items.count, 2)
        XCTAssertNil(section.placeholderMessage)
        XCTAssertEqual(
            section.readerExtensionQuery,
            .search(query: "pirates", filters: catalog.filters),
            "paging the expanded catalog has to repeat the same query, not a bare popular call"
        )
    }

    @MainActor
    func testAnEmptyOrFailingCatalogStillPublishesARowThatSaysSo() async throws {
        let source = try installedSource()
        let catalog = KanzenCustomCatalog(
            title: "Quiet",
            sourceID: source.id,
            query: "",
            filters: []
        )

        let empty = RecordingCatalogProvider(source: source, itemCount: 0)
        let emptySection = await MangaHomeViewModel.customCatalogSection(
            provider: empty,
            sourceID: source.id,
            catalog: catalog
        )
        XCTAssertTrue(emptySection.items.isEmpty)
        XCTAssertNotNil(
            emptySection.placeholderMessage,
            "a row the user asked for by name must not silently vanish when it returns nothing"
        )

        let failing = RecordingCatalogProvider(source: source, failure: ReaderExtensionError.sourceNotFound)
        let failedSection = await MangaHomeViewModel.customCatalogSection(
            provider: failing,
            sourceID: source.id,
            catalog: catalog
        )
        XCTAssertTrue(failedSection.items.isEmpty)
        XCTAssertEqual(
            failedSection.placeholderMessage,
            ReaderExtensionError.sourceNotFound.localizedDescription
        )
    }

    private func installedSource() throws -> ReaderExtensionInstalledSource {
        let repositoryURL = try XCTUnwrap(URL(string: "https://m2k3a.github.io/mangayomi-extensions/index.json"))
        let base = try XCTUnwrap(URL(string: "https://weebcentral.com"))
        let catalog = ReaderExtensionCatalogSource(
            id: ReaderExtensionSourceID(
                repositoryURL: repositoryURL,
                upstreamID: "custom-catalog-tests",
                language: "en",
                mediaType: .manga
            ),
            upstreamID: "custom-catalog-tests",
            repositoryID: "custom-catalog-tests",
            repositoryURL: repositoryURL,
            name: "Catalog Source",
            baseURL: base,
            apiURL: nil,
            language: "en",
            mediaType: .manga,
            implementation: .javascript,
            sourceCodeURL: nil,
            version: "1.0.0",
            maturity: .safe,
            hasCloudflare: false,
            dateFormat: nil,
            dateFormatLocale: nil,
            additionalParameters: nil,
            notes: nil,
            license: ReaderExtensionLicense(kind: .mit, name: "MIT License", url: nil, textSHA256: nil, detectedAt: Date())
        )
        return ReaderExtensionInstalledSource(catalog: catalog, sortIndex: 0)
    }
}

private final class RecordingCatalogProvider: ReaderSourceProvider {
    let source: ReaderExtensionInstalledSource

    private(set) var recordedQueries: [String] = []
    private(set) var recordedPages: [Int] = []
    private(set) var recordedFilters: [[ReaderExtensionFilter]] = []

    private let itemCount: Int
    private let failure: Error?

    init(source: ReaderExtensionInstalledSource, itemCount: Int = 2, failure: Error? = nil) {
        self.source = source
        self.itemCount = itemCount
        self.failure = failure
    }

    func popular(page: Int) async throws -> ReaderExtensionPagedResult {
        throw ReaderExtensionError.unsupportedSource
    }

    func latest(page: Int) async throws -> ReaderExtensionPagedResult {
        throw ReaderExtensionError.unsupportedSource
    }

    func search(query: String, page: Int, filters: [ReaderExtensionFilter]) async throws -> ReaderExtensionPagedResult {
        recordedQueries.append(query)
        recordedPages.append(page)
        recordedFilters.append(filters)
        if let failure { throw failure }
        let items = (0..<itemCount).map {
            ReaderExtensionItem(key: "item-\($0)", title: "Item \($0)")
        }
        return ReaderExtensionPagedResult(items: items, hasNextPage: true)
    }

    func detail(itemKey: String) async throws -> ReaderExtensionItem {
        throw ReaderExtensionError.unsupportedSource
    }

    func chapters(itemKey: String) async throws -> [ReaderExtensionChapter] {
        throw ReaderExtensionError.unsupportedSource
    }

    func pages(chapterKey: String) async throws -> [ReaderExtensionPage] {
        throw ReaderExtensionError.unsupportedSource
    }

    func chapterHTML(chapterKey: String, chapterTitle: String) async throws -> String {
        throw ReaderExtensionError.unsupportedSource
    }

    func resourceHeaders() async throws -> [String: String] { [:] }

    func filters() async throws -> [ReaderExtensionFilter] { [] }

    func preferences() async throws -> [ReaderExtensionPreference] { [] }
}

#endif
