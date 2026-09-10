import XCTest
import SwiftUI
import Combine
import CoreMedia
@testable import Eclipse

private struct ServicesSheetInactiveSceneFixture: View {
    @Environment(\.scenePhase) private var scenePhase
    let onAppear: (Bool) -> Void
    let onScene: (ObjectIdentifier?, Bool) -> Void

    var body: some View {
        ServicesSheetPresentationAnchor(onResolve: { _ in }, onSceneActivity: onScene)
            .onAppear { onAppear(scenePhase == .active) }
    }
}

final class PlaybackInputSafetyTests: XCTestCase {
    func testAttachedSubtitleAdmissionRechecksSettingsAfterStaging() throws {
        let suite = "Eclipse.AttachedSubtitleAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sourceID = "stremio:\(UUID().uuidString)"
        let otherID = "stremio:\(UUID().uuidString)"
        let canLoad = {
            PlaybackAttachedSubtitleAdmission.allows(sourceKind: .stremio, sourceID: sourceID, defaults: defaults)
        }
        XCTAssertTrue(canLoad())
        ContentBlockingSettings.setBlocksAddonSubtitles(true, defaults: defaults)
        XCTAssertFalse(canLoad())
        for sourceKind in [PlaybackSourceKind.service, .nuvio, .skyStream] {
            XCTAssertTrue(PlaybackAttachedSubtitleAdmission.allows(sourceKind: sourceKind, sourceID: sourceID, defaults: defaults))
        }
        XCTAssertTrue(PlaybackAttachedSubtitleAdmission.allows(sourceKind: nil, sourceID: nil, defaults: defaults))
        ContentBlockingSettings.setBlocksAddonSubtitles(false, defaults: defaults)
        XCTAssertTrue(canLoad())
        StremioAddonComponentSettings.setEnabled(false, sourceID: sourceID, component: .subtitles, defaults: defaults)
        XCTAssertFalse(canLoad())
        XCTAssertTrue(PlaybackAttachedSubtitleAdmission.allows(sourceKind: .stremio, sourceID: otherID, defaults: defaults))
        StremioAddonComponentSettings.setEnabled(true, sourceID: sourceID, component: .subtitles, defaults: defaults)
        XCTAssertTrue(canLoad())
    }

    func testAudioTrackLabelsRecoverLanguagesFromGenericTitles() {
        let cases = [
            ("", "eng", "English"),
            ("Track 2", "jpn", "Japanese"),
            ("Track (2)", "spa", "Spanish"),
            ("Audio #2", "fra", "French"),
            ("  track 2  ", "ger", "German"),
            ("Track 2", "uk", "Ukrainian"),
            ("2", "hin", "Hindi"),
            ("Unknown language", "tam", "Tamil"),
            ("Audio", "pt_BR", "Portuguese (Brazil)"),
            ("Track", "es-419", "Spanish (Latin America)"),
            ("", "zh-Hant", "Chinese, Traditional")
        ]
        for (title, language, expected) in cases {
            XCTAssertEqual(
                PlaybackAudioTrackLabel.title(id: 2, title: title, language: language),
                expected
            )
        }
    }

    func testAudioTrackLabelsPreserveTitlesAndAvoidPartialLanguageMatches() {
        XCTAssertEqual(
            PlaybackAudioTrackLabel.title(id: 1, title: "Director Commentary", language: "eng"),
            "Director Commentary · English"
        )
        XCTAssertEqual(
            PlaybackAudioTrackLabel.title(id: 1, title: "French Commentary", language: "en"),
            "French Commentary · English"
        )
        XCTAssertEqual(
            PlaybackAudioTrackLabel.title(id: 1, title: "English AAC Stereo", language: "eng", codec: "aac", channelLayout: "stereo"),
            "English AAC Stereo"
        )
    }

    func testAudioTrackLabelsDescribeAvailableCodecAndLayoutWithoutGuessingLanguage() {
        XCTAssertEqual(
            PlaybackAudioTrackLabel.title(id: 3, title: "Track 3", language: "und", codec: "eac3", channelLayout: "5.1(side)", channelCount: 6),
            "Audio 3 · E-AC-3 · 5.1(side)"
        )
        XCTAssertEqual(
            PlaybackAudioTrackLabel.title(id: 4, title: "", language: "", codec: "ac3", channelCount: 6),
            "Audio 4 · AC-3 · 6 channels"
        )
        for language in ["", "und", "und-US", "unknown", "unk"] {
            XCTAssertEqual(
                PlaybackAudioTrackLabel.title(id: 5, title: "Track 5", language: language),
                "Audio 5"
            )
        }
    }

    func testAudioTrackLabelsUseContainerMetadataWithoutChangingSelectionLanguage() {
        XCTAssertEqual(
            PlaybackAudioTrackLabel.title(id: 1, title: "", language: "eng", codec: "aac", channelLayout: "stereo", channelCount: 2),
            "English · AAC · Stereo"
        )
        XCTAssertEqual(
            PlaybackAudioTrackLabel.title(id: 2, title: "", language: "jpn", codec: "pcm_s16le", channelLayout: "mono", channelCount: 1),
            "Japanese · PCM · Mono"
        )
        XCTAssertEqual(
            PlaybackAudioTrackLabel.title(id: 3, title: "", language: "qaa", codec: "truehd", channelLayout: "unknown8", channelCount: 8),
            "QAA · TrueHD · 8 channels"
        )
        XCTAssertEqual(
            PlaybackAudioTrackLabel.title(id: 4, title: "", language: "eng", codec: "ec-3"),
            "English · E-AC-3"
        )
    }

    func testActiveOwningSceneStartsWorkWhenSwiftUIRemainsInactive() {
        let owner = NSObject()
        var state = ServicesSheetActivityState()
        XCTAssertEqual(state.appear(environmentIsActive: false), .none)
        XCTAssertFalse(state.hasStarted)
        XCTAssertEqual(state.updateScene(id: ObjectIdentifier(owner), isActive: true), .start)
        XCTAssertTrue(state.allowsWork)
        XCTAssertEqual(state.updateEnvironment(isActive: false), .none)
        XCTAssertEqual(state.updateScene(id: ObjectIdentifier(owner), isActive: true), .none)
        XCTAssertEqual(state.appear(environmentIsActive: false), .none)
    }

    func testOwningScenePausesResumesAndIgnoresOtherWindows() {
        let owner = NSObject()
        let other = NSObject()
        var state = ServicesSheetActivityState()
        XCTAssertEqual(state.updateScene(id: ObjectIdentifier(owner), isActive: false), .none)
        XCTAssertEqual(state.appear(environmentIsActive: true), .none)
        XCTAssertEqual(state.sceneActivityChanged(id: ObjectIdentifier(other), isActive: true), .none)
        XCTAssertFalse(state.allowsWork)
        XCTAssertEqual(state.sceneActivityChanged(id: ObjectIdentifier(owner), isActive: true), .start)
        XCTAssertEqual(state.sceneActivityChanged(id: ObjectIdentifier(owner), isActive: false), .pause)
        XCTAssertEqual(state.updateEnvironment(isActive: true), .none)
        XCTAssertEqual(state.sceneActivityChanged(id: ObjectIdentifier(owner), isActive: true), .resume)
        XCTAssertEqual(state.updateScene(id: nil, isActive: false), .pause)
        XCTAssertEqual(state.updateEnvironment(isActive: true), .none)
        XCTAssertEqual(state.sceneActivityChanged(id: ObjectIdentifier(owner), isActive: true), .none)
    }

    func testDismissedSheetCannotRestartFromLateActivation() {
        let owner = NSObject()
        var state = ServicesSheetActivityState()
        XCTAssertEqual(state.appear(environmentIsActive: true), .start)
        state.dismiss()
        XCTAssertEqual(state.updateScene(id: ObjectIdentifier(owner), isActive: true), .none)
        XCTAssertEqual(state.updateEnvironment(isActive: true), .none)
        XCTAssertEqual(state.appear(environmentIsActive: true), .none)
        XCTAssertFalse(state.isPresented)
    }

    func testSheetResumesAfterReturningFromAChildPresentation() {
        let owner = NSObject()
        var state = ServicesSheetActivityState()
        _ = state.updateScene(id: ObjectIdentifier(owner), isActive: true)
        XCTAssertEqual(state.appear(environmentIsActive: false), .start)
        XCTAssertEqual(state.disappear(), .pause)
        XCTAssertEqual(state.updateScene(id: ObjectIdentifier(owner), isActive: true), .none)
        XCTAssertEqual(state.appear(environmentIsActive: false), .resume)
        XCTAssertEqual(state.appear(environmentIsActive: false), .none)
        state.dismiss()
        _ = state.disappear()
        XCTAssertEqual(state.appear(environmentIsActive: false), .none)
    }

    @MainActor
    func testUIKitHostingAnchorReportsActiveSceneDespiteInactiveEnvironment() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            throw XCTSkip("The test host has no active window scene")
        }
        let started = expectation(description: "Attached scene starts the inactive-environment sheet")
        var state = ServicesSheetActivityState()
        var fulfilled = false
        var observationFinished = false
        func checkStarted() {
            if state.hasStarted && !fulfilled {
                fulfilled = true
                started.fulfill()
            }
        }
        let fixture = ServicesSheetInactiveSceneFixture(
            onAppear: { active in
                guard !observationFinished else { return }
                XCTAssertFalse(active)
                _ = state.appear(environmentIsActive: active)
                checkStarted()
            },
            onScene: { sceneID, active in
                guard !observationFinished else { return }
                if let sceneID { XCTAssertEqual(sceneID, ObjectIdentifier(scene)) }
                _ = state.updateScene(id: sceneID, isActive: active)
                checkStarted()
            }
        ).environment(\.scenePhase, .inactive)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: fixture)
        window.isHidden = false
        defer {
            observationFinished = true
            window.isHidden = true
            window.rootViewController = nil
        }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(state.allowsWork)
    }

    func testServiceSettingOptionsKeepSingleQuotesWithoutTrapping() throws {
        for quote in ["\"", "'", "“", "”", "‘", "’"] {
            let source = [
                "// Settings start",
                "const mode = \"auto\"; // Select mode [\(quote), \"auto\", '', ‘manual’]",
                "// Settings end"
            ].joined(separator: "\n")
            let setting = try XCTUnwrap(ServiceManager.parseSettingsFromJS(source).first)
            XCTAssertEqual(setting.options, [quote, "auto", "manual"])
            XCTAssertEqual(setting.comment, "Select mode")
            XCTAssertEqual(setting.value, "auto")
        }
    }

    func testServiceSettingTypesAndRoundTripRemainUnchanged() {
        let source = [
            "const untouched = 7;",
            "// Settings start",
            "const text = ‘hello’; // Label [‘hello’, “world”]",
            "const enabled = true;",
            "const count = 12;",
            "const speed = 1.5;",
            "// Settings end",
            "function useSettings() { return untouched; }"
        ].joined(separator: "\n")
        let settings = ServiceManager.parseSettingsFromJS(source)
        XCTAssertEqual(settings.map(\.value), ["hello", "true", "12", "1.5"])
        XCTAssertEqual(settings.map(\.type), [.string, .bool, .int, .float])
        let updated = ServiceManager.updateSettingsInJS(source, with: settings)
        XCTAssertTrue(updated.hasPrefix("const untouched = 7;\n"))
        XCTAssertTrue(updated.hasSuffix("function useSettings() { return untouched; }"))
        XCTAssertEqual(ServiceManager.parseSettingsFromJS(updated).map(\.value), settings.map(\.value))
    }

    @MainActor
    func testTraktWatchlistBatchPersistsOnceAndPreservesExistingEntries() async throws {
        let profile = UUID()
        let key = LibraryManager.collectionsKey(for: profile)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let manager = LibraryManager(profileID: profile)
        manager.applyTraktWatchlistPull([watchlistResult(1)])
        let collection = try XCTUnwrap(manager.collections.first { $0.name == TrackerManager.traktWatchlistCollectionName })
        let originalID = collection.id
        let originalDate = Date(timeIntervalSince1970: 1234)
        collection.items = [
            LibraryItem(searchResult: watchlistResult(1), dateAdded: originalDate),
            LibraryItem(searchResult: watchlistResult(1), dateAdded: originalDate)
        ]
        await drainLibraryCallbacks()
        var publications = 0
        var saves = 0
        let subscription = collection.objectWillChange.sink { publications += 1 }
        let observer = NotificationCenter.default.addObserver(forName: .libraryDataDidChange, object: manager, queue: nil) { _ in
            saves += 1
        }
        defer {
            subscription.cancel()
            NotificationCenter.default.removeObserver(observer)
        }
        let results = (1...500).map(watchlistResult)
        manager.applyTraktWatchlistPull(results + results)
        await drainLibraryCallbacks()
        XCTAssertEqual(collection.id, originalID)
        XCTAssertEqual(collection.items.count, 501)
        XCTAssertEqual(Array(collection.items.prefix(2)).map(\.dateAdded), [originalDate, originalDate])
        XCTAssertEqual(Array(collection.items.dropFirst(2)).map { $0.searchResult.id }, Array(2...500))
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(saves, 1)
        manager.applyTraktWatchlistPull(results)
        await drainLibraryCallbacks()
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(saves, 1)
    }

    @MainActor
    func testTraktWatchlistDoesNotOverwriteUnreadableStore() {
        let profile = UUID()
        let key = LibraryManager.collectionsKey(for: profile)
        let original = Data("unreadable library".utf8)
        UserDefaults.standard.set(original, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let manager = LibraryManager(profileID: profile)
        manager.applyTraktWatchlistPull([watchlistResult(1)])
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), original)
        XCTAssertFalse(manager.collections.contains { $0.name == TrackerManager.traktWatchlistCollectionName })
    }

    private func watchlistResult(_ id: Int) -> TMDBSearchResult {
        TMDBSearchResult(id: id, mediaType: "tv", title: nil, name: "Title \(id)", overview: nil,
                         posterPath: nil, backdropPath: nil, releaseDate: nil, firstAirDate: nil,
                         voteAverage: nil, popularity: 0, adult: false, genreIds: nil)
    }

    @MainActor
    private func drainLibraryCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    func testSkipSegmentKeysRejectUnrepresentableTimes() {
        for value in [Double.nan, .infinity, -.infinity, -1, Double(Int.max), .greatestFiniteMagnitude] {
            XCTAssertEqual(SkipSegment(startTime: value, endTime: value, type: .intro).uniqueKey, "intro_unknown")
        }
        XCTAssertEqual(SkipSegment(startTime: 12.9, endTime: 90, type: .intro).uniqueKey, "intro_12")
        XCTAssertEqual(SkipSegment(startTime: 0, endTime: 90, type: .recap).uniqueKey, "recap_0")
    }

    func testAniSkipDurationHandlesUnknownAndOutOfRangeRendererValues() {
        for value in [Double.nan, .infinity, -.infinity, -1, 0, Double(Int.max), .greatestFiniteMagnitude] {
            XCTAssertEqual(AniSkipService.episodeLengthParameter(for: value), 0)
        }
        XCTAssertEqual(AniSkipService.episodeLengthParameter(for: 1440.75), 1440)
        XCTAssertEqual(AniSkipService.episodeLengthParameter(for: Double(Int.max).nextDown), Int.max - 1023)
    }

    func testAVPlayerResponseRejectsUnrepresentableAndMalformedByteRanges() throws {
        let invalidRanges = [
            "bytes 9223372036854775807-9223372036854775807/*",
            "bytes 9223372036854775806-9223372036854775807/*",
            "bytes 0-9223372036854775808/*",
            "bytes 0-1/9223372036854775808",
            "bytes -1-1/2",
            "bytes +0-1/2",
            "bytes 2-1/3",
            "bytes 0-1/1",
            "bytes 0-1/0",
            "bytes 0-1/unknown",
            "bytes 0-/2",
            "bytes 0-1/",
            "bytes 0-1/2/3",
            "bytes */2",
            "items 0-1/2"
        ]
        for range in invalidRanges {
            let response = try makeResponse(status: 206, headers: [
                "Content-Range": range,
                "Content-Length": "1"
            ])
            XCTAssertNil(AVPlayerResourceLoader.responseByteLayout(response, requestedOffset: 0), range)
        }
    }

    func testAVPlayerResponseKeepsValidPartialAndUnknownLengthRanges() throws {
        let partial = try makeResponse(status: 206, headers: [
            "Content-Range": "bytes 100-199/1000",
            "Content-Length": "100"
        ])
        let partialLayout = try XCTUnwrap(AVPlayerResourceLoader.responseByteLayout(partial, requestedOffset: 100))
        XCTAssertEqual(partialLayout.start, 100)
        XCTAssertEqual(partialLayout.totalLength, 1000)

        let unknown = try makeResponse(status: 206, headers: ["Content-Range": "Bytes 100-199/*"])
        let unknownLayout = try XCTUnwrap(AVPlayerResourceLoader.responseByteLayout(unknown, requestedOffset: 100))
        XCTAssertEqual(unknownLayout.start, 100)
        XCTAssertEqual(unknownLayout.totalLength, 200)

        let boundary = try makeResponse(status: 206, headers: [
            "Content-Range": "bytes 9223372036854775806-9223372036854775806/9223372036854775807",
            "Content-Length": "1"
        ])
        let boundaryLayout = try XCTUnwrap(AVPlayerResourceLoader.responseByteLayout(boundary, requestedOffset: Int64.max - 1))
        XCTAssertEqual(boundaryLayout.start, Int64.max - 1)
        XCTAssertEqual(boundaryLayout.totalLength, Int64.max)
    }

    func testAVPlayerResponsePreservesFullResponsesAndMissingRangeFallback() throws {
        let full = try makeResponse(status: 200, headers: ["Content-Length": "1000"])
        let fullLayout = try XCTUnwrap(AVPlayerResourceLoader.responseByteLayout(full, requestedOffset: 100))
        XCTAssertEqual(fullLayout.start, 0)
        XCTAssertEqual(fullLayout.totalLength, 1000)

        let partial = try makeResponse(status: 206, headers: ["Content-Length": "100"])
        let partialLayout = try XCTUnwrap(AVPlayerResourceLoader.responseByteLayout(partial, requestedOffset: 100))
        XCTAssertEqual(partialLayout.start, 100)
        XCTAssertEqual(partialLayout.totalLength, 200)
        XCTAssertNil(AVPlayerResourceLoader.responseByteLayout(partial, requestedOffset: Int64.max))

        let streaming = try makeResponse(status: 200, headers: [:])
        let streamingLayout = try XCTUnwrap(AVPlayerResourceLoader.responseByteLayout(streaming, requestedOffset: 0))
        XCTAssertEqual(streamingLayout.start, 0)
        XCTAssertEqual(streamingLayout.totalLength, 0)
    }

    func testAVPlayerResponseRejectsOverflowingLengthEvenWithARepresentableRange() throws {
        let response = try makeResponse(status: 206, headers: [
            "Content-Range": "bytes 9223372036854775806-9223372036854775806/9223372036854775807",
            "Content-Length": "2"
        ])
        XCTAssertNil(AVPlayerResourceLoader.responseByteLayout(response, requestedOffset: Int64.max - 1))
    }

    func testAVPlayerBodyChunkOffsetsRemainSafeAcrossStreamedChunks() {
        XCTAssertEqual(AVPlayerResourceLoader.bodyChunkRange(responseOffset: 100, receivedBytes: 0, chunkByteCount: 20), 100..<120)
        XCTAssertEqual(AVPlayerResourceLoader.bodyChunkRange(responseOffset: 100, receivedBytes: 20, chunkByteCount: 80), 120..<200)
        XCTAssertEqual(AVPlayerResourceLoader.bodyChunkRange(responseOffset: Int64.max - 1, receivedBytes: 0, chunkByteCount: 1), (Int64.max - 1)..<Int64.max)
        XCTAssertNil(AVPlayerResourceLoader.bodyChunkRange(responseOffset: Int64.max, receivedBytes: 0, chunkByteCount: 1))
        XCTAssertNil(AVPlayerResourceLoader.bodyChunkRange(responseOffset: Int64.max, receivedBytes: 1, chunkByteCount: 0))
        XCTAssertNil(AVPlayerResourceLoader.bodyChunkRange(responseOffset: -1, receivedBytes: 0, chunkByteCount: 1))
        XCTAssertNil(AVPlayerResourceLoader.bodyChunkRange(responseOffset: 0, receivedBytes: -1, chunkByteCount: 1))
        XCTAssertNil(AVPlayerResourceLoader.bodyChunkRange(responseOffset: 0, receivedBytes: 0, chunkByteCount: -1))
    }

    private func makeResponse(status: Int, headers: [String: String]) throws -> HTTPURLResponse {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/media.mp4"))
        return try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
    }
}

final class PlaybackSubtitlePrefetchPolicyTests: XCTestCase {
    private typealias Policy = PlaybackSubtitlePrefetchPolicy

    private func resolve(
        _ candidates: [Policy.Candidate],
        sources: Set<Policy.Source> = [.addon, .openSubtitles],
        subtitles: Bool = true,
        fallback: Bool = true,
        warmup: Bool = true,
        menu: Bool = false,
        constrained: Bool = false
    ) -> [String] {
        Policy.urls(
            candidates: candidates,
            enabledSources: sources,
            subtitlesEnabled: subtitles,
            automaticFallbackEnabled: fallback,
            warmupEnabled: warmup,
            menuIsOpen: menu,
            resourceConstrained: constrained
        )
    }

    func testAutomaticPreparationRespectsEachExistingSetting() {
        let candidates = [Policy.Candidate(url: "https://example.invalid/en.srt", source: .addon, matchesPreferredLanguage: true)]
        XCTAssertEqual(resolve(candidates), [candidates[0].url])
        XCTAssertTrue(resolve(candidates, subtitles: false).isEmpty)
        XCTAssertTrue(resolve(candidates, fallback: false).isEmpty)
        XCTAssertTrue(resolve(candidates, warmup: false).isEmpty)
    }

    func testOpeningMenuCanPrepareOtherLanguagesWithoutEnablingSubtitles() {
        let candidates = [Policy.Candidate(url: "https://example.invalid/fr.srt", source: .addon, matchesPreferredLanguage: false)]
        XCTAssertTrue(resolve(candidates).isEmpty)
        XCTAssertEqual(resolve(candidates, subtitles: false, fallback: false, warmup: false, menu: true), [candidates[0].url])
    }

    func testDisabledSourcesStayDisabledEvenWithMenuOpen() {
        let candidates = [
            Policy.Candidate(url: "https://example.invalid/addon.srt", source: .addon, matchesPreferredLanguage: true),
            Policy.Candidate(url: "https://example.invalid/open.srt", source: .openSubtitles, matchesPreferredLanguage: true)
        ]
        XCTAssertEqual(resolve(candidates, sources: [.openSubtitles], menu: true), [candidates[1].url])
        XCTAssertEqual(resolve(candidates, sources: [.addon], menu: true), [candidates[0].url])
        XCTAssertTrue(resolve(candidates, sources: [], menu: true).isEmpty)
    }

    func testPreparationIsBoundedPerSourceAndUsesExactURLIdentity() {
        let candidates = [
            Policy.Candidate(url: "https://example.invalid/Sub.srt?token=A", source: .addon, matchesPreferredLanguage: true),
            Policy.Candidate(url: "https://example.invalid/Sub.srt?token=A", source: .addon, matchesPreferredLanguage: true),
            Policy.Candidate(url: "https://example.invalid/sub.srt?token=A", source: .addon, matchesPreferredLanguage: true),
            Policy.Candidate(url: "https://example.invalid/third.srt", source: .addon, matchesPreferredLanguage: true),
            Policy.Candidate(url: "https://example.invalid/Sub.srt?token=B", source: .openSubtitles, matchesPreferredLanguage: true),
            Policy.Candidate(url: "https://example.invalid/fourth.srt", source: .openSubtitles, matchesPreferredLanguage: true),
            Policy.Candidate(url: "https://example.invalid/fifth.srt", source: .openSubtitles, matchesPreferredLanguage: true)
        ]
        XCTAssertEqual(resolve(candidates), [candidates[0].url, candidates[2].url, candidates[4].url, candidates[5].url])
    }

    func testInvalidAndLocalURLsDoNotConsumePreparationSlots() {
        let candidates = ["file:///tmp/a.srt", "magnet:?xt=anything", "https:///", "https://example.invalid/a.srt"]
            .map { Policy.Candidate(url: $0, source: .addon, matchesPreferredLanguage: true) }
        XCTAssertEqual(resolve(candidates), ["https://example.invalid/a.srt"])
    }

    func testResourcePressureSuppressesAutomaticAndMenuPreparation() {
        let candidates = [Policy.Candidate(url: "https://example.invalid/en.srt", source: .addon, matchesPreferredLanguage: true)]
        XCTAssertTrue(resolve(candidates, constrained: true).isEmpty)
        XCTAssertTrue(resolve(candidates, menu: true, constrained: true).isEmpty)
    }
}


@MainActor
final class PlayerSubtitleAppearanceTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "Eclipse.SubtitleAppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testMPVColorsUseAlphaFirstAndPreserveEveryPickerColor() {
        let cases: [(UIColor, String)] = [
            (.white, "#FFFFFFFF"), (.yellow, "#FFFFFF00"), (.cyan, "#FF00FFFF"),
            (.green, "#FF00FF00"), (.magenta, "#FFFF00FF"), (.black, "#FF000000"),
            (.clear, "#00000000"), (.darkGray, "#FF555555"),
            (UIColor.red.withAlphaComponent(0.5), "#7FFF0000")
        ]
        for (color, expected) in cases {
            XCTAssertEqual(PlayerSubtitleAppearance.mpvColor(color), expected)
        }
        XCTAssertEqual(PlayerSubtitleAppearance.mpvASSMarginOverride(for: -24), "")
        XCTAssertEqual(PlayerSubtitleAppearance.mpvASSMarginOverride(for: -6), "")
        XCTAssertEqual(PlayerSubtitleAppearance.mpvASSMarginOverride(for: 6), "MarginV=20")
        XCTAssertEqual(PlayerSubtitleAppearance.mpvASSMarginOverride(for: 18), "MarginV=7")
    }

    func testDefaultAppearancePreservesAuthoredASSAndMatchesSettingsReset() throws {
        try withDefaults { defaults in
            let appearance = PlayerSubtitleAppearance(defaults: defaults)
            XCTAssertFalse(appearance.overridesASSStyles)
            XCTAssertEqual(appearance.fontSize, 30)
            XCTAssertEqual(appearance.strokeWidth, 1)
            XCTAssertEqual(appearance.verticalOffset, -6)
            XCTAssertFalse(appearance.captionBackground)
        }
    }

    func testEveryAppearanceCustomizationCanOverrideASS() throws {
        try withDefaults { defaults in
            for (key, value) in [
                ("subtitles_strokeWidth", 0.0),
                ("subtitles_strokeWidth", 0.5),
                ("subtitles_strokeWidth", 1.5),
                ("subtitles_strokeWidth", 2.0),
                ("subtitles_fontSize", 20.0),
                ("subtitles_fontSize", 46.0),
                ("playerSubtitleOverlayBottomConstant", -24.0),
                ("playerSubtitleOverlayBottomConstant", 18.0)
            ] {
                defaults.set(value, forKey: key)
                XCTAssertTrue(PlayerSubtitleAppearance(defaults: defaults).overridesASSStyles, "\(key)=\(value)")
                defaults.removeObject(forKey: key)
            }
            for key in ["subtitles_foregroundColor", "subtitles_strokeColor"] {
                defaults.set(try NSKeyedArchiver.archivedData(withRootObject: UIColor.cyan, requiringSecureCoding: false), forKey: key)
                XCTAssertTrue(PlayerSubtitleAppearance(defaults: defaults).overridesASSStyles)
                defaults.removeObject(forKey: key)
            }
            defaults.set(true, forKey: "subtitles_closedCaptionBackground")
            XCTAssertTrue(PlayerSubtitleAppearance(defaults: defaults).overridesASSStyles)
        }
    }

    func testEveryVerticalPresetMovesInTheSameDirectionWithoutClippingMPV() throws {
        try withDefaults { defaults in
            let offsets: [CGFloat] = [-24, -16, -6, 6, 18]
            var previousMPVInset = CGFloat.infinity
            var previousOverlayPosition = -CGFloat.infinity
            for offset in offsets {
                defaults.set(Double(offset), forKey: "playerSubtitleOverlayBottomConstant")
                let appearance = PlayerSubtitleAppearance(defaults: defaults)
                let position = PlayerSubtitleAppearance.mpvPosition(for: offset)
                let margin = PlayerSubtitleAppearance.mpvMargin(for: offset)
                let inset = (100 - position) * 7.2 + margin
                XCTAssertLessThanOrEqual(position, 100)
                XCTAssertGreaterThanOrEqual(margin, 0)
                XCTAssertLessThan(inset, previousMPVInset)
                XCTAssertGreaterThan(appearance.overlayBottomConstant, previousOverlayPosition)
                previousMPVInset = inset
                previousOverlayPosition = appearance.overlayBottomConstant
            }
        }
    }

    func testLegacyOffsetAndInvalidNumbersRemainBounded() throws {
        try withDefaults { defaults in
            defaults.set(-16.0, forKey: "vlcSubtitleOverlayBottomConstant")
            XCTAssertEqual(PlayerSubtitleAppearance(defaults: defaults).verticalOffset, -16)
            defaults.set(18.0, forKey: "playerSubtitleOverlayBottomConstant")
            XCTAssertEqual(PlayerSubtitleAppearance(defaults: defaults).verticalOffset, 18)
            defaults.set(Double.infinity, forKey: "subtitles_strokeWidth")
            defaults.set(Double.nan, forKey: "subtitles_fontSize")
            let appearance = PlayerSubtitleAppearance(defaults: defaults)
            XCTAssertEqual(appearance.strokeWidth, 1)
            XCTAssertEqual(appearance.fontSize, 30)
            XCTAssertEqual(PlayerSubtitleAppearance.mpvPosition(for: .nan), 100)
            XCTAssertEqual(PlayerSubtitleAppearance.mpvMargin(for: .infinity), 34)
        }
    }

    func testExternalTextUsesPixelStrokeWidthAndKeepsStrokeWithCaptionBackground() throws {
        try withDefaults { defaults in
            for size in [20.0, 24, 30, 34, 38, 42, 46] {
                defaults.set(size, forKey: "subtitles_fontSize")
                for background in [false, true] {
                    defaults.set(background, forKey: "subtitles_closedCaptionBackground")
                    for width in [0.0, 0.5, 1, 1.5, 2] {
                        defaults.set(width, forKey: "subtitles_strokeWidth")
                        let text = PlayerSubtitleAppearance(defaults: defaults).attributedText("Subtitle")
                        let attributes = text.attributes(at: 0, effectiveRange: nil)
                        let stroke = try XCTUnwrap(attributes[.strokeWidth] as? CGFloat)
                        let font = try XCTUnwrap(attributes[.font] as? UIFont)
                        XCTAssertEqual(font.pointSize, size)
                        XCTAssertEqual(-stroke / 100 * font.pointSize, width, accuracy: 0.0001)
                    }
                }
            }
        }
    }

    func testNativeAVPlayerReceivesSupportedAppearanceAndOutlineOff() throws {
        try withDefaults { defaults in
            defaults.set(46.0, forKey: "subtitles_fontSize")
            defaults.set(0.0, forKey: "subtitles_strokeWidth")
            defaults.set(true, forKey: "subtitles_closedCaptionBackground")
            let appearance = PlayerSubtitleAppearance(defaults: defaults)
            let rule = try XCTUnwrap(appearance.avTextStyleRules.first)
            let attributes = rule.textMarkupAttributes
            XCTAssertEqual(attributes[kCMTextMarkupAttribute_RelativeFontSize as String] as? CGFloat, 46.0 / 30 * 100)
            XCTAssertEqual(attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] as? String, kCMTextMarkupCharacterEdgeStyle_None as String)
            let background = try XCTUnwrap(attributes[kCMTextMarkupAttribute_BackgroundColorARGB as String] as? [Double])
            XCTAssertEqual(background, [0.75, 0, 0, 0])
            defaults.set(2.0, forKey: "subtitles_strokeWidth")
            let outlined = try XCTUnwrap(PlayerSubtitleAppearance(defaults: defaults).avTextStyleRules.first)
            XCTAssertEqual(outlined.textMarkupAttributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] as? String, kCMTextMarkupCharacterEdgeStyle_Uniform as String)
        }
    }

    func testRenderedExternalSubtitleOutlineGrowsAndRemainsVisibleOverCaptionBackground() throws {
        try withDefaults { defaults in
            defaults.set(try NSKeyedArchiver.archivedData(withRootObject: UIColor.green, requiringSecureCoding: false), forKey: "subtitles_foregroundColor")
            defaults.set(try NSKeyedArchiver.archivedData(withRootObject: UIColor.red, requiringSecureCoding: false), forKey: "subtitles_strokeColor")
            for size in [20.0, 46.0] {
                defaults.set(size, forKey: "subtitles_fontSize")
                for background in [false, true] {
                    defaults.set(background, forKey: "subtitles_closedCaptionBackground")
                    var previousOutlinePixels = -1
                    for stroke in [0.0, 0.5, 1.0, 2.0] {
                        defaults.set(stroke, forKey: "subtitles_strokeWidth")
                        let appearance = PlayerSubtitleAppearance(defaults: defaults)
                        let label = UILabel(frame: CGRect(x: 0, y: 0, width: 280, height: 90))
                        label.textAlignment = .center
                        label.backgroundColor = appearance.captionBackground ? UIColor.black.withAlphaComponent(0.72) : .white
                        label.attributedText = appearance.attributedText("Stroke")
                        let format = UIGraphicsImageRendererFormat()
                        format.scale = 2
                        let image = UIGraphicsImageRenderer(size: label.bounds.size, format: format).image { context in
                            label.layer.render(in: context.cgContext)
                        }
                        let cgImage = try XCTUnwrap(image.cgImage)
                        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
                        let bitmap = try XCTUnwrap(CGContext(
                            data: &pixels,
                            width: cgImage.width,
                            height: cgImage.height,
                            bitsPerComponent: 8,
                            bytesPerRow: cgImage.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                        ))
                        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
                        var outlinePixels = 0
                        for pixel in stride(from: 0, to: pixels.count, by: 4) {
                            let red = Int(pixels[pixel])
                            let green = Int(pixels[pixel + 1])
                            let blue = Int(pixels[pixel + 2])
                            if red > 80, red > green * 2, blue < 80 {
                                outlinePixels += 1
                            }
                        }
                        if stroke == 0 { XCTAssertEqual(outlinePixels, 0) }
                        XCTAssertGreaterThan(outlinePixels, previousOutlinePixels, "size=\(size) stroke=\(stroke) background=\(background)")
                        previousOutlinePixels = outlinePixels
                        if size == 46, stroke == 2 {
                            let attachment = XCTAttachment(image: image)
                            attachment.name = "Subtitle outline captionBackground=\(background)"
                            attachment.lifetime = .keepAlways
                            add(attachment)
                        }
                    }
                }
            }
        }
    }
}
