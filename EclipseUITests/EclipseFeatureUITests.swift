import XCTest

final class EclipseFeatureUITests: XCTestCase {
    private let app = XCUIApplication()
    private var restorations: [() throws -> Void] = []
    private var activeSettingsPage: String?

    private enum UIInteractionError: Error {
        case unavailable(String)
        case unexpectedValue(String)
        case timedOut(String)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
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

    func testImageDataSaverChangesAndPersists() throws {
        try openSettingFromLaunch("Image Data Saver")
        try verifyToggleRoundTrip(label: "Image Data Saver", search: "Image Data Saver", checkPersistence: true)
    }

    func testRememberedPlaybackChoiceChangesAndPersists() throws {
        try openSettingFromLaunch("Remember Last Choice per Show")
        try verifyToggleRoundTrip(label: "Remember Last Choice per Show", search: "Remember Last Choice per Show", checkPersistence: true)
        XCTAssertTrue(app.buttons["Clear Remembered Choices"].exists)
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
            for kind in ["Anime", "Manga"] {
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
        let detailAction = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "(Play.*|Resume.*|Continue.*|No Sources|Choose Episode)")).firstMatch
        XCTAssertTrue(detailAction.waitForExistence(timeout: 60), "A tracker card must open normal media details with the playback action: \(app.debugDescription)")
        if detailAction.label == "Choose Episode" {
            XCTAssertTrue(app.staticTexts["trackerLibrary.playbackNotice"].exists, "An unresolved next episode needs an explanation.")
        } else if source != "Trakt", let progressLabel, let raw = progressLabel.split(separator: " ").first, let watched = Int(raw), detailAction.label.hasPrefix("Play E") {
            XCTAssertEqual(detailAction.label, "Play E\(watched + 1)", "Play from a tracker library must follow its last watched episode.")
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
        try reveal(card)
        card.tap()
        let expected = app.buttons["Play E\(watched + 1)"]
        XCTAssertTrue(expected.waitForExistence(timeout: 60), "Expected tracker continuation after \(watched) watched episodes: \(app.debugDescription)")
        let receipt = XCTAttachment(string: "\(source) / \(title): \(watched) watched -> \(expected.label). No playback or tracker write was performed.")
        receipt.name = "Aired tracker episode selection"
        receipt.lifetime = .keepAlways
        add(receipt)
        capture("Tracker progress selects aired next episode")
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
        restartApp()
        try openLibraryTab()
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

    private func verifyAvailableEditorCanCancel(source: String, kind: String) throws {
        let summary = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
        guard summary.exists,
              let countText = summary.label.split(separator: " ").first,
              let count = Int(countText), count > 0 else { return }
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
        XCTAssertTrue(app.staticTexts[originalSummary].exists, "Cancelling the editor must preserve the loaded tracker list.")
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
        try searchSettings(title)
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
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
        case "Autoplay Next Episode":
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
        quickActions.tap()
        let settings = app.buttons["Settings"].firstMatch
        guard settings.waitForExistence(timeout: 5) else {
            throw UIInteractionError.unavailable("Settings is unavailable in Quick Actions.")
        }
        settings.tap()
        guard app.searchFields.firstMatch.waitForExistence(timeout: 10) else {
            throw UIInteractionError.unavailable("Settings search is unavailable.")
        }
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

    private func capture(_ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
