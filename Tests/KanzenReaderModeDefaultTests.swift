import XCTest
@testable import Eclipse

#if os(iOS)

final class KanzenReaderModeDefaultTests: XCTestCase {

    private var suiteNames: [String] = []

    private func makeStore() -> UserDefaults {
        let name = "KanzenReaderModeDefaultTests.\(UUID().uuidString)"
        suiteNames.append(name)
        guard let store = UserDefaults(suiteName: name) else {
            XCTFail("could not create an isolated defaults suite")
            return .standard
        }
        return store
    }

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    func testFreshProfileReadsAsContinuousScrollRatherThanLeftToRight() {
        let empty = makeStore()
        let resolution = KanzenReaderMode.resolveDefault(
            scopedKey: "kanzenReaderMode",
            stores: [empty]
        )
        XCTAssertEqual(
            resolution.mode,
            .webtoon,
            "an absent reading mode must not resolve through integer(forKey:) == 0 to LTR paging"
        )
        XCTAssertFalse(
            resolution.recoveredStoredPreference,
            "an unresolved default must never be persisted as if it were the user's choice"
        )
    }

    func testExplicitlyStoredLegacyModesStillResolve() {
        let cases: [(Int, KanzenReaderMode)] = [
            (ReadingMode.LTR.rawValue, .ltr),
            (ReadingMode.RTL.rawValue, .rtl),
            (ReadingMode.WEBTOON.rawValue, .webtoon),
            (ReadingMode.VERTICAL.rawValue, .vertical)
        ]
        for (raw, expected) in cases {
            let store = makeStore()
            store.set(raw, forKey: "readingMode")
            let resolution = KanzenReaderMode.resolveDefault(
                scopedKey: "kanzenReaderMode",
                stores: [store]
            )
            XCTAssertEqual(resolution.mode, expected, "legacy readingMode \(raw) did not round-trip")
            XCTAssertTrue(resolution.recoveredStoredPreference)
        }
    }

    func testDeviceLevelPreferenceSurvivesTheMoveToProfileScopedStorage() {
        let profile = makeStore()
        let device = makeStore()
        device.set(KanzenReaderMode.rtl.rawValue, forKey: "kanzenReaderMode")

        let resolution = KanzenReaderMode.resolveDefault(
            scopedKey: "kanzenReaderMode",
            stores: [profile, device]
        )
        XCTAssertEqual(
            resolution.mode,
            .rtl,
            "a preference written before reader mode became profile-scoped must still be found"
        )
        XCTAssertTrue(resolution.recoveredStoredPreference)
    }

    func testProfileValueWinsOverDeviceValue() {
        let profile = makeStore()
        let device = makeStore()
        profile.set(KanzenReaderMode.webtoon.rawValue, forKey: "kanzenReaderMode")
        device.set(KanzenReaderMode.ltr.rawValue, forKey: "kanzenReaderMode")

        XCTAssertEqual(
            KanzenReaderMode.resolveDefault(scopedKey: "kanzenReaderMode", stores: [profile, device]).mode,
            .webtoon
        )
    }

    func testPerSeriesOverrideBeatsTheGlobalPreference() {
        let profile = makeStore()
        profile.set(KanzenReaderMode.webtoon.rawValue, forKey: "kanzenReaderMode")
        profile.set(KanzenReaderMode.rtl.rawValue, forKey: "kanzenReaderMode.series-42")

        let resolution = KanzenReaderMode.resolveDefault(
            scopedKey: "kanzenReaderMode.series-42",
            stores: [profile]
        )
        XCTAssertEqual(resolution.mode, .rtl)
        XCTAssertFalse(
            resolution.recoveredStoredPreference,
            "a per-series override must not be copied onto the global preference"
        )
    }

    func testManufacturedLeftToRightIsRecognizedAndDeliberateChoicesAreNot() {
        let poisoned = makeStore()
        poisoned.set(KanzenReaderMode.ltr.rawValue, forKey: "kanzenReaderMode")
        XCTAssertTrue(
            KanzenReaderMode.storedGlobalDefaultIsManufactured(in: poisoned),
            "kanzenReaderMode=ltr with no readingMode is the pre-fix default path's fingerprint"
        )

        let deliberate = makeStore()
        deliberate.set(KanzenReaderMode.ltr.rawValue, forKey: "kanzenReaderMode")
        deliberate.set(ReadingMode.LTR.rawValue, forKey: "readingMode")
        XCTAssertFalse(
            KanzenReaderMode.storedGlobalDefaultIsManufactured(in: deliberate),
            "a real selection writes both keys and must never be discarded"
        )

        for mode in [KanzenReaderMode.rtl, .webtoon, .vertical] {
            let other = makeStore()
            other.set(mode.rawValue, forKey: "kanzenReaderMode")
            XCTAssertFalse(
                KanzenReaderMode.storedGlobalDefaultIsManufactured(in: other),
                "the pre-fix path could not manufacture \(mode.rawValue) with readingMode absent"
            )
        }

        let untouched = makeStore()
        XCTAssertFalse(KanzenReaderMode.storedGlobalDefaultIsManufactured(in: untouched))
    }

    func testUnrecognizedStoredValuesFallBackToTheBuiltInDefault() {
        let store = makeStore()
        store.set("sideways", forKey: "kanzenReaderMode")
        store.set(99, forKey: "readingMode")

        XCTAssertEqual(
            KanzenReaderMode.resolveDefault(scopedKey: "kanzenReaderMode", stores: [store]).mode,
            KanzenReaderMode.builtInDefault
        )
    }
}

#endif
