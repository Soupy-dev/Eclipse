import XCTest

final class EclipseTVRemoteSmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITesting"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20))
    }

    func testAllFiveStreamingTabsAreRemoteAccessible() {
        let expectedTabs = ["Home", "Schedule", "Library", "Search", "Settings"]

        for (index, title) in expectedTabs.enumerated() {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.exists, "Missing tvOS tab: \(title)")
            activateTab(at: index, title: title)
        }

        XCTAssertFalse(app.tabBars.buttons["Downloads"].exists)
        XCTAssertFalse(app.tabBars.buttons["Reader"].exists)
    }

    func testSearchSurvivesRemoteKeyboardCancellation() {
        activateTab(at: 3, title: "Search")

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        focusSearchField(searchField)
        XCUIRemote.shared.press(.select)
        searchField.typeText("Dune")
        XCUIRemote.shared.press(.menu)

        XCTAssertTrue(app.tabBars.buttons["Search"].exists)
        XCTAssertTrue(searchField.exists)
    }

    func testRemoteCanMoveBetweenTabFocusAndOpenSettings() {
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        activateTab(at: 4, title: "Settings")

        XCTAssertTrue(app.staticTexts["TMDB SETTINGS"].waitForExistence(timeout: 10))
    }

    func testCatalogReorderControlIsFocusableAndBackRestoresSettingsFocus() {
        activateTab(at: 4, title: "Settings")

        let catalogsLink = cell(containingIdentifier: "tv.settings.catalogs")
        moveFocusVertically(to: catalogsLink, direction: .down, maximumPresses: 16)
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            element(identifier: "tv.settings.catalogs.screen").waitForExistence(timeout: 10),
            "Catalog settings did not open"
        )

        let moveDown = firstEnabledButton(identifierSuffix: ".moveDown")
        XCTAssertTrue(moveDown.exists, "Catalogs must expose at least one enabled Move Down control")
        moveFocusHorizontally(to: moveDown, direction: .right, maximumPresses: 4)

        XCUIRemote.shared.press(.menu)
        assertEventuallyFocused(catalogsLink, message: "Back did not restore focus to the Catalogs row")
    }

    func testNestedAppearanceBackRestoresFocusAtEachLevel() {
        activateTab(at: 4, title: "Settings")

        let appearanceLink = cell(containingIdentifier: "tv.settings.appearance")
        moveFocusVertically(to: appearanceLink, direction: .down, maximumPresses: 14)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            element(identifier: "tv.settings.appearance.screen").waitForExistence(timeout: 10),
            "Appearance settings did not open"
        )

        let homeLayoutLink = cell(containingIdentifier: "tv.appearance.homeLayout")
        moveFocusVertically(to: homeLayoutLink, direction: .down, maximumPresses: 18)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            element(identifier: "tv.appearance.homeLayout.screen").waitForExistence(timeout: 10),
            "Home Layout did not open"
        )

        XCUIRemote.shared.press(.menu)
        assertEventuallyFocused(homeLayoutLink, message: "Back did not restore focus to Home Layout")

        XCUIRemote.shared.press(.menu)
        assertEventuallyFocused(appearanceLink, message: "Second Back did not restore focus to Appearance")
    }

    func testDiagnosticsIsRemoteAccessibleAndRestoresFocus() {
        activateTab(at: 4, title: "Settings")

        let diagnosticsLink = cell(containingIdentifier: "tv.settings.diagnostics")
        moveFocusVertically(to: diagnosticsLink, direction: .down, maximumPresses: 24)
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            element(identifier: "tv.settings.diagnostics.screen").waitForExistence(timeout: 10),
            "Diagnostics did not open"
        )
        XCTAssertTrue(app.staticTexts["Selected Engine"].exists)
        XCTAssertTrue(app.staticTexts["Fallback"].exists)

        XCUIRemote.shared.press(.menu)
        assertEventuallyFocused(diagnosticsLink, message: "Back did not restore focus to Diagnostics")
    }

    func testServicesAddFlowIsFocusableAndKeyboardCancellationIsSafe() {
        activateTab(at: 4, title: "Settings")

        let servicesLink = cell(containingIdentifier: "tv.settings.services")
        moveFocusVertically(to: servicesLink, direction: .down, maximumPresses: 20)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            element(identifier: "tv.settings.services.screen").waitForExistence(timeout: 10),
            "Services settings did not open"
        )

        let addService = app.buttons["Add Service"]
        XCTAssertTrue(addService.waitForExistence(timeout: 10))
        moveFocusVertically(to: addService, direction: .down, maximumPresses: 10)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.alerts["Add Service"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)

        XCTAssertFalse(app.alerts["Add Service"].exists)
        XCTAssertTrue(element(identifier: "tv.settings.services.screen").exists)
        // Let the system alert's dismissal transition finish so the next Menu press reaches the
        // NavigationStack instead of being swallowed by the outgoing keyboard/alert controller.
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        XCUIRemote.shared.press(.menu)
        assertEventuallyFocused(servicesLink, message: "Back did not restore focus to Services")
    }

    func testMPVPlayerControlsAndModalBackPrecedenceAreRemoteAccessible() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["-UITesting", "-UITestingPlayerHarness"]
        app.launch()

        let playPause = app.buttons["tv.player.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 15))
        assertEventuallyFocused(playPause, message: "MPV player did not establish default transport focus")

        let subtitles = app.buttons["tv.player.subtitles"]
        moveFocusHorizontally(to: subtitles, direction: .right, maximumPresses: 5)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.alerts["Subtitles"].waitForExistence(timeout: 5))

        XCUIRemote.shared.press(.menu)
        XCTAssertFalse(app.alerts["Subtitles"].exists)
        XCTAssertTrue(playPause.exists)
    }

    private func activateTab(at index: Int, title: String) {
        let remote = XCUIRemote.shared

        // Move focus into the persistent tab strip, normalize at its leading
        // edge, then traverse exactly as a Siri Remote user would.
        // Menu returns a populated tab's restored content focus to the
        // persistent tab strip. Avoid sending it when the strip already owns
        // focus because that would ask tvOS to leave the app.
        if !tabBarHasFocus {
            remote.press(.menu)
        }
        for _ in 0..<8 where !tabBarHasFocus { remote.press(.up) }
        for _ in 0..<8 { remote.press(.left) }
        for _ in 0..<index { remote.press(.right) }

        let focused = NSPredicate(format: "hasFocus == true")
        let expectation = XCTNSPredicateExpectation(
            predicate: focused,
            object: app.tabBars.buttons[title]
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "Could not focus the \(title) tab; current focus: \(focusedElementDescription())"
        )
        remote.press(.select)
    }

    private func focusSearchField(_ field: XCUIElement) {
        guard !field.hasFocus else { return }
        let remote = XCUIRemote.shared
        let keyboardEntry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Keyboard"))
            .firstMatch
        var focusTrace = [focusedElementDescription()]
        // tvOS exposes the collapsed system `.searchable` control as a
        // focusable "Keyboard" entry before expanding it into the search field.
        for _ in 0..<4 where !field.hasFocus && !keyboardEntry.hasFocus {
            remote.press(.down)
            focusTrace.append(focusedElementDescription())
        }
        XCTAssertTrue(
            field.hasFocus || keyboardEntry.hasFocus,
            "System search entry never received remote focus. Trace: \(focusTrace.joined(separator: " -> "))"
        )
    }

    private func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func cell(containingIdentifier identifier: String) -> XCUIElement {
        app.cells
            .containing(.any, identifier: identifier)
            .firstMatch
    }

    private func firstEnabledButton(identifierSuffix: String) -> XCUIElement {
        let candidates = app.buttons.matching(
            NSPredicate(format: "identifier ENDSWITH %@", identifierSuffix)
        )
        for index in 0..<candidates.count {
            let candidate = candidates.element(boundBy: index)
            if candidate.isEnabled {
                return candidate
            }
        }
        return candidates.firstMatch
    }

    private func moveFocusVertically(
        to element: XCUIElement,
        direction: XCUIRemote.Button,
        maximumPresses: Int
    ) {
        moveFocus(to: element, direction: direction, maximumPresses: maximumPresses)
    }

    private func moveFocusHorizontally(
        to element: XCUIElement,
        direction: XCUIRemote.Button,
        maximumPresses: Int
    ) {
        moveFocus(to: element, direction: direction, maximumPresses: maximumPresses)
    }

    private func moveFocus(
        to element: XCUIElement,
        direction: XCUIRemote.Button,
        maximumPresses: Int
    ) {
        let remote = XCUIRemote.shared
        var focusTrace = [focusedElementDescription()]
        for _ in 0..<maximumPresses where !element.hasFocus {
            remote.press(direction)
            focusTrace.append(focusedElementDescription())
        }
        XCTAssertTrue(
            element.exists && element.hasFocus,
            "Could not focus \(element.identifier). Trace: \(focusTrace.joined(separator: " -> "))"
        )
    }

    private func assertEventuallyFocused(
        _ element: XCUIElement,
        message: String,
        timeout: TimeInterval = 5
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hasFocus == true"),
            object: element
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "\(message). Current focus: \(focusedElementDescription())"
        )
    }

    private func focusedElementDescription() -> String {
        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true"))
            .firstMatch
        guard focused.exists else { return "none" }
        return "\(focused.elementType.rawValue):\(focused.label)"
    }

    private var tabBarHasFocus: Bool {
        app.tabBars.buttons
            .matching(NSPredicate(format: "hasFocus == true"))
            .firstMatch
            .exists
    }
}
