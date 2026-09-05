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

    func testSearchDetailFocusSurvivesCachedReopening() {
        activateTab(at: 3, title: "Search")

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        focusSearchField(searchField)
        if let query = searchField.value as? String,
           !query.isEmpty,
           query != searchField.placeholderValue {
            searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: query.count))
        }
        searchField.typeText("Dune")
        XCUIRemote.shared.press(.menu)

        let result = element(identifier: "tv.search.result.movie-438631")
        guard result.waitForExistence(timeout: 30) else {
            XCTFail("This search regression requires live TMDB results for Dune (2021)")
            return
        }
        guard moveFocusToward(result, maximumPresses: 12) else { return }

        for presentation in 0..<2 {
            XCUIRemote.shared.press(.select)

            let play = app.buttons["tv.detail.play"]
            XCTAssertTrue(play.waitForExistence(timeout: 20))
            assertEventuallyFocused(
                play,
                message: "Detail presentation \(presentation + 1) did not focus Play",
                timeout: 10
            )
            moveFocusVertically(
                to: app.buttons["tv.detail.collection"],
                direction: .down,
                maximumPresses: 3
            )

            XCUIRemote.shared.press(.menu)
            assertEventuallyFocused(
                result,
                message: "Back did not restore the Dune result after presentation \(presentation + 1)",
                timeout: 10
            )
        }
    }

    func testRemoteCanMoveBetweenTabFocusAndOpenSettings() {
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        activateTab(at: 4, title: "Settings")

        XCTAssertTrue(element(identifier: "tv.settings.player").waitForExistence(timeout: 10))
    }

    func testPlayerSettingsHidesTabsAndBackRestoresPlayerRowFocus() {
        activateTab(at: 4, title: "Settings")

        let playerLink = cell(containingIdentifier: "tv.settings.player")
        moveFocusVertically(to: playerLink, direction: .down, maximumPresses: 6)
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(app.staticTexts["Default Playback Speed"].waitForExistence(timeout: 10))
        let settingsTab = app.tabBars.buttons["Settings"]
        let tabsHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !settingsTab.isHittable },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [tabsHidden], timeout: 5), .completed)

        XCUIRemote.shared.press(.menu)
        assertEventuallyFocused(playerLink, message: "Back did not restore focus to Media Player")
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
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

    func testCustomToggleChangesOnOffWithRemoteAndKeepsFocus() {
        activateTab(at: 4, title: "Settings")

        let appearanceLink = cell(containingIdentifier: "tv.settings.appearance")
        moveFocusVertically(to: appearanceLink, direction: .down, maximumPresses: 14)
        XCUIRemote.shared.press(.select)

        let homeLayoutLink = cell(containingIdentifier: "tv.appearance.homeLayout")
        XCTAssertTrue(homeLayoutLink.waitForExistence(timeout: 10))
        moveFocusVertically(to: homeLayoutLink, direction: .down, maximumPresses: 18)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(element(identifier: "tv.appearance.homeLayout.screen").waitForExistence(timeout: 10))

        let identifier = "tv.appearance.animatedBackground"
        let toggle = moveFocusToControl(identifier: identifier, maximumPresses: 20)
        guard let originalValue = normalizedToggleValue(toggle.value) else {
            XCTFail("The custom toggle must expose an explicit On or Off value. \(controlDiagnostics(identifier: identifier))")
            return
        }
        XCTAssertTrue(toggle.label.contains("Animated Background"))
        XCTAssertTrue(toggle.isEnabled)
        let changedValue = originalValue == "On" ? "Off" : "On"

        XCUIRemote.shared.press(.select)
        assertEventuallyValue(toggle, equals: changedValue)
        XCTAssertTrue(controlHasFocus(identifier: identifier), "Changing a toggle lost remote focus")

        XCUIRemote.shared.press(.select)
        assertEventuallyValue(toggle, equals: originalValue)
        XCTAssertTrue(controlHasFocus(identifier: identifier), "Restoring a toggle lost remote focus")

        XCUIRemote.shared.press(.menu)
        assertEventuallyFocused(homeLayoutLink, message: "Back did not restore Home Layout focus")
    }

    func testSettingsSyncRequiresExplicitDirectionAndCancelKeepsItOff() throws {
        activateTab(at: 4, title: "Settings")

        let dataLink = cell(containingIdentifier: "tv.settings.data")
        moveFocusVertically(to: dataLink, direction: .down, maximumPresses: 22)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(element(identifier: "tv.settings.data.screen").waitForExistence(timeout: 10))

        let librarySync = element(identifier: "tv.data.iCloudSync")
        XCTAssertTrue(librarySync.waitForExistence(timeout: 10))
        guard let originalLibrarySyncValue = normalizedToggleValue(librarySync.value) else {
            XCTFail("Library sync must expose its On or Off value. \(controlDiagnostics(identifier: "tv.data.iCloudSync"))")
            return
        }

        let identifier = "tv.data.settingsSync"
        let settingsSync = moveFocusToControl(identifier: identifier, maximumPresses: 14)
        guard let initialValue = normalizedToggleValue(settingsSync.value) else {
            XCTFail("Settings sync must expose its On or Off value. \(controlDiagnostics(identifier: identifier))")
            return
        }
        try XCTSkipIf(
            initialValue == "On",
            "Settings sync must already be off; this test never changes an enabled sync preference or chooses cloud authority."
        )

        XCUIRemote.shared.press(.select)
        let directionAlert = app.alerts["Which Settings Should Win?"]
        XCTAssertTrue(directionAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(directionAlert.buttons["Use My Other Devices"].exists)
        XCTAssertTrue(directionAlert.buttons["Use This Apple TV"].exists)
        XCTAssertTrue(directionAlert.buttons["Cancel"].exists)

        XCUIRemote.shared.press(.menu)
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !directionAlert.exists },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        assertEventuallyValue(settingsSync, equals: "Off")
        assertEventuallyValue(librarySync, equals: originalLibrarySyncValue)
        let focusRestored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.controlHasFocus(identifier: identifier) },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [focusRestored], timeout: 5),
            .completed,
            "Cancel did not restore Settings Sync focus"
        )

        XCUIRemote.shared.press(.menu)
        assertEventuallyFocused(dataLink, message: "Back did not restore Cloud Sync & Cache focus")
    }

    func testBundledLicenseDocumentScrollsWithRemoteAndBackRestoresInventoryFocus() {
        activateTab(at: 4, title: "Settings")

        let legalLink = cell(containingIdentifier: "tv.settings.legal")
        moveFocusVertically(to: legalLink, direction: .down, maximumPresses: 28)
        XCUIRemote.shared.press(.select)

        let noticesLink = element(identifier: "tv.legal.thirdParty")
        XCTAssertTrue(noticesLink.waitForExistence(timeout: 10))
        moveFocusVertically(to: noticesLink, direction: .down, maximumPresses: 5)
        XCUIRemote.shared.press(.select)

        let documentsLink = element(identifier: "tv.legal.documents")
        XCTAssertTrue(documentsLink.waitForExistence(timeout: 10))
        moveFocusVertically(to: documentsLink, direction: .down, maximumPresses: 3)
        XCUIRemote.shared.press(.select)

        let inventoryLink = element(identifier: "tv.legal.document.component-inventory")
        XCTAssertTrue(inventoryLink.waitForExistence(timeout: 10))
        moveFocusVertically(to: inventoryLink, direction: .down, maximumPresses: 3)
        XCUIRemote.shared.press(.select)

        let firstBlock = element(identifier: "tv.legal.document.block.0")
        XCTAssertTrue(firstBlock.waitForExistence(timeout: 10))
        moveFocusVertically(to: firstBlock, direction: .down, maximumPresses: 3)
        let initialBlockTop = firstBlock.frame.minY

        let laterBlock = element(identifier: "tv.legal.document.block.6")
        moveFocusVertically(to: laterBlock, direction: .down, maximumPresses: 10)
        let documentScrolled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                laterBlock.isHittable
                    && (!firstBlock.isHittable || firstBlock.frame.minY < initialBlockTop - 40)
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [documentScrolled], timeout: 5),
            .completed,
            "Remote Down changed focus without scrolling to later license content"
        )

        XCUIRemote.shared.press(.menu)
        assertEventuallyFocused(
            inventoryLink,
            message: "Back from the license document did not restore Component Inventory focus"
        )
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
        let addServiceCell = cell(containingIdentifier: "tv.services.addService")
        let addServiceFocusTarget = addServiceCell.exists ? addServiceCell : addService
        moveFocusVertically(to: addServiceFocusTarget, direction: .down, maximumPresses: 10)
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
        let closedMarker = element(identifier: "tv.playerHarness.closed")
        XCTAssertFalse(closedMarker.isHittable)

        let subtitles = app.buttons["tv.player.subtitles"]
        moveFocusHorizontally(to: subtitles, direction: .right, maximumPresses: 5)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.alerts["Subtitles"].waitForExistence(timeout: 5))

        XCUIRemote.shared.press(.menu)
        let alertDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !self.app.alerts["Subtitles"].exists && playPause.isHittable
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [alertDismissed], timeout: 5), .completed)
        XCTAssertFalse(closedMarker.isHittable, "Back from the track menu dismissed the player")

        XCUIRemote.shared.press(.menu)
        let controlsHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !playPause.isHittable },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [controlsHidden], timeout: 5), .completed)
        XCTAssertFalse(closedMarker.isHittable, "Back from visible controls dismissed the player")

        XCUIRemote.shared.press(.menu)
        let playerClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: closedMarker
        )
        XCTAssertEqual(XCTWaiter.wait(for: [playerClosed], timeout: 5), .completed)
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

    private func normalizedToggleValue(_ value: Any?) -> String? {
        if let string = value as? String {
            switch string {
            case "On", "1": return "On"
            case "Off", "0": return "Off"
            default: return nil
            }
        }
        if let number = value as? NSNumber {
            switch number.doubleValue {
            case 1: return "On"
            case 0: return "Off"
            default: return nil
            }
        }
        return nil
    }

    private func controlDiagnostics(identifier: String) -> String {
        let candidates = app.descendants(matching: .any)
            .matching(identifier: identifier)
            .allElementsBoundByIndex
        let details = candidates.prefix(6).map { candidate in
            "type=\(candidate.elementType.rawValue) label=\(candidate.label) value=\(String(describing: candidate.value)) focused=\(candidate.hasFocus) enabled=\(candidate.isEnabled)"
        }
        return "Matches=\(candidates.count): \(details.joined(separator: " | "))"
    }

    private func moveFocusToControl(identifier: String, maximumPresses: Int) -> XCUIElement {
        let control = element(identifier: identifier)
        var focusTrace = [focusedElementDescription()]
        for _ in 0..<maximumPresses where !controlHasFocus(identifier: identifier) {
            XCUIRemote.shared.press(.down)
            focusTrace.append(focusedElementDescription())
        }
        XCTAssertTrue(
            controlHasFocus(identifier: identifier),
            "Could not focus \(identifier). Trace: \(focusTrace.joined(separator: " -> "))"
        )
        return control
    }

    private func controlHasFocus(identifier: String) -> Bool {
        let control = element(identifier: identifier)
        let containingCell = cell(containingIdentifier: identifier)
        return (control.exists && control.hasFocus) || (containingCell.exists && containingCell.hasFocus)
    }

    private func assertEventuallyValue(_ element: XCUIElement, equals expectedValue: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                element.exists && self.normalizedToggleValue(element.value) == expectedValue
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "\(element.identifier) did not expose value \(expectedValue)"
        )
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

    private func moveFocusToward(_ element: XCUIElement, maximumPresses: Int) -> Bool {
        guard element.exists else {
            XCTFail("The remote navigation target disappeared")
            return false
        }
        let identifier = element.identifier
        var focusTrace = [focusedElementDescription()]
        for _ in 0..<maximumPresses {
            guard element.exists else { break }
            if element.hasFocus { break }
            let focused = app.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true"))
                .firstMatch
            guard focused.exists else { break }
            let currentFrame = focused.frame
            let targetFrame = element.frame
            guard !currentFrame.isEmpty, !targetFrame.isEmpty else { break }
            let verticalDistance = targetFrame.midY - currentFrame.midY
            let horizontalDistance = targetFrame.midX - currentFrame.midX
            let direction: XCUIRemote.Button
            if abs(verticalDistance) > min(currentFrame.height, targetFrame.height) / 2 {
                direction = verticalDistance > 0 ? .down : .up
            } else if abs(horizontalDistance) > 1 {
                direction = horizontalDistance > 0 ? .right : .left
            } else {
                break
            }
            XCUIRemote.shared.press(direction)
            focusTrace.append(focusedElementDescription())
        }
        let reachedTarget = element.exists && element.hasFocus
        XCTAssertTrue(
            reachedTarget,
            "Could not focus \(identifier). Trace: \(focusTrace.joined(separator: " -> "))"
        )
        return reachedTarget
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
