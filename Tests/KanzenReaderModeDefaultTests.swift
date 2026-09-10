import XCTest
@testable import Eclipse

#if os(iOS)
import Combine
import SwiftUI
import WebKit

final class KanzenReaderModeDefaultTests: XCTestCase {

    @MainActor
    func testPagedModeChangesReplaceDirectionAndOrientation() {
        let left = KanzenPagedReaderViewController(mode: .ltr, pageOffsetKey: nil)
        let anotherLeft = KanzenPagedReaderViewController(mode: .ltr, pageOffsetKey: nil)
        let right = KanzenPagedReaderViewController(mode: .rtl, pageOffsetKey: nil)
        let vertical = KanzenPagedReaderViewController(mode: .vertical, pageOffsetKey: nil)
        XCTAssertTrue(KanzenReaderViewController.canReuseReader(left, for: anotherLeft))
        XCTAssertFalse(KanzenReaderViewController.canReuseReader(left, for: right))
        XCTAssertFalse(KanzenReaderViewController.canReuseReader(right, for: vertical))
        XCTAssertFalse(KanzenReaderViewController.canReuseReader(vertical, for: left))
    }

    func testNovelPositionKeysSurviveChapterRecreationAndSeparateSources() {
        let first = NovelReaderPositionKey.make(titleIdentity: "source-a/title-12", chapterIdentity: "chapter-7")
        XCTAssertEqual(first, NovelReaderPositionKey.make(titleIdentity: "source-a/title-12", chapterIdentity: "chapter-7"))
        XCTAssertNotEqual(first, NovelReaderPositionKey.make(titleIdentity: "source-b/title-12", chapterIdentity: "chapter-7"))
        XCTAssertNotEqual(first, NovelReaderPositionKey.make(titleIdentity: "source-a/title-12", chapterIdentity: "chapter-8"))
        XCTAssertNotEqual(NovelReaderPositionKey.make(titleIdentity: "a", chapterIdentity: "bc"), NovelReaderPositionKey.make(titleIdentity: "ab", chapterIdentity: "c"))
    }

    func testTextAndSplitCompletionOverridePreventsSyntheticLastPageMarkingRead() {
        let manager = MangaReadingProgressManager(profileID: UUID(), defaults: makeStore())
        manager.savePagePosition(mangaId: 1, chapterNumber: "1", page: 0, pageCount: 1, readThreshold: 0.8, readingCompletion: 0)
        XCTAssertFalse(manager.isChapterRead(mangaId: 1, chapterNumber: "1"))
        manager.savePagePosition(mangaId: 1, chapterNumber: "1", page: 0, pageCount: 1, readThreshold: 0.8, readingCompletion: 0.79)
        XCTAssertFalse(manager.isChapterRead(mangaId: 1, chapterNumber: "1"))
        manager.savePagePosition(mangaId: 1, chapterNumber: "1", page: 0, pageCount: 1, readThreshold: 0.8, readingCompletion: 0.8)
        XCTAssertTrue(manager.isChapterRead(mangaId: 1, chapterNumber: "1"))
        manager.savePagePosition(mangaId: 1, chapterNumber: "2", page: 9, pageCount: 10, readThreshold: 1, readingCompletion: 0.95)
        XCTAssertFalse(manager.isChapterRead(mangaId: 1, chapterNumber: "2"))
        XCTAssertEqual(manager.pagePosition(mangaId: 1, chapterNumber: "2"), 9)
        manager.savePagePosition(mangaId: 1, chapterNumber: "2", page: 9, pageCount: 10, readThreshold: 1, readingCompletion: 1)
        XCTAssertTrue(manager.isChapterRead(mangaId: 1, chapterNumber: "2"))
    }

    @MainActor
    func testPreparingWidePageLayoutCannotMarkRestoredLastSourcePageRead() {
        let manager = MangaReadingProgressManager(profileID: UUID(), defaults: makeStore())
        let provisional = KanzenPagedReaderViewController.readingCompletion(lastDisplayPage: 2, displayPageCount: 3, isPreparingSplitPages: true)
        manager.savePagePosition(mangaId: 2, chapterNumber: "1", page: 2, pageCount: 3, readThreshold: 0.9, readingCompletion: provisional)
        XCTAssertFalse(manager.isChapterRead(mangaId: 2, chapterNumber: "1"))
        let firstHalf = KanzenPagedReaderViewController.readingCompletion(lastDisplayPage: 4, displayPageCount: 6, isPreparingSplitPages: false)
        manager.savePagePosition(mangaId: 2, chapterNumber: "1", page: 2, pageCount: 3, readThreshold: 0.9, readingCompletion: firstHalf)
        XCTAssertFalse(manager.isChapterRead(mangaId: 2, chapterNumber: "1"))
        let secondHalf = KanzenPagedReaderViewController.readingCompletion(lastDisplayPage: 5, displayPageCount: 6, isPreparingSplitPages: false)
        manager.savePagePosition(mangaId: 2, chapterNumber: "1", page: 2, pageCount: 3, readThreshold: 0.9, readingCompletion: secondHalf)
        XCTAssertTrue(manager.isChapterRead(mangaId: 2, chapterNumber: "1"))
    }

    func testSplitPageUnitsResolveSourcePositions() {
        let data = PageData(content: "https://example.com/page.jpg")
        let left = KanzenReaderPage(pageData: data, index: 8, chapterNumber: "1", sourceIndex: 4, splitHalf: 0)
        let right = KanzenReaderPage(pageData: data, index: 9, chapterNumber: "1", sourceIndex: 4, splitHalf: 1)
        let unit = KanzenPagedUnit(pages: [right], firstPageIndex: 9)
        XCTAssertTrue(unit.contains(page: 4))
        XCTAssertFalse(unit.contains(page: 9))
        XCTAssertEqual(left.pageData, right.pageData)
        XCTAssertNotEqual(left.splitHalf, right.splitHalf)
    }

    @MainActor
    func testReaderSessionRejectsChapterResponseAfterSelectionReturnsToSameChapter() async throws {
        let a = Chapter(chapterNumber: "1", idx: 0, chapterData: nil)
        let b = Chapter(chapterNumber: "2", idx: 1, chapterData: nil)
        var continuations: [CheckedContinuation<[PageData], Error>] = []
        let session = KanzenReaderSession(kanzen: KanzenEngine(), chapters: [a, b], selectedChapter: a, mangaId: 0, mangaTitle: "Fixture", mangaCoverURL: "", mangaRoute: nil, mangaFormat: nil, totalChapters: nil, latestChapterNumbers: nil, trackerAniListId: nil, trackerMALId: nil, pageLoader: { _, _ in
            try await withCheckedThrowingContinuation { continuations.append($0) }
        })
        let old = Task { try await session.loadSelectedChapter() }
        for _ in 0..<100 where continuations.isEmpty { await Task.yield() }
        guard let oldContinuation = continuations.first else { old.cancel(); return XCTFail("first load did not suspend") }
        session.selectChapter(b)
        session.selectChapter(a)
        let latest = Task { try await session.loadSelectedChapter() }
        for _ in 0..<100 where continuations.count < 2 { await Task.yield() }
        guard continuations.count == 2 else {
            oldContinuation.resume(throwing: CancellationError())
            latest.cancel()
            return XCTFail("replacement load did not suspend")
        }
        continuations[1].resume(returning: [PageData(content: .text("current chapter"))])
        _ = try await latest.value
        oldContinuation.resume(returning: [PageData(content: .text("stale chapter"))])
        do { _ = try await old.value; XCTFail("stale load was accepted") } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(session.pages.first?.text, "current chapter")
        XCTAssertEqual(session.selectedChapter.chapterNumber, "1")
    }

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

    func testLegacyBackupSanitizesNovelColorPresetBeforeItCanIndexThePalette() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for value in [Int.min, -1, 0, 1, 2, 3, 4, 5, Int.max] {
            let data = try JSONSerialization.data(withJSONObject: [
                "version": "1.0",
                "createdDate": "2026-09-05T00:00:00Z",
                "readerColorPreset": value
            ])
            let backup = try decoder.decode(BackupData.self, from: data)
            XCTAssertEqual(backup.readerColorPreset, (0...4).contains(value) ? value : 0)
            XCTAssertTrue(backup.topLevelSettingIsAuthoritative(storageKey: "readerColorPreset"))
        }
    }

    func testBackupEncodingCannotExportAnInvalidNovelColorPreset() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var backup = try decoder.decode(
            BackupData.self,
            from: Data(#"{"createdDate":"2026-09-05T00:00:00Z","readerColorPreset":4}"#.utf8)
        )
        backup.readerColorPreset = Int.max
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let restored = try decoder.decode(BackupData.self, from: encoder.encode(backup))
        XCTAssertEqual(restored.readerColorPreset, 0)
    }

    func testSequentialUnreadCountMatchesExistingChapterIdentityRules() {
        let readSets: [Set<String>] = [
            [],
            ["1", "Chapter 1", "01", "1.0", "2.5", "0", "-1"],
            ["Chapter 4 - revision 2", "Vol 1 Chapter 2", "Episode 3", "7 Extra", "Extra"],
            Set((1...100).map(String.init))
        ]
        for total in [1, 7, 100] {
            let item = MangaLibraryItem(aniListId: 1, title: "Reader probe", totalChapters: total)
            for read in readSets {
                let keys = Set(read.map(ChapterIdentityNormalizer.key))
                let expected = (1...total).filter {
                    !keys.contains(ChapterIdentityNormalizer.key(for: String($0)))
                }.count
                XCTAssertEqual(item.unreadCount(readChapters: read), expected)
            }
        }
    }

    func testUntrustedLargeChapterTotalsDoNotRequireEnumeratingChapters() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "aniListId": 1,
            "title": "Reader probe",
            "totalChapters": Int.max,
            "dateAdded": "2026-09-05T00:00:00Z"
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(MangaLibraryItem.self, from: data)
        XCTAssertEqual(item.unreadCount(readChapters: []), Int.max)
        XCTAssertEqual(item.unreadCount(readChapters: ["1", "Chapter 1", "2", "2.5", "Vol 1 Chapter 3"]), Int.max - 2)
    }

    func testSourceChapterNumbersRetainFractionalAndVolumeSpecificIdentity() {
        let item = MangaLibraryItem(
            aniListId: 1,
            title: "Reader probe",
            totalChapters: Int.max,
            latestChapterNumbers: ["1", "1.0", "2.5", "Vol 1 Chapter 2", "Extra"]
        )
        XCTAssertEqual(item.unreadCount(readChapters: ["Chapter 1", "2.5"]), 2)
        XCTAssertEqual(MangaLibraryItem(aniListId: 1, title: "Reader probe", totalChapters: -1).unreadCount(readChapters: ["1"]), 0)
    }

    func testTrackerMangaExpansionRejectsUnboundedCountsWithoutTruncation() {
        XCTAssertTrue(TrackerRemoteProgressBoundary.canExpandMangaProgress(0))
        XCTAssertTrue(TrackerRemoteProgressBoundary.canExpandMangaProgress(100_000))
        XCTAssertFalse(TrackerRemoteProgressBoundary.canExpandMangaProgress(100_001))
        XCTAssertFalse(TrackerRemoteProgressBoundary.canExpandMangaProgress(Int.max))
        XCTAssertFalse(TrackerRemoteProgressBoundary.canExpandMangaProgress(-1))
    }

    func testMangaPaginationRejectsRepeatedMALContinuation() throws {
        var sequence = TrackerRemoteProgressBoundary.PageSequence()
        let first = try XCTUnwrap(URL(string: "https://api.myanimelist.net/v2/users/@me/mangalist?offset=0"))
        let second = try XCTUnwrap(URL(string: "https://api.myanimelist.net/v2/users/@me/mangalist?offset=1000"))
        let third = try XCTUnwrap(URL(string: "https://api.myanimelist.net/v2/users/@me/mangalist?offset=2000"))

        XCTAssertTrue(sequence.beginMALPage(first, listKind: .manga))
        XCTAssertTrue(sequence.allowsMALContinuation(second, listKind: .manga))
        XCTAssertTrue(sequence.beginMALPage(second, listKind: .manga))
        XCTAssertFalse(sequence.allowsMALContinuation(first, listKind: .manga))
        XCTAssertFalse(sequence.beginMALPage(first, listKind: .manga))
        XCTAssertFalse(sequence.beginMALPage(second, listKind: .manga))
        XCTAssertTrue(sequence.beginMALPage(third, listKind: .manga))
    }

    func testMangaPaginationUsesExistingPageLimitForUniqueURLsAndChunks() throws {
        var malSequence = TrackerRemoteProgressBoundary.PageSequence()
        var aniListSequence = TrackerRemoteProgressBoundary.PageSequence()
        for offset in 0..<1_000 {
            let url = try XCTUnwrap(URL(string: "https://api.myanimelist.net/v2/users/@me/mangalist?offset=\(offset)"))
            XCTAssertTrue(malSequence.beginMALPage(url, listKind: .manga))
            XCTAssertTrue(aniListSequence.beginPage())
        }
        let beyondLimit = try XCTUnwrap(URL(string: "https://api.myanimelist.net/v2/users/@me/mangalist?offset=1000"))
        XCTAssertFalse(malSequence.allowsMALContinuation(beyondLimit, listKind: .manga))
        XCTAssertFalse(malSequence.beginMALPage(beyondLimit, listKind: .manga))
        XCTAssertFalse(aniListSequence.canRequestNextPage)
        XCTAssertFalse(aniListSequence.beginPage())
    }

    func testMangaPaginationRestrictsContinuationToItsMALList() throws {
        var sequence = TrackerRemoteProgressBoundary.PageSequence()
        let invalidURLs = [
            "http://api.myanimelist.net/v2/users/@me/mangalist?offset=1000",
            "https://example.com/v2/users/@me/mangalist?offset=1000",
            "https://api.myanimelist.net:443/v2/users/@me/mangalist?offset=1000",
            "https://api.myanimelist.net/v2/users/@me/animelist?offset=1000",
            "https://api.myanimelist.net/v2/manga/1"
        ]
        for raw in invalidURLs {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertFalse(sequence.beginMALPage(url, listKind: .manga))
        }
        let mangaURL = try XCTUnwrap(URL(string: "https://api.myanimelist.net/v2/users/@me/mangalist?offset=0"))
        let animeURL = try XCTUnwrap(URL(string: "https://api.myanimelist.net/v2/users/@me/animelist?offset=0"))
        XCTAssertTrue(sequence.beginMALPage(mangaURL, listKind: .manga))
        XCTAssertTrue(TrackerRemoteProgressBoundary.isAllowedMALPageURL(animeURL))
        XCTAssertFalse(TrackerRemoteProgressBoundary.isAllowedMALPageURL(mangaURL))
    }

    func testMangaPaginationRejectsOversizedAggregateBeforeAppending() {
        XCTAssertTrue(TrackerRemoteProgressBoundary.canAppendEntries(500, existingCount: 99_500))
        XCTAssertTrue(TrackerRemoteProgressBoundary.canAppendEntries(0, existingCount: 100_000))
        XCTAssertFalse(TrackerRemoteProgressBoundary.canAppendEntries(1, existingCount: 100_000))
        XCTAssertFalse(TrackerRemoteProgressBoundary.canAppendEntries(100_001, existingCount: 0))
        XCTAssertFalse(TrackerRemoteProgressBoundary.canAppendEntries(Int.max, existingCount: 1))
        XCTAssertFalse(TrackerRemoteProgressBoundary.canAppendEntries(1, existingCount: Int.max))
        XCTAssertFalse(TrackerRemoteProgressBoundary.canAppendEntries(-1, existingCount: 0))
        XCTAssertFalse(TrackerRemoteProgressBoundary.canAppendEntries(0, existingCount: -1))
    }

    func testImportedPagePositionsClampBeforeConvertingToDisplayedPage() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "pagePositions": ["1": Int.max, "2": Int.min],
            "pageCounts": ["1": 5, "2": Int.max]
        ])
        let progress = try JSONDecoder().decode(MangaProgress.self, from: data)
        let first = try XCTUnwrap(progress.pagePositions["1"])
        let second = try XCTUnwrap(progress.pagePositions["2"])
        XCTAssertEqual(MangaProgress.displayedPage(position: first, total: 5), 5)
        XCTAssertEqual(MangaProgress.displayedPage(position: second, total: Int.max), 1)
        XCTAssertEqual(MangaProgress.displayedPage(position: Int.max, total: Int.max), Int.max)
        XCTAssertEqual(MangaProgress.displayedPage(position: 3, total: 5), 4)
        XCTAssertNil(MangaProgress.displayedPage(position: 0, total: 0))
        XCTAssertNil(MangaProgress.displayedPage(position: 0, total: Int.min))
    }
}


extension KanzenReaderModeDefaultTests {
    func testModuleUpdateRefindsReorderedRowsAndRejectsRemovedOrReplacedRows() throws {
        let data = Data(#"{"sourceName":"Fixture","author":{"name":"Fixture"},"iconURL":"","version":"1","language":"en","scriptURL":"https://example.invalid/fixture.js"}"#.utf8)
        let metadata = try JSONDecoder().decode(ModuleData.self, from: data)
        let original = ModuleDataContainer(moduleData: metadata, localPath: "/fixture/a.js", moduleurl: "https://example.invalid/a", isActive: true)
        let other = ModuleDataContainer(moduleData: metadata, localPath: "/fixture/b.js", moduleurl: "https://example.invalid/b")
        var toggled = original
        toggled.isActive = false
        XCTAssertEqual(ModuleManager.currentUpdateIndex(for: original, in: [other, toggled], expectedGeneration: 1, currentGeneration: 1), 1)
        XCTAssertNil(ModuleManager.currentUpdateIndex(for: original, in: [other], expectedGeneration: 1, currentGeneration: 1))
        XCTAssertNil(ModuleManager.currentUpdateIndex(for: original, in: [original], expectedGeneration: 1, currentGeneration: 3))
        let replaced = ModuleDataContainer(id: original.id, moduleData: metadata, localPath: "/fixture/new.js", moduleurl: original.moduleurl)
        XCTAssertNil(ModuleManager.currentUpdateIndex(for: original, in: [replaced], expectedGeneration: 1, currentGeneration: 1))
    }

    @MainActor
    func testChapterSnapshotPreservesOrderingPayloadAndLanguageFallback() async throws {
        let numbers = ["Extras", "Chapter 2.5", "Chapter 1", "Chapter 2", "2", "Prologue"]
        let chapters = numbers.enumerated().map { index, number in
            Chapter(chapterNumber: number, idx: index, chapterData: [ChapterData(params: "payload-\(index)")])
        }
        let snapshot = await LegacyReaderChapterSnapshot.prepare([
            Chapters(language: "English", chapters: chapters),
            Chapters(language: "French", chapters: [])
        ])
        let group = try XCTUnwrap(snapshot.group(at: 0))
        XCTAssertEqual(group.chronological.map(\.chapterNumber), ["Chapter 1", "Chapter 2", "2", "Chapter 2.5", "Prologue", "Extras"])
        XCTAssertEqual(group.readerChapters.map(\.chapterNumber), ["Chapter 1", "Chapter 2", "Chapter 2.5", "Prologue", "Extras"])
        XCTAssertEqual(group.readerChapters.map(\.idx), Array(0..<5))
        XCTAssertEqual(group.readerChapters.first?.chapterData?.first?.params as? String, "payload-2")
        XCTAssertEqual(group.reversed.map(\.id), Array(chapters.reversed()).map(\.id))
        XCTAssertEqual(group.readingTarget(lastRead: "2.5", readKeys: ["c1", "c2"])?.chapterNumber, "Chapter 2.5")
        XCTAssertEqual(group.readingTarget(lastRead: nil, readKeys: ["c1", "c2"])?.chapterNumber, "Chapter 2.5")
        XCTAssertEqual(snapshot.group(at: Int.max)?.original.language, "English")
        XCTAssertEqual(LegacyReaderChapterSnapshot.selectedIndex(languages: ["English", "French"], preserving: "French"), 1)
        XCTAssertEqual(LegacyReaderChapterSnapshot.selectedIndex(languages: ["English"], preserving: "French"), 0)
        let empty = await LegacyReaderChapterSnapshot.prepare([])
        XCTAssertNil(empty.group(at: 0))
    }

    @MainActor
    func testNovelTeardownInvalidatesBothTimersAndRejectsLateCallbacks() async throws {
        var scrolling = true
        let view = NovelHTMLView(htmlContent: "", fontSize: 18, fontFamily: "serif", fontWeight: "normal", textAlignment: "left", lineSpacing: 1.5, margin: 8, isAutoScrolling: Binding(get: { scrolling }, set: { scrolling = $0 }), autoScrollSpeed: 1, colorPreset: ("Fixture", "#000000", "#ffffff"), chapterKey: "fixture", settingsStore: makeStore(), isolatesReaderExtensionHTML: false, scrollRequest: nil)
        var coordinator: NovelHTMLView.Coordinator? = view.makeCoordinator()
        var webView: WKWebView? = WKWebView(frame: .zero)
        let live = try XCTUnwrap(coordinator)
        live.webView = webView
        var scripts = 0
        var delayed: ((Any?, Error?) -> Void)?
        live.scriptEvaluator = { _, _, completion in
            scripts += 1
            if let completion { delayed = completion }
        }
        if let webView {
            live.startAutoScroll(webView)
            let timer = try XCTUnwrap(live.scrollTimer)
            live.startAutoScroll(webView)
            XCTAssertTrue(live.scrollTimer === timer)
            live.startProgressTracking(webView: webView)
            timer.fire()
            let before = scripts
            live.tearDown()
            XCTAssertFalse(timer.isValid)
            XCTAssertNil(live.scrollTimer)
            XCTAssertNil(live.progressTimer)
            XCTAssertNil(live.webView)
            timer.fire()
            delayed?(true, nil)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            XCTAssertEqual(scripts, before)
            XCTAssertTrue(scrolling)
            XCTAssertTrue(webView.configuration.userContentController.userScripts.isEmpty)
        }
        coordinator = nil
        webView = nil
    }

    @MainActor
    func testNovelTimerDoesNotRetainItsCoordinatorAfterTeardown() throws {
        let view = NovelHTMLView(htmlContent: "", fontSize: 18, fontFamily: "serif", fontWeight: "normal", textAlignment: "left", lineSpacing: 1.5, margin: 8, isAutoScrolling: .constant(true), autoScrollSpeed: 1, colorPreset: ("Fixture", "#000000", "#ffffff"), chapterKey: "fixture", settingsStore: makeStore(), isolatesReaderExtensionHTML: false, scrollRequest: nil)
        var coordinator: NovelHTMLView.Coordinator? = view.makeCoordinator()
        weak var weakCoordinator = coordinator
        let webView = WKWebView(frame: .zero)
        coordinator?.webView = webView
        coordinator?.startAutoScroll(webView)
        let timer = try XCTUnwrap(coordinator?.scrollTimer)
        coordinator?.tearDown()
        coordinator = nil
        XCTAssertNil(weakCoordinator)
        timer.fire()
        XCTAssertFalse(timer.isValid)
    }

    @MainActor
    func testNovelSameHTMLChapterChangeRejectsStaleNavigationAndBottomCallback() async throws {
        var scrolling = true
        let store = makeStore()
        func view(_ chapter: String) -> NovelHTMLView {
            NovelHTMLView(htmlContent: "<p>Same text</p>", fontSize: 18, fontFamily: "serif", fontWeight: "normal", textAlignment: "left", lineSpacing: 1.5, margin: 8, isAutoScrolling: Binding(get: { scrolling }, set: { scrolling = $0 }), autoScrollSpeed: 1, colorPreset: ("Fixture", "#000000", "#ffffff"), chapterKey: chapter, settingsStore: store, isolatesReaderExtensionHTML: false, scrollRequest: nil)
        }
        let firstView = view("first")
        let coordinator = firstView.makeCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView
        defer { coordinator.tearDown() }
        coordinator.recordDocument(firstView)
        XCTAssertFalse(coordinator.documentHasChanged(firstView))
        let secondView = view("second")
        XCTAssertTrue(coordinator.documentHasChanged(secondView))
        var oldBottom: ((Any?, Error?) -> Void)?
        coordinator.scriptEvaluator = { _, _, completion in
            if let completion { oldBottom = completion }
        }
        coordinator.beginDocumentReplacement()
        let firstNavigation = try XCTUnwrap(webView.loadHTMLString("<p>Same text</p>", baseURL: nil))
        coordinator.registerNavigation(firstNavigation)
        coordinator.webView(webView, didFinish: firstNavigation)
        XCTAssertTrue(coordinator.isDocumentReady)
        let firstTimer = try XCTUnwrap(coordinator.scrollTimer)
        firstTimer.fire()
        let oldGeneration = coordinator.documentGeneration
        coordinator.parent = secondView
        coordinator.beginDocumentReplacement()
        XCTAssertNotEqual(coordinator.documentGeneration, oldGeneration)
        XCTAssertFalse(firstTimer.isValid)
        let secondNavigation = try XCTUnwrap(webView.loadHTMLString("<p>Same text</p>", baseURL: nil))
        coordinator.registerNavigation(secondNavigation)
        coordinator.recordDocument(secondView)
        coordinator.webView(webView, didFinish: firstNavigation)
        XCTAssertFalse(coordinator.isDocumentReady)
        XCTAssertNil(coordinator.scrollTimer)
        oldBottom?(true, nil)
        coordinator.webView(webView, didFinish: secondNavigation)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(scrolling)
        XCTAssertTrue(coordinator.isDocumentReady)
        XCTAssertTrue(try XCTUnwrap(coordinator.scrollTimer).isValid)
    }

    @MainActor
    func testNovelTeardownRemovesHandlerFromItsOriginalContentWorld() {
        let store = makeStore()
        func view(isolated: Bool) -> NovelHTMLView {
            NovelHTMLView(htmlContent: "<p>Text</p>", fontSize: 18, fontFamily: "serif", fontWeight: "normal", textAlignment: "left", lineSpacing: 1.5, margin: 8, isAutoScrolling: .constant(false), autoScrollSpeed: 1, colorPreset: ("Fixture", "#000000", "#ffffff"), chapterKey: "first", settingsStore: store, isolatesReaderExtensionHTML: isolated, scrollRequest: nil)
        }
        var coordinator: NovelHTMLView.Coordinator? = view(isolated: false).makeCoordinator()
        weak var weakCoordinator = coordinator
        let webView = WKWebView(frame: .zero)
        coordinator?.webView = webView
        coordinator?.startProgressTracking(webView: webView)
        coordinator?.parent = view(isolated: true)
        coordinator?.tearDown()
        coordinator = nil
        XCTAssertNil(weakCoordinator)
        XCTAssertTrue(webView.configuration.userContentController.userScripts.isEmpty)
    }

    func testMangaImportPreparationUnionsProgressAndPreservesMetadata() throws {
        var existing = MangaProgress()
        existing.readChapterNumbers = ["12", "Chapter 2.5"]
        existing.pagePositions = ["8": 4]
        existing.format = "Manhwa"
        let result = try MangaReadingProgressManager.prepareImport([
            .init(mangaID: -1, throughChapter: 3, title: "Title", coverURL: "cover", totalChapters: 20),
            .init(mangaID: -2, throughChapter: 100_001, title: nil, coverURL: nil, totalChapters: nil)
        ], progress: [-1: existing])
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.rejected, 1)
        let value = try XCTUnwrap(result.progress[-1])
        XCTAssertEqual(value.readChapterNumbers, ["1", "2", "3", "12", "Chapter 2.5"])
        XCTAssertEqual(value.lastReadChapter, "12")
        XCTAssertEqual(value.pagePositions, ["8": 4])
        XCTAssertEqual(value.format, "Manhwa")
        XCTAssertEqual(value.title, "Title")
        XCTAssertEqual(try JSONDecoder().decode([Int: MangaProgress].self, from: result.data)[-1]?.readChapterNumbers, value.readChapterNumbers)
    }

    @MainActor
    func testMangaImportPublishesOnceAndPersistsTheWholeBatch() async throws {
        let owner = UUID()
        let store = makeStore()
        let manager = MangaReadingProgressManager(profileID: owner, defaults: store)
        var publications = 0
        let subscription = manager.$progressMap.dropFirst().sink { _ in publications += 1 }
        let records = (1...30).map { MangaReadingProgressManager.ImportRecord(mangaID: -$0, throughChapter: 100, title: "Title \($0)", coverURL: nil, totalChapters: 100) }
        let result = try await manager.importChapters(records, owner: owner, validateAuthority: {})
        XCTAssertEqual(result.imported, 30)
        XCTAssertEqual(publications, 1)
        let persisted = try XCTUnwrap(store.data(forKey: MangaReadingProgressManager.storageKey(for: owner)))
        let decoded = try JSONDecoder().decode([Int: MangaProgress].self, from: persisted)
        XCTAssertEqual(decoded.count, 30)
        XCTAssertTrue(decoded.values.allSatisfy { $0.readChapterNumbers.count == 100 })
        withExtendedLifetime(subscription) {}
    }

    func testMangaImportRebasesMetadataButAbortsResetAndProfileRoundTrip() throws {
        let owner = UUID()
        let manager = MangaReadingProgressManager(profileID: owner, defaults: makeStore())
        let records = [MangaReadingProgressManager.ImportRecord(mangaID: -1, throughChapter: 3, title: nil, coverURL: nil, totalChapters: nil)]
        let first = try XCTUnwrap(manager.captureImport(owner: owner, invalidation: nil))
        let firstPrepared = try MangaReadingProgressManager.prepareImport(records, progress: first.progress)
        manager.updateSourceMetadata(mangaId: -1, title: "New metadata", latestChapterNumbers: ["1", "2", "3"], forProfile: owner)
        XCTAssertFalse(try manager.commitImport(firstPrepared, snapshot: first))
        let rebased = try XCTUnwrap(manager.captureImport(owner: owner, invalidation: first.invalidation))
        let prepared = try MangaReadingProgressManager.prepareImport(records, progress: rebased.progress)
        XCTAssertTrue(try manager.commitImport(prepared, snapshot: rebased))
        XCTAssertEqual(manager.progress(for: -1)?.title, "New metadata")
        let beforeReset = try XCTUnwrap(manager.captureImport(owner: owner, invalidation: nil))
        manager.markAllUnread(mangaId: -1)
        XCTAssertThrowsError(try manager.commitImport(prepared, snapshot: beforeReset)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(manager.readChapters(for: -1).isEmpty)
        let beforeSwitch = try XCTUnwrap(manager.captureImport(owner: owner, invalidation: nil))
        manager.switchProfile(to: UUID())
        manager.switchProfile(to: owner)
        XCTAssertThrowsError(try manager.commitImport(prepared, snapshot: beforeSwitch)) { XCTAssertTrue($0 is CancellationError) }
    }

    func testMangaReadKeyCacheInvalidatesOnRestoreAndUnread() {
        let manager = MangaReadingProgressManager(profileID: UUID(), defaults: makeStore())
        var progress = MangaProgress()
        progress.readChapterNumbers = ["Chapter 1"]
        manager.replaceProgressMapForRestore([-1: progress])
        XCTAssertEqual(manager.normalizedReadChapterKeys(for: -1), ["c1"])
        manager.markAllUnread(mangaId: -1)
        XCTAssertTrue(manager.normalizedReadChapterKeys(for: -1).isEmpty)
        progress.readChapterNumbers = ["Chapter 2"]
        manager.replaceProgressMapForRestore([-1: progress])
        XCTAssertEqual(manager.normalizedReadChapterKeys(for: -1), ["c2"])
    }

    private func downloadFixture(_ chapter: Int, status: ReaderDownloadStatus = .queued) -> ReaderDownloadItem {
        let route = MangaContentRoute.legacyModule(moduleUUID: "fixture", contentParams: "title", isNovel: false)
        let number = String(chapter)
        return ReaderDownloadItem(id: ReaderDownloadManager.downloadId(route: route, chapterNumber: number), route: route, routeKey: route.stableKey, mangaId: route.stableNegativeId, mangaTitle: "Fixture", coverURL: nil, sourceName: "Fixture", format: "Manga", chapterNumber: number, chapterTitle: nil, chapterKey: ChapterIdentityNormalizer.key(for: number), contentRating: ReaderContentRating.safe.rawValue, provider: ReaderDownloadProvider(kind: .legacyModule, sourceId: nil, mangaKey: nil, moduleUUID: "fixture", contentParams: "title", isNovel: false, chapterParams: "chapter-\(number)"), status: status, progress: 0, completedPages: 0, totalPages: 0, downloadedBytes: 0, error: nil, dateAdded: Date(timeIntervalSince1970: 1), dateCompleted: nil)
    }

    func testDownloadBatchKeepsExistingRowsAndStopsAtTheFirstRejectedChapter() throws {
        let completed = downloadFixture(1, status: .completed)
        let paused = downloadFixture(2, status: .paused)
        let plan = try ReaderDownloadManager.prepareEnqueue(current: [completed, paused], proposals: [downloadFixture(1), downloadFixture(2), downloadFixture(3)])
        XCTAssertEqual(plan.items.map(\.chapterNumber), ["1", "2", "3"])
        XCTAssertEqual(plan.items[0], completed)
        XCTAssertEqual(plan.items[1].status, .queued)
        XCTAssertEqual(plan.queuedIDs, [paused.id, downloadFixture(3).id])
        XCTAssertTrue(ReaderDownloadManager.persistedIndexSchemaIsValid(try XCTUnwrap(plan.data)))
        var invalid = downloadFixture(4)
        invalid.provider.chapterParams = String(repeating: "a", count: 100_000)
        let partial = try ReaderDownloadManager.prepareEnqueue(current: [], proposals: [downloadFixture(3), invalid, downloadFixture(5)])
        XCTAssertEqual(partial.items.map(\.chapterNumber), ["3"])
        XCTAssertNotNil(partial.errorMessage)
        XCTAssertNotNil(partial.data)
        let unchanged = try ReaderDownloadManager.prepareEnqueue(current: [completed], proposals: [downloadFixture(1)])
        XCTAssertNil(unchanged.data)
    }

    @MainActor
    func testDownloadAllUsesOneDurableWriteAndCancelIsOrderedAfterIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let began = expectation(description: "first write began")
        let writer = ReaderIndexWriteProbe(firstWriteBegan: began)
        let manager = ReaderDownloadManager(downloadsRoot: root, write: writer.write)
        let route = downloadFixture(1).route
        let chapters = (1...300).map { Chapter(chapterNumber: String($0), idx: $0 - 1, chapterData: [ChapterData(params: "chapter-\($0)")]) }
        manager.enqueueChapters(route: route, mangaId: route.stableNegativeId, title: "Fixture", coverURL: nil, sourceName: "Fixture", format: "Manga", chapters: chapters)
        await fulfillment(of: [began], timeout: 10)
        XCTAssertTrue(manager.downloads.isEmpty)
        let cancelled = ReaderDownloadManager.downloadId(route: route, chapterNumber: "150")
        manager.cancelDownload(id: cancelled)
        writer.releaseFirstWrite()
        await manager.waitForPendingMutations()
        XCTAssertEqual(writer.writeCount, 2)
        XCTAssertEqual(writer.firstBatchCount, 300)
        XCTAssertTrue(writer.firstBatchWasPrepared)
        XCTAssertEqual(manager.downloads.count, 299)
        XCTAssertFalse(manager.downloads.contains { $0.id == cancelled })
        XCTAssertEqual(manager.downloads.first?.chapterNumber, "1")
        XCTAssertEqual(manager.downloads.last?.chapterNumber, "300")
    }

    @MainActor
    func testFailedDownloadWriteNeverStartsATransferOrPublishesQueuedRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var starts = 0
        let manager = ReaderDownloadManager(downloadsRoot: root, automaticallyStartsDownloads: true, write: { _, _ in .writeFailed(storedStateChanged: false) }, transferStarted: { _ in starts += 1 })
        let route = downloadFixture(1).route
        manager.enqueueChapter(route: route, mangaId: route.stableNegativeId, title: "Fixture", coverURL: nil, sourceName: "Fixture", format: "Manga", chapter: Chapter(chapterNumber: "1", idx: 0, chapterData: [ChapterData(params: "chapter-1")]))
        await manager.waitForPendingMutations()
        await manager.waitForPendingMutations()
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(manager.downloads.isEmpty)
        XCTAssertNotNil(manager.enqueueErrorMessage)
    }

    @MainActor
    func testQueuedResumeCannotAdoptAProfileSelectedWhileWaitingForTheWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = ProfileManager.shared.activeProfileID
        let source = ReaderExtensionSourceID(rawValue: String(repeating: "b", count: 64))
        let route = MangaContentRoute.readerExtension(source: source, itemKey: "/title", legacyStableKey: nil)
        let paused = ReaderDownloadItem(id: ReaderDownloadManager.downloadId(route: route, chapterNumber: "1"), route: route, routeKey: route.stableKey, mangaId: route.stableNegativeId, mangaTitle: "Fixture", coverURL: nil, sourceName: nil, format: "Manga", chapterNumber: "1", chapterTitle: nil, chapterKey: "c1", contentRating: ReaderContentRating.safe.rawValue, provider: ReaderDownloadProvider(kind: .readerExtension, sourceId: source.rawValue, mangaKey: "/title", moduleUUID: nil, contentParams: nil, isNovel: false, chapterParams: "/chapter", authenticationProfileID: owner), status: .paused, progress: 0, completedPages: 0, totalPages: 0, downloadedBytes: 0, error: nil, dateAdded: Date(), dateCompleted: nil)
        let began = expectation(description: "write is pending")
        let writer = ReaderIndexWriteProbe(firstWriteBegan: began)
        let manager = ReaderDownloadManager(downloadsRoot: root, initialDownloads: [paused], write: writer.write)
        let legacy = downloadFixture(1).route
        manager.enqueueChapter(route: legacy, mangaId: legacy.stableNegativeId, title: "Fixture", coverURL: nil, sourceName: nil, format: "Manga", chapter: Chapter(chapterNumber: "1", idx: 0, chapterData: [ChapterData(params: "chapter-1")]))
        await fulfillment(of: [began], timeout: 10)
        manager.resumeDownload(id: paused.id)
        manager.profileDidChange(to: UUID())
        manager.profileDidChange(to: owner)
        writer.releaseFirstWrite()
        await manager.waitForPendingMutations()
        let retained = try XCTUnwrap(manager.downloads.first { $0.id == paused.id })
        XCTAssertEqual(retained.status, .paused)
        XCTAssertEqual(retained.provider.authenticationProfileID, owner)
        XCTAssertEqual(writer.writeCount, 1)
    }

    @MainActor
    func testDownloadReadbackFailureLeavesProvidersInert() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var starts = 0
        let manager = ReaderDownloadManager(downloadsRoot: root, automaticallyStartsDownloads: true, write: { _, _ in .writeFailed(storedStateChanged: true) }, transferStarted: { _ in starts += 1 })
        let route = downloadFixture(1).route
        manager.enqueueChapter(route: route, mangaId: route.stableNegativeId, title: "Fixture", coverURL: nil, sourceName: nil, format: "Manga", chapter: Chapter(chapterNumber: "1", idx: 0, chapterData: [ChapterData(params: "chapter-1")]))
        await manager.waitForPendingMutations()
        await manager.waitForPendingMutations()
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(manager.downloads.isEmpty)
        XCTAssertNotNil(manager.enqueueErrorMessage)
    }

    func testReaderBulkPreparationFixtures() async throws {
        let records = (1...500).map { MangaReadingProgressManager.ImportRecord(mangaID: -$0, throughChapter: 300, title: "Fixture \($0)", coverURL: nil, totalChapters: 300) }
        let proposals = (1...300).map { downloadFixture($0) }
        let chapters = (1...1_200).reversed().enumerated().map { LegacyReaderChapterSnapshot.OrderingInput(number: "Chapter \($0.element)", index: $0.offset) }
        let timings = try await Task.detached(priority: .utility) {
            let start = ProcessInfo.processInfo.systemUptime
            let progress = try MangaReadingProgressManager.prepareImport(records, progress: [:])
            let mangaEnd = ProcessInfo.processInfo.systemUptime
            let downloads = try ReaderDownloadManager.prepareEnqueue(current: [], proposals: proposals)
            let downloadEnd = ProcessInfo.processInfo.systemUptime
            let ordering = LegacyReaderChapterSnapshot.ordering(chapters)
            let chapterEnd = ProcessInfo.processInfo.systemUptime
            return (progress.imported, downloads.items.count, ordering.offsets.count, mangaEnd - start, downloadEnd - mangaEnd, chapterEnd - downloadEnd)
        }.value
        XCTAssertEqual(timings.0, 500)
        XCTAssertEqual(timings.1, 300)
        XCTAssertEqual(timings.2, 1_200)
        print("ReaderBulkFixture manga500x300=\(timings.3)s downloads300=\(timings.4)s chapters1200=\(timings.5)s")
    }

    @MainActor
    func testReaderDownloadBatchWritesAndReadsBackTheActualTemporaryIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ReaderDownloadManager(downloadsRoot: root)
        let route = downloadFixture(1).route
        let chapters = (1...300).map { Chapter(chapterNumber: String($0), idx: $0 - 1, chapterData: [ChapterData(params: "chapter-\($0)")]) }
        let started = ProcessInfo.processInfo.systemUptime
        manager.enqueueChapters(route: route, mangaId: route.stableNegativeId, title: "Fixture", coverURL: nil, sourceName: "Fixture", format: "Manga", chapters: chapters)
        await manager.waitForPendingMutations()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let data = try Data(contentsOf: root.appendingPathComponent(".reader_downloads.json"))
        XCTAssertTrue(ReaderDownloadManager.persistedIndexSchemaIsValid(data))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rows = try decoder.decode([ReaderDownloadItem].self, from: data)
        XCTAssertEqual(rows.count, 300)
        XCTAssertEqual(rows.map(\.id), manager.downloads.map(\.id))
        XCTAssertTrue(rows.allSatisfy { $0.status == .queued })
        print("ReaderBulkFixture durableEnqueue300=\(elapsed)s")
    }

    @MainActor
    func testDeletedDownloadsRejectAnAlreadyRunningStorageScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 64).write(to: root.appendingPathComponent("page"))
        let began = expectation(description: "old storage scan began")
        let scanner = ReaderStorageScanProbe(firstScanBegan: began)
        let manager = ReaderDownloadManager(downloadsRoot: root, storageScan: scanner.scan)
        let completed = expectation(description: "replacement storage scan published")
        var values: [Int64] = []
        let subscription = manager.$totalDownloadedBytes.dropFirst().prefix(1).sink {
            values.append($0)
            completed.fulfill()
        }
        let observer = UUID()
        manager.beginStorageSnapshotObservation(observer)
        await fulfillment(of: [began], timeout: 10)
        manager.deleteAll()
        await manager.waitForPendingMutations()
        XCTAssertNil(manager.enqueueErrorMessage)
        XCTAssertEqual(ReaderDownloadManager.directorySize(root), 0)
        scanner.releaseFirstScan()
        await fulfillment(of: [completed], timeout: 5)
        manager.endStorageSnapshotObservation(observer)
        XCTAssertEqual(values, [0])
        XCTAssertEqual(manager.totalDownloadedBytes, 0)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testDownloadStorageSnapshotScansOnlyWhileObserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 64).write(to: root.appendingPathComponent("page"))
        let manager = ReaderDownloadManager(downloadsRoot: root, write: { _, _ in .success })
        XCTAssertEqual(manager.totalDownloadedBytes, 0)
        let observed = expectation(description: "storage snapshot arrived")
        let subscription = manager.$totalDownloadedBytes.filter { $0 >= 64 }.prefix(1).sink { _ in observed.fulfill() }
        let observer = UUID()
        manager.beginStorageSnapshotObservation(observer)
        await fulfillment(of: [observed], timeout: 5)
        manager.endStorageSnapshotObservation(observer)
        let snapshot = manager.totalDownloadedBytes
        try Data(repeating: 1, count: 256).write(to: root.appendingPathComponent("page"))
        XCTAssertEqual(manager.totalDownloadedBytes, snapshot)
        XCTAssertGreaterThan(ReaderDownloadManager.directorySize(root), snapshot)
        withExtendedLifetime(subscription) {}
    }
}

private final class ReaderStorageScanProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private let firstScanBegan: XCTestExpectation
    private let gate = DispatchSemaphore(value: 0)

    init(firstScanBegan: XCTestExpectation) {
        self.firstScanBegan = firstScanBegan
    }

    func scan(_ root: URL) -> Int64 {
        lock.lock()
        let first = !didStart
        didStart = true
        lock.unlock()
        let value = ReaderDownloadManager.directorySize(root)
        if first {
            firstScanBegan.fulfill()
            _ = gate.wait(timeout: .now() + 10)
        }
        return value
    }

    func releaseFirstScan() {
        gate.signal()
    }
}

private final class ReaderIndexWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let firstWriteBegan: XCTestExpectation
    private let gate = DispatchSemaphore(value: 0)
    private var counts: [Int] = []
    private var preparedFirst = false

    init(firstWriteBegan: XCTestExpectation) {
        self.firstWriteBegan = firstWriteBegan
    }

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return counts.count
    }

    var firstBatchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return counts.first ?? 0
    }

    var firstBatchWasPrepared: Bool {
        lock.lock()
        defer { lock.unlock() }
        return preparedFirst
    }

    func write(_ items: [ReaderDownloadItem], _ data: Data?) -> ReaderDownloadManager.IndexWriteOutcome {
        lock.lock()
        let first = counts.isEmpty
        counts.append(items.count)
        if first { preparedFirst = data != nil }
        lock.unlock()
        if first {
            firstWriteBegan.fulfill()
            guard gate.wait(timeout: .now() + 10) == .success else { return .writeFailed(storedStateChanged: false) }
        }
        return .success
    }

    func releaseFirstWrite() {
        gate.signal()
    }
}

#endif
