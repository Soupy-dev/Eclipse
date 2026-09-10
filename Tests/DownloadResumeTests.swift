import Foundation
import Combine
import XCTest
@testable import Eclipse

final class DownloadResumeTests: XCTestCase {
    func testEpisodeLookupAvoidsCheckingUnrelatedDownloadFiles() {
        let items = (1...500).map { episodeDownload(id: "other-\($0)", episode: $0) }
        let snapshot = EpisodeDownloadLookupSnapshot(items: items, providerAliasesByTMDBID: [:], revision: 7)
        var checks = 0
        for episode in 501...1500 {
            let result = snapshot.matchingEpisodeDownloadItem(
                tmdbId: 1, seasonNumber: 1, episodeNumber: episode,
                playbackContext: episodeContext(episode: episode)
            ) { _ in
                checks += 1
                return true
            }
            XCTAssertNil(result)
        }
        XCTAssertEqual(checks, 0)
        XCTAssertEqual(snapshot.revision, 7)
    }

    func testEpisodeLookupPreservesLegacyExactAndOrderedFallback() {
        let exactID = DownloadManager.downloadID(tmdbId: 1, isMovie: false, seasonNumber: 1, episodeNumber: 4)
        var exact = episodeDownload(id: exactID, episode: 4)
        exact.episodePlaybackContext = nil
        let fallback = episodeDownload(id: "fallback", episode: 4)
        let later = episodeDownload(id: "later", episode: 4)
        let snapshot = EpisodeDownloadLookupSnapshot(items: [exact, fallback, later], providerAliasesByTMDBID: [:], revision: 0)
        let context = episodeContext(episode: 4, provider: 123)
        XCTAssertEqual(snapshot.matchingEpisodeDownloadItem(
            tmdbId: 1, seasonNumber: 1, episodeNumber: 4, playbackContext: context,
            accepting: { _ in true }
        )?.id, exactID)
        XCTAssertEqual(snapshot.matchingEpisodeDownloadItem(
            tmdbId: 1, seasonNumber: 1, episodeNumber: 4, playbackContext: context,
            accepting: { $0.id != exactID }
        )?.id, "fallback")
    }

    func testEpisodeLookupKeepsProviderAliasesAndCoordinateContradictions() {
        var contradictory = episodeDownload(id: "contradictory", episode: 4)
        contradictory.episodePlaybackContext = episodeContext(episode: 4, provider: 123, tmdbEpisode: 5)
        var aliased = episodeDownload(id: "aliased", episode: 4)
        aliased.episodePlaybackContext = episodeContext(episode: 4, provider: 456)
        let snapshot = EpisodeDownloadLookupSnapshot(
            items: [contradictory, aliased], providerAliasesByTMDBID: [1: [123: 456]], revision: 0
        )
        var checked: [String] = []
        let result = snapshot.matchingEpisodeDownloadItem(
            tmdbId: 1, seasonNumber: 1, episodeNumber: 4,
            playbackContext: episodeContext(episode: 4, provider: 123)
        ) { item in
            checked.append(item.id)
            return true
        }
        XCTAssertEqual(result?.id, "aliased")
        XCTAssertEqual(checked, ["aliased"])
    }

    func testEpisodeLookupDoesNotReplaceFirstAcceptedDuplicateExactID() {
        let exactID = DownloadManager.downloadID(tmdbId: 1, isMovie: false, seasonNumber: 1, episodeNumber: 4)
        var missing = episodeDownload(id: exactID, episode: 4)
        missing.localFileName = "missing.mkv"
        var present = episodeDownload(id: exactID, episode: 4)
        present.localFileName = "present.mkv"
        let snapshot = EpisodeDownloadLookupSnapshot(items: [missing, present], providerAliasesByTMDBID: [:], revision: 0)
        XCTAssertEqual(snapshot.matchingEpisodeDownloadItem(
            tmdbId: 1, seasonNumber: 1, episodeNumber: 4, playbackContext: nil,
            accepting: { $0.localFileName == "present.mkv" }
        )?.localFileName, "present.mkv")
    }

    private func episodeContext(episode: Int, provider: Int? = nil, tmdbEpisode: Int? = nil) -> EpisodePlaybackContext {
        EpisodePlaybackContext(localSeasonNumber: 1, localEpisodeNumber: episode, anilistMediaId: provider,
                               tmdbSeasonNumber: 1, tmdbEpisodeNumber: tmdbEpisode ?? episode,
                               tmdbEpisodeOffset: nil, animeAbsoluteEpisodeNumber: nil,
                               animeSeasonEpisodeCount: nil, isSpecial: false, titleOnlySearch: false)
    }

    private func episodeDownload(id: String, episode: Int) -> DownloadItem {
        DownloadItem(id: id, tmdbId: 1, isMovie: false, title: "Show", displayTitle: "Episode \(episode)",
                     posterURL: nil, seasonNumber: 1, episodeNumber: episode, episodeName: nil,
                     streamURL: "", headers: [:], subtitleURL: nil, serviceBaseURL: "",
                     episodePlaybackContext: episodeContext(episode: episode), status: .completed,
                     progress: 1, totalBytes: 100, downloadedBytes: 100, localFileName: "\(id).mkv",
                     subtitleFileName: nil, error: nil, dateAdded: Date(), dateCompleted: Date(), isAnime: false)
    }

    @MainActor
    func testBackgroundReturnDiscardsOldRefreshWithoutBlockingTheNewAttempt() async throws {
        let fixture = try DownloadLifecycleFixture()
        defer { fixture.cleanUp() }
        let started = expectation(description: "Initial transfer starts")
        fixture.onStart = { _ in started.fulfill() }
        fixture.manager.applicationDidBecomeActive()
        await fulfillment(of: [started], timeout: 3)

        fixture.isActive = false
        fixture.manager.applicationDidEnterBackground()
        XCTAssertEqual(fixture.manager.downloads.first?.status, .queued)
        XCTAssertEqual(fixture.manager.downloads.first?.streamURL, "")

        let firstRefresh = expectation(description: "First foreground refresh")
        fixture.onRefresh = { firstRefresh.fulfill() }
        fixture.isActive = true
        fixture.manager.applicationDidBecomeActive()
        await fulfillment(of: [firstRefresh], timeout: 3)

        fixture.isActive = false
        fixture.manager.applicationDidEnterBackground()
        let secondRefresh = expectation(description: "Fresh foreground operation")
        fixture.onRefresh = { secondRefresh.fulfill() }
        fixture.isActive = true
        fixture.manager.applicationDidBecomeActive()
        await fulfillment(of: [secondRefresh], timeout: 3)

        fixture.resolve(0, url: "https://cdn.example/old.mp4")
        await fixture.settle()
        fixture.manager.applicationDidBecomeActive()
        await fixture.settle()
        XCTAssertEqual(fixture.requestCount, 2)
        XCTAssertEqual(fixture.startedURLs.count, 1)
        XCTAssertEqual(fixture.manager.downloads.first?.status, .queued)
        XCTAssertEqual(fixture.manager.downloads.first?.error, "Refreshing protected download access")

        let resumed = expectation(description: "Current refresh resumes transfer")
        fixture.onStart = { _ in resumed.fulfill() }
        fixture.resolve(1, url: "https://cdn.example/current.mp4")
        await fulfillment(of: [resumed], timeout: 3)
        XCTAssertEqual(fixture.startedURLs.last, "https://cdn.example/current.mp4")
        XCTAssertEqual(fixture.manager.downloads.first?.status, .downloading)
    }

    @MainActor
    func testCancelDuringRefreshAllowsSameEpisodeToBeEnqueuedAgain() async throws {
        let fixture = try DownloadLifecycleFixture(needsRefresh: true)
        defer { fixture.cleanUp() }
        let refreshing = expectation(description: "Refreshing download")
        fixture.onRefresh = { refreshing.fulfill() }
        fixture.manager.applicationDidBecomeActive()
        await fulfillment(of: [refreshing], timeout: 3)
        let oldRevision = fixture.manager.availability.revision
        fixture.manager.cancelDownload(id: fixture.item.id)
        XCTAssertTrue(fixture.manager.downloads.isEmpty)
        XCTAssertGreaterThan(fixture.manager.availability.revision, oldRevision)
        XCTAssertNil(fixture.manager.activeEpisodeDownloadItem(
            tmdbId: fixture.item.tmdbId, seasonNumber: 1, episodeNumber: 1, playbackContext: nil
        ))

        let replacementStarted = expectation(description: "Replacement download starts")
        fixture.onStart = { _ in replacementStarted.fulfill() }
        let outcome = await fixture.manager.enqueueDownload(
            tmdbId: fixture.item.tmdbId, isMovie: false, title: "Lifecycle fixture",
            displayTitle: "Episode 1", posterURL: nil, seasonNumber: 1, episodeNumber: 1,
            episodeName: nil, streamURL: "https://cdn.example/replacement.mp4", headers: [:],
            subtitleURL: nil, serviceBaseURL: "https://animepahe.example",
            lastSourceId: fixture.item.lastSourceId,
            lastContentReference: fixture.item.lastContentReference, isAnime: true
        )
        guard case .enqueued = outcome else { return XCTFail("Cancelled episode was not admitted again") }
        await fulfillment(of: [replacementStarted], timeout: 3)
        fixture.resolve(0, url: "https://cdn.example/stale.mp4")
        await fixture.settle()
        XCTAssertEqual(fixture.startedURLs, ["https://cdn.example/replacement.mp4"])
        XCTAssertEqual(fixture.manager.downloads.first?.status, .downloading)
        XCTAssertEqual(fixture.manager.downloads.first?.streamURL, "https://cdn.example/replacement.mp4")
    }

    @MainActor
    func testQueuedDownloadCanPauseAndResumeWhileAccessIsRefreshing() async throws {
        let fixture = try DownloadLifecycleFixture(needsRefresh: true)
        defer { fixture.cleanUp() }
        let first = expectation(description: "Refresh begins")
        fixture.onRefresh = { first.fulfill() }
        fixture.manager.applicationDidBecomeActive()
        await fulfillment(of: [first], timeout: 3)
        fixture.manager.pauseDownload(id: fixture.item.id)
        XCTAssertEqual(fixture.manager.downloads.first?.status, .paused)
        fixture.resolve(0, url: "https://cdn.example/stale.mp4")
        await fixture.settle()
        XCTAssertEqual(fixture.manager.downloads.first?.status, .paused)
        XCTAssertTrue(fixture.startedURLs.isEmpty)

        let second = expectation(description: "Manual resume refreshes again")
        fixture.onRefresh = { second.fulfill() }
        fixture.manager.resumeDownload(id: fixture.item.id)
        await fulfillment(of: [second], timeout: 3)
        let resumed = expectation(description: "Resumed transfer starts")
        fixture.onStart = { _ in resumed.fulfill() }
        fixture.resolve(1, url: "https://cdn.example/resumed.mp4")
        await fulfillment(of: [resumed], timeout: 3)
    }

    @MainActor
    func testFailedForegroundRefreshOffersRetryInsteadOfAnEndlessQueue() async throws {
        let fixture = try DownloadLifecycleFixture(needsRefresh: true)
        defer { fixture.cleanUp() }
        let refreshing = expectation(description: "Foreground refresh begins")
        fixture.onRefresh = { refreshing.fulfill() }
        fixture.manager.applicationDidBecomeActive()
        await fulfillment(of: [refreshing], timeout: 3)
        let failed = expectation(description: "Download becomes retryable")
        let observation = fixture.manager.$downloads.map { $0.first?.status }.removeDuplicates().sink { status in
            if status == .failed { failed.fulfill() }
        }
        fixture.resolve(0, url: nil)
        await fulfillment(of: [failed], timeout: 3)
        observation.cancel()
        await fixture.settle()
        XCTAssertNil(fixture.manager.downloads.first?.retryNotBefore)
        XCTAssertEqual(fixture.manager.downloads.first?.error, "The provider could not refresh this download. Retry, or remove it and select the episode's source again.")

        let retry = expectation(description: "Retry begins new resolution")
        fixture.onRefresh = { retry.fulfill() }
        fixture.manager.resumeDownload(id: fixture.item.id)
        await fulfillment(of: [retry], timeout: 3)
        let started = expectation(description: "Retry starts transfer")
        fixture.onStart = { _ in started.fulfill() }
        fixture.resolve(1, url: "https://cdn.example/retry.mp4")
        await fulfillment(of: [started], timeout: 3)
    }

    func testDownloadAvailabilityPublishesStatusAndRemovalButNotByteProgress() {
        let availability = DownloadAvailability()
        var item = episodeDownload(id: "availability", episode: 1)
        item.status = .downloading
        availability.update(from: [], to: [item])
        let initialRevision = availability.revision
        var progressed = item
        progressed.progress = 0.4
        progressed.downloadedBytes = 40
        availability.update(from: [item], to: [progressed])
        XCTAssertEqual(availability.revision, initialRevision)
        var paused = progressed
        paused.status = .paused
        availability.update(from: [progressed], to: [paused])
        XCTAssertEqual(availability.revision, initialRevision + 1)
        availability.update(from: [paused], to: [])
        XCTAssertEqual(availability.revision, initialRevision + 2)
    }

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

    func testHLSSelectsMuxedAudioVariantAndPreservesInBandAudioGroups() throws {
        let base = try XCTUnwrap(URL(string: "https://hls-resume.example/playlist.m3u8"))
        let downloader = HLSDownloader(streamURL: base, headers: [:], destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), downloadId: UUID().uuidString)
        let external = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio,main\",NAME=\"English\",URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=9000000,AUDIO=\"audio,main\",RESOLUTION=1920x1080\nvideo.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720\nmuxed.m3u8"
        let variants = downloader.parseMasterPlaylist(external, baseURL: base)
        XCTAssertEqual(variants.count, 2)
        XCTAssertTrue(variants[0].requiresExternalAudio)
        XCTAssertEqual(downloader.selectBestVariant(variants)?.url.lastPathComponent, "muxed.m3u8")
        let inBand = external.replacingOccurrences(of: ",URI=\"audio.m3u8\"", with: "")
        XCTAssertEqual(downloader.selectBestVariant(downloader.parseMasterPlaylist(inBand, baseURL: base))?.url.lastPathComponent, "video.m3u8")
        XCTAssertNil(HLSDownloadCompatibility.unsupportedMediaLayout(in: "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:1,\nsegment.m4s\n#EXT-X-ENDLIST"))
    }

    @MainActor
    func testHLSUnsupportedRangesPreservePartialAndNeverFetchWholeResource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("movie.ts")
        let partial = directory.appendingPathComponent(".movie.ts.partial")
        let bytes = Data("saved partial".utf8)
        try bytes.write(to: partial)
        let base = try XCTUnwrap(URL(string: "https://hls-resume.example/playlist.m3u8"))
        for layout in ["#EXT-X-BYTERANGE:4@0", "#EXT-X-MAP:URI=\"init.mp4\",BYTERANGE=\"4@0\""] {
            DownloadResumeURLProtocol.configure(playlist: "#EXTM3U\n\(layout)\n#EXTINF:1,\nfirst.ts\n#EXT-X-ENDLIST", holdsLastSegment: false)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DownloadResumeURLProtocol.self]
            let stopped = expectation(description: "Unsupported range is refused before media transfer")
            let downloader = HLSDownloader(streamURL: base, headers: [:], destinationURL: output, downloadId: UUID().uuidString, resumeFromSegment: 1, resumeByteCount: Int64(bytes.count), pinnedVariantURL: base, minimumRequestStartInterval: 0, sessionConfiguration: configuration)
            downloader.onCompletion = { result in
                guard case .failure(let error) = result, case .unsupportedLayout = error as? HLSError else {
                    XCTFail("Expected a visible unsupported-layout error")
                    stopped.fulfill()
                    return
                }
                stopped.fulfill()
            }
            downloader.start()
            await fulfillment(of: [stopped], timeout: 5)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try Data(contentsOf: partial), bytes)
            XCTAssertTrue(DownloadResumeURLProtocol.requestedPaths().allSatisfy { $0 == "/playlist.m3u8" })
        }
    }

    @MainActor
    func testHLSPinnedVariantCannotResumeWithoutItsSeparateAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("movie.ts")
        let partial = directory.appendingPathComponent(".movie.ts.partial")
        let bytes = Data("saved partial".utf8)
        try bytes.write(to: partial)
        let base = try XCTUnwrap(URL(string: "https://hls-resume.example/playlist.m3u8"))
        let pinned = try XCTUnwrap(URL(string: "video.m3u8", relativeTo: base)?.absoluteURL)
        DownloadResumeURLProtocol.configure(playlist: "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO=\"a\"\nvideo.m3u8", holdsLastSegment: false)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadResumeURLProtocol.self]
        let stopped = expectation(description: "Pinned external audio layout is refused")
        let downloader = HLSDownloader(streamURL: base, headers: [:], destinationURL: output, downloadId: UUID().uuidString, resumeFromSegment: 1, resumeByteCount: Int64(bytes.count), pinnedVariantURL: pinned, minimumRequestStartInterval: 0, sessionConfiguration: configuration)
        downloader.onCompletion = { result in
            guard case .failure(let error) = result, case .unsupportedLayout = error as? HLSError else {
                XCTFail("Expected a visible unsupported-layout error")
                stopped.fulfill()
                return
            }
            stopped.fulfill()
        }
        downloader.start()
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(DownloadResumeURLProtocol.requestedPaths(), ["/playlist.m3u8"])
        XCTAssertEqual(try Data(contentsOf: partial), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
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

@MainActor
private final class DownloadLifecycleFixture {
    let root: URL
    let item: DownloadItem
    var isActive = true
    var onStart: ((DownloadItem) -> Void)?
    var onRefresh: (() -> Void)?
    var startedURLs: [String] = []
    var requestCount = 0
    private var pending: [Int: CheckedContinuation<DownloadManager.RefreshedDownloadSource?, Never>] = [:]
    private(set) lazy var manager = DownloadManager(
        downloadsDirectory: root, initialDownloads: [item],
        transportMayStart: { [weak self] in self?.isActive == true },
        refreshSource: { [weak self] _ in
            guard let self else { return nil }
            return await withCheckedContinuation { continuation in
                let index = self.requestCount
                self.requestCount += 1
                self.pending[index] = continuation
                self.onRefresh?()
            }
        },
        transferStarter: { [weak self] item in
            self?.startedURLs.append(item.streamURL)
            self?.onStart?(item)
        }
    )

    init(needsRefresh: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceID = "service:download-lifecycle-fixture"
        let tmdbID = 1_937_467_211
        item = DownloadItem(
            id: DownloadManager.downloadID(tmdbId: tmdbID, isMovie: false, seasonNumber: 1, episodeNumber: 1),
            tmdbId: tmdbID, isMovie: false, title: "Lifecycle fixture", displayTitle: "Episode 1",
            posterURL: nil, seasonNumber: 1, episodeNumber: 1, episodeName: nil,
            streamURL: needsRefresh ? "" : "https://cdn.example/initial.mp4", headers: [:],
            subtitleURL: nil, serviceBaseURL: "https://animepahe.example",
            lastSourceId: sourceID,
            lastContentReference: .service(sourceID: sourceID, href: "https://animepahe.example/episode"),
            protectedProviderKind: .service, protectedTransportKind: .direct,
            protectedOwnerProfileID: ProfileManager.shared.activeProfileID,
            status: .queued, progress: 0, totalBytes: 0, downloadedBytes: 0,
            localFileName: nil, subtitleFileName: nil, error: nil, dateAdded: Date(), dateCompleted: nil,
            isAnime: true
        )
    }

    func resolve(_ index: Int, url: String?) {
        let source = url.flatMap(URL.init(string:)).map {
            DownloadManager.RefreshedDownloadSource(
                transport: .direct(url: $0, headers: [:], expectedContentLength: nil),
                streamName: nil, subtitleURL: nil, subtitleHeaders: nil,
                serviceContentHref: "https://animepahe.example/episode",
                lastSourceId: "service:download-lifecycle-fixture",
                lastContentReference: .service(sourceID: "service:download-lifecycle-fixture", href: "https://animepahe.example/episode")
            )
        }
        pending.removeValue(forKey: index)?.resume(returning: source)
    }

    func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    func cleanUp() {
        manager.cancelAllActive()
        for continuation in pending.values { continuation.resume(returning: nil) }
        pending.removeAll()
        manager.finishIsolatedSession()
        try? FileManager.default.removeItem(at: root)
    }
}

final class DownloadAuditRegressionTests: XCTestCase {
    private func item(_ id: Int, isMovie: Bool = false) -> DownloadItem {
        let identifier = DownloadManager.downloadID(tmdbId: id, isMovie: isMovie, seasonNumber: isMovie ? nil : 1, episodeNumber: isMovie ? nil : 1)
        return DownloadItem(id: identifier, tmdbId: id, isMovie: isMovie, title: "Fixture", displayTitle: "Fixture", posterURL: nil, seasonNumber: isMovie ? nil : 1, episodeNumber: isMovie ? nil : 1, episodeName: nil, streamURL: "https://example.invalid/video.mp4", headers: [:], subtitleURL: nil, serviceBaseURL: "", status: .completed, progress: 1, totalBytes: 32, downloadedBytes: 32, localFileName: "\(identifier).mp4", subtitleFileName: nil, error: nil, dateAdded: Date(), dateCompleted: Date(), isAnime: false)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    private func manager(_ directory: URL, items: [DownloadItem] = [], load: Bool = false) -> DownloadManager {
        DownloadManager(downloadsDirectory: directory, initialDownloads: items, transportMayStart: { false }, refreshSource: { _ in nil }, transferStarter: { _ in XCTFail("A refused or paused admission must not start transport") }, loadPersistedMetadata: load)
    }

    @MainActor
    private func enqueue(_ manager: DownloadManager, id: Int) async -> DownloadEnqueueResult {
        await manager.enqueueDownload(tmdbId: id, isMovie: false, title: "Fixture", displayTitle: "Fixture", posterURL: nil, seasonNumber: 1, episodeNumber: 1, episodeName: nil, streamURL: "https://example.invalid/video.mp4", headers: [:], subtitleURL: nil, serviceBaseURL: "", isAnime: false)
    }

    func testSyntheticSeasonAndProviderIdentitySurvivePersistence() throws {
        for provider in [42, -42, ProgressPersistencePolicy.maximumIdentifier, -ProgressPersistencePolicy.maximumIdentifier] {
            var value = item(42)
            let season = try XCTUnwrap(AnimeSyntheticSeasonKey.make(providerID: provider))
            value.seasonNumber = season
            value.episodePlaybackContext = EpisodePlaybackContext(localSeasonNumber: season, localEpisodeNumber: 1, anilistMediaId: provider, tmdbSeasonNumber: nil, tmdbEpisodeNumber: nil, tmdbEpisodeOffset: nil, animeAbsoluteEpisodeNumber: nil, animeSeasonEpisodeCount: nil, isSpecial: false, titleOnlySearch: true)
            let normalized = try DownloadMetadataPersistencePolicy.decodeAndNormalizeLoadedItems(from: JSONEncoder().encode([value]))
            XCTAssertEqual(normalized.items.first?.seasonNumber, season)
            XCTAssertEqual(normalized.items.first?.episodePlaybackContext?.localSeasonNumber, season)
            XCTAssertEqual(normalized.items.first?.episodePlaybackContext?.anilistMediaId, provider)
            XCTAssertFalse(normalized.hasUnreadableItems)
        }
    }

    @MainActor
    func testUnreadableIndexPreservesBytesAndFilesUntilSuccessfulRetry() async throws {
        let root = try directory()
        let index = root.appendingPathComponent(".downloads_metadata.json")
        let partial = root.appendingPathComponent("unclaimed.partial")
        let original = Data("broken index".utf8)
        try original.write(to: index)
        try Data(repeating: 7, count: 32).write(to: partial)
        let downloads = manager(root, load: true)
        defer { downloads.finishIsolatedSession() }
        XCTAssertTrue(downloads.metadataLoadFailed)
        if case .failed = await enqueue(downloads, id: 77) {} else { XCTFail("Unknown index must reject admission") }
        downloads.deleteAllCompleted()
        XCTAssertEqual(try Data(contentsOf: index), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        try JSONEncoder().encode([item(42)]).write(to: index, options: .atomic)
        downloads.retryLoadingDownloadMetadata()
        XCTAssertFalse(downloads.metadataLoadFailed)
        XCTAssertEqual(downloads.downloads.map(\.tmdbId), [42])
    }

    @MainActor
    func testPartiallyDecodedIndexDoesNotAuthorizeReplacement() async throws {
        let root = try directory()
        let index = root.appendingPathComponent(".downloads_metadata.json")
        let valid = try JSONEncoder().encode(item(42))
        var original = Data("[".utf8)
        original.append(valid)
        original.append(Data(",{}]".utf8))
        try original.write(to: index)
        let downloads = manager(root, load: true)
        defer { downloads.finishIsolatedSession() }
        XCTAssertTrue(downloads.metadataLoadFailed)
        if case .failed = await enqueue(downloads, id: 77) {} else { XCTFail("Partial recovery must reject admission") }
        XCTAssertEqual(try Data(contentsOf: index), original)
    }

    @MainActor
    func testFullIndexRejectsAdmissionWithoutPublishingAnUndurableRow() async throws {
        let root = try directory()
        let items = (1...DownloadMetadataPersistencePolicy.Bounds.items).map { item($0) }
        let index = root.appendingPathComponent(".downloads_metadata.json")
        let original = try JSONEncoder().encode(items)
        try original.write(to: index)
        let downloads = manager(root, items: items)
        defer { downloads.finishIsolatedSession() }
        if case .failed = await enqueue(downloads, id: 2001) {} else { XCTFail("Full index must reject admission") }
        XCTAssertEqual(downloads.downloads.count, 2000)
        XCTAssertFalse(downloads.downloads.contains { $0.tmdbId == 2001 })
        XCTAssertEqual(try Data(contentsOf: index), original)
    }

    @MainActor
    func testFailedRetryPreservesExistingRowAndFileWhenSavingFails() async throws {
        let root = try directory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".downloads_metadata.json"), withIntermediateDirectories: false)
        var prior = item(42)
        prior.status = .failed
        prior.error = "Retry fixture"
        let file = root.appendingPathComponent(try XCTUnwrap(prior.localFileName))
        let bytes = Data(repeating: 9, count: 32)
        try bytes.write(to: file)
        let downloads = manager(root, items: [prior])
        defer { downloads.finishIsolatedSession() }
        if case .failed = await enqueue(downloads, id: 42) {} else { XCTFail("Unwritable index must reject retry") }
        XCTAssertEqual(downloads.downloads.first?.status, .failed)
        XCTAssertEqual(downloads.downloads.first?.error, prior.error)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    @MainActor
    func testDeletingSeriesPreservesMovieWithSameNumericID() throws {
        let root = try directory()
        let movie = item(42, isMovie: true)
        let series = item(42)
        let movieFile = root.appendingPathComponent(try XCTUnwrap(movie.localFileName))
        try Data(repeating: 1, count: 32).write(to: movieFile)
        let downloads = manager(root, items: [movie, series])
        defer { downloads.finishIsolatedSession() }
        downloads.deleteAllForShow(tmdbId: 42)
        XCTAssertEqual(downloads.downloads.map(\.id), [movie.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: movieFile.path))
    }
}

private final class DownloadAdmissionAuditGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var count = 0
    private var startedOnMain = false
    let started: XCTestExpectation

    init(started: XCTestExpectation) { self.started = started }

    func prepare() {
        lock.lock()
        count += 1
        let first = count == 1
        startedOnMain = startedOnMain || Thread.isMainThread
        lock.unlock()
        if first {
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
    }

    func open() { release.signal() }

    var preparationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var usedMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return startedOnMain
    }
}

extension DownloadAuditRegressionTests {
    @MainActor
    private func gatedManager(_ root: URL, items: [DownloadItem] = [], gate: DownloadAdmissionAuditGate, scope: (() -> Int)? = nil) -> DownloadManager {
        DownloadManager(downloadsDirectory: root, initialDownloads: items, transportMayStart: { false }, refreshSource: { _ in nil }, transferStarter: { _ in }, admissionPreparation: { gate.prepare() }, admissionScopeGeneration: scope)
    }

    @MainActor
    func testAdmissionDoesNotResurrectRetryDeletedDuringPreparation() async throws {
        let root = try directory()
        var prior = item(42)
        prior.status = .failed
        let gate = DownloadAdmissionAuditGate(started: expectation(description: "Admission prepares away from main"))
        let downloads = gatedManager(root, items: [prior], gate: gate)
        defer { gate.open(); downloads.finishIsolatedSession() }
        let pending = Task { await enqueue(downloads, id: 42) }
        await fulfillment(of: [gate.started], timeout: 3)
        XCTAssertFalse(gate.usedMainThread)
        downloads.removeDownload(id: prior.id, deleteFile: false)
        gate.open()
        if case .failed = await pending.value {} else { XCTFail("Deleted retry must stay deleted") }
        await downloads.drainIsolatedPersistence()
        XCTAssertTrue(downloads.downloads.isEmpty)
        let stored = try JSONDecoder().decode([DownloadItem].self, from: Data(contentsOf: root.appendingPathComponent(".downloads_metadata.json")))
        XCTAssertTrue(stored.isEmpty)
    }

    @MainActor
    func testAdmissionRetriesUnrelatedRemovalAndKeepsLatestIndex() async throws {
        let root = try directory()
        let prior = item(42)
        let gate = DownloadAdmissionAuditGate(started: expectation(description: "First immutable snapshot captured"))
        let downloads = gatedManager(root, items: [prior], gate: gate)
        defer { gate.open(); downloads.finishIsolatedSession() }
        let pending = Task { await enqueue(downloads, id: 77) }
        await fulfillment(of: [gate.started], timeout: 3)
        downloads.removeDownload(id: prior.id, deleteFile: false)
        gate.open()
        if case .enqueued = await pending.value {} else { XCTFail("Unrelated mutation should rebuild the admission") }
        await downloads.drainIsolatedPersistence()
        XCTAssertEqual(gate.preparationCount, 2)
        XCTAssertEqual(downloads.downloads.map(\.tmdbId), [77])
        let stored = try JSONDecoder().decode([DownloadItem].self, from: Data(contentsOf: root.appendingPathComponent(".downloads_metadata.json")))
        XCTAssertEqual(stored.map(\.tmdbId), [77])
    }

    @MainActor
    func testAdmissionKeepsFrequentProgressWithoutRestartingPreparation() async throws {
        let root = try directory()
        var first = item(41)
        var second = item(42)
        first.status = .downloading
        second.status = .downloading
        let gate = DownloadAdmissionAuditGate(started: expectation(description: "Large snapshot preparation suspended"))
        let downloads = gatedManager(root, items: [first, second], gate: gate)
        defer { gate.open(); downloads.finishIsolatedSession() }
        let pending = Task { await enqueue(downloads, id: 77) }
        await fulfillment(of: [gate.started], timeout: 3)
        for step in 1...100 {
            downloads.updateObservedDownloadProgress(id: first.id, progress: Double(step) / 100, downloadedBytes: Int64(step), totalBytes: 100)
            downloads.updateObservedDownloadProgress(id: second.id, progress: Double(step) / 200, downloadedBytes: Int64(step), totalBytes: 200, hlsResumeSegmentIndex: step, hlsResumeByteCount: Int64(step))
        }
        gate.open()
        if case .enqueued = await pending.value {} else { XCTFail("Progress observations must not starve admission") }
        await downloads.drainIsolatedPersistence()
        XCTAssertEqual(gate.preparationCount, 1)
        XCTAssertEqual(downloads.downloads.first(where: { $0.id == first.id })?.downloadedBytes, 100)
        XCTAssertEqual(downloads.downloads.first(where: { $0.id == second.id })?.hlsResumeSegmentIndex, 100)
        let stored = try JSONDecoder().decode([DownloadItem].self, from: Data(contentsOf: root.appendingPathComponent(".downloads_metadata.json")))
        XCTAssertEqual(stored.first(where: { $0.id == first.id })?.downloadedBytes, 100)
        XCTAssertEqual(stored.first(where: { $0.id == second.id })?.hlsResumeSegmentIndex, 100)
        XCTAssertEqual(Set(stored.map(\.tmdbId)), [41, 42, 77])
    }

    @MainActor
    func testAdmissionRejectsScopeABAWithoutWriting() async throws {
        let root = try directory()
        var generation = 0
        let gate = DownloadAdmissionAuditGate(started: expectation(description: "Captured original scope"))
        let downloads = gatedManager(root, gate: gate, scope: { generation })
        defer { gate.open(); downloads.finishIsolatedSession() }
        let pending = Task { await enqueue(downloads, id: 77) }
        await fulfillment(of: [gate.started], timeout: 3)
        generation += 2
        gate.open()
        if case .failed = await pending.value {} else { XCTFail("A to B to A must expire captured admission") }
        XCTAssertTrue(downloads.downloads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".downloads_metadata.json").path))
    }

    @MainActor
    func testCancelledAdmissionNeverPublishesOrStartsTransport() async throws {
        let root = try directory()
        let gate = DownloadAdmissionAuditGate(started: expectation(description: "Cancellable preparation started"))
        let downloads = gatedManager(root, gate: gate)
        defer { gate.open(); downloads.finishIsolatedSession() }
        let pending = Task { await enqueue(downloads, id: 77) }
        await fulfillment(of: [gate.started], timeout: 3)
        pending.cancel()
        gate.open()
        if case .failed = await pending.value {} else { XCTFail("Cancelled preparation must refuse publication") }
        XCTAssertTrue(downloads.downloads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".downloads_metadata.json").path))
    }

    @MainActor
    func testCancelOfUnpublishedIDPreventsLaterAdmission() async throws {
        let root = try directory()
        let gate = DownloadAdmissionAuditGate(started: expectation(description: "Unpublished admission preparing"))
        let downloads = gatedManager(root, gate: gate)
        defer { gate.open(); downloads.finishIsolatedSession() }
        let pending = Task { await enqueue(downloads, id: 77) }
        await fulfillment(of: [gate.started], timeout: 3)
        downloads.cancelDownload(id: DownloadManager.downloadID(tmdbId: 77, isMovie: false, seasonNumber: 1, episodeNumber: 1))
        gate.open()
        if case .failed = await pending.value {} else { XCTFail("Explicit cancellation must expire unpublished admission") }
        await downloads.drainIsolatedPersistence()
        XCTAssertTrue(downloads.downloads.isEmpty)
    }

    @MainActor
    func testConcurrentAdoptionsCannotShareOneVideoFile() async throws {
        let root = try directory()
        let folder = root.appendingPathComponent("Fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("S01E01.mp4")
        try Data(repeating: 1, count: 32).write(to: file)
        let gate = DownloadAdmissionAuditGate(started: expectation(description: "First adoption preparing"))
        let secondCaptured = expectation(description: "Second adoption captured same unowned file")
        var scopeReads = 0
        let downloads = gatedManager(root, gate: gate, scope: {
            scopeReads += 1
            if scopeReads == 4 { secondCaptured.fulfill() }
            return 0
        })
        defer { gate.open(); downloads.finishIsolatedSession() }
        let first = Task { await enqueue(downloads, id: 42) }
        await fulfillment(of: [gate.started], timeout: 3)
        let second = Task { await enqueue(downloads, id: 77) }
        await fulfillment(of: [secondCaptured], timeout: 3)
        gate.open()
        let outcomes = await [first.value, second.value]
        XCTAssertEqual(outcomes.filter { if case .adoptedExistingFile = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(outcomes.filter { if case .failed = $0 { return true }; return false }.count, 1)
        await downloads.drainIsolatedPersistence()
        XCTAssertEqual(downloads.downloads.count, 1)
        XCTAssertEqual(downloads.downloads.first?.localFileName, "Fixture/S01E01.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let stored = try JSONDecoder().decode([DownloadItem].self, from: Data(contentsOf: root.appendingPathComponent(".downloads_metadata.json")))
        XCTAssertEqual(stored.count, 1)
    }

    @MainActor
    func testAdmissionRefusesAdoptedFileRemovedDuringPreparation() async throws {
        let root = try directory()
        let prior = item(42)
        let file = root.appendingPathComponent(try XCTUnwrap(prior.localFileName))
        try Data(repeating: 1, count: 32).write(to: file)
        let gate = DownloadAdmissionAuditGate(started: expectation(description: "Adoption snapshot captured"))
        let downloads = gatedManager(root, gate: gate)
        defer { gate.open(); downloads.finishIsolatedSession() }
        let pending = Task { await enqueue(downloads, id: 42) }
        await fulfillment(of: [gate.started], timeout: 3)
        try FileManager.default.removeItem(at: file)
        gate.open()
        if case .failed = await pending.value {} else { XCTFail("A disappeared file cannot be adopted") }
        XCTAssertTrue(downloads.downloads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".downloads_metadata.json").path))
    }

    @MainActor
    func testQueuedOldSnapshotCannotEraseCommittedAdmission() async throws {
        let root = try directory()
        let gate = DownloadAdmissionAuditGate(started: expectation(description: "Admission precedes queued ordinary save"))
        let downloads = gatedManager(root, gate: gate)
        defer { gate.open(); downloads.finishIsolatedSession() }
        let pending = Task { await enqueue(downloads, id: 77) }
        await fulfillment(of: [gate.started], timeout: 3)
        downloads.pauseAll()
        gate.open()
        if case .enqueued = await pending.value {} else { XCTFail("Admission should survive an unchanged queued save") }
        await downloads.drainIsolatedPersistence()
        let stored = try JSONDecoder().decode([DownloadItem].self, from: Data(contentsOf: root.appendingPathComponent(".downloads_metadata.json")))
        XCTAssertEqual(stored.map(\.tmdbId), [77])
    }
}
