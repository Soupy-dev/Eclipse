import XCTest
@testable import Eclipse

final class NextEpisodeResolverTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-07-09T12:00:00Z")!

    func testRegularShowResolvesVerifiedSameSeasonEpisode() async throws {
        let metadata = MetadataStub()
        metadata.seasons[MetadataStub.key(showID: 10, season: 1)] = seasonDetail(
            season: 1,
            episodes: [
                episode(season: 1, number: 1, airDate: "2026-07-01"),
                episode(season: 1, number: 2, airDate: "2026-07-08")
            ]
        )

        let result = await NextEpisodeResolver(metadata: metadata).resolve(
            seed: seed(showID: 10, season: 1, episode: 1),
            now: now
        )
        let target = try availableTarget(result)

        XCTAssertEqual(target.episode.seasonNumber, 1)
        XCTAssertEqual(target.episode.episodeNumber, 2)
        XCTAssertNil(target.playbackContext)
    }

    func testRegularShowResolvesSeasonBoundaryFromActualSeasonDetail() async throws {
        let metadata = MetadataStub()
        metadata.seasons[MetadataStub.key(showID: 11, season: 1)] = seasonDetail(
            season: 1,
            episodes: [episode(season: 1, number: 8, airDate: "2026-07-01")]
        )
        metadata.seasons[MetadataStub.key(showID: 11, season: 2)] = seasonDetail(
            season: 2,
            episodes: [episode(season: 2, number: 1, airDate: "2026-07-08")]
        )
        metadata.shows[11] = tvShow(
            id: 11,
            seasons: [seasonSummary(1, count: 8), seasonSummary(2, count: 1)]
        )

        let result = await NextEpisodeResolver(metadata: metadata).resolve(
            seed: seed(showID: 11, season: 1, episode: 8),
            now: now
        )
        let target = try availableTarget(result)

        XCTAssertEqual(target.episode.seasonNumber, 2)
        XCTAssertEqual(target.episode.episodeNumber, 1)
    }

    func testFutureEpisodeAndSeriesFinaleDoNotProduceTargets() async {
        let futureMetadata = MetadataStub()
        futureMetadata.seasons[MetadataStub.key(showID: 12, season: 1)] = seasonDetail(
            season: 1,
            episodes: [
                episode(season: 1, number: 1, airDate: "2026-07-01"),
                episode(season: 1, number: 2, airDate: "2026-07-10")
            ]
        )
        let future = await NextEpisodeResolver(metadata: futureMetadata).resolve(
            seed: seed(showID: 12, season: 1, episode: 1),
            now: now
        )
        assertNoAvailableEpisode(future)

        let finaleMetadata = MetadataStub()
        finaleMetadata.seasons[MetadataStub.key(showID: 13, season: 1)] = seasonDetail(
            season: 1,
            episodes: [episode(season: 1, number: 12, airDate: "2026-07-01")]
        )
        finaleMetadata.shows[13] = tvShow(
            id: 13,
            seasons: [seasonSummary(1, count: 12)]
        )
        let finale = await NextEpisodeResolver(metadata: finaleMetadata).resolve(
            seed: seed(showID: 13, season: 1, episode: 12),
            now: now
        )
        assertNoAvailableEpisode(finale)
    }

    func testMissingOrFailedMetadataFailsClosedWithoutEpisodePlusOneGuess() async {
        let missingCurrentEpisode = MetadataStub()
        missingCurrentEpisode.seasons[MetadataStub.key(showID: 14, season: 1)] = seasonDetail(
            season: 1,
            episodes: [episode(season: 1, number: 2, airDate: "2026-07-01")]
        )
        let missing = await NextEpisodeResolver(metadata: missingCurrentEpisode).resolve(
            seed: seed(showID: 14, season: 1, episode: 1),
            now: now
        )
        assertUnavailable(missing)

        let failed = MetadataStub()
        failed.failSeasonFetch = true
        let failure = await NextEpisodeResolver(metadata: failed).resolve(
            seed: seed(showID: 15, season: 1, episode: 1),
            now: now
        )
        assertUnavailable(failure)
    }

    func testAnimeSeasonBoundaryBuildsFreshDestinationContext() async throws {
        let metadata = MetadataStub()
        metadata.anime = AniListAnimeWithSeasons(
            id: 100,
            malId: 200,
            title: "Example Anime",
            genres: nil,
            seasons: [
                animeSeason(
                    season: 1,
                    anilistID: 101,
                    kitsuID: 201,
                    title: "Example Anime",
                    episodes: [
                        animeEpisode(number: 1, season: 1, tmdbSeason: 1, tmdbEpisode: 1),
                        animeEpisode(number: 2, season: 1, tmdbSeason: 1, tmdbEpisode: 2)
                    ]
                ),
                animeSeason(
                    season: 2,
                    anilistID: 102,
                    kitsuID: 202,
                    title: "Example Anime Season 2",
                    episodes: [
                        animeEpisode(number: 1, season: 2, tmdbSeason: 2, tmdbEpisode: 1)
                    ]
                )
            ],
            totalEpisodes: 3,
            status: "FINISHED",
            rating: nil
        )
        let currentContext = EpisodePlaybackContext(
            localSeasonNumber: 1,
            localEpisodeNumber: 2,
            anilistMediaId: 101,
            kitsuMediaId: 201,
            tmdbSeasonNumber: 1,
            tmdbEpisodeNumber: 2,
            tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: 2,
            animeSeasonEpisodeCount: 2,
            isSpecial: false,
            titleOnlySearch: false
        )

        let result = await NextEpisodeResolver(metadata: metadata).resolve(
            seed: seed(
                showID: 20,
                season: 1,
                episode: 2,
                isAnime: true,
                context: currentContext
            ),
            now: now
        )
        let target = try availableTarget(result)
        let context = try XCTUnwrap(target.playbackContext)

        XCTAssertEqual(target.episode.seasonNumber, 2)
        XCTAssertEqual(target.episode.episodeNumber, 1)
        XCTAssertEqual(context.localSeasonNumber, 2)
        XCTAssertEqual(context.localEpisodeNumber, 1)
        XCTAssertEqual(context.anilistMediaId, 102)
        XCTAssertEqual(context.kitsuMediaId, 202)
        XCTAssertEqual(context.resolvedTMDBSeasonNumber, 2)
        XCTAssertEqual(context.resolvedTMDBEpisodeNumber, 1)
        XCTAssertEqual(context.animeAbsoluteEpisodeNumber, 3)
        XCTAssertEqual(context.animeSeasonEpisodeCount, 1)
        XCTAssertFalse(context.isSpecial)
        XCTAssertEqual(metadata.animeSeedAniListIDs, [101])
        XCTAssertEqual(metadata.animeSeedMALIDs, [nil])
    }

    func testAnimeMetadataFailureFailsClosed() async {
        let metadata = MetadataStub()
        metadata.failAnimeFetch = true

        let result = await NextEpisodeResolver(metadata: metadata).resolve(
            seed: seed(showID: 21, season: 1, episode: 12, isAnime: true),
            now: now
        )

        assertUnavailable(result)
    }

    func testSpecialAdvancesOnlyWithinMatchedEntryAndStopsAtItsEnd() async throws {
        let metadata = MetadataStub()
        metadata.anime = emptyAnime(id: 900)
        metadata.specials = [specialEntry(id: 900, episodeCount: 2)]
        let currentContext = specialContext(entryID: 900, episode: 1)

        let result = await NextEpisodeResolver(metadata: metadata).resolve(
            seed: seed(
                showID: 30,
                season: currentContext.localSeasonNumber,
                episode: 1,
                isAnime: true,
                context: currentContext
            ),
            now: now
        )
        let target = try availableTarget(result)
        let targetContext = try XCTUnwrap(target.playbackContext)

        XCTAssertEqual(target.episode.episodeNumber, 2)
        XCTAssertEqual(target.episode.seasonNumber, 100_900)
        XCTAssertEqual(targetContext.anilistMediaId, 900)
        XCTAssertEqual(targetContext.resolvedTMDBSeasonNumber, 0)
        XCTAssertEqual(targetContext.resolvedTMDBEpisodeNumber, 6)
        XCTAssertTrue(targetContext.isSpecial)
        XCTAssertEqual(metadata.animeSeedAniListIDs, [900])
        XCTAssertEqual(metadata.animeSeedMALIDs, [nil])
        XCTAssertEqual(metadata.requiredSpecialAniListIDs, [[900]])

        let final = await NextEpisodeResolver(metadata: metadata).resolve(
            seed: seed(
                showID: 30,
                season: 100_900,
                episode: 2,
                isAnime: true,
                context: specialContext(entryID: 900, episode: 2)
            ),
            now: now
        )
        assertNoAvailableEpisode(final)
    }

    func testNegativeMALSpecialSeedRemainsExactAcrossMetadataBoundaries() async throws {
        let metadata = MetadataStub()
        metadata.anime = emptyAnime(id: 777)
        // -777 is the MAL-namespace provider ID for MAL 777, so the entry carries that exact
        // MAL alias the way an AniMap fallback graph would.
        metadata.specials = [specialEntry(id: -777, episodeCount: 2, malID: 777)]
        let currentContext = specialContext(entryID: -777, episode: 1)

        let result = await NextEpisodeResolver(metadata: metadata).resolve(
            seed: seed(
                showID: 31,
                season: currentContext.localSeasonNumber,
                episode: 1,
                isAnime: true,
                context: currentContext
            ),
            now: now
        )

        _ = try availableTarget(result)
        XCTAssertEqual(metadata.animeSeedAniListIDs, [-777])
        XCTAssertEqual(metadata.animeSeedMALIDs, [777])
        XCTAssertEqual(metadata.requiredSpecialAniListIDs, [[-777]])
    }

    @MainActor
    func testNextEpisodeAccountBoundaryInvalidatesVisibleRouteSynchronously() async throws {
        let center = NotificationCenter()
        let router = TVNextEpisodeRoutingCenter(notificationCenter: center)
        let authority = router.captureAuthority()
        await router.route(routingTarget(), authority: authority)
        let route = try XCTUnwrap(router.target)
        router.presentationError = "Previous failure"

        MediaStateAccountPlaybackBoundary.notifyWillChangeUser(notificationCenter: center)

        XCTAssertNil(router.target)
        XCTAssertNil(router.presentationError)
        XCTAssertFalse(router.isCurrent(authority))
        XCTAssertFalse(router.isCurrent(route))
        await router.route(routingTarget(), authority: authority)
        XCTAssertNil(router.target)
    }

    @MainActor
    func testNextEpisodeRejectsDismissalHandoffAfterProfileRoundTrip() async {
        let center = NotificationCenter()
        let router = TVNextEpisodeRoutingCenter(notificationCenter: center)
        let authority = router.captureAuthority()
        center.post(name: .activeProfileDidChange, object: nil)
        center.post(name: .activeProfileDidChange, object: nil)

        XCTAssertEqual(authority.scope.profileID, router.captureAuthority().scope.profileID)
        XCTAssertFalse(router.isCurrent(authority))
        await router.route(routingTarget(), authority: authority)
        XCTAssertNil(router.target)
    }

    @MainActor
    func testNextEpisodeBoundaryCannotRestoreYieldedRoute() async {
        let center = NotificationCenter()
        let router = TVNextEpisodeRoutingCenter(notificationCenter: center)
        let authority = router.captureAuthority()
        let target = routingTarget()
        let pending = Task { @MainActor in
            await router.route(target, authority: authority)
        }
        await Task.yield()
        MediaStateAccountPlaybackBoundary.notifyWillChangeUser(notificationCenter: center)
        await pending.value

        XCTAssertNil(router.target)
        XCTAssertFalse(router.isCurrent(authority))
    }

    @MainActor
    func testNextEpisodeReplacementRejectsEarlierCallbackForSameEpisode() async throws {
        let router = TVNextEpisodeRoutingCenter(notificationCenter: NotificationCenter())
        let authority = router.captureAuthority()
        let target = routingTarget()
        await router.route(target, authority: authority)
        let previous = try XCTUnwrap(router.target)
        await router.route(target, authority: authority)
        let replacement = try XCTUnwrap(router.target)

        XCTAssertEqual(previous.target.id, replacement.target.id)
        XCTAssertNotEqual(previous.id, replacement.id)
        XCTAssertFalse(router.isCurrent(previous))
        XCTAssertTrue(router.isCurrent(replacement))
    }

    private func routingTarget() -> ResolvedNextEpisodeTarget {
        ResolvedNextEpisodeTarget(
            showID: 42,
            episode: episode(season: 1, number: 2, airDate: nil),
            playbackContext: nil,
            mediaTitle: "Show 42",
            seasonTitleOverride: nil,
            originalTitle: nil,
            posterURL: nil,
            imdbID: nil,
            isAnime: false,
            isAnimation: false
        )
    }

    // MARK: - Assertions

    private func availableTarget(
        _ resolution: NextEpisodeResolution,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ResolvedNextEpisodeTarget {
        guard case .available(let target) = resolution else {
            XCTFail("Expected an available next episode", file: file, line: line)
            throw TestError.unexpectedResolution
        }
        return target
    }

    private func assertNoAvailableEpisode(
        _ resolution: NextEpisodeResolution,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .noAvailableEpisode = resolution else {
            XCTFail("Expected a verified absence of a next episode", file: file, line: line)
            return
        }
    }

    private func assertUnavailable(
        _ resolution: NextEpisodeResolution,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable = resolution else {
            XCTFail("Expected metadata resolution to fail closed", file: file, line: line)
            return
        }
    }

    // MARK: - Fixtures

    private func seed(
        showID: Int,
        season: Int,
        episode: Int,
        isAnime: Bool = false,
        context: EpisodePlaybackContext? = nil
    ) -> NextEpisodeSeed {
        NextEpisodeSeed(
            showID: showID,
            currentSeasonNumber: season,
            currentEpisodeNumber: episode,
            showTitle: "Show \(showID)",
            showPosterURL: "https://images.example/show.jpg",
            imdbID: "tt00000\(showID)",
            isAnime: isAnime,
            isAnimation: isAnime,
            playbackContext: context
        )
    }

    private func episode(season: Int, number: Int, airDate: String?) -> TMDBEpisode {
        TMDBEpisode(
            id: season * 100 + number,
            name: "Episode \(number)",
            overview: nil,
            stillPath: nil,
            episodeNumber: number,
            seasonNumber: season,
            airDate: airDate,
            runtime: 24,
            voteAverage: 0,
            voteCount: 0
        )
    }

    private func seasonDetail(season: Int, episodes: [TMDBEpisode]) -> TMDBSeasonDetail {
        TMDBSeasonDetail(
            id: season,
            name: "Season \(season)",
            overview: nil,
            posterPath: nil,
            seasonNumber: season,
            airDate: nil,
            episodes: episodes
        )
    }

    private func seasonSummary(_ season: Int, count: Int) -> TMDBSeason {
        TMDBSeason(
            id: season,
            name: "Season \(season)",
            overview: nil,
            posterPath: nil,
            seasonNumber: season,
            episodeCount: count,
            airDate: nil
        )
    }

    private func tvShow(id: Int, seasons: [TMDBSeason]) -> TMDBTVShowWithSeasons {
        TMDBTVShowWithSeasons(
            id: id,
            name: "Show \(id)",
            overview: nil,
            posterPath: nil,
            backdropPath: nil,
            firstAirDate: nil,
            lastAirDate: nil,
            voteAverage: 0,
            popularity: 0,
            genres: [],
            tagline: nil,
            status: "Ended",
            originalLanguage: "en",
            originalName: nil,
            adult: false,
            voteCount: 0,
            numberOfSeasons: seasons.count,
            numberOfEpisodes: seasons.reduce(0) { $0 + $1.episodeCount },
            episodeRunTime: nil,
            inProduction: false,
            languages: ["en"],
            originCountry: ["US"],
            type: "Scripted",
            seasons: seasons,
            contentRatings: nil,
            externalIds: nil
        )
    }

    private func animeEpisode(
        number: Int,
        season: Int,
        tmdbSeason: Int,
        tmdbEpisode: Int
    ) -> AniListEpisode {
        AniListEpisode(
            number: number,
            title: "Episode \(number)",
            description: nil,
            seasonNumber: season,
            stillPath: nil,
            airDate: "2026-07-01",
            runtime: 24,
            tmdbSeasonNumber: tmdbSeason,
            tmdbEpisodeNumber: tmdbEpisode
        )
    }

    /// `canonicalAniListId` and `malId` default to nil because AniList-sourced seasons only carry
    /// them on the exact-MAL fallback path; the resolver derives the canonical alias from a
    /// positive `anilistId`, which is what these fixtures use.
    private func animeSeason(
        season: Int,
        anilistID: Int,
        kitsuID: Int,
        title: String,
        canonicalAniListID: Int? = nil,
        malID: Int? = nil,
        episodes: [AniListEpisode]
    ) -> AniListSeasonWithPoster {
        AniListSeasonWithPoster(
            seasonNumber: season,
            anilistId: anilistID,
            canonicalAniListId: canonicalAniListID,
            malId: malID,
            kitsuId: kitsuID,
            title: title,
            englishTitle: title,
            romajiTitle: "\(title) Romaji",
            nativeTitle: nil,
            episodes: episodes,
            posterUrl: "https://images.example/anime-\(anilistID).jpg"
        )
    }

    private func emptyAnime(id: Int) -> AniListAnimeWithSeasons {
        AniListAnimeWithSeasons(
            id: id,
            malId: nil,
            title: "Fixture Anime",
            genres: nil,
            seasons: [],
            totalEpisodes: 0,
            status: "FINISHED",
            rating: nil
        )
    }

    /// `status` stays nil so the resolver keeps relying on per-episode air dates for release
    /// verification rather than the entry-level FINISHED shortcut.
    private func specialEntry(
        id: Int,
        episodeCount: Int,
        canonicalAniListID: Int? = nil,
        malID: Int? = nil,
        kitsuID: Int? = nil
    ) -> AniListSpecialSearchEntry {
        AniListSpecialSearchEntry(
            id: id,
            canonicalAniListId: canonicalAniListID,
            malId: malID,
            kitsuId: kitsuID,
            title: "Example OVA",
            englishTitle: "Example OVA",
            romajiTitle: "Example OVA Romaji",
            nativeTitle: nil,
            format: "OVA",
            episodeCount: episodeCount,
            posterUrl: "https://images.example/ova.jpg",
            tmdbSeasonNumber: 0,
            tvdbSeasonNumber: 0,
            episodeOffset: 4,
            imdbId: "tt900",
            releaseDate: "2026-07-01",
            status: nil,
            episodes: (1...episodeCount).map {
                animeEpisode(number: $0, season: 0, tmdbSeason: 0, tmdbEpisode: $0 + 4)
            }
        )
    }

    private func specialContext(entryID: Int, episode: Int) -> EpisodePlaybackContext {
        guard let localSeasonNumber = AnimeSyntheticSeasonKey.make(providerID: entryID) else {
            XCTFail("Test fixture must use a bounded nonzero provider ID")
            return EpisodePlaybackContext(
                localSeasonNumber: 0,
                localEpisodeNumber: max(1, episode),
                anilistMediaId: nil,
                tmdbSeasonNumber: nil,
                tmdbEpisodeNumber: nil,
                tmdbEpisodeOffset: nil,
                animeAbsoluteEpisodeNumber: nil,
                animeSeasonEpisodeCount: nil,
                isSpecial: true,
                titleOnlySearch: false
            )
        }
        return EpisodePlaybackContext(
            localSeasonNumber: localSeasonNumber,
            localEpisodeNumber: episode,
            anilistMediaId: entryID,
            tmdbSeasonNumber: 0,
            tmdbEpisodeNumber: 4 + episode,
            tmdbEpisodeOffset: 4,
            animeAbsoluteEpisodeNumber: nil,
            animeSeasonEpisodeCount: nil,
            isSpecial: true,
            titleOnlySearch: false
        )
    }
}

private final class MetadataStub: NextEpisodeMetadataProviding {
    var shows: [Int: TMDBTVShowWithSeasons] = [:]
    var seasons: [String: TMDBSeasonDetail] = [:]
    var anime: AniListAnimeWithSeasons?
    var specials: [AniListSpecialSearchEntry]?
    var failSeasonFetch = false
    var failAnimeFetch = false
    var animeSeedAniListIDs: [Int?] = []
    var animeSeedMALIDs: [Int?] = []
    var requiredSpecialAniListIDs: [[Int]] = []

    static func key(showID: Int, season: Int) -> String {
        "\(showID):\(season)"
    }

    func tvShow(showID: Int) async throws -> TMDBTVShowWithSeasons {
        guard let show = shows[showID] else { throw TestError.missingFixture }
        return show
    }

    func season(showID: Int, seasonNumber: Int) async throws -> TMDBSeasonDetail {
        guard !failSeasonFetch,
              let season = seasons[Self.key(showID: showID, season: seasonNumber)] else {
            throw TestError.missingFixture
        }
        return season
    }

    func animeDetails(
        title: String,
        showID: Int,
        posterURL: String?,
        seedAniListID: Int?,
        seedMALID: Int?
    ) async throws -> AniListAnimeWithSeasons {
        animeSeedAniListIDs.append(seedAniListID)
        animeSeedMALIDs.append(seedMALID)
        guard !failAnimeFetch, let anime else { throw TestError.missingFixture }
        return anime
    }

    func specialEntries(
        showID: Int,
        posterURL: String?,
        baseAniListIDs: [Int],
        requiredSpecialAniListIDs: [Int]
    ) async throws -> [AniListSpecialSearchEntry] {
        self.requiredSpecialAniListIDs.append(requiredSpecialAniListIDs.sorted())
        guard let specials else { throw TestError.missingFixture }
        return specials
    }
}

private enum TestError: Error {
    case missingFixture
    case unexpectedResolution
}

final class TrackerAuditRegressionTests: XCTestCase {
    func testTraktPlaybackKeepsSubOnePercentUnits() throws {
        for percent in [0.1, 0.5, 1, 1.1, 99, 100] {
            let value = try XCTUnwrap(TrackerProgressSyncPolicy.traktPlaybackProgress(percent))
            XCTAssertEqual(value.percent, percent, accuracy: 0.000001)
            XCTAssertEqual(value.fraction, percent / 100, accuracy: 0.000001)
        }
        XCTAssertNil(TrackerProgressSyncPolicy.traktPlaybackProgress(nil))
        XCTAssertNil(TrackerProgressSyncPolicy.traktPlaybackProgress(.nan))
        XCTAssertNil(TrackerProgressSyncPolicy.traktPlaybackProgress(.infinity))
        XCTAssertNil(TrackerProgressSyncPolicy.traktPlaybackProgress(-1))
        XCTAssertNil(TrackerProgressSyncPolicy.traktPlaybackProgress(0))
        XCTAssertEqual(TrackerProgressSyncPolicy.traktPlaybackProgress(101)?.fraction, 1)
    }

    func testAniListRatingsUseFixedHundredPointScaleAndHalfSteps() {
        XCTAssertEqual(TrackerProgressSyncPolicy.aniListScoreRaw(9), 90)
        XCTAssertEqual(TrackerProgressSyncPolicy.aniListScoreRaw(9.5), 95)
        XCTAssertEqual(TrackerProgressSyncPolicy.aniListScoreRaw(0.5), 5)
        XCTAssertEqual(TrackerProgressSyncPolicy.aniListScoreRaw(10), 100)
        XCTAssertEqual(TrackerProgressSyncPolicy.aniListScoreRaw(.greatestFiniteMagnitude), 100)
        XCTAssertEqual(TrackerProgressSyncPolicy.aniListScoreRaw(.nan), 5)
    }

    func testAdditiveProgressSkipsAheadCompletedAndRewatchingDestinations() {
        XCTAssertFalse(TrackerProgressSyncPolicy.shouldAdvance(requested: 3, requestedStatus: "CURRENT", current: 10, currentStatus: "CURRENT", isRepeating: false))
        XCTAssertFalse(TrackerProgressSyncPolicy.shouldAdvance(requested: 12, requestedStatus: "COMPLETED", current: 2, currentStatus: "REPEATING", isRepeating: true))
        XCTAssertFalse(TrackerProgressSyncPolicy.shouldAdvance(requested: 12, requestedStatus: "COMPLETED", current: 0, currentStatus: "completed", isRepeating: false))
        XCTAssertFalse(TrackerProgressSyncPolicy.shouldAdvance(requested: 4, requestedStatus: "CURRENT", current: 4, currentStatus: "CURRENT", isRepeating: false))
        XCTAssertTrue(TrackerProgressSyncPolicy.shouldAdvance(requested: 5, requestedStatus: "CURRENT", current: 4, currentStatus: "CURRENT", isRepeating: false))
        XCTAssertTrue(TrackerProgressSyncPolicy.shouldAdvance(requested: 12, requestedStatus: "COMPLETED", current: 12, currentStatus: "CURRENT", isRepeating: false))
    }

    func testAdditiveStatusPreservesPausedDroppedAndNewPlanningEntries() {
        XCTAssertEqual(TrackerProgressSyncPolicy.additiveStatus(requested: "CURRENT", current: "PAUSED", progress: 10, total: 12, isAniList: true, isManga: false), "PAUSED")
        XCTAssertEqual(TrackerProgressSyncPolicy.additiveStatus(requested: "reading", current: "dropped", progress: 10, total: 12, isAniList: false, isManga: true), "dropped")
        XCTAssertEqual(TrackerProgressSyncPolicy.additiveStatus(requested: "PLANNING", current: nil, progress: 0, total: nil, isAniList: true, isManga: false), "PLANNING")
        XCTAssertEqual(TrackerProgressSyncPolicy.additiveStatus(requested: "watching", current: "watching", progress: 1, total: 12, isAniList: false, isManga: false), "watching")
        XCTAssertEqual(TrackerProgressSyncPolicy.additiveStatus(requested: "watching", current: "watching", progress: 12, total: 12, isAniList: false, isManga: false), "completed")
    }

    func testAnimeImportPreservesLaterSeasonAndCourCoordinates() throws {
        let laterSeason = try XCTUnwrap(TrackerAnimeImportCoordinates.resolve(watched: 2, episodes: [episode(1, season: 2, mapped: 1), episode(2, season: 2, mapped: 2)]))
        XCTAssertEqual(laterSeason, [2: [1, 2]])
        let laterCour = try XCTUnwrap(TrackerAnimeImportCoordinates.resolve(watched: 2, episodes: [episode(1, season: 1, mapped: 13), episode(2, season: 1, mapped: 14)]))
        XCTAssertEqual(laterCour, [1: [13, 14]])
        let split = try XCTUnwrap(TrackerAnimeImportCoordinates.resolve(watched: 2, episodes: [episode(1, season: 1, mapped: 12), episode(2, season: 2, mapped: 1)]))
        XCTAssertEqual(split, [1: [12], 2: [1]])
    }

    func testAnimeImportRejectsMissingAmbiguousAndPartialCoordinates() {
        XCTAssertNil(TrackerAnimeImportCoordinates.resolve(watched: 1, episodes: [episode(1, season: nil, mapped: nil)]))
        XCTAssertNil(TrackerAnimeImportCoordinates.resolve(watched: 2, episodes: [episode(1, season: 1, mapped: 1)]))
        XCTAssertNil(TrackerAnimeImportCoordinates.resolve(watched: 2, episodes: [episode(1, season: 1, mapped: 1), episode(2, season: 1, mapped: 1)]))
        XCTAssertNil(TrackerAnimeImportCoordinates.resolve(watched: 2, episodes: [episode(1, season: 1, mapped: 1), episode(1, season: 1, mapped: 2)]))
        XCTAssertNil(TrackerAnimeImportCoordinates.resolve(watched: Int.max, episodes: []))
        XCTAssertNil(TrackerAnimeImportCoordinates.resolve(watched: 0, episodes: []))
    }

    private func episode(_ number: Int, season: Int?, mapped: Int?) -> AniListEpisode {
        AniListEpisode(number: number, title: "Episode \(number)", description: nil, seasonNumber: 1, stillPath: nil, airDate: nil, runtime: nil, tmdbSeasonNumber: season, tmdbEpisodeNumber: mapped)
    }
}

final class ProviderAuditRegressionTests: XCTestCase {
    func testExternalPlayerNestedURLRoundTrips() throws {
        let values = [
            "https://media.example/video.m3u8?part=1&quality=1080",
            "https://media.example/東京%20video.m3u8?name=a+b&value=%2B&next=https%3A%2F%2Fother.example%2Fa%3Fx%3D1%26y%3D2#part",
            "https://media.example/video.mp4?empty=&literal=%25&unicode=기생충"
        ]
        for player in [ExternalPlayer.infuse, .senPlayer, .tracy, .vidHub] {
            for value in values {
                let url = try XCTUnwrap(player.schemeURL(for: value))
                let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
                XCTAssertEqual(components.queryItems?.count, 1)
                XCTAssertEqual(components.queryItems?.first?.value, value)
                XCTAssertFalse(components.percentEncodedQuery?.contains("+") ?? true)
            }
        }
        XCTAssertNil(ExternalPlayer.none.schemeURL(for: values[0]))
    }

    func testRetiredServiceLaneKeepsControllerCallbacksOnOneWorkerAcrossRepeatedRetirement() throws {
        let pool = ServiceJavaScriptWorkerPool(maximumConcurrentWorkers: 4)
        let original = try XCTUnwrap(pool.leaseLane())
        original.markPermanentlyUnavailable()
        let state = ProviderWorkerAuditState()
        let firstBatch = expectation(description: "One retired controller keeps a stable replacement")
        firstBatch.expectedFulfillmentCount = 8
        for _ in 0..<8 {
            _ = pool.leaseLane()
            XCTAssertTrue(original.async({ firstBatch.fulfill() }, ifRerouted: { state.record($0) }))
        }
        wait(for: [firstBatch], timeout: 3)
        XCTAssertEqual(state.identities.count, 1)
        let firstReplacement = try XCTUnwrap(state.first)
        firstReplacement.markPermanentlyUnavailable()
        state.reset()
        let secondBatch = expectation(description: "Aliases converge after a second retirement")
        secondBatch.expectedFulfillmentCount = 8
        for index in 0..<8 {
            _ = pool.leaseLane()
            let source = index.isMultiple(of: 2) ? original : firstReplacement
            XCTAssertTrue(source.async({ secondBatch.fulfill() }, ifRerouted: { state.record($0) }))
        }
        wait(for: [secondBatch], timeout: 3)
        XCTAssertEqual(state.identities.count, 1)
        XCTAssertFalse(state.first === firstReplacement)
        withExtendedLifetime(pool) {}
    }

    func testRetiredServiceLaneFullQueueRejectsWithoutConcurrentSpillover() throws {
        let pool = ServiceJavaScriptWorkerPool(maximumConcurrentWorkers: 4)
        let original = try XCTUnwrap(pool.leaseLane())
        original.markPermanentlyUnavailable()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let done = expectation(description: "Accepted operations drain on the pinned worker")
        done.expectedFulfillmentCount = 65
        let state = ProviderWorkerAuditState()
        XCTAssertTrue(original.async({
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            done.fulfill()
        }, ifRerouted: { state.record($0) }))
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        for _ in 0..<64 {
            _ = pool.leaseLane()
            XCTAssertTrue(original.async({ done.fulfill() }, ifRerouted: { state.record($0) }))
        }
        let rejected = expectation(description: "Full pinned lane rejects the extra operation")
        XCTAssertFalse(original.async({ XCTFail("A full controller lane must not spill onto another worker") }, ifUnavailable: { rejected.fulfill() }))
        release.signal()
        wait(for: [done, rejected], timeout: 3)
        XCTAssertEqual(state.identities.count, 1)
        withExtendedLifetime(pool) {}
    }
}

private final class ProviderWorkerAuditState: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ServiceJavaScriptWorkerLane] = []

    func record(_ lane: ServiceJavaScriptWorkerLane) {
        lock.lock()
        recorded.append(lane)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        recorded.removeAll()
        lock.unlock()
    }

    var first: ServiceJavaScriptWorkerLane? {
        lock.lock()
        defer { lock.unlock() }
        return recorded.first
    }

    var identities: Set<ObjectIdentifier> {
        lock.lock()
        defer { lock.unlock() }
        return Set(recorded.map(ObjectIdentifier.init))
    }
}

final class AnimeEpisodeUnitProgressRegressionTests: XCTestCase {
    func testStartingCompilationDoesNotInheritLegacyWatchedTime() throws {
        let owner = UUID()
        let manager = ProgressManager(profileID: owner)
        defer {
            manager.flushPendingSave()
            try? FileManager.default.removeItem(at: ProgressManager.progressFileURL(for: owner))
        }
        var legacy = EpisodeProgressEntry(showId: 67676, seasonNumber: 1, episodeNumber: 6)
        legacy.currentTime = 300
        legacy.totalDuration = 300
        legacy.isWatched = true
        var data = ProgressData()
        data.episodeProgress = [legacy]
        XCTAssertTrue(manager.replaceProgressDataForRestore(data, expectedProfileID: owner))
        let context = compilationContext(6)
        XCTAssertEqual(manager.getEpisodeProgress(showId: 67676, seasonNumber: 1, episodeNumber: 6, playbackContext: context), 0)
        XCTAssertEqual(manager.getEpisodeCurrentTime(showId: 67676, seasonNumber: 1, episodeNumber: 6, playbackContext: context), 0)
        manager.updateEpisodeProgress(showId: 67676, seasonNumber: 1, episodeNumber: 6,
            currentTime: 10, totalDuration: 100, playbackContext: context, isAnime: true, owner: owner)
        let updated = try XCTUnwrap(manager.captureEpisodeLookup(showID: 67676).entries.first)
        XCTAssertFalse(updated.isWatched)
        XCTAssertEqual(updated.totalDuration, 100)
        XCTAssertEqual(updated.currentTime, 10)
        XCTAssertEqual(updated.playbackContext, context)
        manager.updateEpisodeProgress(showId: 67676, seasonNumber: 1, episodeNumber: 6,
            currentTime: 240, totalDuration: 240, playbackContext: context, isAnime: true, owner: owner)
        _ = manager.captureEpisodeLookup(showID: 67676)
        XCTAssertFalse(manager.isEpisodeWatched(showId: 67676, seasonNumber: 1, episodeNumber: 6, playbackContext: context))
        XCTAssertFalse(manager.hasStartedOrCompletedEpisode(showId: 67676, seasonNumber: 1, episodeNumber: 6, playbackContext: context))
        XCTAssertEqual(manager.getEpisodeProgress(showId: 67676, seasonNumber: 1, episodeNumber: 6, playbackContext: context), 0)
        manager.markEpisodeAsWatched(showId: 67676, seasonNumber: 1, episodeNumber: 6, playbackContext: context, isAnime: true, owner: owner)
        let manuallyCompleted = try XCTUnwrap(manager.captureEpisodeLookup(showID: 67676).entries.first)
        XCTAssertTrue(manuallyCompleted.isWatched)
        XCTAssertEqual(manuallyCompleted.totalDuration, 1)
        XCTAssertTrue(manager.isEpisodeWatched(showId: 67676, seasonNumber: 1, episodeNumber: 6, playbackContext: context))
    }

    func testCompilationResetLeavesUnrelatedLegacyShortUntouched() throws {
        let owner = UUID()
        let manager = ProgressManager(profileID: owner)
        defer {
            manager.flushPendingSave()
            try? FileManager.default.removeItem(at: ProgressManager.progressFileURL(for: owner))
        }
        var legacy = EpisodeProgressEntry(showId: 67676, seasonNumber: 1, episodeNumber: 6)
        legacy.currentTime = 300
        legacy.totalDuration = 300
        legacy.isWatched = true
        var data = ProgressData()
        data.episodeProgress = [legacy]
        XCTAssertTrue(manager.replaceProgressDataForRestore(data, expectedProfileID: owner))
        manager.resetEpisodeProgress(showId: 67676, seasonNumber: 1, episodeNumber: 6,
            playbackContext: compilationContext(6), owner: owner)
        let remaining = try XCTUnwrap(manager.captureEpisodeLookup(showID: 67676).entries.first)
        XCTAssertTrue(remaining.isWatched)
        XCTAssertEqual(remaining.currentTime, 300)
        XCTAssertNil(remaining.playbackContext)
    }

    func testMarkPreviousCompilationsKeepsValidPhysicalAndCanonicalCoverage() throws {
        let owner = UUID()
        let manager = ProgressManager(profileID: owner)
        defer {
            manager.flushPendingSave()
            try? FileManager.default.removeItem(at: ProgressManager.progressFileURL(for: owner))
        }
        manager.markPreviousEpisodesAsWatched(showId: 67676, seasonNumber: 1, episodeNumber: 6,
            playbackContext: compilationContext(6), isAnime: true, owner: owner)
        let entries = manager.captureEpisodeLookup(showID: 67676).entries.sorted { $0.episodeNumber < $1.episodeNumber }
        XCTAssertEqual(entries.map(\.episodeNumber), [1, 2, 3, 4, 5])
        XCTAssertTrue(entries.allSatisfy { $0.isWatched && $0.playbackContext?.hasTrustedUnitProjection(showID: 67676) == true })
        XCTAssertEqual(entries.compactMap { $0.playbackContext?.canonicalCompletedEpisodeNumber(forMAL: false) }, [5, 10, 15, 20, 25])
    }

    func testFeatureMovieContextSurvivesPersistenceAndRejectsForeignMovie() throws {
        let context = EpisodePlaybackContext(localSeasonNumber: 2, localEpisodeNumber: 1,
            anilistMediaId: 170935, canonicalAniListMediaId: 170935, malMediaId: 57184,
            tmdbSeasonNumber: nil, tmdbEpisodeNumber: nil, tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: 24, animeSeasonEpisodeCount: 1, isSpecial: false, titleOnlySearch: false,
            unitProjection: .init(edition: .feature, canonicalAniListEpisodeRange: .init(lowerBound: 1, upperBound: 1),
                canonicalMALEpisodeRange: .init(lowerBound: 1, upperBound: 4), tmdbMovieID: 1220441))
        var movie = MovieProgressEntry(id: 1220441, title: "GREAT PRETENDER razbliuto")
        movie.currentTime = 100
        movie.totalDuration = 5000
        movie.playbackContext = context
        var data = ProgressData()
        data.movieProgress = [movie]
        let decoded = try JSONDecoder().decode(ProgressData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(ProgressPersistencePolicy.sanitized(decoded, preservingDeviceLocalReferences: true).movieProgress.first?.playbackContext, context)
        var foreign = MovieProgressEntry(id: 93816, title: "Foreign movie")
        foreign.playbackContext = context
        data.movieProgress = [foreign]
        XCTAssertNil(ProgressPersistencePolicy.sanitized(data, preservingDeviceLocalReferences: true).movieProgress.first?.playbackContext)
    }

    func testFeatureMovieRejectsPartDurationEvenWhenLaterUpdatesOmitContext() throws {
        let owner = UUID()
        let manager = ProgressManager(profileID: owner)
        defer {
            manager.flushPendingSave()
            try? FileManager.default.removeItem(at: ProgressManager.progressFileURL(for: owner))
        }
        let context = EpisodePlaybackContext(localSeasonNumber: 2, localEpisodeNumber: 1,
            anilistMediaId: 170935, canonicalAniListMediaId: 170935, malMediaId: 57184,
            tmdbSeasonNumber: nil, tmdbEpisodeNumber: nil, tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: nil, animeSeasonEpisodeCount: 1, isSpecial: false, titleOnlySearch: false,
            unitProjection: .init(edition: .feature, canonicalAniListEpisodeRange: .init(lowerBound: 1, upperBound: 1),
                canonicalMALEpisodeRange: .init(lowerBound: 1, upperBound: 4), tmdbMovieID: 1220441))
        manager.updateMovieProgress(movieId: 1220441, title: "GREAT PRETENDER razbliuto",
            currentTime: 1200, totalDuration: 1440, playbackContext: context, owner: owner)
        XCTAssertFalse(manager.isMovieWatched(movieId: 1220441))
        manager.updateMovieProgress(movieId: 1220441, title: "GREAT PRETENDER razbliuto",
            currentTime: 1440, totalDuration: 1440, owner: owner)
        XCTAssertFalse(manager.isMovieWatched(movieId: 1220441))
        XCTAssertEqual(manager.getMovieCurrentTime(movieId: 1220441, title: "GREAT PRETENDER razbliuto"), 0)
        manager.updateMovieProgress(movieId: 1220441, title: "GREAT PRETENDER razbliuto",
            currentTime: 5000, totalDuration: 5340, owner: owner)
        XCTAssertTrue(manager.isMovieWatched(movieId: 1220441))
    }

    func testShortPlaybackCannotCompleteCompiledCanonicalEpisodes() {
        let context = compilationContext(2)
        XCTAssertFalse(context.allowsProjectedPlaybackCompletion(duration: 4 * 60))
        XCTAssertFalse(context.allowsProjectedPlaybackCompletion(duration: .nan))
        XCTAssertTrue(context.allowsProjectedPlaybackCompletion(duration: 23 * 60))
        let movie = EpisodePlaybackContext(localSeasonNumber: 2, localEpisodeNumber: 1,
            anilistMediaId: 170935, canonicalAniListMediaId: 170935, malMediaId: 57184,
            tmdbSeasonNumber: nil, tmdbEpisodeNumber: nil, tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: nil, animeSeasonEpisodeCount: 1, isSpecial: false, titleOnlySearch: false,
            unitProjection: .init(edition: .feature, canonicalAniListEpisodeRange: .init(lowerBound: 1, upperBound: 1),
                canonicalMALEpisodeRange: .init(lowerBound: 1, upperBound: 4), tmdbMovieID: 1220441))
        XCTAssertFalse(movie.allowsProjectedPlaybackCompletion(duration: 24 * 60))
        XCTAssertTrue(movie.allowsProjectedPlaybackCompletion(duration: 89 * 60))
    }

    func testUnprovenPhysicalImportCannotExportCanonicalShortProgress() throws {
        let owner = UUID()
        let manager = ProgressManager(profileID: owner)
        defer {
            manager.flushPendingSave()
            try? FileManager.default.removeItem(at: ProgressManager.progressFileURL(for: owner))
        }
        manager.bulkMarkEpisodeNumbersAsWatched(showId: 67676, seasonNumber: 1, episodeNumbers: [24], owner: owner)
        let unproven = try XCTUnwrap(manager.captureEpisodeLookup(showID: 67676).entries.first)
        XCTAssertTrue(unproven.isWatched)
        XCTAssertNil(unproven.playbackContext)
        XCTAssertFalse(AnimeEpisodeIdentityPolicy.allowsCanonicalEpisodeTranslation(
            showId: unproven.showId, seasonNumber: unproven.seasonNumber, episodeNumber: unproven.episodeNumber,
            playbackContext: unproven.playbackContext))
        let verifiedContext = compilationContext(24)
        manager.bulkMarkEpisodeNumbersAsWatched(showId: 67676, seasonNumber: 1, episodeNumbers: [24],
            playbackContexts: [24: verifiedContext], owner: owner)
        let verified = try XCTUnwrap(manager.captureEpisodeLookup(showID: 67676).entries.first)
        XCTAssertTrue(AnimeEpisodeIdentityPolicy.allowsCanonicalEpisodeTranslation(
            showId: verified.showId, seasonNumber: verified.seasonNumber, episodeNumber: verified.episodeNumber,
            playbackContext: verified.playbackContext))
        XCTAssertEqual(verified.playbackContext?.canonicalCompletedEpisodeNumber(forMAL: false), 120)
        XCTAssertEqual(verified.playbackContext?.canonicalCompletedEpisodeNumber(forMAL: true), 120)
    }

    func testCanonicalTranslationRefusesUnknownFeatureEditionAndForeignCompilation() {
        XCTAssertFalse(AnimeEpisodeIdentityPolicy.allowsCanonicalEpisodeTranslation(
            showId: 93816, seasonNumber: 2, episodeNumber: 1, playbackContext: nil))
        XCTAssertFalse(AnimeEpisodeIdentityPolicy.allowsCanonicalEpisodeTranslation(
            showId: 93816, seasonNumber: 2, episodeNumber: 6, playbackContext: compilationContext(6)))
        XCTAssertFalse(AnimeEpisodeIdentityPolicy.allowsCanonicalEpisodeTranslation(
            showId: 67676, seasonNumber: 1, episodeNumber: 7, playbackContext: compilationContext(6)))
        XCTAssertFalse(AnimeEpisodeIdentityPolicy.allowsCanonicalEpisodeTranslation(
            showId: 67676, seasonNumber: 1, episodeNumber: 25, playbackContext: compilationContext(6).forEpisodeNumber(25)))
        let feature = EpisodePlaybackContext(localSeasonNumber: 2, localEpisodeNumber: 1,
            anilistMediaId: 170935, canonicalAniListMediaId: 170935, malMediaId: 57184,
            tmdbSeasonNumber: nil, tmdbEpisodeNumber: nil, tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: nil, animeSeasonEpisodeCount: 1, isSpecial: false, titleOnlySearch: true,
            unitProjection: .init(edition: .feature, canonicalAniListEpisodeRange: .init(lowerBound: 1, upperBound: 1),
                canonicalMALEpisodeRange: .init(lowerBound: 1, upperBound: 4), tmdbMovieID: 1220441))
        XCTAssertTrue(AnimeEpisodeIdentityPolicy.allowsCanonicalEpisodeTranslation(
            showId: 93816, seasonNumber: 2, episodeNumber: 1, playbackContext: feature))
        XCTAssertTrue(AnimeEpisodeIdentityPolicy.allowsCanonicalEpisodeTranslation(
            showId: 1220441, seasonNumber: 2, episodeNumber: 1, playbackContext: feature))
    }

    func testCanonicalTranslationPreservesOrdinarySourceSeasons() {
        XCTAssertTrue(AnimeEpisodeIdentityPolicy.allowsCanonicalEpisodeTranslation(
            showId: 67676, seasonNumber: 2, episodeNumber: 24, playbackContext: nil))
        XCTAssertTrue(AnimeEpisodeIdentityPolicy.allowsCanonicalEpisodeTranslation(
            showId: 93816, seasonNumber: 1, episodeNumber: 23, playbackContext: nil))
        XCTAssertTrue(AnimeEpisodeIdentityPolicy.allowsCanonicalEpisodeTranslation(
            showId: 220542, seasonNumber: 1, episodeNumber: 24, playbackContext: nil))
    }

    func testLegacyAndContradictedHighRowsCannotHideVerifiedCanonicalExport() throws {
        var legacy = EpisodeProgressEntry(showId: 67676, seasonNumber: 1, episodeNumber: 120)
        legacy.isWatched = true
        legacy.totalDuration = 1
        legacy.currentTime = 1
        var verified = EpisodeProgressEntry(showId: 67676, seasonNumber: 1, episodeNumber: 6)
        verified.playbackContext = compilationContext(6)
        verified.isWatched = true
        verified.totalDuration = 1
        verified.currentTime = 1
        var contradicted = EpisodeProgressEntry(showId: 67676, seasonNumber: 1, episodeNumber: 24)
        contradicted.playbackContext = compilationContext(24)
        contradicted.totalDuration = 240
        contradicted.currentTime = 240
        let candidates = AnimeEpisodeIdentityPolicy.canonicalExportCandidates([legacy, contradicted, verified])
        XCTAssertEqual(candidates.map(\.episodeNumber), [6])
        XCTAssertEqual(try XCTUnwrap(candidates.first).playbackContext?.canonicalCompletedEpisodeNumber(forMAL: false), 30)
        var ordinary = EpisodeProgressEntry(showId: 67676, seasonNumber: 2, episodeNumber: 24)
        ordinary.isWatched = true
        XCTAssertEqual(AnimeEpisodeIdentityPolicy.canonicalExportCandidates([ordinary]).map(\.episodeNumber), [24])
    }

    func testManualActionsWithoutReplacementRetainStoredVerifiedUnit() throws {
        let owner = UUID()
        let manager = ProgressManager(profileID: owner)
        defer {
            manager.flushPendingSave()
            try? FileManager.default.removeItem(at: ProgressManager.progressFileURL(for: owner))
        }
        let context = compilationContext(6)
        manager.updateEpisodeProgress(showId: 67676, seasonNumber: 1, episodeNumber: 6,
            currentTime: 120, totalDuration: 1380, playbackContext: context, isAnime: true, owner: owner)
        manager.markEpisodeAsWatched(showId: 67676, seasonNumber: 1, episodeNumber: 6, owner: owner)
        let manuallyCompleted = try XCTUnwrap(manager.captureEpisodeLookup(showID: 67676).entries.first)
        XCTAssertEqual(manuallyCompleted.playbackContext, context)
        XCTAssertTrue(manuallyCompleted.isWatched)
        manager.markPreviousEpisodesAsWatched(showId: 67676, seasonNumber: 1, episodeNumber: 7, owner: owner)
        let previous = manager.captureEpisodeLookup(showID: 67676).entries
        XCTAssertEqual(previous.first { $0.episodeNumber == 6 }?.playbackContext, context)
        XCTAssertNil(previous.first { $0.episodeNumber == 1 }?.playbackContext)
        XCTAssertEqual(AnimeEpisodeIdentityPolicy.canonicalExportCandidates(previous).map(\.episodeNumber), [6])
        let nextContext = compilationContext(8)
        manager.updateEpisodeProgress(showId: 67676, seasonNumber: 1, episodeNumber: 8,
            currentTime: 120, totalDuration: 1380, playbackContext: nextContext, isAnime: true, owner: owner)
        let item = ContinueWatchingItem(id: "episode_67676", tmdbId: 67676, isMovie: false, title: "Saiki",
            posterURL: nil, progress: 0.1, lastUpdated: Date(), seasonNumber: 1, episodeNumber: 8,
            currentTime: 120, totalDuration: 1380, playbackContext: nil, isAnime: true,
            statusText: nil, isWatchNext: false, traktPlaybackId: nil)
        manager.markContinueWatchingItemAsWatched(item, owner: owner)
        let continued = try XCTUnwrap(manager.captureEpisodeLookup(showID: 67676).entries.first { $0.episodeNumber == 8 })
        XCTAssertEqual(continued.playbackContext, nextContext)
        XCTAssertTrue(continued.isWatched)
        XCTAssertEqual(continued.playbackContext?.canonicalCompletedEpisodeNumber(forMAL: false), 40)
    }

    private func compilationContext(_ number: Int) -> EpisodePlaybackContext {
        let range = AnimeVerifiedEpisodeUnitPolicy.saikiCanonicalGroups[number - 1]
        return EpisodePlaybackContext(localSeasonNumber: 1, localEpisodeNumber: number,
            anilistMediaId: 21804, canonicalAniListMediaId: 21804, malMediaId: 33255,
            tmdbSeasonNumber: 1, tmdbEpisodeNumber: number, tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: number, animeSeasonEpisodeCount: 24, isSpecial: false, titleOnlySearch: false,
            unitProjection: .init(edition: .compilation, canonicalAniListEpisodeRange: range, canonicalMALEpisodeRange: range))
    }
}

final class AnimeExternalFeatureOwnershipTVTests: XCTestCase {
    func testFeaturePreflightRequiresOneClosedReciprocalUnownedONA() throws {
        let closed = closedRoot()
        let fullCandidate = try XCTUnwrap(closed.relations?.edges.first?.node.asAnime())
        XCTAssertEqual(AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidate(
            root: closed, selectedAniListID: 100, knownRegularOwnerIDs: [], hydratedCandidate: fullCandidate)?.id, 200)
        XCTAssertEqual(AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidate(
            root: closed, selectedAniListID: 100, knownRegularOwnerIDs: [100], hydratedCandidate: fullCandidate)?.id, 200)
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidate(
            root: closed, selectedAniListID: 100, knownRegularOwnerIDs: []))
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidate(
            root: closed, selectedAniListID: 200, knownRegularOwnerIDs: [], hydratedCandidate: fullCandidate))
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidate(
            root: closed, selectedAniListID: 100, knownRegularOwnerIDs: [200], hydratedCandidate: fullCandidate))
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidate(
            root: closed, selectedAniListID: 100, knownRegularOwnerIDs: [999], hydratedCandidate: fullCandidate))
        let ordinaryNeighbor = AniListAnime.AniListRelationEdge(relationType: "SEQUEL",
            node: node(anime(id: 201, format: "TV", episodes: 12)))
        let unknownNeighbor = AniListAnime.AniListRelationEdge(relationType: "SEQUEL",
            node: node(anime(id: 202, format: nil, status: "NOT_YET_RELEASED", episodes: nil)))
        let unrecognizedNeighbor = AniListAnime.AniListRelationEdge(relationType: "SEQUEL",
            node: node(anime(id: 204, format: "UNRECOGNIZED")))
        for neighbor in [ordinaryNeighbor, unknownNeighbor, unrecognizedNeighbor] {
            XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidate(
                root: closedRoot(rootNeighbors: [neighbor]), selectedAniListID: 100, knownRegularOwnerIDs: [],
                hydratedCandidate: fullCandidate))
            let expanded = closedRoot(candidateNeighbors: [neighbor])
            let expandedCandidate = try XCTUnwrap(expanded.relations?.edges.first?.node.asAnime())
            XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidate(
                root: expanded, selectedAniListID: 100, knownRegularOwnerIDs: [], hydratedCandidate: expandedCandidate))
        }
        let mappedNeighbor = AniListAnime.AniListRelationEdge(relationType: "SEQUEL",
            node: node(anime(id: 203, format: "SPECIAL")))
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidate(
            root: closedRoot(rootNeighbors: [mappedNeighbor]), selectedAniListID: 100, knownRegularOwnerIDs: [203],
            hydratedCandidate: fullCandidate))
        let shallow = root(edges: [.init(relationType: "PREQUEL", node: node(anime(id: 200)))])
        XCTAssertEqual(AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidateID(
            root: shallow, selectedAniListID: 100, knownRegularOwnerIDs: []), 200)
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidate(
            root: shallow, selectedAniListID: 100, knownRegularOwnerIDs: []))
        let successor = AniListAnime.AniListRelationEdge(relationType: "SEQUEL", node: node(root()))
        XCTAssertEqual(AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidate(
            root: shallow, selectedAniListID: 100, knownRegularOwnerIDs: [],
            hydratedCandidate: anime(id: 200, edges: [successor]))?.id, 200)
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidate(
            root: shallow, selectedAniListID: 100, knownRegularOwnerIDs: [],
            hydratedCandidate: anime(id: 201, edges: [successor])))
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidate(
            root: shallow, selectedAniListID: 100, knownRegularOwnerIDs: [],
            hydratedCandidate: anime(id: 200, format: "MOVIE", edges: [successor])))
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidate(
            root: shallow, selectedAniListID: 100, knownRegularOwnerIDs: [],
            hydratedCandidate: anime(id: 200, edges: [successor, unknownNeighbor])))
    }

    func testIndependentFeatureRequiresExactTitleAndRecordedDigitalReleaseDay() {
        XCTAssertTrue(detaches())
        XCTAssertTrue(detaches(movie: movie(region: "GB")))
        XCTAssertFalse(detaches(movie: movie(title: "Different Feature")))
        XCTAssertFalse(detaches(movie: movie(releaseType: 3)))
        XCTAssertFalse(detaches(movie: movie(region: "JP", digitalDate: "2024-01-22")))
        XCTAssertFalse(detaches(movie: movie(digitalDate: "2024-01-20")))
        XCTAssertFalse(detaches(movie: movie(digitalDate: "2024-01-21-invalid")))
        XCTAssertFalse(detaches(movie: movie(language: "en")))
        XCTAssertFalse(detaches(movie: movie(runtime: 0)))
        XCTAssertFalse(detaches(movie: movie(genres: [])))
        XCTAssertFalse(detaches(movie: movie(imdbID: nil)))
        XCTAssertFalse(detaches(movie: movie(imdbID: "ttinvalid")))
        XCTAssertFalse(detaches(movie: movie(imdbID: "tt300")))
        XCTAssertFalse(detaches(movie: movie(imdbID: "tt0000000")))
        XCTAssertFalse(detaches(movie: movie(imdbID: "tt1234567890123")))
        XCTAssertFalse(detaches(exclusiveMovieID: nil))
        XCTAssertFalse(detaches(exclusiveMovieID: 301))
    }

    func testSelectedMappedAndOrdinaryCandidatesKeepEpisodeOwnership() {
        XCTAssertFalse(detaches(selectedID: 200))
        XCTAssertFalse(detaches(hasSameShowPlacement: true))
        XCTAssertFalse(detaches(candidate: anime(id: 200, format: "TV")))
        XCTAssertFalse(detaches(candidate: anime(id: 200, episodes: 2)))
        XCTAssertFalse(detaches(candidate: anime(id: 200, status: "RELEASING")))
        XCTAssertFalse(detaches(candidate: anime(id: 200, end: nil)))
        XCTAssertFalse(detaches(candidate: anime(id: 200,
            end: .init(year: 2024, month: 1, day: 22))))
    }

    func testSingleRowCourAndSameDayCustomEpisodePreserveTheFeatureInTheShow() {
        let singleRowCour = Array(sourceRows().prefix(3))
        XCTAssertFalse(detaches(counts: [1: 2, 2: 1], rows: singleRowCour))
        var sameDay = sourceRows()
        sameDay[1] = episode(id: 12, season: 1, number: 2,
            date: "2024-01-21", title: "A Custom Episode Title")
        XCTAssertFalse(detaches(rows: sameDay))
        var exactTitle = sourceRows()
        exactTitle[1] = episode(id: 12, season: 1, number: 2,
            date: "2019-01-08", title: "Long Running Series: Separate Feature")
        XCTAssertFalse(detaches(rows: exactTitle))
        XCTAssertFalse(detaches(movie: movie(title: "Long Running Series")))
    }

    func testCoincidentCustomEpisodeRequiresDistinctValidatedIMDbAuthority() throws {
        var sameDay = sourceRows()
        sameDay[1] = episode(id: 12, season: 1, number: 2,
            date: "2024-01-21", title: "A Custom Episode Title")
        let candidates = try XCTUnwrap(AnimeExternalFeatureOwnershipPolicy.coincidentEpisodeIdentityCandidates(
            candidate: anime(id: 200), movie: movie(), sourceEpisodes: sameDay))
        XCTAssertEqual(candidates.map(\.id), [12])
        XCTAssertTrue(detaches(rows: sameDay, episodeIMDbIDs: [12: "tt30869313"]))
        XCTAssertFalse(detaches(rows: sameDay))
        XCTAssertFalse(detaches(rows: sameDay, episodeIMDbIDs: [12: "tt30475122"]))
        XCTAssertFalse(detaches(rows: sameDay, episodeIMDbIDs: [12: "ttinvalid"]))
        XCTAssertFalse(detaches(rows: sameDay, episodeIMDbIDs: [12: "tt999"]))
        XCTAssertFalse(detaches(rows: sameDay, episodeIMDbIDs: [12: "tt0000000"]))
        XCTAssertFalse(detaches(rows: sameDay, episodeIMDbIDs: [12: "tt1234567890123"]))
        XCTAssertFalse(detaches(rows: sameDay, episodeIMDbIDs: [21: "tt30869313"]))
        for placeholder in ["", "Episode 2", "TBA", "Unknown", "Long Running Series: Separate Feature"] {
            var ambiguous = sameDay
            ambiguous[1] = episode(id: 12, season: 1, number: 2, date: "2024-01-21", title: placeholder)
            XCTAssertFalse(detaches(rows: ambiguous, episodeIMDbIDs: [12: "tt30869313"]), placeholder)
        }
        var baseDate = sameDay
        baseDate[1] = episode(id: 12, season: 1, number: 2, date: "2024-01-22", title: "Another Custom Chapter")
        XCTAssertFalse(detaches(rows: baseDate))
        XCTAssertTrue(detaches(rows: baseDate, episodeIMDbIDs: [12: "tt30869313"]))
    }

    func testCoincidentIdentityQueriesRemainBoundedAndUnique() throws {
        let rows = (1...4).map { episode(id: 100 + $0, season: 1, number: $0,
            date: "2024-01-21", title: "Custom Chapter \($0)") }
        XCTAssertEqual(try XCTUnwrap(AnimeExternalFeatureOwnershipPolicy.coincidentEpisodeIdentityCandidates(
            candidate: anime(id: 200), movie: movie(), sourceEpisodes: rows)).map(\.id), [101, 102, 103, 104])
        let fifth = episode(id: 105, season: 1, number: 5, date: "2024-01-21", title: "Custom Chapter 5")
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.coincidentEpisodeIdentityCandidates(
            candidate: anime(id: 200), movie: movie(), sourceEpisodes: rows + [fifth]))
        let duplicate = episode(id: 101, season: 1, number: 5, date: "2024-01-21", title: "Custom Chapter 5")
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.coincidentEpisodeIdentityCandidates(
            candidate: anime(id: 200), movie: movie(), sourceEpisodes: Array(rows.prefix(3)) + [duplicate]))
    }

    func testMovieIMDbFindAuthorityRequiresOnlyTheExpectedFilm() throws {
        XCTAssertTrue(try TMDBService.ExclusiveMovieIMDbMatch.decode(
            movieFindData(movieIDs: [300]), expectedMovieID: 300))
        for movies in [[], [301], [300, 301], [300, 300], [0], [-300]] {
            XCTAssertFalse(try TMDBService.ExclusiveMovieIMDbMatch.decode(
                movieFindData(movieIDs: movies), expectedMovieID: 300))
        }
        XCTAssertFalse(try TMDBService.ExclusiveMovieIMDbMatch.decode(
            movieFindData(movieIDs: [300], tvIDs: [100]), expectedMovieID: 300))
        XCTAssertFalse(try TMDBService.ExclusiveMovieIMDbMatch.decode(
            movieFindData(movieIDs: [300], episodeIDs: [12]), expectedMovieID: 300))
        XCTAssertFalse(try TMDBService.ExclusiveMovieIMDbMatch.decode(
            movieFindData(movieIDs: [300], seasonIDs: [1]), expectedMovieID: 300))
    }

    func testOpenEndedInventoryPreservesActualAbsoluteCoordinatesAcrossSeasons() throws {
        let input = sourceRows()
        let rows = try XCTUnwrap(AnimeExternalFeatureOwnershipPolicy.validatedOpenEndedInventory(
            hasExactRootIdentity: true, root: root(), tmdbSeasonEpisodeCounts: [1: 2, 2: 2],
            sourceEpisodes: [input[3], input[1], input[2], input[0]]))
        XCTAssertEqual(rows.map(\.id), [11, 12, 21, 22])
        XCTAssertEqual(rows.map(\.seasonNumber), [1, 1, 2, 2])
        XCTAssertEqual(rows.map(\.episodeNumber), [1, 2, 26, 27])
        XCTAssertEqual(rows.map(\.name), input.map(\.name))
        XCTAssertEqual(rows.map(\.airDate), input.map(\.airDate))
        XCTAssertTrue(detaches(rows: rows))
    }

    func testOpenEndedInventoryRejectsIncompleteDuplicateAndInvalidPhysicalRows() {
        let valid = sourceRows()
        var duplicateID = valid
        duplicateID[3] = episode(id: 21, season: 2, number: 27, date: "2026-10-07")
        var invalidID = valid
        invalidID[3] = episode(id: 0, season: 2, number: 27, date: "2026-10-07")
        var negativeID = valid
        negativeID[3] = episode(id: -22, season: 2, number: 27, date: "2026-10-07")
        var duplicateCoordinate = valid
        duplicateCoordinate[3] = episode(id: 22, season: 2, number: 26, date: "2026-10-07")
        var invalidCoordinate = valid
        invalidCoordinate[3] = episode(id: 22, season: 2, number: 0, date: "2026-10-07")
        var foreignSeason = valid
        foreignSeason[3] = episode(id: 22, season: 3, number: 27, date: "2026-10-07")
        var invalidDate = valid
        invalidDate[3] = episode(id: 22, season: 2, number: 27, date: "2026-02-30")
        var reversedDates = valid
        reversedDates[3] = episode(id: 22, season: 2, number: 27, date: "2026-09-01")
        for (name, rows) in [("missing", Array(valid.dropLast())), ("summary only", []),
            ("duplicate ID", duplicateID), ("zero ID", invalidID), ("negative ID", negativeID),
            ("duplicate coordinate", duplicateCoordinate), ("zero episode", invalidCoordinate),
            ("foreign season", foreignSeason), ("invalid date", invalidDate), ("reversed dates", reversedDates)] {
            XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.validatedOpenEndedInventory(
                hasExactRootIdentity: true, root: root(), tmdbSeasonEpisodeCounts: [1: 2, 2: 2],
                sourceEpisodes: rows), name)
            XCTAssertFalse(detaches(rows: rows), name)
        }
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.validatedOpenEndedInventory(
            hasExactRootIdentity: false, root: root(), tmdbSeasonEpisodeCounts: [1: 2, 2: 2], sourceEpisodes: valid))
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.validatedOpenEndedInventory(
            hasExactRootIdentity: true, root: root(format: "ONA"),
            tmdbSeasonEpisodeCounts: [1: 2, 2: 2], sourceEpisodes: valid))
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.validatedOpenEndedInventory(
            hasExactRootIdentity: true, root: root(episodes: 4),
            tmdbSeasonEpisodeCounts: [1: 2, 2: 2], sourceEpisodes: valid))
    }

    func testMovieSearchDoesNotChooseBetweenCompetingExactIdentities() {
        let first = searchMovie(id: 300)
        XCTAssertEqual(AnimeExternalFeatureOwnershipPolicy.uniqueMovieID(candidate: anime(id: 200), movies: [first]), 300)
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.uniqueMovieID(
            candidate: anime(id: 200), movies: [first, searchMovie(id: 301)]))
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.uniqueMovieID(candidate: anime(id: 200), movies: []))
        XCTAssertNil(AnimeExternalFeatureOwnershipPolicy.uniqueMovieID(
            candidate: anime(id: 200), movies: Array(repeating: first, count: 20)))
    }

    private func detaches(
        candidate: AniListAnime? = nil, movie suppliedMovie: TMDBMovieDetail? = nil,
        selectedID: Int? = 100, hasSameShowPlacement: Bool = false,
        counts: [Int: Int] = [1: 2, 2: 2], rows: [TMDBEpisode]? = nil,
        exclusiveMovieID: Int? = 300, episodeIMDbIDs: [Int: String] = [:]
    ) -> Bool {
        AnimeExternalFeatureOwnershipPolicy.isDetachedFeaturePrequel(
            candidate: candidate ?? anime(id: 200), root: root(), movie: suppliedMovie ?? movie(),
            selectedAniListID: selectedID, hasSameShowPlacement: hasSameShowPlacement,
            tmdbSeasonEpisodeCounts: counts, sourceEpisodes: rows ?? sourceRows(),
            exclusiveMovieID: exclusiveMovieID, independentlyDistinctEpisodeIMDbIDs: episodeIMDbIDs)
    }

    private func closedRoot(
        rootNeighbors: [AniListAnime.AniListRelationEdge] = [],
        candidateNeighbors: [AniListAnime.AniListRelationEdge] = []
    ) -> AniListAnime {
        let successor = AniListAnime.AniListRelationEdge(relationType: "SEQUEL", node: node(root()))
        let candidate = anime(id: 200, edges: [successor] + candidateNeighbors)
        return root(edges: [.init(relationType: "PREQUEL", node: node(candidate))] + rootNeighbors)
    }

    private func node(_ anime: AniListAnime) -> AniListAnime.AniListRelationNode {
        .init(id: anime.id, idMal: anime.idMal, externalLinks: anime.externalLinks, averageScore: anime.averageScore,
            isAdult: anime.isAdult, genres: anime.genres, tags: anime.tags, title: anime.title, episodes: anime.episodes,
            status: anime.status, startDate: anime.startDate, endDate: anime.endDate, seasonYear: anime.seasonYear,
            season: anime.season, format: anime.format, type: anime.type, coverImage: anime.coverImage, relations: anime.relations)
    }

    private func root(
        format: String = "TV", episodes: Int? = nil, edges: [AniListAnime.AniListRelationEdge] = []
    ) -> AniListAnime {
        anime(id: 100, title: "Long Running Series", format: format, status: "RELEASING", episodes: episodes,
            start: .init(year: 2019, month: 1, day: 1), end: nil, edges: edges)
    }

    private func anime(
        id: Int, title: String = "Long Running Series: Separate Feature", format: String? = "ONA",
        status: String = "FINISHED", episodes: Int? = 1,
        start: AniListDate? = .init(year: 2024, month: 1, day: 21),
        end: AniListDate? = .init(year: 2024, month: 1, day: 21),
        edges: [AniListAnime.AniListRelationEdge] = []
    ) -> AniListAnime {
        AniListAnime(id: id, idMal: nil, externalLinks: nil, averageScore: nil, isAdult: false, genres: nil,
            tags: nil, title: .init(romaji: title, english: title, native: nil), episodes: episodes,
            status: status, startDate: start, endDate: end, seasonYear: start?.year, season: nil,
            coverImage: nil, format: format, type: "ANIME", nextAiringEpisode: nil, relations: .init(edges: edges))
    }

    private func movie(
        title: String = "Long Running Series: Separate Feature", region: String = "US", releaseType: Int = 4,
        digitalDate: String = "2024-01-21", language: String = "ja", runtime: Int = 88,
        imdbID: String? = "tt30475122",
        genres: [TMDBGenre] = [.init(id: 16, name: "Animation")]
    ) -> TMDBMovieDetail {
        TMDBMovieDetail(id: 300, title: title, overview: nil, posterPath: nil, backdropPath: nil,
            releaseDate: "2024-01-22", voteAverage: 0, popularity: 0, runtime: runtime, genres: genres,
            tagline: nil, status: "Released", budget: nil, revenue: nil, imdbId: imdbID, originalLanguage: language,
            originalTitle: title, adult: false, voteCount: 0, releaseDates: .init(results: [
                .init(iso31661: region, releaseDates: [.init(certification: "", iso6391: nil, note: nil,
                    releaseDate: digitalDate + "T00:00:00.000Z", type: releaseType)])]))
    }

    private func movieFindData(
        movieIDs: [Int], tvIDs: [Int] = [], episodeIDs: [Int] = [], seasonIDs: [Int] = []
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "movie_results": movieIDs.map { ["id": $0] },
            "tv_results": tvIDs.map { ["id": $0] },
            "tv_episode_results": episodeIDs.map { ["id": $0] },
            "tv_season_results": seasonIDs.map { ["id": $0] }
        ])
    }

    private func searchMovie(id: Int) -> TMDBMovie {
        TMDBMovie(id: id, title: "Long Running Series: Separate Feature", overview: nil, posterPath: nil,
            backdropPath: nil, releaseDate: "2024-02-22", voteAverage: 0, popularity: 0, adult: false,
            genreIds: [16], originalLanguage: "ja", originCountry: ["JP"])
    }

    private func sourceRows() -> [TMDBEpisode] {
        [episode(id: 11, season: 1, number: 1, date: "2019-01-01"),
         episode(id: 12, season: 1, number: 2, date: "2019-01-08"),
         episode(id: 21, season: 2, number: 26, date: "2026-09-30"),
         episode(id: 22, season: 2, number: 27, date: "2026-10-07")]
    }

    private func episode(id: Int, season: Int, number: Int, date: String, title: String = "Ordinary Chapter") -> TMDBEpisode {
        TMDBEpisode(id: id, name: title, overview: nil, stillPath: nil, episodeNumber: number,
            seasonNumber: season, airDate: date, runtime: 24, voteAverage: 0, voteCount: 0)
    }
}
