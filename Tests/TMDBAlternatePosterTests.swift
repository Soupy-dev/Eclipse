import XCTest
@testable import Eclipse
#if canImport(zlib)
import zlib
#endif

#if os(iOS)
import UIKit

final class TMDBAlternatePosterTests: XCTestCase {
    private let service = TMDBService.shared

    func testRejectsDownvotedLanguageNeutralPoster() {
        let images = response([
            poster(path: "/downvoted.jpg", language: nil, average: 0.5, votes: 5)
        ])

        XCTAssertNil(service.getBestAlternatePoster(from: images, excluding: []))
    }

    func testAcceptsModestlyRatedLanguageNeutralPoster() {
        let images = response([
            poster(path: "/community.jpg", language: nil, average: 2.28, votes: 3)
        ])

        XCTAssertEqual(
            service.getBestAlternatePoster(from: images, excluding: [])?.filePath,
            "/community.jpg"
        )
    }

    func testDownvotedMisuploadLosesToBetterRatedPoster() {
        let images = response([
            poster(path: "/wrong-show.jpg", language: nil, average: 0.5, votes: 5),
            poster(path: "/correct.jpg", language: nil, average: 3.33, votes: 2)
        ])

        XCTAssertEqual(
            service.getBestAlternatePoster(from: images, excluding: [])?.filePath,
            "/correct.jpg"
        )
    }

    func testRejectsLocalizedPosterEvenWhenHighlyRated() {
        let images = response([
            poster(path: "/localized.jpg", language: "en", average: 9, votes: 40)
        ])

        XCTAssertNil(service.getBestAlternatePoster(from: images, excluding: []))
    }

    func testRejectsNonPosterShapedArtworkEvenWhenWellRated() {
        let images = response([
            poster(
                path: "/wide.jpg",
                language: nil,
                average: 8,
                votes: 10,
                aspectRatio: 1.5,
                width: 1200,
                height: 800
            )
        ])

        XCTAssertNil(service.getBestAlternatePoster(from: images, excluding: []))
    }

    func testPrefersMoreEstablishedTrustedPoster() {
        let images = response([
            poster(path: "/lightly-voted.jpg", language: nil, average: 3.334, votes: 2),
            poster(path: "/established.jpg", language: nil, average: 7.542, votes: 9)
        ])

        XCTAssertEqual(
            service.getBestAlternatePoster(from: images, excluding: [])?.filePath,
            "/established.jpg"
        )
    }

    func testWidelyVotedDownvotedPosterLosesToBetterRatedPoster() {
        let images = response([
            poster(path: "/controversial.jpg", language: nil, average: 0.5, votes: 10),
            poster(path: "/liked.jpg", language: nil, average: 7.05, votes: 9)
        ])

        XCTAssertEqual(
            service.getBestAlternatePoster(from: images, excluding: [])?.filePath,
            "/liked.jpg"
        )
    }

    func testFallsBackToLargestUnratedPosterWhenNothingIsEndorsed() {
        let images = response([
            poster(path: "/small.jpg", language: nil, average: 0, votes: 0, width: 1000, height: 1500),
            poster(path: "/large.jpg", language: nil, average: 0, votes: 0, width: 2000, height: 3000)
        ])

        XCTAssertEqual(
            service.getBestAlternatePoster(from: images, excluding: [])?.filePath,
            "/large.jpg"
        )
    }

    func testEndorsedPosterOutranksLargerUnratedPoster() {
        let images = response([
            poster(path: "/unrated.jpg", language: nil, average: 0, votes: 0, width: 2000, height: 3000),
            poster(path: "/endorsed.jpg", language: nil, average: 2.278, votes: 3, width: 1000, height: 1500)
        ])

        XCTAssertEqual(
            service.getBestAlternatePoster(from: images, excluding: [])?.filePath,
            "/endorsed.jpg"
        )
    }

    func testDownvotedPosterIsNeverRescuedByTheUnratedFallback() {
        let images = response([
            poster(path: "/downvoted.jpg", language: nil, average: 0.5, votes: 5)
        ])

        XCTAssertNil(service.getBestAlternatePoster(from: images, excluding: []))
    }

    func testFallsBackToRatingWhenVoteCountsTie() {
        let images = response([
            poster(path: "/lower-rated.jpg", language: nil, average: 2.28, votes: 4),
            poster(path: "/higher-rated.jpg", language: nil, average: 6.72, votes: 4)
        ])

        XCTAssertEqual(
            service.getBestAlternatePoster(from: images, excluding: [])?.filePath,
            "/higher-rated.jpg"
        )
    }

    func testExcludesRegularPosterPath() {
        let images = response([
            poster(path: "/regular.jpg", language: nil, average: 8, votes: 20),
            poster(path: "/alternate.jpg", language: nil, average: 7, votes: 5)
        ])

        XCTAssertEqual(
            service.getBestAlternatePoster(from: images, excluding: ["/regular.jpg"])?.filePath,
            "/alternate.jpg"
        )
    }

    func testHeavyKnightMisuploadsDoNotReplaceItsTextFreePoster() async {
        let shieldHero = "/jptWKaW8gGzPIOxkanDVjO71kG9.jpg"
        let localizedHeavyKnight = "/rO1riUCT84W88K9N6KzYr1iFwlX.jpg"
        let textFreeHeavyKnight = "/8fjzyHd67TaPUnbn8gsK12VbQjP.jpg"
        let primary = "/bADzMfofNWYdxLnlqNuMkO6du34.jpg"
        let images = response([
            poster(path: shieldHero, language: nil, average: 0, votes: 0, width: 2000, height: 3000),
            poster(path: localizedHeavyKnight, language: nil, average: 0, votes: 0, aspectRatio: 0.707, width: 2000, height: 2827),
            poster(path: textFreeHeavyKnight, language: nil, average: 0, votes: 0, aspectRatio: 0.666, width: 1089, height: 1634)
        ])
        let fingerprints: [String: [UInt8]] = [
            primary: [100], shieldHero: [162], localizedHeavyKnight: [117], textFreeHeavyKnight: [130]
        ]

        XCTAssertEqual(service.getBestAlternatePoster(from: images, excluding: [])?.filePath, shieldHero)
        let selected = await service.bestAlternatePoster(
            from: images,
            excluding: [primary],
            matching: primary,
            loadFingerprint: { fingerprints[$0] },
            containsText: { $0 == shieldHero || $0 == localizedHeavyKnight }
        )

        XCTAssertEqual(selected?.filePath, textFreeHeavyKnight)
    }

    func testMarriedCoupleLowRatedArtworkBeatsUnrelatedUnratedUpload() async {
        let primary = "/tEdCclmak7CHR5OzbusD94zdhUW.jpg"
        let matching = "/uPCrSXP7cgy0CzCedMGVmzmfl9Q.jpg"
        let cropped = "/6sxX39Lbm4JUzvf5KN5mLrkJJeX.jpg"
        let unrelated = "/yruvQb2dKkSaOapDGasYPqrX6rc.jpg"
        let images = response([
            poster(path: cropped, language: nil, average: 1.222, votes: 3, aspectRatio: 0.748, width: 1874, height: 2507),
            poster(path: matching, language: nil, average: 1.222, votes: 3, width: 2000, height: 3000),
            poster(path: unrelated, language: nil, average: 0, votes: 0, width: 708, height: 1061)
        ])
        let fingerprints: [String: [UInt8]] = [
            primary: [0], matching: [10], cropped: [26], unrelated: [100]
        ]

        XCTAssertEqual(service.getBestAlternatePoster(from: images, excluding: [])?.filePath, unrelated)
        let selected = await service.bestAlternatePoster(
            from: images,
            excluding: [primary],
            matching: primary,
            loadFingerprint: { fingerprints[$0] },
            containsText: { path in
                XCTAssertEqual(path, matching)
                return false
            }
        )

        XCTAssertEqual(selected?.filePath, matching)
    }

    func testSingleUnratedVisualMismatchKeepsTheRegularPoster() async {
        let selected = await service.bestAlternatePoster(
            from: response([poster(path: "/unrelated.jpg", language: nil, average: 0, votes: 0)]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [100] },
            containsText: { _ in
                XCTFail("A visually unrelated unrated poster should be rejected before the text check")
                return false
            }
        )

        XCTAssertNil(selected)
    }

    func testSingleUnratedMatchingPosterRemainsAvailable() async {
        let selected = await service.bestAlternatePoster(
            from: response([poster(path: "/matching.jpg", language: nil, average: 0, votes: 0)]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [10] },
            containsText: { _ in false }
        )

        XCTAssertEqual(selected?.filePath, "/matching.jpg")
    }

    func testLowRatedAlternativeRequiresClearVisualAdvantage() async {
        let fingerprints: [String: [UInt8]] = [
            "/primary.jpg": [0], "/unrated.jpg": [40], "/low-rated.jpg": [30]
        ]
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/unrated.jpg", language: nil, average: 0, votes: 0),
                poster(path: "/low-rated.jpg", language: nil, average: 1, votes: 3)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { fingerprints[$0] },
            containsText: { _ in false }
        )

        XCTAssertNil(selected)
    }

    func testLowRatedVisualMatchStillRequiresNoTitleText() async {
        let fingerprints: [String: [UInt8]] = [
            "/primary.jpg": [0], "/unrelated.jpg": [100], "/low-rated.jpg": [10]
        ]
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/unrelated.jpg", language: nil, average: 0, votes: 0),
                poster(path: "/low-rated.jpg", language: nil, average: 1, votes: 3)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { fingerprints[$0] },
            containsText: { path in
                XCTAssertEqual(path, "/low-rated.jpg")
                return true
            }
        )

        XCTAssertNil(selected)
    }

    func testLowRatedArtworkDoesNotOverrideEndorsedFallback() async {
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/endorsed.jpg", language: nil, average: 8, votes: 10),
                poster(path: "/low-rated.jpg", language: nil, average: 1, votes: 3)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                XCTAssertNotEqual(path, "/low-rated.jpg")
                return path == "/primary.jpg" ? [0] : [100]
            },
            containsText: { _ in false }
        )

        XCTAssertEqual(selected?.filePath, "/endorsed.jpg")
    }

    func testLowRatedAlternativeNeedsItsOwnReadableFingerprint() async {
        let fingerprints: [String: [UInt8]] = [
            "/primary.jpg": [0], "/unrelated.jpg": [100]
        ]
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/unrelated.jpg", language: nil, average: 0, votes: 0),
                poster(path: "/unreadable.jpg", language: nil, average: 1, votes: 3)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { fingerprints[$0] },
            containsText: { _ in false }
        )

        XCTAssertNil(selected)
    }

    func testLowRatedVisualAlternativesShareTheComparisonLimit() async {
        let images = response(
            [poster(path: "/unrelated.jpg", language: nil, average: 0, votes: 0)]
                + (0..<12).map { poster(path: "/low-rated-\($0).jpg", language: nil, average: 1, votes: 3) }
        )
        let selected = await service.bestAlternatePoster(
            from: images,
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                XCTAssertNotEqual(path, "/low-rated-11.jpg")
                if path == "/primary.jpg" { return [0] }
                return path == "/unrelated.jpg" ? [100] : [10]
            },
            containsText: { path in
                XCTAssertNotEqual(path, "/low-rated-11.jpg")
                return true
            }
        )

        XCTAssertNil(selected)
    }

    func testSingleCandidateMustPassTheTextCheck() async {
        let selected = await service.bestAlternatePoster(
            from: response([poster(path: "/mislabeled.jpg", language: nil, average: 8, votes: 10)]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { _ in nil },
            containsText: { _ in true }
        )

        XCTAssertNil(selected)
    }

    func testFailedTextCheckKeepsTheRegularPoster() async {
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/unreadable.jpg", language: nil, average: 8, votes: 10),
                poster(path: "/next.jpg", language: nil, average: 3, votes: 2)
            ]),
            excluding: [],
            matching: nil,
            loadFingerprint: { _ in nil },
            containsText: { path in
                XCTAssertEqual(path, "/unreadable.jpg")
                return nil
            }
        )

        XCTAssertNil(selected)
    }

    func testCancellationDuringTextCheckDoesNotPublishAPoster() async {
        let images = response([poster(path: "/text-free.jpg", language: nil, average: 0, votes: 0)])
        let selection = Task {
            await service.bestAlternatePoster(
                from: images,
                excluding: [],
                matching: nil,
                loadFingerprint: { _ in nil },
                containsText: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return false
                }
            )
        }

        let selected = await selection.value
        XCTAssertNil(selected)
    }

    func testUnratedTextFreePosterRemainsAvailableWithoutFingerprint() async {
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/mislabeled.jpg", language: nil, average: 0, votes: 0, width: 2000, height: 3000),
                poster(path: "/text-free.jpg", language: nil, average: 0, votes: 0)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { _ in nil },
            containsText: { $0 == "/mislabeled.jpg" }
        )

        XCTAssertEqual(selected?.filePath, "/text-free.jpg")
    }

    func testTextFreeTwinStillOutranksTheVoteWinner() async {
        let fingerprints: [String: [UInt8]] = [
            "/primary.jpg": [100], "/popular.jpg": [160], "/twin.jpg": [105]
        ]
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/popular.jpg", language: nil, average: 8, votes: 10),
                poster(path: "/twin.jpg", language: nil, average: 3, votes: 2)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { fingerprints[$0] },
            containsText: { path in
                XCTAssertEqual(path, "/twin.jpg")
                return false
            }
        )

        XCTAssertEqual(selected?.filePath, "/twin.jpg")
    }

    func testRejectedTwinDoesNotReturnThroughTheVoteFallback() async {
        let fingerprints: [String: [UInt8]] = [
            "/primary.jpg": [100], "/mislabeled.jpg": [105], "/text-free.jpg": [160]
        ]
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/mislabeled.jpg", language: nil, average: 8, votes: 10),
                poster(path: "/text-free.jpg", language: nil, average: 3, votes: 2)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { fingerprints[$0] },
            containsText: { $0 == "/mislabeled.jpg" }
        )

        XCTAssertEqual(selected?.filePath, "/text-free.jpg")
    }

    func testTextChecksStayWithinTheCandidateLimit() async {
        let images = response((0..<13).map { index in
            poster(path: "/poster-\(index).jpg", language: nil, average: 9 - Double(index) / 10, votes: 10)
        })
        let selected = await service.bestAlternatePoster(
            from: images,
            excluding: [],
            matching: nil,
            loadFingerprint: { _ in nil },
            containsText: { path in
                XCTAssertNotEqual(path, "/poster-12.jpg")
                return true
            }
        )

        XCTAssertNil(selected)
    }

    func testDetectsTitleTextInPosterPixels() throws {
        let data = try posterImage(text: "SHIELD\nHERO")
        XCTAssertEqual(TMDBService.alternatePosterContainsText(in: data), true)
    }

    func testAcceptsPosterPixelsWithoutText() throws {
        let data = try posterImage(text: nil)
        XCTAssertEqual(TMDBService.alternatePosterContainsText(in: data), false)
    }

    func testUnreadablePosterPixelsAreNotTreatedAsTextFree() {
        XCTAssertNil(TMDBService.alternatePosterContainsText(in: Data([0, 1, 2])))
    }

    private func posterImage(text: String?) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 342, height: 513), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 342, height: 513))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 30, y: 230, width: 280, height: 250))
            if let text {
                (text as NSString).draw(
                    in: CGRect(x: 50, y: 40, width: 250, height: 150),
                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 44), .foregroundColor: UIColor.black]
                )
            }
        }
        return try XCTUnwrap(image.pngData())
    }

    private func response(_ posters: [TMDBImage]) -> TMDBImagesResponse {
        TMDBImagesResponse(id: 1, backdrops: nil, logos: nil, posters: posters)
    }

    private func poster(
        path: String,
        language: String?,
        average: Double,
        votes: Int,
        aspectRatio: Double = 2.0 / 3.0,
        width: Int = 1000,
        height: Int = 1500
    ) -> TMDBImage {
        TMDBImage(
            aspectRatio: aspectRatio,
            height: height,
            width: width,
            filePath: path,
            iso6391: language,
            voteAverage: average,
            voteCount: votes
        )
    }
}

#if canImport(zlib)
final class TMDBResponseDecompressionTests: XCTestCase {
    func testGzipResponseRetainsItsOriginalJSONBytes() {
        let compressed = Data([
            31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 171, 86, 42, 74, 45, 46, 205,
            41, 41, 86, 178, 138, 142, 173, 5, 0, 10, 39, 124, 158, 14, 0, 0, 0
        ])
        XCTAssertEqual(
            TMDBService.inflateResponseData(compressed, windowBits: 15 + 16),
            Data(#"{"results":[]}"#.utf8)
        )
    }

    func testZlibResponseAtExistingEightMiBLimitIsAccepted() throws {
        let original = Data(repeating: 32, count: 8 * 1_024 * 1_024)
        let compressed = try compress(original)
        XCTAssertLessThan(compressed.count, original.count)
        XCTAssertEqual(TMDBService.inflateResponseData(compressed, windowBits: 15), original)
    }

    func testCompressedResponseExceedingExistingLimitByOneByteIsRejected() throws {
        let original = Data(repeating: 32, count: 8 * 1_024 * 1_024 + 1)
        let compressed = try compress(original)
        XCTAssertLessThan(compressed.count, 16 * 1_024)
        XCTAssertNil(TMDBService.inflateResponseData(compressed, windowBits: 15))
    }

    func testTruncatedCompressedResponseDoesNotReturnPartialJSON() throws {
        let compressed = try compress(Data(#"{"results":[]}"#.utf8))
        XCTAssertNil(TMDBService.inflateResponseData(Data(compressed.dropLast()), windowBits: 15))
    }

    private func compress(_ data: Data) throws -> Data {
        let sourceCount = uLong(data.count)
        var outputCount = compressBound(sourceCount)
        var output = Data(count: Int(outputCount))
        let status = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination -> Int32 in
                guard let input = source.bindMemory(to: Bytef.self).baseAddress,
                      let buffer = destination.bindMemory(to: Bytef.self).baseAddress else {
                    return Z_BUF_ERROR
                }
                return compress2(buffer, &outputCount, input, sourceCount, Z_BEST_COMPRESSION)
            }
        }
        guard status == Z_OK else {
            throw NSError(domain: "TMDBResponseDecompressionTests", code: Int(status))
        }
        output.count = Int(outputCount)
        return output
    }
}
#endif

final class RecommendationCacheOwnershipTests: XCTestCase {
    func testLateResultPersistsForInactiveOwnerWithoutChangingActiveCache() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownerID = UUID()
        let engine = RecommendationEngine(profileID: ownerID, cacheDirectory: directory)
        let owner = engine.captureCacheOwner()
        engine.switchProfile(to: UUID())

        engine.storeGeneratedRecommendations([result(id: 1)], for: owner)
        engine.storeGeneratedBecauseYouWatched(title: "Owner's title", results: [result(id: 2)], for: owner)

        XCTAssertTrue(engine.getRecommendationCache().isEmpty)
        let reloadedOwner = RecommendationEngine(profileID: ownerID, cacheDirectory: directory)
        XCTAssertEqual(reloadedOwner.getRecommendationCache().map(\.id), [1])
        let becauseYouWatched = await reloadedOwner.generateBecauseYouWatched(tmdbService: .shared)
        XCTAssertEqual(becauseYouWatched.title, "Owner's title")
        XCTAssertEqual(becauseYouWatched.results.map(\.id), [2])
    }

    func testReturningToOwnerRejectsPriorActivationResult() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownerID = UUID()
        let engine = RecommendationEngine(profileID: ownerID, cacheDirectory: directory)
        let oldOwner = engine.captureCacheOwner()
        engine.switchProfile(to: UUID())
        engine.switchProfile(to: ownerID)
        let currentOwner = engine.captureCacheOwner()
        engine.storeGeneratedRecommendations([result(id: 2)], for: currentOwner)
        engine.storeGeneratedBecauseYouWatched(title: "Current", results: [result(id: 2)], for: currentOwner)

        engine.storeGeneratedRecommendations([result(id: 1)], for: oldOwner)
        engine.storeGeneratedBecauseYouWatched(title: "Stale", results: [result(id: 1)], for: oldOwner)

        XCTAssertEqual(engine.getRecommendationCache().map(\.id), [2])
        let reloaded = RecommendationEngine(profileID: ownerID, cacheDirectory: directory)
        XCTAssertEqual(reloaded.getRecommendationCache().map(\.id), [2])
        let becauseYouWatched = await reloaded.generateBecauseYouWatched(tmdbService: .shared)
        XCTAssertEqual(becauseYouWatched.title, "Current")
        XCTAssertEqual(becauseYouWatched.results.map(\.id), [2])
    }

    func testInvalidationRejectsPendingResultsAndKeepsDiskEmpty() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownerID = UUID()
        let engine = RecommendationEngine(profileID: ownerID, cacheDirectory: directory)
        let owner = engine.captureCacheOwner()
        engine.invalidateCache()

        engine.storeGeneratedRecommendations([result(id: 1)], for: owner)
        engine.storeGeneratedBecauseYouWatched(title: "Stale", results: [result(id: 1)], for: owner)

        XCTAssertTrue(engine.getRecommendationCache().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testDiscardedOwnerCannotRecreateCacheFromPendingResults() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownerID = UUID()
        let engine = RecommendationEngine(profileID: ownerID, cacheDirectory: directory)
        let owner = engine.captureCacheOwner()
        engine.switchProfile(to: UUID())
        engine.discardCaches(forProfile: ownerID)

        engine.storeGeneratedRecommendations([result(id: 1)], for: owner)
        engine.storeGeneratedBecauseYouWatched(title: "Deleted", results: [result(id: 1)], for: owner)

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testRestoredCacheCannotBeOverwrittenByPendingResult() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownerID = UUID()
        let engine = RecommendationEngine(profileID: ownerID, cacheDirectory: directory)
        let owner = engine.captureCacheOwner()
        engine.restoreRecommendationCache([result(id: 2)])

        engine.storeGeneratedRecommendations([result(id: 1)], for: owner)

        XCTAssertEqual(engine.getRecommendationCache().map(\.id), [2])
        let reloaded = RecommendationEngine(profileID: ownerID, cacheDirectory: directory)
        XCTAssertEqual(reloaded.getRecommendationCache().map(\.id), [2])
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecommendationCacheTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func result(id: Int) -> TMDBSearchResult {
        TMDBSearchResult(
            id: id,
            mediaType: "movie",
            title: "Movie \(id)",
            name: nil,
            overview: nil,
            posterPath: nil,
            backdropPath: nil,
            releaseDate: nil,
            firstAirDate: nil,
            voteAverage: nil,
            popularity: 1,
            adult: false,
            genreIds: [12]
        )
    }
}
#endif
