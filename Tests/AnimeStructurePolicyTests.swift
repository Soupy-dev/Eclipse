import Foundation
import XCTest
@testable import Eclipse

#if os(iOS)
private struct AnimeFillerHTTPStub {
    let statusCode: Int
    let body: Data
    let headers: [String: String]

    init(statusCode: Int, json: String, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = Data(json.utf8)
        self.headers = headers
    }
}

private final class AnimeFillerURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stubs: [AnimeFillerHTTPStub] = []
    private static var urls: [URL] = []

    static func configure(stubs: [AnimeFillerHTTPStub]) {
        lock.lock()
        self.stubs = stubs
        urls = []
        lock.unlock()
    }

    static func requestedURLs() -> [URL] {
        lock.lock()
        let result = urls
        lock.unlock()
        return result
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let stub = Self.stubs.isEmpty ? nil : Self.stubs.removeFirst()
        if let url = request.url {
            Self.urls.append(url)
        }
        Self.lock.unlock()

        guard let stub,
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: stub.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AnimeStructurePolicyTests: XCTestCase {
    func testAniListExplicitShutdown403UsesMALFallback() {
        let error = NSError(
            domain: "AniList",
            code: 403,
            userInfo: [
                NSLocalizedDescriptionKey: "AniList error (HTTP 403): The AniList API has been temporarily disabled due to severe stability issues."
            ]
        )

        let reason = AnimeProviderHealthCenter.shared.classifyAniListFailure(error)

        XCTAssertEqual(reason.rawValue, AnimeProviderFailureReason.anilistUnavailable.rawValue)
        XCTAssertTrue(AnimeProviderHealthCenter.shared.shouldUseMALFallback(for: reason))
    }

    func testAniListGeneric403DoesNotMasqueradeAsServiceOutage() {
        let error = NSError(
            domain: "AniList",
            code: 403,
            userInfo: [NSLocalizedDescriptionKey: "AniList error (HTTP 403): Forbidden"]
        )

        let reason = AnimeProviderHealthCenter.shared.classifyAniListFailure(error)

        XCTAssertEqual(reason.rawValue, AnimeProviderFailureReason.unknown.rawValue)
        XCTAssertFalse(AnimeProviderHealthCenter.shared.shouldUseMALFallback(for: reason))
    }

    func testExactCoverageWinsDespiteUnresolvedMappingRow() {
        XCTAssertTrue(AnimeStructurePolicy.acceptsMappedCoverage(
            lookupIsComplete: true,
            hasUnresolvedIdentity: true,
            hasExactCoverage: true,
            allowsSingleOpenEndedSeries: false
        ))
    }

    func testUnresolvedMappingRowRejectsOpenEndedException() {
        XCTAssertFalse(AnimeStructurePolicy.acceptsMappedCoverage(
            lookupIsComplete: true,
            hasUnresolvedIdentity: true,
            hasExactCoverage: false,
            allowsSingleOpenEndedSeries: true
        ))
    }

    func testJujutsuKaisenStyleStructureStillYieldsTMDBCoordinates() {
        let tmdbSeasons = [1: 59]
        let segments: [AnimeStructureCoverageSegment] = [
            .init(mappedTMDBSeason: 1, episodeCount: 24),
            .init(mappedTMDBSeason: 2, episodeCount: 23),
            .init(mappedTMDBSeason: 3, episodeCount: 12)
        ]

        XCTAssertFalse(
            AnimeStructurePolicy.hasExactCoverage(
                tmdbSeasonEpisodeCounts: tmdbSeasons,
                segments: segments
            ),
            "AniMap hints at TMDB seasons 2 and 3 that this show does not have, so per-season coverage is not exact"
        )
        XCTAssertTrue(
            AnimeStructurePolicy.hasMatchingEpisodeTotals(
                tmdbSeasonEpisodeCounts: tmdbSeasons,
                segments: segments
            ),
            "24 + 23 + 12 is exactly TMDB's 59 episodes, so the two lists correspond index for index"
        )
        XCTAssertTrue(
            AnimeStructurePolicy.allowsLinearTMDBCoordinates(
                hydrationPolicy: .initiallyVisible,
                hasExactCoverage: false,
                hasMatchingEpisodeTotals: true
            ),
            "Without this the sheet skips every provider and reports nothing searched"
        )
    }

    func testEpisodeTotalsMustMatchExactlyBeforeCoordinatesAreAllowed() {
        XCTAssertFalse(AnimeStructurePolicy.hasMatchingEpisodeTotals(
            tmdbSeasonEpisodeCounts: [1: 59],
            segments: [
                .init(mappedTMDBSeason: nil, episodeCount: 24),
                .init(mappedTMDBSeason: nil, episodeCount: 23)
            ]
        ))
        XCTAssertFalse(
            AnimeStructurePolicy.hasMatchingEpisodeTotals(
                tmdbSeasonEpisodeCounts: [1: 59],
                segments: [
                    .init(mappedTMDBSeason: nil, episodeCount: 24),
                    .init(mappedTMDBSeason: nil, episodeCount: nil)
                ]
            ),
            "A segment with an unknown episode count makes the running total meaningless"
        )
        XCTAssertFalse(AnimeStructurePolicy.hasMatchingEpisodeTotals(
            tmdbSeasonEpisodeCounts: [:],
            segments: [.init(mappedTMDBSeason: nil, episodeCount: 24)]
        ))
        XCTAssertFalse(AnimeStructurePolicy.hasMatchingEpisodeTotals(
            tmdbSeasonEpisodeCounts: [1: 24],
            segments: []
        ))
        XCTAssertFalse(
            AnimeStructurePolicy.allowsLinearTMDBCoordinates(
                hydrationPolicy: .initiallyVisible,
                hasExactCoverage: false,
                hasMatchingEpisodeTotals: false
            ),
            "Refusing to guess is still the behaviour when the totals disagree"
        )
    }

    func testSpecialsSeasonIsExcludedFromTheTotalsComparison() {
        XCTAssertTrue(AnimeStructurePolicy.hasMatchingEpisodeTotals(
            tmdbSeasonEpisodeCounts: [0: 12, 1: 24],
            segments: [.init(mappedTMDBSeason: 1, episodeCount: 24)]
        ))
    }

    func testDirectContinuationONAsAreNotDetachedSpecialCandidates() {
        XCTAssertTrue(AnimeRelationRolePolicy.isRegularContinuationCandidate(
            relationType: "SEQUEL",
            mediaFormat: "ONA"
        ))
        XCTAssertTrue(AnimeRelationRolePolicy.isRegularContinuationCandidate(
            relationType: "PREQUEL",
            mediaFormat: "ONA"
        ))
        XCTAssertFalse(AnimeRelationRolePolicy.isDetachedSpecialCandidate(
            relationType: "SEQUEL",
            mediaFormat: "ONA",
            titleCandidates: ["Link Click Season 3", "Shiguang Dailiren III"]
        ))
        XCTAssertFalse(AnimeRelationRolePolicy.isDetachedSpecialCandidate(
            relationType: "PREQUEL",
            mediaFormat: "ONA",
            titleCandidates: ["STEEL BALL RUN JoJo's Bizarre Adventure 2nd - 3rd STAGE"]
        ))
        XCTAssertTrue(AnimeRelationRolePolicy.isExactSelectedRegularEntry(
            mediaID: 191832,
            selectedMediaID: 191832,
            mediaFormat: "ONA"
        ))
        XCTAssertTrue(AnimeRelationRolePolicy.isExactSelectedRegularEntry(
            mediaID: 210482,
            selectedMediaID: 210482,
            mediaFormat: "ONA"
        ))
        XCTAssertFalse(AnimeRelationRolePolicy.isExactSelectedRegularEntry(
            mediaID: 210482,
            selectedMediaID: 190327,
            mediaFormat: "ONA"
        ))
    }

    func testDetachedONASideStoryAndOVAStaySpecialCandidates() {
        XCTAssertTrue(AnimeRelationRolePolicy.isDetachedSpecialCandidate(
            relationType: "SIDE_STORY",
            mediaFormat: "ONA",
            titleCandidates: ["Another World"]
        ))
        XCTAssertTrue(AnimeRelationRolePolicy.isDetachedSpecialCandidate(
            relationType: "SEQUEL",
            mediaFormat: "OVA",
            titleCandidates: ["Bonus Episode"]
        ))
    }

    func testUnmappedSingleSpecialHydratesFromUniqueSeasonZeroDate() {
        let seasonZero = specialSeasonDetail(episodes: [
            tmdbSpecialEpisode(number: 1, name: "First Extra", airDate: "2024-01-01"),
            tmdbSpecialEpisode(number: 2, name: "The OVA", airDate: "2024-02-14"),
            tmdbSpecialEpisode(number: 3, name: "Recap", airDate: "2024-03-01")
        ])

        let hydrated = AnimeSpecialEpisodeHydrationPolicy.exactEpisodes(
            episodeCount: 1,
            exactReleaseDate: "2024-02-14",
            mappedSeasonNumber: nil,
            seasonDetailsByNumber: [0: seasonZero]
        )

        XCTAssertEqual(hydrated.map(\.episodeNumber), [2])
        XCTAssertEqual(hydrated.first?.name, "The OVA")
    }

    func testMultiEpisodeSpecialHydratesOnlyFromUniqueContiguousDateWindow() {
        let seasonZero = specialSeasonDetail(episodes: [
            tmdbSpecialEpisode(number: 1, name: "Unrelated", airDate: "2024-01-01"),
            tmdbSpecialEpisode(number: 2, name: "OVA Part One", airDate: "2024-02-14"),
            tmdbSpecialEpisode(number: 3, name: "OVA Part Two", airDate: "2024-02-21"),
            tmdbSpecialEpisode(number: 4, name: "Later Extra", airDate: "2024-04-01")
        ])

        let hydrated = AnimeSpecialEpisodeHydrationPolicy.exactEpisodes(
            episodeCount: 2,
            exactReleaseDate: "2024-02-14",
            mappedSeasonNumber: nil,
            seasonDetailsByNumber: [0: seasonZero]
        )

        XCTAssertEqual(hydrated.map(\.episodeNumber), [2, 3])
        XCTAssertEqual(hydrated.map(\.name), ["OVA Part One", "OVA Part Two"])
    }

    func testSpecialHydrationRejectsAmbiguousSeasonZeroDate() {
        let seasonZero = specialSeasonDetail(episodes: [
            tmdbSpecialEpisode(number: 1, name: "Extra A", airDate: "2024-02-14"),
            tmdbSpecialEpisode(number: 2, name: "Extra B", airDate: "2024-02-14"),
            tmdbSpecialEpisode(number: 3, name: "Extra C", airDate: "2024-03-01")
        ])

        XCTAssertTrue(AnimeSpecialEpisodeHydrationPolicy.exactEpisodes(
            episodeCount: 1,
            exactReleaseDate: "2024-02-14",
            mappedSeasonNumber: nil,
            seasonDetailsByNumber: [0: seasonZero]
        ).isEmpty)
        XCTAssertTrue(AnimeSpecialEpisodeHydrationPolicy.exactEpisodes(
            episodeCount: 2,
            exactReleaseDate: nil,
            mappedSeasonNumber: nil,
            seasonDetailsByNumber: [0: seasonZero]
        ).isEmpty)
    }

    func testSingleTMDBSeasonRejectsNonexistentExplicitSeason() {
        XCTAssertFalse(AnimeStructurePolicy.hasExactCoverage(
            tmdbSeasonEpisodeCounts: [1: 24],
            segments: [
                .init(mappedTMDBSeason: 3, episodeCount: 24)
            ]
        ))
    }

    func testFlattenedCoursAcceptExactCountAndContiguousProviderOrder() {
        XCTAssertTrue(AnimeStructurePolicy.hasExactCoverage(
            tmdbSeasonEpisodeCounts: [1: 23],
            segments: [
                .init(mappedTMDBSeason: 1, episodeCount: 11),
                .init(mappedTMDBSeason: 1, episodeCount: 12)
            ]
        ))
        XCTAssertTrue(AnimeStructurePolicy.hasCompatibleMappedOrder(
            [
                .init(mappedTMDBSeason: 1, mappedTVDBSeason: 1, tvdbEpisodeOffset: 0, episodeCount: 11),
                .init(mappedTMDBSeason: 1, mappedTVDBSeason: 1, tvdbEpisodeOffset: 11, episodeCount: 12)
            ],
            expectedTMDBSeasonCount: 1
        ))
    }

    func testBleachAllowsSingletonUnknownTVDBThenSplitSecondSeason() {
        XCTAssertTrue(AnimeStructurePolicy.hasExactCoverage(
            tmdbSeasonEpisodeCounts: [1: 366, 2: 52],
            segments: [
                .init(mappedTMDBSeason: 1, episodeCount: 366),
                .init(mappedTMDBSeason: 2, episodeCount: 13),
                .init(mappedTMDBSeason: 2, episodeCount: 13),
                .init(mappedTMDBSeason: 2, episodeCount: 14),
                .init(mappedTMDBSeason: 2, episodeCount: 12)
            ]
        ))
        XCTAssertTrue(AnimeStructurePolicy.hasCompatibleMappedOrder(
            [
                .init(mappedTMDBSeason: 1, mappedTVDBSeason: -1, tvdbEpisodeOffset: 0, episodeCount: 366),
                .init(mappedTMDBSeason: 2, mappedTVDBSeason: 17, tvdbEpisodeOffset: 0, episodeCount: 13),
                .init(mappedTMDBSeason: 2, mappedTVDBSeason: 17, tvdbEpisodeOffset: 13, episodeCount: 13),
                .init(mappedTMDBSeason: 2, mappedTVDBSeason: 17, tvdbEpisodeOffset: 26, episodeCount: 14),
                .init(mappedTMDBSeason: 2, mappedTVDBSeason: 17, tvdbEpisodeOffset: 40, episodeCount: 12)
            ],
            expectedTMDBSeasonCount: 2
        ))
    }

    func testAttackOnTitanFinalSpecialCompletesRegularSeasonFour() {
        XCTAssertTrue(AnimeStructurePolicy.hasExactCoverage(
            tmdbSeasonEpisodeCounts: [1: 25, 2: 12, 3: 22, 4: 30],
            segments: [
                .init(mappedTMDBSeason: 1, episodeCount: 25),
                .init(mappedTMDBSeason: 2, episodeCount: 12),
                .init(mappedTMDBSeason: 3, episodeCount: 12),
                .init(mappedTMDBSeason: 3, episodeCount: 10),
                .init(mappedTMDBSeason: 4, episodeCount: 16),
                .init(mappedTMDBSeason: 4, episodeCount: 12),
                .init(mappedTMDBSeason: 4, episodeCount: 2)
            ]
        ))
        XCTAssertTrue(AnimeStructurePolicy.hasCompatibleMappedOrder(
            [
                .init(mappedTMDBSeason: 1, mappedTVDBSeason: 1, tvdbEpisodeOffset: 0, episodeCount: 25),
                .init(mappedTMDBSeason: 2, mappedTVDBSeason: 2, tvdbEpisodeOffset: 0, episodeCount: 12),
                .init(mappedTMDBSeason: 3, mappedTVDBSeason: 3, tvdbEpisodeOffset: 0, episodeCount: 12),
                .init(mappedTMDBSeason: 3, mappedTVDBSeason: 3, tvdbEpisodeOffset: 12, episodeCount: 10),
                .init(mappedTMDBSeason: 4, mappedTVDBSeason: 4, tvdbEpisodeOffset: 0, episodeCount: 16),
                .init(mappedTMDBSeason: 4, mappedTVDBSeason: 4, tvdbEpisodeOffset: 16, episodeCount: 12),
                .init(mappedTMDBSeason: 4, mappedTVDBSeason: 4, tvdbEpisodeOffset: 28, episodeCount: 2)
            ],
            expectedTMDBSeasonCount: 4
        ))
    }

    func testDescendingTMDBMappingCannotOverrideLegacyOrder() {
        XCTAssertFalse(AnimeStructurePolicy.hasCompatibleMappedOrder(
            [
                .init(mappedTMDBSeason: 2, mappedTVDBSeason: 1, tvdbEpisodeOffset: 0, episodeCount: 12),
                .init(mappedTMDBSeason: 1, mappedTVDBSeason: 2, tvdbEpisodeOffset: 0, episodeCount: 12)
            ],
            expectedTMDBSeasonCount: 2
        ))
    }

    func testUnknownEpisodeCountNeverPassesExactCoverage() {
        XCTAssertFalse(AnimeStructurePolicy.hasExactCoverage(
            tmdbSeasonEpisodeCounts: [1: 12],
            segments: [.init(mappedTMDBSeason: 1, episodeCount: nil)]
        ))
    }

    func testPreviewCoverageAcceptsSmallCourDriftAndFutureOnlySeason() {
        XCTAssertTrue(AnimeStructurePolicy.hasSafePreviewCoverage(
            lookupIsComplete: true,
            hasUnresolvedIdentity: false,
            tmdbSeasonEpisodeCounts: [1: 23, 2: 24, 3: 14],
            activeSegments: [
                .init(mappedTMDBSeason: 1, episodeCount: 11),
                .init(mappedTMDBSeason: 1, episodeCount: 12),
                .init(mappedTMDBSeason: 2, episodeCount: 13),
                .init(mappedTMDBSeason: 2, episodeCount: 12)
            ],
            futureOnlyMappedTMDBSeasons: [3]
        ))
    }

    func testPreviewPrologueDriftDoesNotPublishGuessedTMDBCoordinates() {
        let tmdbSeasonEpisodeCounts = [1: 12, 2: 24]
        let providerSegments = [
            AnimeStructureCoverageSegment(mappedTMDBSeason: 1, episodeCount: 12),

            AnimeStructureCoverageSegment(mappedTMDBSeason: 2, episodeCount: 13),
            AnimeStructureCoverageSegment(mappedTMDBSeason: 2, episodeCount: 12)
        ]

        XCTAssertTrue(AnimeStructurePolicy.hasSafePreviewCoverage(
            lookupIsComplete: true,
            hasUnresolvedIdentity: false,
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
            activeSegments: providerSegments,
            futureOnlyMappedTMDBSeasons: []
        ))
        XCTAssertFalse(AnimeStructurePolicy.hasExactCoverage(
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
            segments: providerSegments
        ))
        XCTAssertFalse(AnimeStructurePolicy.allowsLinearTMDBCoordinates(
            hydrationPolicy: .initiallyVisible,
            hasExactCoverage: false
        ))
        XCTAssertTrue(AnimeStructurePolicy.allowsLinearTMDBCoordinates(
            hydrationPolicy: .complete,
            hasExactCoverage: false
        ))
    }

    func testPreviewCoverageRejectsMissingActiveSeason() {
        XCTAssertFalse(AnimeStructurePolicy.hasSafePreviewCoverage(
            lookupIsComplete: true,
            hasUnresolvedIdentity: false,
            tmdbSeasonEpisodeCounts: [1: 24, 2: 24],
            activeSegments: [
                .init(mappedTMDBSeason: 1, episodeCount: 24)
            ],
            futureOnlyMappedTMDBSeasons: []
        ))
    }

    func testPreviewCoverageRejectsLargeCatalogDrift() {
        XCTAssertFalse(AnimeStructurePolicy.hasSafePreviewCoverage(
            lookupIsComplete: true,
            hasUnresolvedIdentity: false,
            tmdbSeasonEpisodeCounts: [1: 24],
            activeSegments: [
                .init(mappedTMDBSeason: 1, episodeCount: 12)
            ],
            futureOnlyMappedTMDBSeasons: []
        ))
    }

    func testPreviewCoverageRequiresCompleteResolvedMapping() {
        let segments = [AnimeStructureCoverageSegment(
            mappedTMDBSeason: 1,
            episodeCount: 12
        )]
        XCTAssertFalse(AnimeStructurePolicy.hasSafePreviewCoverage(
            lookupIsComplete: false,
            hasUnresolvedIdentity: false,
            tmdbSeasonEpisodeCounts: [1: 12],
            activeSegments: segments,
            futureOnlyMappedTMDBSeasons: []
        ))
        XCTAssertFalse(AnimeStructurePolicy.hasSafePreviewCoverage(
            lookupIsComplete: true,
            hasUnresolvedIdentity: true,
            tmdbSeasonEpisodeCounts: [1: 12],
            activeSegments: segments,
            futureOnlyMappedTMDBSeasons: []
        ))
    }

    func testFlattenedCoursRejectMissingLeadingProviderRange() {
        XCTAssertFalse(AnimeStructurePolicy.hasCompatibleMappedOrder(
            [
                .init(mappedTMDBSeason: 1, mappedTVDBSeason: 1, tvdbEpisodeOffset: 12, episodeCount: 12),
                .init(mappedTMDBSeason: 1, mappedTVDBSeason: 1, tvdbEpisodeOffset: 24, episodeCount: 12)
            ],
            expectedTMDBSeasonCount: 1
        ))
    }

    func testHistoricalNegativeOneInitialOffsetRemainsValid() {
        XCTAssertTrue(AnimeStructurePolicy.hasCompatibleMappedOrder(
            [
                .init(mappedTMDBSeason: 1, mappedTVDBSeason: 1, tvdbEpisodeOffset: -1, episodeCount: 12),
                .init(mappedTMDBSeason: 1, mappedTVDBSeason: 1, tvdbEpisodeOffset: 11, episodeCount: 12)
            ],
            expectedTMDBSeasonCount: 1
        ))
    }

    func testOpenEndedExceptionIsNarrow() {
        XCTAssertTrue(AnimeStructurePolicy.allowsSingleOpenEndedSeries(
            status: "RELEASING",
            episodeCount: nil,
            mappedTMDBSeason: nil,
            tmdbSeasonEpisodeCounts: [1: 100]
        ))
        XCTAssertFalse(AnimeStructurePolicy.allowsSingleOpenEndedSeries(
            status: "FINISHED",
            episodeCount: nil,
            mappedTMDBSeason: nil,
            tmdbSeasonEpisodeCounts: [1: 100]
        ))
        XCTAssertFalse(AnimeStructurePolicy.allowsSingleOpenEndedSeries(
            status: "RELEASING",
            episodeCount: nil,
            mappedTMDBSeason: 1,
            tmdbSeasonEpisodeCounts: [1: 100]
        ))
    }

    func testLegacyOrderingDoesNotUseStartYearWhenSeasonYearIsMissing() {
        let knownSeasonYear = AnimeStructureOrderingCandidate(
            anilistId: 2,
            mappedTMDBSeason: nil,
            episodeOffset: nil,
            startYear: 2024,
            startMonth: 1,
            startDay: 1,
            seasonYear: 2024,
            seasonOrdinal: 0
        )
        let missingSeasonYear = AnimeStructureOrderingCandidate(
            anilistId: 1,
            mappedTMDBSeason: nil,
            episodeOffset: nil,
            startYear: 2000,
            startMonth: 1,
            startDay: 1,
            seasonYear: nil,
            seasonOrdinal: 0
        )

        XCTAssertEqual(
            AnimeStructurePolicy.orderedIDs([missingSeasonYear, knownSeasonYear]),
            [2, 1]
        )
    }

    func testWatchTogetherIdentitySurvivesSpecialToRegularRemap() {
        let old = animeDescriptor(
            season: 100_000 + 16498,
            episode: 2,
            anilistID: 16498,
            kitsuID: 7442,
            tmdbSeason: 4,
            tmdbEpisode: 30,
            isSpecial: true
        )
        let canonical = animeDescriptor(
            season: 4,
            episode: 2,
            anilistID: 16498,
            kitsuID: 7442,
            tmdbSeason: 4,
            tmdbEpisode: 30,
            isSpecial: false
        )

        XCTAssertTrue(old.isSameLogicalMedia(as: canonical))
        XCTAssertTrue(canonical.isSameLogicalMedia(as: old))
    }

    func testWatchTogetherKitsuOnlyIdentitySurvivesRoleRemap() {
        let old = animeDescriptor(
            season: 107_442,
            episode: 1,
            anilistID: nil,
            kitsuID: 7442,
            tmdbSeason: nil,
            tmdbEpisode: nil,
            isSpecial: true
        )
        let canonical = animeDescriptor(
            season: 2,
            episode: 1,
            anilistID: nil,
            kitsuID: 7442,
            tmdbSeason: nil,
            tmdbEpisode: nil,
            isSpecial: false
        )

        XCTAssertNil(old.animeContextFailureReason)
        XCTAssertTrue(old.isSameLogicalMedia(as: canonical))
    }

    func testWatchTogetherIdentityRejectsProviderConflict() {
        let lhs = animeDescriptor(
            season: 1,
            episode: 1,
            anilistID: 100,
            kitsuID: nil,
            tmdbSeason: 1,
            tmdbEpisode: 1,
            isSpecial: false
        )
        let rhs = animeDescriptor(
            season: 1,
            episode: 1,
            anilistID: 101,
            kitsuID: nil,
            tmdbSeason: 1,
            tmdbEpisode: 1,
            isSpecial: false
        )

        XCTAssertFalse(lhs.isSameLogicalMedia(as: rhs))
    }

    func testWatchTogetherIdentityRejectsExactTMDBConflict() {
        let lhs = animeDescriptor(
            season: 4,
            episode: 2,
            anilistID: 16498,
            kitsuID: nil,
            tmdbSeason: 4,
            tmdbEpisode: 29,
            isSpecial: false
        )
        let rhs = animeDescriptor(
            season: 100_000 + 16498,
            episode: 2,
            anilistID: 16498,
            kitsuID: nil,
            tmdbSeason: 4,
            tmdbEpisode: 30,
            isSpecial: true
        )

        XCTAssertFalse(lhs.isSameLogicalMedia(as: rhs))
    }

    func testSyntheticSeasonKeyPreservesLegacyAniListNamespace() throws {
        let providerID = 16498
        let seasonNumber = try XCTUnwrap(AnimeSyntheticSeasonKey.make(providerID: providerID))

        XCTAssertEqual(seasonNumber, 100_000 + providerID)
        XCTAssertEqual(AnimeSyntheticSeasonKey.providerID(from: seasonNumber), providerID)
        XCTAssertTrue(AnimeSyntheticSeasonKey.isSynthetic(seasonNumber))
    }

    func testSyntheticSeasonKeyKeepsExactMALNamespaceDisjoint() throws {
        let providerID = -5114
        let seasonNumber = try XCTUnwrap(AnimeSyntheticSeasonKey.make(providerID: providerID))

        XCTAssertLessThan(seasonNumber, -100_000)
        XCTAssertEqual(AnimeSyntheticSeasonKey.providerID(from: seasonNumber), providerID)
        XCTAssertTrue(AnimeSyntheticSeasonKey.isSynthetic(seasonNumber))
        XCTAssertNotEqual(
            seasonNumber,
            AnimeSyntheticSeasonKey.make(providerID: abs(providerID))
        )
        XCTAssertNotNil(PlaybackEpisodeCoordinate(seasonNumber: seasonNumber, episodeNumber: 2))
        XCTAssertNil(PlaybackEpisodeCoordinate(seasonNumber: -1, episodeNumber: 2))
    }

    func testSyntheticSeasonKeyRejectsOverflowingOrAmbiguousProviderIDs() {
        XCTAssertNil(AnimeSyntheticSeasonKey.make(providerID: 0))
        XCTAssertNil(AnimeSyntheticSeasonKey.make(providerID: Int.min))
        XCTAssertNil(AnimeSyntheticSeasonKey.make(providerID: Int.max))
        XCTAssertNil(
            AnimeSyntheticSeasonKey.make(
                providerID: ProgressPersistencePolicy.maximumIdentifier + 1
            )
        )
    }

    func testIdentityPolicyAcceptsLegacyAndEnrichedSameMALProvider() {
        let legacy = episodeContext(rawProviderID: -5114)
        let enriched = episodeContext(
            rawProviderID: -5114,
            canonicalAniListID: 21,
            malID: 5114
        )

        XCTAssertTrue(AnimeEpisodeIdentityPolicy.isSameEpisode(legacy, enriched))
        XCTAssertTrue(AnimeEpisodeIdentityPolicy.isSameEpisode(enriched, legacy))
    }

    func testIdentityPolicyBridgesOppositeNamespacesWithCanonicalIdentity() {
        let aniList = episodeContext(
            rawProviderID: 21,
            canonicalAniListID: 21,
            malID: 5114
        )
        let mal = episodeContext(
            rawProviderID: -5114,
            canonicalAniListID: 21,
            malID: 5114
        )

        XCTAssertTrue(AnimeEpisodeIdentityPolicy.isSameEpisode(aniList, mal))
    }

    func testIdentityPolicyRejectsCanonicalProviderMismatch() {
        let lhs = episodeContext(rawProviderID: -5114, canonicalAniListID: 21)
        let rhs = episodeContext(rawProviderID: 21, canonicalAniListID: 22)

        XCTAssertFalse(AnimeEpisodeIdentityPolicy.isSameEpisode(lhs, rhs))
    }

    func testIdentityPolicyRejectsSharedKitsuWithExactTMDBConflict() {
        let lhs = episodeContext(
            rawProviderID: 21,
            kitsuID: 9,
            tmdbSeason: 2,
            tmdbEpisode: 3
        )
        let rhs = episodeContext(
            rawProviderID: -5114,
            kitsuID: 9,
            tmdbSeason: 2,
            tmdbEpisode: 4
        )

        XCTAssertFalse(AnimeEpisodeIdentityPolicy.isSameEpisode(lhs, rhs))
    }

    func testMALFallbackGraphSatisfiesPositiveLaterCourSeed() {
        let graph = animeGraph(
            id: -1,
            rootMALID: 1,
            seasons: [animeSeason(rawID: -5114, canonicalID: 21, malID: 5114)]
        )

        XCTAssertTrue(graph.satisfiesAnimeSeed(21))
        XCTAssertTrue(graph.satisfiesAnimeSeed(-5114))
        XCTAssertTrue(graph.satisfiesMALSeed(5114))
    }

    func testPositiveGraphSatisfiesExactLaterCourMALSeed() {
        let graph = animeGraph(
            id: 1,
            rootMALID: 1,
            seasons: [animeSeason(rawID: 21, canonicalID: 21, malID: 5114)]
        )

        XCTAssertTrue(graph.satisfiesMALSeed(5114))
    }

    func testContinueWatchingFastModePreservesExactSplitCourContext() {
        let proven = EpisodePlaybackContext(
            localSeasonNumber: 2,
            localEpisodeNumber: 1,
            anilistMediaId: 200,
            canonicalAniListMediaId: 200,
            malMediaId: 300,
            kitsuMediaId: 400,
            tmdbSeasonNumber: 1,
            tmdbEpisodeNumber: 12,
            tmdbEpisodeOffset: 11,
            animeAbsoluteEpisodeNumber: 12,
            animeSeasonEpisodeCount: 12,
            isSpecial: false,
            titleOnlySearch: false
        )

        let resolved = ContinueWatchingAnimePlaybackContextPolicy.resolve(
            existingContext: proven,
            localSeasonNumber: 2,
            localEpisodeNumber: 1,
            localCoordinatesAreKnownTMDB: true
        )

        XCTAssertEqual(resolved, proven)
        XCTAssertEqual(resolved?.resolvedTMDBSeasonNumber, 1)
        XCTAssertEqual(resolved?.resolvedTMDBEpisodeNumber, 12)
        XCTAssertEqual(resolved?.canonicalAniListMediaId, 200)
    }

    func testContinueWatchingFastModeProjectsOnlyDerivableSameCourEpisode() {
        let seed = EpisodePlaybackContext(
            localSeasonNumber: 2,
            localEpisodeNumber: 1,
            anilistMediaId: 200,
            canonicalAniListMediaId: 200,
            malMediaId: nil,
            kitsuMediaId: nil,
            tmdbSeasonNumber: 1,
            tmdbEpisodeNumber: 12,
            tmdbEpisodeOffset: 11,
            animeAbsoluteEpisodeNumber: 12,
            animeSeasonEpisodeCount: 12,
            isSpecial: false,
            titleOnlySearch: false
        )

        let resolved = ContinueWatchingAnimePlaybackContextPolicy.resolve(
            existingContext: seed,
            localSeasonNumber: 2,
            localEpisodeNumber: 2,
            localCoordinatesAreKnownTMDB: false
        )

        XCTAssertEqual(resolved?.localEpisodeNumber, 2)
        XCTAssertEqual(resolved?.resolvedTMDBSeasonNumber, 1)
        XCTAssertEqual(resolved?.resolvedTMDBEpisodeNumber, 13)
        XCTAssertEqual(resolved?.animeAbsoluteEpisodeNumber, 13)
    }

    func testContinueWatchingFastModeNeverOverwritesIncompleteAnimeContext() {
        let incomplete = EpisodePlaybackContext(
            localSeasonNumber: 2,
            localEpisodeNumber: 1,
            anilistMediaId: 200,
            canonicalAniListMediaId: 200,
            malMediaId: nil,
            kitsuMediaId: nil,
            tmdbSeasonNumber: nil,
            tmdbEpisodeNumber: nil,
            tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: 12,
            animeSeasonEpisodeCount: 12,
            isSpecial: false,
            titleOnlySearch: false
        )

        XCTAssertNil(ContinueWatchingAnimePlaybackContextPolicy.resolve(
            existingContext: incomplete,
            localSeasonNumber: 2,
            localEpisodeNumber: 1,
            localCoordinatesAreKnownTMDB: true
        ))
    }

    func testContinueWatchingFastModeSynthesizesOnlyProvenTMDBCoordinates() {
        XCTAssertNil(ContinueWatchingAnimePlaybackContextPolicy.resolve(
            existingContext: nil,
            localSeasonNumber: 2,
            localEpisodeNumber: 1,
            localCoordinatesAreKnownTMDB: false
        ))

        let resolved = ContinueWatchingAnimePlaybackContextPolicy.resolve(
            existingContext: nil,
            localSeasonNumber: 2,
            localEpisodeNumber: 1,
            localCoordinatesAreKnownTMDB: true
        )
        XCTAssertEqual(resolved?.localSeasonNumber, 2)
        XCTAssertEqual(resolved?.localEpisodeNumber, 1)
        XCTAssertEqual(resolved?.resolvedTMDBSeasonNumber, 2)
        XCTAssertEqual(resolved?.resolvedTMDBEpisodeNumber, 1)
        XCTAssertFalse(resolved?.hasAnimeMediaId ?? true)
    }

    func testEpisodeGraphCachePolicyEvictsOldestUntilEpisodeBudgetFits() {
        let candidates = [
            AnimeEpisodeGraphCacheCandidate(key: "newest", storedAt: 30, episodeCost: 1_800),
            AnimeEpisodeGraphCacheCandidate(key: "middle", storedAt: 20, episodeCost: 1_600),
            AnimeEpisodeGraphCacheCandidate(key: "oldest", storedAt: 10, episodeCost: 1_000)
        ]

        XCTAssertEqual(
            AnimeEpisodeGraphCachePolicy.retainedKeys(
                candidates: candidates,
                maximumEntryCount: 10,
                maximumEpisodeCost: 3_500
            ),
            Set(["newest", "middle"])
        )
    }

    func testEpisodeGraphCachePolicyAppliesCountLimitToShortGraphs() {
        let candidates = [
            AnimeEpisodeGraphCacheCandidate(key: "newest", storedAt: 30, episodeCost: 12),
            AnimeEpisodeGraphCacheCandidate(key: "middle", storedAt: 20, episodeCost: 12),
            AnimeEpisodeGraphCacheCandidate(key: "oldest", storedAt: 10, episodeCost: 12)
        ]

        XCTAssertEqual(
            AnimeEpisodeGraphCachePolicy.retainedKeys(
                candidates: candidates,
                maximumEntryCount: 2,
                maximumEpisodeCost: 10_000
            ),
            Set(["newest", "middle"])
        )
    }

    func testEpisodeGraphCachePolicyRetainsOneOversizedNewestGraph() {
        let candidates = [
            AnimeEpisodeGraphCacheCandidate(key: "newest", storedAt: 20, episodeCost: 5_000),
            AnimeEpisodeGraphCacheCandidate(key: "oldest", storedAt: 10, episodeCost: 100)
        ]

        XCTAssertEqual(
            AnimeEpisodeGraphCachePolicy.retainedKeys(
                candidates: candidates,
                maximumEntryCount: 12,
                maximumEpisodeCost: 4_000
            ),
            Set(["newest"])
        )
    }

    func testRemoteNumericBoundaryRejectsHostileMagnitudesAndKeepsStableSyntheticIDs() {
        XCTAssertNil(RemoteMediaNumericBoundary.positiveMagnitude(Int.min))
        XCTAssertNil(RemoteMediaNumericBoundary.positiveMagnitude(Int.max))
        XCTAssertEqual(
            RemoteMediaNumericBoundary.positiveMagnitude(
                -RemoteMediaNumericBoundary.maximumIdentifier
            ),
            RemoteMediaNumericBoundary.maximumIdentifier
        )

        XCTAssertEqual(
            RemoteMediaNumericBoundary.syntheticIdentifier([(2, 1_000), (3, 1)]),
            2_003
        )
        let hostile = [(Int.max, Int.max), (Int.min, -1)]
        let first = RemoteMediaNumericBoundary.syntheticIdentifier(hostile)
        XCTAssertGreaterThan(first, 0)
        XCTAssertEqual(first, RemoteMediaNumericBoundary.syntheticIdentifier(hostile))
    }

    func testRemoteSeasonCountsRejectDuplicatesAndTotalsAboveCap() {
        XCTAssertEqual(
            RemoteMediaNumericBoundary.seasonEpisodeCounts([
                (season: 1, count: RemoteMediaNumericBoundary.maximumEpisodeCount),
                (season: 2, count: RemoteMediaNumericBoundary.maximumEpisodeCount)
            ]),
            [
                1: RemoteMediaNumericBoundary.maximumEpisodeCount,
                2: RemoteMediaNumericBoundary.maximumEpisodeCount
            ]
        )
        XCTAssertNil(RemoteMediaNumericBoundary.seasonEpisodeCounts([
            (season: 1, count: 12),
            (season: 1, count: 13)
        ]))
        XCTAssertNil(RemoteMediaNumericBoundary.seasonEpisodeCounts([
            (season: 1, count: RemoteMediaNumericBoundary.maximumEpisodeCount),
            (season: 2, count: RemoteMediaNumericBoundary.maximumEpisodeCount),
            (season: 3, count: 1)
        ]))
    }

    func testEpisodeCacheCostsSaturateInsteadOfOverflowing() {
        XCTAssertEqual(
            RemoteMediaNumericBoundary.saturatingNonnegativeSum([Int.max, 1]),
            Int.max
        )
        XCTAssertEqual(
            RemoteMediaNumericBoundary.saturatingNonnegativeProduct(Int.max, 4),
            Int.max
        )

        let hostileGraph = AniListAnimeWithSeasons(
            id: 1,
            malId: nil,
            title: "Hostile cache fixture",
            genres: nil,
            seasons: [],
            totalEpisodes: Int.max,
            status: "FINISHED",
            rating: nil
        )
        XCTAssertEqual(AnimeEpisodeGraphCachePolicy.episodeCost(of: hostileGraph), Int.max)
        XCTAssertEqual(
            AnimeEpisodeGraphCachePolicy.retainedKeys(
                candidates: [
                    .init(key: "newest", storedAt: 2, episodeCost: Int.max),
                    .init(key: "oldest", storedAt: 1, episodeCost: Int.max)
                ],
                maximumEntryCount: 2,
                maximumEpisodeCost: Int.max
            ),
            Set(["newest", "oldest"])
        )
    }

    func testAnimeStructurePolicyRejectsExtremeRemoteCoordinatesWithoutArithmetic() {
        XCTAssertFalse(AnimeStructurePolicy.hasExactCoverage(
            tmdbSeasonEpisodeCounts: [1: Int.max],
            segments: [.init(mappedTMDBSeason: 1, episodeCount: Int.max)]
        ))
        XCTAssertFalse(AnimeStructurePolicy.hasMatchingEpisodeTotals(
            tmdbSeasonEpisodeCounts: [1: 12, Int.max: 12],
            segments: [.init(mappedTMDBSeason: 1, episodeCount: 12)]
        ))
        XCTAssertFalse(AnimeStructurePolicy.hasCompatibleMappedOrder(
            [
                .init(
                    mappedTMDBSeason: 1,
                    mappedTVDBSeason: 1,
                    tvdbEpisodeOffset: Int.min,
                    episodeCount: 12
                ),
                .init(
                    mappedTMDBSeason: 1,
                    mappedTVDBSeason: 1,
                    tvdbEpisodeOffset: Int.max,
                    episodeCount: 12
                )
            ],
            expectedTMDBSeasonCount: 1
        ))
    }

    func testAniListDecoderRejectsExtremeIDsCountsOffsetsAndYears() throws {
        let decoder = JSONDecoder()
        let hostilePayloads = [
            "{\"id\":\(Int.max),\"title\":{}}",
            "{\"id\":1,\"title\":{},\"episodes\":\(Int.max)}",
            "{\"id\":1,\"title\":{},\"seasonYear\":\(Int.min)}",
            "{\"id\":1,\"title\":{},\"externalLinks\":[{\"site\":\"Kitsu\",\"siteId\":\(Int.max)}]}"
        ]
        for payload in hostilePayloads {
            XCTAssertThrowsError(
                try decoder.decode(AniListAnime.self, from: Data(payload.utf8)),
                "Expected hostile AniList fixture to be rejected: \(payload)"
            )
        }

        let boundaryPayload = """
        {
          "id": \(RemoteMediaNumericBoundary.maximumIdentifier),
          "idMal": \(RemoteMediaNumericBoundary.maximumIdentifier),
          "title": {},
          "episodes": \(RemoteMediaNumericBoundary.maximumEpisodeCount),
          "seasonYear": \(RemoteMediaNumericBoundary.maximumYear),
          "externalLinks": [{
            "site": "Kitsu",
            "siteId": \(RemoteMediaNumericBoundary.maximumIdentifier)
          }]
        }
        """
        let decoded = try decoder.decode(AniListAnime.self, from: Data(boundaryPayload.utf8))
        XCTAssertEqual(decoded.id, RemoteMediaNumericBoundary.maximumIdentifier)
        XCTAssertEqual(decoded.episodes, RemoteMediaNumericBoundary.maximumEpisodeCount)
        XCTAssertEqual(decoded.kitsuId, RemoteMediaNumericBoundary.maximumIdentifier)
    }

    func testAniListMangaDecoderRejectsHostileNumericFieldsAtIngress() throws {
        let decoder = JSONDecoder()
        let hostilePayloads = [
            "{\"id\":\(Int.max),\"title\":{}}",
            "{\"id\":1,\"title\":{},\"chapters\":\(Int.max)}",
            "{\"id\":1,\"title\":{},\"volumes\":\(Int.min)}",
            "{\"id\":1,\"title\":{},\"averageScore\":101}",
            "{\"id\":1,\"title\":{},\"startDate\":{\"year\":\(Int.max)}}"
        ]
        for payload in hostilePayloads {
            XCTAssertThrowsError(
                try decoder.decode(AniListManga.self, from: Data(payload.utf8)),
                "Expected hostile AniList manga fixture to be rejected: \(payload)"
            )
        }

        let boundaryPayload = """
        {
          "id": \(RemoteMediaNumericBoundary.maximumIdentifier),
          "title": {},
          "chapters": \(RemoteMediaNumericBoundary.maximumEpisodeCount),
          "volumes": \(RemoteMediaNumericBoundary.maximumEpisodeCount),
          "averageScore": 100,
          "startDate": {"year": \(RemoteMediaNumericBoundary.maximumYear)}
        }
        """
        let boundary = try decoder.decode(
            AniListManga.self,
            from: Data(boundaryPayload.utf8)
        )
        XCTAssertEqual(boundary.id, RemoteMediaNumericBoundary.maximumIdentifier)
        XCTAssertEqual(boundary.chapters, RemoteMediaNumericBoundary.maximumEpisodeCount)
        XCTAssertEqual(boundary.volumes, RemoteMediaNumericBoundary.maximumEpisodeCount)
        XCTAssertEqual(boundary.averageScore, 100)
        XCTAssertEqual(boundary.startYear, RemoteMediaNumericBoundary.maximumYear)

        let unknownCounts = try decoder.decode(
            AniListManga.self,
            from: Data("{\"id\":1,\"title\":{},\"chapters\":0,\"volumes\":0,\"startDate\":{\"year\":0}}".utf8)
        )
        XCTAssertNil(unknownCounts.chapters)
        XCTAssertNil(unknownCounts.volumes)
        XCTAssertNil(unknownCounts.startYear)
    }

    func testTMDBTVAndSeasonPayloadValidationRejectsDuplicatesAndExtremeCounts() throws {
        let duplicateSeasons = """
        {
          "id": 1,
          "name": "Show",
          "vote_average": 8,
          "popularity": 1,
          "genres": [],
          "adult": false,
          "vote_count": 1,
          "number_of_episodes": \(Int.max),
          "seasons": [
            {"id": 10, "name": "One", "season_number": 1, "episode_count": 12},
            {"id": 11, "name": "Duplicate", "season_number": 1, "episode_count": 12}
          ]
        }
        """
        let show = try JSONDecoder().decode(
            TMDBTVShowWithSeasons.self,
            from: Data(duplicateSeasons.utf8)
        )
        XCTAssertFalse(show.isValidRemotePayload)

        let duplicateEpisodes = """
        {
          "id": 20,
          "name": "Season One",
          "season_number": 1,
          "episodes": [
            {"id": 101, "name": "One", "episode_number": 1, "season_number": 1, "vote_average": 0, "vote_count": 0},
            {"id": 102, "name": "Duplicate", "episode_number": 1, "season_number": 1, "vote_average": 0, "vote_count": 0}
          ]
        }
        """
        let season = try JSONDecoder().decode(
            TMDBSeasonDetail.self,
            from: Data(duplicateEpisodes.utf8)
        )
        XCTAssertFalse(season.isValidRemotePayload)
    }

    func testTMDBSearchDecoderLossilyDropsHostileNumericResults() throws {
        let payload = """
        {
          "page": 1,
          "total_pages": 1,
          "total_results": 2,
          "results": [
            {"id": \(Int.max), "media_type": "tv"},
            {"id": 42, "media_type": "tv", "popularity": 1, "vote_average": 8}
          ]
        }
        """
        let response = try JSONDecoder().decode(
            TMDBSearchResponse.self,
            from: Data(payload.utf8)
        )
        XCTAssertEqual(response.results.map(\.id), [42])
        XCTAssertEqual(response.skippedResultCount, 1)
    }

    func testProgressBulkMutationBoundaryRejectsCapPlusOneBeforeDispatch() {
        let cap = ProgressPersistencePolicy.maximumBulkEpisodeMutationCount
        XCTAssertTrue(ProgressPersistencePolicy.bulkEpisodeMutationIsSafe(
            showID: 1,
            seasonNumber: 0,
            throughEpisode: cap
        ))
        XCTAssertFalse(ProgressPersistencePolicy.bulkEpisodeMutationIsSafe(
            showID: 1,
            seasonNumber: 0,
            throughEpisode: cap + 1
        ))
        XCTAssertFalse(ProgressPersistencePolicy.bulkEpisodeMutationIsSafe(
            showID: Int.max,
            seasonNumber: 0,
            throughEpisode: 1
        ))
        XCTAssertNil(ProgressPersistencePolicy.exactEpisodeMutationNumbers(
            showID: 1,
            seasonNumber: 1,
            episodeNumbers: Array(repeating: 1, count: cap + 1)
        ))
        XCTAssertFalse(ProgressPersistencePolicy.previousEpisodeMutationIsSafe(
            showID: 1,
            seasonNumber: 1,
            episodeNumber: cap + 2
        ))
        XCTAssertFalse(ProgressPersistencePolicy.previousEpisodeMutationIsSafe(
            showID: Int.min,
            seasonNumber: Int.max,
            episodeNumber: Int.max
        ))
    }

    func testTrackerProgressBoundaryRejectsExtremeProgressAndPaging() throws {
        let cap = ProgressPersistencePolicy.maximumBulkEpisodeMutationCount
        XCTAssertEqual(
            TrackerRemoteProgressBoundary.watchedEpisodeCount(
                progress: cap,
                totalEpisodes: cap,
                status: "completed"
            ),
            cap
        )
        XCTAssertNil(TrackerRemoteProgressBoundary.watchedEpisodeCount(
            progress: cap + 1,
            totalEpisodes: nil,
            status: "watching"
        ))
        XCTAssertNil(TrackerRemoteProgressBoundary.watchedEpisodeCount(
            progress: Int.min,
            totalEpisodes: Int.max,
            status: "completed"
        ))
        XCTAssertNil(TrackerRemoteProgressBoundary.pageCallCount(
            itemCount: Int.max,
            pageSize: 100
        ))
        XCTAssertTrue(TrackerRemoteProgressBoundary.isAllowedMALPageURL(
            try XCTUnwrap(URL(string: "https://api.myanimelist.net/v2/users/@me/animelist?offset=100"))
        ))
        XCTAssertFalse(TrackerRemoteProgressBoundary.isAllowedMALPageURL(
            try XCTUnwrap(URL(string: "https://example.test/v2/users/@me/animelist"))
        ))
    }

    func testFillerClassificationSkipsOnlyExplicitFiller() {
        let classifications = AnimeEpisodeClassifications([
            1: .filler,
            2: .mixed,
            3: .animeCanon,
            4: .mangaCanon,
            5: .unknown
        ])

        XCTAssertTrue(classifications.shouldSkip(episodeNumber: 1))
        for episodeNumber in 2...6 {
            XCTAssertFalse(classifications.shouldSkip(episodeNumber: episodeNumber))
        }
        XCTAssertEqual(classifications.classification(for: 2), .mixed)
        XCTAssertEqual(classifications.classification(for: 5), .unknown)
        XCTAssertEqual(classifications.classification(for: 6), .unknown)
        XCTAssertEqual(classifications.explicitFillerCount, 1)
    }

    func testFillerRequestPolicyRetriesOnlyTransientFailures() {
        for statusCode in [408, 425, 429, 500, 503, 599] {
            XCTAssertTrue(AnimeFillerRequestPolicy.shouldRetry(statusCode: statusCode))
        }
        for statusCode in [200, 400, 401, 403, 404, 422] {
            XCTAssertFalse(AnimeFillerRequestPolicy.shouldRetry(statusCode: statusCode))
        }
        XCTAssertTrue(AnimeFillerRequestPolicy.shouldRetry(error: URLError(.timedOut)))
        XCTAssertFalse(AnimeFillerRequestPolicy.shouldRetry(error: URLError(.cancelled)))
        XCTAssertEqual(
            AnimeFillerRequestPolicy.retryDelay(
                retryAfterValue: "90",
                attempt: 0
            ),
            AnimeFillerRequestPolicy.maximumRetryDelay
        )
        XCTAssertEqual(
            AnimeFillerRequestPolicy.retryDelay(
                retryAfterValue: "nan",
                attempt: 0
            ),
            0.6
        )
    }

    func testFillerCacheExpiresInsteadOfBecomingPermanentSkipAuthority() {
        let now = Date().timeIntervalSince1970
        XCTAssertEqual(
            AnimeFillerCachePolicy.freshness(
                storedAt: now - AnimeFillerCachePolicy.freshMaxAge,
                now: now
            ),
            .fresh
        )
        XCTAssertEqual(
            AnimeFillerCachePolicy.freshness(
                storedAt: now - AnimeFillerCachePolicy.freshMaxAge - 1,
                now: now
            ),
            .stale
        )
        XCTAssertEqual(
            AnimeFillerCachePolicy.freshness(
                storedAt: now - AnimeFillerCachePolicy.staleMaxAge - 1,
                now: now
            ),
            .expired
        )
        XCTAssertEqual(
            AnimeFillerCachePolicy.freshness(
                storedAt: now + AnimeFillerCachePolicy.maximumFutureClockSkew + 1,
                now: now
            ),
            .expired
        )
    }

    func testFillerServicePersistsFreshCacheWithoutMaintainingOverrides() async throws {
        let payload = """
        {
          "pagination": {"has_next_page": false},
          "data": [
            {"mal_id": 3, "filler": true},
            {"mal_id": 4, "filler": false}
          ]
        }
        """
        AnimeFillerURLProtocol.configure(stubs: [
            AnimeFillerHTTPStub(statusCode: 200, json: payload)
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnimeFillerURLProtocol.self]
        let firstSession = URLSession(configuration: configuration)
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anime-filler-cache-\(UUID().uuidString).json")
        defer {
            firstSession.invalidateAndCancel()
            try? FileManager.default.removeItem(at: cacheURL)
        }

        let firstService = AnimeFillerService(
            session: firstSession,
            cacheFileURL: cacheURL
        )
        let fetched = try await firstService.episodeClassifications(malId: 21)
        XCTAssertTrue(fetched.shouldSkip(episodeNumber: 3))
        XCTAssertFalse(fetched.shouldSkip(episodeNumber: 4))
        XCTAssertEqual(AnimeFillerURLProtocol.requestedURLs().count, 1)

        AnimeFillerURLProtocol.configure(stubs: [])
        let secondSession = URLSession(configuration: configuration)
        defer { secondSession.invalidateAndCancel() }
        let secondService = AnimeFillerService(
            session: secondSession,
            cacheFileURL: cacheURL
        )
        let cached = try await secondService.episodeClassifications(malId: 21)
        XCTAssertTrue(cached.shouldSkip(episodeNumber: 3))
        XCTAssertFalse(cached.shouldSkip(episodeNumber: 4))
        XCTAssertTrue(AnimeFillerURLProtocol.requestedURLs().isEmpty)
    }

    func testFillerServiceFallsBackFromJikanToTenrai() async throws {
        let payload = """
        {
          "pagination": {"has_next_page": false},
          "data": [{"mal_id": 8, "filler": true}]
        }
        """
        AnimeFillerURLProtocol.configure(stubs: [
            AnimeFillerHTTPStub(statusCode: 404, json: "{}"),
            AnimeFillerHTTPStub(statusCode: 200, json: payload)
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnimeFillerURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anime-filler-fallback-\(UUID().uuidString).json")
        defer {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: cacheURL)
        }

        let service = AnimeFillerService(session: session, cacheFileURL: cacheURL)
        let classifications = try await service.episodeClassifications(malId: 21)
        XCTAssertTrue(classifications.shouldSkip(episodeNumber: 8))
        XCTAssertEqual(
            AnimeFillerURLProtocol.requestedURLs().compactMap(\.host),
            ["api.jikan.moe", "api.tenrai.org"]
        )
    }

    private func specialSeasonDetail(episodes: [TMDBEpisode]) -> TMDBSeasonDetail {
        TMDBSeasonDetail(
            id: 100,
            name: "Specials",
            overview: "",
            posterPath: nil,
            seasonNumber: 0,
            airDate: nil,
            episodes: episodes
        )
    }

    private func tmdbSpecialEpisode(
        number: Int,
        name: String,
        airDate: String?
    ) -> TMDBEpisode {
        TMDBEpisode(
            id: 1_000 + number,
            name: name,
            overview: "Overview \(number)",
            stillPath: "/still-\(number).jpg",
            episodeNumber: number,
            seasonNumber: 0,
            airDate: airDate,
            runtime: 24,
            voteAverage: 8,
            voteCount: 10
        )
    }

    private func episodeContext(
        rawProviderID: Int,
        canonicalAniListID: Int? = nil,
        malID: Int? = nil,
        kitsuID: Int? = nil,
        tmdbSeason: Int? = nil,
        tmdbEpisode: Int? = nil
    ) -> EpisodePlaybackContext {
        EpisodePlaybackContext(
            localSeasonNumber: 2,
            localEpisodeNumber: 3,
            anilistMediaId: rawProviderID,
            canonicalAniListMediaId: canonicalAniListID,
            malMediaId: malID,
            kitsuMediaId: kitsuID,
            tmdbSeasonNumber: tmdbSeason,
            tmdbEpisodeNumber: tmdbEpisode,
            tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: nil,
            animeSeasonEpisodeCount: 12,
            isSpecial: false,
            titleOnlySearch: false
        )
    }

    private func animeSeason(
        rawID: Int,
        canonicalID: Int?,
        malID: Int?
    ) -> AniListSeasonWithPoster {
        AniListSeasonWithPoster(
            seasonNumber: 2,
            anilistId: rawID,
            canonicalAniListId: canonicalID,
            malId: malID,
            kitsuId: nil,
            title: "Cour 2",
            englishTitle: nil,
            romajiTitle: nil,
            nativeTitle: nil,
            episodes: [],
            posterUrl: nil
        )
    }

    private func animeGraph(
        id: Int,
        rootMALID: Int?,
        seasons: [AniListSeasonWithPoster]
    ) -> AniListAnimeWithSeasons {
        AniListAnimeWithSeasons(
            id: id,
            malId: rootMALID,
            title: "Anime",
            genres: nil,
            seasons: seasons,
            totalEpisodes: seasons.reduce(0) { $0 + $1.episodes.count },
            status: "FINISHED",
            rating: nil
        )
    }

    private func animeDescriptor(
        season: Int,
        episode: Int,
        anilistID: Int?,
        kitsuID: Int?,
        tmdbSeason: Int?,
        tmdbEpisode: Int?,
        isSpecial: Bool
    ) -> WatchTogetherMediaDescriptor {
        WatchTogetherMediaDescriptor(
            tmdbID: 1429,
            mediaType: "tv",
            seasonNumber: tmdbSeason,
            episodeNumber: tmdbEpisode,
            playbackContext: EpisodePlaybackContext(
                localSeasonNumber: season,
                localEpisodeNumber: episode,
                anilistMediaId: anilistID,
                kitsuMediaId: kitsuID,
                tmdbSeasonNumber: tmdbSeason,
                tmdbEpisodeNumber: tmdbEpisode,
                tmdbEpisodeOffset: nil,
                animeAbsoluteEpisodeNumber: nil,
                animeSeasonEpisodeCount: 2,
                isSpecial: isSpecial,
                titleOnlySearch: isSpecial
            ),
            isAnime: true,
            title: "Anime"
        )
    }
}
#endif
