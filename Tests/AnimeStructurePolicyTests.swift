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

    func testAniListOutageAdmissionBlocksThenRequestsRecoveryProbe() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(
            AnimeProviderOutagePolicy.readAdmission(unavailableUntil: nil, now: now),
            .allowed
        )
        XCTAssertEqual(
            AnimeProviderOutagePolicy.readAdmission(
                unavailableUntil: now.addingTimeInterval(1),
                now: now
            ),
            .blocked
        )
        XCTAssertEqual(
            AnimeProviderOutagePolicy.readAdmission(
                unavailableUntil: now.addingTimeInterval(-1),
                now: now
            ),
            .recoveryProbe
        )
    }

    func testAniListReadGatePreservesMutationsAndFallbackClassification() throws {
        XCTAssertTrue(AniListGraphQLDocumentPolicy.isReadOnly("query { Viewer { id } }"))
        XCTAssertTrue(AniListGraphQLDocumentPolicy.isReadOnly("{ Viewer { id } }"))
        XCTAssertFalse(AniListGraphQLDocumentPolicy.isReadOnly("  mutation { SaveMediaListEntry { id } }"))

        let endpoint = try XCTUnwrap(URL(string: "https://graphql.anilist.co"))
        var readRequest = URLRequest(url: endpoint)
        readRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": "query { Viewer { id } }"
        ])
        var mutationRequest = URLRequest(url: endpoint)
        mutationRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": "mutation { SaveMediaListEntry { id } }"
        ])
        XCTAssertTrue(AniListGraphQLDocumentPolicy.isReadOnly(readRequest))
        XCTAssertFalse(AniListGraphQLDocumentPolicy.isReadOnly(mutationRequest))

        let reason = AnimeProviderHealthCenter.shared.classifyAniListFailure(
            AniListReadGateError.cooldown
        )
        XCTAssertEqual(reason, .anilistUnavailable)
        XCTAssertTrue(AnimeProviderHealthCenter.shared.shouldUseMALFallback(for: reason))
    }

    func testAniListDetailSearchRetainsProviderSignificantTitleVariants() {
        let localized = "The Forsaken Saintess and Her Foodie Road Trip in Another World"
        let original = "捨てられ聖女の異世界ごはん旅 隠れスキルでキャンピングカーを召喚しました"
        let providerEnglish = "The Forsaken Saintess and Her Foodie Roadtrip in Another World"

        XCTAssertEqual(
            AniListTitlePicker.detailSearchCandidates(
                primaryTitle: localized,
                localizedTitle: "  \(localized)  ",
                originalTitle: original,
                preferredLocaleIdentifier: "en-US",
                alternativeTitles: [
                    .init(iso31661: "JP", title: providerEnglish, type: ""),
                    .init(
                        iso31661: "JP",
                        title: "Suterare Seijo no Isekai Gohantabi",
                        type: "Romanized"
                    )
                ]
            ),
            [localized, original, "Suterare Seijo no Isekai Gohantabi", providerEnglish]
        )
    }

    func testAniListDetailSearchCandidatesAreBoundedAndRejectInvalidTitles() {
        let candidates = AniListTitlePicker.detailSearchCandidates(
            primaryTitle: "Primary",
            localizedTitle: "primary",
            originalTitle: "Bad\nTitle",
            alternativeTitles: ["One", "Two", "Three", "Four", "Five", "Six", "Seven"].map {
                TMDBTVAlternativeTitle(iso31661: "FR", title: $0, type: nil)
            }
        )

        XCTAssertEqual(candidates, ["Primary", "One", "Two", "Three", "Four", "Five"])
    }

    func testAniListDetailSearchSkipsEarlyFuzzyResponseForLaterExactAlias() {
        let localized = "The Forsaken Saintess and Her Foodie Road Trip in Another World"
        let original = "捨てられ聖女の異世界ごはん旅 隠れスキルでキャンピングカーを召喚しました"
        let providerEnglish = "The Forsaken Saintess and Her Foodie Roadtrip in Another World"
        let responses = [
            [["The Forsaken Princess and Her Secret Journey"]],
            [[providerEnglish, "Suterare Seijo no Isekai Gohantabi"]]
        ]

        XCTAssertEqual(
            AniListTitlePicker.detailSearchSelection(
                responseCandidateTitles: responses,
                searchedTitles: [localized, original],
                authoritativeTitles: [localized, original]
            ),
            AniListDetailSearchSelection(
                responseIndex: 1,
                candidateIndexes: [0],
                isExact: true
            )
        )
        XCTAssertEqual(
            AniListTitlePicker.detailSearchSelection(
                responseCandidateTitles: [responses[0], []],
                searchedTitles: [localized, original],
                authoritativeTitles: [localized, original]
            ),
            AniListDetailSearchSelection(
                responseIndex: 0,
                candidateIndexes: [0],
                isExact: false
            )
        )
    }

    func testAniListDetailSearchPrioritizesUsefulLateAlternativeMetadata() {
        let alternatives = [
            TMDBTVAlternativeTitle(iso31661: "FR", title: "French Raw First", type: nil),
            TMDBTVAlternativeTitle(iso31661: "DE", title: "German Raw Second", type: nil),
            TMDBTVAlternativeTitle(iso31661: "IT", title: "Italian Raw Third", type: nil),
            TMDBTVAlternativeTitle(iso31661: "RU", title: "Russian Raw Fourth", type: nil),
            TMDBTVAlternativeTitle(iso31661: "ES", title: "Spanish Raw Fifth", type: nil),
            TMDBTVAlternativeTitle(
                iso31661: "US",
                title: "The Forsaken Saintess and Her Foodie Roadtrip in Another World",
                type: "English"
            ),
            TMDBTVAlternativeTitle(
                iso31661: "JP",
                title: "Suterare Seijo no Isekai Gohantabi",
                type: "Romanized"
            )
        ]

        XCTAssertEqual(
            AniListTitlePicker.detailSearchCandidates(
                primaryTitle: "Localized",
                localizedTitle: "Localized",
                originalTitle: "Original",
                preferredLocaleIdentifier: "en-US",
                alternativeTitles: alternatives
            ),
            [
                "Localized",
                "Original",
                "Suterare Seijo no Isekai Gohantabi",
                "The Forsaken Saintess and Her Foodie Roadtrip in Another World",
                "French Raw First",
                "German Raw Second"
            ]
        )
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

    func testJoJoCurrentPartUsesTheUniqueMappedTMDBSeasonRemainder() {
        let tmdbSeasons = [1: 26, 2: 48, 3: 39, 4: 39, 5: 38, 6: 12]
        let segments: [AnimeStructureCoverageSegment] = [
            .init(mappedTMDBSeason: 1, episodeCount: 26),
            .init(mappedTMDBSeason: 2, episodeCount: 24),
            .init(mappedTMDBSeason: 2, episodeCount: 24),
            .init(mappedTMDBSeason: 3, episodeCount: 39),
            .init(mappedTMDBSeason: 4, episodeCount: 39),
            .init(mappedTMDBSeason: 5, episodeCount: 12),
            .init(mappedTMDBSeason: 5, episodeCount: 12),
            .init(mappedTMDBSeason: 5, episodeCount: 14),
            .init(mappedTMDBSeason: 6, episodeCount: nil)
        ]

        let resolved = AnimeStructurePolicy.resolvingSingleUnknownMappedSeasonCounts(
            tmdbSeasonEpisodeCounts: tmdbSeasons,
            segments: segments
        )

        XCTAssertEqual(resolved.last?.episodeCount, 12)
        XCTAssertTrue(AnimeStructurePolicy.hasExactCoverage(
            tmdbSeasonEpisodeCounts: tmdbSeasons,
            segments: resolved
        ))
        XCTAssertTrue(AnimeStructurePolicy.allowsLinearTMDBCoordinates(
            hydrationPolicy: .initiallyVisible,
            hasExactCoverage: true
        ))
    }

    func testLinkClickReleasingTailUsesTheRemainingTMDBSeason() {
        let tmdbSeasons = [1: 11, 2: 12, 3: 6, 4: 12]
        let segments: [AnimeStructureCoverageSegment] = [
            .init(mappedTMDBSeason: 1, episodeCount: 11),
            .init(mappedTMDBSeason: 2, episodeCount: 12),
            .init(mappedTMDBSeason: 3, episodeCount: 6),
            .init(mappedTMDBSeason: nil, episodeCount: 24)
        ]

        let reconciled = AnimeStructurePolicy.reconcilingReleasingTailCount(
            tmdbSeasonEpisodeCounts: tmdbSeasons,
            segments: segments,
            terminalStatus: "RELEASING"
        )

        XCTAssertEqual(reconciled.map(\.episodeCount), [11, 12, 6, 12])
        XCTAssertTrue(AnimeStructurePolicy.hasMatchingEpisodeTotals(
            tmdbSeasonEpisodeCounts: tmdbSeasons,
            segments: reconciled
        ))
        XCTAssertTrue(AnimeStructurePolicy.canUseShallowTerminalContinuation(
            hydrationPolicy: .initiallyVisible,
            relationType: "SEQUEL",
            mediaFormat: "ONA",
            tmdbSeasonEpisodeCounts: tmdbSeasons,
            currentSegments: Array(segments.dropLast()),
            continuationSegment: segments[3],
            continuationStatus: "RELEASING"
        ))
        XCTAssertFalse(AnimeStructurePolicy.canUseShallowTerminalContinuation(
            hydrationPolicy: .complete,
            relationType: "SEQUEL",
            mediaFormat: "ONA",
            tmdbSeasonEpisodeCounts: tmdbSeasons,
            currentSegments: Array(segments.dropLast()),
            continuationSegment: segments[3],
            continuationStatus: "RELEASING"
        ))
    }

    func testFinishedOversizedTailIsNotReconciled() {
        let segments: [AnimeStructureCoverageSegment] = [
            .init(mappedTMDBSeason: 1, episodeCount: 11),
            .init(mappedTMDBSeason: 2, episodeCount: 24)
        ]

        XCTAssertEqual(
            AnimeStructurePolicy.reconcilingReleasingTailCount(
                tmdbSeasonEpisodeCounts: [1: 11, 2: 12],
                segments: segments,
                terminalStatus: "FINISHED"
            ),
            segments
        )
    }

    func testJoJoUpcomingStageCompletesTMDBCoverage() {
        let tmdbSeasons = [1: 26, 2: 48, 3: 39, 4: 39, 5: 38, 6: 12]
        let currentSegments: [AnimeStructureCoverageSegment] = [
            .init(mappedTMDBSeason: 1, episodeCount: 26),
            .init(mappedTMDBSeason: 2, episodeCount: 24),
            .init(mappedTMDBSeason: 2, episodeCount: 24),
            .init(mappedTMDBSeason: 3, episodeCount: 39),
            .init(mappedTMDBSeason: 4, episodeCount: 39),
            .init(mappedTMDBSeason: 5, episodeCount: 12),
            .init(mappedTMDBSeason: 5, episodeCount: 26),
            .init(mappedTMDBSeason: 6, episodeCount: 1)
        ]
        let upcoming = AnimeStructureCoverageSegment(
            mappedTMDBSeason: nil,
            episodeCount: 11
        )

        XCTAssertTrue(AnimeStructurePolicy.admitsUpcomingContinuation(
            relationType: "SEQUEL",
            mediaFormat: "ONA",
            status: "NOT_YET_RELEASED",
            tmdbSeasonEpisodeCounts: tmdbSeasons,
            currentSegments: currentSegments,
            continuationSegment: upcoming
        ))
        XCTAssertTrue(AnimeStructurePolicy.canUseShallowTerminalContinuation(
            hydrationPolicy: .initiallyVisible,
            relationType: "SEQUEL",
            mediaFormat: "ONA",
            tmdbSeasonEpisodeCounts: tmdbSeasons,
            currentSegments: currentSegments,
            continuationSegment: upcoming,
            continuationStatus: "NOT_YET_RELEASED"
        ))
        XCTAssertFalse(AnimeStructurePolicy.admitsUpcomingContinuation(
            relationType: "SIDE_STORY",
            mediaFormat: "ONA",
            status: "NOT_YET_RELEASED",
            tmdbSeasonEpisodeCounts: tmdbSeasons,
            currentSegments: currentSegments,
            continuationSegment: upcoming
        ))
        XCTAssertFalse(AnimeStructurePolicy.admitsUpcomingContinuation(
            relationType: "SEQUEL",
            mediaFormat: "ONA",
            status: "NOT_YET_RELEASED",
            tmdbSeasonEpisodeCounts: tmdbSeasons,
            currentSegments: currentSegments,
            continuationSegment: .init(mappedTMDBSeason: nil, episodeCount: 10)
        ))
        var mismatchedPrefix = currentSegments
        mismatchedPrefix[0] = .init(mappedTMDBSeason: 1, episodeCount: 25)
        mismatchedPrefix[7] = .init(mappedTMDBSeason: 6, episodeCount: 2)
        XCTAssertFalse(AnimeStructurePolicy.admitsUpcomingContinuation(
            relationType: "SEQUEL",
            mediaFormat: "ONA",
            status: "NOT_YET_RELEASED",
            tmdbSeasonEpisodeCounts: tmdbSeasons,
            currentSegments: mismatchedPrefix,
            continuationSegment: upcoming
        ))
    }

    func testAmbiguousUnknownMappedCountsStillWithholdCoordinates() {
        let segments: [AnimeStructureCoverageSegment] = [
            .init(mappedTMDBSeason: 1, episodeCount: nil),
            .init(mappedTMDBSeason: 1, episodeCount: nil)
        ]

        let resolved = AnimeStructurePolicy.resolvingSingleUnknownMappedSeasonCounts(
            tmdbSeasonEpisodeCounts: [1: 24],
            segments: segments
        )

        XCTAssertEqual(resolved.compactMap(\.episodeCount), [])
        XCTAssertFalse(AnimeStructurePolicy.hasExactCoverage(
            tmdbSeasonEpisodeCounts: [1: 24],
            segments: resolved
        ))
        XCTAssertFalse(AnimeStructurePolicy.allowsLinearTMDBCoordinates(
            hydrationPolicy: .initiallyVisible,
            hasExactCoverage: false
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

    func testMALFallbackTraversesLinkClickContinuationAndMappedBridonArc() {
        XCTAssertTrue(AnimeMALFallbackRelationPolicy.traversesRegular(
            relationType: "sequel",
            isMappedRegular: false
        ))
        XCTAssertTrue(AnimeMALFallbackRelationPolicy.traversesRegular(
            relationType: "side_story",
            isMappedRegular: true
        ))
        XCTAssertFalse(AnimeMALFallbackRelationPolicy.discoversDetachedSpecial(
            relationType: "sequel",
            isMappedDetachedSpecial: false
        ))
        XCTAssertTrue(AnimeMALFallbackRelationPolicy.discoversDetachedSpecial(
            relationType: "side_story",
            isMappedDetachedSpecial: false
        ))
    }

    func testMALFallbackStatusTracksAiringContinuationInsteadOfFinishedRoot() {
        XCTAssertEqual(AnimeFallbackStatusPolicy.aggregateStatus(
            statuses: ["finished_airing", "currently_airing"],
            rootStatus: "finished_airing"
        ), "RELEASING")
        XCTAssertEqual(AnimeFallbackStatusPolicy.aggregateStatus(
            statuses: ["finished_airing", "not_yet_aired"],
            rootStatus: "finished_airing"
        ), "NOT_YET_RELEASED")
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


private actor TrackerImportConcurrencyProbe {
    private var active = 0
    private var maximumActive = 0
    private var started: [Int] = []
    private var completed: [Int] = []

    func begin(_ id: Int) {
        started.append(id)
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func finish(_ id: Int) {
        active -= 1
        completed.append(id)
    }

    func snapshot() -> (active: Int, maximum: Int, started: [Int], completed: [Int]) {
        (active, maximumActive, started, completed)
    }
}

final class TrackerImportPerformanceTests: XCTestCase {
    func testLargeLibraryLookupsKeepInputOrderAndBoundConcurrentWork() async throws {
        let probe = TrackerImportConcurrencyProbe()
        let count = 10_000
        let values = try await TrackerImportWork.map(Array(0..<count)) { id -> Int? in
            await probe.begin(id)
            if id.isMultiple(of: 7) { await Task.yield() }
            await probe.finish(id)
            return id.isMultiple(of: 11) ? nil : id
        }
        let result = await probe.snapshot()
        XCTAssertEqual(values, (0..<count).map { $0.isMultiple(of: 11) ? nil : $0 })
        XCTAssertEqual(result.started.count, count)
        XCTAssertEqual(Set(result.completed), Set(0..<count))
        XCTAssertEqual(result.active, 0)
        XCTAssertLessThanOrEqual(result.maximum, TrackerImportWork.maximumConcurrentLookups)
    }

    func testBoundedLookupsPreserveOrderAndMissingResults() async throws {
        let probe = TrackerImportConcurrencyProbe()
        let results = try await TrackerImportWork.map(Array(0..<24)) { id -> Int? in
            await probe.begin(id)
            try await Task.sleep(nanoseconds: id == 0 ? 160_000_000 : 20_000_000)
            await probe.finish(id)
            return id.isMultiple(of: 5) ? nil : id
        }
        let snapshot = await probe.snapshot()
        XCTAssertEqual(results, (0..<24).map { $0.isMultiple(of: 5) ? nil : $0 })
        XCTAssertEqual(snapshot.started.count, 24)
        XCTAssertEqual(snapshot.maximum, 4)
        XCTAssertEqual(snapshot.active, 0)
        XCTAssertLessThan(try XCTUnwrap(snapshot.completed.firstIndex(of: 4)), try XCTUnwrap(snapshot.completed.firstIndex(of: 0)))
    }

    func testCanceledImportDoesNotStartTheRestOfTheLibrary() async throws {
        let probe = TrackerImportConcurrencyProbe()
        let admitted = expectation(description: "Initial bounded lookups started")
        admitted.expectedFulfillmentCount = 4
        let task = Task {
            try await TrackerImportWork.map(Array(0..<1_000)) { id in
                await probe.begin(id)
                admitted.fulfill()
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return id
            }
        }
        await fulfillment(of: [admitted], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Canceled preparation must not return a batch for commit")
        } catch is CancellationError {
        }
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.started.count, 4)
    }

    func testExpiredAuthorityCancelsRemainingLookups() async throws {
        enum AuthorityError: Error { case expired }
        let probe = TrackerImportConcurrencyProbe()
        do {
            _ = try await TrackerImportWork.map(Array(0..<1_000)) { id in
                await probe.begin(id)
                if id == 0 { throw AuthorityError.expired }
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return id
            }
            XCTFail("Expired authority must not produce an import batch")
        } catch AuthorityError.expired {
        }
        let snapshot = await probe.snapshot()
        XCTAssertLessThanOrEqual(snapshot.started.count, 4)
    }

    func testAniListImportReusesMetadataWithoutAnotherRequest() async throws {
        let anime = try importAnime(id: 1)
        let nodes = try await AniListImportMetadata.resolve(ids: [1, 1], prefetched: [anime]) { _ in
            XCTFail("The library response already contains this metadata")
            return [:]
        }
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[1]?.seasonYear, 2020)
        XCTAssertEqual(nodes[1]?.format, "TV")
        XCTAssertEqual(nodes[1]?.kitsuId, 42)
    }

    func testAniListImportFetchesOnlyMissingIDsAndRejectsMismatchedMetadata() async throws {
        let first = try importAnime(id: 1)
        let second = try importAnime(id: 2)
        let foreign = try importAnime(id: 9)
        let nodes = try await AniListImportMetadata.resolve(ids: [3, 2, 1, 2], prefetched: [first, foreign]) { ids in
            XCTAssertEqual(ids, [2, 3])
            return [2: second, 3: foreign, 9: foreign]
        }
        XCTAssertEqual(Set(nodes.keys), Set([1, 2]))
    }

    func testCompleteIDLookupDoesNotRetryEachMissingID() throws {
        let page = try TrackerAniListIDBatchPage.decode(
            Data(#"{"data":{"Page":{"pageInfo":{"hasNextPage":false},"media":[{"id":101,"idMal":1}]}}}"#.utf8),
            requestedIDs: Set([1, 2])
        )
        let complete = TrackerAniListIDBatchResult(idsByMAL: page.idsByMAL, isComplete: !page.hasNextPage)
        XCTAssertEqual(complete.idsByMAL, [1: 101])
        XCTAssertEqual(complete.fallbackIDs(requested: [1, 2]), [])
        let partial = TrackerAniListIDBatchResult(idsByMAL: page.idsByMAL, isComplete: false)
        XCTAssertEqual(partial.fallbackIDs(requested: [1, 2]), [2])
        let failed = TrackerAniListIDBatchResult(idsByMAL: [:], isComplete: false)
        XCTAssertEqual(failed.fallbackIDs(requested: [1, 2]), [1, 2])
    }

    func testPartialAndInvalidIDResponsesNeverClaimCompleteAbsence() throws {
        let payloads = [
            #"{"data":{"Page":{"media":[]}}}"#,
            #"{"data":{"Page":{"pageInfo":{"hasNextPage":false},"media":[]}},"errors":[{"message":"unavailable"}]}"#,
            #"{"data":{"Page":{"pageInfo":{"hasNextPage":false},"media":[{"id":101,"idMal":9}]}}}"#,
            #"{"data":{"Page":{"pageInfo":{"hasNextPage":false},"media":[{"id":-1,"idMal":1}]}}}"#
        ]
        for payload in payloads {
            XCTAssertThrowsError(try TrackerAniListIDBatchPage.decode(Data(payload.utf8), requestedIDs: [1]))
        }
        let page = try TrackerAniListIDBatchPage.decode(
            Data(#"{"data":{"Page":{"pageInfo":{"hasNextPage":true},"media":[{"id":101,"idMal":1}]}}}"#.utf8),
            requestedIDs: [1]
        )
        XCTAssertTrue(page.hasNextPage)
    }

    func testTrackerAndMetadataRequestsShareAniListSpacing() async throws {
        let limiter = AniListRateLimiter(minInterval: 0.08, burstCapacity: 1)
        let scheduler = TrackerRequestScheduler(aniListLimiter: limiter)
        let start = Date()
        try await scheduler.waitForSlot(provider: .anilist)
        try await limiter.waitForSlot()
        try await scheduler.waitForSlot(provider: .anilist)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.14)
    }

    func testTrackerCooldownDelaysAlreadyWaitingMetadataRequests() async throws {
        let limiter = AniListRateLimiter(minInterval: 0.08, burstCapacity: 1)
        let scheduler = TrackerRequestScheduler(aniListLimiter: limiter)
        try await limiter.waitForSlot()
        let start = Date()
        let waiter = Task { try await limiter.waitForSlot() }
        try await Task.sleep(nanoseconds: 15_000_000)
        let response = try response(status: 429, headers: ["Retry-After": "0.2"])
        _ = await scheduler.recordResponse(provider: .anilist, response: response)
        try await waiter.value
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.19)
    }

    func testCanceledAniListQueueDoesNotLeaveLongReservations() async throws {
        let limiter = AniListRateLimiter(minInterval: 0.08, burstCapacity: 1)
        try await limiter.waitForSlot()
        let waiters = (0..<20).map { _ in Task { try await limiter.waitForSlot() } }
        try await Task.sleep(nanoseconds: 15_000_000)
        for waiter in waiters { waiter.cancel() }
        for waiter in waiters { _ = try? await waiter.value }
        let start = Date()
        try await limiter.waitForSlot()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.4)
    }

    func testTMDBCooldownDelaysQueuedLookup() async throws {
        let limiter = TMDBRateLimiter(maxConcurrent: 2, minInterval: 0.08)
        _ = try await limiter.execute { 0 }
        let start = Date()
        let waiter = Task { try await limiter.execute { 1 } }
        try await Task.sleep(nanoseconds: 15_000_000)
        let response = try response(status: 429, headers: ["Retry-After": "0.2"])
        await limiter.recordResponse(response)
        let value = try await waiter.value
        XCTAssertEqual(value, 1)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.19)
    }

    func testMALCooldownExtendsAQueuedRequest() async throws {
        let scheduler = TrackerRequestScheduler()
        try await scheduler.waitForSlot(provider: .myAnimeList)
        let start = Date()
        let waiter = Task { try await scheduler.waitForSlot(provider: .myAnimeList) }
        try await Task.sleep(nanoseconds: 400_000_000)
        let response = try response(status: 429, headers: ["Retry-After": "1"])
        _ = await scheduler.recordResponse(provider: .myAnimeList, response: response)
        try await waiter.value
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 1.3)
    }

    func testInvalidOptionalImportMetadataDoesNotDiscardTheProgressRow() throws {
        let data = Data(#"{"id":1,"idMal":1,"title":{"english":"Example"},"episodes":12,"seasonYear":999999999}"#.utf8)
        let media = try JSONDecoder().decode(TrackerAniListImportMedia.self, from: data)
        XCTAssertEqual(media.id, 1)
        XCTAssertEqual(media.episodes, 12)
        XCTAssertNil(media.importMetadata)
    }

    func testReducedAniListRateLimitReschedulesQueuedRequests() async throws {
        let limiter = AniListRateLimiter(minInterval: 0.08, burstCapacity: 1)
        try await limiter.waitForSlot()
        let start = Date()
        let waiter = Task { try await limiter.waitForSlot() }
        try await Task.sleep(nanoseconds: 15_000_000)
        let response = try response(status: 200, headers: ["X-RateLimit-Limit": "75"])
        await limiter.recordResponse(response)
        try await waiter.value
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.7)
    }

    private func importAnime(id: Int) throws -> AniListAnime {
        let json = """
        {"id":\(id),"idMal":\(id),"title":{"english":"Example","romaji":"Example"},"episodes":12,"seasonYear":2020,"format":"TV","externalLinks":[{"site":"Kitsu","url":"https://kitsu.io/anime/42"}]}
        """
        return try JSONDecoder().decode(AniListAnime.self, from: Data(json.utf8))
    }

    private func response(status: Int, headers: [String: String]) throws -> HTTPURLResponse {
        let url = try XCTUnwrap(URL(string: "https://example.com/metadata"))
        return try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers))
    }
}

final class TrackerAuditRegressionTests: XCTestCase {
    func testFullLengthAnimeImportRetainsEverySeasonAcrossUnsortedHistory() throws {
        let count = ProgressPersistencePolicy.maximumBulkEpisodeMutationCount
        let episodes = (1...count).map { number in
            episode(number, season: (number - 1) / 200 + 2, mapped: (number - 1) % 200 + 1)
        }
        let ranges = try XCTUnwrap(TrackerAnimeImportCoordinates.ranges(watched: count, episodes: Array(episodes.reversed())))
        XCTAssertEqual(ranges.count, (count + 199) / 200)
        XCTAssertNil(ranges[1])
        XCTAssertEqual(ranges.values.flatMap { $0 }.reduce(0) { $0 + $1.count }, count)
        for season in ranges.keys {
            let remaining = count - (season - 2) * 200
            XCTAssertEqual(ranges[season], [1...min(200, remaining)])
        }
        var partial = episodes
        partial.removeLast()
        XCTAssertNil(TrackerAnimeImportCoordinates.ranges(watched: count, episodes: partial))
        var ambiguous = episodes
        ambiguous[count - 1] = episode(count, season: 2, mapped: 1)
        XCTAssertNil(TrackerAnimeImportCoordinates.ranges(watched: count, episodes: ambiguous))
    }

    func testRepeatedWatchCallbacksPreserveNewAttemptsAndIndependentProviders() throws {
        var gate = TrackerWatchSyncDedupeGate()
        let base = Date(timeIntervalSinceReferenceDate: 100)
        for index in 0..<1_000 {
            let now = base.addingTimeInterval(Double(index) * 1_000)
            let successKey = "fixture|anilist|episode-\(index)"
            let retryKey = "fixture|mal|episode-\(index)"
            let success = try XCTUnwrap(gate.begin(key: successKey, now: now, completedInterval: 60, staleInFlightInterval: 600))
            let stale = try XCTUnwrap(gate.begin(key: retryKey, now: now, completedInterval: 60, staleInFlightInterval: 600))
            for _ in 0..<8 {
                XCTAssertNil(gate.begin(key: successKey, now: now, completedInterval: 60, staleInFlightInterval: 600))
                XCTAssertNil(gate.begin(key: retryKey, now: now, completedInterval: 60, staleInFlightInterval: 600))
            }
            gate.finish(registration: success, succeeded: true, now: now)
            gate.finish(registration: stale, succeeded: false, now: now)
            let retry = try XCTUnwrap(gate.begin(key: retryKey, now: now.addingTimeInterval(1), completedInterval: 60, staleInFlightInterval: 600))
            gate.finish(registration: stale, succeeded: true, now: now.addingTimeInterval(2))
            XCTAssertNil(gate.begin(key: retryKey, now: now.addingTimeInterval(3), completedInterval: 60, staleInFlightInterval: 600))
            XCTAssertNil(gate.begin(key: successKey, now: now.addingTimeInterval(3), completedInterval: 60, staleInFlightInterval: 600))
            gate.finish(registration: retry, succeeded: false, now: now.addingTimeInterval(4))
            let resumed = try XCTUnwrap(gate.begin(key: retryKey, now: now.addingTimeInterval(5), completedInterval: 60, staleInFlightInterval: 600))
            gate.finish(registration: resumed, succeeded: true, now: now.addingTimeInterval(6))
        }
    }

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


final class DASHAuditRegressionTests: XCTestCase {
    func testDASHResolvesNestedBasesAndSiblingRepresentations() throws {
        let source = try XCTUnwrap(URL(string: "https://media.test/catalog/main.mpd"))
        let xml = """
        <MPD><BaseURL>https://media.test/root/</BaseURL><Period><BaseURL>period/</BaseURL>
        <AdaptationSet><Representation id="video"><BaseURL>video/</BaseURL>
        <SegmentList><Initialization sourceURL="init.mp4"/><SegmentURL media="seg.m4s"/></SegmentList>
        </Representation><Representation id="audio"><BaseURL>audio/</BaseURL>
        <SegmentList><Initialization sourceURL="init.mp4"/><SegmentURL media="seg.m4s"/></SegmentList>
        </Representation></AdaptationSet></Period></MPD>
        """
        let document = try XCTUnwrap(SkyStreamDASHDocument(Data(xml.utf8)))
        let references = try XCTUnwrap(document.references(relativeTo: source))
        let media = Set(references.map(\.url.absoluteString).filter { !$0.hasSuffix("/") })
        XCTAssertEqual(media, [
            "https://media.test/root/period/video/init.mp4",
            "https://media.test/root/period/video/seg.m4s",
            "https://media.test/root/period/audio/init.mp4",
            "https://media.test/root/period/audio/seg.m4s"
        ])
    }

    func testDASHMaterializesInheritedSegmentsForEachRepresentation() throws {
        let source = try XCTUnwrap(URL(string: "https://media.test/catalog/main.mpd"))
        let xml = """
        <MPD><Period><AdaptationSet><SegmentList timescale="1">
        <Initialization sourceURL="init.mp4"/><SegmentURL media="seg.m4s"/></SegmentList>
        <Representation id="video"><BaseURL>video/</BaseURL></Representation>
        <Representation id="audio"><BaseURL>audio/</BaseURL><SegmentList timescale="2"/></Representation>
        </AdaptationSet></Period></MPD>
        """
        let document = try XCTUnwrap(SkyStreamDASHDocument(Data(xml.utf8)))
        let rewritten = try XCTUnwrap(document.rewritten(relativeTo: source, maximumOutputBytes: 100_000) {
            $0.absoluteString.replacingOccurrences(of: "media.test", with: "proxy.test")
        })
        let parsed = try XCTUnwrap(SkyStreamDASHDocument(rewritten))
        let references = try XCTUnwrap(parsed.references(relativeTo: source))
        let media = Set(references.map(\.url.absoluteString).filter { !$0.hasSuffix("/") })
        XCTAssertEqual(media, [
            "https://proxy.test/catalog/video/init.mp4",
            "https://proxy.test/catalog/video/seg.m4s",
            "https://proxy.test/catalog/audio/init.mp4",
            "https://proxy.test/catalog/audio/seg.m4s"
        ])
        let text = try XCTUnwrap(String(data: rewritten, encoding: .utf8))
        XCTAssertTrue(text.contains("timescale=\"2\""))
        XCTAssertEqual(references.filter(\.isInitialization).count, 2)
    }

    func testDASHRewritePreservesNamespacesAndQueryValues() throws {
        let source = try XCTUnwrap(URL(string: "https://media.test/catalog/main.mpd"))
        let xml = """
        <m:MPD xmlns:m="urn:mpeg:dash:schema:mpd:2011"><m:Period><m:AdaptationSet>
        <m:Representation><m:BaseURL>video/</m:BaseURL>
        <m:SegmentTemplate initialization="init.mp4?x=1&amp;y=2" media="seg.m4s"/>
        </m:Representation></m:AdaptationSet></m:Period></m:MPD>
        """
        let document = try XCTUnwrap(SkyStreamDASHDocument(Data(xml.utf8)))
        let rewritten = try XCTUnwrap(document.rewritten(relativeTo: source, maximumOutputBytes: 100_000) { $0.absoluteString })
        let parsed = try XCTUnwrap(SkyStreamDASHDocument(rewritten))
        let references = try XCTUnwrap(parsed.references(relativeTo: source))
        XCTAssertTrue(references.contains { $0.url.absoluteString == "https://media.test/catalog/video/init.mp4?x=1&y=2" })
        XCTAssertNil(document.rewritten(relativeTo: source, maximumOutputBytes: 10) { $0.absoluteString })
    }
}


extension DASHAuditRegressionTests {
    func testDASHLocalSegmentKindReplacesInheritedAddressingKind() throws {
        let source = try XCTUnwrap(URL(string: "https://media.test/main.mpd"))
        let xml = """
        <MPD><Period><SegmentBase><Initialization sourceURL="old.mp4"/></SegmentBase>
        <AdaptationSet><SegmentList><Initialization sourceURL="init.mp4"/>
        <SegmentURL media="seg.m4s"/></SegmentList><Representation id="video">
        <BaseURL>video/</BaseURL></Representation></AdaptationSet></Period></MPD>
        """
        let document = try XCTUnwrap(SkyStreamDASHDocument(Data(xml.utf8)))
        let rewritten = try XCTUnwrap(document.rewritten(relativeTo: source, maximumOutputBytes: 100_000) { $0.absoluteString })
        let text = try XCTUnwrap(String(data: rewritten, encoding: .utf8))
        XCTAssertFalse(text.contains("SegmentBase"))
        XCTAssertFalse(text.contains("old.mp4"))
        XCTAssertTrue(text.contains("https://media.test/video/seg.m4s"))
    }
}
