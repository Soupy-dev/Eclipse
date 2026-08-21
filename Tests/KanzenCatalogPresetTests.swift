import XCTest
@testable import Eclipse

#if os(iOS)

/// Resolves the built-in catalog presets against the real published filter
/// trees of the five most-used sources. A preset that silently resolves to the
/// wrong node produces a row titled "Horror" full of unfiltered results, and a
/// preset that mutates only `value` on a select picks whichever option happens
/// to share that value string — Comix declares nine sorts over two of them.
final class KanzenCatalogPresetTests: XCTestCase {

    // MARK: - Genre presets

    // MARK: - Sort presets

    // MARK: - Genre index widget

    func testASourceWithNoGenreAxisResolvesNoGenrePresetsAtAll() {
        let filters = [
            ReaderExtensionFilter(
                key: "query",
                title: "Keyword",
                kind: .text,
                options: [],
                value: .string("")
            )
        ]

        XCTAssertNil(KanzenCatalogPresetResolver.resolution(for: .genreIndex, against: filters))
        XCTAssertTrue(KanzenCatalogPresetResolver.genreOptions(in: filters).isEmpty)
        XCTAssertTrue(
            KanzenCatalogPresetResolver.resolutions(against: filters, builtInRows: .none).isEmpty
        )
        XCTAssertTrue(
            KanzenCatalogPresetResolver.resolutions(against: [], builtInRows: .none).isEmpty
        )
    }

    // MARK: - Suggestions never restate a row the home feed already builds

    private static let everyBuiltInRow = KanzenCatalogBuiltInRows(
        publishesPopular: true,
        publishesLatestUpdates: true
    )

    func testASuggestionIsWithheldOnlyWhenEvenTheSourcesOwnLabelCollides() throws {
        let sort = ReaderExtensionFilter(
            key: "sort",
            title: "Sort",
            kind: .select,
            options: [
                ReaderExtensionFilterOption(label: "Popular", value: "popular"),
                ReaderExtensionFilterOption(label: "Alphabetical", value: "az")
            ],
            value: .string("az")
        )
        let preset = try XCTUnwrap(KanzenCatalogPreset.preset(id: "sort.popular"))

        XCTAssertNotNil(
            KanzenCatalogPresetResolver.resolution(
                for: preset,
                against: [sort],
                builtInRows: .none
            )
        )
        XCTAssertNil(
            KanzenCatalogPresetResolver.resolution(
                for: preset,
                against: [sort],
                builtInRows: Self.everyBuiltInRow
            ),
            "when the source's own label is also \u{201C}Popular\u{201D} there is nothing left to tell the rows apart"
        )
    }

    func testOnlyTheRowsASourceActuallyPublishesClaimTheirTitles() {
        XCTAssertFalse(KanzenCatalogBuiltInRows.none.claimsTitle("Popular"))
        XCTAssertFalse(KanzenCatalogBuiltInRows.none.claimsTitle("Latest Updates"))

        let popularOnly = KanzenCatalogBuiltInRows(
            publishesPopular: true,
            publishesLatestUpdates: false
        )
        XCTAssertTrue(popularOnly.claimsTitle("Popular"))
        XCTAssertTrue(popularOnly.claimsTitle("popular"))
        XCTAssertFalse(popularOnly.claimsTitle("Latest Updates"))
        XCTAssertFalse(popularOnly.claimsTitle("Popularity"))
    }

    // MARK: - Presets stay off until the user asks for them

    // MARK: - Old stored catalogs still decode

    func testCatalogsPersistedBeforeDisplayStyleAndPresetIDStillDecode() throws {
        let json = """
        [
          {
            "id": "11111111-2222-3333-4444-555555555555",
            "title": "Top Rated",
            "sourceID": "\(String(repeating: "a", count: 64))",
            "query": "pirates",
            "filters": [
              {
                "key": "sort",
                "title": "Sort",
                "kind": "sort",
                "options": [
                  { "label": "Rating", "value": "desc" },
                  { "label": "Newest", "value": "desc" }
                ],
                "value": { "type": "string", "string": "desc" },
                "selectedOptionIndex": 1,
                "sortAscending": false,
                "children": []
              }
            ],
            "isEnabled": true,
            "order": 4
          }
        ]
        """

        let decoded = try JSONDecoder().decode([KanzenCustomCatalog].self, from: Data(json.utf8))
        let catalog = try XCTUnwrap(decoded.first)

        XCTAssertEqual(catalog.title, "Top Rated")
        XCTAssertEqual(catalog.query, "pirates")
        XCTAssertEqual(catalog.order, 4)
        XCTAssertTrue(catalog.isEnabled)
        XCTAssertEqual(
            catalog.displayStyle,
            .poster,
            "an existing catalog has to keep rendering exactly as it did before presets existed"
        )
        XCTAssertNil(catalog.presetID)
        XCTAssertFalse(catalog.isPreset)
        XCTAssertEqual(catalog.filters.first?.selectedOptionIndex, 1)
        XCTAssertEqual(catalog.filters.first?.sortAscending, false)
    }

    func testAnOldStoreLoadsThroughTheManagerRatherThanBeingQuarantined() throws {
        let store = makeStore()
        let profileID = UUID()
        let json = """
        [
          {
            "id": "11111111-2222-3333-4444-555555555555",
            "title": "Legacy",
            "sourceID": "\(String(repeating: "b", count: 64))",
            "query": "",
            "filters": [],
            "isEnabled": false,
            "order": 2
          }
        ]
        """
        let key = KanzenCustomCatalogManager.storageKey(for: profileID)
        store.set(Data(json.utf8), forKey: key)

        let manager = KanzenCustomCatalogManager(defaults: store, profileID: profileID)
        XCTAssertEqual(manager.catalogs.map(\.title), ["Legacy"])
        XCTAssertEqual(manager.catalogs.first?.displayStyle, .poster)
        XCTAssertNotNil(store.data(forKey: key), "the store must not have been quarantined")
        XCTAssertTrue(
            store.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("\(key)-unreadable-") },
            "adding a field must not make every previously stored catalog unreadable"
        )
    }

    func testAnUnknownDisplayStyleDegradesToPosterInsteadOfLosingTheWholeStore() throws {
        let json = """
        [
          {
            "id": "11111111-2222-3333-4444-555555555555",
            "title": "From the future",
            "sourceID": "\(String(repeating: "c", count: 64))",
            "query": "",
            "filters": [],
            "isEnabled": true,
            "order": 0,
            "displayStyle": "carousel",
            "presetID": "genre.action"
          }
        ]
        """

        let decoded = try JSONDecoder().decode([KanzenCustomCatalog].self, from: Data(json.utf8))
        let catalog = try XCTUnwrap(decoded.first)
        XCTAssertEqual(catalog.displayStyle, .poster)
        XCTAssertEqual(catalog.presetID, "genre.action")
    }

    func testTheNewFieldsSurviveTheirOwnRoundTrip() throws {
        let catalog = KanzenCustomCatalog(
            title: "Genres",
            sourceID: sourceID("d"),
            query: "",
            filters: [],
            displayStyle: .genres,
            presetID: KanzenCatalogPreset.genreIndex.id
        )

        let data = try JSONEncoder().encode([catalog])
        let decoded = try XCTUnwrap(try JSONDecoder().decode([KanzenCustomCatalog].self, from: data).first)

        XCTAssertEqual(decoded, catalog)
        XCTAssertEqual(decoded.displayStyle, .genres)
        XCTAssertEqual(decoded.presetID, "widget.genres")
    }

    func testEveryBuiltInPresetHasAStableUniqueIdentifier() {
        let ids = KanzenCatalogPreset.builtIn.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "preset identifiers are persisted, so they must be unique")
        for id in ids {
            XCTAssertEqual(KanzenCatalogPreset.preset(id: id)?.id, id)
        }
        XCTAssertNil(KanzenCatalogPreset.preset(id: "genre.does-not-exist"))
        XCTAssertGreaterThanOrEqual(KanzenCatalogPreset.genrePresets.count, 12)
        XCTAssertGreaterThanOrEqual(KanzenCatalogPreset.sortPresets.count, 5)
    }

    // MARK: - Helpers

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeStore() -> UserDefaults {
        let name = "KanzenCatalogPresetTests.\(UUID().uuidString)"
        suiteNames.append(name)
        guard let store = UserDefaults(suiteName: name) else {
            XCTFail("could not create an isolated defaults suite")
            return .standard
        }
        return store
    }

    private func sourceID(_ seed: String) -> ReaderExtensionSourceID {
        ReaderExtensionSourceID(rawValue: String(String(repeating: seed, count: 64).prefix(64)))
    }

    private static func matchesAnyTerm(_ label: String, of preset: KanzenCatalogPreset) -> Bool {
        let normalizedLabel = KanzenCatalogPresetResolver.normalized(label)
        for term in preset.searchTerms {
            let normalizedTerm = KanzenCatalogPresetResolver.normalized(term)
            if normalizedLabel == normalizedTerm { return true }
            if normalizedLabel == normalizedTerm + "s" { return true }
            if normalizedTerm == normalizedLabel + "s" { return true }
        }
        return false
    }
}

#endif
