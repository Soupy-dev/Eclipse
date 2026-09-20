import XCTest
import Libmpv
@testable import Eclipse

#if os(iOS)
import UIKit
import AVFoundation
import Darwin
import Network
import UniformTypeIdentifiers

@MainActor
final class V221RendererLifecycleTests: XCTestCase {
    func testAVPlayerDecodesGeneratedHLSMasterWithExternalAudioTracks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoSegments = ExternalAudioSegmentFixture()
        let audioSegments = ExternalAudioSegmentFixture()
        try await Task.detached(priority: .utility) {
            try Self.makeVideo(at: directory.appendingPathComponent("unused.mov"), frameCount: 240,
                               width: 160, height: 90, segmentDelegate: videoSegments)
            let audio = directory.appendingPathComponent("audio.wav")
            try Self.makeSilentAudio(at: audio)
            try Self.makeSegmentedAudio(at: audio, delegate: audioSegments)
        }.value
        var resources = videoSegments.resources(prefix: "/video")
            .merging(audioSegments.resources(prefix: "/japanese")) { first, _ in first }
            .merging(audioSegments.resources(prefix: "/english")) { first, _ in first }
        resources["/master.m3u8"] = Data((
            "#EXTM3U\n#EXT-X-VERSION:7\n" +
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"original\",NAME=\"Japanese\",LANGUAGE=\"ja\",DEFAULT=YES,AUTOSELECT=YES,URI=\"japanese/index.m3u8\"\n" +
            "#EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO=\"original\"\nvideo/index.m3u8\n"
        ).utf8)
        let fixture = try ExternalAudioHTTPFixture(resources: resources)
        fixture.start()
        defer { fixture.stop() }
        try await waitForPiPFixture("HLS audio fixture listener", timeout: 3) { fixture.port != nil }
        let port = try XCTUnwrap(fixture.port)
        let video = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/video/index.m3u8"))
        let japanese = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/japanese/index.m3u8"))
        let english = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/english/index.m3u8"))
        let upstreamMaster = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/master.m3u8"))
        let videoProxy = try XCTUnwrap(MPVHeaderProxy.shared.makeProxyURL(for: upstreamMaster, headers: [:]))
        defer { MPVHeaderProxy.shared.invalidateSession(for: videoProxy) }
        let manifest = PlaybackExternalAudioTransport.hlsManifest(video: videoProxy, tracks: [
            .init(url: english, label: "English")
        ], preferredLanguage: "eng")
        let (upstreamBytes, _) = try await URLSession.shared.data(from: videoProxy)
        let expectedManifest = try PlaybackExternalAudioTransport.mergedHLSMaster(
            String(decoding: upstreamBytes, as: UTF8.self), externalManifest: manifest, preferredLanguage: "eng"
        )
        let compound = try XCTUnwrap(MPVHeaderProxy.shared.makeLocalManifestURL(
            body: Data(manifest.utf8), contentType: "application/vnd.apple.mpegurl", fileExtension: "m3u8",
            compositeVideoURL: videoProxy, compositePreferredLanguage: "eng"
        ))
        defer { MPVHeaderProxy.shared.invalidateSession(for: compound) }
        try await verifyExternalAudioManifest(compound, expected: expectedManifest)
        try await verifyExternalAudioResource(video)
        try await verifyExternalAudioResource(japanese)
        try await verifyExternalAudioResource(english)
        let player = AVPlayer(url: compound)
        player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        player.play()
        do {
            try await waitForPiPFixture("AVPlayer HLS composite clock", timeout: 15) {
                player.currentItem?.status == .readyToPlay && player.currentTime().seconds > 0.4
            }
        } catch {
            let item = player.currentItem
            let errors = item?.errorLog()?.events.map {
                "domain=\($0.errorDomain) code=\($0.errorStatusCode) detail=\($0.errorComment ?? "nil")"
            }.joined(separator: " | ") ?? "none"
            let accesses = item?.accessLog()?.events.map {
                "bytes=\($0.numberOfBytesTransferred) stalls=\($0.numberOfStalls) duration=\($0.durationWatched)"
            }.joined(separator: " | ") ?? "none"
            print("ExternalAudioFixture AV status=\(item?.status.rawValue ?? -1) timeControl=\(player.timeControlStatus.rawValue) waiting=\(player.reasonForWaitingToPlay?.rawValue ?? "nil") itemError=\(String(describing: item?.error)) errors=[\(errors)] access=[\(accesses)] requests=[\(fixture.requestSummary)]")
            throw error
        }
        let item = try XCTUnwrap(player.currentItem)
        let group = try XCTUnwrap(item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible))
        XCTAssertEqual(group.options.count, 2)
        print("ExternalAudioFixture AV audio options=\(group.options.map { "name=\($0.displayName) language=\($0.extendedLanguageTag ?? $0.locale?.languageCode ?? "nil")" })")
        let englishIndex = try XCTUnwrap(PlaybackLanguageSelectionPolicy.preferredIndex(in: group.options.map {
            .init(languageTag: $0.extendedLanguageTag ?? $0.locale?.languageCode, displayName: $0.displayName)
        }, preferredLanguage: "en"))
        let selected = group.options[englishIndex]
        item.select(selected, in: group)
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: group), selected)
        let position = player.currentTime().seconds
        try await waitForPiPFixture("AVPlayer selected external English audio progresses", timeout: 4) {
            player.currentTime().seconds > position + 0.4
        }
    }

    func testExternalAudioHLSMasterRetainsUpstreamAudioAndSubtitles() throws {
        let upstream = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="original",NAME="Japanese",LANGUAGE="ja",DEFAULT=YES,AUTOSELECT=YES,URI="https://example.com/japanese.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English subtitles",URI="https://example.com/subtitles.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,CODECS="avc1.640028,mp4a.40.2",AUDIO="original",SUBTITLES="subs",RESOLUTION=1920x1080
        https://example.com/video.m3u8
        """
        let external = PlaybackExternalAudioTransport.hlsManifest(
            video: try XCTUnwrap(URL(string: "https://example.com/master.m3u8")),
            tracks: [.init(url: try XCTUnwrap(URL(string: "https://example.com/english.m3u8")), label: "English")],
            preferredLanguage: "eng"
        )
        XCTAssertTrue(external.contains("LANGUAGE=\"en\""))
        let result = try PlaybackExternalAudioTransport.mergedHLSMaster(upstream, externalManifest: external, preferredLanguage: "en")
        XCTAssertTrue(result.contains("https://example.com/japanese.m3u8"))
        XCTAssertTrue(result.contains("https://example.com/english.m3u8"))
        XCTAssertTrue(result.contains("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"English subtitles\",URI=\"https://example.com/subtitles.m3u8\""))
        XCTAssertTrue(result.contains("SUBTITLES=\"subs\",RESOLUTION=1920x1080,AUDIO=\"original\""))
        XCTAssertFalse(result.contains("CODECS="))
        let audio = result.components(separatedBy: .newlines).filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }
        XCTAssertEqual(audio.count, 2)
        XCTAssertEqual(audio.filter { $0.contains("DEFAULT=YES") }.count, 1)
        XCTAssertTrue(audio.contains { $0.contains("LANGUAGE=\"en\"") && $0.contains("DEFAULT=YES") })
        let japanesePreferred = try PlaybackExternalAudioTransport.mergedHLSMaster(upstream, externalManifest: external, preferredLanguage: "ja")
        XCTAssertTrue(japanesePreferred.components(separatedBy: .newlines).contains { $0.contains("LANGUAGE=\"ja\"") && $0.contains("DEFAULT=YES") })
        let muxed = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,CODECS=\"avc1.640028,mp4a.40.2\"\nhttps://example.com/muxed.m3u8\n"
        let muxedResult = try PlaybackExternalAudioTransport.mergedHLSMaster(muxed, externalManifest: external, preferredLanguage: "en")
        let original = try XCTUnwrap(muxedResult.components(separatedBy: .newlines).first { $0.contains("NAME=\"Original audio\"") })
        XCTAssertFalse(original.contains("URI="))
        XCTAssertTrue(original.contains("DEFAULT=NO"))
        let unknown = muxed.replacingOccurrences(of: ",CODECS=\"avc1.640028,mp4a.40.2\"", with: "")
        XCTAssertFalse(try PlaybackExternalAudioTransport.mergedHLSMaster(unknown, externalManifest: external).contains("Original audio"))
        let leaf = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n"
        XCTAssertEqual(try PlaybackExternalAudioTransport.mergedHLSMaster(leaf, externalManifest: external), external)
        XCTAssertThrowsError(try PlaybackExternalAudioTransport.mergedHLSMaster("<html>challenge</html>", externalManifest: external))
    }

    nonisolated private static func makeSilentAudio(at url: URL, duration: Int = 8) throws {
        let frameCount = 44100 * duration
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let samples = buffer.int16ChannelData?[0] else { throw URLError(.cannotCreateFile) }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        memset(samples, 0, frameCount * 2)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: buffer)
    }

    nonisolated private static func makeSegmentedAudio(at url: URL, delegate: AVAssetWriterDelegate) throws {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw URLError(.cannotDecodeContentData) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.delegate = delegate
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 2, preferredTimescale: 44100)
        writer.initialSegmentStartTime = .zero
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000
        ])
        guard writer.canAdd(input) else { throw URLError(.cannotCreateFile) }
        writer.add(input)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? URLError(.cannotCreateFile) }
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(20)
        while let sample = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard input.isReadyForMoreMediaData, input.append(sample) else { throw writer.error ?? URLError(.cannotWriteToFile) }
        }
        guard reader.status == .completed else { throw reader.error ?? URLError(.cannotDecodeContentData) }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 20) == .success, writer.status == .completed else {
            throw writer.error ?? URLError(.cannotWriteToFile)
        }
    }

    func testGPUBridgeDecodesGeneratedEDLWithExternalAudioTracks() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
            try? FileManager.default.removeItem(at: directory)
        }
        let video = directory.appendingPathComponent("video.mov")
        let audio = directory.appendingPathComponent("audio.wav")
        try await Task.detached(priority: .utility) {
            try Self.makeVideo(at: video, frameCount: 600, width: 160, height: 90)
            try Self.makeSilentAudio(at: audio, duration: 20)
        }.value
        let fixture = try ExternalAudioHTTPFixture(resources: [
            "/video.mov": Data(contentsOf: video),
            "/japanese.wav": Data(contentsOf: audio),
            "/english.wav": Data(contentsOf: audio)
        ])
        fixture.start()
        defer { fixture.stop() }
        try await waitForPiPFixture("external audio fixture listener", timeout: 3) { fixture.port != nil }
        let port = try XCTUnwrap(fixture.port)
        let videoURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/video.mov"))
        let japanese = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/japanese.wav"))
        let english = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/english.wav"))
        let hostileTitle = "日本語,;\"\n!new_stream"
        let manifest = PlaybackExternalAudioTransport.edlManifest(video: videoURL, tracks: [
            .init(url: japanese, label: hostileTitle), .init(url: english, label: "English")
        ])
        let compound = try XCTUnwrap(MPVHeaderProxy.shared.makeLocalManifestURL(
            body: Data(manifest.utf8), contentType: "application/x-mpv-edl", fileExtension: "edl"
        ))
        defer { MPVHeaderProxy.shared.invalidateSession(for: compound) }
        try await verifyExternalAudioManifest(compound, expected: manifest)
        try await verifyExternalAudioResource(videoURL)
        try await verifyExternalAudioResource(japanese)
        try await verifyExternalAudioResource(english)
        let renderer = MPVGPUPlayerBridge(
            pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer(), qualityProfile: .lowHeat(reason: "external-audio-fixture")
        )
        let view = renderer.getRenderingView()
        view.frame = host.view.bounds
        host.view.addSubview(view)
        renderer.renderingLayoutDidChange(containerSize: view.bounds.size)
        defer { renderer.stop(); view.removeFromSuperview() }
        try renderer.start()
        renderer.load(url: compound, with: PlayerPreset(
            id: .sdrRec709, title: "External audio fixture", summary: "", stream: nil,
            commands: [["set", "hwdec", "no"], ["set", "hwdec-software-fallback", "yes"]]
        ), headers: nil)
        do {
            try await waitForPiPFixture("EDL video and two audio tracks", timeout: 15) {
                renderer.getAudioTracksDetailed().count == 2 && self.playbackTime(renderer) > 0.4
            }
            let tracks = renderer.getAudioTracksDetailed()
            XCTAssertEqual(tracks.count, 2)
            XCTAssertTrue(tracks.contains { $0.1.contains(hostileTitle) })
            let englishTrack = try XCTUnwrap(tracks.first(where: { $0.1.contains("English") }))
            renderer.setAudioTrack(id: englishTrack.0)
            try await waitForPiPFixture("selected separate English audio", timeout: 4) {
                renderer.getCurrentAudioTrackId() == englishTrack.0
            }
            let position = playbackTime(renderer)
            try await waitForPiPFixture("composite clock progresses with selected audio", timeout: 12) {
                renderer.getCurrentAudioTrackId() == englishTrack.0 && self.playbackTime(renderer) > position + 0.4
            }
        } catch {
            print("ExternalAudioFixture MPV tracks=\(renderer.getAudioTracksDetailed()) state=\(renderer.pictureInPictureDebugSnapshot()) requests=[\(fixture.requestSummary)]")
            renderer.stop()
            await renderer.waitUntilStopped()
            throw error
        }
        renderer.stop()
        await renderer.waitUntilStopped()
    }

    private func verifyExternalAudioManifest(_ url: URL, expected: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for method in ["HEAD", "GET"] {
            var request = URLRequest(url: url)
            request.httpMethod = method
            let (bytes, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(response.expectedContentLength, Int64(expected.utf8.count))
            XCTAssertEqual(bytes, method == "HEAD" ? Data() : Data(expected.utf8))
        }
        print("ExternalAudioFixture manifest verified bytes=\(expected.utf8.count)")
    }

    private func verifyExternalAudioResource(_ url: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertGreaterThan(bytes.count, 12)
        for (range, expected) in [("bytes=5-12", bytes.subdata(in: 5..<13)), ("bytes=-8", Data(bytes.suffix(8)))] {
            var request = URLRequest(url: url)
            request.setValue(range, forHTTPHeaderField: "Range")
            let (partial, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
            XCTAssertEqual(partial, expected)
        }
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        let (empty, headResponse) = try await session.data(for: head)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(headResponse.expectedContentLength, Int64(bytes.count))
        XCTAssertTrue(empty.isEmpty)
        print("ExternalAudioFixture resource path=\(url.path) bytes=\(bytes.count) ranges=verified")
    }

    func testGPUBridgeSeeksBeyondPrematureNetworkEOF() async throws {
        try await exercisePrematureNetworkEOF(kind: 0)
    }

    func testSampleBufferBridgeSeeksBeyondPrematureNetworkEOF() async throws {
        try await exercisePrematureNetworkEOF(kind: 1)
    }

    private func exercisePrematureNetworkEOF(kind: Int) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
            try? FileManager.default.removeItem(at: directory)
        }
        let fixture = try MPVPrematureEOFFixture()
        defer { fixture.stop() }
        let unusedURL = directory.appendingPathComponent("fixture.mov")
        try await Task.detached(priority: .utility) {
            try Self.makeVideo(at: unusedURL, frameCount: 1200, width: 320, height: 180, segmentDelegate: fixture)
        }.value
        fixture.start()
        try await waitForPiPFixture("HLS listener", timeout: 3) { fixture.port != nil }
        let port = try XCTUnwrap(fixture.port)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/index.m3u8"))
        let subtitleURL = directory.appendingPathComponent("fixture.srt")
        try "1\n00:00:00,000 --> 00:00:39,000\nSeek recovery fixture\n".write(to: subtitleURL, atomically: true, encoding: .utf8)

        for initiallyPaused in [false, true] {
            fixture.resetFailure()
            let layer = AVSampleBufferDisplayLayer()
            let renderer: PlayerRenderer = kind == 0
                ? MPVGPUPlayerBridge(pictureInPictureDisplayLayer: layer, qualityProfile: .lowHeat(reason: "seek-fixture"))
                : MPVSampleBufferPiPBridge(displayLayer: layer, qualityProfile: .lowHeat(reason: "seek-fixture"))
            let view = renderer.getRenderingView()
            view.frame = host.view.bounds
            host.view.addSubview(view)
            renderer.renderingLayoutDidChange(containerSize: view.bounds.size)
            defer {
                renderer.stop()
                view.removeFromSuperview()
            }
            try renderer.start()
            var commands: [[String]] = []
#if targetEnvironment(simulator)
            commands = [["set", "hwdec", "no"], ["set", "hwdec-software-fallback", "yes"]]
#endif
            renderer.load(url: url, with: PlayerPreset(id: .sdrRec709, title: "Seek fixture", summary: "", stream: nil, commands: commands), headers: nil)
            try await waitForPiPFixture("truncated HLS cache", timeout: 12) {
                fixture.rejectedLastSegment && self.playbackTime(renderer) > 0.25
            }
            renderer.loadExternalSubtitles(urls: [subtitleURL.absoluteString], names: ["Fixture"], enforce: true)
            try await waitForPiPFixture("external subtitle", timeout: 5) { renderer.getCurrentSubtitleTrackId() >= 0 }
            let subtitleID = renderer.getCurrentSubtitleTrackId()
            renderer.setSpeed(1.5)
            if initiallyPaused { renderer.pausePlayback() }
            try await Task.sleep(nanoseconds: 200_000_000)
            fixture.restoreUpstream()
            renderer.seek(to: 20)
            try await waitForPiPFixture("fresh segment beyond the failed cache", timeout: 5) { fixture.servedTargetSegment }
            XCTAssertEqual(renderer.isPausedState, initiallyPaused)
            XCTAssertEqual(renderer.getSpeed(), 1.5, accuracy: 0.01)
            XCTAssertEqual(renderer.getCurrentSubtitleTrackId(), subtitleID)
            if initiallyPaused {
                try await Task.sleep(nanoseconds: 200_000_000)
                XCTAssertEqual(playbackTime(renderer), 20, accuracy: 0.25)
                renderer.play()
            }
            try await waitForPiPFixture("playback beyond requested intro endpoint", timeout: 5) { self.playbackTime(renderer) > 20.3 }
            XCTAssertEqual(renderer.getCurrentSubtitleTrackId(), subtitleID)
            renderer.stop()
            await renderer.waitUntilStopped()
            view.removeFromSuperview()
        }
    }

    func testGPUBridgeRepeatedLocalPlaybackSeekResizeAndStop() async throws {
        try await exercise(kind: 0)
    }

    func testSampleBufferBridgeRepeatedLocalPlaybackSeekResizeAndStop() async throws {
        try await exercise(kind: 1)
    }

    func testGPUBridge4KHardwarePlaybackAndRelease() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("4K hardware lifecycle validation requires a physical device")
#else
        guard MPVGPUPlayerBridge.isAvailable else { throw XCTSkip(MPVGPUPlayerBridge.unavailableReason ?? "GPU renderer unavailable") }
        try await exercise(kind: 0, sourceWidth: 3840, sourceHeight: 2160, frameCount: 90, cycles: 8, requiresHardwareDecode: true)
#endif
    }

    func testGPUBridgeSystemPictureInPictureRoundTripRestoresPresentedInlineFrames() async throws {
        guard PiPController.isPictureInPictureSupported else { throw XCTSkip("System picture in picture is unavailable on this device") }
        guard MPVGPUPlayerBridge.isAvailable else { throw XCTSkip(MPVGPUPlayerBridge.unavailableReason ?? "GPU renderer unavailable") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive }))
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let audio = AVAudioSession.sharedInstance()
        let previousCategory = audio.category
        let previousMode = audio.mode
        let previousOptions = audio.categoryOptions
        let previousChannels = audio.preferredOutputNumberOfChannels
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            try? audio.setCategory(previousCategory, mode: previousMode, options: previousOptions)
            if previousChannels > 0 { try? audio.setPreferredOutputNumberOfChannels(previousChannels) }
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("pip-fixture.mov")
        try await Task.detached(priority: .utility) { try Self.makeVideo(at: url, frameCount: 360) }.value
        try audio.setCategory(.playback, mode: .moviePlayback)
        try audio.setActive(true)
        let layer = AVSampleBufferDisplayLayer()
        var renderer: MPVGPUPlayerBridge? = MPVGPUPlayerBridge(pictureInPictureDisplayLayer: layer, qualityProfile: .lowHeat(reason: "pip-runtime-fixture"))
        weak var releasedRenderer = renderer
        let view = try XCTUnwrap(renderer?.getRenderingView())
        view.frame = host.view.bounds
        host.view.addSubview(view)
        layer.frame = host.view.bounds
        layer.videoGravity = .resizeAspect
        host.view.layer.addSublayer(layer)
        host.view.layoutIfNeeded()
        renderer?.renderingLayoutDidChange(containerSize: view.bounds.size)
        let driver = V221PiPFixtureDelegate(renderer: renderer)
        let pip = PiPController(sampleBufferDisplayLayer: layer, playbackLoadGeneration: 1)
        pip.delegate = driver
        var metrics: [[String: String]] = []
        defer {
            pip.invalidateForReplacement()
            driver.cancel()
            renderer?.stop()
            layer.removeFromSuperlayer()
            view.removeFromSuperview()
        }
        do {
            try renderer?.start()
            var commands = [["set", "loop-file", "inf"]]
#if targetEnvironment(simulator)
            commands.append(["set", "hwdec", "no"])
            commands.append(["set", "hwdec-software-fallback", "yes"])
#endif
            renderer?.load(url: url, with: PlayerPreset(id: .sdrRec709, title: "PiP Fixture", summary: "", stream: nil, commands: commands), headers: nil)
            try await waitForPiPFixture("initial local playback", timeout: 12) { (renderer?.currentTime ?? 0) > 0.25 }
            for attempt in 1...2 {
                pip.armTransition(attemptID: attempt)
                driver.arm(controller: pip)
                renderer?.seek(to: 0.5)
                renderer?.play()
                var preparation: Result<Void, Error>?
                let preparing = Task { @MainActor in
                    do {
                        try await renderer?.preparePictureInPicture()
                        preparation = .success(())
                    } catch {
                        preparation = .failure(error)
                    }
                }
                defer { preparing.cancel() }
                try await waitForPiPFixture("frame preparation", timeout: 10) { preparation != nil }
                try preparation?.get()
                XCTAssertTrue(renderer?.isPictureInPicturePrimed() ?? false)
                XCTAssertGreaterThan(try pipFrameCount(renderer), 0)
                renderer?.setPictureInPictureSourcePreparedForAutomaticStart(true)
                try await waitForPiPFixture("system PiP eligibility", timeout: 5) { pip.isPictureInPicturePossible }
                guard renderer?.activatePictureInPictureLayer() == true else { throw fixtureFailure("Native PiP activation failed") }
                pip.updatePlaybackState()
                pip.startPictureInPicture()
                try await waitForPiPFixture("system PiP start callback", timeout: 8) { driver.startedAttempts.contains(attempt) || driver.failedAttempts.contains(attempt) }
                XCTAssertFalse(driver.failedAttempts.contains(attempt))
                XCTAssertTrue(driver.startedAttempts.contains(attempt))
                XCTAssertTrue(pip.isPictureInPictureActive)
                XCTAssertFalse(pip.isPictureInPictureStartPending)
                XCTAssertFalse(driver.activationFailed)
                XCTAssertTrue(driver.didStartWhileSystemActive.allSatisfy { $0 })
                XCTAssertEqual(layer.status, .rendering)
                if #available(iOS 17.4, *) {
                    try await waitForPiPFixture("system PiP first displayed frame", timeout: 4) {
                        pip.isPictureInPictureActive && layer.isReadyForDisplay
                    }
                    XCTAssertTrue(layer.isReadyForDisplay)
                }
                let firstFrame = try pipFrameCount(renderer)
                try await waitForPiPFixture("new sample frames while system PiP is active", timeout: 4) {
                    pip.isPictureInPictureActive && ((try? self.pipFrameCount(renderer)) ?? 0) > firstFrame + 2
                }
                renderer?.pausePlayback()
                try await waitForPiPFixture("PiP pause", timeout: 2) { renderer?.isPausedState == true }
                let pausedPosition = renderer?.currentTime ?? 0
                try await Task.sleep(nanoseconds: 200_000_000)
                XCTAssertLessThan(abs((renderer?.currentTime ?? 0) - pausedPosition), 0.2)
                renderer?.seek(to: 2)
                var seekTimelineReady = false
                let updatingTimeline = Task { @MainActor in
                    await renderer?.waitForPictureInPictureTimelineUpdate()
                    seekTimelineReady = true
                }
                defer { updatingTimeline.cancel() }
                try await waitForPiPFixture("paused PiP seek target and timeline", timeout: 4) {
                    seekTimelineReady && abs((renderer?.currentTime ?? 0) - 2) < 0.25
                }
                renderer?.setSpeed(1.25)
                renderer?.play()
                pip.updatePlaybackState()
                let beforeSeekFrames = try pipFrameCount(renderer)
                try await waitForPiPFixture("new frames after PiP seek and resume", timeout: 4) {
                    pip.isPictureInPictureActive && (renderer?.currentTime ?? 0) > 2.1 && ((try? self.pipFrameCount(renderer)) ?? 0) > beforeSeekFrames + 2
                }
                XCTAssertEqual(renderer?.getSpeed() ?? 0, 1.25, accuracy: 0.01)
                XCTAssertTrue(pip.isPictureInPictureActive)
                XCTAssertNil(layer.error)
                metrics.append(["attempt": String(attempt), "phase": "system-active", "enqueuedFrames": String(try pipFrameCount(renderer)), "diagnostics": renderer?.pictureInPictureDebugSnapshot() ?? "missing", "footprintBytes": String(Self.footprint())])
                pip.stopPictureInPicture(source: "v221-system-roundtrip-fixture")
                try await waitForPiPFixture("system PiP stop and native inline presentation", timeout: 10) { driver.stoppedCount == attempt && driver.restoreResult != nil }
                XCTAssertEqual(driver.restoreResult, true, "Native inline presentation was not proven")
                XCTAssertFalse(pip.isPictureInPictureActive)
                XCTAssertTrue(layer.isHidden)
                let inlinePosition = renderer?.currentTime ?? 0
                try await waitForPiPFixture("inline playback after native presentation", timeout: 3) { (renderer?.currentTime ?? 0) > inlinePosition + 0.15 }
                XCTAssertFalse(renderer?.isPictureInPicturePrimed() ?? true)
                metrics.append(["attempt": String(attempt), "phase": "inline-restored", "restorePresented": String(driver.restoreResult ?? false), "acceptedPlaybackCallbacks": driver.acceptedPlaybackCallbacks.joined(separator: ","), "ignoredPlaybackCallbacks": driver.ignoredPlaybackCallbacks.joined(separator: ","), "diagnostics": renderer?.pictureInPictureDebugSnapshot() ?? "missing", "footprintBytes": String(Self.footprint())])
            }
        } catch {
            metrics.append(["phase": "failure", "error": String(describing: error), "acceptedPlaybackCallbacks": driver.acceptedPlaybackCallbacks.joined(separator: ","), "ignoredPlaybackCallbacks": driver.ignoredPlaybackCallbacks.joined(separator: ","), "systemActive": String(pip.isPictureInPictureActive), "diagnostics": renderer?.pictureInPictureDebugSnapshot() ?? "missing"])
            try? addPiPFixtureAttachment(metrics)
            await stopPiPFixture(pip, driver: driver, renderer: renderer)
            throw error
        }
        await stopPiPFixture(pip, driver: driver, renderer: renderer)
        renderer = nil
        try await waitForPiPFixture("released GPU bridge", timeout: 2) { releasedRenderer == nil }
        try addPiPFixtureAttachment(metrics)
    }

    private func waitForPiPFixture(_ phase: String, timeout: TimeInterval, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard condition() else { throw fixtureFailure("Timed out waiting for \(phase)") }
    }

    private func fixtureFailure(_ message: String) -> Error {
        NSError(domain: "V221PiPFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func pipFrameCount(_ renderer: MPVGPUPlayerBridge?) throws -> Int {
        let snapshot = renderer?.pictureInPictureDebugSnapshot() ?? ""
        let value = snapshot.split(separator: " ").first(where: { $0.hasPrefix("pipFrames=") }).flatMap { Int($0.dropFirst("pipFrames=".count)) }
        return try XCTUnwrap(value, "Missing native enqueued-frame count: \(snapshot)")
    }

    private func addPiPFixtureAttachment(_ metrics: [[String: String]]) throws {
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "System PiP callbacks, sample frame counts and native inline restoration"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func stopPiPFixture(_ pip: PiPController, driver: V221PiPFixtureDelegate, renderer: MPVGPUPlayerBridge?) async {
        await Task { @MainActor in
            pip.stopPictureInPicture(source: "v221-fixture-cleanup")
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while pip.isPictureInPictureActive && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTAssertFalse(pip.isPictureInPictureActive, "System PiP did not stop before cleanup")
            pip.invalidateForReplacement()
            driver.cancel()
            renderer?.stop()
            var stopped = false
            let stopTask = Task { @MainActor in
                await renderer?.waitUntilStopped()
                stopped = true
            }
            let stopDeadline = ProcessInfo.processInfo.systemUptime + 5
            while !stopped && ProcessInfo.processInfo.systemUptime < stopDeadline {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            stopTask.cancel()
            XCTAssertTrue(stopped, "Renderer shutdown exceeded the bounded cleanup deadline")
        }.value
    }

    private func exercise(kind: Int, sourceWidth: Int = 640, sourceHeight: Int = 360, frameCount: Int = 120, cycles: Int = 4, requiresHardwareDecode: Bool = false) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fixture.mov")
        try await Task.detached(priority: .utility) { try Self.makeVideo(at: url, frameCount: frameCount, width: sourceWidth, height: sourceHeight) }.value
        var metrics: [[String: String]] = []
        for iteration in 0..<cycles {
            let layer = AVSampleBufferDisplayLayer()
            var renderer: PlayerRenderer?
            switch kind {
            case 0:
                renderer = MPVGPUPlayerBridge(pictureInPictureDisplayLayer: layer, qualityProfile: .lowHeat(reason: "runtime-fixture"))
            default:
                renderer = MPVSampleBufferPiPBridge(displayLayer: layer, qualityProfile: .lowHeat(reason: "runtime-fixture"))
            }
            weak var releasedRenderer: AnyObject? = renderer
            let view = try XCTUnwrap(renderer?.getRenderingView())
            defer {
                renderer?.stop()
                view.removeFromSuperview()
            }
            view.frame = host.view.bounds
            host.view.addSubview(view)
            host.view.layoutIfNeeded()
            renderer?.renderingLayoutDidChange(containerSize: view.bounds.size)
            try renderer?.start()
            var commands: [[String]] = []
#if targetEnvironment(simulator)
            commands = [["set", "hwdec", "no"], ["set", "hwdec-software-fallback", "yes"]]
#endif
            let preset = PlayerPreset(id: .sdrRec709, title: "Fixture", summary: "", stream: nil, commands: commands)
            renderer?.load(url: url, with: preset, headers: nil)
            let deadline = Date().addingTimeInterval(12)
            while playbackTime(renderer) < 0.25 && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertGreaterThan(playbackTime(renderer), 0.2, "No advancing playback for renderer \(kind), iteration \(iteration): \(renderer?.pictureInPictureDebugSnapshot() ?? "missing")")
            if requiresHardwareDecode {
                let diagnostics = renderer?.pictureInPictureDebugSnapshot() ?? "missing"
                let usesVideoToolbox = diagnostics.contains(" hw=videotoolbox ") || diagnostics.contains(" hw=videotoolbox-copy ")
                XCTAssertTrue(usesVideoToolbox, "Physical fixture did not use VideoToolbox: \(diagnostics)")
                XCTAssertTrue(diagnostics.contains(" size=\(sourceWidth)x\(sourceHeight)}"), "Physical fixture did not decode the full source dimensions: \(diagnostics)")
            }
            renderer?.pausePlayback()
            try await Task.sleep(nanoseconds: 150_000_000)
            let pausedAt = playbackTime(renderer)
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertLessThan(abs(playbackTime(renderer) - pausedAt), 0.15, "Pause did not hold playback")
            renderer?.seek(to: 1.25)
            let seekDeadline = Date().addingTimeInterval(3)
            while abs(playbackTime(renderer) - 1.25) > 0.25 && Date() < seekDeadline {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTAssertLessThan(abs(playbackTime(renderer) - 1.25), 0.3, "Seek did not reach its target")
            renderer?.setSpeed(1.5)
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(renderer?.getSpeed() ?? 0, 1.5, accuracy: 0.01)
            let resumedAt = ProcessInfo.processInfo.systemUptime
            renderer?.play()
            for size in [CGSize(width: 640, height: 360), CGSize(width: 360, height: 640), host.view.bounds.size] {
                view.frame.size = size
                renderer?.renderingLayoutDidChange(containerSize: size)
                try await Task.sleep(nanoseconds: 80_000_000)
            }
            try await waitForPiPFixture("playback progress after layout changes", timeout: 3) {
                playbackTime(renderer) > 1.3
            }
            XCTAssertGreaterThan(playbackTime(renderer), 1.3, "Playback did not continue through layout changes")
            NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
            metrics.append(["renderer": String(kind), "iteration": String(iteration), "sourceWidth": String(sourceWidth), "sourceHeight": String(sourceHeight), "footprintBytes": String(Self.footprint()), "position": String(playbackTime(renderer)), "resumeToPostLayoutProgressMilliseconds": String((ProcessInfo.processInfo.systemUptime - resumedAt) * 1_000), "diagnostics": renderer?.pictureInPictureDebugSnapshot() ?? "missing"])
            renderer?.stop()
            await renderer?.waitUntilStopped()
            view.removeFromSuperview()
            renderer = nil
            for _ in 0..<40 where releasedRenderer != nil {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTAssertNil(releasedRenderer, "Stopped renderer retained after cycle \(iteration)")
            metrics.append(["renderer": String(kind), "iteration": String(iteration), "phase": "stopped", "footprintBytes": String(Self.footprint())])
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Renderer lifecycle and process footprint"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func playbackTime(_ renderer: PlayerRenderer?) -> Double {
        if let renderer = renderer as? MPVGPUPlayerBridge { return renderer.currentTime }
        if let renderer = renderer as? MPVSampleBufferPiPBridge { return renderer.currentTime }
        return 0
    }

    nonisolated private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    nonisolated private static func makeVideo(at url: URL, frameCount: Int = 120, width: Int = 640, height: Int = 360, segmentDelegate: AVAssetWriterDelegate? = nil) throws {
        let writer: AVAssetWriter
        if let segmentDelegate {
            writer = AVAssetWriter(contentType: .mpeg4Movie)
            writer.delegate = segmentDelegate
            writer.outputFileTypeProfile = .mpeg4AppleHLS
            writer.preferredOutputSegmentInterval = CMTime(seconds: 2, preferredTimescale: 30)
            writer.initialSegmentStartTime = .zero
        } else {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        }
        defer {
            if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
        }
        var outputSettings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height]
        if segmentDelegate != nil {
            outputSettings[AVVideoCompressionPropertiesKey] = [AVVideoMaxKeyFrameIntervalKey: 60]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { throw NSError(domain: "V221VideoFixture", code: 1) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "V221VideoFixture", code: 2) }
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(20)
        let rowTemplate = UnsafeMutablePointer<UInt32>.allocate(capacity: width)
        defer { rowTemplate.deallocate() }
        for frame in 0..<frameCount {
            guard Date() < deadline else { throw NSError(domain: "V221VideoFixture", code: 8, userInfo: [NSLocalizedDescriptionKey: "Local H264 fixture generation exceeded its deadline"]) }
            while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard input.isReadyForMoreMediaData else { throw writer.error ?? NSError(domain: "V221VideoFixture", code: 3) }
            var buffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard result == kCVReturnSuccess, let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw NSError(domain: "V221VideoFixture", code: 4) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw NSError(domain: "V221VideoFixture", code: 5)
            }
            let pixels = base.assumingMemoryBound(to: UInt32.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<UInt32>.size
            if width > 640 || height > 360 {
                for column in 0..<width {
                    rowTemplate[column] = 0xFF000000 | UInt32((frame * 2) % 255) << 16 | UInt32(column % 255) << 8 | UInt32(frame % 255)
                }
                for row in 0..<height {
                    memcpy(pixels.advanced(by: row * stride), rowTemplate, width * MemoryLayout<UInt32>.size)
                }
            } else {
                for row in 0..<height {
                    for column in 0..<width {
                        pixels[row * stride + column] = 0xFF000000 | UInt32((frame * 2) % 255) << 16 | UInt32(column % 255) << 8 | UInt32(row % 255)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? NSError(domain: "V221VideoFixture", code: 6) }
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 20) == .success, writer.status == .completed else {
            writer.cancelWriting()
            throw writer.error ?? NSError(domain: "V221VideoFixture", code: 7)
        }
    }
}

private final class ExternalAudioSegmentFixture: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var initialization = Data()
    private var segments: [Data] = []

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.lock()
        defer { lock.unlock() }
        if segmentType == .initialization { initialization = data } else { segments.append(data) }
    }

    func resources(prefix: String) -> [String: Data] {
        lock.lock()
        defer { lock.unlock() }
        var result = [prefix + "/init.mp4": initialization]
        var manifest = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        for (index, segment) in segments.enumerated() {
            let name = "segment\(index).m4s"
            result[prefix + "/" + name] = segment
            manifest += "#EXTINF:2.000,\n" + name + "\n"
        }
        result[prefix + "/index.m3u8"] = Data((manifest + "#EXT-X-ENDLIST\n").utf8)
        return result
    }
}

private final class ExternalAudioHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let resources: [String: Data]
    private let queue = DispatchQueue(label: "eclipse.external-audio.fixture")
    private var connections: [NWConnection] = []
    private let requestLock = NSLock()
    private var requests: [String] = []
    var port: UInt16? {
        guard let value = listener.port?.rawValue, value > 0 else { return nil }
        return value
    }
    var requestSummary: String {
        requestLock.lock()
        defer { requestLock.unlock() }
        return requests.joined(separator: "; ")
    }

    init(resources: [String: Data]) throws {
        self.resources = resources
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, pending: Data())
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, pending: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] bytes, _, complete, error in
            guard let self else { connection.cancel(); return }
            var pending = pending
            if let bytes { pending.append(bytes) }
            guard pending.count <= 65536, error == nil else { connection.cancel(); return }
            guard pending.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() } else { self.receive(connection, pending: pending) }
                return
            }
            let lines = String(decoding: pending, as: UTF8.self).components(separatedBy: "\r\n")
            let tokens = lines.first?.split(separator: " ") ?? []
            let rangeHeader = lines.first(where: { $0.lowercased().hasPrefix("range:") })
                .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }
            self.requestLock.lock()
            self.requests.append(String((lines.first ?? "missing request").prefix(256)) + " range=" + (rangeHeader ?? "none"))
            self.requestLock.unlock()
            guard tokens.count >= 2, let body = self.resources[String(tokens[1])] else {
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            var byteRange = 0..<body.count
            if let rangeHeader {
                let pair = rangeHeader.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
                let start: Int?
                let end: Int?
                if pair.count == 2, pair[0].isEmpty, let suffix = Int(pair[1]), suffix > 0 {
                    start = max(0, body.count - suffix)
                    end = body.count - 1
                } else if pair.count == 2 {
                    start = Int(pair[0])
                    end = pair[1].isEmpty ? body.count - 1 : Int(pair[1])
                } else {
                    start = nil
                    end = nil
                }
                guard rangeHeader.hasPrefix("bytes="), let start, let end,
                      start >= 0, start < body.count, end >= start else {
                    connection.send(content: Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(body.count)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                byteRange = start..<(min(end, body.count - 1) + 1)
            }
            let payload = body.subdata(in: byteRange)
            let status = rangeHeader == nil ? "200 OK" : "206 Partial Content"
            let type = tokens[1].hasSuffix("m3u8") ? "application/vnd.apple.mpegurl"
                : (tokens[1].hasSuffix("wav") ? "audio/wav" : "video/mp4")
            var header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
            if rangeHeader != nil { header += "Content-Range: bytes \(byteRange.lowerBound)-\(byteRange.upperBound - 1)/\(body.count)\r\n" }
            var response = Data((header + "\r\n").utf8)
            if tokens[0] != "HEAD" { response.append(payload) }
            connection.send(content: response, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private final class MPVPrematureEOFFixture: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "mpv.premature-eof.fixture")
    private let lock = NSLock()
    private var resources: [String: Data] = [:]
    private var segmentCount = 0
    private var healthy = false
    private var rejectedLast = false
    private var servedTarget = false
    private var connections: [NWConnection] = []

    var port: UInt16? {
        guard let value = listener.port?.rawValue, value > 0 else { return nil }
        return value
    }
    var rejectedLastSegment: Bool { withLock { rejectedLast } }
    var servedTargetSegment: Bool { withLock { servedTarget } }

    init(parameters: NWParameters = .tcp) throws {
        listener = try NWListener(using: parameters, on: .any)
        super.init()
    }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        withLock {
            if segmentType == .initialization {
                resources["init.mp4"] = data
            } else {
                resources["segment\(segmentCount).m4s"] = data
                segmentCount += 1
            }
        }
    }

    func resetFailure() {
        withLock {
            healthy = false
            rejectedLast = false
            servedTarget = false
        }
    }

    func restoreUpstream() {
        withLock { healthy = true }
    }

    func start() {
        withLock {
            var playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-MAP:URI=\"init.mp4\"\n"
            for index in 0..<segmentCount {
                playlist += "#EXTINF:2.000,\nsegment\(index).m4s\n"
            }
            playlist += "#EXT-X-ENDLIST\n"
            resources["index.m3u8"] = Data(playlist.utf8)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] bytes, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = data
            if let bytes { request.append(bytes) }
            guard request.count <= 64 * 1024, error == nil else { connection.cancel(); return }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() } else { self.receive(connection, data: request) }
                return
            }
            let path = String(decoding: request, as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let name = String(path.dropFirst())
            let body: Data? = self.withLock {
                if name.hasPrefix("segment"), let index = Int(name.dropFirst(7).dropLast(4)) {
                    if !self.healthy, index >= 4 {
                        if index == self.segmentCount - 1 { self.rejectedLast = true }
                        return nil
                    }
                    if self.healthy, index >= 10 { self.servedTarget = true }
                }
                return self.resources[name]
            }
            let contentType = name.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : "video/mp4"
            let status = body == nil ? "503 Service Unavailable" : "200 OK"
            var response = Data("HTTP/1.1 \(status)\r\nContent-Length: \(body?.count ?? 0)\r\nContent-Type: \(contentType)\r\nConnection: close\r\n\r\n".utf8)
            if let body { response.append(body) }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@MainActor
private final class V221PiPFixtureDelegate: @preconcurrency PiPControllerDelegate {
    private struct CallbackIdentity: Equatable {
        let controller: ObjectIdentifier
        let loadGeneration: Int
        let attempt: Int
    }

    weak var renderer: MPVGPUPlayerBridge?
    var startedAttempts: [Int] = []
    var failedAttempts: [Int] = []
    var didStartWhileSystemActive: [Bool] = []
    var stoppedCount = 0
    var activationFailed = false
    var restoreResult: Bool?
    var acceptedPlaybackCallbacks: [String] = []
    var ignoredPlaybackCallbacks: [String] = []
    private var expectedCallback: CallbackIdentity?
    private var knownRestore: CallbackIdentity?
    private var restoreTask: Task<Void, Never>?
    private var restoreCallbacks: [(Bool) -> Void] = []
    private var playbackTasks: [Task<Void, Never>] = []

    init(renderer: MPVGPUPlayerBridge?) { self.renderer = renderer }

    private func identity(_ controller: PiPController) -> CallbackIdentity {
        CallbackIdentity(controller: ObjectIdentifier(controller), loadGeneration: controller.playbackLoadGeneration, attempt: controller.transitionAttemptID)
    }

    private func acceptsPlayback(_ controller: PiPController) -> Bool {
        renderer != nil && expectedCallback == identity(controller)
    }

    func arm(controller: PiPController) {
        restoreTask?.cancel()
        restoreTask = nil
        restoreResult = nil
        knownRestore = nil
        expectedCallback = identity(controller)
    }

    func cancel() {
        expectedCallback = nil
        knownRestore = nil
        restoreTask?.cancel()
        restoreTask = nil
        playbackTasks.forEach { $0.cancel() }
        playbackTasks.removeAll()
        let callbacks = restoreCallbacks
        restoreCallbacks.removeAll()
        callbacks.forEach { $0(false) }
        renderer = nil
    }

    private func beginRestore(_ controller: PiPController, completion: ((Bool) -> Void)? = nil) {
        let callback = identity(controller)
        guard expectedCallback == callback || knownRestore == callback else {
            completion?(false)
            return
        }
        if let restoreResult, knownRestore == callback {
            completion?(restoreResult)
            return
        }
        if let completion { restoreCallbacks.append(completion) }
        guard restoreTask == nil else { return }
        knownRestore = callback
        restoreTask = Task { @MainActor [weak self, weak renderer] in
            let restored = await renderer?.finishPictureInPictureAndWait(restoringInlinePlayback: true) ?? false
            guard let self, !Task.isCancelled, self.knownRestore == callback else { return }
            self.restoreResult = restored
            if self.expectedCallback == callback { self.expectedCallback = nil }
            let callbacks = self.restoreCallbacks
            self.restoreCallbacks.removeAll()
            callbacks.forEach { $0(restored) }
        }
    }

    func pipController(_ controller: PiPController, willStartPictureInPicture: Bool) {
        guard acceptsPlayback(controller) else { return }
        if renderer?.isPictureInPicturePrimed() == true {
            activationFailed = renderer?.activatePictureInPictureLayer() != true || activationFailed
        }
    }

    func pipController(_ controller: PiPController, didStartPictureInPicture: Bool, attemptID: Int) {
        guard acceptsPlayback(controller), expectedCallback?.attempt == attemptID else { return }
        if didStartPictureInPicture {
            startedAttempts.append(attemptID)
            didStartWhileSystemActive.append(controller.isPictureInPictureActive)
            activationFailed = renderer?.activatePictureInPictureLayer() != true || activationFailed
        } else {
            failedAttempts.append(attemptID)
        }
    }

    func pipController(_ controller: PiPController, willStopPictureInPicture: Bool) { }

    func pipController(_ controller: PiPController, didStopPictureInPicture: Bool) {
        let callback = identity(controller)
        guard expectedCallback == callback || knownRestore == callback else { return }
        stoppedCount += 1
        beginRestore(controller)
    }

    func pipController(_ controller: PiPController, restoreUserInterfaceForPictureInPictureStop completionHandler: @escaping (Bool) -> Void) {
        beginRestore(controller, completion: completionHandler)
    }

    func pipControllerPlay(_ controller: PiPController) {
        guard acceptsPlayback(controller) else { return }
        renderer?.play()
    }

    func pipControllerPause(_ controller: PiPController) {
        guard acceptsPlayback(controller) else { return }
        renderer?.pausePlayback()
    }

    func pipController(_ controller: PiPController, setPlaying playing: Bool, completion: @escaping () -> Void) {
        let event = "attempt=\(controller.transitionAttemptID) playing=\(playing)"
        guard acceptsPlayback(controller) else {
            ignoredPlaybackCallbacks.append(event)
            completion()
            return
        }
        acceptedPlaybackCallbacks.append(event)
        if playing { renderer?.play() } else { renderer?.pausePlayback() }
        playbackTasks.append(Task { @MainActor [weak renderer] in
            await renderer?.waitForPictureInPictureTimelineUpdate()
            completion()
        })
    }

    func pipController(_ controller: PiPController, didTransitionToRenderSize size: CGSize) {
        guard acceptsPlayback(controller) else { return }
        renderer?.updatePictureInPictureRenderSize(size)
    }

    func pipController(_ controller: PiPController, skipByInterval interval: CMTime, completion: @escaping () -> Void) {
        guard acceptsPlayback(controller) else {
            completion()
            return
        }
        let seconds = CMTimeGetSeconds(interval)
        if seconds.isFinite { renderer?.seek(by: seconds) }
        playbackTasks.append(Task { @MainActor [weak renderer] in
            await renderer?.waitForPictureInPictureTimelineUpdate()
            completion()
        })
    }

    func pipControllerIsPlaying(_ controller: PiPController) -> Bool {
        acceptsPlayback(controller) && renderer?.isPausedState == false
    }

    func pipControllerDuration(_ controller: PiPController) -> Double {
        acceptsPlayback(controller) ? renderer?.duration ?? 0 : 0
    }

    func pipControllerCurrentTime(_ controller: PiPController) -> Double {
        acceptsPlayback(controller) ? renderer?.currentTime ?? 0 : 0
    }
}

#endif

final class MPVScalerPolicyTests: XCTestCase {

    func testDolbyOptionsAreAcceptedByBundledMPV() throws {
        let suite = "DolbyNativeOptionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "mpvDolbyVisionEnabled")
        for atmos in [false, true] {
            defaults.set(atmos, forKey: "mpvDolbyAtmosEnabled")
            let handle = try XCTUnwrap(mpv_create())
            defer { mpv_terminate_destroy(handle) }
            XCTAssertGreaterThanOrEqual(mpv_set_option_string(handle, "vo", "null"), 0)
            XCTAssertGreaterThanOrEqual(mpv_set_option_string(handle, "ao", "null"), 0)
            XCTAssertGreaterThanOrEqual(mpv_set_option_string(handle, "terminal", "no"), 0)
            for (name, value) in MPVDolbyPlaybackSettings(defaults: defaults).options {
                XCTAssertGreaterThanOrEqual(mpv_set_option_string(handle, name, value), 0, name)
            }
            XCTAssertGreaterThanOrEqual(mpv_initialize(handle), 0)
            let raw = try XCTUnwrap(mpv_get_property_string(handle, "vf"))
            defer { mpv_free(raw) }
            XCTAssertTrue(String(cString: raw).contains("dolbyvision=no"))
        }
    }

    func testDolbySettingsKeepSurroundIndependentAndDisableCompressedFallback() throws {
        let suite = "DolbyPlaybackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = MPVDolbyPlaybackSettings(defaults: defaults)
        XCTAssertTrue(initial.visionEnabled)
        XCTAssertTrue(initial.atmosEnabled)
        XCTAssertNil(initial.options["vf"])
        for vision in [false, true] {
            for atmos in [false, true] {
                for surround in [false, true] {
                    defaults.set(vision, forKey: "mpvDolbyVisionEnabled")
                    defaults.set(atmos, forKey: "mpvDolbyAtmosEnabled")
                    defaults.set(surround, forKey: "mpvSurroundSoundEnabled")
                    let settings = MPVDolbyPlaybackSettings(defaults: defaults)
                    XCTAssertEqual(settings.options["audio-channels"], surround ? "auto" : "stereo")
                    XCTAssertEqual(settings.options["apple-compressed-audio"], atmos && surround ? "yes" : "no")
                    XCTAssertEqual(settings.options["audio-spdif"], atmos && surround ? "eac3" : "")
                    XCTAssertEqual(settings.videoFilterChain.isEmpty, vision)
                    XCTAssertEqual(settings.options["vf"], vision ? nil : settings.videoFilterChain)
                }
            }
        }
        XCTAssertTrue(initial.atmosEnabled)
        XCTAssertTrue(initial.visionEnabled)
        XCTAssertEqual(EclipseSettingsRegistry.scope(for: "mpvDolbyVisionEnabled"), .profile)
        XCTAssertEqual(EclipseSettingsRegistry.scope(for: "mpvDolbyAtmosEnabled"), .profile)
    }

    func testHDROutputHonorsSDRAndDisplayCapabilityWithoutExpandingSDRContent() {
        for mode in MPVHDRMode.allCases {
            XCTAssertFalse(mode.usesHDR(sourceIsHDR: false, displaySupportsHDR: true))
            XCTAssertFalse(mode.usesHDR(sourceIsHDR: false, displaySupportsHDR: false))
        }
        XCTAssertTrue(MPVHDRMode.auto.usesHDR(sourceIsHDR: true, displaySupportsHDR: true))
        XCTAssertFalse(MPVHDRMode.auto.usesHDR(sourceIsHDR: true, displaySupportsHDR: false))
        XCTAssertTrue(MPVHDRMode.hdr.usesHDR(sourceIsHDR: true, displaySupportsHDR: false))
        XCTAssertFalse(MPVHDRMode.sdr.usesHDR(sourceIsHDR: true, displaySupportsHDR: true))
    }

    private func inline(
        mode: MPVUpscalingMode,
        neuralActive: Bool = false,
        isPad: Bool = false,
        isLowHeat: Bool = false,
        sourceHeight: Int = 1080
    ) -> MPVScalerSelection {
        MPVScalerPolicy.inlineScalers(
            mode: mode,
            neuralActive: neuralActive,
            isPad: isPad,
            isLowHeat: isLowHeat,
            sourceHeight: sourceHeight
        )
    }

    func testOffModeStaysOnCheapPath() {
        let s = inline(mode: .off)
        XCTAssertEqual(s, MPVScalerSelection(scale: "bilinear", cscale: "bilinear", dscale: "mitchell", deband: "no", qualityScaling: false))
    }

    func testLowHeatForcesCheapPathInEveryMode() {
        for mode in MPVUpscalingMode.allCases {
            let s = inline(mode: mode, isLowHeat: true, sourceHeight: 720)
            XCTAssertEqual(s.scale, "bilinear", "mode \(mode.rawValue)")
            XCTAssertEqual(s.deband, "no", "mode \(mode.rawValue)")
            XCTAssertFalse(s.qualityScaling, "mode \(mode.rawValue)")
        }
    }

    func testUpscaleTo1080AppliesQualityOnlyBelowHD() {
        let below = inline(mode: .upscaleTo1080, sourceHeight: 720)
        XCTAssertEqual(below.scale, "ewa_lanczossharp")
        XCTAssertEqual(below.cscale, "lanczos")
        XCTAssertTrue(below.qualityScaling)
        let at = inline(mode: .upscaleTo1080, sourceHeight: 1080)
        XCTAssertEqual(at.scale, "bilinear")
        XCTAssertFalse(at.qualityScaling)
        let unknown = inline(mode: .upscaleTo1080, sourceHeight: 0)
        XCTAssertEqual(unknown.scale, "bilinear")
    }

    func testUpscaleTo4KUsesQualityChroma() {
        let s = inline(mode: .upscaleTo4K, sourceHeight: 1080)
        XCTAssertEqual(s, MPVScalerSelection(scale: "lanczos", cscale: "lanczos", dscale: "mitchell", deband: "yes", qualityScaling: true))
        let uhd = inline(mode: .upscaleTo4K, sourceHeight: 2160)
        XCTAssertEqual(uhd.scale, "bilinear")
        XCTAssertFalse(uhd.qualityScaling)
    }

    func testQualityModesOnPadDemoteChromaToLanczos() {
        for mode in [MPVUpscalingMode.oneLevelAlways, .auto] {
            let s = inline(mode: mode, isPad: true)
            XCTAssertEqual(s.scale, "ewa_lanczossharp", "mode \(mode.rawValue)")
            XCTAssertEqual(s.cscale, "lanczos", "mode \(mode.rawValue)")
            XCTAssertTrue(s.qualityScaling, "mode \(mode.rawValue)")
        }
    }

    func testNeuralUpgradesTheCheapResamplerWhereverItRuns() {
        let s = inline(mode: .upscaleTo1080, neuralActive: true, sourceHeight: 1080)
        XCTAssertEqual(s, MPVScalerSelection(scale: "lanczos", cscale: "lanczos", dscale: "mitchell", deband: "yes", qualityScaling: true))
    }

    func testNeuralOnPadDemotesEWAScalers() {
        let s = inline(mode: .auto, neuralActive: true, isPad: true)
        XCTAssertEqual(s.scale, "lanczos")
        XCTAssertEqual(s.cscale, "lanczos")
    }

    func testNeuralOnPhoneKeepsEWAScalers() {
        let s = inline(mode: .auto, neuralActive: true)
        XCTAssertEqual(s.scale, "ewa_lanczossharp")
        XCTAssertEqual(s.cscale, "lanczos")
    }

    private func inlineNeural(
        selected: MPVNeuralUpscaler,
        mode: MPVUpscalingMode = .auto,
        isAnimation: Bool = false,
        supportsConvolutional: Bool = true,
        isLowHeat: Bool = false,
        isThermallyReduced: Bool = false,
        sourceHeight: Int = 1080,
        outputScale: Double? = 2.0
    ) -> MPVNeuralUpscaler {
        MPVScalerPolicy.inlineNeuralUpscaler(
            selected: selected,
            mode: mode,
            isAnimation: isAnimation,
            supportsConvolutional: supportsConvolutional,
            isLowHeat: isLowHeat,
            isThermallyReduced: isThermallyReduced,
            sourceHeight: sourceHeight,
            outputScale: outputScale
        )
    }

    func testInlineNeuralUpscalerGates() {
        XCTAssertEqual(inlineNeural(selected: .anime), .anime)
        XCTAssertEqual(inlineNeural(selected: .off, sourceHeight: 720), .off)
        XCTAssertEqual(inlineNeural(selected: .anime, supportsConvolutional: false, sourceHeight: 720), .off)
        XCTAssertEqual(inlineNeural(selected: .anime, isLowHeat: true, sourceHeight: 720), .off)
        XCTAssertEqual(inlineNeural(selected: .general, sourceHeight: 1440), .general)
        XCTAssertEqual(inlineNeural(selected: .general, sourceHeight: 1441), .off)
    }

    func testEnhancedUpscalingIsOffWhenUpscalingModeIsOff() {
        XCTAssertEqual(inlineNeural(selected: .anime, mode: .off), .off)
        XCTAssertEqual(inlineNeural(selected: .general, mode: .off), .off)
        XCTAssertEqual(inlineNeural(selected: .automatic, mode: .off, isAnimation: true), .off)
        for mode in MPVUpscalingMode.allCases where mode != .off {
            XCTAssertNotEqual(inlineNeural(selected: .general, mode: mode), .off, mode.rawValue)
        }
    }

    func testAutomaticPicksArtCNNForAnimationAndFSRForLiveAction() {
        XCTAssertEqual(inlineNeural(selected: .automatic, isAnimation: true), .anime)
        XCTAssertEqual(inlineNeural(selected: .automatic, isAnimation: false), .general)
        XCTAssertEqual(
            MPVScalerPolicy.tvNeuralUpscaler(selected: .automatic, isAnimation: true, supportsConvolutional: true, sourceHeight: 1080, outputScale: 2.0),
            .anime
        )
        XCTAssertEqual(
            MPVScalerPolicy.tvNeuralUpscaler(selected: .automatic, isAnimation: false, supportsConvolutional: true, sourceHeight: 1080, outputScale: 2.0),
            .general
        )
    }

    func testAutomaticFallsBackToFSRWhenTheDeviceCannotRunArtCNN() {
        XCTAssertEqual(inlineNeural(selected: .automatic, isAnimation: true, supportsConvolutional: false), .general)
        XCTAssertEqual(
            MPVScalerPolicy.tvNeuralUpscaler(selected: .automatic, isAnimation: true, supportsConvolutional: false, sourceHeight: 1080, outputScale: 2.0),
            .general
        )
    }

    func testAnExplicitChoiceIsNeverOverriddenByContentType() {
        XCTAssertEqual(inlineNeural(selected: .anime, isAnimation: false), .anime)
        XCTAssertEqual(inlineNeural(selected: .general, isAnimation: true), .general)
        XCTAssertEqual(inlineNeural(selected: .animeLowBitrate, isAnimation: false), .animeLowBitrate)
    }

    func testTVScalersUpgradeChromaOnCapableHardware() {
        let capable = MPVScalerPolicy.tvScalers(neuralActive: false, qualityChroma: true)
        XCTAssertEqual(capable, MPVScalerSelection(scale: "bilinear", cscale: "lanczos", dscale: "mitchell", deband: "no", qualityScaling: false))
        let constrained = MPVScalerPolicy.tvScalers(neuralActive: false, qualityChroma: false)
        XCTAssertEqual(constrained.cscale, "bilinear")
        let neural = MPVScalerPolicy.tvScalers(neuralActive: true, qualityChroma: true)
        XCTAssertEqual(neural, MPVScalerSelection(scale: "lanczos", cscale: "lanczos", dscale: "mitchell", deband: "yes", qualityScaling: true))
    }

    func testTVQualityChromaMemoryBoundary() {
        XCTAssertTrue(MPVScalerPolicy.tvSupportsQualityChroma(memoryGB: 2.5))
        XCTAssertTrue(MPVScalerPolicy.tvSupportsQualityChroma(memoryGB: 3.0))
        XCTAssertFalse(MPVScalerPolicy.tvSupportsQualityChroma(memoryGB: 2.0))
    }

    func testTVNeuralUpscalerGates() {
        XCTAssertEqual(
            MPVScalerPolicy.tvNeuralUpscaler(selected: .anime, isAnimation: true, supportsConvolutional: true, sourceHeight: 1080, outputScale: 2.0),
            .anime
        )
        XCTAssertEqual(
            MPVScalerPolicy.tvNeuralUpscaler(selected: .anime, isAnimation: true, supportsConvolutional: true, sourceHeight: 2160, outputScale: 2.0),
            .off
        )
        XCTAssertEqual(
            MPVScalerPolicy.tvNeuralUpscaler(selected: .anime, isAnimation: true, supportsConvolutional: false, sourceHeight: 1080, outputScale: 2.0),
            .off
        )
    }

    private func neural(
        selected: MPVNeuralUpscaler,
        resolved: MPVNeuralUpscaler? = nil,
        mode: MPVUpscalingMode = .auto,
        shaderLoaded: Bool = true,
        shaderListAccepted: Bool = true,
        executionConfirmed: Bool = false,
        isSupported: Bool = true,
        isLowHeat: Bool = false,
        isThermallyReduced: Bool = false,
        sourceHeight: Int = 720,
        outputScale: Double? = 2.0
    ) -> MPVNeuralUpscalerStatus? {
        MPVScalerPolicy.neuralStatus(
            selected: selected,
            resolved: resolved ?? selected,
            mode: mode,
            shaderLoaded: shaderLoaded,
            shaderListAccepted: shaderListAccepted,
            executionConfirmed: executionConfirmed,
            isSupported: isSupported,
            isLowHeat: isLowHeat,
            isThermallyReduced: isThermallyReduced,
            sourceHeight: sourceHeight,
            outputScale: outputScale
        )
    }

    func testStatusNamesTheActiveScaler() {
        let status = MPVScalerPolicy.status(
            mode: .auto,
            scalers: inline(mode: .auto),
            isLowHeat: false,
            sourceHeight: 1080
        )
        XCTAssertTrue(status.isActive)
        XCTAssertFalse(status.isThermallyLimited)
        XCTAssertEqual(status.summary, "EWA Lanczos")
    }

    func testStatusBlamesLowHeatBeforeAnythingElse() {
        let status = MPVScalerPolicy.status(
            mode: .auto,
            scalers: inline(mode: .auto, isLowHeat: true, sourceHeight: 720),
            isLowHeat: true,
            sourceHeight: 720
        )
        XCTAssertFalse(status.isActive)
        XCTAssertTrue(status.isThermallyLimited)
        XCTAssertEqual(status.summary, "Off · Low Heat")
    }

    func testStatusBlamesSourceHeightWhenModeCannotUpscaleIt() {
        let status = MPVScalerPolicy.status(
            mode: .upscaleTo1080,
            scalers: inline(mode: .upscaleTo1080, sourceHeight: 1080),
            isLowHeat: false,
            sourceHeight: 1080
        )
        XCTAssertFalse(status.isActive)
        XCTAssertFalse(status.isThermallyLimited)
        XCTAssertEqual(status.summary, "Off · 1080p source")
    }

    func testStatusDistinguishesDisabledFromPendingSource() {
        let disabled = MPVScalerPolicy.status(
            mode: .off,
            scalers: inline(mode: .off),
            isLowHeat: false,
            sourceHeight: 1080
        )
        XCTAssertEqual(disabled.summary, "Off")
        let pending = MPVScalerPolicy.status(
            mode: .upscaleTo1080,
            scalers: inline(mode: .upscaleTo1080, sourceHeight: 0),
            isLowHeat: false,
            sourceHeight: 0
        )
        XCTAssertEqual(pending.summary, "Off · source pending")
    }

    func testNeuralStatusIsAbsentWhenNothingIsSelected() {
        XCTAssertNil(neural(selected: .off))
    }

    func testNeuralStatusDoesNotClaimExecutionFromEligibilityAlone() {
        let status = neural(selected: .anime, outputScale: 1.8)
        XCTAssertEqual(status?.isEngaged, true)
        XCTAssertEqual(status?.isConfirmedRunning, false)
        XCTAssertEqual(status?.summary, "ArtCNN · on, 1.80x output")
    }

    func testNeuralStatusReportsUpscalingModeOffBeforeAnythingElse() {
        let status = neural(selected: .anime, resolved: .off, mode: .off)
        XCTAssertEqual(status?.isEngaged, false)
        XCTAssertEqual(status?.summary, "ArtCNN · off, Upscaling off")
    }

    func testNeuralStatusNamesTheUpscalerAutomaticResolvedTo() {
        let status = neural(selected: .automatic, resolved: .general, outputScale: 1.8)
        XCTAssertEqual(status?.summary, "FSR 1 · on, 1.80x output")
        let idle = neural(selected: .automatic, resolved: .off, mode: .off)
        XCTAssertEqual(idle?.summary, "Auto · off, Upscaling off")
    }

    func testNeuralStatusReportsRunningOnlyWithPassConfirmation() {
        let status = neural(selected: .anime, executionConfirmed: true, outputScale: 1.8)
        XCTAssertEqual(status?.isConfirmedRunning, true)
        XCTAssertEqual(status?.summary, "ArtCNN · running, 1.80x output")
    }

    func testNeuralStatusReportsIdleAtTheShaderActivationThreshold() {
        let threshold = MPVScalerPolicy.neuralActivationThreshold(for: .anime)
        let below = neural(selected: .anime, outputScale: threshold)
        XCTAssertEqual(below?.isConfirmedRunning, false)
        XCTAssertEqual(below?.summary, "ArtCNN · idle, 1.05x output")
        let above = neural(selected: .anime, outputScale: 1.06)
        XCTAssertEqual(above?.isConfirmedRunning, false)
        XCTAssertEqual(above?.summary, "ArtCNN · on, 1.06x output")
    }

    func testFSR1AllowsModestPhoneEnlargement() {
        XCTAssertEqual(MPVScalerPolicy.neuralActivationThreshold(for: .general), 1.05)
        XCTAssertEqual(neural(selected: .general, outputScale: 1.05)?.summary, "FSR 1 · idle, 1.05x output")
        XCTAssertEqual(neural(selected: .general, outputScale: 1.06)?.summary, "FSR 1 · on, 1.06x output")
    }

    func testNeuralStatusBlamesUnsupportedHardware() {
        let status = neural(selected: .anime, resolved: .off, isSupported: false)
        XCTAssertEqual(status?.isConfirmedRunning, false)
        XCTAssertEqual(status?.summary, "ArtCNN · off, needs more memory")
    }

    func testNeuralStatusBlamesLowHeat() {
        let status = neural(selected: .animeLowBitrate, resolved: .off, isLowHeat: true)
        XCTAssertEqual(status?.isConfirmedRunning, false)
        XCTAssertEqual(status?.summary, "ArtCNN DS · off, Low Heat")
    }

    func testNeuralStatusBlamesSourceAboveTheGate() {
        let status = neural(selected: .anime, resolved: .off, sourceHeight: 2160)
        XCTAssertEqual(status?.isConfirmedRunning, false)
        XCTAssertEqual(status?.summary, "ArtCNN · off, 2160p source")
    }

    func testNeuralStatusBlamesMissingShader() {
        let status = neural(selected: .general, shaderLoaded: false)
        XCTAssertEqual(status?.isConfirmedRunning, false)
        XCTAssertEqual(status?.summary, "FSR 1 · off, shader missing")
    }

    func testNeuralStatusReportsRendererRejection() {
        let status = neural(selected: .general, shaderListAccepted: false)
        XCTAssertEqual(status?.isConfirmedRunning, false)
        XCTAssertEqual(status?.summary, "FSR 1 · off, renderer rejected shader")
    }

    func testNeuralStatusDoesNotClaimRunningBeforeVideoDimensionsExist() {
        let status = neural(selected: .general, outputScale: nil)
        XCTAssertEqual(status?.isConfirmedRunning, false)
        XCTAssertEqual(status?.summary, "FSR 1 · configured, video pending")
    }

    func testNeuralStatusMatchesTheBundledShaderActivationThreshold() throws {
        for upscaler in [MPVNeuralUpscaler.anime, .animeLowBitrate, .general] {
            let path = try XCTUnwrap(MPVUserShaderLibrary.shaderPath(for: upscaler), upscaler.rawValue)
            let contents = try String(contentsOfFile: path, encoding: .utf8)
            let threshold = String(format: "%g", MPVScalerPolicy.neuralActivationThreshold(for: upscaler))
            for line in contents.components(separatedBy: .newlines) where line.hasPrefix("//!WHEN") {
                XCTAssertTrue(line.contains(threshold), "\(upscaler.rawValue): \(line)")
            }
        }
    }

    func testNoisyAnimeUsesDenoiseAndSharpenModel() throws {
        let path = try XCTUnwrap(MPVUserShaderLibrary.shaderPath(for: .animeLowBitrate))
        XCTAssertEqual((path as NSString).lastPathComponent, "ArtCNN_C4F16_DS.glsl")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents.contains("//!DESC ArtCNN C4F16 DS"))
        XCTAssertFalse(contents.contains("//!DESC ArtCNN C4F16 DN"))
    }

    func testBundledArtCNNShadersUseRelaxedActivationThreshold() throws {
        for upscaler in [MPVNeuralUpscaler.anime, .animeLowBitrate] {
            let path = try XCTUnwrap(MPVUserShaderLibrary.shaderPath(for: upscaler), upscaler.rawValue)
            let contents = try String(contentsOfFile: path, encoding: .utf8)
            let whenLines = contents
                .components(separatedBy: .newlines)
                .filter { $0.hasPrefix("//!WHEN") }
            XCTAssertFalse(whenLines.isEmpty, upscaler.rawValue)
            for line in whenLines {
                XCTAssertTrue(line.contains("1.05"), "\(upscaler.rawValue): \(line)")
                XCTAssertFalse(line.contains("1.3"), "\(upscaler.rawValue): \(line)")
            }
        }
    }

    func testBundledFSR1ShaderUsesFixedAppPolicy() throws {
        let path = try XCTUnwrap(MPVUserShaderLibrary.shaderPath(for: .general))
        XCTAssertEqual((path as NSString).lastPathComponent, "AMD_FSR1_EASU_RCAS.glsl")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let whenLines = contents
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("//!WHEN") }
        XCTAssertFalse(whenLines.isEmpty)
        for line in whenLines {
            XCTAssertTrue(line.contains("1.05"), line)
            XCTAssertFalse(line.contains("1.300"), line)
        }
        XCTAssertTrue(contents.contains("Copyright (c) 2021 Advanced Micro Devices"))
        XCTAssertTrue(contents.contains("adapted to mpv GLSL from mpv_PlayKit"))
        XCTAssertTrue(contents.contains("//!HOOK MAIN"))
        XCTAssertTrue(contents.contains("EASU (Edge-Adaptive Spatial Upsampling)"))
        XCTAssertTrue(contents.contains("RCAS (Robust Contrast-Adaptive Sharpening)"))
        XCTAssertTrue(contents.contains("#define SHARP           0.2"))
        XCTAssertTrue(contents.contains("#define NDS             1"))
        XCTAssertFalse(contents.contains("//!PARAM"))
        XCTAssertFalse(contents.contains("fsr_sharpness"))
        XCTAssertFalse(contents.contains("fsr_pq"))
    }

    func testTheAdaptiveSharpenShaderIsNoLongerBundled() {
        XCTAssertNil(Bundle(for: type(of: self)).path(forResource: "EclipseCAS", ofType: "glsl", inDirectory: "Shaders"))
    }

    func testThermalReductionDisablesTheNeuralUpscalerOutright() {
        XCTAssertEqual(inlineNeural(selected: .anime, isThermallyReduced: true), .off)
        XCTAssertEqual(inlineNeural(selected: .general, isThermallyReduced: true, outputScale: 4.0), .off)
        XCTAssertEqual(inlineNeural(selected: .anime, isThermallyReduced: false), .anime)
        for mode in MPVUpscalingMode.allCases {
            XCTAssertEqual(inlineNeural(selected: .anime, mode: mode, isThermallyReduced: true), .off, mode.rawValue)
        }
    }

    func testThermalReductionLeavesTheScalerSelectionAlone() {
        for mode in MPVUpscalingMode.allCases {
            XCTAssertEqual(inline(mode: mode), inline(mode: mode), mode.rawValue)
        }
        let quality = inline(mode: .oneLevelAlways)
        XCTAssertEqual(quality.scale, "ewa_lanczossharp")
        XCTAssertEqual(quality.deband, "yes")
    }

    func testNeuralStatusBlamesAWarmDeviceBeforeSourceHeight() {
        let status = neural(selected: .anime, resolved: .off, isThermallyReduced: true, sourceHeight: 2160)
        XCTAssertEqual(status?.isEngaged, false)
        XCTAssertEqual(status?.isConfirmedRunning, false)
        XCTAssertEqual(status?.summary, "ArtCNN · off, device warm")
    }

    func testLowHeatOutranksAWarmDeviceInTheStatusString() {
        let status = neural(selected: .anime, resolved: .off, isLowHeat: true, isThermallyReduced: true)
        XCTAssertEqual(status?.summary, "ArtCNN · off, Low Heat")
    }

    func testInlineNeuralUpscalerStaysOffBelowTheShaderActivationThreshold() {
        XCTAssertEqual(inlineNeural(selected: .anime, outputScale: 1.0833), .anime)
        XCTAssertEqual(inlineNeural(selected: .anime, outputScale: 0.888), .off)
        XCTAssertEqual(inlineNeural(selected: .anime, outputScale: 1.05), .off)
        XCTAssertEqual(inlineNeural(selected: .anime, outputScale: 0.6094), .off)
    }

    func testInlineNeuralUpscalerStaysSelectedWhileTheOutputSizeIsUnknown() {
        XCTAssertEqual(inlineNeural(selected: .anime, outputScale: nil), .anime)
        XCTAssertEqual(inlineNeural(selected: .automatic, isAnimation: true, outputScale: nil), .anime)
    }

    func testTVNeuralUpscalerRespectsTheShaderActivationThreshold() {
        XCTAssertEqual(
            MPVScalerPolicy.tvNeuralUpscaler(selected: .anime, isAnimation: true, supportsConvolutional: true, sourceHeight: 1080, outputScale: 1.0),
            .off
        )
        XCTAssertEqual(
            MPVScalerPolicy.tvNeuralUpscaler(selected: .anime, isAnimation: true, supportsConvolutional: true, sourceHeight: 1080, outputScale: nil),
            .anime
        )
    }







#if os(iOS)
    func testOnlyAnAutomaticReductionCountsAsThermallyReduced() {
        XCTAssertFalse(MPVMetalSampleBufferQualityProfile.balanced(reason: "manual").isThermallyReduced)
        XCTAssertTrue(MPVMetalSampleBufferQualityProfile.balanced(reason: "auto", isAutomatic: true).isThermallyReduced)
        XCTAssertFalse(MPVMetalSampleBufferQualityProfile.sharp(reason: "auto", isAutomatic: true).isThermallyReduced)
        XCTAssertFalse(
            MPVMetalSampleBufferQualityProfile.balanced(reason: "manual")
                .hasSameRenderSettings(as: .balanced(reason: "auto", isAutomatic: true))
        )
    }
#endif

    func testAutomaticIsOfferedAndTheDenoiseVariantIsNot() {
        let offered = MPVNeuralUpscaler.offeredUpscalers
        XCTAssertEqual(offered, [.off, .automatic, .anime, .general])
        XCTAssertFalse(offered.contains(.animeLowBitrate))
        XCTAssertTrue(MPVUserShaderLibrary.pickerUpscalers(including: .animeLowBitrate).contains(.animeLowBitrate))
        XCTAssertFalse(MPVUserShaderLibrary.pickerUpscalers(including: .general).contains(.animeLowBitrate))
    }
}
