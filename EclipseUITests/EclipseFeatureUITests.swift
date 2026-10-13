import XCTest

final class EclipseFeatureUITests: XCTestCase {
    private let app = XCUIApplication()
    private var restorations: [() throws -> Void] = []
    private var activeSettingsPage: String?
    private var suppressScreenshots = false

    private enum UIInteractionError: Error {
        case unavailable(String)
        case unexpectedValue(String)
        case timedOut(String)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        suppressScreenshots = false
        app.launchArguments = [
            "-experimentalICloudSyncEnabled", "NO",
            "-experimentalGoogleDriveSyncEnabled", "NO",
            "-experimentalOneDriveSyncEnabled", "NO",
            "-eclipseSyncSettingsAcrossDevicesV1", "NO"
        ]
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        capture(name)
        var failures: [String] = []
        for restore in restorations.reversed() {
            do {
                try restore()
            } catch {
                failures.append(String(describing: error))
            }
        }
        restorations = []
        XCTAssertTrue(failures.isEmpty, "Could not restore the original settings through the UI: \(failures.joined(separator: "; "))")
    }

    func testQuickActionsOpensSettingsAndFindsAutoplay() throws {
        try openSettingFromLaunch("Autoplay Next Episode")
        try verifyToggleRoundTrip(label: "Autoplay Next Episode", search: "Autoplay Next Episode")
    }

    func testMPVDoubleTapSeekPreservesControlVisibility() throws {
        guard let fixture = ProcessInfo.processInfo.environment["ECLIPSE_UI_FIXTURE_URL"],
              let url = URL(string: fixture), url.isFileURL else {
            throw XCTSkip("Set ECLIPSE_UI_FIXTURE_URL to a simulator-accessible audio/video fixture.")
        }
        app.launchArguments += [
            "-playerDoubleTapSeekEnabled", "YES",
            "-playerCenterTapPlayPauseEnabled", "NO"
        ]
        app.launchEnvironment["ECLIPSE_DEBUG_AUTOPLAY_URL"] = fixture
        app.launchEnvironment["ECLIPSE_DEBUG_HWDEC"] = "no"
        app.launch()
        let playback = app.buttons["player.playPause"]
        XCTAssertTrue(playback.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 10) { playback.label == "Pause" })
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.35))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.35))
        if playback.isHittable { left.tap() }
        XCTAssertTrue(waitUntil(timeout: 5) { !playback.isHittable })
        for surface in [left, right] {
            surface.doubleTap()
            XCTAssertFalse(playback.isHittable, "Double-tap seeking must leave hidden controls hidden.")
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertFalse(playback.isHittable, "A pending single tap must not reveal controls after seeking.")
        }
        left.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { playback.isHittable }, "Single taps must still reveal controls.")
        right.doubleTap()
        XCTAssertTrue(playback.isHittable, "Double-tap seeking must preserve visible controls.")
        left.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !playback.isHittable }, "Single taps must still hide controls.")
        capture("MPV controls hidden after double-tap seeking")
        left.tap()
        let close = app.buttons["player.close"]
        XCTAssertTrue(waitUntil(timeout: 5) { close.isHittable })
        close.tap()
    }

    func testMPVReturnsFromBackgroundWithoutPictureInPicture() throws {
        guard let fixture = ProcessInfo.processInfo.environment["ECLIPSE_UI_FIXTURE_URL"],
              let url = URL(string: fixture), url.isFileURL else {
            throw XCTSkip("Set ECLIPSE_UI_FIXTURE_URL to a simulator-accessible audio/video fixture.")
        }
        app.launchArguments += [
            "-mpvAppExitPictureInPictureEnabled", "NO",
            "-defaultPlaybackSpeed", "1"
        ]
        app.launchEnvironment["ECLIPSE_DEBUG_AUTOPLAY_URL"] = fixture
        app.launchEnvironment["ECLIPSE_DEBUG_HWDEC"] = "no"
        if let logPath = ProcessInfo.processInfo.environment["ECLIPSE_UI_MPV_LOG_PATH"] {
            app.launchEnvironment["ECLIPSE_DEBUG_MPV_LOG_FILE"] = logPath
        }
        app.launch()
        let playback = app.buttons["player.playPause"]
        XCTAssertTrue(playback.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 10) { playback.label == "Pause" })

        for cycle in 1...2 {
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
            Thread.sleep(forTimeInterval: 2)
            app.activate()
            if !playback.waitForExistence(timeout: 2) {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            }
            XCTAssertTrue(playback.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(waitUntil(timeout: 10) { playback.label == "Pause" }, app.debugDescription)
            capture("MPV inline after background cycle \(cycle)")
        }

        if !playback.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        }
        XCTAssertTrue(playback.isHittable)
        playback.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { playback.label == "Play" })
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        if !playback.waitForExistence(timeout: 2) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        }
        XCTAssertTrue(playback.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(playback.label, "Play", "Foreground recovery must preserve the user's pause intent.")
        Thread.sleep(forTimeInterval: 2)
        if !playback.waitForExistence(timeout: 1) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        }
        XCTAssertTrue(playback.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(playback.label, "Play", "Foreground recovery must preserve the user's pause intent.")
        capture("MPV paused after background cycle")
        let close = app.buttons["player.close"]
        if close.exists, close.isHittable { close.tap() }
    }

    func testImageDataSaverChangesAndPersists() throws {
        try openSettingFromLaunch("Image Data Saver")
        try verifyToggleRoundTrip(label: "Image Data Saver", search: "Image Data Saver", checkPersistence: true)
    }

    func testRememberedPlaybackChoiceChangesAndPersists() throws {
        try openSettingFromLaunch("Remember Last Choice per Show")
        try verifyToggleRoundTrip(label: "Remember Last Choice per Show", search: "Remember Last Choice per Show", checkPersistence: true)
        XCTAssertTrue(app.buttons["Clear Remembered Choices"].exists)
    }

    func testExtraSourceLanguageFilterSavesAndRestoresThroughSettings() throws {
        try openSettingFromLaunch("Languages to Include")
        try openStreamLanguagePicker("Languages to Include")
        var includedOriginals: [(id: String, query: String, selected: Bool)] = []
        restorations.append { [self] in
            try openSettingFromLaunch("Languages to Include")
            try openStreamLanguagePicker("Languages to Include")
            for original in includedOriginals {
                try setStreamLanguageSelection(id: original.id, query: original.query, selected: original.selected)
            }
            try closeStreamLanguagePicker()
        }
        for (id, query) in [("en", "ENG"), ("yo", "Yoruba"), ("pt-BR", "Brazil")] {
            let original = try streamLanguageSelection(id: id, query: query)
            includedOriginals.append((id: id, query: query, selected: original))
            if !original { try setStreamLanguageSelection(id: id, query: query, selected: true) }
        }
        capture("Searchable Brazilian Portuguese included")
        try closeStreamLanguagePicker()

        try openSettingFromLaunch("Languages to Include")
        try openStreamLanguagePicker("Languages to Include")
        for (id, query) in [("en", "ENG"), ("yo", "Yoruba"), ("pt-BR", "Brazil")] {
            XCTAssertTrue(try streamLanguageSelection(id: id, query: query))
        }
        try closeStreamLanguagePicker()
        try openStreamLanguagePicker("Languages to Exclude")
        let originalExcludedEnglish = try streamLanguageSelection(id: "en", query: "English")
        if !originalExcludedEnglish {
            restorations.append { [self] in
                try restoreStreamLanguageSelection(title: "Languages to Exclude", id: "en", query: "English", selected: originalExcludedEnglish)
            }
            try setStreamLanguageSelection(id: "en", query: "English", selected: true)
        }
        XCTAssertTrue(app.staticTexts["Excluded languages take priority"].firstMatch.exists)
        capture("English exclusion conflict explained")
        try closeStreamLanguagePicker()
        try openSettingFromLaunch("Languages to Exclude")
        try openStreamLanguagePicker("Languages to Exclude")
        XCTAssertTrue(try streamLanguageSelection(id: "en", query: "English"))
        try closeStreamLanguagePicker()
    }

    func testPlayerLanguagePickerSearchesBroadCatalog() throws {
        try openSettingFromLaunch("Auto Audio Language")
        let preference = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Auto Audio Language")).firstMatch
        try reveal(preference)
        preference.tap()
        try waitForSettingsPage(["Auto Audio Language"])
        for (id, query) in [("yo", "Yoruba"), ("bo", "tib"), ("pt-BR", "Brazil")] {
            try searchLanguagePicker(query)
            XCTAssertTrue(app.buttons["player-language-option-\(id)"].waitForExistence(timeout: 5))
        }
        capture("Player language catalog searches regional variants")
    }

    private func openStreamLanguagePicker(_ title: String) throws {
        let identifier = title == "Languages to Include" ? "settings.services.includedLanguages" : "settings.services.excludedLanguages"
        let button = app.buttons[identifier].firstMatch
        try reveal(button)
        button.tap()
        try waitForSettingsPage([title])
    }

    private func closeStreamLanguagePicker() throws {
        let cancelSearch = app.buttons["Cancel"].firstMatch
        if cancelSearch.exists, cancelSearch.isHittable {
            cancelSearch.tap()
        } else {
            let closeSearch = app.toolbars.buttons["close"].firstMatch
            if closeSearch.exists, closeSearch.isHittable { closeSearch.tap() }
        }
        let done = app.buttons["stream-language-done"].firstMatch
        guard done.waitForExistence(timeout: 5), done.isHittable else {
            throw UIInteractionError.unavailable("The language picker cannot close: \(app.debugDescription)")
        }
        done.tap()
        try waitForSettingsPage(["Extra Source Settings"])
    }

    private func searchLanguagePicker(_ query: String) throws {
        let field = app.searchFields["Search languages or codes"].firstMatch
        guard field.waitForExistence(timeout: 5) else {
            throw UIInteractionError.unavailable("Language search is unavailable.")
        }
        if field.value as? String == query {
            activeSettingsPage = nil
            return
        }
        field.tap()
        if let value = field.value as? String, value != field.placeholderValue, !value.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(query)
        activeSettingsPage = nil
    }

    private func streamLanguageSelection(id: String, query: String) throws -> Bool {
        try searchLanguagePicker(query)
        let row = app.buttons["stream-language-option-\(id)"].firstMatch
        guard row.waitForExistence(timeout: 5) else {
            throw UIInteractionError.unavailable("The language catalog did not find \(id).")
        }
        try reveal(row)
        return row.isSelected
    }

    private func setStreamLanguageSelection(id: String, query: String, selected: Bool) throws {
        let actual = try streamLanguageSelection(id: id, query: query)
        if actual == selected { return }
        let row = app.buttons["stream-language-option-\(id)"].firstMatch
        guard row.isEnabled else { throw UIInteractionError.unavailable("The language selection limit has been reached.") }
        row.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { row.isSelected == selected })
    }

    private func restoreStreamLanguageSelection(title: String, id: String, query: String, selected: Bool) throws {
        try openSettingFromLaunch(title)
        try openStreamLanguagePicker(title)
        try setStreamLanguageSelection(id: id, query: query, selected: selected)
        try closeStreamLanguagePicker()
    }

    func testAnimationOffers60And120FramesPerSecond() throws {
        try openSettingFromLaunch("Animation Frame Rate")
        let identifier = "settings.appearance.animationFrameRate"
        let original = try menuValue(identifier, options: ["20 FPS", "30 FPS", "60 FPS", "120 FPS"])
        restorations.append { [self] in
            try openSettingFromLaunch("Animation Frame Rate")
            try selectMenu(identifier, value: original)
        }
        try selectMenu(identifier, value: "60 FPS")
        capture("Background animation at 60 FPS")
        try selectMenu(identifier, value: "120 FPS")
        capture("Background animation at 120 FPS")
        try openSettingFromLaunch("Animation Frame Rate")
        XCTAssertEqual(try menuValue(identifier, options: ["20 FPS", "30 FPS", "60 FPS", "120 FPS"]), "120 FPS")
        try selectMenu(identifier, value: original)
        restorations.removeLast()
    }

    func testDownloadConcurrencyAndFillerControls() throws {
        try openSettingFromLaunch("Concurrent Downloads")
        let overallID = "settings.storage.concurrentDownloads"
        let hlsID = "settings.storage.concurrentHLSDownloads"
        let options = ["1", "2", "3", "4"]
        let originalOverall = try menuValue(overallID, options: options)
        let originalHLS = try menuValue(hlsID, options: options)
        restorations.append { [self] in
            try openSettingFromLaunch("Concurrent Downloads")
            try selectMenu(overallID, value: originalOverall)
            try selectMenu(hlsID, value: originalHLS)
        }
        let expectedOverall = originalOverall == "4" ? "1" : "4"
        let expectedHLS = originalHLS == "4" ? "1" : "4"
        try selectMenu(overallID, value: expectedOverall == "4" ? "1" : "4")
        try selectMenu(hlsID, value: expectedHLS == "4" ? "1" : "4")
        try selectMenu(overallID, value: expectedOverall)
        try selectMenu(hlsID, value: expectedHLS)
        capture("Overall and HLS download limits")
        try openSettingFromLaunch("Concurrent Downloads")
        XCTAssertEqual(try menuValue(overallID, options: options), expectedOverall)
        XCTAssertEqual(try menuValue(hlsID, options: options), expectedHLS)
        try verifyToggleRoundTrip(label: "Skip Filler in Download All", search: "Concurrent Downloads")
        try selectMenu(overallID, value: originalOverall)
        try selectMenu(hlsID, value: originalHLS)
        restorations.removeLast()
    }

    func testDeepLibraryFilterRowsDoNotOverlap() throws {
        app.launchArguments += ["-trackerDeepLibraryEnabled", "YES", "-showKanzen", "NO"]
        restartApp()
        try openLibraryTab()
        let sources = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(sources.waitForExistence(timeout: 10), app.debugDescription)
        for source in ["AniList", "MAL", "Trakt"] {
            sources.buttons[source].tap()
            let search = app.textFields["Search library"]
            let primary = app.buttons[source == "Trakt" ? "trackerLibrary.traktSection" : "trackerLibrary.status"].firstMatch
            let genre = app.buttons["trackerLibrary.genre"].firstMatch
            let refresh = app.buttons["trackerLibrary.refresh"].firstMatch
            XCTAssertTrue(primary.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(genre.exists, app.debugDescription)
            XCTAssertTrue(refresh.exists, app.debugDescription)
            XCTAssertGreaterThan(primary.frame.width, 150)
            XCTAssertGreaterThanOrEqual(primary.frame.height, 44)
            XCTAssertLessThanOrEqual(search.frame.maxY, primary.frame.minY)
            XCTAssertLessThanOrEqual(primary.frame.maxY, genre.frame.minY)
            XCTAssertFalse(primary.frame.intersects(refresh.frame))
            XCTAssertLessThanOrEqual(genre.frame.maxX, app.frame.maxX)
            if source == "AniList" {
                let lists = app.buttons["trackerLibrary.anilistSection"].firstMatch
                XCTAssertTrue(lists.exists, app.debugDescription)
                XCTAssertLessThanOrEqual(genre.frame.maxY, lists.frame.minY)
            }
            capture("\(source) filter layout")
        }
    }

    func testDeepLibraryMALGridGeometryRemainsStable() throws {
        suppressScreenshots = true
        app.launchArguments += ["-trackerDeepLibraryEnabled", "YES", "-showKanzen", "NO", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        restartApp()
        try openLibraryTab()
        let sources = app.segmentedControls["trackerLibrarySourcePicker"]
        guard sources.waitForExistence(timeout: 10) else { throw UIInteractionError.unavailable("Library sources are unavailable.") }
        sources.buttons["MAL"].tap()
        let unavailable = app.staticTexts["Enable Deep Library Integration and connect this tracker in Settings to view its library."]
        if unavailable.exists { throw XCTSkip("MAL is not connected on this simulator.") }
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trackerLibrary.open."))
        let refresh = app.buttons["trackerLibrary.refresh"].firstMatch
        let loaded = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
        let loadingCount = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles loaded")).firstMatch
        guard cards.firstMatch.waitForExistence(timeout: 60) else {
            if unavailable.exists { throw XCTSkip("MAL is not connected on this simulator.") }
            if app.buttons["Retry"].exists { throw UIInteractionError.unavailable("MAL returned a library error.") }
            throw XCTSkip("The connected MAL library has no cards to validate.")
        }

        struct Cell {
            let id: String
            let frame: CGRect
            let titleLength: Int
            let readiness: String
        }

        func snapshot() throws -> [Cell] {
            guard !app.buttons["Retry"].exists else { throw UIInteractionError.unavailable("MAL returned a library error during geometry validation.") }
            return cards.allElementsBoundByIndex.prefix(18).compactMap { card in
                let frame = card.frame
                guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite,
                      frame.width > 0, frame.height > 0 else { return nil }
                return Cell(id: card.identifier, frame: frame,
                            titleLength: max(0, card.label.count - "Open ".count), readiness: card.value as? String ?? "Unknown")
            }
        }

        let initial = try snapshot()
        var columns: [CGFloat] = []
        for cell in initial where !columns.contains(where: { abs($0 - cell.frame.minX) <= 1 }) { columns.append(cell.frame.minX) }
        guard columns.count >= 2, initial.count >= columns.count * 2 else {
            throw XCTSkip("At least two complete MAL grid rows are needed for geometry validation.")
        }
        let baseline = Array(initial.prefix(min(initial.count / columns.count, 3) * columns.count))
        XCTAssertLessThanOrEqual(try XCTUnwrap(baseline.first).frame.width, 126, "Default-size tracker posters must remain compact.")
        let baselineIDs = Set(baseline.map(\.id))
        let rowCount = baseline.count / columns.count
        let tolerance: CGFloat = 1
        var readinessChanges = Set<String>()
        var sampleCount = 0

        func checkGeometry(_ cells: [Cell]) throws {
            let byID = Dictionary(cells.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard let anchor = baseline.first, let currentAnchor = byID[anchor.id] else {
                throw UIInteractionError.unavailable("The first sampled MAL card disappeared during loading.")
            }
            let translation = CGPoint(x: currentAnchor.frame.minX - anchor.frame.minX, y: currentAnchor.frame.minY - anchor.frame.minY)
            for row in 0..<rowCount {
                let reference = baseline[row * columns.count]
                guard let currentReference = byID[reference.id] else {
                    throw UIInteractionError.unavailable("MAL row \(row + 1) lost its sampled first card.")
                }
                for column in 0..<columns.count {
                    let old = baseline[row * columns.count + column]
                    guard let current = byID[old.id] else {
                        throw UIInteractionError.unavailable("MAL row \(row + 1) column \(column + 1) disappeared during loading.")
                    }
                    XCTAssertEqual(current.frame.minY, currentReference.frame.minY, accuracy: tolerance, "MAL row \(row + 1) has misaligned card tops.")
                    XCTAssertEqual(current.frame.width, currentReference.frame.width, accuracy: tolerance, "MAL row \(row + 1) has unequal card widths.")
                    XCTAssertEqual(current.frame.height, currentReference.frame.height, accuracy: tolerance, "MAL row \(row + 1) has unequal card heights.")
                    XCTAssertGreaterThanOrEqual(current.frame.minX, app.frame.minX - tolerance, "MAL card \(row * columns.count + column + 1) overflowed the leading viewport edge.")
                    XCTAssertLessThanOrEqual(current.frame.maxX, app.frame.maxX + tolerance, "MAL card \(row * columns.count + column + 1) overflowed the trailing viewport edge.")
                    XCTAssertEqual(current.frame.minX - old.frame.minX, translation.x, accuracy: tolerance, "MAL card \(row * columns.count + column + 1) moved horizontally.")
                    XCTAssertEqual(current.frame.minY - old.frame.minY, translation.y, accuracy: tolerance, "MAL card \(row * columns.count + column + 1) changed row spacing.")
                    XCTAssertEqual(current.frame.width, old.frame.width, accuracy: tolerance, "MAL card \(row * columns.count + column + 1) changed width.")
                    XCTAssertEqual(current.frame.height, old.frame.height, accuracy: tolerance, "MAL card \(row * columns.count + column + 1) changed height.")
                    if old.readiness == "Matching", current.readiness == "Ready" { readinessChanges.insert(old.id) }
                }
            }
            sampleCount += 1
        }

        try checkGeometry(initial)
        let matchingDeadline = Date().addingTimeInterval(12)
        repeat {
            Thread.sleep(forTimeInterval: 0.25)
            let current = try snapshot()
            try checkGeometry(current)
            if refresh.isEnabled && loaded.exists && !readinessChanges.isEmpty { break }
        } while Date() < matchingDeadline
        guard waitUntil(timeout: 60, { refresh.isEnabled && (loaded.exists || self.app.buttons["Retry"].exists) }) else {
            throw UIInteractionError.timedOut("MAL did not settle before the refresh geometry check.")
        }
        try checkGeometry(snapshot())

        let scoredCells = baseline.filter { cell in
            let entryID = String(cell.id.dropFirst("trackerLibrary.open.".count))
            return app.descendants(matching: .any).matching(identifier: "trackerLibrary.score.\(entryID)").firstMatch.exists
        }.count
        guard refresh.isHittable else { throw UIInteractionError.unavailable("MAL refresh is outside the visible library controls.") }
        Thread.sleep(forTimeInterval: 1.1)
        refresh.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        var observedLoading = false
        let refreshDeadline = Date().addingTimeInterval(60)
        repeat {
            if !refresh.isEnabled || loadingCount.exists { observedLoading = true }
            let current = try snapshot()
            try checkGeometry(current)
            if observedLoading && refresh.isEnabled && loaded.exists { break }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < refreshDeadline
        guard refresh.isEnabled, loaded.exists else { throw UIInteractionError.timedOut("MAL refresh did not settle during geometry validation.") }
        try checkGeometry(snapshot())
        let lengths = baseline.map(\.titleLength)
        let receipt = XCTAttachment(string: "MAL grid rows=\(rowCount) columns=\(columns.count) cells=\(baselineIDs.count) samples=\(sampleCount) title-length-min=\(lengths.min() ?? 0) title-length-max=\(lengths.max() ?? 0) scored-cells=\(scoredCells) unscored-cells=\(baseline.count - scoredCells) readiness-changes=\(readinessChanges.count) refresh-loading-observed=\(observedLoading)")
        receipt.name = "MAL grid geometry coverage"
        receipt.lifetime = .keepAlways
        add(receipt)
        guard observedLoading else { throw XCTSkip("MAL refresh completed too quickly to observe loading geometry.") }
        guard let minimum = lengths.min(), let maximum = lengths.max(), maximum - minimum >= 10 else {
            throw XCTSkip("The sampled MAL rows need more varied title lengths for wrapping coverage.")
        }
        guard scoredCells > 0, scoredCells < baseline.count else {
            throw XCTSkip("The sampled MAL rows need both scored and unscored entries for optional-footer coverage.")
        }
        guard !readinessChanges.isEmpty else {
            throw XCTSkip("No sampled MAL matching state changed during geometry validation.")
        }
    }

    func testDeepLibraryMALGridFitsAccessibilityText() throws {
        app.launchArguments += ["-trackerDeepLibraryEnabled", "YES", "-showKanzen", "NO", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        restartApp()
        try openLibraryTab()
        let sources = app.segmentedControls["trackerLibrarySourcePicker"]
        guard sources.waitForExistence(timeout: 10) else { throw UIInteractionError.unavailable("Library sources are unavailable.") }
        sources.buttons["MAL"].tap()
        let unavailable = app.staticTexts["Enable Deep Library Integration and connect this tracker in Settings to view its library."]
        if unavailable.waitForExistence(timeout: 2) { throw XCTSkip("MAL is not connected on this simulator.") }
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trackerLibrary.open."))
        guard app.buttons["trackerLibrary.refresh"].waitForExistence(timeout: 10) else {
            throw UIInteractionError.unavailable("MAL library controls are unavailable.")
        }
        let readyDeadline = Date().addingTimeInterval(60)
        while (!cards.firstMatch.exists || !cards.firstMatch.isHittable) && Date() < readyDeadline {
            guard !app.buttons["Retry"].exists else { throw UIInteractionError.unavailable("MAL returned a library error at accessibility text size.") }
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard cards.firstMatch.exists, cards.firstMatch.isHittable else { throw XCTSkip("The connected MAL library has no visible accessibility-size cards to validate.") }
        let first = cards.firstMatch
        let firstFrame = first.frame
        let entryID = String(first.identifier.dropFirst("trackerLibrary.open.".count))
        let viewport = app.frame
        let tolerance: CGFloat = 1
        XCTAssertGreaterThanOrEqual(firstFrame.minX, viewport.minX - tolerance, "The MAL accessibility card overflowed the leading viewport edge.")
        XCTAssertLessThanOrEqual(firstFrame.maxX, viewport.maxX + tolerance, "The MAL accessibility card overflowed the trailing viewport edge.")
        XCTAssertGreaterThanOrEqual(firstFrame.width, viewport.width * 0.8, "MAL accessibility text did not use a full-width column.")
        XCTAssertGreaterThan(firstFrame.height, 0)
        let sampledFrames = cards.allElementsBoundByIndex.prefix(6).map(\.frame).filter { $0.width > 0 && $0.height > 0 }
        for (index, frame) in sampledFrames.enumerated() {
            XCTAssertEqual(frame.minX, firstFrame.minX, accuracy: tolerance, "MAL accessibility card \(index + 1) used another column.")
            XCTAssertEqual(frame.width, firstFrame.width, accuracy: tolerance, "MAL accessibility card \(index + 1) changed column width.")
            XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX - tolerance, "MAL accessibility card \(index + 1) overflowed the leading viewport edge.")
            XCTAssertLessThanOrEqual(frame.maxX, viewport.maxX + tolerance, "MAL accessibility card \(index + 1) overflowed the trailing viewport edge.")
        }
        let progress = app.staticTexts["trackerLibrary.progress.\(entryID)"].firstMatch
        for _ in 0..<8 where !progress.isHittable { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        guard progress.exists, progress.isHittable else { throw UIInteractionError.unavailable("MAL progress is inaccessible at accessibility text size.") }
        XCTAssertGreaterThan(progress.frame.width, 0)
        XCTAssertGreaterThanOrEqual(progress.frame.minX, viewport.minX - tolerance)
        XCTAssertLessThanOrEqual(progress.frame.maxX, viewport.maxX + tolerance)
        let edit = app.buttons["trackerLibrary.edit.\(entryID)"].firstMatch
        for _ in 0..<8 where !edit.isHittable { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        guard edit.exists, edit.isHittable else { throw UIInteractionError.unavailable("MAL editing is inaccessible at accessibility text size.") }
        XCTAssertLessThanOrEqual(progress.frame.maxY, edit.frame.minY + tolerance, "MAL progress overlapped the accessibility edit button.")
        XCTAssertGreaterThanOrEqual(edit.frame.minX, viewport.minX - tolerance)
        XCTAssertLessThanOrEqual(edit.frame.maxX, viewport.maxX + tolerance)
        let scores = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "trackerLibrary.score."))
            .allElementsBoundByIndex.prefix(6)
        for score in scores {
            XCTAssertGreaterThan(score.frame.width, 0, "A present MAL score became inaccessible at accessibility text size.")
            XCTAssertGreaterThanOrEqual(score.frame.minX, viewport.minX - tolerance)
            XCTAssertLessThanOrEqual(score.frame.maxX, viewport.maxX + tolerance)
        }
        XCTAssertFalse(app.buttons["Retry"].exists, "MAL returned a library error at accessibility text size.")
        capture("MAL accessibility text layout")
    }

    func testDeepLibrarySeparatesVideoAndReaderMedia() throws {
        app.launchArguments += ["-trackerDeepLibraryEnabled", "YES", "-showKanzen", "NO"]
        restartApp()
        try openLibraryTab()
        let videoSources = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(videoSources.waitForExistence(timeout: 10))
        for source in ["AniList", "MAL"] {
            videoSources.buttons[source].tap()
            let types = app.segmentedControls["trackerLibrary.mediaType"]
            XCTAssertTrue(types.waitForExistence(timeout: 10))
            XCTAssertTrue(types.buttons["Anime"].exists)
            XCTAssertFalse(types.buttons["Manga"].exists)
            XCTAssertFalse(types.buttons["Light Novels"].exists)
        }
        videoSources.buttons["Trakt"].tap()
        let videoTypes = app.segmentedControls["trackerLibrary.mediaType"]
        XCTAssertTrue(videoTypes.buttons["Movies"].exists)
        XCTAssertTrue(videoTypes.buttons["Shows"].exists)
        XCTAssertFalse(videoTypes.buttons["Manga"].exists)
        XCTAssertFalse(videoTypes.buttons["Light Novels"].exists)

        app.launchArguments[app.launchArguments.count - 1] = "YES"
        restartApp()
        try openNovelReaderLibrary(allowModeSwitch: false)
        let readerSources = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(readerSources.waitForExistence(timeout: 10))
        XCTAssertFalse(readerSources.buttons["Trakt"].exists)
        var coverage: [String] = []
        for source in ["AniList", "MAL"] {
            readerSources.buttons[source].tap()
            let types = app.segmentedControls["trackerLibrary.mediaType"]
            XCTAssertTrue(types.waitForExistence(timeout: 10))
            XCTAssertTrue(types.buttons["Manga"].exists)
            XCTAssertTrue(types.buttons["Light Novels"].exists)
            XCTAssertFalse(types.buttons["Anime"].exists)
            XCTAssertFalse(types.buttons["Movies"].exists)
            XCTAssertFalse(types.buttons["Shows"].exists)
            for (title, kind) in [("Manga", "MANGA"), ("Light Novels", "NOVEL")] {
                types.buttons[title].tap()
                let count = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
                let unavailable = app.staticTexts["Enable Deep Library Integration and connect this tracker in Settings to view its library."]
                XCTAssertTrue(waitUntil(timeout: 60) { count.exists || unavailable.exists || self.app.buttons["Retry"].exists })
                XCTAssertFalse(app.buttons["Retry"].exists, "The Reader \(source) \(title) library returned an error.")
                let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trackerLibrary.open."))
                for card in cards.allElementsBoundByIndex.prefix(6) {
                    XCTAssertTrue(card.identifier.contains(":\(kind):"), "A title appeared in the wrong Reader media section.")
                }
                let editorChecked = title == "Light Novels" ? try verifyAvailableEditorCanCancel(source: source, kind: title) : false
                coverage.append("\(source) \(kind) titles=\(count.exists ? count.label : "unavailable") cards=\(cards.count) editor=\(editorChecked)")
                capture("Reader \(source) \(title) library")
            }
        }
        let receipt = XCTAttachment(string: coverage.joined(separator: "\n"))
        receipt.name = "Reader media and editor coverage"
        receipt.lifetime = .keepAlways
        add(receipt)
    }

    func testDeepLibraryConnectedTrackerReads() throws {
        app.launchArguments += ["-trackerDeepLibraryEnabled", "YES"]
        restartApp()
        try openLibraryTab()
        let sources = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(sources.waitForExistence(timeout: 10), app.debugDescription)
        var checked = 0
        sourceLoop: for source in ["AniList", "MAL", "Trakt"] {
            sources.buttons[source].tap()
            let unavailable = app.staticTexts["Enable Deep Library Integration and connect this tracker in Settings to view its library."]
            if unavailable.waitForExistence(timeout: 2) { continue }
            let sections = source == "Trakt" ? ["Watched History", "Collection", "Watchlist"] : ["Library"]
            let mediaTypes = source == "Trakt" ? ["Movies", "Shows"] : ["Anime"]
            for mediaType in mediaTypes {
                if source == "Trakt" { app.segmentedControls["trackerLibrary.mediaType"].buttons[mediaType].tap() }
                for section in sections {
                    if source == "Trakt" { try selectMenu("trackerLibrary.traktSection", value: section) }
                    let refresh = app.buttons["trackerLibrary.refresh"].firstMatch
                    XCTAssertTrue(refresh.waitForExistence(timeout: 10))
                    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        refresh.isEnabled
                    }, object: nil)
                    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed, "\(source) \(section) did not become ready")
                    let loaded = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
                    let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                        refresh.isEnabled && (loaded.exists || app.buttons["Retry"].exists)
                    }, object: nil)
                    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 60), .completed, "\(source) \(section) did not settle")
                    if source == "Trakt", app.staticTexts["Trakt session expired. Reconnect Trakt in Settings."].exists {
                        capture("Trakt reconnect required")
                        continue sourceLoop
                    }
                    XCTAssertTrue(loaded.exists, "\(source) \(section) did not load")
                    XCTAssertFalse(app.buttons["Retry"].exists, "\(source) \(section) returned a library error")
                    capture("\(source) \(mediaType) \(section) connected read")
                    checked += 1
                }
            }
        }
        if checked == 0 { throw XCTSkip("No tracker is connected on this simulator.") }
    }

    func testDeepLibraryTraktPersonalListReads() throws {
        suppressScreenshots = true
        app.launchArguments += ["-trackerDeepLibraryEnabled", "YES"]
        restartApp()
        try openLibraryTab()
        let sources = app.segmentedControls["trackerLibrarySourcePicker"]
        guard sources.waitForExistence(timeout: 10) else { throw UIInteractionError.unavailable("Library sources are unavailable.") }
        sources.buttons["Trakt"].tap()
        let unavailable = app.staticTexts["Enable Deep Library Integration and connect this tracker in Settings to view its library."]
        if unavailable.waitForExistence(timeout: 2) { throw XCTSkip("Trakt is not connected on this simulator.") }
        let sections = app.buttons["trackerLibrary.traktSection"].firstMatch
        let refresh = app.buttons["trackerLibrary.refresh"].firstMatch
        let kinds = app.segmentedControls["trackerLibrary.mediaType"]
        guard sections.waitForExistence(timeout: 10), refresh.exists, kinds.exists else {
            throw UIInteractionError.unavailable("Trakt library controls are unavailable.")
        }
        let standards = Set(["Watchlist", "Watched History", "Collection"])
        let loaded = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
        let loadingCount = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles loaded")).firstMatch
        let metadataError = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Custom lists:")).firstMatch
        let reconnect = app.staticTexts["Trakt session expired. Reconnect Trakt in Settings."]

        func checkErrors(_ index: Int) throws {
            if reconnect.exists { throw XCTSkip("Trakt requires reconnection on this simulator.") }
            guard !metadataError.exists else { throw UIInteractionError.unavailable("Trakt personal-list metadata failed for read \(index).") }
            guard !app.buttons["Retry"].exists else { throw UIInteractionError.unavailable("Trakt personal-list read \(index) returned a library error.") }
        }

        func menuOptions() -> [XCUIElement] {
            let buttons = app.buttons.allElementsBoundByIndex
            let standardRows = buttons.filter { standards.contains($0.label) && $0.isHittable }
            guard standardRows.count == standards.count, let reference = standardRows.first,
                  let lastStandard = standardRows.max(by: { $0.frame.maxY < $1.frame.maxY }) else { return [] }
            let frame = reference.frame
            return buttons.filter {
                !standards.contains($0.label) && $0.isHittable && $0.frame.height > 0
                    && abs($0.frame.minX - frame.minX) < 2 && abs($0.frame.maxX - frame.maxX) < 2
                    && $0.frame.minY >= lastStandard.frame.maxY - 2
            }.sorted { $0.frame.minY < $1.frame.minY }
        }

        func dismissMenu() {
            sections.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        func waitForRead(_ index: Int, previousCount: String?) throws -> Bool {
            var admitted = false
            let admissionDeadline = Date().addingTimeInterval(2)
            while Date() < admissionDeadline {
                try checkErrors(index)
                if !refresh.isEnabled || loadingCount.exists { admitted = true; break }
                if refresh.isEnabled, loaded.exists, loaded.label != previousCount { admitted = true; break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if !admitted {
                guard waitUntil(timeout: 60, { refresh.isEnabled }) else {
                    throw UIInteractionError.timedOut("Trakt personal-list read \(index) did not become ready.")
                }
                try checkErrors(index)
                Thread.sleep(forTimeInterval: 1.1)
                refresh.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let refreshDeadline = Date().addingTimeInterval(5)
                while Date() < refreshDeadline {
                    try checkErrors(index)
                    if !refresh.isEnabled || loadingCount.exists { admitted = true; break }
                    if refresh.isEnabled, loaded.exists, loaded.label != previousCount { admitted = true; break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            guard waitUntil(timeout: 60, { refresh.isEnabled && (loaded.exists || self.app.buttons["Retry"].exists) }) else {
                throw UIInteractionError.timedOut("Trakt personal-list read \(index) did not settle.")
            }
            try checkErrors(index)
            guard loaded.exists else { throw UIInteractionError.unavailable("Trakt personal-list read \(index) has no settled title count.") }
            return admitted
        }

        var personalNames: [String] = []
        let metadataDeadline = Date().addingTimeInterval(60)
        while Date() < metadataDeadline {
            try checkErrors(0)
            sections.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            guard app.buttons["Collection"].waitForExistence(timeout: 5) else {
                throw UIInteractionError.unavailable("Trakt list options are unavailable.")
            }
            personalNames = menuOptions().map(\.label)
            dismissMenu()
            if !personalNames.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard !personalNames.isEmpty else {
            throw XCTSkip("No personal-list options were observed; the UI cannot distinguish pending metadata from a valid empty response.")
        }
        let duplicateNameCount = personalNames.count - Set(personalNames).count

        var readIndex = 0
        var unprovenReads: [Int] = []
        for mediaType in ["Movies", "Shows"] {
            kinds.buttons[mediaType].tap()
            guard waitUntil(timeout: 10, { kinds.buttons[mediaType].isSelected }) else {
                throw UIInteractionError.timedOut("Trakt media type did not change.")
            }
            for (optionIndex, name) in personalNames.enumerated() {
                readIndex += 1
                let previousCount = loaded.exists ? loaded.label : nil
                sections.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                guard app.buttons["Collection"].waitForExistence(timeout: 5) else {
                    throw UIInteractionError.unavailable("Trakt list options are unavailable for read \(readIndex).")
                }
                let options = menuOptions()
                guard options.indices.contains(optionIndex), options[optionIndex].label == name else {
                    throw UIInteractionError.unavailable("Personal-list option is unavailable for read \(readIndex).")
                }
                let option = options[optionIndex]
                option.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                guard waitUntil(timeout: 5, { sections.value as? String == name }) else {
                    throw UIInteractionError.timedOut("Personal-list selection did not change for read \(readIndex).")
                }
                if try !waitForRead(readIndex, previousCount: previousCount) { unprovenReads.append(readIndex) }
            }
        }
        if !unprovenReads.isEmpty {
            throw XCTSkip("Work admission was not observable for \(unprovenReads.count) personal-list reads: \(unprovenReads.map(String.init).joined(separator: ", ")).")
        }
        if duplicateNameCount > 0 {
            throw XCTSkip("\(duplicateNameCount) personal-list options share names; the UI cannot verify their distinct identities.")
        }
    }

    func testDeepLibrarySwitchesTrackerAndMediaType() throws {
        try openSettingFromLaunch("Deep Library Integration")
        let original = try switchValue("Deep Library Integration")
        restorations.append { [self] in
            try openSettingFromLaunch("Deep Library Integration")
            try setSwitch("Deep Library Integration", to: original)
        }
        let disconnectedSources = try disconnectedTrackerSources()
        try setSwitch("Deep Library Integration", to: true)
        restartApp()
        try openLibraryTab()
        let sourcePicker = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(sourcePicker.waitForExistence(timeout: 10), app.debugDescription)
        for source in ["AniList", "MAL"] {
            let sourceButton = sourcePicker.buttons[source]
            XCTAssertTrue(sourceButton.exists, app.debugDescription)
            sourceButton.tap()
            let kindPicker = app.segmentedControls["trackerLibrary.mediaType"]
            XCTAssertTrue(kindPicker.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertFalse(kindPicker.buttons["Manga"].exists)
            XCTAssertFalse(kindPicker.buttons["Light Novels"].exists)
            for kind in ["Anime"] {
                let kindButton = kindPicker.buttons[kind]
                XCTAssertTrue(kindButton.exists, app.debugDescription)
                kindButton.tap()
                XCTAssertTrue(kindButton.isSelected, app.debugDescription)
                XCTAssertTrue(app.textFields["Search library"].exists, app.debugDescription)
                let unavailable = app.staticTexts["Enable Deep Library Integration and connect this tracker in Settings to view its library."]
                if disconnectedSources.contains(source) {
                    XCTAssertTrue(unavailable.waitForExistence(timeout: 10), app.debugDescription)
                } else {
                    let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                        app.buttons["Retry"].exists
                            || app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch.exists
                    }, object: nil)
                    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 35), .completed, app.debugDescription)
                }
                if unavailable.exists {
                    XCTAssertTrue(app.buttons["Tracker Settings"].exists, app.debugDescription)
                    XCTAssertFalse(app.buttons["Retry"].isEnabled)
                }
                capture("\(source) \(kind) library")
                try verifyAvailableEditorCanCancel(source: source, kind: kind)
            }
        }
        let trakt = sourcePicker.buttons["Trakt"]
        XCTAssertTrue(trakt.exists, app.debugDescription)
        trakt.tap()
        let traktKind = app.segmentedControls["trackerLibrary.mediaType"]
        XCTAssertTrue(traktKind.waitForExistence(timeout: 10), app.debugDescription)
        for kind in ["Movies", "Shows"] {
            traktKind.buttons[kind].tap()
            XCTAssertTrue(traktKind.buttons[kind].isSelected, app.debugDescription)
            let sections = app.buttons["trackerLibrary.traktSection"]
            XCTAssertTrue(sections.waitForExistence(timeout: 10), app.debugDescription)
            for title in ["Watched History", "Collection", "Watchlist"] {
                sections.tap()
                let option = app.buttons[title].firstMatch
                XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
                option.tap()
                XCTAssertEqual(currentMenuValue(sections, options: [title]), title, app.debugDescription)
                if disconnectedSources.contains("Trakt") {
                    XCTAssertTrue(app.staticTexts["Enable Deep Library Integration and connect this tracker in Settings to view its library."].waitForExistence(timeout: 10))
                } else {
                    let loaded = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
                    let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in loaded.exists || app.buttons["Retry"].exists }, object: nil)
                    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 60), .completed, app.debugDescription)
                    XCTAssertTrue(loaded.exists, "Connected Trakt \(kind) \(title) did not load: \(app.debugDescription)")
                    let edit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Edit ")).firstMatch
                    if edit.exists {
                        try reveal(edit)
                        edit.tap()
                        let editor = app.navigationBars["Edit Trakt Entry"]
                        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
                        XCTAssertTrue(app.staticTexts["Each action updates Trakt immediately."].exists)
                        XCTAssertFalse(app.staticTexts["Updating Trakt…"].exists)
                        capture("Trakt \(kind) \(title) read-only editor")
                        editor.buttons["Close"].tap()
                    }
                }
                capture("Trakt \(kind) \(title) library")
            }
            capture("Trakt \(kind) library sections")
        }
        sourcePicker.buttons["My Library"].tap()
        XCTAssertFalse(app.segmentedControls["trackerLibrary.mediaType"].exists)
        try openSettingFromLaunch("Deep Library Integration")
        try setSwitch("Deep Library Integration", to: original)
        restorations.removeLast()
        if !original {
            restartApp()
            try openLibraryTab()
            XCTAssertFalse(app.segmentedControls["trackerLibrarySourcePicker"].exists)
        }
    }

    func testBeerusEpisodeMetadataKeepsTheNewSeriesIdentity() throws {
        try openAnimeMetadataDetail(title: "Dragon Ball Super: Beerus", tmdbID: 312359)
        try verifyAnimeSeasonMetadata(seasonNumber: 1, firstEpisodeTitle: "The God Who Destroys")
        let first = app.buttons["mediaDetail.episode.s1.e1"]
        XCTAssertTrue(first.label.contains("24m"), first.debugDescription)
        XCTAssertTrue(first.label.localizedCaseInsensitiveContains("Goku"), first.debugDescription)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mediaDetail.episode.s1."))
        XCTAssertEqual(rows.count, 1, app.debugDescription)
        let picker = app.buttons["mediaDetail.seasonPicker"]
        try revealAnimeDetailElement(picker)
        picker.tap()
        XCTAssertFalse(app.buttons["mediaDetail.season.2"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["mediaDetail.season.3"].exists, app.debugDescription)
        app.buttons["mediaDetail.season.1"].tap()
        capture("Beerus has its own first episode and no older Dragon Ball seasons")
    }

    func testApothecaryEpisodeMetadataAndHiddenUpcomingSeason() throws {
        try openAnimeMetadataDetail(title: "The Apothecary Diaries", tmdbID: 220542)
        try verifyAnimeSeasonMetadata(seasonNumber: 1, firstEpisodeTitle: "Maomao")
        try verifyAnimeSeasonMetadata(seasonNumber: 2, firstEpisodeTitle: "Maomao and Maomao")
        try verifyAnimeSeasonMetadata(seasonNumber: 3, firstEpisodeTitle: "Locusts")
        try selectAnimeSeason(4)
        let empty = app.staticTexts["mediaDetail.noAiredEpisodes"]
        XCTAssertTrue(empty.waitForExistence(timeout: 60), app.debugDescription)
        try revealAnimeDetailElement(empty)
        let episodeRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mediaDetail.episode.s4."))
        XCTAssertEqual(episodeRows.count, 0, app.debugDescription)
        XCTAssertFalse(app.buttons["mediaDetail.episode.s4.e1"].exists, app.debugDescription)
        capture("Apothecary upcoming season has no aired episodes")
        try verifyAnimeSeasonMetadata(seasonNumber: 2, firstEpisodeTitle: "Maomao and Maomao")
    }

    func testLinkClickEpisodeMetadataDoesNotRegress() throws {
        try openAnimeMetadataDetail(title: "Link Click", tmdbID: 123542)
        try verifyAnimeSeasonMetadata(seasonNumber: 1, firstEpisodeTitle: "EMMA")
        try verifyAnimeSeasonMetadata(seasonNumber: 3, firstEpisodeTitle: "So Time Begins to Flow Again")
        try verifyAnimeSeasonMetadata(seasonNumber: 1, firstEpisodeTitle: "EMMA")
    }

    func testSaikiCompiledEpisodesHaveMetadataWithoutDuplicatedShortRows() throws {
        try openAnimeMetadataDetail(title: "The Disastrous Life of Saiki K.", tmdbID: 67676)
        try verifyAnimeSeasonMetadata(seasonNumber: 1, firstEpisodeTitle: "The Disastrous Life of a Psychic")
        let finalEpisode = app.buttons["mediaDetail.episode.s1.e24"]
        let followingSection = app.staticTexts["Stills"].firstMatch
        try revealAnimeDetailElement(finalEpisode, episodePosition: (season: 1, episode: 24),
            followingEpisodeSection: followingSection)
        XCTAssertTrue(finalEpisode.label.localizedCaseInsensitiveContains("Talent Blossoms"), finalEpisode.debugDescription)
        try revealAnimeDetailElement(followingSection, lastEpisodePosition: (season: 1, episode: 24))
        XCTAssertFalse(app.buttons["mediaDetail.episode.s1.e25"].exists, app.debugDescription)
        capture("Saiki details follow the twenty-fourth compilation without extra episode rows")
        try revealAnimeDetailElement(finalEpisode, episodePosition: (season: 1, episode: 24),
            followingEpisodeSection: followingSection)
        capture("Saiki season one ends at the verified twenty-fourth compilation")
        try revealAnimeDetailElement(app.buttons["mediaDetail.episode.s1.e1"], episodePosition: (season: 1, episode: 1),
            followingEpisodeSection: followingSection)
        try verifyAnimeSeasonMetadata(seasonNumber: 2, firstEpisodeTitle: "Restarting! Everyday Life")
    }

    func testRazbliutoFeatureMetadataUsesTheFullMovie() throws {
        try openAnimeMetadataDetail(title: "Great Pretender", tmdbID: 93816)
        try verifyAnimeSeasonMetadata(seasonNumber: 2, firstEpisodeTitle: "GREAT PRETENDER razbliuto")
        XCTAssertFalse(app.buttons["mediaDetail.episode.s2.e2"].exists, app.debugDescription)
        capture("Razbliuto displays one full feature with movie metadata")
    }

    private func openAnimeMetadataDetail(title: String, tmdbID: Int) throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_UI_ANIME_METADATA"] == "1" else {
            throw XCTSkip("Set ECLIPSE_UI_ANIME_METADATA=1 to verify current anime metadata without tracker writes.")
        }
        app.launchArguments += [
            "-showKanzen", "NO",
            "-showUnairedEpisodes", "NO",
            "-seasonMenu", "YES",
            "-horizontalEpisodeList", "NO",
            "-mediaDetailHiddenElements", "",
            "-mediaDetailElementOrder", "episodes,overview,actions,details,cast,ratingNotes,traktComments,stills,trailers,similarTitles"
        ]
        restartApp()
        let standard = app.tabBars.buttons["Search"].firstMatch
        let modern = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "Search", "magnifyingglass")).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in standard.exists || modern.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed, app.debugDescription)
        (standard.exists ? standard : modern).tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap()
        field.typeText(title + "\n")
        let result = app.buttons["media.search.result.tv-\(tmdbID)"]
        XCTAssertTrue(result.waitForExistence(timeout: 45), app.debugDescription)
        result.tap()
        let seasons = app.buttons["mediaDetail.seasonPicker"]
        XCTAssertTrue(seasons.waitForExistence(timeout: 90), app.debugDescription)
        try revealAnimeDetailElement(seasons)
    }

    private func selectAnimeSeason(_ number: Int) throws {
        let picker = app.buttons["mediaDetail.seasonPicker"]
        try revealAnimeDetailElement(picker)
        picker.tap()
        let season = app.buttons["mediaDetail.season.\(number)"]
        XCTAssertTrue(season.waitForExistence(timeout: 10), app.debugDescription)
        season.tap()
    }

    private func verifyAnimeSeasonMetadata(seasonNumber: Int, firstEpisodeTitle: String) throws {
        try selectAnimeSeason(seasonNumber)
        let episode = app.buttons["mediaDetail.episode.s\(seasonNumber).e1"]
        XCTAssertTrue(episode.waitForExistence(timeout: 60), app.debugDescription)
        try revealAnimeDetailElement(episode)
        XCTAssertTrue(episode.label.localizedCaseInsensitiveContains(firstEpisodeTitle), episode.debugDescription)
        XCTAssertFalse(app.staticTexts["mediaDetail.noAiredEpisodes"].exists, app.debugDescription)
        capture("Anime season \(seasonNumber) episode metadata")
    }

    private func revealAnimeDetailElement(
        _ element: XCUIElement,
        episodePosition: (season: Int, episode: Int)? = nil,
        lastEpisodePosition: (season: Int, episode: Int)? = nil,
        followingEpisodeSection: XCUIElement? = nil
    ) throws {
        let window = app.windows.firstMatch.frame
        let tabs = app.buttons.matching(NSPredicate(format: "label IN %@ AND identifier IN %@",
            ["Home", "Library", "Search", "History", "Settings", "Schedule", "Downloads"],
            ["house", "house.fill", "books.vertical", "books.vertical.fill", "magnifyingglass", "clock", "gear", "calendar", "arrow.down.circle.fill"]))
            .allElementsBoundByIndex.filter { $0.isHittable }.map(\.frame)
        let tabFrames = (app.tabBars.allElementsBoundByIndex.filter { $0.isHittable }.map(\.frame) + tabs)
            .filter {
                $0.origin.x.isFinite && $0.origin.y.isFinite && $0.width.isFinite && $0.height.isFinite
                    && $0.width > 0 && $0.height > 0 && $0.height <= 120 && window.intersects($0)
            }
        let top = tabFrames.filter { $0.maxY <= window.minY + window.height * 0.2 }.map(\.maxY).max() ?? window.minY
        let bottom = tabFrames.filter { $0.minY >= window.maxY - window.height * 0.2 }.map(\.minY).min() ?? window.maxY
        let viewport = CGRect(x: window.minX + 12, y: top + 12, width: window.width - 24, height: bottom - top - 24)
        guard viewport.width > 0, viewport.height > 0 else {
            throw UIInteractionError.unavailable("The anime detail page has no visible viewport.")
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let maximumAttempts = episodePosition == nil && lastEpisodePosition == nil ? 16 : 64
        var missingEpisodeDirection: CGFloat = 1
        for _ in 0..<maximumAttempts {
            let visibleEpisodeRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mediaDetail.episode.s"))
                .allElementsBoundByIndex.filter {
                    let row = $0.frame
                    return row.width > 0 && row.height > 0 && viewport.intersection(row).height >= 24
                }
            if let lastEpisodePosition {
                let prefix = "mediaDetail.episode.s\(lastEpisodePosition.season).e"
                let episodeNumbers = visibleEpisodeRows.compactMap { row -> Int? in
                    guard row.identifier.hasPrefix(prefix) else { return nil }
                    return Int(row.identifier.dropFirst(prefix.count))
                }
                guard episodeNumbers.allSatisfy({ $0 <= lastEpisodePosition.episode }) else {
                    throw UIInteractionError.unavailable("The anime season displays episodes beyond its final compilation: \(episodeNumbers)")
                }
            }
            let frame = element.exists ? element.frame : .zero
            let hasFrame = frame.origin.x.isFinite && frame.origin.y.isFinite
                && frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
            if hasFrame, viewport.contains(CGPoint(x: frame.midX, y: frame.midY)), element.isHittable {
                return
            }
            let distance: CGFloat
            if hasFrame {
                distance = frame.midY - viewport.midY
            } else if let episodePosition {
                let prefix = "mediaDetail.episode.s\(episodePosition.season).e"
                let episodeNumbers = visibleEpisodeRows.compactMap { row -> Int? in
                    guard row.identifier.hasPrefix(prefix) else { return nil }
                    return Int(row.identifier.dropFirst(prefix.count))
                }
                if let maximumVisible = episodeNumbers.max(), maximumVisible < episodePosition.episode {
                    missingEpisodeDirection = 1
                } else if let minimumVisible = episodeNumbers.min(), minimumVisible > episodePosition.episode {
                    missingEpisodeDirection = -1
                } else if episodeNumbers.isEmpty, let followingEpisodeSection {
                    let followingFrame = followingEpisodeSection.exists ? followingEpisodeSection.frame : .zero
                    if followingFrame.width > 0, followingFrame.height > 0,
                       viewport.intersection(followingFrame).height >= 24 {
                        missingEpisodeDirection = -1
                    }
                }
                distance = viewport.height * 0.55 * missingEpisodeDirection
            } else if lastEpisodePosition != nil {
                distance = viewport.height * 0.55
            } else {
                distance = viewport.height * (visibleEpisodeRows.isEmpty ? 0.18 : -0.18)
            }
            let maximumMovement = viewport.height * (episodePosition == nil && lastEpisodePosition == nil ? 0.22 : 0.55)
            let movement = min(max(distance, -maximumMovement), maximumMovement)
            let startY = movement >= 0
                ? viewport.maxY - min(32, viewport.height * 0.1)
                : viewport.minY + viewport.height * 0.18
            origin.withOffset(CGVector(dx: viewport.midX, dy: startY))
                .press(forDuration: 0.1,
                       thenDragTo: origin.withOffset(CGVector(dx: viewport.midX, dy: startY - movement)),
                       withVelocity: .slow,
                       thenHoldForDuration: 0.2)
        }
        throw UIInteractionError.unavailable("The anime detail control is not visible: \(element.debugDescription)")
    }

    func testLinkClickCollectionContainsEverySeasonInStoryOrder() throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_UI_LINK_CLICK"] == "1" else {
            throw XCTSkip("Set ECLIPSE_UI_LINK_CLICK=1 to verify current Link Click metadata without tracker writes.")
        }
        try openSettingFromLaunch("Deep Library Integration")
        let original = try switchValue("Deep Library Integration")
        restorations.append { [self] in
            try openSettingFromLaunch("Deep Library Integration")
            try setSwitch("Deep Library Integration", to: original)
        }
        let disconnected = try disconnectedTrackerSources()
        let sources = [("AniList", "anilist"), ("MAL", "myAnimeList")].filter { !disconnected.contains($0.0) }
        guard !sources.isEmpty else { throw XCTSkip("No anime tracker is connected on this simulator.") }
        try setSwitch("Deep Library Integration", to: true)
        restartApp()
        let standard = app.tabBars.buttons["Search"].firstMatch
        let modern = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "Search", "magnifyingglass")).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in standard.exists || modern.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed, app.debugDescription)
        (standard.exists ? standard : modern).tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap()
        field.typeText("Link Click\n")
        let result = app.buttons["media.search.result.tv-123542"]
        XCTAssertTrue(result.waitForExistence(timeout: 30), app.debugDescription)
        result.tap()
        let collection = app.buttons["Add to Collection"].firstMatch
        XCTAssertTrue(collection.waitForExistence(timeout: 60), app.debugDescription)
        collection.tap()
        for (name, service) in sources {
            let count = app.staticTexts["trackerCollection.\(service).seasonCount"]
            if service != sources.first?.1 { try reveal(count) }
            let built = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in count.exists && count.label == "All 4 seasons" }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [built], timeout: 120), .completed, app.debugDescription)
            var titles: [String] = []
            for index in 0..<4 {
                let title = app.staticTexts["trackerCollection.\(service).season.\(index)"]
                try reveal(title)
                XCTAssertTrue(title.waitForExistence(timeout: 60), app.debugDescription)
                titles.append(title.label)
            }
            XCTAssertTrue(titles[2].localizedCaseInsensitiveContains("Bridon"), "\(name): \(titles)")
            XCTAssertTrue(titles[3].contains("III") || titles[3].contains("3"), "\(name): \(titles)")
            let receipt = XCTAttachment(string: "\(name): \(titles.joined(separator: " → "))")
            receipt.name = "Link Click all-season tracker identities"
            receipt.lifetime = .keepAlways
            add(receipt)
            capture("\(name) Link Click all-season collection")
        }
    }

    func testDeepLibraryIncludesPlanningAndAllStatuses() throws {
        try openSettingFromLaunch("Deep Library Integration")
        let original = try switchValue("Deep Library Integration")
        restorations.append { [self] in
            try openSettingFromLaunch("Deep Library Integration")
            try setSwitch("Deep Library Integration", to: original)
        }
        let disconnected = try disconnectedTrackerSources()
        let sources = ["AniList", "MAL"].filter { !disconnected.contains($0) }
        guard !sources.isEmpty else { throw XCTSkip("No anime tracker is connected on this simulator.") }
        try setSwitch("Deep Library Integration", to: true)
        restartApp()
        try openLibraryTab()
        let picker = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        for source in sources {
            picker.buttons[source].tap()
            XCTAssertEqual(try menuValue("trackerLibrary.status", options: ["All Statuses"]), "All Statuses")
            for status in ["Planning to Watch", "Completed", "All Statuses"] {
                try selectMenu("trackerLibrary.status", value: status)
                let loaded = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
                let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                    loaded.exists || app.buttons["Retry"].exists
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 60), .completed, app.debugDescription)
                XCTAssertTrue(loaded.exists, app.debugDescription)
                capture("\(source) \(status) deep library")
            }
            if source == "AniList" {
                XCTAssertTrue(app.buttons["trackerLibrary.anilistSection"].exists, app.debugDescription)
            }
        }
    }

    func testMatchedTrackerCardOpensNormalMediaDetails() throws {
        try openSettingFromLaunch("Deep Library Integration")
        let original = try switchValue("Deep Library Integration")
        restorations.append { [self] in
            try openSettingFromLaunch("Deep Library Integration")
            try setSwitch("Deep Library Integration", to: original)
        }
        let disconnected = try disconnectedTrackerSources()
        guard let source = ["AniList", "MAL", "Trakt"].first(where: { !disconnected.contains($0) }) else {
            throw XCTSkip("No tracker account is connected on this simulator.")
        }
        try setSwitch("Deep Library Integration", to: true)
        restartApp()
        try openLibraryTab()
        let picker = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.buttons[source].tap()
        let loaded = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 60), app.debugDescription)
        if loaded.label.hasPrefix("0 ") { throw XCTSkip("The selected tracker list is empty on this simulator.") }
        let ready = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "trackerLibrary.open.", "Ready")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 60), "The visible tracker cards did not resolve: \(app.debugDescription)")
        try reveal(ready)
        capture("Resolved tracker cards before opening")
        let entryID = String(ready.identifier.dropFirst("trackerLibrary.open.".count))
        let trackerProgress = app.staticTexts["trackerLibrary.progress.\(entryID)"]
        let progressLabel = trackerProgress.exists ? trackerProgress.label : nil
        ready.tap()
        let detailAction = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "(Play.*|Resume.*|Continue.*|No Sources|Choose Episode|Choose Sources|Rewatch)")).firstMatch
        XCTAssertTrue(detailAction.waitForExistence(timeout: 60), "A tracker card must open normal media details with the playback action: \(app.debugDescription)")
        if ["Choose Episode", "Choose Sources", "Rewatch"].contains(detailAction.label) {
            XCTAssertTrue(app.staticTexts["trackerLibrary.playbackNotice"].exists, "An unavailable next episode needs an explanation.")
        } else if source != "Trakt", let progressLabel, let raw = progressLabel.split(separator: " ").first, let watched = Int(raw), detailAction.label.hasPrefix("Play E") {
            let expected = try trackerResumeAction(entryID: entryID, watched: watched)
            XCTAssertEqual(detailAction.label, expected, "Play from a tracker library must use the next physical episode for its canonical progress.")
        }
        let receipt = XCTAttachment(string: "\(source): tracker progress \(progressLabel ?? "n/a"); detail action \(detailAction.label)")
        receipt.name = "Tracker-first playback selection"
        receipt.lifetime = .keepAlways
        add(receipt)
        capture("Tracker card opens normal media details")
        if detailAction.label == "Choose Episode" {
            detailAction.tap()
            let chooser = app.descendants(matching: .any).matching(identifier: "mediaDetail.episodeChooser").firstMatch
            XCTAssertTrue(chooser.waitForExistence(timeout: 15), app.debugDescription)
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                hasVisibleFrame(chooser)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed, "Choose Episode must reveal the episode list.")
            XCTAssertFalse(app.alerts["Tracker Playback"].exists)
            capture("Choose Episode opens the existing episode list")
        }
    }

    func testTrackerProgressSelectsNextAvailableEpisode() throws {
        guard let title = ProcessInfo.processInfo.environment["ECLIPSE_UI_TRACKER_RESUME_TITLE"], !title.isEmpty else {
            throw XCTSkip("Set ECLIPSE_UI_TRACKER_RESUME_TITLE to an existing tracker title with an aired next episode.")
        }
        try openSettingFromLaunch("Deep Library Integration")
        let original = try switchValue("Deep Library Integration")
        restorations.append { [self] in
            try openSettingFromLaunch("Deep Library Integration")
            try setSwitch("Deep Library Integration", to: original)
        }
        let disconnected = try disconnectedTrackerSources()
        guard let source = ["AniList", "MAL"].first(where: { !disconnected.contains($0) }) else { throw XCTSkip("No anime tracker connected.") }
        try setSwitch("Deep Library Integration", to: true)
        restartApp()
        try openLibraryTab()
        let picker = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.buttons[source].tap()
        let summary = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 60), app.debugDescription)
        let search = app.textFields["Search library"]
        search.tap()
        search.typeText(title)
        let card = app.buttons["Open \(title)"]
        guard card.waitForExistence(timeout: 10) else { throw XCTSkip("The configured tracker fixture title is absent.") }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Ready"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed, app.debugDescription)
        let entryID = String(card.identifier.dropFirst("trackerLibrary.open.".count))
        let progress = app.staticTexts["trackerLibrary.progress.\(entryID)"]
        let raw = try XCTUnwrap(progress.label.split(separator: " ").first)
        let watched = try XCTUnwrap(Int(raw))
        let expectedAction = try trackerResumeAction(entryID: entryID, watched: watched,
            configuredAction: ProcessInfo.processInfo.environment["ECLIPSE_UI_TRACKER_RESUME_ACTION"])
        try reveal(card)
        card.tap()
        let expected = app.buttons[expectedAction]
        XCTAssertTrue(expected.waitForExistence(timeout: 60), "Expected tracker continuation after \(watched) watched episodes: \(app.debugDescription)")
        let receipt = XCTAttachment(string: "\(source) / \(title): \(watched) watched -> \(expected.label). No playback or tracker write was performed.")
        receipt.name = "Aired tracker episode selection"
        receipt.lifetime = .keepAlways
        add(receipt)
        capture("Tracker progress selects aired next episode")
    }

    private func trackerResumeAction(entryID: String, watched: Int, configuredAction: String? = nil) throws -> String {
        if let configuredAction {
            guard configuredAction == "Play"
                    || configuredAction.range(of: "^Play (E[1-9][0-9]*|S(0|[1-9][0-9]*)E[1-9][0-9]*)$", options: .regularExpression) != nil else {
                throw UIInteractionError.unexpectedValue("ECLIPSE_UI_TRACKER_RESUME_ACTION must specify the fixture’s exact Play label.")
            }
            return configuredAction
        }
        if ["anilist:anime:21804", "myAnimeList:anime:33255"].contains(entryID) {
            guard (0..<120).contains(watched) else {
                throw UIInteractionError.unexpectedValue("Saiki has no unwatched canonical short at this progress.")
            }
            return "Play E\(watched / 5 + 1)"
        }
        if ["anilist:anime:170935", "myAnimeList:anime:57184"].contains(entryID) {
            throw XCTSkip("Run the configured Razbliuto fixture with ECLIPSE_UI_TRACKER_RESUME_ACTION set to the exact label for its full movie or four-part edition.")
        }
        return "Play E\(watched + 1)"
    }

    func testTrackerLibraryAllStatusesLoadsAndFilters() throws {
        try openSettingFromLaunch("Deep Library Integration")
        let original = try switchValue("Deep Library Integration")
        restorations.append { [self] in
            try openSettingFromLaunch("Deep Library Integration")
            try setSwitch("Deep Library Integration", to: original)
        }
        let disconnected = try disconnectedTrackerSources()
        guard let source = ["AniList", "MAL"].first(where: { !disconnected.contains($0) }) else { throw XCTSkip("No anime tracker connected.") }
        try setSwitch("Deep Library Integration", to: true)
        restartApp()
        try openLibraryTab()
        let picker = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.buttons[source].tap()
        let summary = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 60), app.debugDescription)
        let start = Date()
        try selectMenu("trackerLibrary.status", value: "All Statuses")
        XCTAssertTrue(summary.waitForExistence(timeout: 90), app.debugDescription)
        let total = summary.label
        let receipt = XCTAttachment(string: "\(source) All Statuses: \(total), \(Date().timeIntervalSince(start)) seconds from selecting the list through completion.")
        receipt.name = "Live paginated library loading"
        receipt.lifetime = .keepAlways
        add(receipt)
        capture("All statuses library loaded")
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trackerLibrary.open.")).firstMatch
        guard card.exists else { throw XCTSkip("The connected library is empty.") }
        let originalCardID = card.identifier
        let originalCardTitle = card.label
        let term = String(originalCardTitle.dropFirst(5).prefix(12))
        let search = app.textFields["Search library"]
        search.tap()
        search.typeText(term)
        XCTAssertTrue(app.buttons["Clear Search"].waitForExistence(timeout: 5))
        let filteredCard = app.buttons[originalCardID]
        XCTAssertTrue(filteredCard.waitForExistence(timeout: 5), "Local filtering must preserve the selected title.")
        XCTAssertEqual(filteredCard.label, originalCardTitle)
        capture("Local library filter")
        app.buttons["Clear Search"].tap()
        XCTAssertTrue(app.staticTexts[total].waitForExistence(timeout: 5))
    }

    func testLocalEPUBNovelReaderNavigationBookmarksSearchAndSettings() throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_UI_NOVEL"] == "1" else {
            throw XCTSkip("Set ECLIPSE_UI_NOVEL=1 with a real Alice EPUB imported in the simulator's active profile.")
        }
        app.launchArguments = []
        if app.state == .notRunning { app.launch() } else { app.activate() }
        let readerSettingsBack = app.navigationBars.buttons["Reader Settings"].firstMatch
        if !app.navigationBars["Reader Settings"].exists, readerSettingsBack.exists, readerSettingsBack.isHittable {
            try openNovelSettings()
        }
        for title in ["Reader Settings", "Chapters", "Bookmarks", "Find in Chapter"] where app.navigationBars[title].exists {
            try closeNovelPanel(title)
        }
        let readerClose = app.buttons["novel.close"].firstMatch
        if readerClose.waitForExistence(timeout: 2), readerClose.isHittable { readerClose.tap() }
        try openNovelReaderLibrary()
        let localSource = app.segmentedControls["trackerLibrarySourcePicker"].buttons["Local"].firstMatch
        if localSource.exists, localSource.isHittable { localSource.tap() }
        let books = app.staticTexts["Books"].firstMatch
        guard books.waitForExistence(timeout: 15) else {
            captureNovelNavigationFailure("Reader Library is missing its EPUB Books shelf")
            throw UIInteractionError.unavailable("The confirmed Reader Library has no imported EPUB Books shelf.")
        }
        let alice = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", "Alice", "Wonderland")).firstMatch
        try reveal(alice)
        alice.tap()
        guard app.navigationBars["Book"].waitForExistence(timeout: 10) else { throw UIInteractionError.unavailable("Alice did not open its imported book contents.") }
        let firstChapter = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "CHAPTER I.")).firstMatch
        try reveal(firstChapter)
        firstChapter.tap()
        try waitForNovelChapter("CHAPTER I.", containing: "Alice was beginning")
        capture("EPUB Alice narrative chapter I")

        try openNovelSettings()
        let navigationOptions = ["Scrolling", "Pages"]
        let fontOptions = ["System", "Georgia", "Times", "Helvetica", "Charter", "New York", "Rounded", "Monospace", "Serif", "Sans Serif"]
        if ProcessInfo.processInfo.environment["ECLIPSE_UI_NOVEL_RECOVER_SCROLL"] == "1" {
            try selectNovelMenu("novel.navigation", label: "Navigation", value: "Scrolling")
        }
        if let recoverySize = ProcessInfo.processInfo.environment["ECLIPSE_UI_NOVEL_RECOVER_FONT_SIZE"] {
            guard let size = Int(recoverySize), (12...32).contains(size) else {
                throw UIInteractionError.unexpectedValue("The opt-in font size recovery value must be within 12...32.")
            }
            try setNovelFontSize(size)
        }
        let originalNavigation = try novelMenuValue("novel.navigation", label: "Navigation", options: navigationOptions)
        let originalFont = try novelMenuValue("novel.font", label: "Font", options: fontOptions)
        let originalSize = try novelFontSize()
        let settingsReceipt = XCTAttachment(string: "Navigation=\(originalNavigation)\nFont=\(originalFont)\nFont size=\(originalSize)")
        settingsReceipt.name = "Original novel settings"
        settingsReceipt.lifetime = .keepAlways
        add(settingsReceipt)
        restorations.append { [self] in
            try openNovelSettings()
            try selectNovelMenu("novel.navigation", label: "Navigation", value: originalNavigation)
            try selectNovelMenu("novel.font", label: "Font", value: originalFont)
            try setNovelFontSize(originalSize)
            try closeNovelPanel("Reader Settings")
        }
        try selectNovelMenu("novel.navigation", label: "Navigation", value: "Scrolling")
        try closeNovelPanel("Reader Settings")
        capture("EPUB Alice scrolling layout")
        try openNovelSettings()
        try selectNovelMenu("novel.navigation", label: "Navigation", value: "Pages")
        try selectNovelMenu("novel.font", label: "Font", value: originalFont == "Georgia" ? "System" : "Georgia")
        try setNovelFontSize(originalSize <= 24 ? 28 : 20)
        try closeNovelPanel("Reader Settings")
        guard app.buttons["novel.nextPage"].waitForExistence(timeout: 10) else { throw UIInteractionError.unavailable("Paged navigation controls did not appear.") }
        try assertNovelViewportAvoidsChrome()
        let originalPageLabel = try novelPageIndicator()
        let pageParts = originalPageLabel.components(separatedBy: " / ")
        guard pageParts.count == 2, let page = Int(pageParts[0]), let pages = Int(pageParts[1]), pages > 1 else {
            throw UIInteractionError.unexpectedValue("Alice's first narrative chapter did not paginate into multiple pages.")
        }
        let forward = page < pages
        let pageButton = app.buttons[forward ? "novel.nextPage" : "novel.previousPage"]
        pageButton.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (try? self.novelPageIndicator()) == "\(page + (forward ? 1 : -1)) / \(pages)" }, "Page navigation must move the actual EPUB document.")
        app.buttons[forward ? "novel.previousPage" : "novel.nextPage"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (try? self.novelPageIndicator()) == originalPageLabel })
        capture("EPUB Alice paged typography")
        try openNovelSettings()
        try selectNovelMenu("novel.font", label: "Font", value: originalFont)
        try setNovelFontSize(originalSize)
        try closeNovelPanel("Reader Settings")

        try selectNovelChapter("CHAPTER II.")
        try waitForNovelChapter("CHAPTER II.", containing: "Curiouser")
        try showNovelBookmarks()
        let originalBookmarks = novelBookmarkLabels()
        try closeNovelPanel("Bookmarks")
        try ensureNovelControls()
        app.buttons["novel.search"].tap()
        guard app.navigationBars["Find in Chapter"].waitForExistence(timeout: 10) else { throw UIInteractionError.unavailable("Find in Chapter did not open.") }
        let find = app.textFields["novel.findQuery"]
        guard find.waitForExistence(timeout: 5) else { throw UIInteractionError.unavailable("The chapter search field is unavailable.") }
        try replaceNovelText(find, with: "mouse")
        let matches = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[1-9][0-9]* of [1-9][0-9]* matches")).firstMatch
        guard matches.waitForExistence(timeout: 10) else { throw UIInteractionError.unavailable("Alice chapter II returned no matches for its Mouse passage.") }
        let firstMatch = matches.label
        let nextMatch = app.buttons["Next"].firstMatch
        guard nextMatch.exists, nextMatch.isEnabled else { throw UIInteractionError.unavailable("The search match navigation is unavailable.") }
        nextMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { matches.label != firstMatch }, "Find in Chapter must advance its real match counter.")
        capture("EPUB Alice chapter II search results")
        try closeNovelPanel("Find in Chapter")
        let bookmarkPosition = try novelPageIndicator()
        try ensureNovelControls()
        app.buttons["novel.bookmarks"].tap()
        let save = app.buttons["Save Bookmark"].firstMatch
        guard save.waitForExistence(timeout: 5), save.isEnabled else { throw UIInteractionError.unavailable("The current chapter position cannot be bookmarked.") }
        save.tap()
        try showNovelBookmarks()
        let savedBookmarks = novelBookmarkLabels()
        guard savedBookmarks.contains(where: { $0.localizedCaseInsensitiveContains("CHAPTER II.") }) else {
            throw UIInteractionError.unavailable("The saved chapter II bookmark is absent from Bookmarks.")
        }
        let newLabel = savedBookmarks.first { label in
            savedBookmarks.filter { $0 == label }.count > originalBookmarks.filter { $0 == label }.count
        }
        let newIndex = newLabel.map { label in originalBookmarks.filter { $0 == label }.count }
        if let newLabel, let newIndex {
            restorations.append { [self] in try removeNovelBookmark(label: newLabel, index: newIndex) }
        }
        capture("EPUB Alice saved chapter bookmark")
        try closeNovelPanel("Bookmarks")

        try selectNovelChapter("CHAPTER III.")
        try waitForNovelChapter("CHAPTER III.", containing: "queer-looking party")
        let chapterIIIPosition = try novelPageIndicator()
        try showNovelBookmarks()
        let bookmark = app.buttons.matching(NSPredicate(format: "label == %@", newLabel ?? savedBookmarks.first(where: { $0.localizedCaseInsensitiveContains("CHAPTER II.") }) ?? "")).element(boundBy: newIndex ?? 0)
        try reveal(bookmark)
        bookmark.tap()
        try waitForNovelChapter("CHAPTER II.", containing: "Curiouser")
        XCTAssertTrue(waitUntil(timeout: 10) { (try? self.novelPageIndicator()) == bookmarkPosition }, "A saved bookmark must restore its page in the correct chapter.")
        try ensureNovelControls()
        let nextChapter = app.buttons["novel.nextChapter"]
        guard nextChapter.exists, nextChapter.isEnabled else { throw UIInteractionError.unavailable("Next Chapter is unavailable.") }
        nextChapter.tap()
        try waitForNovelChapter("CHAPTER III.", containing: "queer-looking party")
        XCTAssertTrue(waitUntil(timeout: 10) { (try? self.novelPageIndicator()) == chapterIIIPosition }, "Next Chapter must restore chapter III's own position instead of replaying chapter II's bookmark.")
        try assertNovelViewportAvoidsChrome()
        capture("EPUB Alice next chapter preserves its own position")

        if let newLabel, let newIndex {
            try removeNovelBookmark(label: newLabel, index: newIndex)
            restorations.removeLast()
        }
        try openNovelSettings()
        try selectNovelMenu("novel.navigation", label: "Navigation", value: originalNavigation)
        try selectNovelMenu("novel.font", label: "Font", value: originalFont)
        try setNovelFontSize(originalSize)
        XCTAssertEqual(try novelMenuValue("novel.navigation", label: "Navigation", options: navigationOptions), originalNavigation)
        XCTAssertEqual(try novelMenuValue("novel.font", label: "Font", options: fontOptions), originalFont)
        XCTAssertEqual(try novelFontSize(), originalSize)
        capture("EPUB Reader settings restored through UI")
        try closeNovelPanel("Reader Settings")
        restorations.removeLast()
    }

    func testReaderCollectionSheetShowsLocalAndConnectedTrackers() throws {
        guard let title = ProcessInfo.processInfo.environment["ECLIPSE_UI_IMPORTED_MANGA_TITLE"], !title.isEmpty else {
            throw XCTSkip("Set ECLIPSE_UI_IMPORTED_MANGA_TITLE to an imported Reader history title.")
        }
        try openSettingFromLaunch("Deep Library Integration")
        let original = try switchValue("Deep Library Integration")
        restorations.append { [self] in
            try openSettingFromLaunch("Deep Library Integration")
            try setSwitch("Deep Library Integration", to: original)
        }
        let disconnected = try disconnectedTrackerSources()
        try setSwitch("Deep Library Integration", to: true)
        restartApp()
        if app.buttons["Quick Actions"].waitForExistence(timeout: 5) {
            app.buttons["Quick Actions"].tap()
            let reader = app.buttons["Switch to Reader Mode"]
            if reader.waitForExistence(timeout: 5) { reader.tap() }
        }
        let history = app.tabBars.buttons["History"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10), app.debugDescription)
        history.tap()
        let imported = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        try reveal(imported)
        imported.tap()
        let details = app.buttons["Open Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10), app.debugDescription)
        details.tap()
        let collections = app.buttons["reader.addToCollection"]
        try reveal(collections)
        collections.tap()
        XCTAssertTrue(app.navigationBars["Add to Collection"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Local")).firstMatch.exists)
        for (source, header) in [("AniList", "AniList"), ("MAL", "MyAnimeList")] where !disconnected.contains(source) {
            let label = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", header)).firstMatch
            try reveal(label)
            XCTAssertTrue(label.exists, app.debugDescription)
        }
        capture("Local and connected Reader trackers")
        app.buttons["Done"].tap()
        try openSettingFromLaunch("Deep Library Integration")
        try setSwitch("Deep Library Integration", to: original)
        restorations.removeLast()
    }

    func testImportedMangaCanChooseReaderSource() throws {
        guard let title = ProcessInfo.processInfo.environment["ECLIPSE_UI_IMPORTED_MANGA_TITLE"], !title.isEmpty else {
            throw XCTSkip("Set ECLIPSE_UI_IMPORTED_MANGA_TITLE to an imported Reader history title without a source.")
        }
        restartApp()
        if app.buttons["Quick Actions"].waitForExistence(timeout: 5) {
            app.buttons["Quick Actions"].tap()
            let reader = app.buttons["Switch to Reader Mode"]
            XCTAssertTrue(reader.waitForExistence(timeout: 5))
            reader.tap()
        }
        let history = app.tabBars.buttons["History"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10), app.debugDescription)
        history.tap()
        let imported = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        try reveal(imported)
        imported.tap()
        let details = app.buttons["Open Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10), app.debugDescription)
        details.tap()
        let choose = app.buttons["reader.chooseSource"]
        try reveal(choose)
        XCTAssertTrue(choose.isEnabled)
        choose.tap()
        XCTAssertTrue(app.navigationBars["Choose Reader Source"].waitForExistence(timeout: 10), app.debugDescription)
        let field = app.textFields["Search title"]
        XCTAssertTrue(field.exists)
        XCTAssertEqual(field.value as? String, title)
        XCTAssertTrue(app.buttons.matching(identifier: "Search").allElementsBoundByIndex.contains { $0.isHittable && $0.isEnabled })
        capture("Imported manga source picker")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
    }

    func testTrackerMangaOpensReaderOrActionableSourceFallback() throws {
        try openSettingFromLaunch("Deep Library Integration")
        let original = try switchValue("Deep Library Integration")
        restorations.append { [self] in
            try openSettingFromLaunch("Deep Library Integration")
            try setSwitch("Deep Library Integration", to: original)
        }
        let disconnected = try disconnectedTrackerSources()
        guard let source = ["AniList", "MAL"].first(where: { !disconnected.contains($0) }) else { throw XCTSkip("No manga tracker connected.") }
        try setSwitch("Deep Library Integration", to: true)
        app.launchArguments += ["-showKanzen", "YES"]
        restartApp()
        try openNovelReaderLibrary(allowModeSwitch: false)
        let picker = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.buttons[source].tap()
        let kinds = app.segmentedControls["trackerLibrary.mediaType"]
        XCTAssertTrue(kinds.waitForExistence(timeout: 10))
        kinds.buttons["Manga"].tap()
        let summary = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 60), app.debugDescription)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trackerLibrary.open.")).firstMatch
        guard card.exists else { throw XCTSkip("The connected manga list is empty.") }
        try reveal(card)
        card.tap()
        let chooser = app.navigationBars["Choose Match"]
        if chooser.waitForExistence(timeout: 8) {
            let searchSources = app.buttons["Search Reader Sources"]
            XCTAssertTrue(searchSources.waitForExistence(timeout: 10), app.debugDescription)
            searchSources.tap()
            XCTAssertTrue(app.buttons["Manage Sources"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.searchFields.firstMatch.exists || app.textFields.firstMatch.exists, "Fallback must open normal Reader search.")
            capture("Manga source search fallback")
        } else {
            let chapters = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "chapter")).firstMatch
            XCTAssertTrue(chapters.waitForExistence(timeout: 30), "Matched manga must open its normal Reader details: \(app.debugDescription)")
            capture("Matched manga reader details")
        }
    }

    @discardableResult
    private func verifyAvailableEditorCanCancel(source: String, kind: String) throws -> Bool {
        let summary = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
        guard summary.exists,
              let countText = summary.label.split(separator: " ").first,
              let count = Int(countText), count > 0 else { return false }
        let originalSummary = summary.label
        let editButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Edit ")).firstMatch
        try reveal(editButton)
        let entryTitle = String(editButton.label.dropFirst("Edit ".count))
        editButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let editor = app.navigationBars["Edit Tracker Entry"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        let cancel = editor.buttons["Cancel"]
        defer {
            if editor.exists && cancel.exists { cancel.tap() }
        }
        XCTAssertTrue(app.staticTexts[entryTitle].exists, app.debugDescription)
        let trackerName = source == "MAL" ? "MyAnimeList" : "AniList"
        XCTAssertTrue(app.staticTexts["Save changes to \(trackerName)."].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Status"].exists
            || app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Status")).firstMatch.exists, app.debugDescription)
        let progressLabel = kind == "Anime" ? "Episodes Watched" : "Chapters Read"
        let progress = app.textFields[progressLabel]
        XCTAssertTrue(app.staticTexts[progressLabel].exists, "Progress needs a visible label even when it already has a value.")
        XCTAssertTrue(progress.exists, app.debugDescription)
        XCTAssertNotNil((progress.value as? String).flatMap(Int.init), "The editor must show existing \(progressLabel.lowercased()).")
        XCTAssertTrue(app.steppers.firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Rating:")).firstMatch.exists
            || app.steppers.matching(NSPredicate(format: "label BEGINSWITH %@", "Rating:")).firstMatch.exists, app.debugDescription)
        let save = editor.buttons["Save"]
        XCTAssertTrue(save.exists, app.debugDescription)
        XCTAssertFalse(save.isEnabled, "Opening an unchanged tracker entry must not enable Save.")
        XCTAssertFalse(app.buttons["Saving…"].exists)
        let rating = app.steppers.firstMatch
        let increment = rating.buttons["Increment"]
        let decrement = rating.buttons["Decrement"]
        let adjustment = increment.exists && increment.isEnabled ? increment : decrement
        XCTAssertTrue(adjustment.exists && adjustment.isEnabled, "One bounded rating adjustment must be available.")
        adjustment.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in save.exists && save.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed, "Changing the local rating must enable Save.")
        XCTAssertFalse(app.buttons["Saving…"].exists)
        capture("\(source) \(kind) unsaved rating change before Cancel")
        XCTAssertTrue(cancel.exists && cancel.isEnabled, app.debugDescription)
        cancel.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !editor.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 60) { self.app.staticTexts[originalSummary].exists && self.app.buttons["trackerLibrary.refresh"].isEnabled },
            "Cancelling the editor must preserve the loaded tracker list after refresh.")
        return true
    }

    private func disconnectedTrackerSources() throws -> Set<String> {
        var result = Set<String>()
        for (source, title) in [("AniList", "AniList"), ("MAL", "MyAnimeList"), ("Trakt", "Trakt")] {
            let service = app.staticTexts[title].firstMatch
            try reveal(service)
            let titleFrame = service.frame
            let rowButtons = app.buttons.matching(NSPredicate(format: "label IN %@", ["Connect", "Disconnect"]))
                .allElementsBoundByIndex.filter {
                    $0.frame.minX > titleFrame.minX && abs($0.frame.midY - titleFrame.midY) < 36
                }
            guard rowButtons.count == 1, let action = rowButtons.first else {
                throw UIInteractionError.unavailable("Could not identify the \(title) account row.")
            }
            if action.label == "Connect" {
                let notConnected = app.staticTexts.matching(identifier: "Not connected").allElementsBoundByIndex.contains {
                    $0.frame.minY > titleFrame.minY && $0.frame.minY < titleFrame.maxY + 24
                }
                guard notConnected else {
                    throw UIInteractionError.unexpectedValue("The \(title) account row did not confirm its connection state.")
                }
                result.insert(source)
            }
        }
        return result
    }

    private func ensureNovelControls() throws {
        let document = app.webViews["novel.document"].firstMatch
        guard document.waitForExistence(timeout: 15) else { throw UIInteractionError.unavailable("The real novel document is unavailable.") }
        let contents = app.buttons["novel.contents"].firstMatch
        if !contents.isHittable { document.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }
        guard waitUntil(timeout: 5, { contents.exists && contents.isHittable }) else {
            throw UIInteractionError.unavailable("The novel reader controls could not be revealed.")
        }
    }

    private func assertNovelViewportAvoidsChrome() throws {
        try ensureNovelControls()
        let document = app.webViews["novel.document"].firstMatch
        let header = ["novel.close", "novel.chapters", "novel.settings"].map { app.buttons[$0].firstMatch }
        let footer = ["novel.contents", "novel.bookmarks", "novel.search", "novel.previousPage", "novel.nextPage"].map { app.buttons[$0].firstMatch }
        guard waitUntil(timeout: 5, {
            guard header.allSatisfy({ $0.exists && $0.frame.height > 0 }), footer.allSatisfy({ $0.exists && $0.frame.height > 0 }), document.frame.height > 0 else { return false }
            let headerBottom = header.map { $0.frame.maxY }.max() ?? 0
            let footerTop = footer.map { $0.frame.minY }.min() ?? 0
            return document.frame.minY >= headerBottom - 1 && document.frame.maxY <= footerTop + 1
        }) else {
            captureNovelNavigationFailure("Paged novel viewport overlaps reader controls")
            throw UIInteractionError.unexpectedValue("The paged document viewport overlaps its header or footer controls.")
        }
        XCTAssertGreaterThanOrEqual(document.frame.minY, (header.map { $0.frame.maxY }.max() ?? 0) - 1)
        XCTAssertLessThanOrEqual(document.frame.maxY, (footer.map { $0.frame.minY }.min() ?? 0) + 1)
    }

    private func openNovelReaderLibrary(allowModeSwitch: Bool = true) throws {
        func readerIsVisible() -> Bool {
            let switchToMedia = app.buttons["Switch to Media Mode"].firstMatch
            let readerTabs = app.tabBars.containing(.button, identifier: "History").firstMatch
            let history = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "History", "clock")).firstMatch
            let settings = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "Settings", "gear")).firstMatch
            return switchToMedia.exists && switchToMedia.isHittable
                || readerTabs.exists && readerTabs.buttons["Settings"].exists
                || history.exists && history.isHittable && settings.exists && settings.isHittable
        }
        if !readerIsVisible() {
            if !allowModeSwitch {
                guard waitUntil(timeout: 30, { readerIsVisible() }) else {
                    throw UIInteractionError.unavailable("The transient Reader mode launch did not expose Reader navigation.")
                }
            }
        }
        if allowModeSwitch && !readerIsVisible() {
            let quickActions = app.buttons["Quick Actions"].firstMatch
            guard quickActions.waitForExistence(timeout: 15), quickActions.isHittable else {
                captureNovelNavigationFailure("Reader mode entry is unavailable")
                throw UIInteractionError.unavailable("Neither Reader mode nor its Quick Actions entry is visible.")
            }
            let reader = app.buttons["Switch to Reader Mode"].firstMatch
            func readerActionIsExpanded() -> Bool {
                reader.exists && reader.isHittable && reader.frame.width >= 40 && reader.frame.height >= 40
            }
            if !readerActionIsExpanded() {
                quickActions.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                if !waitUntil(timeout: 3, { readerActionIsExpanded() }) {
                    let handle = quickActions.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    let inward: CGFloat = quickActions.frame.midX >= app.frame.midX ? -64 : 64
                    handle.press(forDuration: 0.1, thenDragTo: handle.withOffset(CGVector(dx: inward, dy: 0)))
                }
            }
            guard waitUntil(timeout: 5, { readerActionIsExpanded() }) else {
                captureNovelNavigationFailure("Quick Actions is missing Reader mode")
                throw UIInteractionError.unavailable("Quick Actions did not expand its Reader mode button beyond the collapsed handle.")
            }
            capture("Quick Actions expanded Reader mode controls")
            reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        guard waitUntil(timeout: 30, { readerIsVisible() }) else {
            captureNovelNavigationFailure("Reader mode did not become visible after switching")
            throw UIInteractionError.timedOut("Switching modes did not expose Reader's mode button or History and Settings tabs.")
        }
        let standardTab = app.tabBars.containing(.button, identifier: "History").buttons["Library"].firstMatch
        let modernTab = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "Library", "books.vertical")).firstMatch
        guard waitUntil(timeout: 15, {
            standardTab.exists && standardTab.isHittable || modernTab.exists && modernTab.isHittable
        }) else {
            captureNovelNavigationFailure("Reader Library tab is unavailable")
            throw UIInteractionError.unavailable("Reader's Library tab is unavailable after the mode transition.")
        }
        let tab = standardTab.exists && standardTab.isHittable ? standardTab : modernTab
        tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if app.navigationBars["Book"].exists {
            let back = app.navigationBars.buttons["Library"].firstMatch
            if back.exists, back.isHittable { back.tap() }
        }
        let importer = app.buttons["reader.importEPUB"].firstMatch
        let refresh = app.buttons["Refresh Sources"].firstMatch
        guard waitUntil(timeout: 15, { importer.exists && refresh.exists }) else {
            captureNovelNavigationFailure("Library navigation did not open Reader Library")
            throw UIInteractionError.unavailable("Library navigation did not expose Reader's EPUB import and source refresh controls.")
        }
        capture("Reader Library confirmed after mode transition")
    }

    private func captureNovelNavigationFailure(_ title: String) {
        capture(title)
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = title + " accessibility hierarchy"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForNovelChapter(_ prefix: String, containing text: String) throws {
        let header = app.buttons["novel.chapters"].firstMatch
        let document = app.webViews["novel.document"].firstMatch
        guard waitUntil(timeout: 20, {
            let title = header.value as? String ?? ""
            return header.exists && title.localizedCaseInsensitiveContains(prefix) && document.exists
                && document.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch.exists
        }) else {
            throw UIInteractionError.unavailable("The novel did not render \(prefix) with its expected text: \(app.debugDescription)")
        }
    }

    private func replaceNovelText(_ field: XCUIElement, with text: String) throws {
        guard field.exists, field.isHittable else { throw UIInteractionError.unavailable("The reader text field is unavailable.") }
        field.tap()
        if let value = field.value as? String, value != field.placeholderValue, !value.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(text)
    }

    private func selectNovelChapter(_ prefix: String) throws {
        try ensureNovelControls()
        app.buttons["novel.contents"].tap()
        guard app.navigationBars["Chapters"].waitForExistence(timeout: 10) else { throw UIInteractionError.unavailable("The novel contents sheet did not open.") }
        activeSettingsPage = "Chapters"
        let field = app.textFields["Filter chapters"].firstMatch
        guard field.waitForExistence(timeout: 5) else { throw UIInteractionError.unavailable("The chapter filter is unavailable.") }
        try replaceNovelText(field, with: prefix)
        let chapter = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", prefix)).firstMatch
        try reveal(chapter)
        chapter.tap()
        activeSettingsPage = nil
        guard waitUntil(timeout: 10, { !self.app.navigationBars["Chapters"].exists }) else { throw UIInteractionError.timedOut("Selecting a chapter did not dismiss Contents.") }
    }

    private func openNovelSettings() throws {
        for title in ["Chapters", "Bookmarks", "Find in Chapter"] where app.navigationBars[title].exists {
            try closeNovelPanel(title)
        }
        if app.navigationBars["Reader Settings"].exists {
            try dismissNovelMenuIfNeeded()
            activeSettingsPage = "Reader Settings"
            return
        }
        let back = app.navigationBars.buttons["Reader Settings"].firstMatch
        if back.exists, back.isHittable {
            back.tap()
        } else {
            try ensureNovelControls()
            let settings = app.buttons["novel.settings"].firstMatch
            guard settings.waitForExistence(timeout: 5), settings.isHittable else { throw UIInteractionError.unavailable("Reader Settings is unavailable.") }
            settings.tap()
        }
        guard app.navigationBars["Reader Settings"].waitForExistence(timeout: 10) else { throw UIInteractionError.unavailable("Reader Settings did not open.") }
        activeSettingsPage = "Reader Settings"
    }

    private func closeNovelPanel(_ title: String) throws {
        if title == "Reader Settings" { try dismissNovelMenuIfNeeded() }
        let done = app.navigationBars[title].buttons["Done"].firstMatch
        guard done.waitForExistence(timeout: 5), done.isHittable else { throw UIInteractionError.unavailable("\(title) has no visible Done control.") }
        done.tap()
        if !waitUntil(timeout: 3, { !self.app.navigationBars[title].exists }), done.exists, done.isHittable { done.tap() }
        guard waitUntil(timeout: 10, { !self.app.navigationBars[title].exists }) else { throw UIInteractionError.timedOut("\(title) did not close.") }
        activeSettingsPage = nil
    }

    private func novelMenuCollections() -> [XCUIElement] {
        let options = ["Scrolling", "Pages", "System", "Georgia", "Times", "Helvetica", "Charter", "New York", "Rounded", "Monospace", "Serif", "Sans Serif", "Light", "Regular", "Medium", "Semibold", "Bold (700)", "Bold", "Left", "Center", "Right", "Justify"]
        return app.collectionViews.allElementsBoundByIndex.filter { collection in
            let frame = collection.frame
            return frame.width > 0 && frame.width < app.frame.width - 4
                && collection.buttons.matching(NSPredicate(format: "label IN %@", options)).firstMatch.exists
        }
    }

    private func dismissNovelMenuIfNeeded() throws {
        guard !novelMenuCollections().isEmpty || app.menus.firstMatch.exists else { return }
        let title = app.navigationBars["Reader Settings"].staticTexts["Reader Settings"].firstMatch
        guard title.exists, app.frame.contains(title.frame), title.frame.height > 0 else {
            throw UIInteractionError.unavailable("The open novel settings menu has no visible outside dismissal target.")
        }
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        guard waitUntil(timeout: 5, { self.novelMenuCollections().isEmpty && !self.app.menus.firstMatch.exists }) else {
            captureNovelNavigationFailure("Novel settings popup did not dismiss")
            throw UIInteractionError.timedOut("The novel settings popup remained open after an outside tap.")
        }
    }

    private func novelMenuButton(_ identifier: String, label: String) -> XCUIElement {
        let identified = app.buttons[identifier].firstMatch
        if identified.exists { return identified }
        return app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")).firstMatch
    }

    private func novelMenuValue(_ identifier: String, label: String, options: [String]) throws -> String {
        let control = novelMenuButton(identifier, label: label)
        try reveal(control)
        guard let value = currentMenuValue(control, options: options) else { throw UIInteractionError.unexpectedValue("Could not read \(label): \(control.debugDescription)") }
        return value
    }

    private func selectNovelMenu(_ identifier: String, label: String, value: String) throws {
        try dismissNovelMenuIfNeeded()
        let control = novelMenuButton(identifier, label: label)
        try reveal(control)
        if currentMenuValue(control, options: [value]) == value { return }
        control.tap()
        func visibleOption() -> (element: XCUIElement, coordinateTap: Bool)? {
            let choices = [app.menus.buttons.matching(identifier: value), app.menus.staticTexts.matching(identifier: value),
                           app.buttons.matching(identifier: value), app.staticTexts.matching(identifier: value)]
            for choice in choices {
                if let option = choice.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return (option, false) }
            }
            for collection in novelMenuCollections() {
                for option in collection.buttons.matching(identifier: value).allElementsBoundByIndex {
                    let frame = option.frame
                    if frame.width > 0, frame.height > 0, app.frame.contains(frame), collection.frame.contains(frame) {
                        return (option, true)
                    }
                }
            }
            return nil
        }
        guard waitUntil(timeout: 5, { visibleOption() != nil }), let option = visibleOption() else {
            captureNovelNavigationFailure("\(label) menu option \(value) is unavailable")
            throw UIInteractionError.unavailable("\(label) option \(value) is not hittable in its menu or picker.")
        }
        if option.coordinateTap { option.element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        else { option.element.tap() }
        if !app.navigationBars["Reader Settings"].exists {
            let back = app.navigationBars.buttons["Reader Settings"].firstMatch
            guard back.waitForExistence(timeout: 5), back.isHittable else { throw UIInteractionError.unavailable("The \(label) picker cannot return to Reader Settings.") }
            back.tap()
        }
        activeSettingsPage = "Reader Settings"
        guard waitUntil(timeout: 5, { self.currentMenuValue(self.novelMenuButton(identifier, label: label), options: [value]) == value }) else {
            throw UIInteractionError.timedOut("\(label) did not select \(value).")
        }
    }

    private func novelFontSize() throws -> Int {
        let slider = app.sliders["novel.fontSize"].firstMatch
        try reveal(slider)
        let label = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Font Size: ")).firstMatch
        guard label.exists, let size = Int(label.label.dropFirst("Font Size: ".count)), (12...32).contains(size) else {
            throw UIInteractionError.unexpectedValue("The reader's current font size is unavailable.")
        }
        return size
    }

    private func setNovelFontSize(_ size: Int) throws {
        guard (12...32).contains(size) else { throw UIInteractionError.unexpectedValue("The captured reader font size is outside its UI range.") }
        var actual = try novelFontSize()
        if actual == size { return }
        let slider = app.sliders["novel.fontSize"].firstMatch
        slider.adjust(toNormalizedSliderPosition: CGFloat(size - 12) / 20)
        if app.staticTexts["Font Size: \(size)"].waitForExistence(timeout: 1) { return }
        actual = try novelFontSize()
        if actual == size { return }
        for attempt in 0..<5 {
            if attempt == 1 {
                let endpoint = size <= 22 ? 12 : 32
                slider.adjust(toNormalizedSliderPosition: endpoint == 12 ? 0 : 1)
                _ = app.staticTexts["Font Size: \(endpoint)"].waitForExistence(timeout: 1)
                actual = try novelFontSize()
                if actual == size { return }
            }
            let frame = slider.frame
            guard slider.isHittable, frame.width > 72, frame.height > 0 else {
                throw UIInteractionError.unavailable("The reader font slider has no visible drag track.")
            }
            let inset = min(CGFloat(18), frame.width / 4)
            let travel = frame.width - inset * 2
            let origin = slider.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: inset + CGFloat(actual - 12) / 20 * travel, dy: frame.height / 2))
            let destination = origin.withOffset(CGVector(dx: inset + CGFloat(size - 12) / 20 * travel, dy: frame.height / 2))
            XCTContext.runActivity(named: "Drag Font Size thumb from \(actual) to \(size), attempt \(attempt + 1)") { _ in
                start.press(forDuration: 0.15, thenDragTo: destination)
            }
            if app.staticTexts["Font Size: \(size)"].waitForExistence(timeout: 1) { return }
            actual = try novelFontSize()
            if actual == size { return }
        }
        captureNovelNavigationFailure("Font Size slider did not reach its requested value")
        throw UIInteractionError.timedOut("The reader font size remained \(actual) after bounded UI thumb drags toward \(size).")
    }

    private func novelPageIndicator() throws -> String {
        let indicator = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[1-9][0-9]* / [1-9][0-9]*")).firstMatch
        guard indicator.waitForExistence(timeout: 2) else { throw UIInteractionError.unavailable("The paged reader's actual page indicator is unavailable.") }
        return indicator.label
    }

    private func showNovelBookmarks() throws {
        if app.navigationBars["Bookmarks"].exists { activeSettingsPage = "Bookmarks"; return }
        try ensureNovelControls()
        app.buttons["novel.bookmarks"].tap()
        let show = app.buttons["Show Bookmarks"].firstMatch
        guard show.waitForExistence(timeout: 5) else { throw UIInteractionError.unavailable("Show Bookmarks is unavailable.") }
        show.tap()
        guard app.navigationBars["Bookmarks"].waitForExistence(timeout: 10) else { throw UIInteractionError.unavailable("The Bookmarks sheet did not open.") }
        activeSettingsPage = "Bookmarks"
    }

    private func novelBookmarkLabels() -> [String] {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "CHAPTER ")).allElementsBoundByIndex.map(\.label)
    }

    private func removeNovelBookmark(label: String, index: Int) throws {
        for title in ["Reader Settings", "Chapters", "Find in Chapter"] where app.navigationBars[title].exists { try closeNovelPanel(title) }
        try showNovelBookmarks()
        let matching = app.buttons.matching(NSPredicate(format: "label == %@", label))
        let count = matching.count
        guard index >= 0, index < count else { throw UIInteractionError.unavailable("The test-created bookmark is unavailable for cleanup.") }
        let bookmark = matching.element(boundBy: index)
        try reveal(bookmark)
        bookmark.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        guard delete.waitForExistence(timeout: 5), delete.isHittable else { throw UIInteractionError.unavailable("The test-created bookmark has no Delete action.") }
        delete.tap()
        guard waitUntil(timeout: 5, { matching.count == count - 1 }) else { throw UIInteractionError.timedOut("The test-created bookmark was not removed.") }
        try closeNovelPanel("Bookmarks")
    }

    private func verifyToggleRoundTrip(label: String, search: String, checkPersistence: Bool = false) throws {
        let original = try switchValue(label)
        restorations.append { [self] in
            try openSettingFromLaunch(search)
            try setSwitch(label, to: original)
        }
        try setSwitch(label, to: !original)
        capture("\(label) changed")
        if checkPersistence {
            try openSettingFromLaunch(search)
            XCTAssertEqual(try switchValue(label), !original)
        }
        try setSwitch(label, to: original)
        restorations.removeLast()
    }

    private func switchValue(_ label: String) throws -> Bool {
        let control = app.switches[label].firstMatch
        try reveal(control)
        guard let value = control.value as? String, ["0", "1"].contains(value) else {
            throw UIInteractionError.unexpectedValue("Could not read the \(label) toggle.")
        }
        return value == "1"
    }

    private func setSwitch(_ label: String, to enabled: Bool) throws {
        let control = app.switches[label].firstMatch
        try reveal(control)
        if try switchValue(label) != enabled {
            let target = try switchTapTarget(control)
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let expected = enabled ? "1" : "0"
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: control)
        guard XCTWaiter.wait(for: [changed], timeout: 5) == .completed else {
            throw UIInteractionError.timedOut("The control did not reach its requested value.")
        }
    }

    private func switchTapTarget(_ control: XCUIElement) throws -> XCUIElement {
        let rowFrame = control.frame
        guard rowFrame.width > 100 else { return control }
        let nativeSwitches = app.switches.allElementsBoundByIndex.filter { candidate in
            let frame = candidate.frame
            return frame.width > 0 && frame.width <= 100 && frame.height > 0
                && rowFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        guard nativeSwitches.count == 1, let target = nativeSwitches.first else {
            throw UIInteractionError.unavailable("Could not identify the native switch inside \(control.label).")
        }
        return target
    }

    private func menuValue(_ identifier: String, options: [String]) throws -> String {
        let control = app.buttons[identifier].firstMatch
        try reveal(control)
        guard let value = currentMenuValue(control, options: options) else {
            throw UIInteractionError.unexpectedValue("Could not read menu \(identifier): \(control.debugDescription)")
        }
        return value
    }

    private func currentMenuValue(_ control: XCUIElement, options: [String]) -> String? {
        if let value = control.value as? String, options.contains(value) { return value }
        if let label = options.first(where: { control.label == $0 || control.label.hasSuffix(", \($0)") }) { return label }
        let texts = control.staticTexts.allElementsBoundByIndex.map(\.label)
        return options.first(where: texts.contains)
    }

    private func selectMenu(_ identifier: String, value: String) throws {
        let control = app.buttons[identifier].firstMatch
        try reveal(control)
        control.tap()
        let option = app.buttons[value].firstMatch
        guard option.waitForExistence(timeout: 5) else {
            throw UIInteractionError.unavailable("Menu option \(value) is unavailable.")
        }
        option.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            currentMenuValue(app.buttons[identifier].firstMatch, options: [value]) == value
        }, object: nil)
        guard XCTWaiter.wait(for: [changed], timeout: 5) == .completed else {
            throw UIInteractionError.timedOut("The control did not reach its requested value.")
        }
    }

    private func openSettingFromLaunch(_ title: String) throws {
        restartApp()
        try openSettings()
        let searchTitle = title == "Assume Original Language for Untagged Streams" ? "Assume Original Language" : title
        try searchSettings(searchTitle)
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", searchTitle)).firstMatch
        guard result.waitForExistence(timeout: 10) else {
            throw UIInteractionError.unavailable("Settings search did not find \(title).")
        }
        result.tap()
        switch title {
        case "Animation Frame Rate":
            try waitForSettingsPage(["Appearance"])
            try openSettingsCategory("Motion & Startup")
        case "Image Data Saver":
            try waitForSettingsPage(["Appearance"])
            try openSettingsCategory("Detail Pages")
        case "Remember Last Choice per Show":
            try waitForSettingsPage(["Auto Mode"])
        case "Languages to Include", "Languages to Exclude", "Hide Streams Without Language Data",
             "Assume Original Language for Untagged Streams", "Treat Dubbed Anime Streams as English",
             "Hide Streams Without Detected Quality":
            try waitForSettingsPage(["Extra Source Settings"])
        case "Autoplay Next Episode", "Auto Audio Language":
            try waitForSettingsPage(["MPV Player", "Media Player"])
        case "Deep Library Integration":
            try waitForSettingsPage(["Trackers"])
        case "Concurrent Downloads":
            try waitForSettingsPage(["Storage"])
        default:
            throw UIInteractionError.unavailable("No test navigation route exists for \(title).")
        }
    }

    private func waitForSettingsPage(_ titles: [String]) throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            titles.contains { app.navigationBars[$0].exists }
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed,
              let title = titles.first(where: { app.navigationBars[$0].exists }) else {
            throw UIInteractionError.unavailable("Settings did not open \(titles.joined(separator: " or ")).")
        }
        activeSettingsPage = title
    }

    private func openSettingsCategory(_ title: String) throws {
        let category = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
        try reveal(category)
        category.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try waitForSettingsPage([title])
    }

    private func openLibraryTab() throws {
        let standardTab = app.tabBars.buttons["Library"].firstMatch
        let modernTab = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "Library", "books.vertical.fill")).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            standardTab.exists || modernTab.exists
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 30) == .completed else {
            throw UIInteractionError.unavailable("The Library tab is unavailable.")
        }
        let tab = standardTab.exists ? standardTab : modernTab
        guard tab.frame.width > 0, tab.frame.height > 0 else {
            throw UIInteractionError.unavailable("The Library tab has no visible frame.")
        }
        tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func restartApp() {
        activeSettingsPage = nil
        if app.state != .notRunning { app.terminate() }
        app.launch()
    }

    private func openSettings() throws {
        let mediaMode = app.buttons["Switch to Media Mode"]
        if mediaMode.waitForExistence(timeout: 2) { mediaMode.tap() }
        let quickActions = app.buttons["Quick Actions"]
        guard quickActions.waitForExistence(timeout: 30) else {
            throw UIInteractionError.unavailable("Quick Actions is unavailable.")
        }
        let settings = app.buttons["Settings"].firstMatch
        for _ in 0..<2 {
            if !settings.exists || !settings.isHittable || settings.frame.width < 44 {
                quickActions.tap()
            }
            var previousFrame = CGRect.zero
            let settingsActionReady = waitUntil(timeout: 5, {
                guard settings.exists, settings.isHittable else { return false }
                let frame = settings.frame
                let ready = frame.width >= 44 && frame.height >= 44 && frame == previousFrame
                previousFrame = frame
                return ready
            })
            if !settingsActionReady { continue }
            settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if app.navigationBars["Settings"].waitForExistence(timeout: 5) {
                activeSettingsPage = "Settings"
                return
            }
        }
        throw UIInteractionError.unavailable("Quick Actions did not open Settings.")
    }

    private func searchSettings(_ text: String) throws {
        let field = app.searchFields.firstMatch
        guard field.waitForExistence(timeout: 10) else {
            throw UIInteractionError.unavailable("Settings search is unavailable.")
        }
        field.tap()
        if let value = field.value as? String, value != field.placeholderValue, !value.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(text)
    }

    private func reveal(_ element: XCUIElement) throws {
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            hasVisibleFrame(element)
        }, object: nil)
        if XCTWaiter.wait(for: [settled], timeout: 2) == .completed { return }
        for _ in 0..<8 {
            let viewport = visibleViewport()
            guard !viewport.isEmpty, !viewport.isNull else {
                throw UIInteractionError.unavailable("The current Settings page has no visible viewport.")
            }
            let frame = element.exists ? element.frame : .zero
            let needsEarlierContent = frame.height > 0 && frame.midY < viewport.minY
            let upper = CGPoint(x: viewport.midX, y: viewport.minY + viewport.height * 0.25)
            let lower = CGPoint(x: viewport.midX, y: viewport.minY + viewport.height * 0.75)
            let from = needsEarlierContent ? upper : lower
            let to = needsEarlierContent ? lower : upper
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: from.x, dy: from.y))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: to.x, dy: to.y)))
            if hasVisibleFrame(element) { return }
        }
        guard hasVisibleFrame(element) else {
            throw UIInteractionError.unavailable("The requested control is not visible: \(element.debugDescription)")
        }
    }

    private func visibleViewport() -> CGRect {
        var viewport = app.windows.firstMatch.frame
        if let activeSettingsPage {
            let bar = app.navigationBars[activeSettingsPage]
            guard bar.exists else { return .zero }
            let frame = bar.frame
            guard frame.width > 0, frame.height > 0 else { return .zero }
            let top = max(viewport.minY, frame.maxY)
            viewport = CGRect(x: max(viewport.minX, frame.minX), y: top,
                              width: min(viewport.width, frame.width), height: max(0, viewport.maxY - top))
        } else if !app.searchFields["Search languages or codes"].firstMatch.exists {
            let tabBars = app.tabBars.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.minY > viewport.midY }
            if let top = tabBars.map({ $0.frame.minY }).min() {
                viewport.size.height = max(0, top - viewport.minY)
            } else {
                let tabs = app.buttons.matching(NSPredicate(format: "label IN %@ AND identifier IN %@",
                    ["Home", "Library", "Search", "History", "Settings", "Schedule", "Downloads"],
                    ["house", "house.fill", "books.vertical", "books.vertical.fill", "magnifyingglass", "clock", "gear", "calendar", "arrow.down.circle.fill"]))
                    .allElementsBoundByIndex.filter {
                        $0.isHittable && $0.frame.minY > viewport.maxY - 150 && $0.frame.height <= 80
                    }
                if tabs.count >= 3, let top = tabs.map({ $0.frame.minY }).min(),
                   tabs.allSatisfy({ abs($0.frame.minY - top) <= 4 }) {
                    viewport.size.height = max(0, top - viewport.minY)
                }
            }
        }
        if app.keyboards.firstMatch.exists {
            let keyboard = app.keyboards.firstMatch.frame
            if keyboard.intersects(viewport) {
                viewport.size.height = max(0, keyboard.minY - viewport.minY)
            }
        }
        return viewport.insetBy(dx: 4, dy: 8)
    }

    private func hasVisibleFrame(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return false }
        let viewport = visibleViewport()
        guard !viewport.isNull, !viewport.isEmpty else { return false }
        return viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
            && viewport.intersection(frame).height >= min(frame.height, 24)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            condition()
        }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func capture(_ title: String) {
        guard !suppressScreenshots else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
