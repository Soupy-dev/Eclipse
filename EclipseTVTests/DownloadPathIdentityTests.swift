import XCTest
@testable import Eclipse

final class DownloadPathIdentityTests: XCTestCase {
    func testMovieRemakesReserveDistinctHumanReadablePaths() {
        let first = owner(
            id: "movie-1",
            identity: "movie:tmdb:1091",
            isMovie: true,
            paths: ["The Thing.mkv"]
        )
        let remake = request(
            id: "movie-2",
            identity: "movie:tmdb:1092",
            tmdbID: 1092,
            isMovie: true,
            base: "The Thing"
        )

        XCTAssertEqual(
            DownloadPathIdentityPolicy.allocateVideoRelativePath(
                request: remake,
                owners: [first],
                fileExtension: "mp4"
            ),
            "The Thing [TMDB 1092].mp4"
        )
    }

    func testSameTitleShowsSeparateAtFolderEvenForSameEpisodeCode() {
        let original = owner(
            id: "show-1-s1e1",
            identity: "show:tmdb:100",
            isMovie: false,
            paths: ["Example/S01E01 - Pilot.mp4"]
        )
        let remake = request(
            id: "show-2-s1e1",
            identity: "show:tmdb:200",
            tmdbID: 200,
            isMovie: false,
            base: "Example",
            episode: "S01E01 - Pilot"
        )

        XCTAssertEqual(
            DownloadPathIdentityPolicy.allocateVideoRelativePath(
                request: remake,
                owners: [original],
                fileExtension: "mp4"
            ),
            "Example [TMDB 200]/S01E01 - Pilot.mp4"
        )
    }

    func testSameShowKeepsOneFolderForDifferentEpisodes() {
        let firstEpisode = owner(
            id: "show-1-s1e1",
            identity: "show:tmdb:100",
            isMovie: false,
            paths: ["Example/S01E01 - Pilot.mp4"]
        )
        let secondEpisode = request(
            id: "show-1-s1e2",
            identity: "show:tmdb:100",
            tmdbID: 100,
            isMovie: false,
            base: "Example",
            episode: "S01E02 - Second"
        )

        XCTAssertEqual(
            DownloadPathIdentityPolicy.allocateVideoRelativePath(
                request: secondEpisode,
                owners: [firstEpisode],
                fileExtension: "mp4"
            ),
            "Example/S01E02 - Second.mp4"
        )
    }

    func testCaseAndEightyCharacterCollisionsRetainIdentitySuffix() {
        let owner = owner(
            id: "movie-owner",
            identity: "movie:tmdb:1",
            isMovie: true,
            paths: [String(repeating: "A", count: 80) + ".mp4"]
        )
        let contender = request(
            id: "movie-contender",
            identity: "movie:tmdb:2",
            tmdbID: 2,
            isMovie: true,
            base: String(repeating: "a", count: 80)
        )
        let path = DownloadPathIdentityPolicy.allocateVideoRelativePath(
            request: contender,
            owners: [owner],
            fileExtension: "mp4"
        )
        let stem = (path as NSString).deletingPathExtension

        XCTAssertLessThanOrEqual(stem.count, 80)
        XCTAssertTrue(stem.hasSuffix("[TMDB 2]"))
    }

    func testSanitizedEquivalentNamesCollideAfterNormalization() {
        let first = owner(
            id: "movie-1",
            identity: "movie:tmdb:1",
            isMovie: true,
            paths: ["Same Title.mp4"]
        )
        let contender = request(
            id: "movie-2",
            identity: "movie:tmdb:2",
            tmdbID: 2,
            isMovie: true,
            base: "same title"
        )

        XCTAssertEqual(
            DownloadPathIdentityPolicy.allocateVideoRelativePath(
                request: contender,
                owners: [first],
                fileExtension: "mp4"
            ),
            "same title [TMDB 2].mp4"
        )
    }

    func testNoTMDBFallbackIsStable() {
        let first = owner(
            id: "legacy-a",
            identity: "movie:id:legacy-a",
            isMovie: true,
            paths: ["Unknown.mp4"]
        )
        let contender = request(
            id: "legacy-b",
            identity: "movie:id:legacy-b",
            tmdbID: 0,
            isMovie: true,
            base: "Unknown"
        )

        let firstResult = DownloadPathIdentityPolicy.allocateVideoRelativePath(
            request: contender,
            owners: [first],
            fileExtension: "mp4"
        )
        let secondResult = DownloadPathIdentityPolicy.allocateVideoRelativePath(
            request: contender,
            owners: [first],
            fileExtension: "mp4"
        )

        XCTAssertEqual(firstResult, secondResult)
        XCTAssertTrue(firstResult.contains("[ID "))
    }

    func testHLSPartialAndSubtitleDeriveFromReservedIdentity() {
        let videoPath = "Example [TMDB 200]/S01E01 - Pilot.ts"

        XCTAssertEqual(
            DownloadPathIdentityPolicy.hlsPartialRelativePath(videoRelativePath: videoPath),
            "Example [TMDB 200]/.S01E01 - Pilot.ts.partial"
        )
        XCTAssertEqual(
            DownloadPathIdentityPolicy.subtitleRelativePath(
                videoRelativePath: videoPath,
                fileExtension: "srt"
            ),
            "Example [TMDB 200]/S01E01 - Pilot.sub.srt"
        )
    }

    func testAdoptionClaimIsCaseInsensitiveAndCanOnlyBeClaimedOnce() {
        let claimed = owner(
            id: "movie-1",
            identity: "movie:tmdb:1",
            isMovie: true,
            paths: ["Alien.mp4", "Alien.sub.srt"]
        )

        XCTAssertTrue(
            DownloadPathIdentityPolicy.exactPathIsAvailable(
                "alien.MP4",
                claimantID: claimed.id,
                owners: [claimed]
            )
        )
        XCTAssertFalse(
            DownloadPathIdentityPolicy.exactPathIsAvailable(
                "alien.MP4",
                claimantID: "movie-2",
                owners: [claimed]
            )
        )
        XCTAssertFalse(
            DownloadPathIdentityPolicy.exactPathIsAvailable(
                "ALIEN.SUB.SRT",
                claimantID: "movie-2",
                owners: [claimed]
            )
        )
    }

    func testMigrationCollisionAllocatesWithoutReplacingTrackedPath() {
        let tracked = owner(
            id: "movie-1",
            identity: "movie:tmdb:1",
            isMovie: true,
            paths: ["Crash.mp4"]
        )
        let migrating = request(
            id: "movie-2",
            identity: "movie:tmdb:2",
            tmdbID: 2,
            isMovie: true,
            base: "Crash"
        )

        XCTAssertEqual(
            DownloadPathIdentityPolicy.allocateVideoRelativePath(
                request: migrating,
                owners: [tracked],
                fileExtension: "mp4",
                forceIdentitySuffix: true
            ),
            "Crash [TMDB 2].mp4"
        )
        XCTAssertEqual(tracked.relativePaths, ["Crash.mp4"])
    }

    func testOccupiedIdentityPathGetsStableSecondFallback() {
        let friendly = owner(
            id: "movie-1",
            identity: "movie:tmdb:1",
            isMovie: true,
            paths: ["Crash.mp4"]
        )
        let request = request(
            id: "movie-2",
            identity: "movie:tmdb:2",
            tmdbID: 2,
            isMovie: true,
            base: "Crash"
        )
        let path = DownloadPathIdentityPolicy.allocateVideoRelativePath(
            request: request,
            owners: [friendly],
            fileExtension: "mp4"
        ) { $0 == "Crash [TMDB 2].mp4" }

        XCTAssertTrue(path.hasPrefix("Crash [TMDB 2 - "))
        XCTAssertTrue(path.hasSuffix("].mp4"))
    }

    func testSharedLegacyPathDeletesOnlyAfterLastReference() {
        let first = owner(
            id: "legacy-1",
            identity: "movie:tmdb:1",
            isMovie: true,
            paths: ["legacy-shared.mp4"]
        )
        let second = owner(
            id: "legacy-2",
            identity: "movie:tmdb:2",
            isMovie: true,
            paths: ["LEGACY-SHARED.MP4"]
        )

        XCTAssertTrue(
            DownloadPathIdentityPolicy.pathIsReferenced(
                "legacy-shared.mp4",
                excludingIDs: [first.id],
                owners: [first, second]
            )
        )
        XCTAssertFalse(
            DownloadPathIdentityPolicy.pathIsReferenced(
                "legacy-shared.mp4",
                excludingIDs: [first.id, second.id],
                owners: [first, second]
            )
        )
    }

    func testUnsafeRelativePathsAreRejected() {
        XCTAssertNil(DownloadPathIdentityPolicy.normalizedRelativePath("Show/../Other.mp4"))
        XCTAssertNil(DownloadPathIdentityPolicy.normalizedRelativePath("./Movie.mp4"))
        XCTAssertEqual(
            DownloadPathIdentityPolicy.normalizedRelativePath("/Show/Episode.mp4/"),
            "Show/Episode.mp4"
        )
    }

    private func owner(
        id: String,
        identity: String,
        isMovie: Bool,
        paths: [String]
    ) -> DownloadPathIdentityOwner {
        DownloadPathIdentityOwner(
            id: id,
            mediaIdentity: identity,
            isMovie: isMovie,
            relativePaths: paths
        )
    }

    private func request(
        id: String,
        identity: String,
        tmdbID: Int,
        isMovie: Bool,
        base: String,
        episode: String = ""
    ) -> DownloadPathIdentityRequest {
        DownloadPathIdentityRequest(
            itemID: id,
            mediaIdentity: identity,
            tmdbID: tmdbID,
            isMovie: isMovie,
            baseComponent: base,
            episodeComponent: episode
        )
    }
}

#if os(iOS)
final class DownloadPathLegacyMetadataTests: XCTestCase {
    func testLegacyMetadataDecodesAndAnimePlaybackIdentityIsUnchanged() throws {
        let context = EpisodePlaybackContext(
            localSeasonNumber: 1,
            localEpisodeNumber: 2,
            anilistMediaId: 123,
            kitsuMediaId: 456,
            tmdbSeasonNumber: 4,
            tmdbEpisodeNumber: 8,
            tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: 26,
            animeSeasonEpisodeCount: 12,
            isSpecial: false,
            titleOnlySearch: false
        )
        let item = DownloadItem(
            id: "anime-s1e2",
            tmdbId: 999,
            isMovie: false,
            title: "Fallback Title",
            displayTitle: "Frieren - S01E0002",
            posterURL: nil,
            seasonNumber: 1,
            episodeNumber: 2,
            episodeName: nil,
            streamURL: "https://example.test/video.mp4",
            headers: [:],
            subtitleURL: nil,
            subtitleHeaders: nil,
            serviceBaseURL: "https://example.test",
            episodePlaybackContext: context,
            status: .queued,
            progress: 0,
            totalBytes: 0,
            downloadedBytes: 0,
            localFileName: nil,
            subtitleFileName: nil,
            error: nil,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            dateCompleted: nil,
            isAnime: true
        )

        let encoded = try JSONEncoder().encode(item)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "reservedVideoFileName")
        object.removeValue(forKey: "reservedSubtitleFileName")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: legacyData)

        XCTAssertNil(decoded.reservedVideoFileName)
        XCTAssertNil(decoded.reservedSubtitleFileName)
        XCTAssertEqual(decoded.playerTitleBase, "Frieren")
        XCTAssertEqual(decoded.episodePlaybackContext, context)
    }
}
#endif
