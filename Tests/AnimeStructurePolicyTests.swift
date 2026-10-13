import Foundation
import SwiftUI
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
    func testContainedCourKeepsKnownFinishedPrefixAndLeavesUndatedTailUnowned() throws {
        let rows = [courProofEpisode(1, date: "2024-07-06"), courProofEpisode(2, date: "2024-07-13"), courProofEpisode(3, date: nil)]
        let result = try XCTUnwrap(containedCourProof(count: 2, end: "2024-07-13", rows: rows))
        XCTAssertEqual(result.map(\.episodeNumber), [1, 2])
        XCTAssertNil(containedCourProof(count: 1, end: "2024-07-06", rows: rows))
        XCTAssertNil(containedCourProof(count: 2, end: "2024-07-13", rows: rows, trusted: false))
        XCTAssertNil(containedCourProof(count: 2, end: "2024-07-13", rows: rows, status: "RELEASING"))
    }

    func testContainedCourRequiresCompleteValidUniqueSourceInventory() {
        let valid = [courProofEpisode(1, date: "2024-07-06"), courProofEpisode(2, date: "2024-07-13"), courProofEpisode(3, date: nil)]
        let malformed = [valid[0], courProofEpisode(2, date: "2024-02-30"), valid[2]]
        let missing = [valid[0], courProofEpisode(2, date: nil), valid[2]]
        let duplicate = [valid[0], courProofEpisode(2, date: "2024-07-13", id: valid[0].id), valid[2]]
        for rows in [malformed, missing, duplicate, [valid[0], courProofEpisode(4, date: "2024-07-13"), valid[2]]] {
            XCTAssertNil(containedCourProof(count: 2, end: "2024-07-13", rows: rows))
        }
        XCTAssertNil(AnimeStructurePolicy.verifiedContainedCourEpisodes(episodeCount: 2, mediaFormat: "TV", status: "FINISHED",
            providerStartDate: "2024-07-06", providerEndDate: "2024-07-13", hasTrustedIdentity: true,
            permitsMeasuredOneDayOffset: false, hasExplicitSpecialContinuation: false,
            sourceEpisodeCount: 3, sourceEpisodes: Array(valid.prefix(2))))
    }

    func testContainedCourNeverConvertsFeatureOrMicroEpisodeUnits() {
        let feature = (1...4).map { courProofEpisode($0, date: "2024-07-06") }
        XCTAssertNil(containedCourProof(count: 1, end: "2024-07-06", rows: feature))
        let compiled = (1...24).map { courProofEpisode($0, date: "2024-07-06") }
        XCTAssertNil(containedCourProof(count: 120, end: "2024-07-06", rows: compiled))
        let partialFeature = [courProofEpisode(1, date: "2024-07-06"), courProofEpisode(2, date: nil),
            courProofEpisode(3, date: nil), courProofEpisode(4, date: nil)]
        func onaProof(_ rows: [TMDBEpisode]) -> [TMDBEpisode]? {
            AnimeStructurePolicy.verifiedContainedCourEpisodes(episodeCount: 1, mediaFormat: "ONA", status: "FINISHED",
                providerStartDate: "2024-07-06", providerEndDate: "2024-07-06", hasTrustedIdentity: true,
                permitsMeasuredOneDayOffset: false, hasExplicitSpecialContinuation: false,
                sourceEpisodeCount: rows.count, sourceEpisodes: rows)
        }
        XCTAssertNil(onaProof(partialFeature))
        XCTAssertEqual(onaProof(Array(partialFeature.prefix(1)))?.count, 1)
    }

    func testContainedCourRequiresIndependentSpecialTailAndConsistentCalendarOffset() throws {
        let rows = [courProofEpisode(1, date: "2024-07-06"), courProofEpisode(2, date: "2024-07-13"), courProofEpisode(3, date: "2024-08-10")]
        func proof(special: Bool, end: String) -> [TMDBEpisode]? {
            AnimeStructurePolicy.verifiedContainedCourEpisodes(episodeCount: 2, mediaFormat: "TV", status: "FINISHED",
                providerStartDate: "2024-07-07", providerEndDate: end, hasTrustedIdentity: true,
                permitsMeasuredOneDayOffset: special, hasExplicitSpecialContinuation: special,
                sourceEpisodeCount: 3, sourceEpisodes: rows)
        }
        XCTAssertNil(proof(special: false, end: "2024-07-14"))
        XCTAssertEqual(try XCTUnwrap(proof(special: true, end: "2024-07-14")).map(\.episodeNumber), [1, 2])
        XCTAssertNil(proof(special: true, end: "2024-07-13"))
    }

    func testMappedFinishedTVPrefixKeepsItsOwnBroadcastSpanAndLeavesLaterRowsUnowned() throws {
        let rows = [courProofEpisode(1, date: "2024-07-06"), courProofEpisode(2, date: "2024-07-13"), courProofEpisode(3, date: "2024-08-10")]
        func proof(format: String? = "TV", count: Int = 2, trusted: Bool = true, mapped: Bool = true,
            episodes: [TMDBEpisode]? = nil) -> [TMDBEpisode]? {
            AnimeStructurePolicy.verifiedContainedCourEpisodes(episodeCount: count, mediaFormat: format, status: "FINISHED",
                providerStartDate: "2024-07-06", providerEndDate: count == 1 ? "2024-07-06" : "2024-07-13",
                hasTrustedIdentity: trusted, permitsMeasuredOneDayOffset: false, hasExplicitSpecialContinuation: false,
                sourceEpisodeCount: 3, sourceEpisodes: episodes ?? rows, allowsMappedFinishedTVPrefix: mapped)
        }
        XCTAssertEqual(try XCTUnwrap(proof()).map(\.episodeNumber), [1, 2])
        XCTAssertNil(proof(format: "ONA"))
        XCTAssertNil(proof(count: 1))
        XCTAssertNil(proof(trusted: false))
        XCTAssertNil(proof(mapped: false))
        XCTAssertNil(proof(episodes: [rows[0], rows[1], courProofEpisode(3, date: "2024-07-13")]))
        XCTAssertNil(proof(episodes: [rows[0], rows[1], courProofEpisode(3, date: "2024-02-30")]))
    }

    func testMappedTVBroadcastOffsetAuthorityRequiresCompleteSameShowReciprocalRoster() {
        func proof(mapped: [Int?] = [99, 99], formats: [String?] = ["TV", "TV"], reciprocal: Bool = true,
            competing: Bool = false, complete: Bool = true) -> Bool {
            AnimeStructurePolicy.hasMappedTVBroadcastDateOffsetProof(lookupIsComplete: true, graphIsComplete: complete,
                tmdbShowId: 99, mappedShowIDs: mapped, mediaFormats: formats,
                statuses: ["finished_airing", "currently_airing"], episodeCounts: [2, nil],
                hasReciprocalTerminalRelation: reciprocal, hasCompetingOrdinaryOwner: competing)
        }
        XCTAssertTrue(proof())
        XCTAssertFalse(proof(mapped: [99, 100]))
        XCTAssertFalse(proof(mapped: [99, nil]))
        XCTAssertFalse(proof(formats: ["TV", nil]))
        XCTAssertFalse(proof(formats: ["ONA", "ONA"]))
        XCTAssertFalse(proof(reciprocal: false))
        XCTAssertFalse(proof(competing: true))
        XCTAssertFalse(proof(complete: false))
    }

    func testProvenMappedTVBroadcastOffsetsStayAtPredeterminedCourBoundaries() throws {
        let rows = [courProofEpisode(1, date: "2024-07-06"), courProofEpisode(2, date: "2024-07-13"),
            courProofEpisode(3, date: "2024-08-03"), courProofEpisode(4, date: "2024-08-10")]
        func proof(childDate: String, authority: Bool = true, formats: [String?] = ["TV", "TV"],
            competing: Bool = false, trusted: Bool = true) -> [Int]? {
            AnimeStructurePolicy.verifiedOngoingEpisodeCounts(hasExactRootIdentity: true,
                hasTrustedOrdinaryCourRoster: trusted, hasOrdinaryContinuationAmbiguity: competing,
                mediaFormats: formats, statuses: ["FINISHED", "RELEASING"], episodeCounts: [2, nil],
                providerStartDates: ["2024-07-06", childDate], tmdbSeasonEpisodeCounts: [1: 4],
                sourceEpisodes: rows, today: "2024-09-01", allowsMappedTVBroadcastDateOffsets: authority)
        }
        XCTAssertEqual(try XCTUnwrap(proof(childDate: "2024-08-04")), [2, 2])
        XCTAssertEqual(try XCTUnwrap(proof(childDate: "2024-08-03", authority: false)), [2, 2])
        XCTAssertNil(proof(childDate: "2024-08-05"))
        XCTAssertNil(proof(childDate: "2024-08-04", authority: false))
        XCTAssertNil(proof(childDate: "2024-08-04", formats: ["ONA", "ONA"]))
        XCTAssertNil(proof(childDate: "2024-08-04", formats: ["TV", nil]))
        XCTAssertNil(proof(childDate: "2024-08-04", competing: true))
        XCTAssertNil(proof(childDate: "2024-08-04", trusted: false))
    }

    func testContainedPlacementsRejectMultipleOwnersOfTheSameActualRows() {
        let rows = [courProofEpisode(1, date: "2024-07-06"), courProofEpisode(2, date: "2024-07-13")]
        let candidates = [courProofCandidate(id: 10, count: 2, start: "2024-07-06", end: "2024-07-13"),
            courProofCandidate(id: 11, count: 2, start: "2024-07-06", end: "2024-07-13")]
        let result = AnimeStructurePolicy.verifiedContainedEpisodePlacements(candidates: candidates,
            sourceSeasonEpisodeCounts: [1: 2], sourceSeasonDetails: [1: courProofSeason(rows)], specialContinuationParentIDs: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testMergedEpisodeProofsRejectSharedCoordinatesEvenWithDifferentSourceIDs() {
        let first = courProofEpisode(1, season: 0, date: "2024-07-06", id: 900)
        let conflicting = courProofEpisode(1, season: 0, date: "2024-07-06", id: 901)
        let valid = courProofEpisode(2, season: 2, date: "2024-07-13", id: 902)
        let result = AnimeStructurePolicy.nonConflictingEpisodePlacements([10: [first], 11: [conflicting], 12: [valid]])
        XCTAssertEqual(Set(result.keys), [12])
        XCTAssertTrue(AnimeStructurePolicy.nonConflictingEpisodePlacements([10: [first, first]]).isEmpty)
    }

    func testFinishedGroupedCoursUseAllStartAnchorsAndExactWholeBodyCount() {
        let rows = [courProofEpisode(1, date: "2024-07-06"), courProofEpisode(2, date: "2024-07-13"),
            courProofEpisode(3, date: "2024-08-03"), courProofEpisode(4, date: "2024-08-10")]
        var candidates = [courProofCandidate(id: 10, count: 2, start: "2024-07-06", end: "2024-07-12", title: "Collected Story First Cour", mapped: nil),
            courProofCandidate(id: 11, count: 2, start: "2024-08-03", end: "2024-08-10", title: "Collected Story Second Cour", mapped: nil)]
        candidates[0].nextIDs = [11]
        candidates[1].previousIDs = [10]
        func proof(_ entries: [AnimeStructureCourPlacementCandidate]) -> [Int: [TMDBEpisode]] {
            AnimeStructurePolicy.verifiedContainedEpisodePlacements(candidates: entries, sourceSeasonEpisodeCounts: [1: 4],
                sourceSeasonDetails: [1: courProofSeason(rows)], specialContinuationParentIDs: [])
        }
        XCTAssertEqual(proof(candidates)[10]?.map(\.episodeNumber), [1, 2])
        XCTAssertEqual(proof(candidates)[11]?.map(\.episodeNumber), [3, 4])
        var wrong = [candidates[0], courProofCandidate(id: 11, count: 2, start: "2024-08-04", end: "2024-08-10", title: "Collected Story Second Cour", mapped: nil)]
        wrong[1].previousIDs = [10]
        XCTAssertNil(proof(wrong)[10])
        var unlinked = candidates
        unlinked[1].previousIDs = []
        XCTAssertTrue(proof(unlinked).isEmpty)
    }

    func testMappedSpecialDateConflictNeedsAnotherExactSameShowSeasonOwner() throws {
        let showData = Data(#"{"id":99,"name":"Umbrella","vote_average":0,"popularity":0,"genres":[],"adult":false,"vote_count":0,"seasons":[{"id":5,"name":"New Edition","season_number":5,"episode_count":15,"air_date":"2024-07-06"}]}"#.utf8)
        let show = try JSONDecoder().decode(TMDBTVShowWithSeasons.self, from: showData)
        let old = courProofCandidate(id: 10, count: 7, start: "2017-08-12", end: "2017-08-13", title: "Old Edition", mapped: 5)
        let current = courProofCandidate(id: 11, count: 14, start: "2024-07-06", end: "2024-10-19", title: "New Edition", mapped: 6)
        let mappings = [10: try courProofMapping(id: 10, season: 5, type: "SPECIAL"), 11: try courProofMapping(id: 11, season: 6, type: "ONA")]
        XCTAssertEqual(AnimeStructurePolicy.contradictedMappedSpecialIDs(candidates: [old, current], mappingsByID: mappings, tmdbShow: show), [10])
        XCTAssertTrue(AnimeStructurePolicy.contradictedMappedSpecialIDs(candidates: [old], mappingsByID: mappings, tmdbShow: show).isEmpty)
        let unmatched = courProofCandidate(id: 11, count: 14, start: "2024-07-06", end: "2024-10-19", title: "Different Edition", mapped: 6)
        XCTAssertTrue(AnimeStructurePolicy.contradictedMappedSpecialIDs(candidates: [old, unmatched], mappingsByID: mappings, tmdbShow: show).isEmpty)
    }

    func testExactRootComponentCannotConnectThroughAnExcludedPilotOrAlternativeEdition() {
        let candidates: Set<Int> = [10, 11, 12]
        let constraints: [AnimeStructureRelationConstraint] = [.init(beforeID: 10, afterID: 50), .init(beforeID: 11, afterID: 12)]
        XCTAssertEqual(AnimeStructurePolicy.ordinaryConnectedIDs(rootID: 11, candidateIDs: candidates, constraints: constraints), [11, 12])
        XCTAssertTrue(AnimeStructurePolicy.ordinaryConnectedIDs(rootID: 50, candidateIDs: candidates, constraints: constraints).isEmpty)
    }

    func testWholeNamedCourUsesIndependentlyVerifiedSuccessorBoundaryWhenProviderEndIsStale() throws {
        var current = courProofCandidate(id: 10, count: 2, start: "2024-07-06", end: "2024-07-06")
        current.nextIDs = [11]
        var successor = courProofCandidate(id: 11, count: 2, start: "2024-08-03", end: "2024-08-10", title: "Next Story", mapped: 2)
        successor.previousIDs = [10]
        let rows = [courProofEpisode(1, date: "2024-07-06"), courProofEpisode(2, date: "2024-07-13")]
        let following = [courProofEpisode(1, season: 2, date: "2024-08-03"), courProofEpisode(2, season: 2, date: "2024-08-10")]
        let nextSource = TMDBSeasonDetail(id: 2, name: "Next Story", overview: nil, posterPath: nil, seasonNumber: 2, airDate: "2024-08-03", episodes: following)
        func proof(_ next: AnimeStructureCourPlacementCandidate, body: TMDBSeasonDetail? = nil) -> [TMDBEpisode]? {
            AnimeStructurePolicy.verifiedWholeCourWithSuccessor(candidate: current, successor: next,
                sourceSeason: courProofSeason(rows), sourceEpisodeCount: 2, successorSourceSeason: body ?? nextSource, successorSourceEpisodeCount: 2)
        }
        XCTAssertEqual(try XCTUnwrap(proof(successor)).map(\.episodeNumber), [1, 2])
        var unlinked = successor
        unlinked.previousIDs = []
        XCTAssertNil(proof(unlinked))
        let missing = TMDBSeasonDetail(id: 2, name: "Next Story", overview: nil, posterPath: nil, seasonNumber: 2, airDate: "2024-08-03", episodes: Array(following.prefix(1)))
        XCTAssertNil(proof(successor, body: missing))
        let overlapping = TMDBSeasonDetail(id: 2, name: "Next Story", overview: nil, posterPath: nil, seasonNumber: 2, airDate: "2024-07-06", episodes: [courProofEpisode(1, season: 2, date: "2024-07-06"), following[1]])
        var overlap = courProofCandidate(id: 11, count: 2, start: "2024-07-06", end: "2024-08-10", title: "Next Story", mapped: 2)
        overlap.previousIDs = [10]
        XCTAssertNil(proof(overlap, body: overlapping))
    }

    func testCompleteMappedIdentityClosesAbsoluteInventoryWithoutAdmittingUnmappedFutureFranchiseRoots() {
        let counts = Dictionary(uniqueKeysWithValues: (1...20).map { ($0, 25) })
        XCTAssertTrue(AnimeStructurePolicy.hasCompleteMappedIdentityInventory(lookupIsComplete: true, hasUnresolvedIdentity: false,
            episodeCounts: [500], statuses: ["FINISHED"], tmdbSeasonEpisodeCounts: counts))
        XCTAssertTrue(AnimeStructurePolicy.hasCompleteMappedIdentityInventory(lookupIsComplete: true, hasUnresolvedIdentity: false,
            episodeCounts: [500, 12], statuses: ["FINISHED", "NOT_YET_RELEASED"], tmdbSeasonEpisodeCounts: counts))
        XCTAssertFalse(AnimeStructurePolicy.hasCompleteMappedIdentityInventory(lookupIsComplete: true, hasUnresolvedIdentity: false,
            episodeCounts: [500, nil], statuses: ["FINISHED", "RELEASING"], tmdbSeasonEpisodeCounts: counts))
        XCTAssertFalse(AnimeStructurePolicy.hasCompleteMappedIdentityInventory(lookupIsComplete: false, hasUnresolvedIdentity: false,
            episodeCounts: [500], statuses: ["FINISHED"], tmdbSeasonEpisodeCounts: counts))
        XCTAssertFalse(AnimeStructurePolicy.hasCompleteMappedIdentityInventory(lookupIsComplete: true, hasUnresolvedIdentity: false,
            episodeCounts: [570], statuses: ["FINISHED"], tmdbSeasonEpisodeCounts: [1: 920]))
    }

    func testMappedArcTailRequiresUniqueNumberedContinuationAndExactFinalDate() throws {
        let regular = [courProofEpisode(1, name: "Story Arc (1)", date: "2024-07-06"), courProofEpisode(2, name: "Story Arc (2)", date: "2024-07-13")]
        let special = [courProofEpisode(1, season: 0, name: "Unrelated Recap", date: "2024-07-10"),
            courProofEpisode(2, season: 0, name: "Story Arc (3)", date: "2024-08-10"),
            courProofEpisode(3, season: 0, name: "Story Arc (4)", date: "2024-08-17")]
        func proof(_ rows: [TMDBEpisode], end: String = "2024-08-17") -> [TMDBEpisode]? {
            AnimeStructurePolicy.verifiedMappedArcContinuation(episodeCount: 4, mediaFormat: "TV", status: "FINISHED",
                providerStartDate: "2024-07-06", providerEndDate: end, sourceSeason: courProofSeason(regular),
                sourceEpisodeCount: 2, specialEpisodes: rows)
        }
        XCTAssertEqual(try XCTUnwrap(proof(special)).map(\.seasonNumber), [1, 1, 0, 0])
        XCTAssertNil(proof(Array(special.dropLast())))
        XCTAssertNil(proof(special + [courProofEpisode(4, season: 0, name: "Story Arc (3)", date: "2024-08-11")]))
        XCTAssertNil(proof(special, end: "2024-08-18"))
    }

    func testCompleteEpisodeListProvesInterleavedRecapsAndRejectsPartialOrConflictingCatalogs() throws {
        let regular = [courProofEpisode(1, name: "Story Arc (1)", date: "2024-07-06"), courProofEpisode(2, name: "Story Arc (2)", date: "2024-07-20")]
        let special = [courProofEpisode(1, season: 0, name: "Summary I", date: "2024-07-13")]
        let catalog = ["Episode 1 - Story Arc Part One", "Episode 2 - Summary One", "Episode 3 - Story Arc Part Two"]
        func proof(_ titles: [String], extras: [TMDBEpisode]? = nil) -> [TMDBEpisode]? {
            AnimeStructurePolicy.verifiedMappedEpisodeList(episodeCount: 3, mediaFormat: "TV", status: "FINISHED",
                providerStartDate: "2024-07-06", providerEndDate: "2024-07-20", sourceSeason: courProofSeason(regular),
                sourceEpisodeCount: 2, specialEpisodes: extras ?? special, streamingEpisodeTitles: titles)
        }
        XCTAssertEqual(try XCTUnwrap(proof(catalog)).map(\.seasonNumber), [1, 0, 1])
        XCTAssertNil(proof(Array(catalog.prefix(2))))
        XCTAssertNil(proof([catalog[0], catalog[0], catalog[2]]))
        XCTAssertNil(proof([catalog[0], "Episode 2 - Unrelated Film", catalog[2]]))
        XCTAssertNil(proof(catalog, extras: special + [courProofEpisode(2, season: 0, name: "Unrelated Special", date: "2024-07-14")]))
    }

    func testPrologueInsertionRetainsActualSeasonZeroCoordinateAndRejectsIncompleteInventory() throws {
        let regular = [courProofEpisode(1, season: 1, date: "2024-07-06"), courProofEpisode(1, season: 2, date: "2024-08-03")]
        let prologue = courProofEpisode(1, season: 0, date: "2024-07-27")
        let result = try XCTUnwrap(AnimeStructurePolicy.inventoryByInsertingEpisode(prologue, beforeSeason: 2,
            tmdbSeasonEpisodeCounts: [1: 1, 2: 1], sourceEpisodes: regular))
        XCTAssertEqual(result.seasonCounts, [1: 1, 2: 2])
        XCTAssertEqual(result.coordinates[2], .init(seasonNumber: 0, episodeNumber: 1))
        XCTAssertEqual(result.coordinates[3], .init(seasonNumber: 2, episodeNumber: 1))
        XCTAssertNil(AnimeStructurePolicy.inventoryByInsertingEpisode(prologue, beforeSeason: 2,
            tmdbSeasonEpisodeCounts: [1: 1, 2: 1], sourceEpisodes: Array(regular.prefix(1))))
        XCTAssertNil(AnimeStructurePolicy.inventoryByInsertingEpisode(regular[0], beforeSeason: 2,
            tmdbSeasonEpisodeCounts: [1: 1, 2: 1], sourceEpisodes: regular))
    }

    private func courProofEpisode(_ number: Int, season: Int = 1, name: String = "Episode", date: String?, id: Int? = nil) -> TMDBEpisode {
        TMDBEpisode(id: id ?? season * 1000 + number, name: name, overview: "Metadata", stillPath: nil,
            episodeNumber: number, seasonNumber: season, airDate: date, runtime: 24, voteAverage: 0, voteCount: 0)
    }

    private func courProofSeason(_ episodes: [TMDBEpisode]) -> TMDBSeasonDetail {
        TMDBSeasonDetail(id: 1, name: "Collected Story", overview: nil, posterPath: nil,
            seasonNumber: episodes.first?.seasonNumber ?? 1, airDate: episodes.first?.airDate, episodes: episodes)
    }

    private func courProofCandidate(id: Int, count: Int, start: String, end: String, title: String = "Collected Story", mapped: Int? = 1) -> AnimeStructureCourPlacementCandidate {
        .init(id: id, mappedTMDBSeason: mapped, episodeCount: count, format: "TV", status: "FINISHED",
            startDate: start, endDate: end, titles: [title], hasTrustedIdentity: true)
    }

    private func courProofMapping(id: Int, season: Int, type: String) throws -> AniMapMapping {
        let object: [String: Any] = ["anilist_id": id, "tmdb_show_id": 99, "tmdb_season": season, "media_type": type]
        return try JSONDecoder().decode(AniMapMapping.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func containedCourProof(count: Int, end: String, rows: [TMDBEpisode], trusted: Bool = true, status: String = "FINISHED") -> [TMDBEpisode]? {
        AnimeStructurePolicy.verifiedContainedCourEpisodes(episodeCount: count, mediaFormat: "TV", status: status,
            providerStartDate: "2024-07-06", providerEndDate: end, hasTrustedIdentity: trusted,
            permitsMeasuredOneDayOffset: false, hasExplicitSpecialContinuation: false,
            sourceEpisodeCount: rows.count, sourceEpisodes: rows)
    }

    func testImageDataSaverUsesSmallerTMDBRequestsWithoutUpscaling() {
        XCTAssertEqual(TMDBImageRequestPolicy.urlString(for: "/poster.jpg", kind: .poster, dataSaverEnabled: false), "https://image.tmdb.org/t/p/original/poster.jpg")
        XCTAssertEqual(TMDBImageRequestPolicy.urlString(for: "/poster.jpg", kind: .poster, dataSaverEnabled: true), "https://image.tmdb.org/t/p/w342/poster.jpg")
        XCTAssertEqual(TMDBImageRequestPolicy.urlString(for: "/backdrop.jpg", kind: .backdrop, dataSaverEnabled: true), "https://image.tmdb.org/t/p/w780/backdrop.jpg")
        XCTAssertEqual(TMDBImageRequestPolicy.urlString(for: "/still.jpg", kind: .still, dataSaverEnabled: true), "https://image.tmdb.org/t/p/w300/still.jpg")
        XCTAssertEqual(TMDBImageRequestPolicy.urlString(for: "/profile.jpg", kind: .profile, dataSaverEnabled: true), "https://image.tmdb.org/t/p/w185/profile.jpg")
        let thumbnail = "https://image.tmdb.org/t/p/w92/poster.jpg"
        XCTAssertEqual(TMDBImageRequestPolicy.urlString(for: thumbnail, kind: .poster, dataSaverEnabled: true), thumbnail)
        let large = "https://image.tmdb.org/t/p/w1280/still.jpg"
        XCTAssertEqual(TMDBImageRequestPolicy.urlString(for: large, kind: .still, dataSaverEnabled: true), "https://image.tmdb.org/t/p/w300/still.jpg")
    }

    func testImageDataSaverPreservesProviderAndSignedArtworkURLs() {
        let urls = [
            "https://provider.example/t/p/original/poster.jpg",
            "https://image.tmdb.org.attacker.example/t/p/original/poster.jpg",
            "https://image.tmdb.org/t/p/original/poster.jpg?token=private",
            "https://image.tmdb.org/t/p/original/poster.jpg#fragment",
            "https://user:password@image.tmdb.org/t/p/original/poster.jpg",
            "https://image.tmdb.org:8443/t/p/original/poster.jpg",
            "https://image.tmdb.org/not-an-image/original/poster.jpg",
            "http://image.tmdb.org/t/p/original/poster.jpg",
            "https://image.tmdb.org/t/p/original/network.svg",
            "https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/image.jpg"
        ]
        for url in urls {
            XCTAssertEqual(TMDBImageRequestPolicy.urlString(for: url, kind: .poster, dataSaverEnabled: true), url)
        }
    }

    func testImageDataSaverUsesOnlySuppliedAnimeAndMangaCoverVariants() throws {
        let data = Data(#"{"large":"https://images.example/cover-original.jpg?token=large","medium":"https://images.example/cover-thumbnail.jpg?token=medium"}"#.utf8)
        let anime = try JSONDecoder().decode(AniListAnime.AniListCoverImage.self, from: data)
        let manga = try JSONDecoder().decode(AniListManga.AniListMangaCover.self, from: data)
        XCTAssertEqual(anime.preferredURL(dataSaverEnabled: false), anime.large)
        XCTAssertEqual(anime.preferredURL(dataSaverEnabled: true), anime.medium)
        XCTAssertEqual(manga.preferredURL(dataSaverEnabled: false), manga.large)
        XCTAssertEqual(manga.preferredURL(dataSaverEnabled: true), manga.medium)
        XCTAssertEqual(ImageDataSaverSettings.preferredURL(large: anime.large, medium: nil, dataSaverEnabled: true), anime.large)
        XCTAssertEqual(ImageDataSaverSettings.preferredURL(large: nil, medium: anime.medium, dataSaverEnabled: false), anime.medium)
        XCTAssertEqual(ImageDataSaverSettings.preferredURL(large: anime.large, medium: "  ", dataSaverEnabled: true), anime.large)
        XCTAssertNil(ImageDataSaverSettings.preferredURL(large: nil, medium: nil, dataSaverEnabled: true))
    }

    func testImageDataSaverIsOffInAnUnconfiguredDeviceStore() throws {
        let name = "ImageDataSaverTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(ImageDataSaverSettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: ImageDataSaverSettings.enabledKey)
        XCTAssertTrue(ImageDataSaverSettings.isEnabled(defaults: defaults))
    }

    func testBackgroundFrameRatePreservesDefaultsAndSupportsHighRefresh() {
        XCTAssertEqual(HomeAnimatedBackgroundFrameRate.resolved(nil), .fps20)
        XCTAssertEqual(HomeAnimatedBackgroundFrameRate.resolved("fps15"), .fps20)
        XCTAssertEqual(HomeAnimatedBackgroundFrameRate.resolved("invalid"), .fps20)
        XCTAssertEqual(HomeAnimatedBackgroundFrameRate.resolved("fps60").frameInterval, 1.0 / 60.0)
        XCTAssertEqual(HomeAnimatedBackgroundFrameRate.resolved("fps120").frameInterval, 1.0 / 120.0)
        XCTAssertEqual(HomeAnimatedBackgroundFrameRate.allCases.map(\.framesPerSecond), [20, 30, 60, 120])
    }

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

    func testSpecialDateSpanHydratesOnlyCompleteMonogatariWeekendGroup() {
        let episodes = [tmdbSpecialEpisode(number: 34, name: "Earlier", airDate: "2017-04-01")]
            + (35...41).map { number in
                tmdbSpecialEpisode(number: number, name: "Weekend \(number)",
                    airDate: number <= 38 ? "2017-08-12" : "2017-08-13")
            } + [tmdbSpecialEpisode(number: 42, name: "Later", airDate: "2024-07-06")]
        let hydrated = AnimeSpecialEpisodeHydrationPolicy.exactEpisodes(
            episodeCount: 7, exactReleaseDate: "2017-08-12", mappedSeasonNumber: 0,
            seasonDetailsByNumber: [0: specialSeasonDetail(episodes: episodes)], exactEndDate: "2017-08-13")
        XCTAssertEqual(hydrated.map(\.episodeNumber), Array(35...41))
        XCTAssertTrue(hydrated.allSatisfy { $0.seasonNumber == 0 && $0.overview != nil && $0.stillPath != nil })
    }

    func testSpecialDateSpanRejectsRepeatedCompleteGroupsAndConflictingEndDate() {
        let first = (1...7).map { number in
            tmdbSpecialEpisode(number: number, name: "First \(number)",
                airDate: number <= 4 ? "2017-08-12" : "2017-08-13")
        }
        let repeated = first + [tmdbSpecialEpisode(number: 8, name: "Other", airDate: "2018-01-01")]
            + (9...15).map { number in
                tmdbSpecialEpisode(number: number, name: "Second \(number)",
                    airDate: number <= 12 ? "2017-08-12" : "2017-08-13")
            }
        XCTAssertTrue(AnimeSpecialEpisodeHydrationPolicy.exactEpisodes(
            episodeCount: 7, exactReleaseDate: "2017-08-12", mappedSeasonNumber: 0,
            seasonDetailsByNumber: [0: specialSeasonDetail(episodes: repeated)], exactEndDate: "2017-08-13").isEmpty)
        XCTAssertTrue(AnimeSpecialEpisodeHydrationPolicy.exactEpisodes(
            episodeCount: 7, exactReleaseDate: "2017-08-12", mappedSeasonNumber: 0,
            seasonDetailsByNumber: [0: specialSeasonDetail(episodes: first)], exactEndDate: "2017-08-14").isEmpty)
        XCTAssertTrue(AnimeSpecialEpisodeHydrationPolicy.exactEpisodes(
            episodeCount: 2, exactReleaseDate: "2016-02-26", mappedSeasonNumber: 0,
            seasonDetailsByNumber: [0: specialSeasonDetail(episodes: first)], exactEndDate: "2016-02-26").isEmpty)
    }

    func testSpecialContinuationHydratesCompleteSameDateTailMetadata() throws {
        let source = continuationSpecialSeason()
        let episodes = continuationSpecialEpisodes(parents: [try continuationSpecialParent()], source: source)
        XCTAssertEqual(episodes.map(\.episodeNumber), [13, 14])
        XCTAssertEqual(episodes.map(\.seasonNumber), [4, 4])
        XCTAssertEqual(episodes.map(\.name), ["Power and Power", "Bright Future"])
        XCTAssertEqual(episodes.map(\.airDate), ["2015-10-29", "2015-10-29"])
        XCTAssertTrue(episodes.allSatisfy { $0.overview != nil && $0.stillPath != nil && $0.runtime == 24 })
    }

    func testSpecialContinuationRejectsContradictoryParentEvidence() throws {
        let parent = try continuationSpecialParent()
        let candidates: [[AnimeSpecialEpisodeHydrationPolicy.ContinuationParent]] = [
            [parent, parent],
            [try continuationSpecialParent(showID: 34743)],
            [try continuationSpecialParent(offset: 12)],
            [try continuationSpecialParent(status: "RELEASING")],
            [try continuationSpecialParent(endDate: nil)],
            [try continuationSpecialParent(endDate: "2015-09-28")],
            [try continuationSpecialParent(relationType: "SIDE_STORY")],
            [try continuationSpecialParent(format: "MOVIE")]
        ]
        for (index, parents) in candidates.enumerated() {
            XCTAssertTrue(continuationSpecialEpisodes(parents: parents).isEmpty, "Parent evidence \(index)")
        }
    }

    func testSpecialContinuationRejectsExtraTailAndDuplicateCoordinates() throws {
        let parent = try continuationSpecialParent()
        XCTAssertTrue(continuationSpecialEpisodes(parents: [parent],
            source: continuationSpecialSeason(extraTail: true)).isEmpty)
        XCTAssertTrue(continuationSpecialEpisodes(parents: [parent],
            source: continuationSpecialSeason(duplicateCoordinate: true)).isEmpty)
        let truncated = TMDBSeasonDetail(id: 4, name: "Season Four", overview: nil, posterPath: nil,
            seasonNumber: 4, airDate: "2015-07-07", episodes: Array(continuationSpecialSeason().episodes.dropLast()))
        XCTAssertTrue(continuationSpecialEpisodes(parents: [parent], source: truncated).isEmpty)
        XCTAssertTrue(continuationSpecialEpisodes(parents: [parent],
            source: continuationSpecialSeason(duplicateID: true)).isEmpty)
        XCTAssertTrue(continuationSpecialEpisodes(parents: [parent],
            source: continuationSpecialSeason(nonpositiveID: true)).isEmpty)
    }

    func testSpecialContinuationRejectsCompetingCanonicalOwners() throws {
        let episodes = continuationSpecialEpisodes(parents: [try continuationSpecialParent()])
        XCTAssertEqual(AnimeSpecialEpisodeHydrationPolicy.uniquelyOwnedContinuationEpisodes(
            [21852: episodes]).keys.sorted(), [21852])
        XCTAssertTrue(AnimeSpecialEpisodeHydrationPolicy.uniquelyOwnedContinuationEpisodes(
            [21852: episodes, 21854: episodes]).isEmpty)
        XCTAssertTrue(AnimeSpecialEpisodeHydrationPolicy.uniquelyOwnedContinuationEpisodes(
            [21852: episodes, 21854: Array(episodes.suffix(1))]).isEmpty)
    }

    func testSpecialContinuationRequiresConsistentParentDateAnchors() throws {
        XCTAssertEqual(continuationSpecialEpisodes(parents: [try continuationSpecialParent(
            startDate: "2015-07-06", endDate: "2015-09-28")]).map(\.episodeNumber), [13, 14])
        XCTAssertTrue(continuationSpecialEpisodes(parents: [try continuationSpecialParent(
            startDate: "2015-07-06", endDate: "2015-09-29")]).isEmpty)
        XCTAssertTrue(continuationSpecialEpisodes(parents: [try continuationSpecialParent(
            startDate: "2015-07-05", endDate: "2015-09-27")]).isEmpty)
    }

    func testSpecialContinuationDoesNotTranslateMALDiscReleaseIntoBroadcastDate() throws {
        XCTAssertTrue(continuationSpecialEpisodes(parents: [try continuationSpecialParent()],
            releaseDate: "2016-02-26").isEmpty)
        XCTAssertTrue(AnimeSpecialEpisodeHydrationPolicy.continuationEpisodes(
            tmdbShowId: 34742, episodeCount: 2, format: "SPECIAL", status: "RELEASING",
            exactReleaseDate: "2015-10-29", exactEndDate: "2015-10-29",
            parents: [try continuationSpecialParent()],
            seasonDetailsByNumber: [4: continuationSpecialSeason()]
        ).isEmpty)
        XCTAssertTrue(AnimeSpecialEpisodeHydrationPolicy.continuationEpisodes(
            tmdbShowId: 34742, episodeCount: 2, format: "SPECIAL", status: "FINISHED",
            exactReleaseDate: "2015-10-29", exactEndDate: nil,
            parents: [try continuationSpecialParent()],
            seasonDetailsByNumber: [4: continuationSpecialSeason()]
        ).isEmpty)
    }

    func testAniListEndDateDecodingSurvivesRelationConversion() throws {
        let raw = #"{"id":20995,"title":{"romaji":"Parent"},"startDate":{"year":2015,"month":7,"day":7},"endDate":{"year":2015,"month":9,"day":29},"relations":{"edges":[{"relationType":"SEQUEL","node":{"id":21852,"title":{"romaji":"Special"},"endDate":{"year":2015,"month":10,"day":29}}}]}}"#
        let node = try JSONDecoder().decode(AniListAnime.self, from: Data(raw.utf8))
        XCTAssertEqual(node.endDate?.exactDateString, "2015-09-29")
        let related = try XCTUnwrap(node.relations?.edges.first?.node.asAnime())
        XCTAssertEqual(related.endDate?.exactDateString, "2015-10-29")
        let legacy = try JSONDecoder().decode(AniListAnime.self,
            from: Data(#"{"id":20995,"title":{"romaji":"Parent"}}"#.utf8))
        XCTAssertNil(legacy.endDate)
    }

    func testTerminalUnknownSeasonProjectsVerifiedYamishibaiBody() throws {
        let entries = try terminalProjectionEntries()
        let counts = Dictionary(uniqueKeysWithValues: (1...17).map { ($0, 13) })
        XCTAssertEqual(AnimeTerminalSeasonProjectionPolicy.candidateSeasonNumber(
            tmdbShowId: 56559, entries: entries, tmdbSeasonEpisodeCounts: counts,
            hasCompetingOrdinaryOwner: false), 17)
        let result = AnimeTerminalSeasonProjectionPolicy.verifiedEpisodes(
            tmdbShowId: 56559, entries: entries, tmdbSeasonEpisodeCounts: counts,
            hasCompetingOrdinaryOwner: false, sourceSeason: try terminalProjectionSource(), today: "2026-10-12")
        XCTAssertEqual(result[213359]?.count, 13)
        XCTAssertEqual(result[213359]?.map(\.seasonNumber), Array(repeating: 17, count: 13))
        XCTAssertEqual(result[213359]?.map(\.episodeNumber), Array(1...13))
        XCTAssertEqual(result[213359]?.first?.airDate, "2026-07-13")
        XCTAssertTrue(result[213359]?.allSatisfy { $0.overview != nil && $0.stillPath != nil } == true)
    }

    func testTerminalUnknownSeasonRejectsCompetingOrUnverifiedRoster() throws {
        let counts = Dictionary(uniqueKeysWithValues: (1...17).map { ($0, 13) })
        for entries in [try terminalProjectionEntries(priorCount: 12),
                        try terminalProjectionEntries(priorShowID: 56560),
                        try terminalProjectionEntries(followsPrevious: false),
                        try terminalProjectionEntries(terminalStatus: "NOT_YET_RELEASED"),
                        try terminalProjectionEntries(terminalCount: 13)] {
            XCTAssertNil(AnimeTerminalSeasonProjectionPolicy.candidateSeasonNumber(
                tmdbShowId: 56559, entries: entries, tmdbSeasonEpisodeCounts: counts,
                hasCompetingOrdinaryOwner: false))
        }
        XCTAssertNil(AnimeTerminalSeasonProjectionPolicy.candidateSeasonNumber(
            tmdbShowId: 56559, entries: try terminalProjectionEntries(), tmdbSeasonEpisodeCounts: counts,
            hasCompetingOrdinaryOwner: true))
        var withFuture = try terminalProjectionEntries()
        withFuture.append(.init(providerID: 213360, mapping: nil, episodeCount: nil,
            status: "NOT_YET_RELEASED", format: "TV_SHORT", startDate: "2027-01-01", followsPrevious: true))
        XCTAssertNil(AnimeTerminalSeasonProjectionPolicy.candidateSeasonNumber(
            tmdbShowId: 56559, entries: withFuture, tmdbSeasonEpisodeCounts: counts,
            hasCompetingOrdinaryOwner: false))
    }

    func testTerminalUnknownSeasonRejectsDateCountAndSourceIdentityGaps() throws {
        let entries = try terminalProjectionEntries()
        let counts = Dictionary(uniqueKeysWithValues: (1...17).map { ($0, 13) })
        for source in [try terminalProjectionSource(firstDate: "2026-07-14"),
                       try terminalProjectionSource(count: 14),
                       try terminalProjectionSource(duplicateID: true),
                       try terminalProjectionSource(nonpositiveID: true)] {
            XCTAssertTrue(AnimeTerminalSeasonProjectionPolicy.verifiedEpisodes(
                tmdbShowId: 56559, entries: entries, tmdbSeasonEpisodeCounts: counts,
                hasCompetingOrdinaryOwner: false, sourceSeason: source, today: "2026-10-12").isEmpty)
        }
        XCTAssertTrue(AnimeTerminalSeasonProjectionPolicy.verifiedEpisodes(
            tmdbShowId: 56559, entries: entries, tmdbSeasonEpisodeCounts: counts,
            hasCompetingOrdinaryOwner: false, sourceSeason: try terminalProjectionSource(), today: "2026-07-12").isEmpty)
    }

    private func terminalProjectionEntries(
        priorCount: Int = 13, priorShowID: Int = 56559,
        followsPrevious: Bool = true, terminalStatus: String = "RELEASING", terminalCount: Int? = nil
    ) throws -> [AnimeTerminalSeasonProjectionPolicy.Entry] {
        var entries = try (1...16).map { season in
            let data = try JSONSerialization.data(withJSONObject: [
                "anilist_id": 10_000 + season, "tmdb_show_id": priorShowID,
                "tmdb_season": season, "tvdb_season": season, "tvdb_epoffset": 99, "media_type": "TV"
            ])
            return AnimeTerminalSeasonProjectionPolicy.Entry(providerID: 10_000 + season,
                mapping: try JSONDecoder().decode(AniMapMapping.self, from: data),
                episodeCount: priorCount, status: "FINISHED", format: "TV_SHORT", startDate: nil, followsPrevious: true)
        }
        entries.append(.init(providerID: 213359, mapping: nil, episodeCount: terminalCount,
            status: terminalStatus, format: "TV_SHORT", startDate: "2026-07-13", followsPrevious: followsPrevious))
        return entries
    }

    private func terminalProjectionSource(
        firstDate: String = "2026-07-13", count: Int = 13, duplicateID: Bool = false, nonpositiveID: Bool = false
    ) throws -> TMDBSeasonDetail {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let first = try XCTUnwrap(formatter.date(from: firstDate))
        let episodes = (1...count).map { number in
            let date = first.addingTimeInterval(Double(number - 1) * 7 * 24 * 60 * 60)
            let id = nonpositiveID && number == count ? 0 : (duplicateID && number == count ? 17_001 : 17_000 + number)
            return TMDBEpisode(id: id, name: "Source \(number)", overview: "Overview \(number)",
                stillPath: "/source-\(number).jpg", episodeNumber: number, seasonNumber: 17,
                airDate: formatter.string(from: date), runtime: 5, voteAverage: 0, voteCount: 0)
        }
        return TMDBSeasonDetail(id: 17, name: "Season Seventeen", overview: nil, posterPath: nil,
            seasonNumber: 17, airDate: firstDate, episodes: episodes)
    }

    private func continuationSpecialParent(
        showID: Int = 34742,
        offset: Int = 0,
        status: String = "FINISHED",
        format: String = "TV",
        relationType: String = "SEQUEL",
        startDate: String? = "2015-07-07",
        endDate: String? = "2015-09-29"
    ) throws -> AnimeSpecialEpisodeHydrationPolicy.ContinuationParent {
        let data = try JSONSerialization.data(withJSONObject: [
            "anilist_id": 20995, "mal_id": 28979, "tmdb_show_id": showID,
            "tmdb_season": 4, "tvdb_season": 4, "tvdb_epoffset": offset, "media_type": "TV"
        ])
        let mapping = try JSONDecoder().decode(AniMapMapping.self, from: data)
        return .init(mapping: mapping, relationType: relationType, episodeCount: 12,
            status: status, format: format, startDate: startDate, endDate: endDate)
    }

    private func continuationSpecialEpisodes(
        parents: [AnimeSpecialEpisodeHydrationPolicy.ContinuationParent],
        source: TMDBSeasonDetail? = nil,
        releaseDate: String = "2015-10-29"
    ) -> [TMDBEpisode] {
        AnimeSpecialEpisodeHydrationPolicy.continuationEpisodes(
            tmdbShowId: 34742, episodeCount: 2, format: "SPECIAL", status: "FINISHED",
            exactReleaseDate: releaseDate, exactEndDate: releaseDate, parents: parents,
            seasonDetailsByNumber: [4: source ?? continuationSpecialSeason()]
        )
    }

    private func continuationSpecialSeason(
        extraTail: Bool = false, duplicateCoordinate: Bool = false,
        duplicateID: Bool = false, nonpositiveID: Bool = false
    ) -> TMDBSeasonDetail {
        let dates = ["2015-07-07", "2015-07-14", "2015-07-21", "2015-07-28", "2015-08-04", "2015-08-11",
            "2015-08-25", "2015-09-01", "2015-09-08", "2015-09-15", "2015-09-22", "2015-09-29",
            "2015-10-29", "2015-10-29"] + (extraTail ? ["2015-10-29"] : [])
        let episodes = dates.enumerated().map { index, date in
            let number = duplicateCoordinate && index == 13 ? 13 : index + 1
            let title = index == 12 ? "Power and Power" : (index == 13 ? "Bright Future" : "Ordinary \(number)")
            let id = nonpositiveID && index == 13 ? 0 : (duplicateID && index == 13 ? 4_012 : 4_000 + index)
            return TMDBEpisode(id: id, name: title, overview: "Source overview \(number)",
                stillPath: "/source-\(number).jpg", episodeNumber: number, seasonNumber: 4, airDate: date,
                runtime: 24, voteAverage: 8, voteCount: 10)
        }
        return TMDBSeasonDetail(id: 4, name: "Season Four", overview: nil, posterPath: nil,
            seasonNumber: 4, airDate: "2015-07-07", episodes: episodes)
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
        XCTAssertFalse(AnimeStructurePolicy.allowsLinearTMDBCoordinates(
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

    func testOrderingUsesStartYearWhenSeasonYearIsMissing() {
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
            [1, 2]
        )
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

    func testAniMapDecoderPreservesTVDBAbsoluteOrderSentinelWithoutDroppingTheIndex() throws {
        let payload = Data(#"[{"anilist_id":21,"mal_id":21,"tmdb_show_id":37854,"tmdb_season":null,"tvdb_season":-1,"tvdb_epoffset":0,"media_type":"TV"},{"anilist_id":126403,"tmdb_show_id":123542,"tmdb_season":1,"tvdb_season":1,"tvdb_epoffset":0,"media_type":"ONA"}]"#.utf8)
        let decoder = JSONDecoder()
        let mappings = try decoder.decode([AniMapMapping].self, from: payload)
        XCTAssertEqual(mappings.count, 2)
        XCTAssertEqual(mappings[0].anilistId, 21)
        XCTAssertNil(mappings[0].tmdbSeason)
        XCTAssertEqual(mappings[0].tvdbSeason, -1)
        XCTAssertEqual(mappings[0].tvdbEpisodeOffset, 0)
        XCTAssertEqual(mappings[1].tmdbSeason, 1)
        XCTAssertEqual(mappings[1].tvdbSeason, 1)
        let restored = try decoder.decode([AniMapMapping].self, from: JSONEncoder().encode(mappings))
        XCTAssertEqual(restored[0].tvdbSeason, -1)
        XCTAssertNil(restored[0].tmdbSeason)
    }

    func testAniMapDecoderKeepsNegativeAndExtremeSeasonBoundariesStrict() throws {
        let decoder = JSONDecoder()
        for (key, values) in [
            ("tmdb_season", [-1, -2, Int.min, Int.max, RemoteMediaNumericBoundary.maximumSeasonNumber + 1]),
            ("tvdb_season", [-2, Int.min, Int.max, RemoteMediaNumericBoundary.maximumSeasonNumber + 1])
        ] {
            for value in values {
                let payload = try JSONSerialization.data(withJSONObject: [key: value])
                XCTAssertThrowsError(try decoder.decode(AniMapMapping.self, from: payload), "\(key)=\(value)")
            }
            for value in [0, 1, RemoteMediaNumericBoundary.maximumSeasonNumber] {
                let payload = try JSONSerialization.data(withJSONObject: [key: value])
                let mapping = try decoder.decode(AniMapMapping.self, from: payload)
                XCTAssertEqual(key == "tmdb_season" ? mapping.tmdbSeason : mapping.tvdbSeason, value)
            }
        }
    }

    func testDecodedAbsoluteOrderMappingRetainsSingleOpenEndedSeriesCoverage() throws {
        let mapping = try JSONDecoder().decode(AniMapMapping.self, from: Data(#"{"anilist_id":21,"tmdb_show_id":37854,"tmdb_season":null,"tvdb_season":-1,"media_type":"TV"}"#.utf8))
        let counts = [1: 61, 2: 16, 3: 14]
        let admitted = AnimeStructurePolicy.allowsSingleOpenEndedSeries(
            status: "RELEASING",
            episodeCount: nil,
            mappedTMDBSeason: mapping.tmdbSeason,
            tmdbSeasonEpisodeCounts: counts
        )
        XCTAssertTrue(admitted)
        XCTAssertTrue(AnimeStructurePolicy.acceptsMappedCoverage(
            lookupIsComplete: true,
            hasUnresolvedIdentity: false,
            hasExactCoverage: false,
            allowsSingleOpenEndedSeries: admitted
        ))
        XCTAssertTrue(AnimeStructurePolicy.hasCompatibleMappedOrder(
            [.init(mappedTMDBSeason: mapping.tmdbSeason, mappedTVDBSeason: mapping.tvdbSeason, tvdbEpisodeOffset: 0, episodeCount: nil)],
            expectedTMDBSeasonCount: counts.count
        ))
        XCTAssertEqual(AnimeSeasonEpisodeHydrationPolicy.displayEpisodeCount(
            declaredCount: nil,
            remainingTMDBCount: counts.values.reduce(0, +),
            allowsOpenEndedRemainder: admitted,
            status: "RELEASING"
        ), 91)
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

    func testRequestQueuePrioritizesVisibleWorkWithoutStarvingImports() {
        var order = TrackerRequestOrder()
        let background = UUID()
        let visible = UUID()
        let interactive = (0..<4).map { _ in UUID() }
        XCTAssertTrue(order.append(background, priority: .background))
        XCTAssertTrue(order.append(visible, priority: .visible))
        for id in interactive { XCTAssertTrue(order.append(id, priority: .interactive)) }
        XCTAssertEqual(order.popNext(), interactive[0])
        XCTAssertEqual(order.popNext(), interactive[1])
        XCTAssertEqual(order.popNext(), interactive[2])
        XCTAssertEqual(order.popNext(), background)
        XCTAssertEqual(order.popNext(), interactive[3])
        XCTAssertEqual(order.popNext(), visible)
        XCTAssertNil(order.popNext())
    }

    func testRequestQueueStaysBoundedAcrossLibraryFixtureSizes() {
        for count in [100, 1_000, 10_000] {
            var order = TrackerRequestOrder()
            var pending = Set<UUID>()
            var admitted = Set<UUID>()
            for index in 0..<count {
                if order.count == TrackerRequestOrder.maximumPendingRequests {
                    XCTAssertFalse(order.append(UUID(), priority: .interactive))
                    if let id = order.popNext() {
                        pending.remove(id)
                        XCTAssertTrue(admitted.insert(id).inserted)
                    }
                }
                let id = UUID()
                let priority: TrackerRequestPriority = index.isMultiple(of: 11) ? .interactive : .background
                XCTAssertTrue(order.append(id, priority: priority))
                pending.insert(id)
                XCTAssertLessThanOrEqual(order.count, TrackerRequestOrder.maximumPendingRequests)
            }
            while let id = order.popNext() {
                pending.remove(id)
                XCTAssertTrue(admitted.insert(id).inserted)
            }
            XCTAssertEqual(admitted.count, count)
            XCTAssertTrue(pending.isEmpty)
        }
    }

    func testLongServerCooldownPreservesDeadlineAndCancelsPromptly() async throws {
        let gate = TrackerRequestGate(minInterval: 0)
        let until = Date().addingTimeInterval(300)
        await gate.pause(until: until)
        let observedUntil = await gate.pausedUntil
        XCTAssertEqual(observedUntil, until)
        do {
            try await gate.waitForSlot(deadline: Date().addingTimeInterval(120), priority: .interactive)
            XCTFail("A 300 second cooldown must not be shortened for interactive work")
        } catch AniListRateLimiterError.localBackPressure(let slot, _) {
            XCTAssertEqual(slot, until)
        }
        let waiting = Task { try await gate.waitForSlot(priority: .background) }
        let timeout = Date().addingTimeInterval(2)
        while await gate.pendingCount == 0, Date() < timeout { await Task.yield() }
        let queued = await gate.pendingCount
        XCTAssertEqual(queued, 1)
        waiting.cancel()
        do {
            try await waiting.value
            XCTFail("Cancelled waiters cannot proceed during cooldown")
        } catch is CancellationError {}
        let remaining = await gate.pendingCount
        XCTAssertEqual(remaining, 0)
        let retainedUntil = await gate.pausedUntil
        XCTAssertEqual(retainedUntil, until)
    }

    func testFullCooldownIsSharedByTrackerMetadataAndBothTraktLanes() async throws {
        let limiter = AniListRateLimiter(minInterval: 0)
        let scheduler = TrackerRequestScheduler(aniListLimiter: limiter)
        let limited = try response(status: 429, headers: ["Retry-After": "300"])
        for provider in [TrackerRequestProvider.anilist, .myAnimeList, .trakt] {
            let delay = await scheduler.recordResponse(provider: provider, response: limited)
            XCTAssertEqual(delay, 300)
            for method in ["GET", "POST"] {
                do {
                    try await scheduler.waitForSlot(provider: provider, method: method, deadline: Date().addingTimeInterval(120))
                    XCTFail("A provider cooldown must cover every request lane")
                } catch AniListRateLimiterError.localBackPressure(let slot, _) {
                    XCTAssertGreaterThan(slot.timeIntervalSinceNow, 290)
                }
            }
        }
        do {
            try await limiter.waitForSlot(deadline: Date().addingTimeInterval(120))
            XCTFail("Tracker cooldown must apply to public AniList metadata too")
        } catch AniListRateLimiterError.localBackPressure(let slot, _) {
            XCTAssertGreaterThan(slot.timeIntervalSinceNow, 290)
        }
    }

    func testTraktReadsAndWritesUseTheirSeparateBudgets() async throws {
        let scheduler = TrackerRequestScheduler()
        try await scheduler.waitForSlot(provider: .trakt, method: "GET")
        try await scheduler.waitForSlot(provider: .trakt, method: "POST", deadline: Date().addingTimeInterval(0.2))
        do {
            try await scheduler.waitForSlot(provider: .trakt, method: "DELETE", deadline: Date().addingTimeInterval(0.2))
            XCTFail("Writes must retain their one-second budget")
        } catch AniListRateLimiterError.localBackPressure {}
    }

    func testTraktHeadersCanReduceTheReadBudget() async throws {
        let scheduler = TrackerRequestScheduler()
        try await scheduler.waitForSlot(provider: .trakt)
        let limited = try response(status: 200, headers: ["X-Ratelimit": #"{"period":300,"limit":10,"remaining":9}"#])
        _ = await scheduler.recordResponse(provider: .trakt, response: limited)
        do {
            try await scheduler.waitForSlot(provider: .trakt, deadline: Date().addingTimeInterval(2))
            XCTFail("A smaller server budget must reschedule queued reads")
        } catch AniListRateLimiterError.localBackPressure(let slot, _) {
            XCTAssertGreaterThan(slot.timeIntervalSinceNow, 25)
        }
    }

    func testAniListStartupUsesConservativeThirtyPerMinuteBudget() async throws {
        let limiter = AniListRateLimiter()
        try await limiter.waitForSlot()
        do {
            try await limiter.waitForSlot(deadline: Date().addingTimeInterval(1))
            XCTFail("Startup must not assume AniList's higher historical budget")
        } catch AniListRateLimiterError.localBackPressure(let slot, _) {
            XCTAssertGreaterThan(slot.timeIntervalSinceNow, 1)
        }
    }

    func testRateHeadersKeepFullNumericAndHTTPDateRetryWindows() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(TrackerRateLimitHeaderPolicy.retryDelay("300"), 300)
        XCTAssertEqual(TrackerRateLimitHeaderPolicy.retryDelay("Tue, 14 Nov 2023 22:18:20 GMT", now: now), 300)
        XCTAssertEqual(TrackerRateLimitHeaderPolicy.resetDelay("1700000300", now: now), 300)
        XCTAssertEqual(TrackerRateLimitHeaderPolicy.maximumSleepChunk, 60)
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


final class AnimeSeasonGraphOrderingTests: XCTestCase {
    func testLinkClickRelationsPlaceBridonBeforeThirdSeasonWithMissingSeasonYear() {
        let candidates = [
            candidate(126403, year: 2021, month: 4, day: 30),
            candidate(136484, year: 2023, month: 7, day: 14),
            candidate(170166, year: 2024, month: 12, day: 27),
            candidate(191832, seasonYear: 2026, seasonOrdinal: 2)
        ]
        let constraints = chain([126403, 136484, 170166, 191832])
        for rotation in candidates.indices {
            let shuffled = Array(candidates[rotation...]) + Array(candidates[..<rotation])
            XCTAssertEqual(AnimeStructurePolicy.relationOrderedIDs(shuffled, constraints: constraints), [126403, 136484, 170166, 191832])
            XCTAssertEqual(AnimeStructurePolicy.relationOrderedIDs(Array(shuffled.reversed()), constraints: constraints), [126403, 136484, 170166, 191832])
        }
    }

    func testExplicitContinuationOrderWinsOverContradictorySeasonalMetadata() {
        let candidates = [candidate(30, seasonYear: 2020), candidate(20), candidate(10, seasonYear: 2025)]
        XCTAssertEqual(AnimeStructurePolicy.relationOrderedIDs(candidates, constraints: chain([10, 20, 30])), [10, 20, 30])
    }

    func testSparseONADatesUseRealReleaseDatesBeforeProviderIdentifier() {
        let candidates = [candidate(1, year: 2025, month: 2, day: 1), candidate(2, year: 2024, month: 12, day: 27), candidate(3, year: 2024, month: 12, day: 20)]
        XCTAssertEqual(AnimeStructurePolicy.orderedIDs(candidates), [3, 2, 1])
    }

    func testBaiYaoPuRenamedONAsRetainRegularOrderWithMixedSeasonalMetadata() throws {
        let nodes = try JSONDecoder().decode([AniListAnime].self, from: Data(#"[{"id":156082,"title":{"romaji":"Bai Yao Pu: Si Fu Pian"},"format":"ONA","episodes":12},{"id":185834,"title":{"romaji":"Bai Yao Pu: Luoyang Pian"},"format":"ONA","episodes":12}]"#.utf8))
        let candidates = [candidate(nodes[1].id, seasonYear: 2025), candidate(nodes[0].id)]
        XCTAssertEqual(AnimeStructurePolicy.relationOrderedIDs(candidates, constraints: chain(nodes.map(\.id))), [156082, 185834])
        XCTAssertTrue(nodes.allSatisfy { AnimeRelationRolePolicy.isRegularContinuationCandidate(relationType: "SEQUEL", mediaFormat: $0.format) })
        XCTAssertFalse(nodes.contains { AnimeRelationRolePolicy.isDetachedSpecialCandidate(relationType: "SEQUEL", mediaFormat: $0.format, titleCandidates: [$0.title.romaji ?? ""]) })
        let segments = nodes.enumerated().map { index, node in AnimeStructureCoverageSegment(mappedTMDBSeason: index + 4, episodeCount: node.episodes) }
        let start = try XCTUnwrap(AnimeSeasonEpisodeHydrationPolicy.exactMappedSeasonStart(index: 1, segments: segments, tmdbSeasonEpisodeCounts: [1: 12, 2: 12, 3: 12, 4: 12, 5: 12]))
        XCTAssertEqual(start, 49)
        let episodes = AnimeSeasonEpisodeHydrationPolicy.episodes(count: 12, displaySeasonNumber: 2, startingAt: start, tmdbEpisodes: [49: episode(season: 5, number: 1, title: "Mapped Luoyang Episode")], tmdbCoordinates: [:], allowsTMDBCoordinates: true)
        XCTAssertEqual(episodes.first?.tmdbSeasonNumber, 5)
        XCTAssertEqual(episodes.first?.title, "Mapped Luoyang Episode")
    }

    func testLingLongSingleEpisodeContinuationIsRegularWithoutGuessingTMDBCoverage() throws {
        let node = try JSONDecoder().decode(AniListAnime.self, from: Data(#"{"id":126832,"title":{"romaji":"Ling Long Middle Chapter"},"format":"ONA","episodes":1}"#.utf8))
        XCTAssertTrue(AnimeRelationRolePolicy.isRegularContinuationCandidate(relationType: "SEQUEL", mediaFormat: node.format))
        XCTAssertFalse(AnimeRelationRolePolicy.isDetachedSpecialCandidate(relationType: "SEQUEL", mediaFormat: node.format, titleCandidates: [node.title.romaji ?? ""]))
        let count = AnimeSeasonEpisodeHydrationPolicy.displayEpisodeCount(declaredCount: node.episodes, remainingTMDBCount: 7, allowsOpenEndedRemainder: false)
        XCTAssertEqual(count, 1)
        XCTAssertNil(AnimeSeasonEpisodeHydrationPolicy.exactMappedSeasonStart(index: 0, segments: [.init(mappedTMDBSeason: nil, episodeCount: count)], tmdbSeasonEpisodeCounts: [1: 7]))
        let episodes = AnimeSeasonEpisodeHydrationPolicy.episodes(count: count, displaySeasonNumber: 2, startingAt: 7, tmdbEpisodes: [7: episode(season: 1, number: 7, title: "Unverified flattened episode")], tmdbCoordinates: [:], allowsTMDBCoordinates: false)
        XCTAssertEqual(episodes.map(\.title), ["Episode 1"])
        XCTAssertNil(episodes.first?.tmdbSeasonNumber)
    }

    func testHidamariSpecialBridgeKeepsDetachedClassificationAndSeasonZeroHydration() {
        XCTAssertFalse(AnimeRelationRolePolicy.isRegularContinuationCandidate(relationType: "SEQUEL", mediaFormat: "SPECIAL"))
        XCTAssertTrue(AnimeRelationRolePolicy.isDetachedSpecialCandidate(relationType: "SEQUEL", mediaFormat: "SPECIAL", titleCandidates: ["Hidamari Sketch x SP"]))
        let specialEpisodes = [episode(season: 0, number: 1, title: "Special One"), episode(season: 0, number: 2, title: "Special Two")]
        let seasonZero = TMDBSeasonDetail(id: 11237, name: "Specials", overview: nil, posterPath: nil, seasonNumber: 0, airDate: nil, episodes: specialEpisodes)
        let hydrated = AnimeSpecialEpisodeHydrationPolicy.exactEpisodes(episodeCount: 2, exactReleaseDate: nil, mappedSeasonNumber: nil, seasonDetailsByNumber: [0: seasonZero])
        XCTAssertEqual(hydrated.map(\.seasonNumber), [0, 0])
        XCTAssertEqual(hydrated.map(\.name), ["Special One", "Special Two"])
        XCTAssertNil(AnimeSeasonEpisodeHydrationPolicy.exactMappedSeasonStart(index: 0, segments: [.init(mappedTMDBSeason: 0, episodeCount: 2)], tmdbSeasonEpisodeCounts: [1: 12]))
    }

    func testRelationCyclesDuplicatesAndForeignEdgesAreDeterministicAndKeepEveryIdentity() {
        let candidates = [candidate(30, year: 2023), candidate(20, year: 2022), candidate(10, year: 2021), candidate(20, year: 2022)]
        let constraints = chain([10, 20, 30, 10]) + [.init(beforeID: 10, afterID: 20), .init(beforeID: 999, afterID: 10), .init(beforeID: 20, afterID: 20)]
        XCTAssertEqual(AnimeStructurePolicy.relationOrderedIDs(candidates, constraints: constraints), [10, 20, 30])
    }

    func testRelationOrderingDoesNotReintroduceExcludedTamayuraAndPrincessPrincipalEntries() {
        let acceptedTamayura = [candidate(10232), candidate(15731)]
        let tamayuraRelations = chain([9055, 10232, 15731, 20805])
        XCTAssertEqual(AnimeStructurePolicy.relationOrderedIDs(acceptedTamayura, constraints: tamayuraRelations), [10232, 15731])
        XCTAssertFalse(AnimeRelationRolePolicy.isRegularContinuationCandidate(relationType: "SIDE_STORY", mediaFormat: "OVA"))
        XCTAssertFalse(AnimeRelationRolePolicy.isRegularContinuationCandidate(relationType: "SEQUEL", mediaFormat: "MOVIE"))
        XCTAssertEqual(AnimeStructurePolicy.relationOrderedIDs([candidate(98505)], constraints: chain([98505, 129759, 137612])), [98505])
    }

    func testUnknownThirdSeasonKeepsIdentityWithoutInventingEpisodes() {
        let count = AnimeSeasonEpisodeHydrationPolicy.displayEpisodeCount(declaredCount: nil, remainingTMDBCount: 0, allowsOpenEndedRemainder: false)
        let episodes = AnimeSeasonEpisodeHydrationPolicy.episodes(count: count, displaySeasonNumber: 4, startingAt: 30, tmdbEpisodes: [:], tmdbCoordinates: [:], allowsTMDBCoordinates: false)
        let season = AniListSeasonWithPoster(seasonNumber: 4, anilistId: 191832, canonicalAniListId: 191832, malId: nil, kitsuId: nil, title: "Link Click Season 3", englishTitle: nil, romajiTitle: nil, nativeTitle: nil, episodes: episodes, posterUrl: nil)
        let model = AniListAnimeWithSeasons(id: 126403, malId: nil, title: "Link Click", genres: nil, seasons: [season], totalEpisodes: 0, status: "RELEASING", rating: nil)
        XCTAssertEqual(count, 0)
        XCTAssertTrue(model.satisfiesAnimeSeed(191832))
        XCTAssertEqual(model.seasons.map(\.canonicalAniListId), [191832])
        XCTAssertTrue(model.seasons[0].episodes.isEmpty)
    }

    func testLinkClickMappedUnknownTailResolvesBeforeShortsCanFillAnArtificialDeficit() throws {
        let candidates = try JSONDecoder().decode([AniListAnime].self, from: Data(#"[{"id":126403,"title":{"romaji":"Shiguang Dailiren"},"format":"ONA","episodes":11},{"id":136484,"title":{"romaji":"Shiguang Dailiren II"},"format":"ONA","episodes":12},{"id":170166,"title":{"romaji":"Shiguang Dailiren: Yingdu Pian"},"format":"ONA","episodes":6},{"id":191832,"title":{"romaji":"Shiguang Dailiren III"},"format":"ONA","status":"RELEASING"},{"id":140175,"idMal":50105,"title":{"english":"LINK CLICK (Shorts)"},"format":"ONA","episodes":18}]"#.utf8))
        let regular = Array(candidates.prefix(4))
        let segments = regular.enumerated().map { index, node in AnimeStructureCoverageSegment(mappedTMDBSeason: index + 1, episodeCount: node.episodes) }
        let tmdbCounts = [1: 11, 2: 12, 3: 6, 4: 12]
        let resolved = AnimeStructurePolicy.resolvingSingleUnknownMappedSeasonCounts(tmdbSeasonEpisodeCounts: tmdbCounts, segments: segments)
        XCTAssertEqual(resolved.map(\.episodeCount), [11, 12, 6, 12])
        XCTAssertFalse(AnimeStructurePolicy.hasKnownEpisodeDeficit(tmdbTotalEpisodeCount: 41, segments: resolved))
        XCTAssertFalse(AnimeStructurePolicy.hasKnownEpisodeDeficit(tmdbTotalEpisodeCount: 41, segments: segments))
        let shorts = try XCTUnwrap(candidates.last)
        XCTAssertEqual(shorts.id, 140175)
        XCTAssertEqual(shorts.idMal, 50105)
        XCTAssertFalse(AnimeRelationRolePolicy.admitsSupplementalRegularEntry(isMappedRegular: false, relationTypesToExistingEntries: ["SIDE_STORY", "CHARACTER"], mediaFormat: shorts.format))
        XCTAssertEqual(regular.map(\.id), [126403, 136484, 170166, 191832])
        let start = try XCTUnwrap(AnimeSeasonEpisodeHydrationPolicy.exactMappedSeasonStart(index: 3, segments: resolved, tmdbSeasonEpisodeCounts: tmdbCounts))
        XCTAssertEqual(start, 30)
        let count = AnimeSeasonEpisodeHydrationPolicy.displayEpisodeCount(declaredCount: resolved[3].episodeCount, remainingTMDBCount: 12, allowsOpenEndedRemainder: false, status: regular[3].status)
        let episodes = AnimeSeasonEpisodeHydrationPolicy.episodes(count: count, displaySeasonNumber: 4, startingAt: start, tmdbEpisodes: [30: episode(season: 4, number: 1, title: "Verified Season 3 Episode")], tmdbCoordinates: [:], allowsTMDBCoordinates: true)
        XCTAssertEqual(episodes.count, 12)
        XCTAssertEqual(episodes.first?.title, "Verified Season 3 Episode")
        XCTAssertEqual(episodes.first?.tmdbSeasonNumber, 4)
        XCTAssertEqual(episodes.first?.tmdbEpisodeNumber, 1)
    }

    func testKnownDeficitStillAllowsMappedOrDirectlyLinkedRegularSupplements() {
        XCTAssertTrue(AnimeStructurePolicy.hasKnownEpisodeDeficit(tmdbTotalEpisodeCount: 48, segments: [.init(mappedTMDBSeason: 1, episodeCount: 12)]))
        XCTAssertTrue(AnimeRelationRolePolicy.admitsSupplementalRegularEntry(isMappedRegular: true, relationTypesToExistingEntries: [], mediaFormat: "TV"))
        XCTAssertTrue(AnimeRelationRolePolicy.admitsSupplementalRegularEntry(isMappedRegular: false, relationTypesToExistingEntries: ["PREQUEL"], mediaFormat: "ONA"))
        XCTAssertTrue(AnimeRelationRolePolicy.admitsSupplementalRegularEntry(isMappedRegular: false, relationTypesToExistingEntries: ["sequel"], mediaFormat: "tv"))
        XCTAssertFalse(AnimeRelationRolePolicy.admitsSupplementalRegularEntry(isMappedRegular: false, relationTypesToExistingEntries: [], mediaFormat: "ONA"))
        XCTAssertFalse(AnimeRelationRolePolicy.admitsSupplementalRegularEntry(isMappedRegular: false, relationTypesToExistingEntries: ["OTHER"], mediaFormat: "ONA"))
    }

    func testSupplementSelectionSkipsRejectedFirstEntryForLaterKnownMapping() async throws {
        let root = try supplementalEntry(10)
        let rejected = try supplementalEntry(20, relationType: "SIDE_STORY")
        let mapped = try supplementalEntry(30)
        let selected = await AnimeRelationRolePolicy.firstAdmittedSupplementalEntry(candidates: [rejected, mapped], regularMappedIDs: [30], existingEntries: [root], prefetched: [:]) { _ in
            XCTFail("Known mapping selection must not require an additional detail request")
            return nil
        }
        XCTAssertEqual(selected?.id, 30)
    }

    func testSupplementSelectionHydratesUntilDirectContinuationAndBoundsRequests() async throws {
        let root = try supplementalEntry(10)
        let candidates = try [20, 30, 40, 50].map { try supplementalEntry($0) }
        let rejected = try supplementalEntry(20, relationType: "SIDE_STORY")
        let accepted = try supplementalEntry(30, relationType: "PREQUEL")
        var requested: [Int] = []
        let selected = await AnimeRelationRolePolicy.firstAdmittedSupplementalEntry(candidates: candidates, regularMappedIDs: [], existingEntries: [root], prefetched: [:]) { id in
            requested.append(id)
            return id == 20 ? rejected : accepted
        }
        XCTAssertEqual(selected?.id, 30)
        XCTAssertEqual(requested, [20, 30])
        requested.removeAll()
        let absent = await AnimeRelationRolePolicy.firstAdmittedSupplementalEntry(candidates: candidates, regularMappedIDs: [], existingEntries: [root], prefetched: [:]) { id in
            requested.append(id)
            return nil
        }
        XCTAssertNil(absent)
        XCTAssertEqual(requested, [20, 30, 40])
    }

    func testUpcomingRegularIdentityDoesNotNeedAnEpisodeCountButSideStoriesStayDetached() {
        XCTAssertTrue(AnimeRelationRolePolicy.retainsUpcomingIdentity(relationType: "SEQUEL", mediaFormat: "ONA", status: "NOT_YET_RELEASED"))
        XCTAssertTrue(AnimeRelationRolePolicy.retainsUpcomingIdentity(relationType: "SEASON", mediaFormat: "TV", status: "NOT_YET_RELEASED"))
        XCTAssertFalse(AnimeRelationRolePolicy.retainsUpcomingIdentity(relationType: "SIDE_STORY", mediaFormat: "ONA", status: "NOT_YET_RELEASED"))
        XCTAssertFalse(AnimeRelationRolePolicy.retainsUpcomingIdentity(relationType: "SEQUEL", mediaFormat: "MOVIE", status: "NOT_YET_RELEASED"))
    }

    func testDeclaredUpcomingSeasonSurvivesThePlayableBudgetWithoutKeepingUnrelatedOverflow() {
        let retained = AnimeStructurePolicy.budgetedIndices(episodeCounts: [11, 12, 6, 12, 24], rootIndex: 0, episodeBudget: 36, retainedIdentityIndices: [3])
        XCTAssertEqual(retained, [0, 1, 2, 3])
        XCTAssertEqual(AnimeStructurePolicy.budgetedIndices(episodeCounts: [11, 12, 6, 12], rootIndex: 0, episodeBudget: 36, retainedIdentityIndices: []), [0, 1, 2])
        XCTAssertEqual(AnimeStructurePolicy.budgetedIndices(episodeCounts: [40, 11, 12, 6, 12], rootIndex: 1, episodeBudget: 36, retainedIdentityIndices: [4]), [1, 2, 3, 4])
    }

    func testExplicitlyUpcomingStatusesHaveNoPlaybackRowsEvenWithDeclaredCoverage() {
        for status in ["NOT_YET_RELEASED", "not_yet_aired"] {
            let count = AnimeSeasonEpisodeHydrationPolicy.displayEpisodeCount(declaredCount: 12, remainingTMDBCount: 12, allowsOpenEndedRemainder: true, status: status)
            XCTAssertEqual(count, 0)
            XCTAssertTrue(AnimeSeasonEpisodeHydrationPolicy.episodes(count: count, displaySeasonNumber: 4, startingAt: 30, tmdbEpisodes: [30: episode(season: 4, number: 1, title: "Future Episode")], tmdbCoordinates: [:], allowsTMDBCoordinates: true).isEmpty)
        }
        XCTAssertEqual(AnimeSeasonEpisodeHydrationPolicy.displayEpisodeCount(declaredCount: 12, remainingTMDBCount: 12, allowsOpenEndedRemainder: false, status: "RELEASING"), 12)
        XCTAssertEqual(AnimeSeasonEpisodeHydrationPolicy.displayEpisodeCount(declaredCount: 12, remainingTMDBCount: 12, allowsOpenEndedRemainder: false, status: "currently_airing"), 12)
    }

    func testUnknownCountConsumesTMDBRemainderOnlyForAnAdmittedOpenEndedSeries() {
        XCTAssertEqual(AnimeSeasonEpisodeHydrationPolicy.displayEpisodeCount(declaredCount: nil, remainingTMDBCount: 12, allowsOpenEndedRemainder: false), 0)
        XCTAssertEqual(AnimeSeasonEpisodeHydrationPolicy.displayEpisodeCount(declaredCount: nil, remainingTMDBCount: 300, allowsOpenEndedRemainder: true), 300)
        XCTAssertEqual(AnimeSeasonEpisodeHydrationPolicy.displayEpisodeCount(declaredCount: 6, remainingTMDBCount: 18, allowsOpenEndedRemainder: false), 6)
    }

    func testBridonHydrationKeepsTitlesArtworkAndCoordinatesTogetherBeforeUnknownThirdSeason() throws {
        let segments: [AnimeStructureCoverageSegment] = [.init(mappedTMDBSeason: 1, episodeCount: 11), .init(mappedTMDBSeason: 2, episodeCount: 12), .init(mappedTMDBSeason: 3, episodeCount: 6), .init(mappedTMDBSeason: 4, episodeCount: nil)]
        let start = try XCTUnwrap(AnimeSeasonEpisodeHydrationPolicy.exactMappedSeasonStart(index: 2, segments: segments, tmdbSeasonEpisodeCounts: [1: 11, 2: 12, 3: 6, 4: 12]))
        XCTAssertEqual(start, 24)
        let metadata = episode(season: 3, number: 1, title: "So Time Begins to Flow Again")
        let episodes = AnimeSeasonEpisodeHydrationPolicy.episodes(count: 6, displaySeasonNumber: 3, startingAt: start, tmdbEpisodes: [24: metadata], tmdbCoordinates: [24: .init(seasonNumber: 3, episodeNumber: 1), 25: .init(seasonNumber: 3, episodeNumber: 2)], allowsTMDBCoordinates: true)
        XCTAssertEqual(episodes[0].title, metadata.name)
        XCTAssertEqual(episodes[0].stillPath, metadata.stillPath)
        XCTAssertEqual(episodes[0].description, metadata.overview)
        XCTAssertEqual(episodes[0].tmdbSeasonNumber, 3)
        XCTAssertEqual(episodes[0].tmdbEpisodeNumber, 1)
        XCTAssertEqual(episodes[1].title, "Episode 2")
        XCTAssertEqual(episodes[1].tmdbSeasonNumber, 3)
        XCTAssertEqual(episodes[1].tmdbEpisodeNumber, 2)
    }

    func testExactMappedSeasonHydrationDoesNotFollowAnUnrelatedDisplayIndex() throws {
        let segments: [AnimeStructureCoverageSegment] = [.init(mappedTMDBSeason: 2, episodeCount: 12), .init(mappedTMDBSeason: 1, episodeCount: 11)]
        let start = try XCTUnwrap(AnimeSeasonEpisodeHydrationPolicy.exactMappedSeasonStart(index: 0, segments: segments, tmdbSeasonEpisodeCounts: [1: 11, 2: 12]))
        XCTAssertEqual(start, 12)
        let episodes = AnimeSeasonEpisodeHydrationPolicy.episodes(count: 1, displaySeasonNumber: 1, startingAt: start, tmdbEpisodes: [12: episode(season: 2, number: 1, title: "Second Season")], tmdbCoordinates: [:], allowsTMDBCoordinates: true)
        XCTAssertEqual(episodes[0].seasonNumber, 1)
        XCTAssertEqual(episodes[0].tmdbSeasonNumber, 2)
    }

    func testUnverifiedHydrationDoesNotBorrowAnotherSeasonsMetadata() {
        let episodes = AnimeSeasonEpisodeHydrationPolicy.episodes(count: 1, displaySeasonNumber: 4, startingAt: 24, tmdbEpisodes: [24: episode(season: 3, number: 1, title: "Bridon Episode")], tmdbCoordinates: [24: .init(seasonNumber: 3, episodeNumber: 1)], allowsTMDBCoordinates: false)
        XCTAssertEqual(episodes[0].title, "Episode 1")
        XCTAssertNil(episodes[0].description)
        XCTAssertNil(episodes[0].stillPath)
        XCTAssertNil(episodes[0].airDate)
        XCTAssertNil(episodes[0].tmdbSeasonNumber)
        XCTAssertNil(episodes[0].tmdbEpisodeNumber)
    }

    func testAmbiguousSplitSeasonDoesNotAcquireStandaloneMappedCoordinates() {
        let split: [AnimeStructureCoverageSegment] = [.init(mappedTMDBSeason: 1, episodeCount: 12), .init(mappedTMDBSeason: 1, episodeCount: nil)]
        XCTAssertNil(AnimeSeasonEpisodeHydrationPolicy.exactMappedSeasonStart(index: 0, segments: split, tmdbSeasonEpisodeCounts: [1: 24]))
        XCTAssertNil(AnimeSeasonEpisodeHydrationPolicy.exactMappedSeasonStart(index: 1, segments: split, tmdbSeasonEpisodeCounts: [1: 24]))
    }

    private func candidate(_ id: Int, year: Int? = nil, month: Int? = nil, day: Int? = nil, seasonYear: Int? = nil, seasonOrdinal: Int = 4) -> AnimeStructureOrderingCandidate {
        .init(anilistId: id, mappedTMDBSeason: nil, episodeOffset: nil, startYear: year, startMonth: month, startDay: day, seasonYear: seasonYear, seasonOrdinal: seasonOrdinal)
    }

    private func supplementalEntry(_ id: Int, relationType: String? = nil) throws -> AniListAnime {
        var payload: [String: Any] = ["id": id, "title": ["romaji": "Supplement Fixture"], "format": "ONA", "episodes": 12]
        if let relationType {
            payload["relations"] = ["edges": [["relationType": relationType, "node": ["id": 10, "title": ["romaji": "Root Fixture"], "format": "ONA", "type": "ANIME"]]]]
        }
        return try JSONDecoder().decode(AniListAnime.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func chain(_ ids: [Int]) -> [AnimeStructureRelationConstraint] {
        zip(ids, ids.dropFirst()).map { pair in .init(beforeID: pair.0, afterID: pair.1) }
    }

    private func episode(season: Int, number: Int, title: String) -> TMDBEpisode {
        TMDBEpisode(id: season * 100 + number, name: title, overview: "Verified overview", stillPath: "/verified.jpg", episodeNumber: number, seasonNumber: season, airDate: "2024-12-27", runtime: 24, voteAverage: 8, voteCount: 10)
    }
}

final class SpecialEpisodeVisibilityRegressionTests: XCTestCase {
    func testHideUnairedEpisodesRejectsFutureMissingAndMalformedDates() {
        let episodes = [
            episode(number: 1, airDate: "2026-10-06"),
            episode(number: 2, airDate: "2026-10-07"),
            episode(number: 3, airDate: "2026-10-08"),
            episode(number: 4, airDate: nil),
            episode(number: 5, airDate: "2026-02-30"),
            episode(number: 6, airDate: "invalid")
        ]
        XCTAssertEqual(TVShowSeasonsSection<EmptyView>.visibleEpisodes(
            episodes,
            showUnairedEpisodes: false,
            today: "2026-10-07"
        ).map(\.episodeNumber), [1, 2])
        XCTAssertEqual(TVShowSeasonsSection<EmptyView>.visibleEpisodes(
            episodes,
            showUnairedEpisodes: true,
            today: "2026-10-07"
        ).map(\.episodeNumber), [1, 2, 3, 4, 5, 6])
    }

    func testHideUnairedEpisodesKeepsUpcomingAndEmptySeasonListsEmpty() {
        XCTAssertTrue(TVShowSeasonsSection<EmptyView>.visibleEpisodes(
            [],
            showUnairedEpisodes: false,
            today: "2026-10-07"
        ).isEmpty)
        XCTAssertTrue(TVShowSeasonsSection<EmptyView>.visibleEpisodes(
            [episode(number: 1, airDate: "2027-01-01")],
            showUnairedEpisodes: false,
            today: "2026-10-07"
        ).isEmpty)
    }

    func testEmptySpecialDoesNotInventAnEpisode() throws {
        let context = try XCTUnwrap(SpecialEpisodeListContext(entry: entry(count: 0), tmdbShowId: 123542))
        XCTAssertTrue(context.episodes.isEmpty)
        XCTAssertTrue(context.seasonDetail.episodes.isEmpty)
        XCTAssertEqual(context.title, "Upcoming Special")
    }

    func testUpcomingSpecialDoesNotExposeStaleHydratedEpisodeMetadata() throws {
        for status in ["NOT_YET_RELEASED", "not_yet_aired"] {
            let context = try XCTUnwrap(SpecialEpisodeListContext(
                entry: entry(count: 1, status: status, airDate: "2024-01-01"),
                tmdbShowId: 123542
            ))
            XCTAssertTrue(context.episodes.isEmpty)
            XCTAssertTrue(context.seasonDetail.episodes.isEmpty)
        }
    }

    func testAiredSpecialKeepsEpisodeMetadataAndPlaybackCoordinates() throws {
        let context = try XCTUnwrap(SpecialEpisodeListContext(
            entry: entry(count: 1, status: "FINISHED", airDate: "2024-01-01"),
            tmdbShowId: 123542
        ))
        let episode = try XCTUnwrap(context.episodes.first)
        XCTAssertEqual(context.episodes.count, 1)
        XCTAssertEqual(episode.airDate, "2024-01-01")
        XCTAssertEqual(episode.overview, "Episode overview")
        XCTAssertEqual(episode.stillPath, "/special.jpg")
        XCTAssertEqual(episode.runtime, 24)
        let playback = context.playbackContext(for: episode)
        XCTAssertEqual(playback.resolvedTMDBSeasonNumber, 0)
        XCTAssertEqual(playback.resolvedTMDBEpisodeNumber, 2)
    }

    func testInvalidSpecialEpisodeCountDoesNotInventAPlayableRow() throws {
        for count in [-1, Int.max] {
            let context = try XCTUnwrap(SpecialEpisodeListContext(entry: entry(count: count), tmdbShowId: 123542))
            XCTAssertTrue(context.episodes.isEmpty)
        }
    }

    private func entry(count: Int, status: String? = nil, airDate: String? = nil) -> AniListSpecialSearchEntry {
        AniListSpecialSearchEntry(
            id: 555,
            canonicalAniListId: 555,
            malId: nil,
            kitsuId: nil,
            title: "Upcoming Special",
            englishTitle: nil,
            romajiTitle: nil,
            nativeTitle: nil,
            format: "SPECIAL",
            episodeCount: count,
            posterUrl: nil,
            tmdbSeasonNumber: 0,
            tvdbSeasonNumber: nil,
            episodeOffset: nil,
            imdbId: nil,
            releaseDate: nil,
            status: status,
            episodes: airDate.map { date in
                [AniListEpisode(
                    number: 1,
                    title: "Source Episode",
                    description: "Episode overview",
                    seasonNumber: 0,
                    stillPath: "/special.jpg",
                    airDate: date,
                    runtime: 24,
                    tmdbSeasonNumber: 0,
                    tmdbEpisodeNumber: 2
                )]
            } ?? []
        )
    }

    private func episode(number: Int, airDate: String?) -> TMDBEpisode {
        TMDBEpisode(
            id: number,
            name: "Episode \(number)",
            overview: nil,
            stillPath: nil,
            episodeNumber: number,
            seasonNumber: 3,
            airDate: airDate,
            runtime: nil,
            voteAverage: 0,
            voteCount: 0
        )
    }
}

final class AnimeEpisodeMetadataRegressionTests: XCTestCase {
#if DEBUG
    func testLiveNativeMALTransportProbe() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_LIVE_MAL_TRANSPORT"] == "1" else {
            throw XCTSkip("Set ECLIPSE_LIVE_MAL_TRANSPORT=1 for the native transport diagnostic.")
        }
        let clientID = (Bundle.main.object(forInfoDictionaryKey: "MALClientID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientID.contains("$(") else {
            XCTFail("The native transport diagnostic requires a configured MAL client ID.")
            return
        }
        let fields = ["id", "title", "main_picture", "alternative_titles", "start_date", "end_date",
            "synopsis", "mean", "rank", "popularity", "num_list_users", "media_type",
            "status", "genres", "num_episodes", "start_season", "broadcast", "source",
            "average_episode_duration", "rating", "related_anime"].joined(separator: ",")
        var receipts: [[String: Any]] = []
        for id in [9181, 56538] {
            for mode in ["default-bytes", "fetch-delegate"] {
                let start = ProcessInfo.processInfo.systemUptime
                let state = MALTransportProbeState(startedAt: start)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let delegate = mode == "fetch-delegate" ? MALTransportProbeDelegate(state: state) : nil
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                var receipt: [String: Any] = ["id": id, "mode": mode, "latencyBenchmarkEligible": false]
                do {
                    let base = try XCTUnwrap(URL(string: "https://api.myanimelist.net/v2/anime/\(id)"))
                    var components = try XCTUnwrap(URLComponents(url: base, resolvingAgainstBaseURL: false))
                    components.queryItems = [URLQueryItem(name: "fields", value: fields)]
                    var request = URLRequest(url: try XCTUnwrap(components.url), timeoutInterval: 8)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.setValue(clientID, forHTTPHeaderField: "X-MAL-CLIENT-ID")
                    let payload = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                        group.addTask {
                            if let delegate {
                                return try await delegate.fetchDelegate.boundedData(in: session, for: request,
                                    maximumResponseBytes: 2 * 1024 * 1024, allowRedirects: true)
                            }
                            let (bytes, response) = try await session.bytes(for: request)
                            state.recordResponse(response)
                            var buffer = try BoundedResponseBuffer(maximumBytes: 2 * 1024 * 1024,
                                expectedContentLength: response.expectedContentLength)
                            do {
                                for try await byte in bytes {
                                    try Task.checkCancellation()
                                    try buffer.append(byte)
                                }
                            } catch {
                                state.setBodyBytes(buffer.data.count)
                                bytes.task.cancel()
                                throw error
                            }
                            state.setBodyBytes(buffer.data.count)
                            return (buffer.data, response)
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 8_000_000_000)
                            state.recordWallTimeout()
                            session.invalidateAndCancel()
                            throw URLError(.timedOut)
                        }
                        defer { group.cancelAll() }
                        guard let first = try await group.next() else { throw URLError(.unknown) }
                        return first
                    }
                    let status = (payload.1 as? HTTPURLResponse)?.statusCode ?? -1
                    receipt["status"] = status
                    receipt["bodyBytes"] = payload.0.count
                    XCTAssertEqual(status, 200, "MAL transport \(id) \(mode)")
                    let object = try JSONSerialization.jsonObject(with: payload.0) as? [String: Any]
                    let returnedID = object?["id"] as? Int
                    receipt["returnedID"] = returnedID
                    XCTAssertEqual(returnedID, id, "MAL transport \(id) \(mode)")
                } catch {
                    let failure = error as NSError
                    receipt["errorDomain"] = failure.domain
                    receipt["errorCode"] = failure.code
                    XCTFail("MAL transport \(id) \(mode) failed with \(failure.domain) code \(failure.code).")
                }
                receipt.merge(state.snapshot(), uniquingKeysWith: { current, _ in current })
                receipt["durationSeconds"] = ProcessInfo.processInfo.systemUptime - start
                receipts.append(receipt)
                printLiveAuditReceipt(receipt, prefix: "MALTransportProbeAudit")
            }
        }
        attachLiveAudit(receipts, name: "Native MAL transport diagnostic")
    }

    private final class MALTransportProbeState: @unchecked Sendable {
        private let lock = NSLock()
        private let startedAt: Double
        private var status: Int?
        private var firstResponseSeconds: Double?
        private var bodyBytes = 0
        private var wallTimeout = false

        init(startedAt: Double) { self.startedAt = startedAt }

        func recordResponse(_ response: URLResponse) {
            lock.lock()
            status = (response as? HTTPURLResponse)?.statusCode
            if firstResponseSeconds == nil { firstResponseSeconds = ProcessInfo.processInfo.systemUptime - startedAt }
            lock.unlock()
        }

        func setBodyBytes(_ count: Int) {
            lock.lock()
            bodyBytes = count
            lock.unlock()
        }

        func appendBodyBytes(_ count: Int) {
            lock.lock()
            bodyBytes = min(2 * 1024 * 1024 + 1, bodyBytes + min(count, 2 * 1024 * 1024 + 1))
            lock.unlock()
        }

        func recordWallTimeout() {
            lock.lock()
            wallTimeout = true
            lock.unlock()
        }

        func snapshot() -> [String: Any] {
            lock.lock()
            defer { lock.unlock() }
            return ["status": status.map { $0 as Any } ?? NSNull(),
                "firstResponseSeconds": firstResponseSeconds.map { $0 as Any } ?? NSNull(),
                "bodyBytes": bodyBytes, "wallTimeout": wallTimeout]
        }
    }

    private final class MALTransportProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let fetchDelegate = FetchDelegate(allowRedirects: true)
        private let state: MALTransportProbeState

        init(state: MALTransportProbeState) { self.state = state }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            state.recordResponse(response)
            fetchDelegate.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            state.appendBodyBytes(data.count)
            fetchDelegate.urlSession(session, dataTask: dataTask, didReceive: data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            fetchDelegate.urlSession(session, task: task, didCompleteWithError: error)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            fetchDelegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: request, completionHandler: completionHandler)
        }
    }

    func testUnmappedRemakeRelationsRespectTargetInventoryWithoutDiscardingUpcomingOrOlderCours() {
        for count in [291, 69, 131] {
            XCTAssertFalse(AnimeRelationRolePolicy.fitsRegularTMDBInventory(
                isMappedRegular: false, episodeCount: count, status: "FINISHED", tmdbEpisodeCount: 19
            ))
        }
        XCTAssertTrue(AnimeRelationRolePolicy.fitsRegularTMDBInventory(
            isMappedRegular: false, episodeCount: nil, tmdbEpisodeCount: 19
        ))
        XCTAssertTrue(AnimeRelationRolePolicy.fitsRegularTMDBInventory(
            isMappedRegular: true, episodeCount: 131, tmdbEpisodeCount: 19
        ))
        XCTAssertTrue(AnimeRelationRolePolicy.fitsRegularTMDBInventory(
            isMappedRegular: false, episodeCount: 12, tmdbEpisodeCount: 19
        ))
        for status in ["NOT_YET_RELEASED", "not_yet_aired", "RELEASING", "currently_airing"] {
            XCTAssertTrue(AnimeRelationRolePolicy.fitsRegularTMDBInventory(
                isMappedRegular: false, episodeCount: 24, status: status, tmdbEpisodeCount: 12
            ), status)
            XCTAssertTrue(AnimeRelationRolePolicy.fitsRegularTMDBInventory(
                isMappedRegular: false, episodeCount: nil, status: status, tmdbEpisodeCount: 12
            ), status)
        }
    }

    func testMALGraphBoundsAdmitLongSameShowRostersAndRemainFinite() {
        XCTAssertEqual(AnimeMALFallbackRelationPolicy.regularGraphEntryLimit(
            tmdbSeasonEpisodeCounts: [1: 19], mappedRegularEntryCount: 0), 12)
        let seasons = Dictionary(uniqueKeysWithValues: (1...21).map { ($0, 51) })
        XCTAssertEqual(AnimeMALFallbackRelationPolicy.regularGraphEntryLimit(
            tmdbSeasonEpisodeCounts: seasons, mappedRegularEntryCount: 12), 34)
        XCTAssertEqual(AnimeMALFallbackRelationPolicy.regularGraphEntryLimit(
            tmdbSeasonEpisodeCounts: seasons, mappedRegularEntryCount: Int.max), 64)
        for counts in [nil, [:], [0: 12], [1: -1], [Int.max: 1]] as [[Int: Int]?] {
            XCTAssertEqual(AnimeMALFallbackRelationPolicy.regularGraphEntryLimit(
                tmdbSeasonEpisodeCounts: counts, mappedRegularEntryCount: 12), 12)
        }
    }

    func testVerifiedEpisodeZeroIsProviderSpecificAndRejectsSourceDrift() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let premiere = try XCTUnwrap(formatter.date(from: "2011-01-12"))
        let regular = (1...12).map { number in
            TMDBEpisode(id: 1344630 + number, name: "Regular \(number)", overview: "Overview",
                stillPath: "/still.jpg", episodeNumber: number, seasonNumber: 2,
                airDate: formatter.string(from: premiere.addingTimeInterval(Double(number - 1) * 604_800)),
                runtime: 23, voteAverage: 0, voteCount: 0)
        }
        let prologue = TMDBEpisode(id: 1699406, name: "片想い", overview: "Recap overview",
            stillPath: "/recap.jpg", episodeNumber: 1, seasonNumber: 0,
            airDate: "2011-01-05", runtime: 23, voteAverage: 0, voteCount: 0)
        func resolve(showID: Int = 68854, aniListID: Int? = 9656, malID: Int? = 9656,
                     count: Int = 13, format: String? = "TV", status: String = "FINISHED", start: String = "2011-01-12",
                     end: String = "2011-03-30", source: [TMDBEpisode]? = nil,
                     specials: [TMDBEpisode]? = nil) -> TMDBEpisode? {
            AnimeVerifiedEpisodeZeroMappingPolicy.prologueEpisode(
                tmdbShowId: showID, aniListID: aniListID, malID: malID, episodeCount: count, format: format,
                status: status, startDate: start, endDate: end,
                regularEpisodes: source ?? regular, specialEpisodes: specials ?? [prologue])
        }
        let mapped = try XCTUnwrap(resolve())
        XCTAssertEqual(mapped.id, prologue.id)
        XCTAssertEqual(mapped.overview, prologue.overview)
        XCTAssertEqual(mapped.stillPath, prologue.stillPath)
        XCTAssertEqual(mapped.airDate, prologue.airDate)
        XCTAssertEqual(mapped.runtime, prologue.runtime)
        XCTAssertEqual(AnimeVerifiedEpisodeZeroMappingPolicy.provenanceURLs.count, 2)
        XCTAssertNil(resolve(showID: 68855))
        XCTAssertNil(resolve(aniListID: nil))
        XCTAssertNil(resolve(aniListID: 9657))
        XCTAssertNil(resolve(malID: 10152))
        XCTAssertNil(resolve(count: 12))
        XCTAssertNil(resolve(format: nil))
        XCTAssertNil(resolve(format: "SPECIAL"))
        XCTAssertNil(resolve(status: "RELEASING"))
        XCTAssertNil(resolve(start: "2011-01-05"))
        XCTAssertNil(resolve(end: "2011-04-06"))
        XCTAssertNil(resolve(source: Array(regular.dropLast())))
        XCTAssertNil(resolve(source: regular + [regular[0]]))
        XCTAssertNil(resolve(specials: []))
        XCTAssertNil(resolve(specials: [prologue, prologue]))
        let foreign = TMDBEpisode(id: 1, name: "Unrelated", overview: nil, stillPath: nil,
            episodeNumber: 1, seasonNumber: 0, airDate: "2011-01-05", runtime: nil,
            voteAverage: 0, voteCount: 0)
        XCTAssertNil(resolve(specials: [foreign]))
        let duplicateCoordinate = TMDBEpisode(id: 999, name: "Unrelated", overview: nil, stillPath: nil,
            episodeNumber: 1, seasonNumber: 2, airDate: "2011-01-12", runtime: nil,
            voteAverage: 0, voteCount: 0)
        XCTAssertNil(resolve(source: regular + [duplicateCoordinate]))
        let replacementFirst = TMDBEpisode(id: 999, name: "Unrelated", overview: nil, stillPath: nil,
            episodeNumber: 1, seasonNumber: 2, airDate: "2011-01-12", runtime: nil,
            voteAverage: 0, voteCount: 0)
        XCTAssertNil(resolve(source: [replacementFirst] + Array(regular.dropFirst())))
    }

    @MainActor
    func testLiveVerifiedEpisodeUnitsUncached() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_LIVE_ANIME_UNITS"] == "1" else {
            throw XCTSkip("Set ECLIPSE_LIVE_ANIME_UNITS=1 for current compiled and feature metadata.")
        }
        let fixtures: [(Int, String, Int, Int)] = [
            (67676, "The Disastrous Life of Saiki K.", 21804, 33255),
            (93816, "GREAT PRETENDER razbliuto", 170935, 57184)
        ]
        for (id, title, aniListID, malID) in fixtures {
            for forceMAL in [false, true] {
                for hydration in [AnimeEpisodeHydrationPolicy.initiallyVisible, .complete] {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    let ledger = AnimeMetadataRequestLedger()
                    let start = ProcessInfo.processInfo.systemUptime
                    _ = try await AnimeMetadataLoadingValidation.$requestLedger.withValue(ledger) {
                            try await AniListService.shared.validateUncachedAnimeLoading(
                                title: title, tmdbShowId: id,
                                seedAniListId: forceMAL ? -malID : aniListID,
                                seedMALId: malID, hydrationPolicy: hydration,
                                verification: { details in
                                    let seconds = ProcessInfo.processInfo.systemUptime - start
                                    let requests = await ledger.snapshot()
                                    let events = await ledger.eventSnapshot()
                                    let droppedEvents = await ledger.droppedEventCount()
                                    let season = try XCTUnwrap(details.seasons.first {
                                        $0.canonicalAniListId == aniListID || $0.malId == malID
                                    })
                                    let count = id == 67676 ? 24 : (forceMAL ? 4 : 1)
                                    XCTAssertEqual(season.episodes.count, count)
                                    guard season.episodes.count == count else { return }
                                    if forceMAL {
                                        XCTAssertGreaterThan(requests["MAL", default: 0], 0)
                                        XCTAssertEqual(requests["AniList", default: 0], 0)
                                        XCTAssertLessThan(season.anilistId, 0)
                                    } else {
                                        XCTAssertGreaterThan(requests["AniList", default: 0], 0)
                                        XCTAssertGreaterThan(season.anilistId, 0)
                                    }
                                    let independentGroups = [
                                        [1, 5], [6, 10], [11, 15], [16, 20], [21, 25], [26, 30],
                                        [31, 35], [36, 40], [41, 45], [46, 50], [51, 55], [56, 60],
                                        [61, 65], [66, 70], [71, 75], [76, 80], [81, 85], [86, 90],
                                        [91, 95], [96, 100], [101, 105], [106, 110], [111, 115], [116, 120]
                                    ]
                                    for (index, episode) in season.episodes.enumerated() {
                                        let projection = try XCTUnwrap(episode.unitProjection)
                                        let expectedAL = id == 67676 ? independentGroups[index] : [1, 1]
                                        let expectedMAL = id == 67676 ? independentGroups[index]
                                            : (forceMAL ? [[1, 1], [2, 2], [3, 3], [4, 4]][index] : [1, 4])
                                        XCTAssertEqual(projection.edition, id == 67676 ? .compilation : (forceMAL ? .featurePart : .feature))
                                        XCTAssertEqual(projection.canonicalAniListEpisodeRange, .init(lowerBound: expectedAL[0], upperBound: expectedAL[1]))
                                        XCTAssertEqual(projection.canonicalMALEpisodeRange, .init(lowerBound: expectedMAL[0], upperBound: expectedMAL[1]))
                                        XCTAssertEqual(projection.physicalPartOrdinal, id == 93816 && forceMAL ? index + 1 : nil)
                                        XCTAssertEqual(projection.physicalPartCount, id == 93816 && forceMAL ? 4 : nil)
                                        let context = EpisodePlaybackContext(localSeasonNumber: season.seasonNumber, localEpisodeNumber: episode.number,
                                            anilistMediaId: season.anilistId, canonicalAniListMediaId: season.canonicalAniListId, malMediaId: season.malId,
                                            tmdbSeasonNumber: episode.tmdbSeasonNumber, tmdbEpisodeNumber: episode.tmdbEpisodeNumber, tmdbEpisodeOffset: nil,
                                            animeAbsoluteEpisodeNumber: nil, animeSeasonEpisodeCount: count, isSpecial: false, titleOnlySearch: false,
                                            unitProjection: projection)
                                        XCTAssertTrue(context.hasTrustedUnitProjection(showID: id))
                                    }
                                    XCTAssertEqual(season.canonicalAniListEpisodeCount, id == 67676 ? 120 : 1)
                                    XCTAssertEqual(season.canonicalMALEpisodeCount, id == 67676 ? 120 : 4)
                                    if id == 93816 && !forceMAL {
                                        let movie = try await self.fetchIndependentLiveMovie(id: 1220441)
                                        let episode = try XCTUnwrap(season.episodes.first)
                                        XCTAssertEqual(episode.title, movie.title)
                                        XCTAssertEqual(episode.description, movie.overview)
                                        XCTAssertEqual(episode.stillPath, movie.backdropPath)
                                        XCTAssertEqual(episode.airDate, movie.releaseDate)
                                        XCTAssertEqual(episode.runtime, movie.runtime)
                                        XCTAssertEqual(episode.unitProjection?.tmdbMovieID, movie.id)
                                        XCTAssertNil(episode.tmdbSeasonNumber)
                                        XCTAssertNil(episode.tmdbEpisodeNumber)
                                    } else {
                                        let sourceInventory = try await self.fetchIndependentLiveAnimeInventory(tmdbID: id, context: title)
                                        let sourceEpisodes = sourceInventory.1.filter { $0.seasonNumber == (id == 67676 ? 1 : 2) }
                                        XCTAssertEqual(Set(season.episodes.compactMap(\.tmdbEpisodeNumber)).count, count)
                                        for episode in season.episodes {
                                            let source = try XCTUnwrap(sourceEpisodes.first { $0.episodeNumber == episode.tmdbEpisodeNumber })
                                            XCTAssertEqual(episode.title, source.name)
                                            XCTAssertEqual(episode.description, source.overview)
                                            XCTAssertEqual(episode.stillPath, source.stillPath)
                                            XCTAssertEqual(episode.airDate, source.airDate)
                                            XCTAssertEqual(episode.runtime, source.runtime)
                                        }
                                    }
                                    let receipt: [String: Any] = ["title": title, "tmdbID": id, "forceMAL": forceMAL,
                                        "hydration": String(describing: hydration), "seconds": seconds,
                                        "episodes": count, "requests": requests, "droppedEvents": droppedEvents,
                                        "events": try JSONSerialization.jsonObject(with: JSONEncoder().encode(events))]
                                    self.printLiveAuditReceipt(receipt, prefix: "AnimeUnitUncachedAudit")
                                }
                            )
                    }
                }
            }
        }
    }

    @MainActor
    func testLiveBeerusUncachedIdentityAndEpisodeMetadata() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_LIVE_BEERUS_TEST"] == "1" else {
            throw XCTSkip("Set ECLIPSE_LIVE_BEERUS_TEST=1 for current Beerus metadata.")
        }
        try await Task.sleep(nanoseconds: 10_000_000_000)
        var receipts: [[String: Any]] = []
        for (label, seed, mal) in [("unseeded", nil, nil), ("AniList seed", 206814, nil), ("MAL seed", -63367, 63367)] as [(String, Int?, Int?)] {
            for hydration in [AnimeEpisodeHydrationPolicy.initiallyVisible, .complete] {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                let ledger = AnimeMetadataRequestLedger()
                let start = ProcessInfo.processInfo.systemUptime
                _ = try await AnimeMetadataLoadingValidation.$requestLedger.withValue(ledger) {
                    try await AniListService.shared.validateUncachedAnimeLoading(
                        title: "Dragon Ball Super: Beerus", tmdbShowId: 312359,
                        seedAniListId: seed, seedMALId: mal, hydrationPolicy: hydration,
                        verification: { details in
                            let seconds = ProcessInfo.processInfo.systemUptime - start
                            let requests = await ledger.snapshot()
                            let requestSeconds = await ledger.timingSnapshot()
                            let requestEvents = await ledger.eventSnapshot()
                            let droppedEvents = await ledger.droppedEventCount()
                            XCTAssertGreaterThan(requests["AniMap", default: 0], 0)
                            XCTAssertGreaterThanOrEqual(requests["TMDB", default: 0], 2)
                            XCTAssertEqual(details.seasons.count, 1, label)
                            if seed == -63367 {
                                XCTAssertEqual(details.seasons.compactMap(\.malId), [63367], label)
                            } else {
                                XCTAssertEqual(details.seasons.compactMap(\.canonicalAniListId), [206814], label)
                            }
                            var receipt = try await self.verifyLiveAnimeMetadata(details, tmdbID: 312359,
                                context: "Beerus \(label) \(hydration)", hydration: hydration,
                                requiresFullRegularInventory: true)
                            let first = try XCTUnwrap(details.seasons.first?.episodes.first)
                            XCTAssertEqual(first.title, "The God Who Destroys")
                            XCTAssertEqual(first.airDate, "2026-10-11")
                            XCTAssertEqual(first.runtime, 24)
                            XCTAssertFalse(first.description?.isEmpty ?? true)
                            XCTAssertNotNil(first.stillPath)
                            receipt["seconds"] = seconds
                            receipt["requests"] = requests
                            receipt["requestSeconds"] = requestSeconds
                            receipt["events"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(requestEvents))
                            receipt["droppedEvents"] = droppedEvents
                            receipt["route"] = label
                            receipts.append(receipt)
                            self.printLiveAuditReceipt(receipt, prefix: "BeerusUncachedAudit")
                        }
                    )
                }
            }
        }
        attachLiveAudit(receipts, name: "Beerus uncached identity and metadata")
    }

    @MainActor
    func testLiveAnimeLargeUncachedCohort() async throws {
        guard let path = ProcessInfo.processInfo.environment["ECLIPSE_LIVE_ANIME_COHORT"],
              !path.isEmpty else {
            throw XCTSkip("Supply ECLIPSE_LIVE_ANIME_COHORT with a verified live cohort JSON path.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fixtures = try XCTUnwrap((envelope["main"] ?? envelope["candidates"]) as? [[String: Any]])
        let ids = fixtures.compactMap { $0["tmdbID"] as? Int }
        XCTAssertGreaterThanOrEqual(fixtures.count, 200)
        XCTAssertEqual(ids.count, fixtures.count)
        XCTAssertEqual(Set(ids).count, fixtures.count)
        let focusIDs = Set((ProcessInfo.processInfo.environment["ECLIPSE_LIVE_ANIME_FOCUS_IDS"] ?? "")
            .split(separator: ",").compactMap { Int($0) })
        let auditedFixtures = focusIDs.isEmpty ? fixtures : fixtures.filter { fixture in
            (fixture["tmdbID"] as? Int).map(focusIDs.contains) ?? false
        }
        if !focusIDs.isEmpty { XCTAssertEqual(auditedFixtures.count, focusIDs.count) }
        var correctionsByID: [Int: [String: Any]] = [:]
        if let correctionPath = ProcessInfo.processInfo.environment["ECLIPSE_LIVE_ANIME_ORACLE_CORRECTIONS"] {
            let correctionData = try Data(contentsOf: URL(fileURLWithPath: correctionPath))
            let corrections = try XCTUnwrap(JSONSerialization.jsonObject(with: correctionData) as? [[String: Any]])
            for correction in corrections {
                let id = try XCTUnwrap(correction["tmdbID"] as? Int)
                XCTAssertNil(correctionsByID[id])
                correctionsByID[id] = correction
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000_000)
        var receipts: [[String: Any]] = []
        var completedIDs = Set<Int>()
        let run = try XCTUnwrap(testRun)
        for fixture in auditedFixtures {
            let id = try XCTUnwrap(fixture["tmdbID"] as? Int)
            let title = try XCTUnwrap(fixture["title"] as? String)
            let independentPolicy = correctionsByID[id] ?? [:]
            let expectedID = try XCTUnwrap((independentPolicy["acceptedSelectedAniListID"] ?? fixture["anilistID"]) as? Int)
            for hydration in [AnimeEpisodeHydrationPolicy.initiallyVisible, .complete] {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                let ledger = AnimeMetadataRequestLedger()
                let failuresBefore = run.failureCount
                let start = ProcessInfo.processInfo.systemUptime
                var measuredSeconds: Double?
                do {
                    _ = try await AnimeMetadataLoadingValidation.$requestLedger.withValue(ledger) {
                        try await AniListService.shared.validateUncachedAnimeLoading(
                            title: title, tmdbShowId: id, hydrationPolicy: hydration,
                            verification: { details in
                                measuredSeconds = ProcessInfo.processInfo.systemUptime - start
                                let seconds = measuredSeconds ?? 0
                                let requests = await ledger.snapshot()
                                let requestSeconds = await ledger.timingSnapshot()
                            let requestEvents = await ledger.eventSnapshot()
                            let droppedEvents = await ledger.droppedEventCount()
                                XCTAssertGreaterThan(requests["AniMap", default: 0], 0, title)
                                XCTAssertGreaterThan(requests["TMDB", default: 0], 0, title)
                                XCTAssertGreaterThan(requests["AniList", default: 0], 0, "\(title) must exercise the primary provider")
                                XCTAssertTrue(details.seasons.allSatisfy { $0.anilistId > 0 }, "\(title) silently used the MAL fallback")
                                XCTAssertTrue(details.seasons.contains { $0.canonicalAniListId == expectedID },
                                    "\(title) lost independently verified season identity \(expectedID)")
                                var allowedIDs = Set((fixture["ordinaryMappedAnime"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int })
                                allowedIDs.insert(expectedID)
                                for edge in fixture["relationEvidence"] as? [[String: Any]] ?? [] {
                                    guard ["SEQUEL", "PREQUEL", "SEASON"].contains(edge["relationType"] as? String ?? ""),
                                          let node = edge["node"] as? [String: Any],
                                          ["TV", "TV_SHORT", "ONA"].contains(node["format"] as? String ?? ""),
                                          let nodeID = node["id"] as? Int else { continue }
                                    let mappedShows = edge["mappedTMDBShowIDs"] as? [Int] ?? []
                                    if mappedShows.isEmpty || mappedShows.contains(id) { allowedIDs.insert(nodeID) }
                                }
                                if let authoritativeIDs = independentPolicy["allowedCanonicalIDs"] as? [Int] {
                                    allowedIDs = Set(authoritativeIDs)
                                }
                                let actualIDs = details.seasons.compactMap(\.canonicalAniListId)
                                XCTAssertEqual(actualIDs.count, details.seasons.count, "\(title) changed metadata provider unexpectedly")
                                XCTAssertEqual(Set(actualIDs).count, actualIDs.count, "\(title) duplicated a canonical season")
                                XCTAssertTrue(Set(actualIDs).isSubset(of: allowedIDs), "\(title) inserted an independently unverified or foreign identity \(Set(actualIDs).subtracting(allowedIDs))")
                                for forbidden in independentPolicy["forbiddenCanonicalIDs"] as? [Int] ?? [] {
                                    XCTAssertFalse(actualIDs.contains(forbidden), "\(title) inserted foreign identity \(forbidden)")
                                }
                                for required in independentPolicy["requiredCanonicalIDs"] as? [Int] ?? [] {
                                    XCTAssertTrue(actualIDs.contains(required), "\(title) discarded independently verified identity \(required)")
                                }
                                if let expected = fixture["expectedRegularAniListIDs"] as? [Int] {
                                    XCTAssertEqual(details.seasons.compactMap(\.canonicalAniListId), expected, title)
                                }
                                let nodes = fixture["ordinaryMappedAnime"] as? [[String: Any]] ?? []
                                let independentRaw = fixture["liveTMDB"] as? [String: Any] ?? [:]
                                let independentSummaries = independentRaw["seasons"] as? [[String: Any]] ?? []
                                let independentTotal = independentSummaries.filter { ($0["season_number"] as? Int ?? 0) > 0 }
                                    .reduce(0) { $0 + ($1["episode_count"] as? Int ?? 0) }
                                let knownCounts = nodes.compactMap { node -> Int? in
                                    if node["status"] as? String == "NOT_YET_RELEASED" { return 0 }
                                    return node["episodes"] as? Int
                                }
                                let consistentRosterCounts = knownCounts.count == nodes.count
                                    && knownCounts.reduce(0, +) == independentTotal
                                if consistentRosterCounts,
                                   fixture["exactRosterConfidence"] as? String == "unambiguous_ordinary_mapped_identity_roster",
                                   let expected = fixture["independentlyExpectedCanonicalIDs"] as? [Int] {
                                    XCTAssertTrue(Set(expected).isSubset(of: Set(details.seasons.compactMap(\.canonicalAniListId))),
                                        "\(title) discarded independently verified mapped identities")
                                    for node in fixture["ordinaryMappedAnime"] as? [[String: Any]] ?? [] {
                                        guard let identity = node["id"] as? Int,
                                              let season = details.seasons.first(where: { $0.canonicalAniListId == identity }) else { continue }
                                        if node["status"] as? String == "NOT_YET_RELEASED" {
                                            XCTAssertTrue(season.episodes.isEmpty, "\(title) invented upcoming episodes")
                                        } else if node["status"] as? String == "FINISHED", let count = node["episodes"] as? Int, count > 0 {
                                            XCTAssertEqual(season.episodes.count, count, "\(title) lost declared finished coverage")
                                        }
                                    }
                                }
                                var receipt = try await self.verifyLiveAnimeMetadata(details, tmdbID: id,
                                    context: "\(title) \(hydration)", hydration: hydration,
                                    requiresFullRegularInventory: true,
                                    expectsActiveMetadata: fixture["status"] as? String != "NOT_YET_RELEASED",
                                    independentPolicy: independentPolicy)
                                receipt["seconds"] = seconds
                                receipt["requests"] = requests
                                receipt["requestSeconds"] = requestSeconds
                            receipt["events"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(requestEvents))
                            receipt["droppedEvents"] = droppedEvents
                                receipt["independentRosterCountsConsistent"] = consistentRosterCounts
                                receipt["expectedAniListID"] = expectedID
                                receipt["actualRootID"] = details.id
                                receipt["rawProviderSeasonIDs"] = details.seasons.map(\.anilistId)
                                receipt["fixture"] = fixture
                                receipt["independentOracleCorrection"] = independentPolicy
                                receipt["auditScope"] = focusIDs.isEmpty ? "Full frozen cohort" : "Focused diagnostic subset"
                                receipt["assertionFailures"] = run.failureCount - failuresBefore
                                receipt["verificationPassed"] = run.failureCount == failuresBefore
                                receipts.append(receipt)
                                self.printLiveAuditReceipt(receipt, prefix: "AnimeLargeUncachedAudit")
                                if hydration == .complete, run.failureCount == failuresBefore { completedIDs.insert(id) }
                            }
                        )
                    }
                } catch {
                    let seconds = measuredSeconds ?? (ProcessInfo.processInfo.systemUptime - start)
                    let error = error as NSError
                    XCTFail("\(title) \(hydration): \(error.domain) \(error.code)")
                    let receipt: [String: Any] = ["tmdbID": id, "title": title,
                        "hydration": hydration.rawValue, "seconds": seconds,
                        "requests": await ledger.snapshot(), "errorDomain": error.domain,
                        "requestSeconds": await ledger.timingSnapshot(),
                        "events": try JSONSerialization.jsonObject(with: JSONEncoder().encode(await ledger.eventSnapshot())),
                        "verificationPassed": false, "assertionFailures": run.failureCount - failuresBefore,
                        "errorCode": error.code, "fixture": fixture]
                    receipts.append(receipt)
                    self.printLiveAuditReceipt(receipt, prefix: "AnimeLargeUncachedAudit")
                }
            }
        }
        attachLiveAudit(receipts, name: focusIDs.isEmpty ? "At least 200 distinct anime uncached audit" : "Focused anime diagnostic")
        XCTAssertEqual(receipts.count, auditedFixtures.count * 2)
        XCTAssertGreaterThanOrEqual(completedIDs.count, focusIDs.isEmpty ? 200 : auditedFixtures.count)
    }

    @MainActor
    private func verifyLiveAnimeMetadata(
        _ details: AniListAnimeWithSeasons,
        tmdbID: Int,
        context: String,
        hydration: AnimeEpisodeHydrationPolicy,
        requiresFullRegularInventory: Bool,
        expectsActiveMetadata: Bool = true,
        independentPolicy: [String: Any] = [:]
    ) async throws -> [String: Any] {
        let prologues = independentPolicy["prologues"] as? [[String: Any]] ?? []
        let inventory = try await fetchIndependentLiveAnimeInventory(tmdbID: tmdbID, context: context, includesSpecials: !prologues.isEmpty)
        let raw = inventory.0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let today = formatter.string(from: Date())
        var coordinates: [String] = []
        var sources: [String: TMDBEpisode] = [:]
        for episode in inventory.1 {
            let key = "\(episode.seasonNumber):\(episode.episodeNumber)"
            XCTAssertNil(sources[key], "\(context) duplicate source coordinate")
            sources[key] = episode
            if episode.seasonNumber > 0 { coordinates.append(key) }
        }
        for prologue in prologues {
            let key = try XCTUnwrap(prologue["coordinate"] as? String)
            let before = try XCTUnwrap(prologue["before"] as? String)
            let source = try XCTUnwrap(sources[key], context)
            XCTAssertEqual(source.name, prologue["title"] as? String, context)
            XCTAssertEqual(source.airDate, prologue["airDate"] as? String, context)
            let index = try XCTUnwrap(coordinates.firstIndex(of: before), context)
            coordinates.insert(key, at: index)
        }
        let excluded = Set(independentPolicy["regularExcludedCoordinates"] as? [String] ?? [])
        XCTAssertTrue(excluded.isSubset(of: Set(coordinates)), context)
        let expectedUnresolved = independentPolicy["expectedUnresolvedEpisodeCounts"] as? [String: Int] ?? [:]
        let unresolvedStarts = (independentPolicy["unresolvedStartsByIdentity"] ?? independentPolicy["unresolvedStartsByAniListID"]) as? [String: Int] ?? [:]
        func isAired(_ episode: TMDBEpisode) -> Bool {
            guard let rawDate = episode.airDate, rawDate.count >= 10 else { return false }
            let value = String(rawDate.prefix(10))
            guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return false }
            return value <= today
        }
        let sourceIndices = Dictionary(coordinates.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var previousIndex = -1
        var compared = 0
        var unresolved = 0
        var unresolvedByIdentity: [String: Int] = [:]
        var upstreamGaps = ["overview": 0, "still": 0, "date": 0, "runtime": 0]
        for season in details.seasons {
            XCTAssertEqual(season.episodes.map(\.number), Array(1..<(season.episodes.count + 1)), context)
            for episode in season.episodes {
                if let projection = episode.unitProjection, projection.edition == .feature {
                    XCTAssertEqual(projection.tmdbMovieID, independentPolicy["verifiedFeatureMovieID"] as? Int, context)
                    let movieID = try XCTUnwrap(projection.tmdbMovieID)
                    let movie = try await fetchIndependentLiveMovie(id: movieID)
                    XCTAssertEqual(episode.title, movie.title, context)
                    XCTAssertEqual(episode.description, movie.overview, context)
                    XCTAssertEqual(episode.stillPath, movie.backdropPath, context)
                    XCTAssertEqual(episode.airDate, movie.releaseDate, context)
                    XCTAssertEqual(episode.runtime, movie.runtime, context)
                    XCTAssertNil(episode.tmdbSeasonNumber, context)
                    XCTAssertNil(episode.tmdbEpisodeNumber, context)
                    compared += 1
                    continue
                }
                guard let sourceSeason = episode.tmdbSeasonNumber, let sourceNumber = episode.tmdbEpisodeNumber else {
                    unresolved += 1
                    XCTAssertNil(episode.tmdbSeasonNumber, "\(context) partial unresolved season coordinate")
                    XCTAssertNil(episode.tmdbEpisodeNumber, "\(context) partial unresolved episode coordinate")
                    let identity = String(independentPolicy["unresolvedIdentityProvider"] as? String == "MAL"
                        ? season.malId ?? 0 : season.canonicalAniListId ?? 0)
                    unresolvedByIdentity[identity, default: 0] += 1
                    let start = unresolvedStarts[identity] ?? Int.max
                    XCTAssertTrue(expectedUnresolved[identity] != nil && episode.number >= start,
                        "\(context) unresolved s\(season.seasonNumber)e\(episode.number)")
                    XCTAssertNil(episode.description, "\(context) invented unresolved overview")
                    XCTAssertNil(episode.airDate, "\(context) invented unresolved date")
                    XCTAssertNil(episode.stillPath, "\(context) invented unresolved still")
                    XCTAssertNil(episode.runtime, "\(context) invented unresolved runtime")
                    continue
                }
                let key = "\(sourceSeason):\(sourceNumber)"
                XCTAssertTrue(seen.insert(key).inserted, "\(context) duplicate \(key)")
                let source = try XCTUnwrap(sources[key], "\(context) invented \(key)")
                let index = try XCTUnwrap(sourceIndices[key])
                XCTAssertGreaterThan(index, previousIndex, "\(context) incorrect source order")
                previousIndex = index
                if hydration == .complete || compared < 100 {
                    XCTAssertEqual(episode.title, source.name, context)
                    XCTAssertEqual(episode.description, source.overview, context)
                    XCTAssertEqual(episode.stillPath, source.stillPath, context)
                    XCTAssertEqual(episode.airDate, source.airDate, context)
                    XCTAssertEqual(episode.runtime, source.runtime, context)
                }
                if source.overview?.isEmpty ?? true { upstreamGaps["overview", default: 0] += 1 }
                if source.stillPath == nil { upstreamGaps["still", default: 0] += 1 }
                if source.airDate?.isEmpty ?? true { upstreamGaps["date", default: 0] += 1 }
                if source.runtime == nil { upstreamGaps["runtime", default: 0] += 1 }
                compared += 1
            }
            let projection = TMDBSeason(id: season.anilistId, name: season.title, overview: nil,
                posterPath: nil, seasonNumber: season.seasonNumber, episodeCount: season.episodes.count, airDate: nil)
            let selected = try await AniListService.shared.hydrateAnimeSeasonDetail(
                tmdbShowId: tmdbID, season: projection, episodes: season.episodes, tmdbService: .shared
            )
            XCTAssertEqual(selected.episodes.count, season.episodes.count, context)
            let byNumber = Dictionary(selected.episodes.map { ($0.episodeNumber, $0) }, uniquingKeysWith: { first, _ in first })
            var expectedVisible: [Int] = []
            for episode in season.episodes {
                if episode.unitProjection?.edition == .feature {
                    let selectedEpisode = try XCTUnwrap(byNumber[episode.number], context)
                    XCTAssertEqual(selectedEpisode.name, episode.title, context)
                    XCTAssertEqual(selectedEpisode.overview, episode.description, context)
                    XCTAssertEqual(selectedEpisode.stillPath, episode.stillPath, context)
                    XCTAssertEqual(selectedEpisode.airDate, episode.airDate, context)
                    XCTAssertEqual(selectedEpisode.runtime, episode.runtime, context)
                    if let date = episode.airDate, date <= today { expectedVisible.append(episode.number) }
                    continue
                }
                guard let sourceSeason = episode.tmdbSeasonNumber, let sourceNumber = episode.tmdbEpisodeNumber,
                      let source = sources["\(sourceSeason):\(sourceNumber)"] else { continue }
                let selectedEpisode = try XCTUnwrap(byNumber[episode.number], context)
                XCTAssertEqual(selectedEpisode.name, source.name, context)
                XCTAssertEqual(selectedEpisode.overview, source.overview, context)
                XCTAssertEqual(selectedEpisode.stillPath, source.stillPath, context)
                XCTAssertEqual(selectedEpisode.airDate, source.airDate, context)
                XCTAssertEqual(selectedEpisode.runtime, source.runtime, context)
                if isAired(source) { expectedVisible.append(episode.number) }
            }
            XCTAssertEqual(TVShowSeasonsSection<EmptyView>.visibleEpisodes(
                selected.episodes, showUnairedEpisodes: false, today: today
            ).map(\.episodeNumber), expectedVisible, context)
            XCTAssertEqual(TVShowSeasonsSection<EmptyView>.visibleEpisodes(
                selected.episodes, showUnairedEpisodes: true, today: today
            ).count, selected.episodes.count, context)
        }
        XCTAssertEqual(unresolvedByIdentity, expectedUnresolved, "\(context) unexpected unresolved coverage")
        let missingAired = coordinates.filter { key in
            guard let source = sources[key] else { return false }
            return isAired(source) && !seen.contains(key) && !excluded.contains(key)
        }
        if let specialID = independentPolicy["requiredSpecialAniListID"] as? Int {
            let specials = try await AniListService.shared.fetchRequiredSpecialSearchEntries(
                tmdbShowId: tmdbID, fallbackPosterURL: nil,
                baseAniListIds: details.seasons.compactMap(\.canonicalAniListId),
                requiredSpecialAniListIds: [specialID], tmdbService: .shared
            )
            let matches = specials.filter { $0.canonicalAniListId == specialID }
            XCTAssertEqual(matches.count, 1, context)
            let special = try XCTUnwrap(matches.first, context)
            XCTAssertEqual(special.malId, independentPolicy["requiredSpecialMALID"] as? Int, context)
            XCTAssertEqual(special.releaseDate, independentPolicy["requiredSpecialReleaseDate"] as? String, context)
            let keys = special.episodes.compactMap { episode -> String? in
                guard let season = episode.tmdbSeasonNumber, let number = episode.tmdbEpisodeNumber else { return nil }
                return "\(season):\(number)"
            }
            XCTAssertEqual(keys, independentPolicy["requiredSpecialCoordinates"] as? [String], context)
            XCTAssertEqual(Set(keys), excluded, "\(context) excluded regular rows must be verified specials")
            XCTAssertEqual(special.episodes.count, keys.count, context)
            for (episode, key) in zip(special.episodes, keys) {
                let source = try XCTUnwrap(sources[key], context)
                XCTAssertEqual(episode.title, source.name, context)
                XCTAssertEqual(episode.description, source.overview, context)
                XCTAssertEqual(episode.airDate, source.airDate, context)
                XCTAssertEqual(episode.stillPath, source.stillPath, context)
                XCTAssertEqual(episode.runtime, source.runtime, context)
            }
        }
        if requiresFullRegularInventory { XCTAssertTrue(missingAired.isEmpty, "\(context) lost aired source rows \(missingAired.prefix(12))") }
        if expectsActiveMetadata, !coordinates.isEmpty {
            XCTAssertGreaterThan(compared, 0, "\(context) no active metadata compared")
        }
        XCTAssertEqual(details.totalEpisodes, details.seasons.reduce(0) { $0 + $1.episodes.count }, context)
        return ["tmdbID": tmdbID, "title": context, "hydration": hydration.rawValue,
            "upstreamShowTitle": raw.name, "comparedEpisodes": compared, "unresolvedCoordinates": unresolved,
            "independentlyExpectedUnresolvedCounts": expectedUnresolved,
            "independentlyExcludedRegularCoordinates": Array(excluded).sorted(),
            "missingAiredSourceCoordinates": missingAired, "upstreamOptionalFieldGaps": upstreamGaps,
            "sourceEpisodes": coordinates.count, "canonicalAniListIDs": details.seasons.compactMap(\.canonicalAniListId),
            "canonicalMALIDs": details.seasons.compactMap(\.malId), "status": details.status,
            "oracleTransport": "Separate fresh TMDB cache, coordinator namespace and ephemeral HTTP session; reference reads excluded from measured loading",
            "cacheScope": "Public load; new AniMap actor without disk reads/writes, new TMDB memory cache, no graph/identity/preview/shallow reads or shared request joins, new ephemeral HTTP session without URLCache for all providers"]
    }

    @MainActor
    private func fetchIndependentLiveAnimeInventory(
        tmdbID: Int, context: String, includesSpecials: Bool = false
    ) async throws -> (TMDBTVShowWithSeasons, [TMDBEpisode]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await AnimeMetadataLoadingValidation.$requestLedger.withValue(nil) {
            try await AnimeMetadataLoadingValidation.$session.withValue(session) {
                try await AnimeMetadataLoadingValidation.$requestNamespace.withValue(UUID().uuidString) {
                    try await AnimeMetadataLoadingValidation.$tmdbCache.withValue(TMDBDetailCache()) {
                        let raw = try await TMDBService.shared.getTVShowWithSeasons(id: tmdbID)
                        var episodes: [TMDBEpisode] = []
                        for season in raw.seasons.filter({ ($0.seasonNumber > 0 || includesSpecials) && $0.episodeCount > 0 })
                            .sorted(by: { $0.seasonNumber < $1.seasonNumber }) {
                            let source = try await TMDBService.shared.getSeasonDetails(
                                tvShowId: tmdbID, seasonNumber: season.seasonNumber
                            )
                            XCTAssertEqual(source.episodes.count, season.episodeCount, "\(context) upstream inventory count")
                            episodes.append(contentsOf: source.episodes.sorted { $0.episodeNumber < $1.episodeNumber })
                        }
                        return (raw, episodes)
                    }
                }
            }
        }
    }

    @MainActor
    private func fetchIndependentLiveMovie(id: Int) async throws -> TMDBMovieDetail {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await AnimeMetadataLoadingValidation.$requestLedger.withValue(nil) {
            try await AnimeMetadataLoadingValidation.$session.withValue(session) {
                try await AnimeMetadataLoadingValidation.$requestNamespace.withValue(UUID().uuidString) {
                    try await AnimeMetadataLoadingValidation.$tmdbCache.withValue(TMDBDetailCache()) {
                        try await TMDBService.shared.getMovieDetails(id: id)
                    }
                }
            }
        }
    }

    private func printLiveAuditReceipt(_ receipt: [String: Any], prefix: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]) else { return }
        print("\(prefix) \(String(decoding: data, as: UTF8.self))")
    }

    private func attachLiveAudit(_ receipts: [[String: Any]], name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: receipts, options: [.sortedKeys]) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLiveAnimeInitialLoadingLatency() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_LIVE_ANIME_LATENCY"] == "1" else {
            throw XCTSkip("Set ECLIPSE_LIVE_ANIME_LATENCY=1 to measure fresh preview loading.")
        }
        let fixtures: [(Int, String, Int)] = [
            (220542, "The Apothecary Diaries", 60),
            (123542, "LINK CLICK", 41),
            (1429, "Attack on Titan", 87),
            (95479, "JUJUTSU KAISEN", 59),
            (124396, "Sonny Boy", 12),
            (34164, "Haibane Renmei", 13),
            (37854, "One Piece", 1180)
        ]
        try await Task.sleep(nanoseconds: 10_000_000_000)
        var receipts: [[String: Any]] = []
        for (id, title, count) in fixtures {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let start = ProcessInfo.processInfo.systemUptime
            let fresh = try await AniListService.shared.validateFreshAnimeLoading(title: title, tmdbShowId: id)
            let seconds = ProcessInfo.processInfo.systemUptime - start
            XCTAssertEqual(fresh.totalEpisodes, count, title)
            let first = try XCTUnwrap(fresh.seasons.first?.episodes.first, title)
            XCTAssertFalse(first.description?.isEmpty ?? true, title)
            XCTAssertNotNil(first.stillPath, title)
            let verifiedCoordinates = fresh.seasons.flatMap(\.episodes).compactMap { episode -> String? in
                guard let season = episode.tmdbSeasonNumber, let number = episode.tmdbEpisodeNumber,
                      season > 0, number > 0 else { return nil }
                return "\(season):\(number)"
            }
            if id == 37854 {
                XCTAssertEqual(verifiedCoordinates.count, count, title)
                XCTAssertEqual(Set(verifiedCoordinates).count, count, title)
            }
            var warmMilliseconds: [Double] = []
            for _ in 0..<3 {
                let warmStart = ProcessInfo.processInfo.systemUptime
                let warm = try await AniListService.shared.fetchAnimeDetailsWithEpisodes(
                    title: title, tmdbShowId: id, tmdbService: .shared, tmdbShowPoster: nil, token: nil,
                    hydrationPolicy: .initiallyVisible
                )
                warmMilliseconds.append((ProcessInfo.processInfo.systemUptime - warmStart) * 1_000)
                XCTAssertEqual(warm.totalEpisodes, fresh.totalEpisodes, title)
            }
            let receipt: [String: Any] = ["title": title, "tmdbID": id, "freshSeconds": seconds,
                "warmMilliseconds": warmMilliseconds, "episodes": fresh.totalEpisodes,
                "verifiedEpisodeCoordinates": verifiedCoordinates.count,
                "scope": "Fresh graph, fresh AniList structure request, isolated TMDB memory cache and TMDB HTTP cache bypass; installed AniMap mapping cache and shared network connections retained"]
            receipts.append(receipt)
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            print("AnimeLoadingLatency \(String(decoding: data, as: UTF8.self))")
        }
        let data = try JSONSerialization.data(withJSONObject: receipts, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Anime fresh and cached initial loading latency"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLiveMALControlsUncachedPublicLoading() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_LIVE_MAL_METADATA"] == "1" else {
            throw XCTSkip("Set ECLIPSE_LIVE_MAL_METADATA=1 for uncached MAL controls.")
        }
        let fixtures: [(Int, String, [Int])] = [
            (1429, "Attack on Titan", [16498, 25777, 35760, 38524, 40028, 48583]),
            (37854, "One Piece", [21]),
            (220542, "The Apothecary Diaries", [54492, 58514, 61987, 62841]),
            (123542, "LINK CLICK", [44074, 49413, 56752, 61607])
        ]
        var receipts: [[String: Any]] = []
        let run = try XCTUnwrap(testRun)
        for (id, title, expectedIDs) in fixtures {
            let seed = try XCTUnwrap(expectedIDs.first)
            for hydration in [AnimeEpisodeHydrationPolicy.initiallyVisible, .complete] {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                let failuresBefore = run.failureCount
                let ledger = AnimeMetadataRequestLedger()
                let start = ProcessInfo.processInfo.systemUptime
                _ = try await AnimeMetadataLoadingValidation.$requestLedger.withValue(ledger) {
                    try await AniListService.shared.validateUncachedAnimeLoading(
                        title: title, tmdbShowId: id, seedAniListId: -seed,
                        seedMALId: seed, hydrationPolicy: hydration,
                        verification: { details in
                            let seconds = ProcessInfo.processInfo.systemUptime - start
                            let requests = await ledger.snapshot()
                            let requestSeconds = await ledger.timingSnapshot()
                            let requestEvents = await ledger.eventSnapshot()
                            let droppedEvents = await ledger.droppedEventCount()
                            XCTAssertGreaterThan(requests["MAL", default: 0], 0, title)
                            XCTAssertGreaterThan(requests["AniMap", default: 0], 0, title)
                            XCTAssertEqual(requests["AniList", default: 0], 0, title)
                            XCTAssertEqual(details.seasons.compactMap(\.malId), expectedIDs, title)
                            var receipt = try await self.verifyLiveAnimeMetadata(
                                details, tmdbID: id, context: "\(title) forced MAL \(hydration)",
                                hydration: hydration, requiresFullRegularInventory: true)
                            receipt["seconds"] = seconds
                            receipt["requests"] = requests
                            receipt["requestSeconds"] = requestSeconds
                            receipt["events"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(requestEvents))
                            receipt["droppedEvents"] = droppedEvents
                            receipt["route"] = "Uncached public negative MAL seed"
                            receipt["assertionFailures"] = run.failureCount - failuresBefore
                            receipt["verificationPassed"] = run.failureCount == failuresBefore
                            receipts.append(receipt)
                            self.printLiveAuditReceipt(receipt, prefix: "MALUncachedControlAudit")
                        }
                    )
                }
            }
        }
        attachLiveAudit(receipts, name: "MAL uncached public controls")
    }

    @MainActor
    func testLiveMALHardCasesUncachedPublicLoading() async throws {
        guard let path = ProcessInfo.processInfo.environment["ECLIPSE_LIVE_MAL_HARDCASE_ORACLE"] else {
            throw XCTSkip("Supply ECLIPSE_LIVE_MAL_HARDCASE_ORACLE for independently verified MAL hard cases.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fixtures = try XCTUnwrap(envelope["cases"] as? [[String: Any]])
        XCTAssertEqual(fixtures.count, 8)
        var receipts: [[String: Any]] = []
        let run = try XCTUnwrap(testRun)
        for fixture in fixtures {
            let id = try XCTUnwrap(fixture["tmdbID"] as? Int)
            let seed = try XCTUnwrap(fixture["selectedMALID"] as? Int)
            let title = try XCTUnwrap(fixture["selectedTitle"] as? String)
            let expectedIDs = try XCTUnwrap(fixture["expectedRegularMALIDs"] as? [Int])
            let declaredCounts = try XCTUnwrap(fixture["expectedCountsByMALID"] as? [String: Int])
            var policy: [String: Any] = ["unresolvedIdentityProvider": "MAL"]
            if id == 105009 {
                policy["expectedUnresolvedEpisodeCounts"] = ["59088": 8]
                policy["unresolvedStartsByIdentity"] = ["59088": 6]
            } else if id == 34742 {
                policy["regularExcludedCoordinates"] = ["4:13", "4:14"]
                policy["independentExcludedRowOwnership"] = "AniList SPECIAL21852 broadcast rows, verified by the separate primary-route live assertion; MAL31711 retains its conflicting disc release date."
            }
            for hydration in [AnimeEpisodeHydrationPolicy.initiallyVisible, .complete] {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                let failuresBefore = run.failureCount
                let ledger = AnimeMetadataRequestLedger()
                let start = ProcessInfo.processInfo.systemUptime
                var verificationStarted = false
                var publicSnapshot: (seconds: Double, requests: [String: Int], requestSeconds: [String: [Double]],
                    events: [AnimeMetadataRequestLedger.Event], droppedEvents: Int)?
                do {
                    _ = try await AnimeMetadataLoadingValidation.$requestLedger.withValue(ledger) {
                        try await AniListService.shared.validateUncachedAnimeLoading(
                            title: title, tmdbShowId: id, seedAniListId: -seed,
                            seedMALId: seed, hydrationPolicy: hydration,
                            verification: { details in
                                verificationStarted = true
                                let seconds = ProcessInfo.processInfo.systemUptime - start
                                let requests = await ledger.snapshot()
                                let requestSeconds = await ledger.timingSnapshot()
                                let requestEvents = await ledger.eventSnapshot()
                                let droppedEvents = await ledger.droppedEventCount()
                                publicSnapshot = (seconds, requests, requestSeconds, requestEvents, droppedEvents)
                                XCTAssertGreaterThan(requests["MAL", default: 0], 0, title)
                                XCTAssertGreaterThan(requests["AniMap", default: 0], 0, title)
                                XCTAssertEqual(requests["AniList", default: 0], 0, title)
                                XCTAssertEqual(details.seasons.compactMap(\.malId), expectedIDs, title)
                                for season in details.seasons {
                                    guard let malID = season.malId, let declared = declaredCounts[String(malID)], declared > 0 else { continue }
                                    XCTAssertEqual(season.episodes.count, declared, "\(title) MAL\(malID) declared coverage")
                                }
                                var receipt = try await self.verifyLiveAnimeMetadata(
                                    details, tmdbID: id, context: "\(title) forced MAL hard case \(hydration)",
                                    hydration: hydration, requiresFullRegularInventory: true,
                                    independentPolicy: policy)
                                receipt["seconds"] = seconds
                                receipt["requests"] = requests
                                receipt["requestSeconds"] = requestSeconds
                                receipt["events"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(requestEvents))
                                receipt["droppedEvents"] = droppedEvents
                                receipt["route"] = "Uncached public negative MAL seed"
                                receipt["independentMALFixture"] = fixture
                                receipt["independentOracleCorrection"] = policy
                                receipt["assertionFailures"] = run.failureCount - failuresBefore
                                receipt["verificationPassed"] = run.failureCount == failuresBefore
                                receipts.append(receipt)
                                self.printLiveAuditReceipt(receipt, prefix: "MALUncachedHardCaseAudit")
                            }
                        )
                    }
                } catch {
                    let totalElapsed = ProcessInfo.processInfo.systemUptime - start
                    let failure = error as NSError
                    let snapshot: (seconds: Double, requests: [String: Int], requestSeconds: [String: [Double]],
                        events: [AnimeMetadataRequestLedger.Event], droppedEvents: Int)
                    if let publicSnapshot {
                        snapshot = publicSnapshot
                    } else {
                        snapshot = (totalElapsed, await ledger.snapshot(), await ledger.timingSnapshot(),
                            await ledger.eventSnapshot(), await ledger.droppedEventCount())
                    }
                    let encodedEvents = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.events))
                    XCTFail("\(title) forced MAL \(hydration) failed: \(failure.domain) \(failure.code) \(failure.localizedDescription)")
                    let receipt: [String: Any] = [
                        "tmdbID": id,
                        "title": "\(title) forced MAL hard case \(hydration)",
                        "hydration": String(describing: hydration),
                        "status": verificationStarted ? "verification-failed" : "load-failed",
                        "failureStage": verificationStarted ? "verification" : "public-load",
                        "seconds": snapshot.seconds,
                        "totalElapsedSeconds": totalElapsed,
                        "requests": snapshot.requests,
                        "requestSeconds": snapshot.requestSeconds,
                        "events": encodedEvents ?? [],
                        "eventEncodingFailed": encodedEvents == nil,
                        "droppedEvents": snapshot.droppedEvents,
                        "route": "Uncached public negative MAL seed",
                        "requestScope": "New isolated public validation scope and ledger for this single mode; no independent reference requests on public-load failure",
                        "cacheScope": "Public load; new AniMap actor without disk reads/writes, new TMDB memory cache, no graph/identity/preview/shallow reads or shared request joins, new ephemeral HTTP session without URLCache for all providers",
                        "seedMALID": seed,
                        "publicNSError": ["domain": failure.domain, "code": failure.code,
                            "description": String(failure.localizedDescription.prefix(2000))],
                        "independentMALFixture": fixture,
                        "independentOracleCorrection": policy,
                        "assertionFailures": run.failureCount - failuresBefore,
                        "verificationPassed": false
                    ]
                    receipts.append(receipt)
                    self.printLiveAuditReceipt(receipt, prefix: "MALUncachedHardCaseAudit")
                }
            }
        }
        attachLiveAudit(receipts, name: "MAL uncached hard cases")
    }

    @MainActor
    func testLiveOnePieceMissingAniMapPreservesVerifiedInventory() async throws {
        try await verifyLiveOnePieceMissingMap(forceMAL: false)
    }

    @MainActor
    func testLiveMALOnePieceMissingAniMapPreservesVerifiedInventory() async throws {
        try await verifyLiveOnePieceMissingMap(forceMAL: true)
    }

    @MainActor
    private func verifyLiveOnePieceMissingMap(forceMAL: Bool) async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_LIVE_ONE_PIECE_MISSING_MAP"] == "1" else {
            throw XCTSkip("Set ECLIPSE_LIVE_ONE_PIECE_MISSING_MAP=1 to verify the public missing-mapping One Piece paths.")
        }
        if !forceMAL { try await Task.sleep(nanoseconds: 10_000_000_000) }
        let run = try XCTUnwrap(testRun)
        let prefix = forceMAL ? "OnePieceMALMissingMapAudit" : "OnePieceMissingMapAudit"
        let route = forceMAL ? "Fresh public negative MAL seed; decoded AniMap results intentionally withheld"
            : "Fresh unseeded public primary load; AniMap decoded results intentionally withheld"
        var receipts: [[String: Any]] = []
        for hydration in [AnimeEpisodeHydrationPolicy.initiallyVisible, .complete] {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let failuresBefore = run.failureCount
            let ledger = AnimeMetadataRequestLedger()
            let start = ProcessInfo.processInfo.systemUptime
            var publicLoadSnapshot: [String: Any]?
            var verificationStarted = false
            do {
                _ = try await AnimeMetadataLoadingValidation.$requestLedger.withValue(ledger) {
                    try await AniListService.shared.validateUncachedAnimeLoading(
                        title: "ONE PIECE", tmdbShowId: 37854, seedAniListId: forceMAL ? -21 : nil,
                        seedMALId: forceMAL ? 21 : nil, hydrationPolicy: hydration,
                        ignoreAniMapResults: true, verification: { details in
                            let seconds = ProcessInfo.processInfo.systemUptime - start
                            let requests = await ledger.snapshot()
                            let requestSeconds = await ledger.timingSnapshot()
                            let events = await ledger.eventSnapshot()
                            let droppedEvents = await ledger.droppedEventCount()
                            let snapshot: [String: Any] = ["seconds": seconds, "requests": requests,
                                "requestSeconds": requestSeconds,
                                "events": try JSONSerialization.jsonObject(with: JSONEncoder().encode(events)),
                                "droppedEvents": droppedEvents, "actualRootID": details.id,
                                "rawProviderSeasonIDs": details.seasons.map(\.anilistId),
                                "canonicalAniListIDs": details.seasons.compactMap(\.canonicalAniListId),
                                "canonicalMALIDs": details.seasons.compactMap(\.malId),
                                "totalEpisodeRows": details.totalEpisodes]
                            publicLoadSnapshot = snapshot
                            verificationStarted = true
                            XCTAssertGreaterThan(requests["AniMap", default: 0], 0)
                            XCTAssertGreaterThan(requests[forceMAL ? "MAL" : "AniList", default: 0], 0)
                            XCTAssertEqual(requests[forceMAL ? "AniList" : "MAL", default: 0], 0)
                            XCTAssertEqual(details.id, forceMAL ? -21 : 21)
                            XCTAssertEqual(details.seasons.map(\.anilistId), [forceMAL ? -21 : 21])
                            if forceMAL { XCTAssertEqual(details.seasons.compactMap(\.malId), [21]) }
                            else { XCTAssertEqual(details.seasons.compactMap(\.canonicalAniListId), [21]) }
                            var receipt = try await self.verifyLiveAnimeMetadata(details, tmdbID: 37854,
                                context: "ONE PIECE \(forceMAL ? "MAL" : "primary") missing AniMap \(hydration)", hydration: .complete,
                                requiresFullRegularInventory: true)
                            let sourceCount = try XCTUnwrap(receipt["sourceEpisodes"] as? Int)
                            XCTAssertEqual(details.totalEpisodes, sourceCount)
                            XCTAssertGreaterThanOrEqual(sourceCount, 1180)
                            XCTAssertEqual(receipt["comparedEpisodes"] as? Int, sourceCount)
                            receipt.merge(snapshot, uniquingKeysWith: { _, frozen in frozen })
                            receipt["hydration"] = hydration.rawValue
                            receipt["metadataVerification"] = "Every actual source body was available to the load; all fields checked in both modes"
                            receipt["route"] = route
                            receipt["forceMAL"] = forceMAL
                            receipt["ignoreAniMapResults"] = true
                            receipt["latencyBenchmarkEligible"] = false
                            receipt["assertionFailures"] = run.failureCount - failuresBefore
                            receipt["verificationPassed"] = run.failureCount == failuresBefore
                            receipts.append(receipt)
                            self.printLiveAuditReceipt(receipt, prefix: prefix)
                        })
                }
            } catch {
                var receipt: [String: Any]
                if let publicLoadSnapshot { receipt = publicLoadSnapshot }
                else {
                    receipt = ["seconds": ProcessInfo.processInfo.systemUptime - start,
                        "requests": await ledger.snapshot(), "requestSeconds": await ledger.timingSnapshot(),
                        "events": try JSONSerialization.jsonObject(with: JSONEncoder().encode(await ledger.eventSnapshot())),
                        "droppedEvents": await ledger.droppedEventCount()]
                }
                let publicError = error as NSError
                XCTFail("ONE PIECE \(forceMAL ? "MAL" : "primary") \(hydration) \(verificationStarted ? "verification" : "load") failed: \(publicError.domain) \(publicError.code)")
                receipt["tmdbID"] = 37854
                receipt["title"] = "ONE PIECE \(forceMAL ? "MAL" : "primary") missing AniMap \(hydration)"
                receipt["hydration"] = hydration.rawValue
                receipt["route"] = route
                receipt["forceMAL"] = forceMAL
                receipt["ignoreAniMapResults"] = true
                receipt["latencyBenchmarkEligible"] = false
                receipt["status"] = verificationStarted ? "verification-failed" : "load-failed"
                receipt["failureStage"] = verificationStarted ? "independent-verification" : "public-load"
                receipt["errorDomain"] = publicError.domain
                receipt["errorCode"] = publicError.code
                receipt["totalElapsedSeconds"] = ProcessInfo.processInfo.systemUptime - start
                receipt["requestScope"] = verificationStarted ? "Frozen at public callback before independent oracle" : "Public load failure before callback"
                receipt["assertionFailures"] = run.failureCount - failuresBefore
                receipt["verificationPassed"] = false
                receipts.append(receipt)
                self.printLiveAuditReceipt(receipt, prefix: prefix)
            }
        }
        attachLiveAudit(receipts, name: "One Piece \(forceMAL ? "MAL" : "primary") missing AniMap verified actual inventory")
    }

    @MainActor
    func testLiveMALMissingAniMapPreservesVerifiedWholeInventory() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_LIVE_MAL_MISSING_MAP"] == "1",
              let path = ProcessInfo.processInfo.environment["ECLIPSE_LIVE_MAL_HARDCASE_ORACLE"] else {
            throw XCTSkip("Set ECLIPSE_LIVE_MAL_MISSING_MAP=1 and supply ECLIPSE_LIVE_MAL_HARDCASE_ORACLE.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fixtures = try XCTUnwrap(envelope["cases"] as? [[String: Any]])
        let run = try XCTUnwrap(testRun)
        var receipts: [[String: Any]] = []
        for tmdbID in [94664, 105009] {
            let fixture = try XCTUnwrap(fixtures.first { ($0["tmdbID"] as? Int) == tmdbID })
            let seed = try XCTUnwrap(fixture["selectedMALID"] as? Int)
            let title = try XCTUnwrap(fixture["selectedTitle"] as? String)
            let expectedIDs = try XCTUnwrap(fixture["expectedRegularMALIDs"] as? [Int])
            let counts = try XCTUnwrap(fixture["expectedCountsByMALID"] as? [String: Int])
            let total = try XCTUnwrap(fixture["independentlyVerifiedActiveMALDeclaredTotal"] as? Int)
            var policy: [String: Any] = ["unresolvedIdentityProvider": "MAL"]
            if tmdbID == 105009 {
                policy["expectedUnresolvedEpisodeCounts"] = ["59088": 8]
                policy["unresolvedStartsByIdentity"] = ["59088": 6]
            }
            for hydration in [AnimeEpisodeHydrationPolicy.initiallyVisible, .complete] {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                let failuresBefore = run.failureCount
                let ledger = AnimeMetadataRequestLedger()
                let start = ProcessInfo.processInfo.systemUptime
                _ = try await AnimeMetadataLoadingValidation.$requestLedger.withValue(ledger) {
                    try await AniListService.shared.validateUncachedAnimeLoading(
                        title: title, tmdbShowId: tmdbID, seedAniListId: -seed, seedMALId: seed,
                        hydrationPolicy: hydration, ignoreAniMapResults: true,
                        verification: { details in
                            let seconds = ProcessInfo.processInfo.systemUptime - start
                            let requests = await ledger.snapshot()
                            let requestSeconds = await ledger.timingSnapshot()
                            let events = await ledger.eventSnapshot()
                            let droppedEvents = await ledger.droppedEventCount()
                            XCTAssertGreaterThan(requests["AniMap", default: 0], 0)
                            XCTAssertGreaterThan(requests["MAL", default: 0], 0)
                            XCTAssertEqual(requests["AniList", default: 0], 0)
                            XCTAssertEqual(details.seasons.compactMap(\.malId), expectedIDs)
                            XCTAssertEqual(details.totalEpisodes, total)
                            for season in details.seasons {
                                guard let id = season.malId, let count = counts[String(id)], count > 0 else { continue }
                                XCTAssertEqual(season.episodes.count, count)
                            }
                            var receipt = try await self.verifyLiveAnimeMetadata(details, tmdbID: tmdbID,
                                context: "\(title) forced missing AniMap \(hydration)", hydration: hydration,
                                requiresFullRegularInventory: true, independentPolicy: policy)
                            receipt["seconds"] = seconds
                            receipt["requests"] = requests
                            receipt["requestSeconds"] = requestSeconds
                            receipt["events"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(events))
                            receipt["droppedEvents"] = droppedEvents
                            receipt["route"] = "Fresh public negative MAL seed; AniMap results intentionally unavailable (successful responses withheld)"
                            receipt["ignoreAniMapResults"] = true
                            receipt["latencyBenchmarkEligible"] = false
                            receipt["independentMALFixture"] = fixture
                            receipt["independentOracleCorrection"] = policy
                            receipt["assertionFailures"] = run.failureCount - failuresBefore
                            receipt["verificationPassed"] = run.failureCount == failuresBefore
                            receipts.append(receipt)
                            self.printLiveAuditReceipt(receipt, prefix: "MALMissingMapAudit")
                        })
                }
            }
        }
        attachLiveAudit(receipts, name: "MAL missing AniMap verified inventory")
    }

    @MainActor
    func testLiveDirectMALAnimeMetadata() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_LIVE_MAL_METADATA"] == "1" else {
            throw XCTSkip("Set ECLIPSE_LIVE_MAL_METADATA=1 to validate the direct MAL metadata path.")
        }
        let fixtures: [(Int, String, [Int], [Int])] = [
            (1429, "Attack on Titan", [16498, 25777, 35760, 38524, 40028, 48583], [25, 12, 12, 10, 16, 12]),
            (37854, "One Piece", [21], []),
            (220542, "The Apothecary Diaries", [54492, 58514, 61987, 62841], [24, 24, 12, 0]),
            (123542, "LINK CLICK", [44074, 49413, 56752, 61607], [11, 12, 6, 12])
        ]
        for (id, title, expectedIDs, declaredCounts) in fixtures {
            let raw = try await TMDBService.shared.getTVShowWithSeasons(id: id)
            let summaries = raw.seasons.filter { $0.seasonNumber > 0 && $0.episodeCount > 0 }
                .sorted { $0.seasonNumber < $1.seasonNumber }
            var coordinates: [String] = []
            var sourceEpisodes: [String: TMDBEpisode] = [:]
            for summary in summaries {
                let detail = try await TMDBService.shared.getSeasonDetails(tvShowId: id, seasonNumber: summary.seasonNumber)
                XCTAssertEqual(detail.episodes.count, summary.episodeCount, "\(title) source inventory")
                for episode in detail.episodes.sorted(by: { $0.episodeNumber < $1.episodeNumber }) {
                    let coordinate = "\(episode.seasonNumber):\(episode.episodeNumber)"
                    coordinates.append(coordinate)
                    sourceEpisodes[coordinate] = episode
                }
            }
            let expectedCounts = declaredCounts.isEmpty ? [coordinates.count] : declaredCounts
            for hydration in [AnimeEpisodeHydrationPolicy.initiallyVisible, .complete] {
                let details = try await AnimeMALMetadataValidation.details(
                    title: title, tmdbShowId: id, hydrationPolicy: hydration, tmdbShowDetail: raw
                )
                let context = "\(title) direct MAL \(hydration)"
                XCTAssertEqual(details.seasons.compactMap(\.malId), expectedIDs, context)
                XCTAssertEqual(details.seasons.map { $0.episodes.count }, expectedCounts, context)
                XCTAssertTrue(details.seasons.allSatisfy { $0.anilistId < 0 }, context)
                XCTAssertEqual(details.totalEpisodes, expectedCounts.reduce(0, +), context)
                let episodes = details.seasons.flatMap(\.episodes)
                let resolved = episodes.compactMap { episode -> String? in
                    guard let season = episode.tmdbSeasonNumber, let number = episode.tmdbEpisodeNumber else { return nil }
                    return "\(season):\(number)"
                }
                XCTAssertEqual(resolved, coordinates, context)
                var compared = 0
                for (absolute, episode) in episodes.enumerated() {
                    guard hydration == .complete || absolute < 100,
                          coordinates.indices.contains(absolute),
                          let source = sourceEpisodes[coordinates[absolute]] else { continue }
                    XCTAssertEqual(episode.title, source.name, context)
                    if let value = source.overview { XCTAssertEqual(episode.description, value, context) }
                    if let value = source.stillPath { XCTAssertEqual(episode.stillPath, value, context) }
                    if let value = source.airDate { XCTAssertEqual(episode.airDate, value, context) }
                    if let value = source.runtime { XCTAssertEqual(episode.runtime, value, context) }
                    compared += 1
                }
                XCTAssertEqual(compared, hydration == .complete ? episodes.count : min(100, episodes.count), context)
                let receipt: [String: Any] = ["tmdbID": id, "title": title, "route": "direct MAL, provider detail cache bypassed",
                    "hydration": hydration.rawValue, "malIDs": details.seasons.compactMap(\.malId),
                    "episodeCounts": details.seasons.map { $0.episodes.count }, "comparedEpisodes": compared]
                let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                print("MALAnimeSweep \(String(decoding: data, as: UTF8.self))")
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = context
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
#endif

    func testUpcomingRegularSeasonHydrationKeepsTheSelectedSeasonEmpty() async throws {
        let season = TMDBSeason(id: 200927, name: "The Apothecary Diaries Season 3 Part 2", overview: nil, posterPath: nil, seasonNumber: 4, episodeCount: 0, airDate: nil)
        let detail = try await AniListService.shared.hydrateAnimeSeasonDetail(
            tmdbShowId: 220542, season: season, episodes: [], tmdbService: .shared
        )
        XCTAssertEqual(detail.seasonNumber, 4)
        XCTAssertEqual(detail.id, season.id)
        XCTAssertTrue(detail.episodes.isEmpty)
        XCTAssertTrue(TVShowSeasonsSection<EmptyView>.visibleEpisodes(
            detail.episodes, showUnairedEpisodes: false, today: "2026-10-07"
        ).isEmpty)
    }

    func testApothecaryMetadataSurvivesUpcomingContinuationWithOrWithoutTMDBInventory() throws {
        let statuses: [String?] = ["FINISHED", "FINISHED", "RELEASING", "NOT_YET_RELEASED"]
        for upcomingCount in [12, nil] as [Int?] {
            let segments: [AnimeStructureCoverageSegment] = [
                .init(mappedTMDBSeason: 1, episodeCount: 24),
                .init(mappedTMDBSeason: 1, episodeCount: 24),
                .init(mappedTMDBSeason: 1, episodeCount: 12),
                .init(mappedTMDBSeason: 1, episodeCount: upcomingCount)
            ]
            for hydration in [AnimeEpisodeHydrationPolicy.initiallyVisible, .complete] {
                let allows = AnimeStructurePolicy.allowsLinearTMDBCoordinates(
                    hydrationPolicy: hydration,
                    tmdbSeasonEpisodeCounts: [1: 60],
                    segments: segments,
                    statuses: statuses
                )
                XCTAssertTrue(allows)
                let starts = [1, 25, 49]
                let titles = ["Maomao", "Maomao and Maomao", "Locusts"]
                for index in starts.indices {
                    let start = starts[index]
                    let metadata = TMDBEpisode(id: start, name: titles[index], overview: "Verified overview", stillPath: "/verified.jpg", episodeNumber: start, seasonNumber: 1, airDate: "2026-10-02", runtime: 24, voteAverage: 8, voteCount: 10)
                    let episodes = AnimeSeasonEpisodeHydrationPolicy.episodes(
                        count: segments[index].episodeCount ?? 0,
                        displaySeasonNumber: index + 1,
                        startingAt: start,
                        tmdbEpisodes: [start: metadata],
                        tmdbCoordinates: [start + 1: .init(seasonNumber: 1, episodeNumber: start + 1)],
                        allowsTMDBCoordinates: allows
                    )
                    let first = try XCTUnwrap(episodes.first)
                    XCTAssertEqual(first.title, titles[index])
                    XCTAssertEqual(first.description, metadata.overview)
                    XCTAssertEqual(first.stillPath, metadata.stillPath)
                    XCTAssertEqual(first.airDate, metadata.airDate)
                    XCTAssertEqual(first.runtime, metadata.runtime)
                    XCTAssertEqual(first.tmdbSeasonNumber, 1)
                    XCTAssertEqual(first.tmdbEpisodeNumber, start)
                    XCTAssertEqual(episodes[1].tmdbEpisodeNumber, start + 1)
                    XCTAssertEqual(first.seasonNumber, index + 1)
                }
                XCTAssertEqual(AnimeSeasonEpisodeHydrationPolicy.displayEpisodeCount(
                    declaredCount: upcomingCount,
                    remainingTMDBCount: 12,
                    allowsOpenEndedRemainder: false,
                    status: statuses[3]
                ), 0)
                if upcomingCount != nil {
                    XCTAssertTrue(AnimeStructurePolicy.allowsLinearTMDBCoordinates(
                        hydrationPolicy: hydration,
                        tmdbSeasonEpisodeCounts: [1: 72],
                        segments: segments,
                        statuses: statuses
                    ))
                }
            }
        }
    }

    func testInterleavedUpcomingSeasonCannotShiftLaterEpisodeMetadata() {
        for hydration in [AnimeEpisodeHydrationPolicy.initiallyVisible, .complete] {
            XCTAssertFalse(AnimeStructurePolicy.allowsLinearTMDBCoordinates(
                hydrationPolicy: hydration,
                tmdbSeasonEpisodeCounts: [1: 60],
                segments: [.init(mappedTMDBSeason: 1, episodeCount: 24), .init(mappedTMDBSeason: 1, episodeCount: 12), .init(mappedTMDBSeason: 1, episodeCount: 24)],
                statuses: ["FINISHED", "NOT_YET_RELEASED", "RELEASING"]
            ))
        }
    }

    func testUnknownActiveSeasonAndUnalignedStatusesStillWithholdLinearMetadata() {
        let segments: [AnimeStructureCoverageSegment] = [.init(mappedTMDBSeason: 1, episodeCount: 24), .init(mappedTMDBSeason: 1, episodeCount: nil)]
        for hydration in [AnimeEpisodeHydrationPolicy.initiallyVisible, .complete] {
            for status in ["RELEASING", "FINISHED", "UNKNOWN", nil] as [String?] {
                XCTAssertFalse(AnimeStructurePolicy.allowsLinearTMDBCoordinates(
                    hydrationPolicy: hydration,
                    tmdbSeasonEpisodeCounts: [1: 24],
                    segments: segments,
                    statuses: ["FINISHED", status]
                ))
            }
            XCTAssertFalse(AnimeStructurePolicy.allowsLinearTMDBCoordinates(
                hydrationPolicy: hydration,
                tmdbSeasonEpisodeCounts: [1: 24],
                segments: segments,
                statuses: ["FINISHED"]
            ))
        }
        XCTAssertFalse(AnimeStructurePolicy.allowsLinearTMDBCoordinates(
            hydrationPolicy: .initiallyVisible,
            tmdbSeasonEpisodeCounts: [1: 60],
            segments: [.init(mappedTMDBSeason: 1, episodeCount: 24), .init(mappedTMDBSeason: 1, episodeCount: 12)],
            statuses: ["FINISHED", "NOT_YET_RELEASED"]
        ))
    }

    func testMALUpcomingStatusUsesTheSameVerifiedPrefixAndLinkClickKeepsEveryActiveSeason() {
        XCTAssertTrue(AnimeStructurePolicy.allowsLinearTMDBCoordinates(
            hydrationPolicy: .initiallyVisible,
            tmdbSeasonEpisodeCounts: [1: 60],
            segments: [24, 24, 12, 12].map { .init(mappedTMDBSeason: 1, episodeCount: $0) },
            statuses: ["finished_airing", "finished_airing", "currently_airing", "not_yet_aired"]
        ))
        XCTAssertTrue(AnimeStructurePolicy.allowsLinearTMDBCoordinates(
            hydrationPolicy: .initiallyVisible,
            tmdbSeasonEpisodeCounts: [1: 11, 2: 12, 3: 6, 4: 12],
            segments: [11, 12, 6, 12].enumerated().map { .init(mappedTMDBSeason: $0.offset + 1, episodeCount: $0.element) },
            statuses: ["FINISHED", "FINISHED", "FINISHED", "RELEASING"]
        ))
    }

    @MainActor
    func testLiveApothecaryAndLinkClickMetadata() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_LIVE_ANIME_METADATA"] == "1" else {
            throw XCTSkip("Set ECLIPSE_LIVE_ANIME_METADATA=1 to check current metadata services.")
        }
        let fixtures = [(220542, "The Apothecary Diaries", [161645, 176301, 195516, 200927]), (123542, "LINK CLICK", [126403, 136484, 170166, 191832])]
        for (id, title, expectedIDs) in fixtures {
            let raw = try await TMDBService.shared.getTVShowWithSeasons(id: id)
            for hydration in [AnimeEpisodeHydrationPolicy.initiallyVisible, .complete] {
                let details = try await AniListService.shared.fetchAnimeDetailsWithEpisodes(
                    title: title, tmdbShowId: id, tmdbService: .shared, tmdbShowPoster: raw.posterPath,
                    token: nil, hydrationPolicy: hydration, knownTMDBShowDetail: raw
                )
                XCTAssertEqual(details.seasons.compactMap(\.canonicalAniListId), expectedIDs)
                let activeSeasons = id == 220542 ? Array(details.seasons.prefix(3)) : details.seasons
                for season in activeSeasons {
                    let first = try XCTUnwrap(season.episodes.first)
                    XCTAssertNotEqual(first.title, "Episode 1", "\(title) \(hydration) \(season.title)")
                    XCTAssertFalse(first.description?.isEmpty ?? true)
                    XCTAssertNotNil(first.stillPath)
                    XCTAssertNotNil(first.airDate)
                    XCTAssertNotNil(first.tmdbSeasonNumber)
                    XCTAssertNotNil(first.tmdbEpisodeNumber)
                }
                if id == 220542 {
                    XCTAssertEqual(details.seasons.map { $0.episodes.count }, [24, 24, 12, 0])
                    XCTAssertEqual(details.seasons.prefix(3).compactMap { $0.episodes.first?.tmdbEpisodeNumber }, [1, 25, 49])
                } else {
                    XCTAssertEqual(details.seasons.map { $0.episodes.count }, [11, 12, 6, 12])
                }
                let receipt = XCTAttachment(string: details.seasons.map { "\($0.title): \($0.episodes.count), first=\($0.episodes.first?.title ?? "empty")" }.joined(separator: "\n"))
                receipt.name = "\(title) \(hydration) metadata"
                receipt.lifetime = .keepAlways
                add(receipt)
            }
        }
    }

    @MainActor
    func testLiveVariedAnimeMetadata() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_LIVE_ANIME_SWEEP"] == "1" else {
            throw XCTSkip("Set ECLIPSE_LIVE_ANIME_SWEEP=1 to audit varied anime against current metadata services.")
        }
        let fixtures: [(Int, String, [Int], [Int])] = [
            (1429, "Attack on Titan", [16498, 20958, 99147, 104578, 110277, 131681], [25, 12, 12, 10, 16, 12]),
            (85937, "Demon Slayer: Kimetsu no Yaiba", [101922, 129874, 142329, 145139, 166240], [26, 7, 11, 11, 8]),
            (95479, "JUJUTSU KAISEN", [113415, 145064, 172463, 209895], [24, 23, 12, 0]),
            (65930, "My Hero Academia", [21459, 21856, 100166, 104276, 117193, 139630, 163139, 182896], [13, 25, 25, 25, 25, 25, 21, 11]),
            (120089, "SPY x FAMILY", [140960, 142838, 158927, 177937], [12, 13, 12, 13]),
            (209867, "Frieren: Beyond Journey's End", [154587, 182255, 209939], [28, 10, 0]),
            (127532, "Solo Leveling", [151807, 176496], [12, 13]),
            (31911, "Fullmetal Alchemist: Brotherhood", [5114], [64]),
            (37854, "One Piece", [21], []),
            (116727, "ODDTAXI", [128547], [13]),
            (124396, "Sonny Boy", [132126], [12]),
            (26867, "Mushi-Shi", [457, 20595, 20751], [26, 10, 10]),
            (16660, "Mononoke", [2246], [12]),
            (34164, "Haibane Renmei", [387], [13]),
            (82766, "Run with the Wind", [101903], [23]),
            (65952, "The Great Passage", [21703], [11]),
            (85065, "Kyousougiga", [19703], [10]),
            (66862, "Descending Stories", [20972, 21733], [13, 12]),
            (60811, "Ping Pong the Animation", [20607], [11]),
            (34121, "Baccano!", [2251], [13]),
            (220542, "The Apothecary Diaries", [161645, 176301, 195516, 200927], [24, 24, 12, 0]),
            (123542, "LINK CLICK", [126403, 136484, 170166, 191832], [11, 12, 6, 12])
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let today = formatter.string(from: Date())
        var receipts: [[String: Any]] = []
        for (id, title, expectedIDs, declaredCounts) in fixtures {
            do {
                let raw = try await TMDBService.shared.getTVShowWithSeasons(id: id)
                let regularSeasons = raw.seasons.filter { $0.seasonNumber > 0 && $0.episodeCount > 0 }
                    .sorted { $0.seasonNumber < $1.seasonNumber }
                var expectedCoordinates: [String] = []
                var sources: [String: TMDBEpisode] = [:]
                for season in regularSeasons {
                    let detail = try await TMDBService.shared.getSeasonDetails(tvShowId: id, seasonNumber: season.seasonNumber)
                    XCTAssertEqual(detail.episodes.count, season.episodeCount, "\(title) source inventory")
                    for episode in detail.episodes.sorted(by: { $0.episodeNumber < $1.episodeNumber }) {
                        let coordinate = "\(episode.seasonNumber):\(episode.episodeNumber)"
                        expectedCoordinates.append(coordinate)
                        sources[coordinate] = episode
                    }
                }
                let expectedCounts = declaredCounts.isEmpty ? [expectedCoordinates.count] : declaredCounts
                let expectedCoordinateSet = Set(expectedCoordinates)
                for hydration in [AnimeEpisodeHydrationPolicy.initiallyVisible, .complete] {
                    let details = try await AniListService.shared.fetchAnimeDetailsWithEpisodes(
                        title: title, tmdbShowId: id, tmdbService: .shared, tmdbShowPoster: raw.posterPath,
                        token: nil, hydrationPolicy: hydration, knownTMDBShowDetail: raw
                    )
                    let context = "\(title) \(hydration)"
                    XCTAssertEqual(details.seasons.compactMap(\.canonicalAniListId), expectedIDs, context)
                    XCTAssertEqual(details.seasons.map { $0.episodes.count }, expectedCounts, context)
                    XCTAssertEqual(details.totalEpisodes, details.seasons.reduce(0) { $0 + $1.episodes.count }, context)
                    XCTAssertEqual(Set(details.seasons.compactMap(\.canonicalAniListId)).count, details.seasons.count, context)
                    var offset = 0
                    var compared = 0
                    var unresolved = 0
                    var sourceGaps = 0
                    var missingFields = ["overview": 0, "still": 0, "date": 0, "runtime": 0]
                    var seenCoordinates = Set<String>()
                    var seasonReceipts: [[String: Any]] = []
                    for season in details.seasons {
                        let comparedBeforeSeason = compared
                        XCTAssertEqual(season.episodes.map(\.number), Array(1..<(season.episodes.count + 1)), context)
                        let projection = TMDBSeason(id: season.anilistId, name: season.title, overview: nil,
                            posterPath: nil, seasonNumber: season.seasonNumber, episodeCount: season.episodes.count, airDate: nil)
                        let selected = try await AniListService.shared.hydrateAnimeSeasonDetail(
                            tmdbShowId: id, season: projection, episodes: season.episodes, tmdbService: .shared
                        )
                        XCTAssertEqual(selected.episodes.count, season.episodes.count, context)
                        XCTAssertEqual(selected.seasonNumber, season.seasonNumber, context)
                        if season.episodes.isEmpty {
                            XCTAssertTrue(selected.episodes.isEmpty, context)
                        }
                        let hydratedByNumber = Dictionary(selected.episodes.map { ($0.episodeNumber, $0) }, uniquingKeysWith: { first, _ in first })
                        for episode in season.episodes {
                            let episodeContext = "\(context) s\(season.seasonNumber)e\(episode.number)"
                            guard let sourceSeason = episode.tmdbSeasonNumber, let sourceNumber = episode.tmdbEpisodeNumber else {
                                unresolved += 1
                                XCTFail("Unresolved coordinates: \(episodeContext)")
                                continue
                            }
                            let coordinate = "\(sourceSeason):\(sourceNumber)"
                            XCTAssertTrue(seenCoordinates.insert(coordinate).inserted, "Repeated coordinate \(coordinate): \(episodeContext)")
                            XCTAssertTrue(expectedCoordinateSet.contains(coordinate), "Outside regular inventory: \(episodeContext)")
                            let absolute = offset + episode.number - 1
                            if expectedCoordinates.indices.contains(absolute) {
                                XCTAssertEqual(coordinate, expectedCoordinates[absolute], "Boundary/order: \(episodeContext)")
                            }
                            guard let source = sources[coordinate] else {
                                sourceGaps += 1
                                continue
                            }
                            let selectedEpisode = try XCTUnwrap(hydratedByNumber[episode.number], episodeContext)
                            XCTAssertEqual(selectedEpisode.name, source.name, episodeContext)
                            if let value = source.overview { XCTAssertEqual(selectedEpisode.overview, value, episodeContext) }
                            if let value = source.stillPath { XCTAssertEqual(selectedEpisode.stillPath, value, episodeContext) }
                            if let value = source.airDate { XCTAssertEqual(selectedEpisode.airDate, value, episodeContext) }
                            if let value = source.runtime { XCTAssertEqual(selectedEpisode.runtime, value, episodeContext) }
                            if hydration == .complete || absolute < 100 {
                                XCTAssertEqual(episode.title, source.name, episodeContext)
                                if let value = source.overview { XCTAssertEqual(episode.description, value, episodeContext) }
                                if let value = source.stillPath { XCTAssertEqual(episode.stillPath, value, episodeContext) }
                                if let value = source.airDate { XCTAssertEqual(episode.airDate, value, episodeContext) }
                                if let value = source.runtime { XCTAssertEqual(episode.runtime, value, episodeContext) }
                            }
                            if source.overview?.isEmpty ?? true { missingFields["overview", default: 0] += 1 }
                            if source.stillPath == nil { missingFields["still", default: 0] += 1 }
                            if source.airDate?.isEmpty ?? true { missingFields["date", default: 0] += 1 }
                            if source.runtime == nil { missingFields["runtime", default: 0] += 1 }
                            compared += 1
                        }
                        let visible = TVShowSeasonsSection<EmptyView>.visibleEpisodes(selected.episodes, showUnairedEpisodes: false, today: today)
                        let expectedVisible = season.episodes.filter { episode in
                            guard let sourceSeason = episode.tmdbSeasonNumber,
                                  let sourceNumber = episode.tmdbEpisodeNumber,
                                  let rawDate = sources["\(sourceSeason):\(sourceNumber)"]?.airDate,
                                  rawDate.count >= 10 else { return false }
                            let value = String(rawDate.prefix(10))
                            guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return false }
                            return value <= today
                        }
                        XCTAssertEqual(visible.map(\.episodeNumber), expectedVisible.map(\.number), context)
                        if !season.episodes.isEmpty {
                            XCTAssertGreaterThan(compared, comparedBeforeSeason, "No source metadata compared: \(context) \(season.title)")
                        }
                        XCTAssertEqual(TVShowSeasonsSection<EmptyView>.visibleEpisodes(
                            selected.episodes, showUnairedEpisodes: true, today: today
                        ).count, selected.episodes.count, context)
                        seasonReceipts.append([
                            "title": season.title, "canonicalID": season.canonicalAniListId ?? 0,
                            "episodes": selected.episodes.count, "airedVisible": visible.count,
                            "first": selected.episodes.first?.name ?? "empty", "last": selected.episodes.last?.name ?? "empty"
                        ])
                        offset += season.episodes.count
                    }
                    XCTAssertEqual(sourceGaps, 0, "Incomplete upstream episode inventory: \(context)")
                    let receipt: [String: Any] = [
                        "tmdbID": id, "title": title, "hydration": hydration.rawValue,
                        "fixtureVerifiedOn": "2026-10-07", "coordinatePolicy": "Full regular TMDB chronology for this fixture",
                        "comparedEpisodes": compared, "unresolvedCoordinates": unresolved,
                        "missingUpstreamRows": sourceGaps, "missingUpstreamFields": missingFields,
                        "seasons": seasonReceipts
                    ]
                    receipts.append(receipt)
                    let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                    print("AnimeSweep \(String(decoding: data, as: UTF8.self))")
                }
                if id == 1429 {
                    let specials = try await AniListService.shared.fetchSpecialSearchEntries(
                        tmdbShowId: id, fallbackPosterURL: raw.posterPath, baseAniListIds: expectedIDs, tmdbService: .shared
                    )
                    for (specialID, episodeNumber) in [(146984, 36), (162314, 37)] {
                        let special = try XCTUnwrap(specials.first { $0.canonicalAniListId == specialID })
                        let episode = try XCTUnwrap(special.episodes.first)
                        XCTAssertEqual(episode.tmdbSeasonNumber, 0)
                        XCTAssertEqual(episode.tmdbEpisodeNumber, episodeNumber)
                        XCTAssertFalse(episode.description?.isEmpty ?? true)
                        XCTAssertNotNil(episode.stillPath)
                    }
                }
            } catch {
                let error = error as NSError
                XCTFail("\(title) live audit failed: \(error.domain) \(error.code)")
                receipts.append(["tmdbID": id, "title": title, "errorDomain": error.domain, "errorCode": error.code])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: receipts, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Varied anime live metadata audit"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(receipts.count, fixtures.count * 2)
    }
}

final class AnimeMappedSpecialPlacementTests: XCTestCase {
    func testAbsoluteOrderingRequiresActualCoordinatesAcrossSourceSeasons() {
        XCTAssertTrue(AnimeStructurePolicy.requiresVerifiedAbsoluteOrderInventory(tvdbSeasons: [-1], tmdbSeasonCount: 23))
        XCTAssertTrue(AnimeStructurePolicy.requiresVerifiedAbsoluteOrderInventory(tvdbSeasons: [1, -1], tmdbSeasonCount: 2))
        XCTAssertFalse(AnimeStructurePolicy.requiresVerifiedAbsoluteOrderInventory(tvdbSeasons: [1, nil], tmdbSeasonCount: 23))
        XCTAssertFalse(AnimeStructurePolicy.requiresVerifiedAbsoluteOrderInventory(tvdbSeasons: [-1], tmdbSeasonCount: 1))
        XCTAssertFalse(AnimeStructurePolicy.requiresVerifiedAbsoluteOrderInventory(tvdbSeasons: [], tmdbSeasonCount: 23))
    }

    func testUnavailableAbsoluteOrderSlotsStayUnresolvedWithoutShiftingLaterMetadata() throws {
        let later = TMDBEpisode(id: 131, name: "Verified later episode", overview: "Source overview", stillPath: nil,
            episodeNumber: 131, seasonNumber: 5, airDate: "2002-01-01", runtime: 24, voteAverage: 0, voteCount: 0)
        let episodes = AnimeSeasonEpisodeHydrationPolicy.episodes(count: 131, displaySeasonNumber: 1, startingAt: 1,
            tmdbEpisodes: [131: later], tmdbCoordinates: [:], allowsTMDBCoordinates: true)
        XCTAssertEqual(episodes.count, 131)
        XCTAssertTrue(episodes.prefix(130).allSatisfy { $0.tmdbSeasonNumber == nil && $0.tmdbEpisodeNumber == nil })
        let resolved = try XCTUnwrap(episodes.last)
        XCTAssertEqual(resolved.number, 131)
        XCTAssertEqual(resolved.tmdbSeasonNumber, 5)
        XCTAssertEqual(resolved.tmdbEpisodeNumber, 131)
        XCTAssertEqual(resolved.title, later.name)
    }

    func testStrictInventoryReservesMissingEmptyAndTruncatedSourceSeasons() throws {
        let summaries = [
            TMDBSeason(id: 1, name: "Earlier", overview: nil, posterPath: nil, seasonNumber: 1, episodeCount: 2, airDate: nil),
            TMDBSeason(id: 5, name: "Later", overview: nil, posterPath: nil, seasonNumber: 5, episodeCount: 1, airDate: nil)
        ]
        let earlier = TMDBEpisode(id: 1, name: "Earlier episode", overview: nil, stillPath: nil,
            episodeNumber: 61, seasonNumber: 1, airDate: nil, runtime: nil, voteAverage: 0, voteCount: 0)
        let later = TMDBEpisode(id: 3, name: "Later episode", overview: "Later overview", stillPath: nil,
            episodeNumber: 131, seasonNumber: 5, airDate: nil, runtime: nil, voteAverage: 0, voteCount: 0)
        for missing in [nil, [], [earlier]] as [[TMDBEpisode]?] {
            var source = [5: [later]]
            source[1] = missing
            let projected = AnimeSeasonEpisodeHydrationPolicy.hydrateTMDBInventory(seasons: summaries,
                fetchedEpisodesBySeason: source, allowsSummaryCoordinates: false)
            XCTAssertEqual(projected.episodes.keys.sorted(), [3])
            XCTAssertEqual(projected.coordinates.keys.sorted(), [3])
            XCTAssertEqual(projected.coordinates[3]?.seasonNumber, 5)
            XCTAssertEqual(projected.coordinates[3]?.episodeNumber, 131)
            XCTAssertEqual(projected.episodes[3]?.name, later.name)
        }
        let unavailable = AnimeSeasonEpisodeHydrationPolicy.hydrateTMDBInventory(seasons: summaries,
            fetchedEpisodesBySeason: [:], allowsSummaryCoordinates: false)
        XCTAssertTrue(unavailable.episodes.isEmpty)
        XCTAssertTrue(unavailable.coordinates.isEmpty)
    }

    func testInventoryPreservesActualSourceNumberingAndOrdinaryPreviewLimit() {
        let summaries = [
            TMDBSeason(id: 1, name: "Earlier", overview: nil, posterPath: nil, seasonNumber: 1, episodeCount: 2, airDate: nil),
            TMDBSeason(id: 2, name: "Later", overview: nil, posterPath: nil, seasonNumber: 2, episodeCount: 1, airDate: nil)
        ]
        let rows = (61...63).map { number in
            TMDBEpisode(id: number, name: "Episode \(number)", overview: nil, stillPath: nil, episodeNumber: number,
                seasonNumber: number == 63 ? 2 : 1, airDate: nil, runtime: nil, voteAverage: 0, voteCount: 0)
        }
        let projected = AnimeSeasonEpisodeHydrationPolicy.hydrateTMDBInventory(seasons: summaries,
            fetchedEpisodesBySeason: [1: Array(rows.prefix(2)), 2: [rows[2]]], allowsSummaryCoordinates: false)
        XCTAssertEqual((1...3).compactMap { projected.coordinates[$0]?.episodeNumber }, [61, 62, 63])
        let preview = AnimeSeasonEpisodeHydrationPolicy.hydrateTMDBInventory(seasons: summaries,
            fetchedEpisodesBySeason: [1: Array(rows.prefix(2))], allowsSummaryCoordinates: true, absoluteEpisodeLimit: 1)
        XCTAssertEqual(preview.episodes.keys.sorted(), [1])
        XCTAssertEqual(preview.coordinates[2]?.episodeNumber, 62)
        XCTAssertEqual(preview.coordinates[3]?.seasonNumber, 2)
        XCTAssertEqual(preview.coordinates[3]?.episodeNumber, 1)
    }

    func testCoveredRegularSeasonKeepsOverhangingFinaleDetached() throws {
        let ordinary = try [mapping(id: 101, type: "TV"), mapping(id: 102, type: "TV")]
        let proof = occupancy(ordinary, counts: [101: 16, 102: 12])
        XCTAssertEqual(proof, [4: 28])
        let finale = try mapping()
        XCTAssertFalse(AniMapStructuralRole.isRegularStory(finale, tmdbSeasonEpisodeCounts: [4: 28], episodeCount: 1, regularStoryEpisodeCounts: proof))
        XCTAssertTrue(AniMapStructuralRole.isDetachedSpecial(finale, tmdbSeasonEpisodeCounts: [4: 28], episodeCount: 1, regularStoryEpisodeCounts: proof))
    }

    func testActualRegularFinaleSlotsRemainSupported() throws {
        let ordinary = try [mapping(id: 101, type: "TV"), mapping(id: 102, type: "TV")]
        let proof = occupancy(ordinary, counts: [101: 16, 102: 12])
        let finale = try mapping(offset: 200)
        XCTAssertTrue(AniMapStructuralRole.isRegularStory(finale, tmdbSeasonEpisodeCounts: [4: 30], episodeCount: 2, regularStoryEpisodeCounts: proof))
        XCTAssertFalse(AniMapStructuralRole.isDetachedSpecial(finale, tmdbSeasonEpisodeCounts: [4: 30], episodeCount: 2, regularStoryEpisodeCounts: proof))
        XCTAssertFalse(AniMapStructuralRole.isRegularStory(finale, tmdbSeasonEpisodeCounts: [4: 30], episodeCount: 3, regularStoryEpisodeCounts: proof))
    }

    func testDifferingTVDBLayoutDoesNotRejectAStandaloneRegularSpecial() throws {
        let finale = try mapping(offset: 28)
        XCTAssertTrue(AniMapStructuralRole.isRegularStory(finale, tmdbSeasonEpisodeCounts: [4: 2], episodeCount: 2, regularStoryEpisodeCounts: [:]))
    }

    func testUnknownOrdinaryCountsCannotAuthorSpecialReclassification() throws {
        let ordinary = try [mapping(id: 101, type: "TV"), mapping(id: 102, type: "TV")]
        let proof = occupancy(ordinary, counts: [101: 16])
        XCTAssertTrue(proof.isEmpty)
        XCTAssertTrue(AniMapStructuralRole.isRegularStory(try mapping(), tmdbSeasonEpisodeCounts: [4: 28], episodeCount: 1, regularStoryEpisodeCounts: proof))
    }

    func testDuplicateIdentityCountsOnceAndConflictingPlacementsAbstain() throws {
        let entry = try mapping(id: 101, type: "TV")
        XCTAssertEqual(occupancy([entry, entry], counts: [101: 28]), [4: 28])
        let conflict = try mapping(id: 101, season: 5, type: "TV")
        XCTAssertTrue(occupancy([entry, conflict], counts: [101: 28]).isEmpty)
    }

    func testAlternativeRegularPlacementSurvivesStaleSpecialMapping() throws {
        let ordinary = try mapping(id: 101, type: "TV")
        let stale = try mapping()
        let valid = try mapping(season: 5)
        let regular = AniMapStructuralRole.regularStoryMappings([ordinary, stale, valid],
            tmdbShowId: 1429, tmdbSeasonEpisodeCounts: [4: 28, 5: 2],
            regularStoryEpisodeCounts: occupancy([ordinary], counts: [101: 28]),
            mediaType: { $0.mediaType }, episodeCount: { $0.anilistId == 101 ? 28 : 2 })
        XCTAssertEqual(regular.filter { $0.anilistId == 146984 }.map(\.tmdbSeason), [5])
        XCTAssertTrue(Set(regular.compactMap(\.anilistId)).contains(146984))
    }

    func testUpcomingOrdinaryRowsContributeNoPlayableOccupancy() throws {
        let entries = try [mapping(id: 101, type: "TV"), mapping(id: 102, type: "TV")]
        XCTAssertEqual(occupancy(entries, counts: [101: 28, 102: 0]), [4: 28])
        XCTAssertTrue(occupancy(entries, counts: [101: 28, 102: -1]).isEmpty)
    }

    func testAbsentRegularSeasonAndUnavailableProofHaveDifferentAuthority() throws {
        let finale = try mapping()
        XCTAssertFalse(AniMapStructuralRole.isRegularStory(finale, tmdbSeasonEpisodeCounts: [1: 10], episodeCount: 1))
        XCTAssertTrue(AniMapStructuralRole.isRegularStory(finale, episodeCount: 1))
        XCTAssertTrue(AniMapStructuralRole.isRegularStory(finale, tmdbSeasonEpisodeCounts: [4: 28], episodeCount: 1, regularStoryEpisodeCounts: [4: 0]))
        XCTAssertTrue(AniMapStructuralRole.isRegularStory(finale, tmdbSeasonEpisodeCounts: [4: 28], episodeCount: 1, regularStoryEpisodeCounts: [4: 29]))
    }

    func testMappedUpcomingFormatFallbackRequiresSameShowRegularEvidence() throws {
        let tv = try mapping(type: "TV", show: 95479)
        XCTAssertEqual(AnimeRelationRolePolicy.regularContinuationFormat(mediaFormat: nil, mapping: tv, tmdbShowId: 95479), "TV")
        XCTAssertNil(AnimeRelationRolePolicy.regularContinuationFormat(mediaFormat: nil, mapping: tv, tmdbShowId: 1429))
        XCTAssertNil(AnimeRelationRolePolicy.regularContinuationFormat(mediaFormat: nil, mapping: try mapping(type: "SPECIAL"), tmdbShowId: 1429))
        XCTAssertNil(AnimeRelationRolePolicy.regularContinuationFormat(mediaFormat: nil, mapping: try mapping(season: 0, type: "TV"), tmdbShowId: 1429))
        XCTAssertEqual(AnimeRelationRolePolicy.regularContinuationFormat(mediaFormat: "SPECIAL", mapping: tv, tmdbShowId: 95479), "SPECIAL")
    }

    private func occupancy(_ mappings: [AniMapMapping], counts: [Int: Int]) -> [Int: Int] {
        AniMapStructuralRole.ordinarySeasonEpisodeCounts(mappings, identity: { $0.anilistId }, mediaType: { $0.mediaType },
            episodeCount: { $0.anilistId.flatMap { counts[$0] } })
    }

    private func mapping(id: Int = 146984, season: Int = 4, tvdbSeason: Int = 4, offset: Int = 28,
        type: String = "SPECIAL", show: Int = 1429) throws -> AniMapMapping {
        let data = try JSONSerialization.data(withJSONObject: ["anilist_id": id, "mal_id": id, "tmdb_show_id": show,
            "tmdb_season": season, "tvdb_season": tvdbSeason, "tvdb_epoffset": offset, "media_type": type])
        let decoded = try JSONDecoder().decode(AniMapMapping.self, from: data)
        XCTAssertEqual(decoded.tmdbShowId, show)
        return decoded
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

final class AnimeVerifiedEpisodeUnitPolicyTests: XCTestCase {
    func testCuratedSaikiProofSurvivesMissingAniMapButRefusesKnownOwners() throws {
        XCTAssertTrue(AnimeVerifiedEpisodeUnitPolicy.hasNoKnownSaikiOwnerConflict(tmdbShowID: 67676,
            aniListID: nil, malID: 33255, mappings: [], hasOtherProvedOwner: false))
        let episodes = try XCTUnwrap(AnimeVerifiedEpisodeUnitPolicy.saikiCompiledEpisodes(
            tmdbShowID: 67676, aniListID: nil, malID: 33255, episodeCount: 120,
            format: "TV", status: "finished_airing", startDate: "2016-07-04", endDate: "2016-12-26",
            hasUniqueSourceOwner: true, sourceSeason: saikiSeason(), displaySeasonNumber: 1))
        XCTAssertEqual(episodes.count, 24)
        let conflicts = [try unitMapping(aniListID: 98034, malID: 34612, season: 1),
            try unitMapping(aniListID: nil, malID: nil, season: 1),
            try unitMapping(aniListID: 21804, malID: 33255, season: 2)]
        for conflict in conflicts {
            XCTAssertFalse(AnimeVerifiedEpisodeUnitPolicy.hasNoKnownSaikiOwnerConflict(tmdbShowID: 67676,
                aniListID: 21804, malID: 33255, mappings: [conflict], hasOtherProvedOwner: false))
        }
        XCTAssertFalse(AnimeVerifiedEpisodeUnitPolicy.hasNoKnownSaikiOwnerConflict(tmdbShowID: 67676,
            aniListID: 21804, malID: 33255, mappings: [], hasOtherProvedOwner: true))
    }

    func testRazbliutoPartsRefuseAnotherProvenSourceSeasonOwner() throws {
        XCTAssertTrue(AnimeVerifiedEpisodeUnitPolicy.hasNoKnownRazbliutoPartOwnerConflict(tmdbShowID: 93816,
            malID: 57184, mappings: [], hasOtherProvedOwner: false))
        XCTAssertFalse(AnimeVerifiedEpisodeUnitPolicy.hasNoKnownRazbliutoPartOwnerConflict(tmdbShowID: 93816,
            malID: 57184, mappings: [], hasOtherProvedOwner: true))
        XCTAssertFalse(AnimeVerifiedEpisodeUnitPolicy.hasNoKnownRazbliutoPartOwnerConflict(tmdbShowID: 93816,
            malID: 57184, mappings: [try unitMapping(aniListID: 110349, malID: 40052, season: 2, showID: 93816)],
            hasOtherProvedOwner: false))
        XCTAssertNil(AnimeVerifiedEpisodeUnitPolicy.razbliutoPartEpisodes(tmdbShowID: 93816, malID: 57184,
            episodeCount: 4, format: "ONA", status: "finished_airing", startDate: "2024-02-23",
            sourceSeason: partsSeason(), displaySeasonNumber: 2, hasUniqueSourceOwner: false))
    }

    private func unitMapping(aniListID: Int?, malID: Int?, season: Int, showID: Int = 67676) throws -> AniMapMapping {
        var payload: [String: Any] = ["tmdb_show_id": showID, "tmdb_season": season, "media_type": "TV"]
        payload["anilist_id"] = aniListID
        payload["mal_id"] = malID
        return try JSONDecoder().decode(AniMapMapping.self, from: JSONSerialization.data(withJSONObject: payload))
    }

#if os(iOS) || os(macOS)
    func testDownloadedFeatureRoutesTheActualMovieAndRejectsLegacyPartOne() throws {
        let feature = try XCTUnwrap(featureEpisode(try movieFixture()))
        let context = playbackContext(feature, aniListID: 170935, malID: 57184, count: 1)
        let movie = try downloadFixture(tmdbID: 1220441, isMovie: true)
        let mediaInfo = try XCTUnwrap(DownloadedAnimeUnitPlaybackPolicy.mediaInfo(for: movie, context: context))
        guard case .movie(let id, _, _, let isAnime) = mediaInfo else {
            XCTFail("Feature download must preserve movie identity")
            return
        }
        XCTAssertEqual(id, 1220441)
        XCTAssertTrue(isAnime)
        let legacyQuarter = try downloadFixture(tmdbID: 93816, isMovie: false)
        XCTAssertNil(DownloadedAnimeUnitPlaybackPolicy.mediaInfo(for: legacyQuarter, context: context))
        XCTAssertNil(DownloadedAnimeUnitPlaybackPolicy.mediaInfo(for: try downloadFixture(tmdbID: 93816, isMovie: true), context: context))
        let snapshot = EpisodeDownloadLookupSnapshot(items: [legacyQuarter, movie], providerAliasesByTMDBID: [:], revision: 1)
        XCTAssertEqual(snapshot.matchingEpisodeDownloadItem(tmdbId: 93816, seasonNumber: 2,
            episodeNumber: 1, playbackContext: context, accepting: { _ in true })?.tmdbId, 1220441)
    }

    func testDownloadedCompilationCannotReuseLegacyMicroepisodeAuthority() throws {
        let episode = try XCTUnwrap(saikiEpisodes(source: saikiSeason())?[5])
        let compiled = playbackContext(episode, aniListID: 21804, malID: 33255, count: 24)
        var item = try downloadFixture(tmdbID: 67676, isMovie: false)
        XCTAssertNil(DownloadedAnimeUnitPlaybackPolicy.mediaInfo(for: item, context: compiled))
        item.episodePlaybackContext = compiled
        XCTAssertNotNil(DownloadedAnimeUnitPlaybackPolicy.mediaInfo(for: item, context: compiled))
        let legacy = EpisodePlaybackContext(localSeasonNumber: 1, localEpisodeNumber: 6,
            anilistMediaId: 21804, canonicalAniListMediaId: 21804, malMediaId: 33255,
            tmdbSeasonNumber: nil, tmdbEpisodeNumber: nil, tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: 6, animeSeasonEpisodeCount: 120, isSpecial: false, titleOnlySearch: false)
        XCTAssertNil(DownloadedAnimeUnitPlaybackPolicy.mediaInfo(for: item, context: legacy))
        var poisoned = compiled
        poisoned = EpisodePlaybackContext(localSeasonNumber: poisoned.localSeasonNumber, localEpisodeNumber: poisoned.localEpisodeNumber,
            anilistMediaId: poisoned.anilistMediaId, tmdbSeasonNumber: nil, tmdbEpisodeNumber: nil, tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: nil, animeSeasonEpisodeCount: nil, isSpecial: false, titleOnlySearch: false,
            unitProjection: .init(edition: .unverified, canonicalAniListEpisodeRange: nil, canonicalMALEpisodeRange: nil))
        item.episodePlaybackContext = poisoned
        XCTAssertNil(DownloadedAnimeUnitPlaybackPolicy.mediaInfo(for: item, context: compiled))
    }

    private func downloadFixture(tmdbID: Int, isMovie: Bool) throws -> DownloadItem {
        let payload: [String: Any] = ["id": "fixture-\(tmdbID)-\(isMovie)", "tmdbId": tmdbID, "isMovie": isMovie,
            "title": "Verified edition", "displayTitle": "Verified edition", "seasonNumber": 2, "episodeNumber": 1,
            "streamURL": "https://example.invalid/fixture.mp4", "headers": [:], "serviceBaseURL": "https://example.invalid",
            "status": "completed", "progress": 1, "totalBytes": 100, "downloadedBytes": 100,
            "localFileName": "fixture.mp4", "dateAdded": 0, "dateCompleted": 0, "isAnime": true]
        return try JSONDecoder().decode(DownloadItem.self, from: JSONSerialization.data(withJSONObject: payload))
    }
#endif

    func testContextTranslationAndCopiesPreserveTheOfficialUnitMap() throws {
        let episode = try XCTUnwrap(saikiEpisodes(source: saikiSeason())?[5])
        let original = playbackContext(episode, aniListID: 21804, malID: 33255, count: 24)
        XCTAssertTrue(original.hasTrustedUnitProjection(showID: 67676))
        XCTAssertFalse(original.supportsCanonicalEpisodeLookup)
        let next = original.forEpisodeNumber(7)
        XCTAssertEqual(next.localEpisodeNumber, 7)
        XCTAssertEqual(next.resolvedTMDBEpisodeNumber, 7)
        XCTAssertEqual(next.unitProjection?.canonicalAniListEpisodeRange?.range, 31...35)
        XCTAssertEqual(next.canonicalCompletedEpisodeNumber(forMAL: false), 35)
        XCTAssertEqual(next.canonicalCompletedEpisodeNumber(forMAL: true), 35)
        XCTAssertTrue(next.hasTrustedUnitProjection(showID: 67676))
        XCTAssertEqual(next.withKitsuMediaId(123).unitProjection, next.unitProjection)
        XCTAssertEqual(next.withCanonicalAniListMediaId(21804).unitProjection, next.unitProjection)
        XCTAssertEqual(next.withMALMediaId(33255).unitProjection, next.unitProjection)
        XCTAssertEqual(original.forEpisodeNumber(25).unitProjection?.edition, .unverified)
    }

    func testProjectedCompilationIsNotTheLegacyMicroepisodeWithTheSameLocalNumber() throws {
        let episode = try XCTUnwrap(saikiEpisodes(source: saikiSeason())?[5])
        let compiled = playbackContext(episode, aniListID: 21804, malID: 33255, count: 24)
        let legacy = EpisodePlaybackContext(localSeasonNumber: 1, localEpisodeNumber: 6,
            anilistMediaId: 21804, canonicalAniListMediaId: 21804, malMediaId: 33255,
            tmdbSeasonNumber: nil, tmdbEpisodeNumber: nil, tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: 6, animeSeasonEpisodeCount: 120, isSpecial: false, titleOnlySearch: false)
        XCTAssertFalse(AnimeEpisodeIdentityPolicy.isSameEpisode(compiled, legacy))
        XCTAssertFalse(AnimeEpisodeIdentityPolicy.isSameEpisode(compiled, legacy, allowLegacyLocalCoordinates: true))
        XCTAssertFalse(AnimeEpisodeIdentityPolicy.isSameEpisode(legacy, compiled, allowLegacyLocalCoordinates: true))
    }

    func testContextCompletesAniListFeatureOnlyAfterAllFourPhysicalParts() throws {
        let part = try XCTUnwrap(partsEpisodes(partsSeason())?.last)
        let context = playbackContext(part, aniListID: 170935, malID: 57184, count: 4)
        XCTAssertTrue(context.hasTrustedUnitProjection(showID: 93816))
        XCTAssertNil(context.canonicalCompletedEpisodeNumber(forMAL: false, completedPhysicalParts: [4]))
        XCTAssertNil(context.canonicalCompletedEpisodeNumber(forMAL: false, completedPhysicalParts: [1, 3, 4]))
        XCTAssertEqual(context.canonicalCompletedEpisodeNumber(forMAL: false, completedPhysicalParts: [1, 2, 3, 4]), 1)
        XCTAssertEqual(context.canonicalCompletedEpisodeNumber(forMAL: true), 4)
        XCTAssertFalse(context.supportsCanonicalEpisodeLookup)
        let previous = context.forEpisodeNumber(3)
        XCTAssertEqual(previous.unitProjection?.physicalPartOrdinal, 3)
        XCTAssertEqual(previous.canonicalCompletedEpisodeNumber(forMAL: true), 3)
    }

    func testFeatureContextRetainsMoviePointerAndRefusesChangedUnit() throws {
        let feature = try XCTUnwrap(featureEpisode(try movieFixture()))
        let context = playbackContext(feature, aniListID: 170935, malID: 57184, count: 1)
        XCTAssertTrue(context.hasTrustedUnitProjection(showID: 93816))
        XCTAssertTrue(context.hasTrustedUnitProjection(showID: 1220441))
        XCTAssertEqual(context.unitProjection?.tmdbMovieID, 1220441)
        XCTAssertNil(context.resolvedTMDBEpisodeNumber)
        XCTAssertEqual(context.canonicalCompletedEpisodeNumber(forMAL: false), 1)
        XCTAssertEqual(context.canonicalCompletedEpisodeNumber(forMAL: true), 4)
        XCTAssertEqual(context.forEpisodeNumber(2).unitProjection?.edition, .unverified)
    }

    func testPhysicalNumberTranslationUsesExplicitWholeCatalogGroups() throws {
        let compiled = try XCTUnwrap(saikiEpisodes(source: saikiSeason())?.first?.unitProjection)
        XCTAssertEqual(compiled.forPhysicalEpisodeNumber(2).canonicalAniListEpisodeRange?.range, 6...10)
        XCTAssertEqual(compiled.forPhysicalEpisodeNumber(24).canonicalMALEpisodeRange?.range, 116...120)
        XCTAssertEqual(compiled.forPhysicalEpisodeNumber(25).edition, .unverified)
        XCTAssertEqual(compiled.forPhysicalEpisodeNumber(Int.max).edition, .unverified)
        let part = try XCTUnwrap(partsEpisodes(partsSeason())?.first?.unitProjection)
        XCTAssertEqual(part.forPhysicalEpisodeNumber(4).physicalPartOrdinal, 4)
        XCTAssertEqual(part.forPhysicalEpisodeNumber(4).canonicalMALEpisodeRange?.range, 4...4)
        XCTAssertEqual(part.forPhysicalEpisodeNumber(4).canonicalAniListEpisodeRange?.range, 1...1)
        XCTAssertEqual(part.forPhysicalEpisodeNumber(5).edition, .unverified)
    }

    func testCanonicalSaikiImportsOnlyFullyCompletedPhysicalGroups() throws {
        let episodes = try XCTUnwrap(saikiEpisodes(source: saikiSeason()))
        XCTAssertEqual(TrackerAnimeImportCoordinates.resolve(watched: 4, episodes: episodes), [:])
        XCTAssertEqual(TrackerAnimeImportCoordinates.resolve(watched: 5, episodes: episodes), [1: [1]])
        XCTAssertEqual(TrackerAnimeImportCoordinates.resolve(watched: 6, episodes: episodes), [1: [1]])
        XCTAssertEqual(TrackerAnimeImportCoordinates.resolve(watched: 10, episodes: episodes), [1: [1, 2]])
        XCTAssertEqual(TrackerAnimeImportCoordinates.resolve(watched: 120, episodes: episodes), [1: Array(1...24)])
        XCTAssertNil(TrackerAnimeImportCoordinates.resolve(watched: 121, episodes: episodes))
        XCTAssertEqual(TrackerAnimeImportCoordinates.resolve(watched: 6, episodes: episodes, provider: .myAnimeList), [1: [1]])
    }

    func testFeaturePartImportUsesTheRequestedCanonicalProvider() throws {
        let episodes = try XCTUnwrap(partsEpisodes(partsSeason()))
        XCTAssertEqual(TrackerAnimeImportCoordinates.resolve(watched: 0, episodes: episodes), [:])
        XCTAssertEqual(TrackerAnimeImportCoordinates.resolve(watched: 1, episodes: episodes), [2: [1, 2, 3, 4]])
        XCTAssertEqual(TrackerAnimeImportCoordinates.resolve(watched: 1, episodes: episodes, provider: .myAnimeList), [2: [1]])
        XCTAssertEqual(TrackerAnimeImportCoordinates.resolve(watched: 3, episodes: episodes, provider: .myAnimeList), [2: [1, 2, 3]])
        XCTAssertNil(TrackerAnimeImportCoordinates.resolve(watched: 4, episodes: episodes, provider: .anilist))
    }

    func testFeatureImportNeverFabricatesAPartOneTVCoordinate() throws {
        let feature = try XCTUnwrap(featureEpisode(try movieFixture()))
        XCTAssertEqual(TrackerAnimeImportCoordinates.resolve(watched: 1, episodes: [feature]), [:])
        XCTAssertEqual(TrackerAnimeImportCoordinates.resolve(watched: 4, episodes: [feature], provider: .myAnimeList), [:])
        XCTAssertNil(TrackerAnimeImportCoordinates.resolve(watched: 2, episodes: [feature]))
    }

    func testProjectedImportRejectsPartialAndUnverifiedUnitCatalogs() throws {
        var episodes = try XCTUnwrap(saikiEpisodes(source: saikiSeason()))
        episodes.removeLast()
        XCTAssertNil(TrackerAnimeImportCoordinates.resolve(watched: 6, episodes: episodes))
        episodes = try XCTUnwrap(saikiEpisodes(source: saikiSeason()))
        episodes[0].unitProjection = .init(edition: .unverified, canonicalAniListEpisodeRange: nil, canonicalMALEpisodeRange: nil)
        XCTAssertNil(TrackerAnimeImportCoordinates.resolve(watched: 6, episodes: episodes))
    }

    func testCombinedImportKeepsProviderSpecificUnitFloor() async throws {
        let episodes = try XCTUnwrap(partsEpisodes(partsSeason()))
        let season = AniListSeasonWithPoster(seasonNumber: 2, anilistId: -57184, canonicalAniListId: 170935,
            malId: 57184, kitsuId: nil, title: "Razbliuto", englishTitle: nil, romajiTitle: nil, nativeTitle: nil,
            episodes: episodes, posterUrl: nil, canonicalAniListEpisodeCount: 1, canonicalMALEpisodeCount: 4)
        let entries = [TrackerCombinedAnimeImport.Entry(index: 0, aniListID: 170935, malID: 57184, watched: 1),
            TrackerCombinedAnimeImport.Entry(index: 1, aniListID: 170935, malID: 57184, watched: 1, provider: .myAnimeList)]
        let result = try await TrackerCombinedAnimeImport.resolve(entries, loadModel: { _ in [season] }, validateAuthority: {})
        XCTAssertEqual(result[0], [2: [1...4]])
        XCTAssertEqual(result[1], [2: [1...1]])
    }

    func testOfficialSaikiCompilationsKeepUniquePhysicalRowsAndCanonicalCoverage() throws {
        let source = saikiSeason()
        let episodes = try XCTUnwrap(saikiEpisodes(source: source))
        XCTAssertEqual(episodes.count, 24)
        XCTAssertEqual(episodes.map(\.tmdbEpisodeNumber), Array(1...24))
        XCTAssertEqual(Set(episodes.compactMap(\.tmdbEpisodeNumber)).count, 24)
        XCTAssertEqual(episodes.first?.runtime, 23)
        XCTAssertEqual(episodes.first?.airDate, "2016-07-11")
        XCTAssertEqual(episodes.first?.title, source.episodes.first?.name)
        XCTAssertEqual(episodes.last?.unitProjection?.canonicalAniListEpisodeRange?.range, 116...120)
        let canonical = episodes.flatMap { $0.unitProjection?.canonicalAniListEpisodeRange?.range.map(Array.init) ?? [] }
        XCTAssertEqual(canonical, Array(1...120))
        XCTAssertEqual(AnimeVerifiedEpisodeUnitPolicy.canonicalAniListCount(episodes), 120)
        XCTAssertEqual(AnimeVerifiedEpisodeUnitPolicy.canonicalMALCount(episodes), 120)
    }

    func testSaikiMALUsesSameProvenCompiledUnits() throws {
        let episodes = try XCTUnwrap(AnimeVerifiedEpisodeUnitPolicy.saikiCompiledEpisodes(
            tmdbShowID: 67676, aniListID: nil, malID: 33255, episodeCount: 120,
            format: "TV", status: "finished_airing", startDate: "2016-07-04", endDate: "2016-12-26",
            hasUniqueSourceOwner: true, sourceSeason: saikiSeason(), displaySeasonNumber: 1))
        XCTAssertEqual(episodes.count, 24)
        XCTAssertEqual(episodes[1].unitProjection?.canonicalMALEpisodeRange?.range, 6...10)
    }

    func testSaikiRejectsRatioOnlyForeignOrCompetingIdentity() {
        XCTAssertNil(saikiEpisodes(source: saikiSeason(), aniListID: 98034))
        XCTAssertNil(saikiEpisodes(source: saikiSeason(), count: 119))
        XCTAssertNil(saikiEpisodes(source: saikiSeason(), uniqueOwner: false))
        XCTAssertNil(saikiEpisodes(source: saikiSeason(), status: "RELEASING"))
    }

    func testSaikiRejectsIncompleteDuplicateAndContradictoryActualSource() {
        var episodes = saikiSeason().episodes
        episodes.removeLast()
        XCTAssertNil(saikiEpisodes(source: season(episodes, id: 79808, number: 1)))
        episodes = saikiSeason().episodes
        episodes[1] = episodes[0]
        XCTAssertNil(saikiEpisodes(source: season(episodes, id: 79808, number: 1)))
        episodes = saikiSeason().episodes
        episodes[0] = sourceEpisode(id: 999, number: 1, season: 1, date: "2016-07-11")
        XCTAssertNil(saikiEpisodes(source: season(episodes, id: 79808, number: 1)))
        episodes = saikiSeason().episodes
        episodes[5] = sourceEpisode(id: episodes[5].id, number: 6, season: 1, date: "2016-02-30")
        XCTAssertNil(saikiEpisodes(source: season(episodes, id: 79808, number: 1)))
    }

    func testRazbliutoFeatureUsesMovieMetadataWithoutPartOneCoordinates() throws {
        let movie = try movieFixture()
        let feature = try XCTUnwrap(featureEpisode(movie))
        XCTAssertEqual(feature.runtime, 89)
        XCTAssertEqual(feature.airDate, "2024-01-09")
        XCTAssertEqual(feature.stillPath, "/film-backdrop.jpg")
        XCTAssertEqual(feature.description, "Whole feature synopsis")
        XCTAssertNil(feature.tmdbSeasonNumber)
        XCTAssertNil(feature.tmdbEpisodeNumber)
        XCTAssertEqual(feature.unitProjection?.edition, .feature)
        XCTAssertEqual(feature.unitProjection?.tmdbMovieID, 1220441)
        XCTAssertEqual(feature.unitProjection?.canonicalAniListEpisodeRange?.range, 1...1)
        XCTAssertEqual(feature.unitProjection?.canonicalMALEpisodeRange?.range, 1...4)
    }

    func testRazbliutoRejectsForeignMovieAndQuarterRuntime() throws {
        XCTAssertNil(featureEpisode(try movieFixture(id: 93816)))
        XCTAssertNil(featureEpisode(try movieFixture(runtime: 24)))
        XCTAssertNil(featureEpisode(try movieFixture(imdb: "tt00000000")))
        XCTAssertFalse(AnimeVerifiedEpisodeUnitPolicy.requiresRazbliutoFeature(
            tmdbShowID: 93816, aniListID: 170935, malID: 57184, episodeCount: 4,
            format: "ONA", status: "FINISHED", startDate: "2024-02-23"))
    }

    func testRazbliutoMALPartsKeepExplicitFeatureCoverage() throws {
        let episodes = try XCTUnwrap(partsEpisodes(partsSeason()))
        XCTAssertEqual(episodes.count, 4)
        XCTAssertEqual(episodes.map(\.tmdbEpisodeNumber), [1, 2, 3, 4])
        XCTAssertTrue(episodes.allSatisfy { $0.runtime == 24 && $0.unitProjection?.edition == .featurePart })
        XCTAssertEqual(episodes.map { $0.unitProjection?.physicalPartOrdinal }, [1, 2, 3, 4])
        XCTAssertTrue(episodes.allSatisfy { $0.unitProjection?.physicalPartCount == 4
            && $0.unitProjection?.canonicalAniListEpisodeRange?.range == 1...1 })
        XCTAssertEqual(episodes.map { $0.unitProjection?.canonicalMALEpisodeRange?.upperBound }, [1, 2, 3, 4])
        XCTAssertEqual(AnimeVerifiedEpisodeUnitPolicy.canonicalAniListCount(episodes), 1)
        XCTAssertEqual(AnimeVerifiedEpisodeUnitPolicy.canonicalMALCount(episodes), 4)
    }

    func testRazbliutoPartsRejectMissingOrDuplicatedInventory() {
        var episodes = partsSeason().episodes
        episodes.removeLast()
        XCTAssertNil(partsEpisodes(season(episodes, id: 380779, number: 2)))
        episodes = partsSeason().episodes
        episodes[3] = episodes[0]
        XCTAssertNil(partsEpisodes(season(episodes, id: 380779, number: 2)))
    }

    func testProjectionDecodingFailsClosedForMalformedOrUnknownStoredUnits() throws {
        let payloads = [
            #"{"edition":"futureFormat","canonicalAniListEpisodeRange":{"lowerBound":1,"upperBound":5}}"#,
            #"{"edition":"compilation","canonicalAniListEpisodeRange":{"lowerBound":6,"upperBound":5}}"#,
            #"{"edition":"compilation","canonicalAniListEpisodeRange":{"lowerBound":1,"upperBound":5},"canonicalMALEpisodeRange":"invalid"}"#,
            #"{"edition":"feature","tmdbMovieID":-1,"canonicalAniListEpisodeRange":{"lowerBound":1,"upperBound":1}}"#,
            #"{"edition":"featurePart","physicalPartOrdinal":5,"physicalPartCount":4,"canonicalAniListEpisodeRange":{"lowerBound":1,"upperBound":1}}"#,
            #"{"edition":"compilation","canonicalAniListEpisodeRange":{"lowerBound":1,"upperBound":2147483647}}"#
        ]
        for payload in payloads {
            let projection = try JSONDecoder().decode(AnimeEpisodeUnitProjection.self, from: Data(payload.utf8))
            XCTAssertEqual(projection.edition, .unverified)
            XCTAssertNil(projection.canonicalAniListEpisodeRange)
            XCTAssertNil(projection.tmdbMovieID)
        }
    }

    func testStoredProjectionRemainsBoundToCanonicalIdentityAndExactPhysicalUnit() throws {
        let episode = try XCTUnwrap(saikiEpisodes(source: saikiSeason())?[1])
        let projection = try XCTUnwrap(episode.unitProjection)
        XCTAssertTrue(AnimeVerifiedEpisodeUnitPolicy.validatesProjection(projection, tmdbShowID: 67676,
            aniListID: 21804, malID: 33255, localEpisodeNumber: 2, tmdbSeasonNumber: 1, tmdbEpisodeNumber: 2))
        XCTAssertFalse(AnimeVerifiedEpisodeUnitPolicy.validatesProjection(projection, tmdbShowID: 67676,
            aniListID: 98034, malID: 33255, localEpisodeNumber: 2, tmdbSeasonNumber: 1, tmdbEpisodeNumber: 2))
        XCTAssertFalse(AnimeVerifiedEpisodeUnitPolicy.validatesProjection(projection, tmdbShowID: 67676,
            aniListID: 21804, malID: 33255, localEpisodeNumber: 3, tmdbSeasonNumber: 1, tmdbEpisodeNumber: 3))
        XCTAssertFalse(AnimeVerifiedEpisodeUnitPolicy.validatesProjection(projection, tmdbShowID: 67676,
            aniListID: 21804, malID: 33255, localEpisodeNumber: 2, tmdbSeasonNumber: nil, tmdbEpisodeNumber: nil))
    }

    func testLegacyEpisodeDecodesWithoutAUnitProjection() throws {
        let payload = #"{"number":6,"title":"Legacy short","seasonNumber":1}"#
        let episode = try JSONDecoder().decode(AniListEpisode.self, from: Data(payload.utf8))
        XCTAssertEqual(episode.number, 6)
        XCTAssertNil(episode.unitProjection)
    }

    func testOngoingSingleRootCannotClaimMoreSourceUnitsThanActualInventory() {
        let source = (1...24).map { sourceEpisode(id: $0, number: $0, season: 1, date: "2026-01-01") }
        XCTAssertNil(AnimeStructurePolicy.verifiedOngoingEpisodeCounts(
            hasExactRootIdentity: true, hasTrustedOrdinaryCourRoster: true, hasOrdinaryContinuationAmbiguity: false,
            mediaFormats: ["TV"], statuses: ["RELEASING"], episodeCounts: [120], providerStartDates: ["2026-01-01"],
            tmdbSeasonEpisodeCounts: [1: 24], sourceEpisodes: source, today: "2026-10-12"))
    }

    func testOngoingMultipleCourDeclaredFutureTailStillKeepsProvenSourcePrefix() {
        let dates = Array(repeating: "2026-01-01", count: 24) + Array(repeating: "2026-01-25", count: 13)
            + Array(repeating: "2026-02-07", count: 13) + Array(repeating: "2026-02-20", count: 5)
        let source = dates.enumerated().map { sourceEpisode(id: $0.offset + 1, number: $0.offset + 1, season: 1, date: $0.element) }
        XCTAssertEqual(AnimeStructurePolicy.verifiedOngoingEpisodeCounts(
            hasExactRootIdentity: true, hasTrustedOrdinaryCourRoster: true, hasOrdinaryContinuationAmbiguity: false,
            mediaFormats: ["TV", "TV", "TV", "TV"], statuses: ["FINISHED", "FINISHED", "FINISHED", "RELEASING"],
            episodeCounts: [24, 13, 13, 13], providerStartDates: ["2026-01-01", "2026-01-25", "2026-02-07", "2026-02-20"],
            tmdbSeasonEpisodeCounts: [1: 55], sourceEpisodes: source, today: "2026-10-12"), [24, 13, 13, 13])
    }

    private func saikiEpisodes(source: TMDBSeasonDetail, aniListID: Int = 21804, count: Int = 120,
        uniqueOwner: Bool = true, status: String = "FINISHED") -> [AniListEpisode]? {
        AnimeVerifiedEpisodeUnitPolicy.saikiCompiledEpisodes(tmdbShowID: 67676, aniListID: aniListID, malID: 33255,
            episodeCount: count, format: "TV_SHORT", status: status, startDate: "2016-07-04", endDate: "2016-12-26",
            hasUniqueSourceOwner: uniqueOwner, sourceSeason: source, displaySeasonNumber: 1)
    }

    private func playbackContext(_ episode: AniListEpisode, aniListID: Int, malID: Int, count: Int) -> EpisodePlaybackContext {
        EpisodePlaybackContext(localSeasonNumber: episode.seasonNumber, localEpisodeNumber: episode.number,
            anilistMediaId: aniListID, canonicalAniListMediaId: aniListID, malMediaId: malID,
            tmdbSeasonNumber: episode.tmdbSeasonNumber, tmdbEpisodeNumber: episode.tmdbEpisodeNumber,
            tmdbEpisodeOffset: nil, animeAbsoluteEpisodeNumber: episode.number, animeSeasonEpisodeCount: count,
            isSpecial: false, titleOnlySearch: false, unitProjection: episode.unitProjection)
    }

    private func featureEpisode(_ movie: TMDBMovieDetail) -> AniListEpisode? {
        AnimeVerifiedEpisodeUnitPolicy.razbliutoFeatureEpisode(tmdbShowID: 93816, aniListID: 170935, malID: 57184,
            episodeCount: 1, format: "ONA", status: "FINISHED", startDate: "2024-02-23", movie: movie, displaySeasonNumber: 2)
    }

    private func partsEpisodes(_ source: TMDBSeasonDetail) -> [AniListEpisode]? {
        AnimeVerifiedEpisodeUnitPolicy.razbliutoPartEpisodes(tmdbShowID: 93816, malID: 57184, episodeCount: 4,
            format: "ONA", status: "finished_airing", startDate: "2024-02-23", sourceSeason: source, displaySeasonNumber: 2)
    }

    private func saikiSeason() -> TMDBSeasonDetail {
        let ids = [1219718, 1243370, 1243374, 1243376, 1243377, 1243378, 1243379, 1243380,
            1243381, 1243382, 1243383, 1243384, 1243385, 1243386, 1243387, 1243388,
            1243389, 1243390, 1243391, 1243392, 1370413, 1370415, 1370416, 1370417]
        let dates = ["2016-07-11", "2016-07-18", "2016-07-25", "2016-08-01", "2016-08-08", "2016-08-15",
            "2016-08-22", "2016-08-29", "2016-09-05", "2016-09-12", "2016-09-19", "2016-09-26",
            "2016-10-03", "2016-10-10", "2016-10-17", "2016-10-24", "2016-10-31", "2016-11-14",
            "2016-11-21", "2016-11-28", "2016-12-05", "2016-12-12", "2016-12-19", "2016-12-26"]
        return season(ids.enumerated().map { sourceEpisode(id: $0.element, number: $0.offset + 1, season: 1,
            date: dates[$0.offset], runtime: 23) }, id: 79808, number: 1)
    }

    private func partsSeason() -> TMDBSeasonDetail {
        season((1...4).map { sourceEpisode(id: 5167932 + $0, number: $0, season: 2,
            date: "2024-02-23", runtime: 24) }, id: 380779, number: 2)
    }

    private func sourceEpisode(id: Int, number: Int, season: Int, date: String, runtime: Int = 23) -> TMDBEpisode {
        TMDBEpisode(id: id, name: "Source unit \(number)", overview: "Actual unit synopsis", stillPath: "/unit.jpg",
            episodeNumber: number, seasonNumber: season, airDate: date, runtime: runtime, voteAverage: 8, voteCount: 10)
    }

    private func season(_ episodes: [TMDBEpisode], id: Int, number: Int) -> TMDBSeasonDetail {
        TMDBSeasonDetail(id: id, name: "Source edition", overview: "", posterPath: nil,
            seasonNumber: number, airDate: episodes.first?.airDate, episodes: episodes)
    }

    private func movieFixture(id: Int = 1220441, runtime: Int = 89, imdb: String = "tt30827040") throws -> TMDBMovieDetail {
        let payload: [String: Any] = ["id": id, "title": "GREAT PRETENDER razbliuto", "original_title": "GREAT PRETENDER razbliuto",
            "overview": "Whole feature synopsis", "backdrop_path": "/film-backdrop.jpg", "release_date": "2024-01-09",
            "vote_average": 7, "popularity": 10, "runtime": runtime, "genres": [["id": 16, "name": "Animation"]],
            "imdb_id": imdb, "original_language": "ja", "adult": false, "vote_count": 30]
        return try JSONDecoder().decode(TMDBMovieDetail.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}

final class AniMapLookupTimingPolicyTests: XCTestCase {
    private actor Events {
        private var counts: [String: Int] = [:]
        func record(_ key: String) { counts[key, default: 0] += 1 }
        func count(_ key: String) -> Int { counts[key, default: 0] }
    }

    func testOnlyTMDBMappingGetsTheMeasuredThreeSecondBudget() {
        XCTAssertEqual(AniMapLookupTimingPolicy.timeout(mappingKey: "tmdb_show"), 3)
        XCTAssertEqual(AniMapLookupTimingPolicy.timeout(mappingKey: "anilist"), 1.5)
        XCTAssertEqual(AniMapLookupTimingPolicy.timeout(mappingKey: "mal"), 2)
    }

    func testHealthyDelayedMappingRetainsExactIdentityWithinNewBudget() async throws {
        let events = Events()
        let mapping = try JSONDecoder().decode(AniMapMapping.self,
            from: Data(#"{"tmdb_show_id":86031,"anilist_id":105333,"tmdb_season":1,"media_type":"TV"}"#.utf8))
        let result = try await AniMapLookupTimingPolicy.perform(
            timeout: AniMapLookupTimingPolicy.timeout(mappingKey: "tmdb_show"),
            onTimeout: { await events.record("timeout") }
        ) {
            try await Task.sleep(nanoseconds: 2_200_000_000)
            return mapping
        }
        XCTAssertEqual(result.anilistId, 105333)
        XCTAssertEqual(result.tmdbShowId, 86031)
        XCTAssertEqual(result.tmdbSeason, 1)
        let timeoutCount = await events.count("timeout")
        XCTAssertEqual(timeoutCount, 0)
    }

    func testSameHealthyDelayExceedsPreviousBudgetAndCancelsTheOperation() async {
        let events = Events()
        do {
            let _: Int = try await AniMapLookupTimingPolicy.perform(timeout: 2,
                onTimeout: { await events.record("timeout") }) {
                do {
                    try await Task.sleep(nanoseconds: 2_200_000_000)
                    return 105333
                } catch {
                    await events.record("cancelled")
                    throw error
                }
            }
            XCTFail("The previous budget must expire before the healthy delayed response")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        let timeoutCount = await events.count("timeout")
        let cancelledCount = await events.count("cancelled")
        XCTAssertEqual(timeoutCount, 1)
        XCTAssertEqual(cancelledCount, 1)
    }

    func testDeadlineAndCallerCancellationRemainBoundedAndDistinct() async {
        let events = Events()
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let _: Int = try await AniMapLookupTimingPolicy.perform(timeout: 0.1,
                onTimeout: { await events.record("timeout") }) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
            XCTFail("A nonresponding operation must expire")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
        let task = Task {
            try await AniMapLookupTimingPolicy.perform(timeout: 3,
                onTimeout: { await events.record("caller-timeout") }) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Caller cancellation must propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let deadlineCount = await events.count("timeout")
        let callerTimeoutCount = await events.count("caller-timeout")
        XCTAssertEqual(deadlineCount, 1)
        XCTAssertEqual(callerTimeoutCount, 0)
    }

    func testTransportTimeoutIsNotReportedAsWallTimerExpiry() async {
        let events = Events()
        do {
            let _: Int = try await AniMapLookupTimingPolicy.perform(timeout: 3,
                onTimeout: { await events.record("timeout") }) { throw URLError(.timedOut) }
            XCTFail("Transport failure must propagate")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        let timeoutCount = await events.count("timeout")
        XCTAssertEqual(timeoutCount, 0)
    }

    func testInvalidDeadlineNeverStartsAnOperationOrEmitsTimerExpiry() async {
        let events = Events()
        for timeout in [Double.nan, Double.infinity, -1, 0, 16] {
            do {
                let _: Int = try await AniMapLookupTimingPolicy.perform(timeout: timeout,
                    onTimeout: { await events.record("timeout") }) {
                    await events.record("operation")
                    return 1
                }
                XCTFail("Invalid deadlines must fail before scheduling work")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .timedOut)
            }
        }
        let operationCount = await events.count("operation")
        let timeoutCount = await events.count("timeout")
        XCTAssertEqual(operationCount, 0)
        XCTAssertEqual(timeoutCount, 0)
    }
}

final class AnimeRelatedNodeLookupPolicyTests: XCTestCase {
    func testHydratedUnmappedNodeAdmissionUsesActualFormatAndCountInsteadOfStaleEdge() {
        let staleEdge = AnimeRelationRolePolicy.admitsHydratedRegularNode(relationType: "SEQUEL",
            mediaFormat: "TV", isMappedRegular: false, episodeCount: 12, status: "FINISHED", tmdbEpisodeCount: 48)
        XCTAssertTrue(staleEdge)
        XCTAssertFalse(AnimeRelationRolePolicy.admitsHydratedRegularNode(relationType: "SEQUEL",
            mediaFormat: "MOVIE", isMappedRegular: false, episodeCount: 12, status: "FINISHED", tmdbEpisodeCount: 48))
        XCTAssertFalse(AnimeRelationRolePolicy.admitsHydratedRegularNode(relationType: "SEQUEL",
            mediaFormat: "TV", isMappedRegular: false, episodeCount: 100, status: "FINISHED", tmdbEpisodeCount: 48))
        XCTAssertFalse(AnimeRelationRolePolicy.admitsHydratedRegularNode(relationType: "SEQUEL",
            mediaFormat: nil, isMappedRegular: false, episodeCount: 12, status: "FINISHED", tmdbEpisodeCount: 48))
        XCTAssertFalse(AnimeRelationRolePolicy.admitsHydratedRegularNode(relationType: "ALTERNATIVE",
            mediaFormat: "TV", isMappedRegular: true, episodeCount: 12, status: "FINISHED", tmdbEpisodeCount: 48))
        XCTAssertTrue(AnimeRelationRolePolicy.admitsHydratedRegularNode(relationType: "SEQUEL",
            mediaFormat: "OVA", isMappedRegular: true, episodeCount: 2, status: "FINISHED", tmdbEpisodeCount: 48))
        XCTAssertTrue(AnimeRelationRolePolicy.admitsHydratedRegularNode(relationType: "SEASON",
            mediaFormat: "TV", isMappedRegular: false, episodeCount: 24, status: "NOT_YET_RELEASED", tmdbEpisodeCount: 12))
    }

    func testFailedMappingCanPrefetchExactMultiseasonRootWithoutGrantingCoverage() {
        XCTAssertTrue(shouldLookup())
        XCTAssertTrue(shouldLookup(format: "ONA", status: "RELEASING"))
        XCTAssertFalse(shouldLookup(exactRoot: false))
        XCTAssertFalse(shouldLookup(closed: true))
        XCTAssertFalse(shouldLookup(absolute: true))
        XCTAssertFalse(shouldLookup(count: nil))
        XCTAssertFalse(shouldLookup(count: 48))
        XCTAssertFalse(shouldLookup(count: 120))
        XCTAssertFalse(shouldLookup(format: "MOVIE"))
        XCTAssertFalse(shouldLookup(format: nil))
        XCTAssertFalse(shouldLookup(status: "NOT_YET_RELEASED"))
        XCTAssertFalse(shouldLookup(status: nil))
        XCTAssertFalse(shouldLookup(seasons: [1: 12]))
        XCTAssertFalse(shouldLookup(seasons: [1: 12, 2: 12, 3: 12]))
        XCTAssertFalse(shouldLookup(seasons: [1: 12, 2: 12, 3: 12, 4: 0]))
        XCTAssertFalse(shouldLookup(seasons: [0: 12, 1: 12, 2: 12, 3: 12]))
        XCTAssertFalse(shouldLookup(seasons: [1: 12, 2: 12, 3: 12, 4: Int.max]))
    }

    func testCompletePartialRosterKeepsItsExistingNarrowPrefetchCondition() {
        XCTAssertTrue(shouldLookup(complete: true, rosterCount: 3,
            mapped: [1, 2, 3], seasons: [1: 12, 2: 12, 3: 12, 4: 12, 5: 12, 6: 12, 7: 12]))
        XCTAssertFalse(shouldLookup(complete: true, rosterCount: 2,
            mapped: [1, 2], seasons: [1: 12, 2: 12, 3: 12, 4: 12, 5: 12, 6: 12, 7: 12]))
        XCTAssertFalse(shouldLookup(complete: true, unresolved: true, rosterCount: 3,
            mapped: [1, 2, 3], seasons: [1: 12, 2: 12, 3: 12, 4: 12, 5: 12, 6: 12, 7: 12]))
        XCTAssertFalse(shouldLookup(complete: true, rosterCount: 3,
            mapped: [1, 2, 3, 4], seasons: [1: 12, 2: 12, 3: 12, 4: 12, 5: 12, 6: 12, 7: 12]))
    }

    func testPrefetchedAlternativeAndUnreachableSearchHitsNeverBecomeRegularOwners() async throws {
        let nodes = try JSONDecoder().decode([AniListAnime].self, from: Data(#"[{"id":10,"format":"TV","title":{"romaji":"Root"}},{"id":20,"format":"TV","title":{"romaji":"Root Alternative"},"relations":{"edges":[{"relationType":"ALTERNATIVE","node":{"id":10,"type":"ANIME","format":"TV","title":{"romaji":"Root"}}}]}},{"id":30,"format":"TV","title":{"romaji":"Unrelated Search Hit"},"relations":{"edges":[]}},{"id":40,"format":"TV","title":{"romaji":"Root II"},"relations":{"edges":[{"relationType":"PREQUEL","node":{"id":10,"type":"ANIME","format":"TV","title":{"romaji":"Root"}}}]}}]"#.utf8))
        let root = try XCTUnwrap(nodes.first)
        let lookup = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rejected = await AnimeRelationRolePolicy.firstAdmittedSupplementalEntry(
            candidates: Array(nodes[1...2]), regularMappedIDs: [], existingEntries: [root], prefetched: lookup
        ) { _ in
            XCTFail("A hydrated Page node must not be fetched again")
            return nil
        }
        XCTAssertNil(rejected)
        let accepted = await AnimeRelationRolePolicy.firstAdmittedSupplementalEntry(
            candidates: Array(nodes.dropFirst()), regularMappedIDs: [], existingEntries: [root], prefetched: lookup
        ) { _ in
            XCTFail("A hydrated Page node must not be fetched again")
            return nil
        }
        XCTAssertEqual(accepted?.id, 40)
    }

    private func shouldLookup(
        closed: Bool = false, absolute: Bool = false, complete: Bool = false,
        unresolved: Bool = false, rosterCount: Int = 0, mapped: Set<Int> = [],
        exactRoot: Bool = true, count: Int? = 12, format: String? = "TV", status: String? = "FINISHED",
        seasons: [Int: Int] = [1: 12, 2: 12, 3: 12, 4: 12]
    ) -> Bool {
        AnimeStructurePolicy.shouldPrefetchRelatedNodeLookup(rosterIsClosed: closed,
            startsVerifiedInventoryEarly: absolute, lookupIsComplete: complete,
            hasUnresolvedIdentity: unresolved, mappedRosterCount: rosterCount,
            mappedSeasonNumbers: mapped, hasExactRootIdentity: exactRoot,
            rootEpisodeCount: count, rootFormat: format, rootStatus: status,
            tmdbSeasonEpisodeCounts: seasons)
    }
}

final class AnimeProjectedProviderInventoryPolicyTests: XCTestCase {
    func testCompilationRequiresCompleteUniquePhysicalRoster() {
        let context = compilationContext(number: 6)
        let physical = rows(count: 24, season: 1)
        XCTAssertTrue(allowed(context, rows: physical))
        XCTAssertEqual(AnimeProjectedProviderInventoryPolicy.targetIdentifier(context: context, isMovie: false, rows: physical), "unit-6")
        XCTAssertFalse(allowed(context, rows: rows(count: 120, season: 1)))
        XCTAssertFalse(allowed(context, rows: Array(physical.prefix(6))))
        XCTAssertFalse(allowed(context, rows: []))
        XCTAssertFalse(allowed(context, rows: rows(count: 24, season: 2)))
        XCTAssertTrue(allowed(context, rows: rows(count: 24, season: nil)))
    }

    func testDuplicateMixedAndMalformedCompilationListsCannotAutoSelect() {
        let context = compilationContext(number: 6)
        var physical = rows(count: 24, season: 1)
        physical[23] = .init(identifier: "unit-24", seasonNumber: 1, episodeNumber: 23)
        XCTAssertFalse(allowed(context, rows: physical))
        physical = rows(count: 24, season: 1)
        physical[23] = .init(identifier: " unit-1 ", seasonNumber: 1, episodeNumber: 24)
        XCTAssertFalse(allowed(context, rows: physical))
        physical = rows(count: 24, season: 1)
        physical[23] = .init(identifier: "unit-24", seasonNumber: nil, episodeNumber: 24)
        XCTAssertFalse(allowed(context, rows: physical))
        physical = rows(count: 24, season: nil)
        physical[23] = .init(identifier: "unit-24", seasonNumber: nil, episodeNumber: nil)
        XCTAssertFalse(allowed(context, rows: physical))
        physical = rows(count: 24, season: 1)
        physical[23] = .init(identifier: " ", seasonNumber: 1, episodeNumber: 24)
        XCTAssertFalse(allowed(context, rows: physical))
    }

    func testPartsRequireFourActualRowsAndSelectThePhysicalPart() {
        let context = partContext(number: 3)
        let physical = rows(count: 4, season: 2)
        XCTAssertTrue(allowed(context, rows: physical))
        XCTAssertEqual(AnimeProjectedProviderInventoryPolicy.targetIdentifier(context: context, isMovie: false, rows: physical), "unit-3")
        XCTAssertFalse(allowed(context, rows: Array(physical.prefix(1))))
        XCTAssertFalse(allowed(context, rows: rows(count: 24, season: 2)))
        XCTAssertFalse(allowed(context, rows: physical, isMovie: true))
        var mixed = physical
        mixed[3] = .init(identifier: "unit-4", seasonNumber: 1, episodeNumber: 4)
        XCTAssertFalse(allowed(context, rows: mixed))
    }

    func testFeatureNeverSelectsTheFirstTVPartOrDefaultPartHint() {
        let context = featureContext()
        XCTAssertFalse(allowed(context, rows: rows(count: 4, season: nil), isMovie: true))
        XCTAssertNil(AnimeProjectedProviderInventoryPolicy.targetIdentifier(context: context, isMovie: true,
            rows: rows(count: 4, season: nil)))
        XCTAssertFalse(allowed(context, rows: rows(count: 1, season: 2), isMovie: true))
        let feature = [AnimeProjectedProviderInventoryPolicy.Row(identifier: "whole-movie", seasonNumber: nil, episodeNumber: nil)]
        XCTAssertTrue(allowed(context, rows: feature, isMovie: true))
        XCTAssertEqual(AnimeProjectedProviderInventoryPolicy.targetIdentifier(context: context, isMovie: true, rows: feature), "whole-movie")
        XCTAssertFalse(allowed(context, rows: feature, isMovie: false))
        XCTAssertFalse(allowed(context, rows: [], isMovie: true))
        XCTAssertTrue(AnimeProjectedProviderInventoryPolicy.allowsAutomaticSelection(
            context: context, isMovie: true, rows: [], allowsEmptyMovieEndpoint: true))
    }

    func testUnverifiedAndForeignProviderIdentityNeverAuthorizeCatalogFallback() {
        let physical = rows(count: 24, season: 1)
        let valid = compilationContext(number: 6)
        let foreign = EpisodePlaybackContext(localSeasonNumber: 1, localEpisodeNumber: 6,
            anilistMediaId: 98034, canonicalAniListMediaId: 98034, malMediaId: 34612,
            tmdbSeasonNumber: 1, tmdbEpisodeNumber: 6, tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: 6, animeSeasonEpisodeCount: 24, isSpecial: false,
            titleOnlySearch: false, unitProjection: valid.unitProjection)
        XCTAssertFalse(allowed(foreign, rows: physical))
        let unverified = EpisodePlaybackContext(localSeasonNumber: 1, localEpisodeNumber: 6,
            anilistMediaId: 21804, canonicalAniListMediaId: 21804, malMediaId: 33255,
            tmdbSeasonNumber: 1, tmdbEpisodeNumber: 6, tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: 6, animeSeasonEpisodeCount: 24, isSpecial: false,
            titleOnlySearch: false, unitProjection: .init(edition: .unverified,
                canonicalAniListEpisodeRange: nil, canonicalMALEpisodeRange: nil))
        XCTAssertFalse(allowed(unverified, rows: physical))
        XCTAssertTrue(AnimeProjectedProviderInventoryPolicy.allowsAutomaticSelection(
            context: nil, isMovie: false, rows: rows(count: 120, season: 1)))
    }

    private func allowed(_ context: EpisodePlaybackContext, rows: [AnimeProjectedProviderInventoryPolicy.Row],
        isMovie: Bool = false) -> Bool {
        AnimeProjectedProviderInventoryPolicy.allowsAutomaticSelection(context: context, isMovie: isMovie, rows: rows)
    }

    private func rows(count: Int, season: Int?) -> [AnimeProjectedProviderInventoryPolicy.Row] {
        (1...count).map { .init(identifier: "unit-\($0)", seasonNumber: season, episodeNumber: $0) }
    }

    private func compilationContext(number: Int) -> EpisodePlaybackContext {
        let range = AnimeVerifiedEpisodeUnitPolicy.saikiCanonicalGroups[number - 1]
        return EpisodePlaybackContext(localSeasonNumber: 1, localEpisodeNumber: number,
            anilistMediaId: 21804, canonicalAniListMediaId: 21804, malMediaId: 33255,
            tmdbSeasonNumber: 1, tmdbEpisodeNumber: number, tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: number, animeSeasonEpisodeCount: 24, isSpecial: false,
            titleOnlySearch: false, unitProjection: .init(edition: .compilation,
                canonicalAniListEpisodeRange: range, canonicalMALEpisodeRange: range))
    }

    private func partContext(number: Int) -> EpisodePlaybackContext {
        EpisodePlaybackContext(localSeasonNumber: 2, localEpisodeNumber: number,
            anilistMediaId: 170935, canonicalAniListMediaId: 170935, malMediaId: 57184,
            tmdbSeasonNumber: 2, tmdbEpisodeNumber: number, tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: number, animeSeasonEpisodeCount: 4, isSpecial: false,
            titleOnlySearch: false, unitProjection: .init(edition: .featurePart,
                canonicalAniListEpisodeRange: .init(lowerBound: 1, upperBound: 1),
                canonicalMALEpisodeRange: .init(lowerBound: number, upperBound: number),
                physicalPartOrdinal: number, physicalPartCount: 4))
    }

    private func featureContext() -> EpisodePlaybackContext {
        EpisodePlaybackContext(localSeasonNumber: 2, localEpisodeNumber: 1,
            anilistMediaId: 170935, canonicalAniListMediaId: 170935, malMediaId: 57184,
            tmdbSeasonNumber: nil, tmdbEpisodeNumber: nil, tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: 1, animeSeasonEpisodeCount: 1, isSpecial: false,
            titleOnlySearch: true, unitProjection: .init(edition: .feature,
                canonicalAniListEpisodeRange: .init(lowerBound: 1, upperBound: 1),
                canonicalMALEpisodeRange: .init(lowerBound: 1, upperBound: 4), tmdbMovieID: 1220441))
    }
}

final class AnimeUnitUpNextCacheKeyTests: XCTestCase {
    func testLegacyCuratedUnitsCannotBypassResolverWhileOrdinarySeasonsKeepTheirCache() {
        XCTAssertTrue(UpNextResolutionCache.requiresProjectedCurrentContext(showId: 67676, seasonNumber: 1, playbackContext: nil))
        XCTAssertFalse(UpNextResolutionCache.requiresProjectedCurrentContext(showId: 67676, seasonNumber: 2, playbackContext: nil))
        XCTAssertTrue(UpNextResolutionCache.requiresProjectedCurrentContext(showId: 93816, seasonNumber: 2, playbackContext: nil))
        XCTAssertFalse(UpNextResolutionCache.requiresProjectedCurrentContext(showId: 93816, seasonNumber: 1, playbackContext: nil))
        XCTAssertEqual(UpNextResolutionCache.key(showId: 67676, seasonNumber: 2, episodeNumber: 6), "67676:2:6")
        XCTAssertEqual(UpNextResolutionCache.key(showId: 93816, seasonNumber: 1, episodeNumber: 6), "93816:1:6")
        let legacy = EpisodePlaybackContext(localSeasonNumber: 1, localEpisodeNumber: 6,
            anilistMediaId: 21804, canonicalAniListMediaId: 21804, malMediaId: 33255,
            tmdbSeasonNumber: nil, tmdbEpisodeNumber: nil, tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: 6, animeSeasonEpisodeCount: 120, isSpecial: false, titleOnlySearch: false)
        let syntheticSeason = AnimeSyntheticSeasonKey.make(providerID: 21804) ?? 1
        let unresolvedKey = UpNextResolutionCache.key(showId: 67676, seasonNumber: syntheticSeason,
            episodeNumber: 6, playbackContext: legacy)
        XCTAssertTrue(unresolvedKey.hasSuffix(":units-v1:unresolved"))
        XCTAssertNil(UpNextResolutionCache.shared.resolution(forKey: unresolvedKey, profile: UUID()))
        XCTAssertTrue(UpNextResolutionCache.key(showId: 67676, seasonNumber: syntheticSeason,
            episodeNumber: 6).hasSuffix(":units-v1:unresolved"))
    }

    func testLegacyShortAndCompiledCurrentEpisodeNeverShareUpNextCacheEntry() {
        let legacy = UpNextResolutionCache.key(showId: 67676, seasonNumber: 1, episodeNumber: 6)
        let projected = UpNextResolutionCache.key(showId: 67676, seasonNumber: 1, episodeNumber: 6,
            playbackContext: compilationContext(number: 6))
        XCTAssertEqual(legacy, "67676:1:6:units-v1:unresolved")
        XCTAssertEqual(UpNextResolutionCache.key(showId: 86031, seasonNumber: 1, episodeNumber: 6), "86031:1:6")
        XCTAssertNotEqual(projected, legacy)
        XCTAssertTrue(projected.hasPrefix("67676:1:6:units-v1:"))
        XCTAssertLessThanOrEqual(projected.utf8.count, 128)
        XCTAssertEqual(projected, UpNextResolutionCache.key(showId: 67676, seasonNumber: 1, episodeNumber: 6,
            playbackContext: compilationContext(number: 6)))
        XCTAssertNotEqual(projected, UpNextResolutionCache.key(showId: 67676, seasonNumber: 1, episodeNumber: 7,
            playbackContext: compilationContext(number: 7)))
    }

    func testMalformedOrForeignUnitContextCannotUseLegacyCacheNamespace() {
        let valid = compilationContext(number: 6)
        let wrongCoordinate = UpNextResolutionCache.key(showId: 67676, seasonNumber: 1, episodeNumber: 7,
            playbackContext: valid)
        let wrongShow = UpNextResolutionCache.key(showId: 93816, seasonNumber: 1, episodeNumber: 6,
            playbackContext: valid)
        XCTAssertTrue(wrongCoordinate.hasSuffix(":units-v1:invalid"))
        XCTAssertTrue(wrongShow.hasSuffix(":units-v1:invalid"))
        XCTAssertNotEqual(wrongCoordinate, UpNextResolutionCache.key(showId: 67676, seasonNumber: 1, episodeNumber: 7))
        let unverified = EpisodePlaybackContext(localSeasonNumber: 1, localEpisodeNumber: 6,
            anilistMediaId: 21804, canonicalAniListMediaId: 21804, malMediaId: 33255,
            tmdbSeasonNumber: 1, tmdbEpisodeNumber: 6, tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: 6, animeSeasonEpisodeCount: 24, isSpecial: false,
            titleOnlySearch: false, unitProjection: .init(edition: .unverified,
                canonicalAniListEpisodeRange: nil, canonicalMALEpisodeRange: nil))
        XCTAssertTrue(UpNextResolutionCache.key(showId: 67676, seasonNumber: 1, episodeNumber: 6,
            playbackContext: unverified).hasSuffix(":units-v1:invalid"))
    }

    private func compilationContext(number: Int) -> EpisodePlaybackContext {
        let range = AnimeVerifiedEpisodeUnitPolicy.saikiCanonicalGroups[number - 1]
        return EpisodePlaybackContext(localSeasonNumber: 1, localEpisodeNumber: number,
            anilistMediaId: 21804, canonicalAniListMediaId: 21804, malMediaId: 33255,
            tmdbSeasonNumber: 1, tmdbEpisodeNumber: number, tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: number, animeSeasonEpisodeCount: 24, isSpecial: false,
            titleOnlySearch: false, unitProjection: .init(edition: .compilation,
                canonicalAniListEpisodeRange: range, canonicalMALEpisodeRange: range))
    }
}

final class AnimeMALSpecialBridgePolicyTests: XCTestCase {
    func testUnmappedOngoingTVChainRetainsOnlyActualPhysicalPrefix() throws {
        let source = ongoingSource()
        XCTAssertEqual(ongoingCounts(source: source), [2, 2, 2, 3])
        let episodesByAbsolute = Dictionary(uniqueKeysWithValues: source.enumerated().map { ($0.offset + 1, $0.element) })
        let coordinates = episodesByAbsolute.mapValues {
            AnimeStructureTMDBCoordinate(seasonNumber: $0.seasonNumber, episodeNumber: $0.episodeNumber)
        }
        let episodes = AnimeSeasonEpisodeHydrationPolicy.episodes(count: 3, displaySeasonNumber: 4,
            startingAt: 7, tmdbEpisodes: episodesByAbsolute, tmdbCoordinates: coordinates, allowsTMDBCoordinates: true)
        XCTAssertEqual(episodes.map(\.tmdbEpisodeNumber), [7, 8, nil])
        XCTAssertEqual(episodes.map(\.number), [1, 2, 3])
        XCTAssertNil(episodes.last?.airDate)
        var future = source
        future[7] = sourceEpisode(8, season: 1, number: 8, date: "2026-10-17")
        XCTAssertEqual(ongoingCounts(source: future), [2, 2, 2, 3])
    }

    func testUnmappedOngoingProofRejectsForeignUnitsAndBrokenOwnershipChain() {
        let source = ongoingSource()
        XCTAssertNil(ongoingCounts(source: source, exactRoot: false))
        XCTAssertNil(ongoingCounts(source: source, complete: false))
        XCTAssertNil(ongoingCounts(source: source, competing: true))
        for format in ["ONA", "TV_SHORT", "SPECIAL", nil] {
            var entries = ongoingEntries()
            entries[1] = entry(2, format: format, count: 2, start: "2023-01-08", end: "2023-01-15", prequels: [1], sequels: [3])
            XCTAssertNil(ongoingCounts(source: source, entries: entries))
        }
        let rejected = [
            entry(2, count: 2, start: "2023-01-08", end: "2023-01-15", prequels: [], sequels: [3]),
            entry(2, count: 2, start: "2023-01-08", end: "2023-01-15", prequels: [1], sequels: [3, 5]),
            entry(2, count: 2, status: "currently_airing", start: "2023-01-08", end: "2023-01-15", prequels: [1], sequels: [3]),
            entry(2, count: nil, start: "2023-01-08", end: "2023-01-15", prequels: [1], sequels: [3]),
            entry(2, count: 2, start: "2023-01-08", end: "2023-01-15", prequels: [1], sequels: [3], foreign: true)
        ]
        for candidate in rejected {
            var entries = ongoingEntries()
            entries[1] = candidate
            XCTAssertNil(ongoingCounts(source: source, entries: entries))
        }
        var unknownLast = ongoingEntries()
        unknownLast[3] = entry(4, count: nil, status: "currently_airing", start: "2026-10-03", prequels: [3])
        XCTAssertNil(ongoingCounts(source: source, entries: unknownLast))
    }

    func testUnmappedOngoingProofRejectsDatePaddingAndIncompleteActualInventory() {
        let source = ongoingSource()
        for candidate in [
            entry(2, count: 2, start: "2023-01-09", end: "2023-01-15", prequels: [1], sequels: [3]),
            entry(2, count: 2, start: "2023-01-08", end: "2023-01-16", prequels: [1], sequels: [3]),
            entry(2, count: 2, start: "2023-02-30", end: "2023-01-15", prequels: [1], sequels: [3])
        ] {
            var entries = ongoingEntries()
            entries[1] = candidate
            XCTAssertNil(ongoingCounts(source: source, entries: entries))
        }
        XCTAssertNil(ongoingCounts(source: Array(source.dropLast())))
        var duplicate = source
        duplicate[7] = duplicate[6]
        XCTAssertNil(ongoingCounts(source: duplicate))
        var skipped = source
        skipped[7] = sourceEpisode(8, season: 1, number: 9, date: "2026-10-10")
        XCTAssertNil(ongoingCounts(source: skipped))
        var malformed = source
        malformed[7] = sourceEpisode(8, season: 1, number: 8, date: "2026-02-30")
        XCTAssertNil(ongoingCounts(source: malformed))
        var reversed = source
        reversed[7] = sourceEpisode(8, season: 1, number: 8, date: "2026-10-02")
        XCTAssertNil(ongoingCounts(source: reversed))
        XCTAssertNil(ongoingCounts(source: source, today: "2026-10-02"))
    }

    private func ongoingEntries() -> [AnimeMALFallbackRelationPolicy.BridgeEntry] {
        [entry(1, count: 2, start: "2021-01-11", end: "2021-01-18", sequels: [2]),
            entry(2, count: 2, start: "2023-01-08", end: "2023-01-15", prequels: [1], sequels: [3]),
            entry(3, count: 2, start: "2023-10-04", end: "2023-10-11", prequels: [2], sequels: [4]),
            entry(4, count: 3, status: "currently_airing", start: "2026-10-03", end: "2026-10-24", prequels: [3])]
    }

    private func ongoingSource() -> [TMDBEpisode] {
        ["2021-01-11", "2021-01-18", "2023-01-08", "2023-01-15", "2023-10-04", "2023-10-11", "2026-10-03", "2026-10-10"]
            .enumerated().map { sourceEpisode($0.offset + 1, season: 1, number: $0.offset + 1, date: $0.element) }
    }

    private func ongoingCounts(source: [TMDBEpisode], entries: [AnimeMALFallbackRelationPolicy.BridgeEntry]? = nil,
        exactRoot: Bool = true, complete: Bool = true, competing: Bool = false, today: String = "2026-10-12") -> [Int]? {
        AnimeMALFallbackRelationPolicy.verifiedUnmappedOngoingEpisodeCounts(hasExactRootIdentity: exactRoot,
            graphIsComplete: complete, hasCompetingOwner: competing, entries: entries ?? ongoingEntries(),
            tmdbSeasonEpisodeCounts: [1: 8], sourceEpisodes: source, today: today)
    }

    func testReciprocalSingleEpisodeSpecialRestoresOrdinaryReachabilityWithoutAddingItsCount() throws {
        let bridge = entry(55818, format: "SPECIAL", count: 1, start: "2023-07-03", end: "2023-07-03", prequels: [45576], sequels: [51179])
        let prior = entry(45576, count: 12, start: "2021-10-04", end: "2021-12-20", sequels: [55818])
        let next = entry(51179, count: 12, start: "2023-07-10", end: "2023-09-25", prequels: [55818])
        XCTAssertEqual(AnimeMALFallbackRelationPolicy.specialBridgeOppositeID(bridge, current: next), 45576)
        let constraint = try XCTUnwrap(AnimeMALFallbackRelationPolicy.verifiedSpecialBridge(bridge, prequel: prior, sequel: next))
        XCTAssertEqual(constraint.beforeID, 45576)
        XCTAssertEqual(constraint.afterID, 51179)
        XCTAssertEqual(AnimeStructurePolicy.ordinaryConnectedIDs(rootID: 51179, candidateIDs: [39535, 45576, 51179],
            constraints: [constraint, .init(beforeID: 39535, afterID: 45576)]), [39535, 45576, 51179])
    }

    func testForeignPilotAmbiguousAndOneSidedBridgesCannotJoinOrdinaryOwners() {
        let prior = entry(45576, count: 12, start: "2021-10-04", end: "2021-12-20", sequels: [55818])
        let next = entry(51179, count: 12, start: "2023-07-10", end: "2023-09-25", prequels: [55818])
        let rejected = [
            entry(55818, format: "MOVIE", count: 1, prequels: [45576], sequels: [51179]),
            entry(55818, format: nil, count: 1, prequels: [45576], sequels: [51179]),
            entry(55818, format: "SPECIAL", count: nil, prequels: [45576], sequels: [51179]),
            entry(55818, format: "SPECIAL", count: 2, prequels: [45576], sequels: [51179]),
            entry(55818, format: "SPECIAL", count: 1, prequels: [45576, 39535], sequels: [51179]),
            entry(55818, format: "SPECIAL", count: 1, prequels: [45576], sequels: [51179, 55888]),
            entry(55818, format: "SPECIAL", count: 1, prequels: [], sequels: [51179]),
            entry(55818, format: "SPECIAL", count: 1, prequels: [55818], sequels: [51179]),
            entry(55818, format: "SPECIAL", count: 1, start: "2023-02-30", prequels: [45576], sequels: [51179]),
            entry(55818, format: "SPECIAL", count: 1, prequels: [45576], sequels: [51179], foreign: true),
            entry(55818, format: "SPECIAL", count: 1, status: "currently_airing", prequels: [45576], sequels: [51179])
        ]
        for bridge in rejected {
            XCTAssertNil(AnimeMALFallbackRelationPolicy.verifiedSpecialBridge(bridge, prequel: prior, sequel: next))
            XCTAssertNil(AnimeMALFallbackRelationPolicy.specialBridgeOppositeID(bridge, current: next))
        }
        let bridge = entry(55818, format: "SPECIAL", count: 1, prequels: [45576], sequels: [51179])
        XCTAssertNil(AnimeMALFallbackRelationPolicy.verifiedSpecialBridge(bridge,
            prequel: entry(45576, count: 12, start: "2021-10-04", end: "2021-12-20"), sequel: next))
        XCTAssertNil(AnimeMALFallbackRelationPolicy.verifiedSpecialBridge(bridge, prequel: prior,
            sequel: entry(51179, format: "ONA", count: nil, start: "2023-07-10", prequels: [55818])))
        XCTAssertNil(AnimeMALFallbackRelationPolicy.verifiedSpecialBridge(bridge, prequel: prior,
            sequel: entry(51179, count: 12, start: "2023-07-10", prequels: [55818], foreign: true)))
    }

    func testNewBridgeGrantRequiresClosedTVGraphAndWholeActualInventory() {
        let source = [sourceEpisode(1, season: 1, number: 1, date: "2021-01-11"),
            sourceEpisode(2, season: 1, number: 2, date: "2021-01-18"),
            sourceEpisode(3, season: 2, number: 1, date: "2023-07-10"),
            sourceEpisode(4, season: 2, number: 2, date: "2023-07-17")]
        XCTAssertTrue(allows(source: source))
        XCTAssertFalse(allows(source: source, exactRoot: false))
        XCTAssertFalse(allows(source: source, complete: false))
        XCTAssertFalse(allows(source: source, closed: false))
        XCTAssertFalse(allows(source: source, rootStart: "2021-01-12"))
        XCTAssertFalse(allows(source: source, starts: ["2021-01-11", nil, "2023-07-10", nil]))
        XCTAssertFalse(allows(source: source, starts: ["2021-01-11", "2024-01-18", "2023-07-10", nil]))
        XCTAssertFalse(allows(source: source, counts: [1, nil, 2, nil]))
        XCTAssertFalse(allows(source: source, counts: [1, 1, 3, nil]))
        XCTAssertFalse(allows(source: source, formats: ["TV_SHORT", "TV", "TV", "TV"]))
        XCTAssertFalse(allows(source: source, formats: ["TV", "TV", "ONA", "TV"]))
        XCTAssertFalse(allows(source: source, statuses: ["finished_airing", "currently_airing", "finished_airing", "not_yet_aired"]))
        XCTAssertFalse(allows(source: source, statuses: ["finished_airing", "not_yet_aired", "finished_airing", "not_yet_aired"]))
        XCTAssertFalse(allows(source: Array(source.prefix(3))))
        XCTAssertFalse(allows(source: [source[0], source[1], source[2], source[2]]))
        var malformed = source
        malformed[3] = sourceEpisode(4, season: 2, number: 3, date: "2023-07-17")
        XCTAssertFalse(allows(source: malformed))
    }

    private func entry(_ id: Int, format: String? = "TV", count: Int? = 12,
        status: String = "finished_airing", start: String = "2023-07-03", end: String = "2023-07-03",
        prequels: [Int] = [], sequels: [Int] = [], foreign: Bool = false) -> AnimeMALFallbackRelationPolicy.BridgeEntry {
        .init(id: id, format: format, status: status, episodeCount: count, startDate: start, endDate: end,
            prequelIDs: prequels, sequelIDs: sequels, hasForeignMapping: foreign)
    }

    private func sourceEpisode(_ id: Int, season: Int, number: Int, date: String) -> TMDBEpisode {
        .init(id: id, name: "Source episode", overview: nil, stillPath: nil, episodeNumber: number,
            seasonNumber: season, airDate: date, runtime: 24, voteAverage: 0, voteCount: 0)
    }

    private func allows(source: [TMDBEpisode], exactRoot: Bool = true, complete: Bool = true, closed: Bool = true,
        rootStart: String = "2021-01-11", counts: [Int?] = [1, 1, 2, nil],
        starts: [String?] = ["2021-01-11", "2021-01-18", "2023-07-10", nil],
        statuses: [String?] = ["finished_airing", "finished_airing", "finished_airing", "not_yet_aired"],
        formats: [String?] = ["TV", "TV", "TV", "TV"]) -> Bool {
        AnimeMALFallbackRelationPolicy.allowsVerifiedBridgeLinearInventory(hasExactRootIdentity: exactRoot,
            graphIsComplete: complete, hasClosedReciprocalChain: closed, providerStartDate: rootStart,
            providerStartDates: starts,
            episodeCounts: counts, statuses: statuses, mediaFormats: formats,
            tmdbSeasonEpisodeCounts: [1: 2, 2: 2], sourceEpisodes: source)
    }
}

final class AnimeExternalFeatureIdentityDecoderTests: XCTestCase {
    func testExclusiveFilmIdentityRequiresTheWholeUnambiguousFindResponse() throws {
        XCTAssertTrue(try TMDBService.ExclusiveMovieIMDbMatch.decode(moviePayload(), expectedMovieID: 300))
        XCTAssertFalse(try TMDBService.ExclusiveMovieIMDbMatch.decode(moviePayload(), expectedMovieID: 301))
        for field in ["movie_results", "tv_results", "tv_episode_results", "tv_season_results"] {
            var payload = movieObject()
            payload.removeValue(forKey: field)
            XCTAssertThrowsError(try TMDBService.ExclusiveMovieIMDbMatch.decode(encode(payload), expectedMovieID: 300), field)
        }
        for field in ["tv_results", "tv_episode_results", "tv_season_results"] {
            var payload = movieObject()
            payload[field] = [["id": 400]]
            XCTAssertFalse(try TMDBService.ExclusiveMovieIMDbMatch.decode(encode(payload), expectedMovieID: 300), field)
            payload[field] = [["invalid": 400]]
            XCTAssertThrowsError(try TMDBService.ExclusiveMovieIMDbMatch.decode(encode(payload), expectedMovieID: 300), field)
        }
        var multiple = movieObject()
        multiple["movie_results"] = [["id": 300], ["id": 301]]
        XCTAssertFalse(try TMDBService.ExclusiveMovieIMDbMatch.decode(encode(multiple), expectedMovieID: 300))
        multiple["movie_results"] = []
        XCTAssertFalse(try TMDBService.ExclusiveMovieIMDbMatch.decode(encode(multiple), expectedMovieID: 300))
        XCTAssertThrowsError(try TMDBService.ExclusiveMovieIMDbMatch.decode(moviePayload(), expectedMovieID: 0))
        XCTAssertThrowsError(try TMDBService.ExclusiveMovieIMDbMatch.decode(Data(repeating: 32, count: 513 * 1_024), expectedMovieID: 300))
    }

    func testCoincidentEpisodeIdentityMustBindToTheActualSourceEpisode() throws {
        let identity = try TMDBService.EpisodeExternalIdentity.decode(encode(["id": 400, "imdb_id": "tt0000401"]), expectedEpisodeID: 400)
        XCTAssertEqual(identity.id, 400)
        XCTAssertEqual(identity.imdbID, "tt0000401")
        XCTAssertThrowsError(try TMDBService.EpisodeExternalIdentity.decode(encode(["id": 401, "imdb_id": "tt0000401"]), expectedEpisodeID: 400))
        XCTAssertThrowsError(try TMDBService.EpisodeExternalIdentity.decode(encode(["id": 0, "imdb_id": "tt0000401"]), expectedEpisodeID: 0))
        XCTAssertThrowsError(try TMDBService.EpisodeExternalIdentity.decode(encode(["imdb_id": "tt0000401"]), expectedEpisodeID: 400))
        for value in ["", "tt", "tt0", "tt1", "tt401", "tt0000000", "tt0000000000000000000001", "ttabc", "nm0000401", "tt0000401 ", "tt００００４０１"] {
            XCTAssertThrowsError(try TMDBService.EpisodeExternalIdentity.decode(encode(["id": 400, "imdb_id": value]), expectedEpisodeID: 400), value)
        }
        let missing = try TMDBService.EpisodeExternalIdentity.decode(encode(["id": 400, "imdb_id": NSNull()]), expectedEpisodeID: 400)
        XCTAssertNil(missing.imdbID)
        XCTAssertThrowsError(try TMDBService.EpisodeExternalIdentity.decode(Data(repeating: 32, count: 513 * 1_024), expectedEpisodeID: 400))
    }

    private func movieObject() -> [String: Any] {
        ["movie_results": [["id": 300]], "tv_results": [], "tv_episode_results": [], "tv_season_results": []]
    }

    private func moviePayload() throws -> Data { try encode(movieObject()) }

    private func encode(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }
}

final class AnimeOpenEndedActualInventoryTests: XCTestCase {
    func testUnknownOngoingTVRequiresActualMultiseasonCoordinatesWithoutATVDBMarker() {
        XCTAssertTrue(requires())
        XCTAssertTrue(requires(seasons: 65))
        XCTAssertFalse(requires(format: "ONA"))
        XCTAssertFalse(requires(format: "TV_SHORT"))
        XCTAssertFalse(requires(format: nil))
        XCTAssertFalse(requires(status: "finished_airing"))
        XCTAssertFalse(requires(status: "not_yet_aired"))
        XCTAssertFalse(requires(count: 120))
        XCTAssertFalse(requires(entries: 2))
        XCTAssertFalse(requires(seasons: 1))
    }

    func testActualOpenEndedInventoryKeepsAbsoluteNumbersAndRejectsSyntheticMissingSpans() throws {
        let source = [episode(1, season: 1, number: 1, date: "1999-10-20"),
            episode(2, season: 1, number: 2, date: "1999-10-27"),
            episode(3, season: 2, number: 26, date: "2001-03-21"),
            episode(4, season: 2, number: 27, date: "2001-03-28")]
        let verified = try XCTUnwrap(validate(source))
        XCTAssertEqual(verified.map(\.episodeNumber), [1, 2, 26, 27])
        XCTAssertEqual(verified.map(\.seasonNumber), [1, 1, 2, 2])
        XCTAssertNil(validate(source, owner: false))
        XCTAssertNil(validate(source, start: "1999-10-21"))
        XCTAssertNil(validate(Array(source.prefix(2))))
        XCTAssertNil(validate([source[0], source[1], source[2], source[2]]))
        XCTAssertNil(validate([source[0], source[1], source[2], episode(0, season: 2, number: 27, date: "2001-03-28")]))
        XCTAssertNil(validate([source[0], source[1], source[2], episode(4, season: 3, number: 27, date: "2001-03-28")]))
        XCTAssertNil(validate([source[0], source[1], source[2], episode(4, season: 2, number: 0, date: "2001-03-28")]))
        XCTAssertNil(validate([source[0], source[1], source[2], episode(4, season: 2, number: 27, date: "2001-02-30")]))
        XCTAssertNil(validate([source[0], source[1], source[2], episode(4, season: 2, number: 27, date: "1999-10-27")]))
    }

    private func requires(format: String? = "tv", status: String = "currently_airing", count: Int? = nil,
        entries: Int = 1, seasons: Int = 2) -> Bool {
        AnimeStructurePolicy.requiresVerifiedOpenEndedInventory(mediaFormat: format, status: status,
            episodeCount: count, entryCount: entries, tmdbSeasonCount: seasons)
    }

    private func validate(_ episodes: [TMDBEpisode], owner: Bool = true, start: String = "1999-10-20") -> [TMDBEpisode]? {
        AnimeStructurePolicy.verifiedOpenEndedTMDBInventory(hasExclusiveOrdinaryOwner: owner,
            providerStartDate: start, tmdbSeasonEpisodeCounts: [1: 2, 2: 2], sourceEpisodes: episodes)
    }

    private func episode(_ id: Int, season: Int, number: Int, date: String) -> TMDBEpisode {
        .init(id: id, name: "Actual source row", overview: nil, stillPath: nil, episodeNumber: number,
            seasonNumber: season, airDate: date, runtime: 24, voteAverage: 0, voteCount: 0)
    }
}
