import XCTest
@testable import EclipseMac

final class MacReaderPortTests: XCTestCase {
    func testIntelReaderUpscalingAdmissionPreservesImportedPreferences() throws {
        let suite = "EclipseMac.IntelReaderSettings." + UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let preferences: [String: Any] = [
            "Reader.downsampleImages": false,
            "Reader.upscaleImages": true,
            "Reader.upscaleMaxHeight": 6000,
            "Reader.upscaleModelName": "Saved Model",
            "Reader.cropBorders": true,
            "Reader.liveText": true
        ]
        store.setPersistentDomain(preferences, forName: suite)
        let intel = IntelMacCompatibilityPolicy(platform: .macOS, isX86_64: true)
        let appleSilicon = IntelMacCompatibilityPolicy(platform: .macOS, isX86_64: false)
        XCTAssertFalse(MacReaderSettingsSnapshot.imageUpscalingEnabled(store: store, compatibility: intel))
        XCTAssertTrue(MacReaderSettingsSnapshot.imageUpscalingEnabled(store: store, compatibility: appleSilicon))
        XCTAssertTrue(NSDictionary(dictionary: preferences).isEqual(to: try XCTUnwrap(store.persistentDomain(forName: suite))))
        store.set(true, forKey: "Reader.downsampleImages")
        XCTAssertFalse(MacReaderSettingsSnapshot.imageUpscalingEnabled(store: store, compatibility: intel))
        XCTAssertFalse(MacReaderSettingsSnapshot.imageUpscalingEnabled(store: store, compatibility: appleSilicon))
        XCTAssertTrue(store.bool(forKey: "Reader.upscaleImages"))
        XCTAssertEqual(store.string(forKey: "Reader.upscaleModelName"), "Saved Model")
    }

    func testIntelReaderUpscalingRejectsMalformedAndRestoredValuesWithoutRewritingThem() throws {
        let suite = "EclipseMac.IntelReaderSettings." + UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let intel = IntelMacCompatibilityPolicy(platform: .macOS, isX86_64: true)
        for value: Any in [true, 1, "YES", "invalid"] {
            let preferences: [String: Any] = ["Reader.downsampleImages": false, "Reader.upscaleImages": value]
            store.setPersistentDomain(preferences, forName: suite)
            XCTAssertFalse(MacReaderSettingsSnapshot.imageUpscalingEnabled(store: store, compatibility: intel))
            XCTAssertTrue(NSDictionary(dictionary: preferences).isEqual(to: try XCTUnwrap(store.persistentDomain(forName: suite))))
        }
    }

    func testReaderProgressRetainsFailedSynchronizationAndRetries() throws {
        let suite = "EclipseMac.ReaderProgressTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = MangaReadingProgressManager(profileID: UUID(), defaults: defaults)
        manager.savePagePosition(mangaId: 41, chapterNumber: "Chapter 2", page: 4, pageCount: 20)
        XCTAssertFalse(manager.flushForMacTermination(synchronize: { false }))
        XCTAssertTrue(manager.macHasPendingProgress)
        XCTAssertTrue(manager.flushForMacTermination(synchronize: { true }))
        XCTAssertFalse(manager.macHasPendingProgress)
        XCTAssertEqual(manager.progress(for: 41)?.pagePositions[ChapterIdentityNormalizer.key(for: "Chapter 2")], 4)
    }

    func testReaderProgressDoesNotRestoreExternallyClearedProfileOnRetry() throws {
        let suite = "EclipseMac.ReaderProgressTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = MangaReadingProgressManager(profileID: UUID(), defaults: defaults)
        manager.savePagePosition(mangaId: 42, chapterNumber: "Chapter 2", page: 1, pageCount: 20)
        XCTAssertFalse(manager.flushForMacTermination(synchronize: { false }))
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.contains("mangaReadingProgress") }
        XCTAssertFalse(keys.isEmpty)
        keys.forEach { defaults.removeObject(forKey: $0) }
        XCTAssertTrue(manager.flushForMacTermination(synchronize: { true }))
        XCTAssertFalse(manager.macHasPendingProgress)
        XCTAssertTrue(keys.allSatisfy { defaults.data(forKey: $0) == nil })
    }

    func testReaderStorageAcceptsMovedChaptersAndRejectsForeignOrEscapingPaths() {
        let root = UUID()
        XCTAssertTrue(ReaderDownloadManager.validMacStorageLocation(DownloadStorageLocation(rootID: root, relativePath: "Reader/Moved/operation/chapter")))
        XCTAssertTrue(ReaderDownloadManager.validMacStorageLocation(DownloadStorageLocation(rootID: root, relativePath: "Reader/title/chapter")))
        for path in ["Video/title/chapter", "Reader/../Video/chapter", "Reader//chapter", "Reader", "/Reader/chapter", "Reader/chapter/."] {
            XCTAssertFalse(ReaderDownloadManager.validMacStorageLocation(DownloadStorageLocation(rootID: root, relativePath: path)))
        }
    }

    func testOffsetCoverIsNotRepeatedInFacingPageNavigation() {
        XCTAssertEqual(MacReaderLayoutPolicy.group(containing: 0, count: 6, columns: 2, offsetFirstPage: true), 0..<1)
        XCTAssertEqual(MacReaderLayoutPolicy.adjacentIndex(from: 0, direction: 1, count: 6, columns: 2, offsetFirstPage: true), 1)
        XCTAssertEqual(MacReaderLayoutPolicy.group(containing: 1, count: 6, columns: 2, offsetFirstPage: true), 1..<3)
        XCTAssertEqual(MacReaderLayoutPolicy.adjacentIndex(from: 1, direction: 1, count: 6, columns: 2, offsetFirstPage: true), 3)
        XCTAssertEqual(MacReaderLayoutPolicy.adjacentIndex(from: 3, direction: -1, count: 6, columns: 2, offsetFirstPage: true), 1)
        XCTAssertEqual(MacReaderLayoutPolicy.adjacentIndex(from: 1, direction: -1, count: 6, columns: 2, offsetFirstPage: true), 0)
        XCTAssertNil(MacReaderLayoutPolicy.adjacentIndex(from: 5, direction: 1, count: 6, columns: 2, offsetFirstPage: true))
    }

    func testFacingPagesCoverEveryPageExactlyOnce() {
        for count in 0...31 {
            for offset in [false, true] {
                var seen: [Int] = []
                var current: Int? = count > 0 ? 0 : nil
                while let index = current {
                    seen.append(contentsOf: MacReaderLayoutPolicy.group(containing: index, count: count, columns: 2, offsetFirstPage: offset))
                    current = MacReaderLayoutPolicy.adjacentIndex(from: index, direction: 1, count: count, columns: 2, offsetFirstPage: offset)
                }
                XCTAssertEqual(seen, Array(0..<count))
            }
        }
    }

    func testNovelPositionUsesExistingIOSChapterIdentityAndWireKey() {
        let source = ReaderExtensionSourceID(rawValue: String(repeating: "a", count: 64))
        let item = ReaderExtensionItem(key: "book", title: "Book")
        let chapter = ReaderExtensionChapter(key: "chapter-identity", title: "Volume One", url: nil, uploadedAt: nil, scanlator: nil, isFiller: false, thumbnailURL: nil, summary: nil)
        let bridge = chapter.kanzenChapter(sourceID: source, mediaType: .novel, item: item, index: 0)
        let route = MangaContentRoute.readerExtension(source: source, itemKey: item.key, legacyStableKey: nil)
        XCTAssertEqual(MacReaderNovelPosition.storageKey(route: route, mangaID: -1, chapter: bridge), "novelScrollPos_" + NovelReaderPositionKey.make(titleIdentity: route.stableKey, chapterIdentity: chapter.key))
        XCTAssertEqual(MacReaderNovelPosition.finiteFraction(.nan), 0)
        XCTAssertEqual(MacReaderNovelPosition.finiteFraction(.infinity), 0)
        XCTAssertEqual(MacReaderNovelPosition.finiteFraction(-1), 0)
        XCTAssertEqual(MacReaderNovelPosition.finiteFraction(2), 1)
    }

    func testProviderDescendingChaptersReadChronologically() {
        let source = ReaderExtensionSourceID(rawValue: String(repeating: "b", count: 64))
        let chapters = ["Chapter 10", "Chapter 2", "Chapter 1"].map { ReaderExtensionChapter(key: $0, title: $0, url: nil, uploadedAt: nil, scanlator: nil, isFiller: false, thumbnailURL: nil, summary: nil) }
        let cache = ReaderExtensionDetailChapterCache.make(sourceID: source, mediaType: .manga, item: ReaderExtensionItem(key: "book", title: "Book"), chapters: chapters)
        XCTAssertEqual(cache.displayChapters.map(\.chapterNumber), ["Chapter 10", "Chapter 2", "Chapter 1"])
        XCTAssertEqual(cache.readerChapters.map(\.chapterNumber), ["Chapter 1", "Chapter 2", "Chapter 10"])
        XCTAssertEqual(cache.readerChapters.map(\.idx), [0, 1, 2])
    }

    @MainActor
    func testQuitRefusesToProceedWhenQueueCheckpointFails() async {
        let row = download(status: .downloading)
        let manager = ReaderDownloadManager(downloadsRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), initialDownloads: [row], write: { _, _ in .writeFailed(storedStateChanged: false) })
        let result = await manager.prepareForMacTermination()
        XCTAssertFalse(result)
        XCTAssertEqual(manager.downloads.first?.status, .downloading)
        XCTAssertEqual(manager.downloads.first?.provider.authenticationProfileID, row.provider.authenticationProfileID)
    }

    @MainActor
    func testQuitPreservesItemLocationAndAuthenticationOwnerInDurableQueue() async {
        let row = download(status: .downloading)
        var writes: [[ReaderDownloadItem]] = []
        let manager = ReaderDownloadManager(downloadsRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), initialDownloads: [row], write: { items, _ in writes.append(items); return .success })
        let result = await manager.prepareForMacTermination()
        XCTAssertTrue(result)
        XCTAssertEqual(manager.downloads.first?.status, .queued)
        XCTAssertEqual(writes.last?.first?.storageLocation, row.storageLocation)
        XCTAssertEqual(writes.last?.first?.provider.authenticationProfileID, row.provider.authenticationProfileID)
        XCTAssertEqual(writes.last?.first?.id, row.id)
    }

    func testRangeMarkingIncludesClickedRowInDisplayedOrder() {
        let chapters = ["Prologue", "1", "1.5", "2", "Extra"].enumerated().map { Chapter(chapterNumber: $0.element, idx: $0.offset, chapterData: nil) }
        let reversed = Array(chapters.reversed())
        XCTAssertEqual(MacReaderChapterRangePolicy.chapters(in: reversed, including: chapters[2], direction: .above).map(\.id), [chapters[4], chapters[3], chapters[2]].map(\.id))
        XCTAssertEqual(MacReaderChapterRangePolicy.chapters(in: reversed, including: chapters[2], direction: .below).map(\.id), [chapters[2], chapters[1], chapters[0]].map(\.id))
        let unread = [chapters[4], chapters[2], chapters[0]]
        XCTAssertEqual(MacReaderChapterRangePolicy.chapters(in: unread, including: chapters[2], direction: .above).map(\.id), [chapters[4], chapters[2]].map(\.id))
        XCTAssertEqual(MacReaderChapterRangePolicy.chapters(in: unread, including: chapters[2], direction: .below).map(\.id), [chapters[2], chapters[0]].map(\.id))
        XCTAssertEqual(MacReaderChapterRangePolicy.chapters(in: unread, including: chapters[4], direction: .above).map(\.id), [chapters[4].id])
        XCTAssertEqual(MacReaderChapterRangePolicy.chapters(in: unread, including: chapters[0], direction: .below).map(\.id), [chapters[0].id])
        XCTAssertTrue(MacReaderChapterRangePolicy.chapters(in: unread, including: chapters[1], direction: .above).isEmpty)
        XCTAssertTrue(MacReaderChapterRangePolicy.chapters(in: unread, including: Chapter(chapterNumber: "1.5", idx: 2, chapterData: nil), direction: .below).isEmpty)
        XCTAssertTrue(MacReaderChapterRangePolicy.chapters(in: [], including: chapters[0], direction: .above).isEmpty)
    }

    func testOfflineChapterListPreservesExactRoutesAndExcludesIncompleteAndForeignRows() throws {
        let routes: [MangaContentRoute] = [
            .readerExtension(source: ReaderExtensionSourceID(rawValue: String(repeating: "e", count: 64)), itemKey: "offline-book", legacyStableKey: "aidoku:retired:book"),
            .aidoku(sourceId: "retired-source", mangaKey: "old-book"),
            .legacyModule(moduleUUID: UUID().uuidString, contentParams: "old-book", isNovel: true)
        ]
        for route in routes {
            let completed = download(status: .completed, route: route)
            let failed = download(status: .failed, route: route)
            let foreign = download(status: .completed)
            let chapters = MacReaderOfflineChapterPolicy.chapters(for: route, downloads: [foreign, completed, failed])
            XCTAssertEqual(chapters.count, 1)
            let chapter = try XCTUnwrap(chapters.first)
            let payload = try XCTUnwrap(chapter.chapterData?.first?.params as? ReaderDownloadedChapterPayload)
            XCTAssertEqual(payload.route, completed.route)
            XCTAssertEqual(payload.chapterNumber, completed.chapterNumber)
            XCTAssertEqual(chapter.chapterNumber, completed.chapterNumber)
            XCTAssertEqual(chapter.idx, 0)
            XCTAssertEqual(chapter.chapterData?.first?.scanlationGroup, completed.sourceName)
        }
    }

    @MainActor
    func testMissingOfflineChapterWithNilLegacyRouteCannotFallThroughToProvider() async throws {
        let route = MangaContentRoute.legacyModule(moduleUUID: UUID().uuidString, contentParams: "missing-local-fixture", isNovel: true)
        let chapters = MacReaderOfflineChapterPolicy.chapters(for: route, downloads: [download(status: .completed, route: route)])
        let chapter = try XCTUnwrap(chapters.first)
        let loader = KanzenReaderPageLoader(kanzen: KanzenEngine(), route: nil)
        do {
            _ = try await loader.loadPages(for: chapter, mode: .webtoon)
            XCTFail("A missing downloaded chapter must report its local failure.")
        } catch {
            XCTAssertEqual((error as NSError).domain, "ReaderDownload")
            XCTAssertEqual((error as NSError).code, 404)
        }
    }

    @MainActor
    func testTitleSettingsResolveInheritedModeAndKeepPageOffsetScoped() async throws {
        if MacLaunchProfileAccess.requiresUnlock || MacLaunchProfileAccess.isTerminating || !ProfileManager.shared.rosterStoreIsReadable { throw XCTSkip("The current profile is unavailable; scoped settings tests preserve it.") }
        let suite = "EclipseMac.ReaderSettingsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let session = MacReaderSession(settingsStore: defaults)
        defer { session.close(); defaults.removePersistentDomain(forName: suite) }
        defaults.set("rtl", forKey: "kanzenReaderMode")
        defaults.set(true, forKey: "Reader.pagedPageOffset")
        let route = MangaContentRoute.legacyModule(moduleUUID: UUID().uuidString, contentParams: "settings-fixture", isNovel: false)
        let chapter = Chapter(chapterNumber: "1", idx: 0, chapterData: nil)
        session.open(item: MangaLibraryItem(aniListId: 0, title: "Settings Fixture", coverURL: nil, format: "MANGA", totalChapters: nil, route: route, contentRating: ReaderContentRating.safe.rawValue), chapters: [chapter], selected: chapter, engine: KanzenEngine()) { _, _ in [PageData(content: .text("Fixture"))] }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while session.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.isLoading)
        let scope = try XCTUnwrap(session.reader?.readerSettingsScopeKey)
        XCTAssertEqual(scope, route.stableKey)
        session.applySettings()
        XCTAssertEqual(session.effectiveReadingMode, .rtl)
        XCTAssertEqual(MacReaderSettingsSnapshot(session: session).mode, .rtl)
        XCTAssertNil(defaults.object(forKey: KanzenReaderMode.storageKey(scopeKey: scope)))
        XCTAssertFalse(MacReaderSettingsSnapshot(session: session).offset)
        XCTAssertTrue(MacReaderSettingsPolicy.pageOffset(store: defaults, scopeKey: nil))
        defaults.set("vertical", forKey: KanzenReaderMode.storageKey(scopeKey: scope))
        defaults.set(true, forKey: MacReaderSettingsPolicy.pageOffsetStorageKey(scopeKey: scope))
        session.applySettings()
        XCTAssertEqual(session.effectiveReadingMode, .vertical)
        XCTAssertEqual(MacReaderSettingsSnapshot(session: session).mode, .vertical)
        XCTAssertTrue(MacReaderSettingsSnapshot(session: session).offset)
        defaults.removeObject(forKey: KanzenReaderMode.storageKey(scopeKey: scope))
        defaults.set(false, forKey: MacReaderSettingsPolicy.pageOffsetStorageKey(scopeKey: scope))
        session.applySettings()
        XCTAssertEqual(session.effectiveReadingMode, .rtl)
        XCTAssertFalse(MacReaderSettingsSnapshot(session: session).offset)
        XCTAssertEqual(defaults.string(forKey: "kanzenReaderMode"), "rtl")
        XCTAssertTrue(defaults.bool(forKey: "Reader.pagedPageOffset"))
    }

    func testLegacyReaderAdoptionRejectsSameSizeConflictingPageAndChangedManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EclipseMac.ReaderMigration." + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
        var item = download(status: .completed, isNovel: true)
        item.storageLocation = nil
        item.progress = 1
        item.completedPages = 1
        item.totalPages = 1
        item.dateCompleted = Date(timeIntervalSince1970: 1000)
        let relative = ReaderDownloadManager.stableHash(item.routeKey) + "/" + ReaderDownloadManager.stableHash(item.chapterKey)
        let source = sourceRoot.appendingPathComponent(relative, isDirectory: true)
        let destination = destinationRoot.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let route = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item.route))
        var manifest: [String: Any] = ["version": 1, "itemId": item.id, "route": route, "mangaTitle": item.mangaTitle, "chapterNumber": item.chapterNumber, "pages": [["index": 0, "kind": "text", "fileName": "0001.txt"]], "dateCompleted": "1970-01-01T00:16:40Z"]
        let original = Data("First fixture text.".utf8)
        let conflict = Data("Other fixture text.".utf8)
        XCTAssertEqual(original.count, conflict.count)
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys)
        for directory in [source, destination] {
            try manifestData.write(to: directory.appendingPathComponent("chapter.json"))
            try original.write(to: directory.appendingPathComponent("0001.txt"))
        }
        XCTAssertNotNil(ReaderDownloadManager.recoverableCompletedCopy(item, downloadsRoot: sourceRoot, fileManager: .default))
        XCTAssertTrue(ReaderDownloadManager.macLegacyChapterCopiesMatch(item, sourceRoot: sourceRoot, destinationRoot: destinationRoot))
        try conflict.write(to: destination.appendingPathComponent("0001.txt"))
        XCTAssertNotNil(ReaderDownloadManager.recoverableCompletedCopy(item, downloadsRoot: destinationRoot, fileManager: .default))
        XCTAssertFalse(ReaderDownloadManager.macLegacyChapterCopiesMatch(item, sourceRoot: sourceRoot, destinationRoot: destinationRoot))
        try original.write(to: destination.appendingPathComponent("0001.txt"))
        manifest["dateCompleted"] = "1970-01-01T00:16:41Z"
        try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys).write(to: destination.appendingPathComponent("chapter.json"))
        XCTAssertFalse(ReaderDownloadManager.macLegacyChapterCopiesMatch(item, sourceRoot: sourceRoot, destinationRoot: destinationRoot))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("0001.txt")), original)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("chapter.json")), manifestData)
    }

    func testWheelContinuationRequiresDirectEndIntentAndConsumesOneGesture() {
        var policy = MacReaderWheelNavigationPolicy()
        func event(_ delta: Double, time: Double, atEnd: Bool, began: Bool = false, momentum: Bool = false, enabled: Bool = true) -> Int? {
            policy.consume(deltaX: 0, deltaY: delta, precise: true, began: began, momentum: momentum, timestamp: time, paged: false, rightToLeft: false, atEnd: atEnd, continuationEnabled: enabled, magnified: false, modified: false)
        }
        XCTAssertNil(event(-600, time: 1, atEnd: false, began: true))
        XCTAssertNil(event(-50, time: 1.1, atEnd: true))
        XCTAssertEqual(event(-80, time: 1.2, atEnd: true), 1)
        XCTAssertNil(event(-500, time: 1.3, atEnd: true))
        XCTAssertNil(event(-500, time: 1.4, atEnd: true, momentum: true))
        XCTAssertNil(event(-500, time: 2, atEnd: true, began: true, enabled: false))
        XCTAssertNil(event(500, time: 3, atEnd: true, began: true))
        XCTAssertEqual(event(-150, time: 4, atEnd: true, began: true), 1)
    }

    @MainActor
    func testRemovalAdmissionRejectsOwnerAndWindowABAAndCannotBeReused() throws {
        var owner = "A"
        var ownerGeneration = 0
        var windowGeneration = 0
        var removed = 0
        let ownerAtProposal = owner
        let generationAtProposal = ownerGeneration
        let windowAtProposal = windowGeneration
        let ownerProposal = MacReaderRemovalAdmission { owner == ownerAtProposal && ownerGeneration == generationAtProposal && windowGeneration == windowAtProposal }
        owner = "B"
        ownerGeneration += 1
        owner = "A"
        ownerGeneration += 1
        XCTAssertFalse(try ownerProposal.perform { removed += 1 })
        XCTAssertEqual(removed, 0)
        let capturedWindow = windowGeneration
        let windowProposal = MacReaderRemovalAdmission { windowGeneration == capturedWindow }
        windowGeneration += 1
        XCTAssertFalse(try windowProposal.perform { removed += 1 })
        let cancelled = MacReaderRemovalAdmission { true }
        cancelled.invalidate()
        XCTAssertFalse(try cancelled.perform { removed += 1 })
        let current = MacReaderRemovalAdmission { true }
        XCTAssertTrue(try current.perform { removed += 1 })
        XCTAssertFalse(try current.perform { removed += 1 })
        XCTAssertEqual(removed, 1)
    }

    func testPagedWheelHonorsRTLAndLeavesMagnifiedModifiedAndMomentumInputAlone() {
        var policy = MacReaderWheelNavigationPolicy()
        func event(x: Double = 0, y: Double = 0, time: Double, began: Bool = true, magnified: Bool = false, modified: Bool = false, momentum: Bool = false) -> Int? {
            policy.consume(deltaX: x, deltaY: y, precise: true, began: began, momentum: momentum, timestamp: time, paged: true, rightToLeft: true, atEnd: false, continuationEnabled: true, magnified: magnified, modified: modified)
        }
        XCTAssertNil(event(y: -300, time: 1, magnified: true))
        XCTAssertNil(event(x: -300, time: 2, modified: true))
        XCTAssertNil(event(y: -300, time: 3, momentum: true))
        XCTAssertNil(event(x: -40, time: 4))
        XCTAssertEqual(event(x: -40, time: 4.1, began: false), -1)
        XCTAssertNil(event(x: -300, time: 4.2, began: false))
        XCTAssertEqual(event(x: 80, time: 5), 1)
        XCTAssertEqual(event(y: -80, time: 6), 1)
    }

    private func download(status: ReaderDownloadStatus, route suppliedRoute: MangaContentRoute? = nil, isNovel: Bool = false) -> ReaderDownloadItem {
        let source = ReaderExtensionSourceID(rawValue: String(repeating: "c", count: 64))
        let route = suppliedRoute ?? MangaContentRoute.readerExtension(source: source, itemKey: "book", legacyStableKey: nil)
        let chapter = "Chapter 1"
        let key = ChapterIdentityNormalizer.key(for: chapter)
        var row = ReaderDownloadItem(id: ReaderDownloadManager.downloadId(route: route, chapterNumber: chapter), route: route, routeKey: route.stableKey, mangaId: route.stableNegativeId, mangaTitle: "Book", coverURL: nil, sourceName: "Source", format: isNovel ? "NOVEL" : "MANGA", chapterNumber: chapter, chapterTitle: nil, chapterKey: key, contentRating: ReaderContentRating.safe.rawValue, provider: ReaderDownloadProvider(kind: .readerExtension, sourceId: source.rawValue, mangaKey: "book", moduleUUID: nil, contentParams: nil, isNovel: isNovel, chapterParams: "chapter", authenticationProfileID: UUID()), status: status, progress: 0.5, completedPages: 1, totalPages: 2, downloadedBytes: 1024, error: nil, dateAdded: Date(), dateCompleted: nil)
        row.storageLocation = DownloadStorageLocation(rootID: UUID(), relativePath: "Reader/\(ReaderDownloadManager.stableHash(route.stableKey))/\(ReaderDownloadManager.stableHash(key))")
        return row
    }
}
