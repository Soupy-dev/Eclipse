import XCTest
#if os(macOS)
@testable import EclipseMac
#else
@testable import Eclipse
#endif

#if os(iOS)
final class MangayomiMediaRuntimeTests: XCTestCase {
    func testReleaseAudioSurvivesTitleEpisodeAndStreamReferences() throws {
        let source = fixtureSource(language: 0)
        let data = try JSONSerialization.data(withJSONObject: ["list": [
            ["name": "Naruto (English Dub)", "link": "/naruto-dub"],
            ["name": "Japanese Folktales", "link": "/folktales"]
        ]])
        let results = try MangayomiMediaAdapter.searchItems(data, source: source)
        let title = try MangayomiMediaKey.decode(XCTUnwrap(results.first).href, source: source.id, kind: "title")
        XCTAssertEqual(title.audio, "English Dub")
        let ordinary = try MangayomiMediaKey.decode(XCTUnwrap(results.last).href, source: source.id, kind: "title")
        XCTAssertNil(ordinary.audio)
        let details = try JSONSerialization.data(withJSONObject: ["episodes": [["name": "Episode 1", "url": "/episode-1"]]])
        let episodes = try MangayomiMediaAdapter.episodes(details, source: source, titleAudio: title.audio)
        let episode = try MangayomiMediaKey.decode(XCTUnwrap(episodes.first).href, source: source.id, kind: "episode")
        XCTAssertEqual(Set((0..<40).compactMap { _ in episode.encoded }).count, 1)
        let streams = try MangayomiMediaAdapter.streamExtraction(
            JSONSerialization.data(withJSONObject: [["url": "https://fixture.invalid/video.m3u8", "quality": "1080p"]]), key: episode
        )
        let row = try XCTUnwrap(streams.sources?.first)
        XCTAssertEqual(row["audio"] as? String, "English Dub")
    }

    func testSplitAudioPreservesIndependentHeadersAndRefusesBrokenTracks() throws {
        let key = MangayomiMediaKey(source: UUID(), kind: "episode", value: "/watch/1", audio: "dub")
        let source: [String: Any] = [
            "url": "https://fixture.invalid/video/index.m3u8", "quality": "1080p",
            "headers": ["Referer": "https://fixture.invalid/"],
            "audios": [["file": "../audio/en.m3u8", "label": "English", "headers": ["Authorization": "fixture"]]],
            "subtitles": [["file": "../subs/en.vtt", "label": "English"]]
        ]
        let parsed = try MangayomiMediaAdapter.streamExtraction(JSONSerialization.data(withJSONObject: [source]), key: key)
        let row = try XCTUnwrap(parsed.sources?.first)
        let audio = try XCTUnwrap((row["externalAudioTracks"] as? [[String: Any]])?.first)
        XCTAssertEqual(audio["url"] as? String, "https://fixture.invalid/audio/en.m3u8")
        XCTAssertEqual(audio["headers"] as? [String: String], ["Authorization": "fixture"])
        XCTAssertEqual(row["headers"] as? [String: String], ["Referer": "https://fixture.invalid/"])
        var broken = source
        broken["audios"] = [["file": "file:///private/audio", "label": "English"]]
        let refused = try? MangayomiMediaAdapter.streamExtraction(JSONSerialization.data(withJSONObject: [broken]), key: key)
        XCTAssertTrue(refused?.sources?.isEmpty ?? true)
    }

    func testRuntimeCancellationBeforeInstallDeliversExactlyOnce() {
        let gate = MangayomiRuntimeCancellation()
        var count = 0
        gate.cancel()
        gate.install { count += 1 }
        gate.cancel()
        XCTAssertEqual(count, 1)
    }

    func testLiveSuppliedAllAnimeRepositorySource() async throws {
        try await verifyLiveSource(id: 558217176)
    }

    func testLiveSuppliedHiAnimeRepositorySource() async throws {
        try await verifyLiveSource(id: 814067600)
    }

    func testLiveSuppliedAnimePaheRepositorySource() async throws {
        try await verifyLiveSource(id: 534387145)
    }

    func testLiveSuppliedKissKHDubRepositorySource() async throws {
        try await verifyLiveSource(id: 614402273, requiredTitle: "Naruto (Dub)")
    }

    private func verifyLiveSource(id: Int64, requiredTitle: String? = nil) async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_RUN_LIVE_MANGAYOMI_TESTS"] == "1" else {
            throw XCTSkip("Live repository checks require explicit opt-in.")
        }
        let repositoryURL = try XCTUnwrap(URL(string: "https://m2k3a.github.io/mangayomi-extensions/anime_index.json"))
        let (index, response) = try await URLSession.shared.data(from: repositoryURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let sources = try MangayomiMediaRepositoryParser.parse(index, repositoryURL: repositoryURL.absoluteString)
        var source = try XCTUnwrap(sources.first(where: { $0.extensionID == id }))
        let scriptURL = try XCTUnwrap(URL(string: source.scriptURL))
        let (bytes, scriptResponse) = try await URLSession.shared.data(from: scriptURL)
        XCTAssertEqual((scriptResponse as? HTTPURLResponse)?.statusCode, 200)
        let script = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        source.scriptDigest = MangayomiMediaManager.digest(bytes)
        let owner = UUID()
        func run(_ operation: String, _ arguments: [String: Any]) async throws -> Data {
            try await MangayomiMediaRuntime.execute(
                source: source, script: script, operation: operation, arguments: arguments,
                preferences: [:], profileID: owner, sharesServices: false
            )
        }
        _ = try await run("validate", [:])
        let search = try MangayomiMediaAdapter.searchItems(try await run("search", ["query": "Naruto", "page": 1]), source: source)
        let selected: SearchItem
        if let requiredTitle {
            selected = try XCTUnwrap(search.first(where: { $0.title.caseInsensitiveCompare(requiredTitle) == .orderedSame }))
            XCTAssertTrue(selected.title.lowercased().contains("dub"))
        } else {
            selected = try XCTUnwrap(search.first(where: { $0.title.lowercased() == "naruto" }) ?? search.first)
        }
        print("Mangayomi live stage=search source=\(source.name) rows=\(search.count) dubEvidence=\(selected.title.lowercased().contains("dub"))")
        let title = try XCTUnwrap(try MangayomiMediaKey.decode(selected.href, source: source.id, kind: "title"))
        let episodes = try MangayomiMediaAdapter.episodes(try await run("detail", ["url": title.value]), source: source, titleAudio: title.audio)
        let episode = try XCTUnwrap(episodes.first(where: { $0.number == 1 }))
        let key = try XCTUnwrap(try MangayomiMediaKey.decode(episode.href, source: source.id, kind: "episode"))
        XCTAssertEqual(episode.number, 1)
        print("Mangayomi live stage=detail source=\(source.name) episodes=\(episodes.count) exactEpisode=\(episode.number)")
        let extraction = try MangayomiMediaAdapter.streamExtraction(try await run("videos", ["url": key.value]), key: key)
        XCTAssertFalse(extraction.sources?.isEmpty ?? true, "No playable HTTP streams from \(source.name)")
        print("Mangayomi live source=\(source.name) search=\(search.count) episodes=\(episodes.count) streams=\(extraction.sources?.count ?? 0)")
    }

    func testDartSourceRunsWithPreferencesDOMAndTypedVideoTracks() async throws {
        let script = #"""
        import 'package:mangayomi/bridge_lib.dart';
        class Fixture extends MProvider {
          MSource source;
          Fixture(this.source);
          List<dynamic> getSourcePreferences() => [ListPreference(key:'audio',title:'Audio',valueIndex:0,entries:['Sub','Dub'],entryValues:['sub','dub'])];
          List<dynamic> getFilterList() => [];
          Future<MPages> search(String query,int page,FilterList filters) async {
            final doc=parseHtml('<article><a href="/alpha" title="Alpha">Alpha</a></article>');
            final manga=MManga();
            manga.name='${doc.xpathFirst('//a/@title')} ${getPreferenceValue(source.id,"audio")}';
            manga.link=doc.selectFirst('article:has(a) a').getHref;
            if (parseHtml('<a title="Alpha"></a><a title="Beta"></a>').xpath('//a/@title').length != 2) throw 'xpath list failed';
            return MPages([manga],false);
          }
          Future<MManga> getDetail(String url) async => MManga(name:'Alpha',chapters:[MChapter(name:'Episode 1',url:'/watch/1')]);
          Future<List<MVideo>> getVideoList(String url) async => [MVideo('https://fixture.invalid/video.m3u8','Dub',url,headers:{'Referer':'https://fixture.invalid/'},subtitles:[MTrack(file:'https://fixture.invalid/en.vtt',label:'English')],audios:[MTrack(file:'https://fixture.invalid/audio.m3u8',label:'English')])];
        }
        Fixture main(MSource source) => Fixture(source);
        """#
        let found = try await execute(script: script, language: 0, operation: "search", preferences: ["audio": "dub"])
        let page = try XCTUnwrap(try JSONSerialization.jsonObject(with: found) as? [String: Any])
        let rows = try XCTUnwrap(page["list"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["name"] as? String, "Alpha dub")
        XCTAssertEqual(rows.first?["link"] as? String, "/alpha")
        let data = try await execute(script: script, language: 0, operation: "videos")
        let videos = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(videos.first?["headers"] as? [String: String], ["Referer": "https://fixture.invalid/"])
        XCTAssertEqual((videos.first?["subtitles"] as? [[String: Any]])?.first?["label"] as? String, "English")
        XCTAssertEqual((videos.first?["audios"] as? [[String: Any]])?.first?["file"] as? String, "https://fixture.invalid/audio.m3u8")
    }

    func testJavaScriptTopLevelSourceAndDOMKeepUpstreamSemantics() async throws {
        let script = #"""
        const capturedBaseURL = new MProvider().source.baseUrl;
        class DefaultExtension extends MProvider {
            getSourcePreferences() { return [{key:'audio',listPreference:{valueIndex:0,entries:['Sub','Dub'],entryValues:['sub','dub']}}]; }
            async search() {
                const doc = new Document('<article><a href="/alpha" title="Alpha">Alpha</a></article>');
                const missing = doc.selectFirst('.missing').text;
                if (new Document('<a title="Alpha"></a><a title="Beta"></a>').xpath('//a/@title').length !== 2) throw new Error('xpath list failed');
                return {list:[{name:doc.xpathFirst('//a/@title')+' '+new SharedPreferences().get('audio'),link:capturedBaseURL+doc.selectFirst('article:has(a) a').getHref,imageUrl:missing}],hasNextPage:false};
            }
            async getDetail() { return {chapters:[]}; }
            async getVideoList() { return []; }
        }
        """#
        let data = try await execute(script: script, language: 1, operation: "search", preferences: ["audio": "dub"])
        let page = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(page["list"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["name"] as? String, "Alpha dub")
        XCTAssertEqual(rows.first?["link"] as? String, "https://fixture.invalid/alpha")
        XCTAssertEqual(rows.first?["imageUrl"] as? String, "")
    }

    func testBothLanguagesUseNativeHTTPAdmission() async throws {
        let dart = #"""
        import 'package:mangayomi/bridge_lib.dart';
        class Fixture extends MProvider {
          Fixture();
          List<dynamic> getSourcePreferences() => [];
          Future<List<MVideo>> getVideoList(String url) async {
            try { await Client().get(Uri.parse('fixture:invalid')); }
            catch (error) { return [MVideo('https://fixture.invalid/blocked.mp4','blocked','')]; }
            throw 'invalid URL unexpectedly allowed';
          }
        }
        Fixture main(MSource source) => Fixture();
        """#
        let javascript = #"""
        class DefaultExtension extends MProvider {
          async getVideoList() {
            try { await new Client().get('fixture:invalid'); }
            catch(error) { return [{url:'https://fixture.invalid/blocked.mp4',quality:'blocked'}]; }
            throw new Error('invalid URL unexpectedly allowed');
          }
        }
        """#
        for (language, script) in [(0, dart), (1, javascript)] {
            let data = try await execute(script: script, language: language, operation: "videos")
            let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            XCTAssertEqual(rows.first?["quality"] as? String, "blocked")
        }
    }

    func testExternalAudioManifestFormatsAndEscaping() throws {
        let video = try XCTUnwrap(URL(string: "https://video.example/video.m3u8?token=" + String(repeating: "x", count: 1200)))
        let audio = try XCTUnwrap(URL(string: "https://audio.example/audio.m3u8?token=" + String(repeating: "y", count: 1200)))
        let tracks = [
            PlaybackExternalAudioTrack(url: audio, label: "Japanese"),
            PlaybackExternalAudioTrack(url: audio, label: "English\"\n#EXT-X-KEY:bad")
        ]
        let hls = PlaybackExternalAudioTransport.hlsManifest(video: video, tracks: tracks, preferredLanguage: "eng")
        XCTAssertTrue(hls.contains(video.absoluteString))
        XCTAssertTrue(hls.contains(audio.absoluteString))
        XCTAssertTrue(hls.contains("DEFAULT=YES"))
        XCTAssertEqual(hls.components(separatedBy: "\n").filter { $0.hasPrefix("#EXT-X-MEDIA:") }.count, 2)
        XCTAssertFalse(hls.contains("\n#EXT-X-KEY:"))
        XCTAssertTrue(PlaybackExternalAudioTransport.usesHLS(video: video, tracks: tracks))
        let raw = try XCTUnwrap(URL(string: "https://video.example/video.mp4"))
        XCTAssertFalse(PlaybackExternalAudioTransport.usesHLS(video: raw, tracks: tracks))
        let hostile = "日本語,;\"\n!new_stream\u{0}"
        XCTAssertEqual(PlaybackExternalAudioTransport.edlValue(hostile), "%\(hostile.utf8.count)%\(hostile)")
        let edl = PlaybackExternalAudioTransport.edlManifest(video: raw, tracks: [PlaybackExternalAudioTrack(url: audio, label: hostile)])
        XCTAssertTrue(edl.hasPrefix("# mpv EDL v0\n%\(raw.absoluteString.utf8.count)%\(raw.absoluteString)\n!new_stream\n"))
        XCTAssertTrue(edl.contains("!track_meta,title=%\(hostile.utf8.count)%\(hostile)\n"))
    }

    func testExternalAudioTransportOwnsHeaderIsolatedChildrenAndManifest() async throws {
        let video = try XCTUnwrap(URL(string: "https://video.example/video.mp4"))
        let audio = try XCTUnwrap(URL(string: "https://audio.example/audio.m4a"))
        let request = PlaybackRequest(
            url: video, headers: ["Authorization": "video-fixture"],
            externalAudioTracks: [PlaybackExternalAudioTrack(url: audio, label: "English", headers: ["Authorization": "audio-fixture"])],
            mediaSelectionIntent: .init(preferredAudioLanguage: "eng", preferredSubtitleLanguage: nil, subtitlesEnabled: false)
        )
        let prepared = try PlaybackExternalAudioTransport.prepare(request)
        let owner = try XCTUnwrap(prepared.launchContext?.ephemeralProxyOwnership)
        let lease = try XCTUnwrap(owner.acquireLease())
        defer { lease.release() }
        XCTAssertTrue(prepared.headers.isEmpty)
        XCTAssertTrue(prepared.externalAudioTracks.isEmpty)
        XCTAssertTrue(PlaybackExternalAudioTransport.requiresMPV(prepared.url))
        XCTAssertEqual(prepared.launchContext?.streamURL, video.absoluteString)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: prepared.url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let master = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(master.hasPrefix("# mpv EDL v0\n"))
        let references = master.components(separatedBy: "\n").compactMap { line -> URL? in
            guard line.hasPrefix("%"), let delimiter = line.dropFirst().firstIndex(of: "%") else { return nil }
            let value = String(line[line.index(after: delimiter)...])
            guard let length = Int(line[line.index(after: line.startIndex)..<delimiter]), length == value.utf8.count else { return nil }
            return URL(string: value)
        }
        XCTAssertEqual(references.count, 2)
        let videoProxy = try XCTUnwrap(references.first)
        let audioProxy = try XCTUnwrap(references.dropFirst().first)
        let proxy = MPVHeaderProxy.shared
        XCTAssertEqual(proxy.upstreamProbeTarget(for: videoProxy)?.url, video)
        XCTAssertEqual(proxy.upstreamProbeTarget(for: audioProxy)?.url, audio)
        XCTAssertEqual(proxy.upstreamProbeTarget(for: videoProxy)?.headers["Authorization"], "video-fixture")
        XCTAssertEqual(proxy.upstreamProbeTarget(for: audioProxy)?.headers["Authorization"], "audio-fixture")
        lease.release()
        XCTAssertNil(proxy.originalTargetURL(for: prepared.url))
        XCTAssertNil(proxy.originalTargetURL(for: videoProxy))
        XCTAssertNil(proxy.originalTargetURL(for: audioProxy))
    }

    func testExternalAudioRawTransportRequiresMPVAndRefusesPrivateSources() throws {
        let video = try XCTUnwrap(URL(string: "https://video.example/video.mp4"))
        let audio = try XCTUnwrap(URL(string: "https://audio.example/audio.m4a"))
        let prepared = try PlaybackExternalAudioTransport.prepare(PlaybackRequest(
            url: video, externalAudioTracks: [PlaybackExternalAudioTrack(url: audio, label: "English")]
        ))
        defer { prepared.launchContext?.ephemeralProxyOwnership?.invalidate() }
        XCTAssertTrue(PlaybackExternalAudioTransport.requiresMPV(prepared.url))
        XCTAssertFalse(PlaybackExternalAudioTransport.mpvReason.isEmpty)
        let privateAudio = try XCTUnwrap(URL(string: "http://127.0.0.1/audio.m4a"))
        XCTAssertThrowsError(try PlaybackExternalAudioTransport.prepare(PlaybackRequest(
            url: video, externalAudioTracks: [PlaybackExternalAudioTrack(url: privateAudio, label: "English")]
        )))
    }

    func testExternalAudioOwnedSessionsSurviveProxyCapacityPressure() throws {
        let proxy = MPVHeaderProxy.testingInstance()
        defer { proxy.shutdownForTesting() }
        let target = try XCTUnwrap(URL(string: "https://audio.example/audio.m4a"))
        let owned = try XCTUnwrap(proxy.makeProxyURL(for: target, headers: [:], requiresPublicHTTP: true))
        let owner = PlaybackProxySessionOwnership(proxyURLs: [owned]) { proxy.invalidateSession(for: $0) }
        let lease = try XCTUnwrap(owner.acquireLease())
        defer { lease.release() }
        for _ in 0..<205 {
            XCTAssertNotNil(proxy.makeProxyURL(for: target, headers: [:]))
        }
        XCTAssertEqual(proxy.originalTargetURL(for: owned), target)
        lease.release()
        XCTAssertNil(proxy.originalTargetURL(for: owned))
    }

    private func fixtureSource(language: Int) -> MangayomiMediaSource {
        MangayomiMediaSource(
            id: UUID(), repositoryURL: "https://fixture.invalid/anime_index.json", extensionID: 42,
            name: "Fixture", baseURL: "https://fixture.invalid", apiURL: "", language: "en", version: "1.0",
            scriptURL: "https://fixture.invalid/source", iconURL: "", scriptLanguage: language, isNSFW: false,
            metadataJSON: #"{"id":42,"name":"Fixture","baseUrl":"https://fixture.invalid","lang":"en"}"#,
            enabled: true, scriptDigest: nil
        )
    }

    func testMangayomiPlaybackIdentityRestrictsSharedCookieUseEvenForMalformedKeys() throws {
        let source = UUID()
        let key = try XCTUnwrap(MangayomiMediaKey(source: source, kind: "title", value: "/show").encoded)
        let url = try XCTUnwrap(URL(string: "https://fixture.invalid/video.mp4"))
        func request(href: String, kind: PlaybackSourceKind = .service) -> PlaybackRequest {
            PlaybackRequest(url: url, launchContext: .init(
                sourceId: "service:\(source.uuidString)", sourceName: "Fixture", sourceKind: kind,
                autoMode: false, streamURL: url.absoluteString, headers: [:], subtitles: [],
                subtitleNames: nil, retryCount: 0, serviceContentHref: href
            ))
        }
        XCTAssertTrue(request(href: key).usesMangayomiSource)
        XCTAssertTrue(request(href: "  MANGAYOMI:invalid").usesMangayomiSource)
        XCTAssertTrue(request(href: "mangayomi:" + String(repeating: "x", count: 10000)).usesMangayomiSource)
        XCTAssertFalse(request(href: "https://fixture.invalid/mangayomi:ordinary").usesMangayomiSource)
        XCTAssertFalse(request(href: key, kind: .stremio).usesMangayomiSource)
    }

    private func execute(script: String, language: Int, operation: String, preferences: [String: Any] = [:]) async throws -> Data {
        let source = fixtureSource(language: language)
        return try await MangayomiMediaRuntime.execute(
            source: source, script: script, operation: operation, arguments: ["query": "Alpha", "url": "/watch/1"],
            preferences: preferences, profileID: UUID(), sharesServices: false
        )
    }
}
#endif
