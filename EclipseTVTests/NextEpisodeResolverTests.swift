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
