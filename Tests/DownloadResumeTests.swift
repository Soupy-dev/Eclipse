import Foundation
import XCTest
@testable import Eclipse

final class DownloadResumeTests: XCTestCase {
    private let chunk = DirectDownloadResumePolicy.chunkBytes

    private func response(
        status: Int = 206,
        start: Int64,
        total: Int64,
        entityTag: String? = "\"version-1\"",
        encoding: String? = nil
    ) throws -> HTTPURLResponse {
        var headers = ["Content-Range": "bytes \(start)-\(min(start + chunk - 1, total - 1))/\(total)"]
        headers["ETag"] = entityTag
        headers["Content-Encoding"] = encoding
        return try XCTUnwrap(HTTPURLResponse(
            url: XCTUnwrap(URL(string: "http://127.0.0.1/media")),
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ))
    }

    private func checkpoint(start: Int64, total: Int64) throws -> DirectDownloadCheckpoint {
        DirectDownloadCheckpoint(
            byteCount: start,
            totalBytes: total,
            representationSHA256: try XCTUnwrap(DirectDownloadResumePolicy.representationDigest(
                url: XCTUnwrap(URL(string: "https://cdn.example/movie.mkv?token=old")),
                entityTag: "\"version-1\""
            ))
        )
    }

    func testResumeBeyondTwoGiBUsesFullWidthRanges() throws {
        let start: Int64 = 3 * 1024 * 1024 * 1024
        let total = start + 19
        XCTAssertEqual(DirectDownloadResumePolicy.requestRange(start: start, total: total), "bytes=3221225472-3221225490")
        let range = try XCTUnwrap(DirectDownloadResumePolicy.byteRange("bytes 3221225472-3221225490/3221225491"))
        XCTAssertEqual(range.start, start)
        XCTAssertEqual(range.total, total)
        XCTAssertTrue(DirectDownloadResumePolicy.accepts(
            response: try response(start: start, total: total),
            bodyBytes: 19,
            authoritativeURL: try XCTUnwrap(URL(string: "https://cdn.example/movie.mkv?token=old")),
            checkpoint: try checkpoint(start: start, total: total)
        ))
    }

    func testMalformedAndOverflowingRangesAreRejected() {
        for range in ["bytes 0-9/*", "bytes -1-9/10", "bytes 10-9/20", "bytes 0-10/10", "bytes 0-9/9223372036854775807", "bytes 0-9999999999999999999999/10", "bytes 0-1/2/3"] {
            XCTAssertNil(DirectDownloadResumePolicy.byteRange(range), range)
        }
        XCTAssertNil(DirectDownloadResumePolicy.requestRange(start: .max))
        XCTAssertNil(DirectDownloadResumePolicy.requestRange(start: -1))
        XCTAssertNil(DirectDownloadResumePolicy.requestRange(start: 10, total: 10))
    }

    func testShortBodyAndChangedRepresentationCannotAppend() throws {
        let total = chunk * 4
        let saved = try checkpoint(start: chunk, total: total)
        let url = try XCTUnwrap(URL(string: "https://cdn.example/movie.mkv?token=old"))
        let good = try response(start: chunk, total: total)
        XCTAssertTrue(DirectDownloadResumePolicy.accepts(response: good, bodyBytes: chunk, authoritativeURL: url, checkpoint: saved))
        XCTAssertFalse(DirectDownloadResumePolicy.accepts(response: good, bodyBytes: chunk - 1, authoritativeURL: url, checkpoint: saved))
        for bad in [
            try response(status: 200, start: chunk, total: total),
            try response(start: 0, total: total),
            try response(start: chunk, total: total + 1),
            try response(start: chunk, total: total, entityTag: "\"version-2\""),
            try response(start: chunk, total: total, entityTag: "W/\"version-1\""),
            try response(start: chunk, total: total, entityTag: nil),
            try response(start: chunk, total: total, encoding: "gzip")
        ] {
            XCTAssertFalse(DirectDownloadResumePolicy.accepts(response: bad, bodyBytes: chunk, authoritativeURL: url, checkpoint: saved))
        }
        for changed in ["https://another.example/movie.mkv", "https://cdn.example/different.mkv", "https://cdn.example/movie.mkv?token=new"] {
            XCTAssertFalse(DirectDownloadResumePolicy.accepts(response: good, bodyBytes: chunk, authoritativeURL: try XCTUnwrap(URL(string: changed)), checkpoint: saved))
        }
    }

    func testShorterValidServerRangeRemainsResumable() throws {
        let total = chunk * 4
        let source = try XCTUnwrap(URL(string: "https://cdn.example/movie.mkv?token=old"))
        let response = try XCTUnwrap(HTTPURLResponse(url: source, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
            "ETag": "\"version-1\"",
            "Content-Range": "bytes \(chunk)-\(chunk + 1023)/\(total)"
        ]))
        XCTAssertTrue(DirectDownloadResumePolicy.accepts(response: response, bodyBytes: 1024, authoritativeURL: source, checkpoint: try checkpoint(start: chunk, total: total)))
        XCTAssertFalse(DirectDownloadResumePolicy.accepts(response: response, bodyBytes: 1023, authoritativeURL: source, checkpoint: try checkpoint(start: chunk, total: total)))
    }

    func testMissingSystemResumeDataDoesNotSilentlyRestartQueuedResume() {
        XCTAssertEqual(DirectDownloadResumePolicy.pauseCompletionStatus(requestedStatus: .queued, resumeData: nil, downloadedBytes: chunk), .paused)
        XCTAssertEqual(DirectDownloadResumePolicy.pauseCompletionStatus(requestedStatus: .queued, resumeData: Data(), downloadedBytes: chunk), .paused)
        XCTAssertEqual(DirectDownloadResumePolicy.pauseCompletionStatus(requestedStatus: .queued, resumeData: Data([1]), downloadedBytes: chunk), .queued)
        XCTAssertEqual(DirectDownloadResumePolicy.pauseCompletionStatus(requestedStatus: .queued, resumeData: nil, downloadedBytes: 0), .queued)
    }

    func testImmediateResumeWaitsForPauseCallbackAndRejectsStaleCallback() {
        XCTAssertTrue(DirectDownloadResumePolicy.mayStoreResumeData(pendingTaskIdentifier: 41, callbackTaskIdentifier: 41, hasActiveTask: false, status: .queued))
        XCTAssertTrue(DirectDownloadResumePolicy.mayStoreResumeData(pendingTaskIdentifier: 41, callbackTaskIdentifier: 41, hasActiveTask: false, status: .paused))
        XCTAssertFalse(DirectDownloadResumePolicy.mayStoreResumeData(pendingTaskIdentifier: 42, callbackTaskIdentifier: 41, hasActiveTask: false, status: .paused))
        XCTAssertFalse(DirectDownloadResumePolicy.mayStoreResumeData(pendingTaskIdentifier: 41, callbackTaskIdentifier: 41, hasActiveTask: true, status: .queued))
        XCTAssertFalse(DirectDownloadResumePolicy.mayStoreResumeData(pendingTaskIdentifier: 41, callbackTaskIdentifier: 41, hasActiveTask: false, status: nil))
    }

    func testProtectedCheckpointSurvivesReloadWithoutPersistingTransport() throws {
        var item = DownloadItem(
            id: "download-resume-test", tmdbId: 1, isMovie: true,
            title: "Movie", displayTitle: "Movie", posterURL: nil,
            seasonNumber: nil, episodeNumber: nil, episodeName: nil,
            streamURL: "https://cdn.example/movie.mkv?token=private",
            headers: ["Authorization": "private"], subtitleURL: nil,
            serviceBaseURL: "https://service.example/private", protectedProviderKind: .service,
            protectedTransportKind: .direct, protectedOwnerProfileID: UUID(),
            episodePlaybackContext: nil, status: .paused, progress: 0.75,
            totalBytes: chunk * 4, downloadedBytes: chunk * 3,
            localFileName: nil, subtitleFileName: nil, error: nil,
            dateAdded: Date(), dateCompleted: nil, isAnime: false
        )
        item.directResumeCheckpoint = try checkpoint(start: chunk * 3, total: chunk * 4)
        let persisted = DownloadManager.persistedDownloadItem(item)
        let data = try JSONEncoder().encode(persisted)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private"))
        let reloaded = try DownloadMetadataPersistencePolicy.decodeAndNormalizeLoadedItems(from: JSONEncoder().encode([persisted])).items
        let restored = try XCTUnwrap(reloaded.first)
        XCTAssertEqual(restored.directResumeCheckpoint, item.directResumeCheckpoint)
        XCTAssertEqual(restored.downloadedBytes, chunk * 3)
        XCTAssertEqual(restored.progress, 0.75)
        XCTAssertEqual(restored.streamURL, "")
        XCTAssertEqual(restored.headers, [:])
        item.directResumeCheckpoint = nil
        item.protectedTransportKind = .hls
        item.hlsResumeManifestSHA256 = String(repeating: "a", count: 64)
        item.hlsResumeSegmentIndex = 2
        item.hlsResumeByteCount = 4
        item.hlsTotalSegments = 3
        item.downloadedBytes = 4
        item.totalBytes = 0
        let hlsData = try JSONEncoder().encode([DownloadManager.persistedDownloadItem(item)])
        let hlsRestored = try XCTUnwrap(DownloadMetadataPersistencePolicy.decodeAndNormalizeLoadedItems(from: hlsData).items.first)
        XCTAssertTrue(hlsRestored.hasVerifiedHLSCheckpoint)
        XCTAssertEqual(hlsRestored.hlsResumeByteCount, 4)
        XCTAssertEqual(hlsRestored.hlsResumeSegmentIndex, 2)
        XCTAssertEqual(hlsRestored.hlsResumeManifestSHA256, item.hlsResumeManifestSHA256)
        XCTAssertFalse(String(decoding: hlsData, as: UTF8.self).contains("private"))
        XCTAssertNil(hlsRestored.resumeLimitationMessage)
        item.hlsResumeManifestSHA256 = nil
        XCTAssertEqual(item.resumeLimitationMessage, "No verified resume checkpoint is available. Continuing restarts this download.")
        item.protectedProviderKind = nil
        item.protectedTransportKind = nil
        item.providerTransportKind = .skyStreamHLS
        XCTAssertFalse(item.claimsProtectedProviderTransport)
        XCTAssertNotNil(item.resumeLimitationMessage)
        item.providerTransportKind = nil
        item.streamURL = "https://cdn.example/playlist.m3u8"
        XCTAssertNil(item.resumeLimitationMessage)
    }

    func testAppendTruncatesUncommittedBytesFromInterruptedWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = directory.appendingPathComponent("partial")
        let chunkURL = directory.appendingPathComponent("chunk")
        try Data("good-uncommitted".utf8).write(to: partial)
        try Data("-resumed".utf8).write(to: chunkURL)
        try DownloadManager.appendDirectChunk(from: chunkURL, to: partial, offset: 4)
        XCTAssertEqual(try Data(contentsOf: partial), Data("good-resumed".utf8))
        XCTAssertThrowsError(try DownloadManager.appendDirectChunk(from: chunkURL, to: partial, offset: 999))
        XCTAssertEqual(try Data(contentsOf: partial), Data("good-resumed".utf8))
    }

    func testAppendBeyondTwoGiBDoesNotOverflowOrReadWholeFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = directory.appendingPathComponent("partial")
        let chunkURL = directory.appendingPathComponent("chunk")
        try Data().write(to: partial)
        let offset: Int64 = 3 * 1024 * 1024 * 1024
        let output = try FileHandle(forWritingTo: partial)
        try output.truncate(atOffset: UInt64(offset))
        try output.close()
        try Data([1, 2, 3]).write(to: chunkURL)
        try DownloadManager.appendDirectChunk(from: chunkURL, to: partial, offset: offset)
        let input = try FileHandle(forReadingFrom: partial)
        defer { try? input.close() }
        XCTAssertEqual(try input.seekToEnd(), UInt64(offset + 3))
        try input.seek(toOffset: UInt64(offset))
        XCTAssertEqual(try input.read(upToCount: 3), Data([1, 2, 3]))
    }

    func testHLSRejectsOutOfBoundsResumeAndMalformedAESBuffers() {
        XCTAssertFalse(HLSDownloader.isValidResumePosition(segment: 100, totalSegments: 2, expectedTotalSegments: 0))
        XCTAssertFalse(HLSDownloader.isValidResumePosition(segment: -1, totalSegments: 2, expectedTotalSegments: 2))
        XCTAssertFalse(HLSDownloader.isValidResumePosition(segment: 1, totalSegments: 2, expectedTotalSegments: 3))
        XCTAssertTrue(HLSDownloader.isValidResumePosition(segment: 2, totalSegments: 2, expectedTotalSegments: 2))
        XCTAssertTrue(HLSDownloader.isValidAES128Material(key: Data(count: 16), iv: Data(count: 16)))
        for count in [0, 1, 15, 17, 64] {
            XCTAssertFalse(HLSDownloader.isValidAES128Material(key: Data(count: count), iv: Data(count: 16)))
            XCTAssertFalse(HLSDownloader.isValidAES128Material(key: Data(count: 16), iv: Data(count: count)))
        }
    }
    func testHLSManifestIdentityCoversUpstreamResourcesKeysAndLayout() throws {
        let upstream = try XCTUnwrap(URL(string: "https://cdn.example/playlist.m3u8"))
        let firstProxy = try XCTUnwrap(URL(string: "http://127.0.0.1:1/attempt-one/master"))
        let secondProxy = try XCTUnwrap(URL(string: "http://127.0.0.1:2/attempt-two/master"))
        func playlist(_ proxy: URL) -> String {
            "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:2\n#EXT-X-KEY:METHOD=AES-128,URI=\"\(proxy.deletingLastPathComponent().appendingPathComponent("key").absoluteString)\",IV=0x00000000000000000000000000000001\n#EXT-X-MAP:URI=\"\(proxy.deletingLastPathComponent().appendingPathComponent("init").absoluteString)\",BYTERANGE=\"100@0\"\n#EXT-X-BYTERANGE:10@100\n\(proxy.deletingLastPathComponent().appendingPathComponent("segment").absoluteString)\n#EXT-X-ENDLIST"
        }
        let canonical: (URL) -> URL? = { url in
            if url.lastPathComponent == "master" { return upstream }
            return URL(string: "https://cdn.example/" + url.lastPathComponent)
        }
        let first = try XCTUnwrap(HLSDownloader.resumeManifestFingerprint(playlist(firstProxy), playlistURL: firstProxy, keyData: Data(count: 16), canonicalURL: canonical))
        XCTAssertEqual(first, HLSDownloader.resumeManifestFingerprint(playlist(secondProxy), playlistURL: secondProxy, keyData: Data(count: 16), canonicalURL: canonical))
        for changed in [
            playlist(secondProxy).replacingOccurrences(of: "10@100", with: "10@101"),
            playlist(secondProxy).replacingOccurrences(of: "100@0", with: "100@1"),
            playlist(secondProxy).replacingOccurrences(of: "SEQUENCE:2", with: "SEQUENCE:3"),
            playlist(secondProxy).replacingOccurrences(of: "ENDLIST", with: "DISCONTINUITY\n#EXT-X-ENDLIST")
        ] {
            XCTAssertNotEqual(first, HLSDownloader.resumeManifestFingerprint(changed, playlistURL: secondProxy, keyData: Data(count: 16), canonicalURL: canonical))
        }
        XCTAssertNotEqual(first, HLSDownloader.resumeManifestFingerprint(playlist(secondProxy), playlistURL: secondProxy, keyData: Data(repeating: 1, count: 16), canonicalURL: canonical))
        XCTAssertNil(HLSDownloader.resumeManifestFingerprint(playlist(firstProxy), playlistURL: firstProxy, keyData: nil, canonicalURL: { $0.lastPathComponent == "key" ? nil : canonical($0) }))
        XCTAssertNil(HLSDownloader.resumeManifestFingerprint("#EXTM3U\nsegment.ts", playlistURL: upstream, keyData: nil))
    }

    @MainActor
    func testHLSPauseAndNewDownloaderContinueVerifiedPartial() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("movie.ts")
        let playlistURL = try XCTUnwrap(URL(string: "https://hls-resume.example/playlist.m3u8"))
        let playlist = "#EXTM3U\n#EXTINF:1,\nfirst.ts\n#EXTINF:1,\nsecond.ts\n#EXTINF:1,\nthird.ts\n#EXT-X-ENDLIST"
        DownloadResumeURLProtocol.configure(playlist: playlist, holdsLastSegment: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadResumeURLProtocol.self]
        let paused = expectation(description: "Old HLS worker finishes cancellation")
        var savedSegments = 0
        var savedBytes: Int64 = 0
        var savedDigest: String?
        let first = HLSDownloader(streamURL: playlistURL, headers: [:], destinationURL: output, downloadId: UUID().uuidString, minimumRequestStartInterval: 0, sessionConfiguration: configuration)
        first.onResumeManifestResolved = { savedDigest = $0 }
        first.onCheckpoint = { segment, bytes in
            savedSegments = segment
            savedBytes = bytes
            if segment == 2 { first.cancel() }
        }
        first.onCompletion = { result in
            if case .success = result { XCTFail("Canceled worker unexpectedly completed") }
            paused.fulfill()
        }
        first.start()
        await fulfillment(of: [paused], timeout: 5)
        XCTAssertEqual(savedSegments, 2)
        XCTAssertEqual(savedBytes, 4)
        let partial = directory.appendingPathComponent(".movie.ts.partial")
        XCTAssertEqual(try Data(contentsOf: partial), Data("AABB".utf8))
        let digest = try XCTUnwrap(savedDigest)
        DownloadResumeURLProtocol.configure(playlist: playlist, holdsLastSegment: false)
        let completed = expectation(description: "Fresh HLS downloader resumes")
        let resumed = HLSDownloader(streamURL: playlistURL, headers: [:], destinationURL: output, downloadId: UUID().uuidString, resumeFromSegment: savedSegments, resumeByteCount: savedBytes, expectedTotalSegments: 3, expectedManifestSHA256: digest, minimumRequestStartInterval: 0, sessionConfiguration: configuration)
        resumed.onCompletion = { result in
            if case .failure(let error) = result { XCTFail("Resume failed: \(error)") }
            completed.fulfill()
        }
        resumed.start()
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: output), Data("AABBCC".utf8))
        XCTAssertEqual(DownloadResumeURLProtocol.requestedPaths(), ["/playlist.m3u8", "/third.ts"])
    }

    @MainActor
    func testHLSLegacyUnverifiedCheckpointDoesNotAppend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("movie.ts")
        let partial = directory.appendingPathComponent(".movie.ts.partial")
        try Data("AABB".utf8).write(to: partial)
        let playlistURL = try XCTUnwrap(URL(string: "https://hls-resume.example/playlist.m3u8"))
        DownloadResumeURLProtocol.configure(playlist: "#EXTM3U\nfirst.ts\nsecond.ts\nthird.ts\n#EXT-X-ENDLIST", holdsLastSegment: false)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadResumeURLProtocol.self]
        let failed = expectation(description: "Unverified legacy checkpoint is refused")
        let downloader = HLSDownloader(streamURL: playlistURL, headers: [:], destinationURL: output, downloadId: UUID().uuidString, resumeFromSegment: 2, resumeByteCount: 4, expectedTotalSegments: 3, minimumRequestStartInterval: 0, sessionConfiguration: configuration)
        downloader.onCompletion = { result in
            if case .success = result { XCTFail("Legacy checkpoint must not be appended without manifest identity") }
            failed.fulfill()
        }
        downloader.start()
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: partial), Data("AABB".utf8))
        XCTAssertEqual(DownloadResumeURLProtocol.requestedPaths(), ["/playlist.m3u8"])
    }

    @MainActor
    func testHLSRefusesMissingSavedBytesWithoutOverwritingPartial() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("movie.ts")
        let partial = directory.appendingPathComponent(".movie.ts.partial")
        try Data("A".utf8).write(to: partial)
        let playlistURL = try XCTUnwrap(URL(string: "https://hls-resume.example/playlist.m3u8"))
        let playlist = "#EXTM3U\nfirst.ts\nsecond.ts\nthird.ts\n#EXT-X-ENDLIST"
        DownloadResumeURLProtocol.configure(playlist: playlist, holdsLastSegment: false)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadResumeURLProtocol.self]
        let failed = expectation(description: "Incomplete checkpoint is refused")
        let downloader = HLSDownloader(streamURL: playlistURL, headers: [:], destinationURL: output, downloadId: UUID().uuidString, resumeFromSegment: 2, resumeByteCount: 4, expectedTotalSegments: 3, expectedManifestSHA256: HLSDownloader.resumeManifestFingerprint(playlist, playlistURL: playlistURL, keyData: nil), minimumRequestStartInterval: 0, sessionConfiguration: configuration)
        downloader.onCompletion = { result in
            guard case .failure(let error) = result,
                  case .resumeCheckpointMissing = error as? HLSError else {
                XCTFail("Expected missing-checkpoint failure")
                failed.fulfill()
                return
            }
            failed.fulfill()
        }
        downloader.start()
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: partial), Data("A".utf8))
        XCTAssertEqual(DownloadResumeURLProtocol.requestedPaths(), ["/playlist.m3u8"])
    }

}

private final class DownloadResumeURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var playlist = ""
    private static var holdsLastSegment = false
    private static var paths: [String] = []

    static func configure(playlist: String, holdsLastSegment: Bool) {
        lock.lock()
        self.playlist = playlist
        self.holdsLastSegment = holdsLastSegment
        paths = []
        lock.unlock()
    }

    static func requestedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.paths.append(url.path)
        let held = Self.holdsLastSegment && url.lastPathComponent == "third.ts"
        let payload: String
        switch url.lastPathComponent {
        case "playlist.m3u8": payload = Self.playlist
        case "first.ts": payload = "AA"
        case "second.ts": payload = "BB"
        default: payload = "CC"
        }
        Self.lock.unlock()
        if held { return }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
