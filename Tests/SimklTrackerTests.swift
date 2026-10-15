import XCTest
#if os(macOS)
@testable import EclipseMac
#else
@testable import Eclipse
#endif

final class SimklTrackerTests: XCTestCase {
    func testRetiredSimklOptionsCannotReturnFromSavedState() throws {
        let legacy = Data("{\"syncEnabled\":true,\"liveSimklScrobbling\":true,\"simklWatchlistSync\":true}".utf8)
        var state = try JSONDecoder().decode(TrackerState.self, from: legacy)
        state.addOrUpdateAccount(TrackerAccount(service: .simkl, username: "Fixture", accessToken: "token", userId: "1"))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        XCTAssertNil(encoded["liveSimklScrobbling"])
        XCTAssertNil(encoded["simklWatchlistSync"])
        XCTAssertTrue(state.syncEnabled)
        XCTAssertEqual(TrackerManager.simklCompletionAccount(state: state, progress: 0.85)?.service, .simkl)
    }

    func testCompletedPlaybackSyncAdmitsSimklWithoutTrakt() {
        var state = TrackerState()
        state.addOrUpdateAccount(TrackerAccount(service: .simkl, username: "Fixture", accessToken: "token", userId: "1"))
        XCTAssertNil(state.getAccount(for: .trakt))
        XCTAssertEqual(TrackerManager.simklCompletionAccount(state: state, progress: 0.85)?.service, .simkl)
        XCTAssertNil(TrackerManager.simklCompletionAccount(state: state, progress: 0.84))
        XCTAssertNil(TrackerManager.simklCompletionAccount(state: state, progress: .nan))
        state.syncEnabled = false
        XCTAssertNil(TrackerManager.simklCompletionAccount(state: state, progress: 1))
    }

    func testMovieHistoryUsesExactTMDBIdentity() throws {
        let body = try TrackerManager.simklPlaybackPayload(mediaInfo: .movie(id: 42, title: ""), playbackContext: nil)
        let movie = try XCTUnwrap((body["movies"] as? [[String: Any]])?.first)
        XCTAssertEqual((movie["ids"] as? [String: Int])?["tmdb"], 42)
        XCTAssertNotNil(movie["watched_at"])
    }

    func testNativeAnimeHistoryUsesCanonicalShowsEnvelope() throws {
        let context = EpisodePlaybackContext(localSeasonNumber: 2, localEpisodeNumber: 4,
            anilistMediaId: 123, malMediaId: 456, tmdbSeasonNumber: 1, tmdbEpisodeNumber: 28,
            tmdbEpisodeOffset: nil, animeAbsoluteEpisodeNumber: 28, animeSeasonEpisodeCount: 12,
            isSpecial: false, titleOnlySearch: false)
        let body = try TrackerManager.simklPlaybackPayload(mediaInfo: .episode(showId: 77, seasonNumber: 2, episodeNumber: 4),
            playbackContext: context)
        XCTAssertNil(body["anime"])
        let show = try XCTUnwrap((body["shows"] as? [[String: Any]])?.first)
        XCTAssertEqual((show["ids"] as? [String: Int])?["anilist"], 123)
        XCTAssertEqual(((show["episodes"] as? [[String: Any]])?.first)?["number"] as? Int, 4)
        XCTAssertNil(show["seasons"])
    }

    func testUnresolvedAndSpecialAnimeFailClosed() {
        for special in [false, true] {
            let context = EpisodePlaybackContext(localSeasonNumber: 1, localEpisodeNumber: 2,
                anilistMediaId: special ? 123 : nil, tmdbSeasonNumber: nil, tmdbEpisodeNumber: nil,
                tmdbEpisodeOffset: nil, animeAbsoluteEpisodeNumber: 2, animeSeasonEpisodeCount: nil,
                isSpecial: special, titleOnlySearch: true)
            XCTAssertThrowsError(try TrackerManager.simklPlaybackPayload(
                mediaInfo: .episode(showId: 77, seasonNumber: 1, episodeNumber: 2), playbackContext: context))
        }
    }

    func testTMDBHistoryRetainsProviderCoordinates() throws {
        let body = try TrackerManager.simklPlaybackPayload(mediaInfo: .episode(showId: 55, seasonNumber: 2, episodeNumber: 9),
            playbackContext: nil)
        let show = try XCTUnwrap((body["shows"] as? [[String: Any]])?.first)
        XCTAssertEqual(show["use_tvdb_anime_seasons"] as? Bool, true)
        let season = try XCTUnwrap((show["seasons"] as? [[String: Any]])?.first)
        XCTAssertEqual(season["number"] as? Int, 2)
        XCTAssertEqual(((season["episodes"] as? [[String: Any]])?.first)?["number"] as? Int, 9)
    }

    func testDeviceGrantNeverLeavesCloudSnapshotOrReplacesLocalGrant() {
        var local = TrackerState()
        let deviceAccount = TrackerAccount(service: .simkl, username: "Local", accessToken: "local-token", refreshToken: "local-refresh", userId: "1")
        local.addOrUpdateAccount(deviceAccount)
        XCTAssertTrue(local.excludingDeviceCredentials().accounts.isEmpty)
        var incoming = TrackerState()
        incoming.addOrUpdateAccount(TrackerAccount(service: .simkl, username: "Peer", accessToken: "peer-token", userId: "2"))
        let preserved = incoming.preservingDeviceAccounts(from: local)
        XCTAssertEqual(preserved.getAccount(for: .simkl)?.accessToken, "local-token")
        XCTAssertNil(incoming.preservingDeviceAccounts(from: nil).getAccount(for: .simkl))
    }

    func testSimklGrantCannotAuthorCloudRecord() {
        let account = TrackerAccount(service: .simkl, username: "Local", accessToken: "token", userId: "1")
        XCTAssertNil(TrackerCloudAccountRecord.bootstrap(profileID: UUID(), account: account))
        XCTAssertNil(TrackerCloudAccountRecord.authoring(profileID: UUID(), service: .simkl, account: account,
            previous: nil, kind: .authorization, previousAccount: nil))
    }

    func testSimklIsExcludedFromDeepLibraryKindsAndCollectionTargets() {
        XCTAssertTrue(TrackerLibraryKind.supportedKinds(for: .simkl).isEmpty)
        XCTAssertFalse(TrackerCollectionTarget(title: "Example", kind: .movie, tmdbID: 42).supports(.simkl))
    }
}
