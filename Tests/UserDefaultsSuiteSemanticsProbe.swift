import XCTest

#if os(iOS)

final class UserDefaultsSuiteSemanticsProbe: XCTestCase {
    private var runID = ""
    private var suiteName = ""
    private var suite: UserDefaults!

    private var inheritanceKey: String { "probe.\(runID).inheritance" }
    private var registrationKey: String { "probe.\(runID).registration" }
    private var removalKey: String { "probe.\(runID).removal" }

    override func setUp() {
        super.setUp()
        runID = UUID().uuidString

        let bundleID = Bundle.main.bundleIdentifier ?? "app.Eclipse"
        suiteName = "\(bundleID).profile.\(runID)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        for key in [inheritanceKey, registrationKey, removalKey] {
            UserDefaults.standard.removeObject(forKey: key)
            suite?.removeObject(forKey: key)
        }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        suite = nil
        super.tearDown()
    }

    func testSuiteIsolationRegistrationSharingAndResetFallback() throws {
        let suite = try XCTUnwrap(self.suite, "UserDefaults(suiteName:) returned nil")

        UserDefaults.standard.set("from-standard", forKey: inheritanceKey)
        let inherited = suite.string(forKey: inheritanceKey)

        UserDefaults.standard.register(defaults: [registrationKey: "from-registration"])
        let registrationViaStandard = UserDefaults.standard.string(forKey: registrationKey)
        let registrationViaSuite = suite.string(forKey: registrationKey)

        UserDefaults.standard.set("standard-value", forKey: removalKey)
        UserDefaults.standard.register(defaults: [removalKey: "registered-value"])
        suite.set("suite-value", forKey: removalKey)
        let beforeRemoval = suite.string(forKey: removalKey)
        suite.removeObject(forKey: removalKey)
        let afterRemoval = suite.string(forKey: removalKey)

        print("""

        ===== PHASE 0a: UserDefaults suite semantics =====
        suiteName: \(suiteName)

        (1) app-domain inheritance
            wrote "from-standard" to .standard only
            suite.string(forKey:) -> \(inherited.map { "\"\($0)\"" } ?? "nil")
            => fresh profile \(inherited == nil ? "does NOT inherit" : "DOES inherit") primary-profile settings

        (2) registration-domain sharing
            registered "from-registration" on .standard
            .standard -> \(registrationViaStandard.map { "\"\($0)\"" } ?? "nil")
            suite     -> \(registrationViaSuite.map { "\"\($0)\"" } ?? "nil")
            => registration is \(registrationViaSuite == nil ? "NOT shared (per-suite re-registration REQUIRED)" : "shared (no per-suite re-registration needed)")

        (3) removeObject on the suite
            suite value before removal -> \(beforeRemoval.map { "\"\($0)\"" } ?? "nil")
            suite value after  removal -> \(afterRemoval.map { "\"\($0)\"" } ?? "nil")
            (.standard held "standard-value", registration held "registered-value")
        =================================================

        """)

        XCTAssertNil(
            inherited,
            "A suite must not inherit the app's own persistent domain"
        )

        XCTAssertEqual(registrationViaStandard, "from-registration")
        XCTAssertEqual(
            registrationViaSuite, "from-registration",
            "A registration default set on .standard must be visible through a suite"
        )

        XCTAssertEqual(beforeRemoval, "suite-value")
        XCTAssertEqual(
            afterRemoval, "registered-value",
            "removeObject on a suite must fall back to the registration domain"
        )
    }
}
#endif
