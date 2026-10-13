import XCTest
import CryptoKit
@testable import Eclipse
#if canImport(zlib)
import zlib
#endif

#if os(iOS)
import UIKit

final class TMDBAlternatePosterTests: XCTestCase {
    private let service = TMDBService.shared
    private let reviewedRejectedTVAssets: [(id: Int, path: String)] = [
        (21734, "/7YIJzhKwqIatbR42vDkU8OojzHq.jpg"),
        (67676, "/2tAZmisXFdSYHYWgqHRWnKNComm.jpg"),
        (270603, "/jptWKaW8gGzPIOxkanDVjO71kG9.jpg"),
        (42253, "/1XhOf4uSp2UJOIYh0ghIMPiKI06.jpg"),
        (158236, "/xfXSM4vrpMFBRpgEM2cR75M9tdb.jpg"),
        (128798, "/uVYHDkghxVrFPNUMwTWMDe9LDls.jpg"),
        (76121, "/745u2NpzUG9p4TBPoLCkvJ84KOE.jpg"),
        (76121, "/ngleTiRHbziuNzclcRK0Mxaqluo.jpg"),
        (76121, "/ctYRyZWuNCNQj2Syso0GSLZWXpk.jpg"),
        (42729, "/qGbaGhgOZaUme14FdicOPRPLepg.jpg"),
        (95, "/zVmPnmhMFNWCBrLvNXSlFiIrwRW.jpg"),
        (83862, "/3yYAyxIQCE8eV1jw6hLiTeCB92U.jpg"),
        (62715, "/md0U2ITC3BDVcYSKXUSkHg9ZBJ1.jpg"),
        (62715, "/jSG9OoATDZNFHAayuwOCygpmzsc.jpg")
    ]
    private let reviewedReferenceAssets: [(mediaType: TMDBAlternatePosterMediaType, id: Int, path: String)] = [
        (.movie, 17606, "/bnhsPAzUgUBJGr8RwQZz1TcdC2y.jpg"),
        (.movie, 783675, "/o0ExOXseKYNfeg84VXCXVTL62CV.jpg"),
        (.movie, 71883, "/oUaOE0weIPznuIkMx8JA4Z6GwIC.jpg"),
        (.movie, 925943, "/3K2c5U4BqPWfar2AYV5WedZPleY.jpg"),
        (.tv, 4167, "/coPJGBQovvmqoPiCG6v0jKzVBtI.jpg"),
        (.tv, 21731, "/23TgMVNUZyfG12Uv1uAv7lgnLJW.jpg"),
        (.tv, 42557, "/eg4DJTA5BiKEjZa6lmWjMEPMW8j.jpg"),
        (.tv, 42253, "/zzalompeC1sWeYtTCbna2jyd8RD.jpg"),
        (.tv, 43865, "/xAtfYepYIpgwQCm4FXoFZvmlTYb.jpg"),
        (.tv, 62564, "/sipyfZS6uikJCkRCMgfAgwzH6eD.jpg"),
        (.tv, 42729, "/A5mZIXro0OxuUbkfD9tCmHBr25e.jpg"),
        (.tv, 29310, "/hp4vnjMOKNDixYwdcCwwE6bPspT.jpg"),
        (.tv, 34809, "/bYQL4BuehTHIjlspIp5n6539bAI.jpg"),
        (.tv, 69500, "/fe12Bo1Od7ou1t5tsvt648Cbus6.jpg"),
        (.tv, 83121, "/j0aK3z9PfveAvJGn8jioi6qZIzI.jpg")
    ]
    private let reviewedIdentityAssets: [(id: Int, path: String, sha256: String)] = [
        (13375, "/wRqyBOBTc4bayPrsT6phlqn8yI1.jpg", "6305068c4c7141354fb90d48f78bafcca08f3d6bb33c78c56fa8ef0b9534fe23"),
        (36581, "/m2MwjhUs1DEWYrrFAkyVPD7buKw.jpg", "d03f3fa5201d6d2faec3cba76dec2ddcccc3e3f81dd4b2aa275f69c0a36f9729"),
        (43865, "/lmGw2SZsE84SChT9cxOkQXiYeKS.jpg", "41c55e4c665e0deb1cc6a284966092837dc6639411beb30141885f3940b62bc4"),
        (62715, "/cQ3MXMOkWfj9m3t00nhqPuFWw1j.jpg", "554daab1504a0d1a2d20119b736b47b0dadc0771e03344c79a307c9cc7aedfa0"),
        (46798, "/7YPaU3G2E5sO9GqqGyo8xR8cBmh.jpg", "921bdb839eb8783d8c47dfce44f41d1a0b782f1c5ecf961cdb71c413a54bb417"),
        (66931, "/1BwmbQWQa7ftborM3GR5If8WZF8.jpg", "69248732d2a1d1e3a6bf400f7939264d5a5a3ef4d48aaa91ac5a9d8049dab379")
    ]

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

    func testExtremeMetadataDimensionsDoNotOverflowPosterOrdering() async {
        let images = response([
            poster(path: "/extreme.jpg", language: nil, average: 0, votes: 0, width: Int.max, height: Int.max),
            poster(path: "/normal.jpg", language: nil, average: 0, votes: 0),
            poster(path: "/low-rated-extreme.jpg", language: nil, average: 1, votes: 3, width: Int.max, height: Int.max)
        ])

        XCTAssertEqual(service.getBestAlternatePoster(from: images, excluding: [])?.filePath, "/extreme.jpg")
        let selected = await service.bestAlternatePoster(
            from: images,
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                if path == "/primary.jpg" { return [0] }
                return path == "/extreme.jpg" ? [10] : [80]
            },
            containsText: { _ in false },
            loadReferenceDistance: { _, path in path == "/extreme.jpg" ? 10 : 80 }
        )

        XCTAssertEqual(selected?.filePath, "/extreme.jpg")
    }

    func testZeroAndNegativeMetadataDimensionsAreRejectedBeforeRanking() {
        let images = response([
            poster(path: "/zero-width.jpg", language: nil, average: 9, votes: 20, width: 0, height: Int.max),
            poster(path: "/zero-height.jpg", language: nil, average: 9, votes: 20, width: Int.max, height: 0),
            poster(path: "/negative-width.jpg", language: nil, average: 9, votes: 20, width: Int.min, height: Int.max),
            poster(path: "/negative-height.jpg", language: nil, average: 9, votes: 20, width: Int.max, height: Int.min),
            poster(path: "/negative-both.jpg", language: nil, average: 9, votes: 20, width: Int.min, height: Int.min)
        ])

        XCTAssertNil(service.getBestAlternatePoster(from: images, excluding: []))
        XCTAssertTrue(service.rankedAlternatePosters(from: images, excluding: []).isEmpty)
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

    func testLowRatedReferenceMatchNeedsSeparationFromCleanUnratedArtwork() async {
        for fallbackDistance in [40, 35] {
            let probe = PosterSelectionProbe()
            let selected = await service.bestAlternatePoster(
                from: response([
                    poster(path: "/unrated.jpg", language: nil, average: 0, votes: 0),
                    poster(path: "/low-rated.jpg", language: nil, average: 1, votes: 3)
                ]),
                excluding: [],
                matching: "/primary.jpg",
                loadFingerprint: { path in
                    if path == "/primary.jpg" { return [0] }
                    return path == "/low-rated.jpg" ? [31] : [UInt8(fallbackDistance)]
                },
                containsText: { path in
                    await probe.recordText(path)
                    XCTAssertEqual(path, "/unrated.jpg")
                    return false
                },
                loadReferenceDistance: { _, path in path == "/low-rated.jpg" ? 31 : Double(fallbackDistance) }
            )

            let checked = await probe.textChecks
            XCTAssertEqual(checked, ["/unrated.jpg"])
            XCTAssertEqual(selected?.filePath, fallbackDistance == 35 ? "/unrated.jpg" : nil)
        }
    }

    func testTextBearingUnratedArtworkDoesNotBlockLowRatedReferenceMatch() async {
        let probe = PosterSelectionProbe()
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/unrated.jpg", language: nil, average: 0, votes: 0),
                poster(path: "/low-rated.jpg", language: nil, average: 1, votes: 3)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                if path == "/primary.jpg" { return [0] }
                return path == "/low-rated.jpg" ? [31] : [40]
            },
            containsText: { path in
                await probe.recordText(path)
                return path == "/unrated.jpg"
            },
            loadReferenceDistance: { _, path in path == "/low-rated.jpg" ? 31 : 40 }
        )

        let checked = await probe.textChecks
        XCTAssertEqual(checked, ["/unrated.jpg", "/low-rated.jpg"])
        XCTAssertEqual(selected?.filePath, "/low-rated.jpg")
    }

    func testUnreadableCompetitiveUnratedTextKeepsResolutionRetryable() async {
        let probe = PosterSelectionProbe()
        let result = await service.resolveAlternatePoster(
            from: response([
                poster(path: "/unrated.jpg", language: nil, average: 0, votes: 0),
                poster(path: "/low-rated.jpg", language: nil, average: 1, votes: 3)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                if path == "/primary.jpg" { return [0] }
                return path == "/low-rated.jpg" ? [31] : [40]
            },
            containsText: { path in
                await probe.recordText(path)
                XCTAssertEqual(path, "/unrated.jpg")
                return nil
            },
            loadReferenceDistance: { _, path in path == "/low-rated.jpg" ? 31 : 40 }
        )

        let checked = await probe.textChecks
        XCTAssertEqual(checked, ["/unrated.jpg"])
        XCTAssertFalse(result.isComplete)
        XCTAssertNil(result.poster)
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
        let probe = PosterSelectionProbe()
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/endorsed.jpg", language: nil, average: 8, votes: 10),
                poster(path: "/low-rated.jpg", language: nil, average: 1, votes: 3)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                await probe.recordFingerprint(path)
                return path == "/primary.jpg" ? [0] : [100]
            },
            containsText: { _ in false },
            loadReferenceDistance: { _, _ in 100 }
        )

        let loaded = await probe.fingerprints
        XCTAssertTrue(loaded.contains("/low-rated.jpg"))
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
        let images = response([poster(path: "/text-free.jpg", language: nil, average: 8, votes: 3)])
        let probe = PosterSelectionProbe()
        let selection = Task {
            await service.bestAlternatePoster(
                from: images,
                excluding: [],
                matching: nil,
                loadFingerprint: { _ in nil },
                containsText: { path in
                    await probe.recordText(path)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return false
                }
            )
        }

        let selected = await selection.value
        let checked = await probe.textChecks
        XCTAssertEqual(checked, ["/text-free.jpg"])
        XCTAssertNil(selected)
    }

    func testUnratedPosterWithoutIdentityEvidenceKeepsTheRegularPoster() async {
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/mislabeled.jpg", language: nil, average: 0, votes: 0, width: 2000, height: 3000),
                poster(path: "/text-free.jpg", language: nil, average: 0, votes: 0)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { _ in nil },
            containsText: { _ in
                XCTFail("Unrated artwork without identity evidence must not reach the text check")
                return false
            }
        )

        XCTAssertNil(selected)
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
                poster(path: "/text-free.jpg", language: nil, average: 3, votes: 3)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { fingerprints[$0] },
            containsText: { $0 == "/mislabeled.jpg" }
        )

        XCTAssertEqual(selected?.filePath, "/text-free.jpg")
    }

    func testWeaklyEndorsedPosterWithoutIdentityEvidenceKeepsTheRegularPoster() async {
        let selected = await service.bestAlternatePoster(
            from: response([poster(path: "/weak.jpg", language: nil, average: 8, votes: 2)]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { _ in nil },
            containsText: { _ in
                XCTFail("Weak endorsement cannot replace unreadable identity evidence")
                return false
            }
        )

        XCTAssertNil(selected)
    }

    func testUnratedCandidateWithUnreadableFingerprintKeepsTheRegularPoster() async {
        let selected = await service.bestAlternatePoster(
            from: response([poster(path: "/unreadable.jpg", language: nil, average: 0, votes: 0)]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : nil },
            containsText: { _ in
                XCTFail("An unreadable candidate cannot establish an unrated match")
                return false
            }
        )

        XCTAssertNil(selected)
    }

    func testReviewedMacrossWrongInstallmentCannotReturnThroughWeakEndorsement() async {
        let selected = await service.bestAlternatePoster(
            from: response([poster(path: "/7YIJzhKwqIatbR42vDkU8OojzHq.jpg", language: nil, average: 3.334, votes: 1)], id: 21734),
            excluding: [],
            matching: "/primary.jpg",
            mediaType: .tv,
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [85] },
            containsText: { _ in
                XCTFail("A reviewed wrong installment must be rejected before OCR")
                return false
            },
            loadReferenceDistance: { _, _ in 85 }
        )

        XCTAssertNil(selected)
    }

    func testEveryReviewedBadTVAssetIsRejectedDespiteStrongVotes() async {
        for asset in reviewedRejectedTVAssets {
            let result = await service.resolveAlternatePoster(
                from: response([poster(path: asset.path, language: nil, average: 9, votes: 100)], id: asset.id),
                excluding: [],
                matching: "/primary.jpg",
                mediaType: .tv,
                loadFingerprint: { _ in
                    XCTFail("A pool containing only reviewed bad artwork must not start fingerprint work")
                    return [0]
                },
                containsText: { _ in
                    XCTFail("Reviewed bad artwork must not start OCR work")
                    return false
                },
                loadReferenceDistance: { _, _ in
                    XCTFail("Reviewed bad artwork must not start reference work")
                    return 0
                }
            )

            XCTAssertTrue(result.isComplete)
            XCTAssertNil(result.poster)
        }
    }

    func testReviewedBadTVPrimaryAndLocalizedAnchorAreNeverLoaded() async {
        for asset in reviewedRejectedTVAssets {
            let probe = PosterSelectionProbe()
            let selected = await service.bestAlternatePoster(
                from: response([
                    poster(path: asset.path, language: "en", average: 9, votes: 100),
                    poster(path: "/good-localized.jpg", language: "ja", average: 8, votes: 3),
                    poster(path: "/clean.jpg", language: nil, average: 0, votes: 0)
                ], id: asset.id),
                excluding: [],
                matching: asset.path,
                mediaType: .tv,
                loadFingerprint: { path in
                    await probe.recordFingerprint(path)
                    XCTAssertNotEqual(path, asset.path)
                    return [0]
                },
                containsText: { path in
                    XCTAssertEqual(path, "/clean.jpg")
                    return false
                },
                loadReferenceDistance: { reference, candidate in
                    await probe.recordReference(reference)
                    XCTAssertEqual(reference, "/good-localized.jpg")
                    XCTAssertEqual(candidate, "/clean.jpg")
                    return 10
                }
            )

            let loaded = await probe.fingerprints
            let references = await probe.references
            XCTAssertEqual(loaded, ["/clean.jpg"])
            XCTAssertEqual(references, ["/good-localized.jpg"])
            XCTAssertEqual(selected?.filePath, "/clean.jpg")
        }
    }

    func testReviewedTVAssetCorrectionDoesNotAffectMatchingMovieID() async {
        for asset in reviewedRejectedTVAssets {
            let selected = await service.bestAlternatePoster(
                from: response([poster(path: asset.path, language: nil, average: 9, votes: 100)], id: asset.id),
                excluding: [],
                matching: "/primary.jpg",
                mediaType: .movie,
                loadFingerprint: { $0 == "/primary.jpg" ? [0] : [10] },
                containsText: { _ in false },
                loadReferenceDistance: { _, _ in 10 }
            )

            XCTAssertEqual(selected?.filePath, asset.path)
        }
    }

    func testReviewedTVAssetCorrectionDoesNotAffectAnotherTVRoute() async {
        for asset in reviewedRejectedTVAssets {
            let selected = await service.bestAlternatePoster(
                from: response([poster(path: asset.path, language: nil, average: 9, votes: 100)], id: 999999),
                excluding: [],
                matching: "/primary.jpg",
                mediaType: .tv,
                loadFingerprint: { $0 == "/primary.jpg" ? [0] : [10] },
                containsText: { _ in false },
                loadReferenceDistance: { _, _ in 10 }
            )

            XCTAssertEqual(selected?.filePath, asset.path)
        }
    }

    func testOrdinarySingleVoteEndorsementCanUseFallbackDespiteDistantReference() async {
        let probe = PosterSelectionProbe()
        let selected = await service.bestAlternatePoster(
            from: response([poster(path: "/ordinary.jpg", language: nil, average: 3, votes: 1)], id: 999999),
            excluding: [],
            matching: "/primary.jpg",
            mediaType: .tv,
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [85] },
            containsText: { path in
                await probe.recordText(path)
                return false
            },
            loadReferenceDistance: { _, _ in 85 }
        )

        let checked = await probe.textChecks
        XCTAssertEqual(checked, ["/ordinary.jpg"])
        XCTAssertEqual(selected?.filePath, "/ordinary.jpg")
    }

    func testTrustedTextBearingPosterFallsThroughToUnratedVisualTwin() async {
        let probe = PosterSelectionProbe()
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/endorsed-text.jpg", language: nil, average: 8, votes: 3),
                poster(path: "/unrated-twin.jpg", language: nil, average: 0, votes: 0)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                if path == "/primary.jpg" { return [0] }
                return path == "/endorsed-text.jpg" ? [1] : [10]
            },
            containsText: { path in
                await probe.recordText(path)
                return path == "/endorsed-text.jpg"
            },
            loadReferenceDistance: { _, path in path == "/endorsed-text.jpg" ? 1 : 10 }
        )

        let checked = await probe.textChecks
        XCTAssertEqual(checked, ["/endorsed-text.jpg", "/unrated-twin.jpg"])
        XCTAssertEqual(selected?.filePath, "/unrated-twin.jpg")
    }

    func testLocalizedGrayscaleReferenceRescuesDifferentPrimaryCrop() async {
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/cropped.jpg", language: nil, average: 0, votes: 0),
                poster(path: "/localized.jpg", language: "en", average: 8, votes: 3)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [50] },
            containsText: { _ in false },
            loadReferenceDistance: { reference, _ in reference == "/localized.jpg" ? 34 : 50 }
        )

        XCTAssertEqual(selected?.filePath, "/cropped.jpg")
    }

    func testReferencesBeyondTwinDistanceCannotRescuePrimaryMismatch() async {
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/different.jpg", language: nil, average: 0, votes: 0),
                poster(path: "/localized.jpg", language: "en", average: 8, votes: 3)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [80] },
            containsText: { _ in
                XCTFail("Grayscale references beyond the twin limit cannot admit unrated artwork")
                return false
            },
            loadReferenceDistance: { reference, _ in reference == "/localized.jpg" ? 37 : 80 }
        )

        XCTAssertNil(selected)
    }

    func testOnlyLowRatedTwinCanBeRescuedWithVisualEvidence() async {
        let selected = await service.bestAlternatePoster(
            from: response([poster(path: "/low-rated-twin.jpg", language: nil, average: 1.2, votes: 3)]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [10] },
            containsText: { _ in false },
            loadReferenceDistance: { _, _ in 10 }
        )

        XCTAssertEqual(selected?.filePath, "/low-rated-twin.jpg")
    }

    func testLargestMatchingLowRatedCandidateUsesSpareSlotBeforeEarlierSmallImages() async {
        let probe = PosterSelectionProbe()
        let images = response([
            poster(path: "/endorsed.jpg", language: nil, average: 8, votes: 3),
            poster(path: "/unrated.jpg", language: nil, average: 0, votes: 0)
        ] + (0..<14).map {
            poster(path: "/small-\($0).jpg", language: nil, average: 1, votes: 3, width: 500, height: 750)
        } + [poster(path: "/large-match.jpg", language: nil, average: 1, votes: 3, width: 2000, height: 3000)])
        let selected = await service.bestAlternatePoster(
            from: images,
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                await probe.recordFingerprint(path)
                if path == "/primary.jpg" { return [0] }
                return path == "/large-match.jpg" ? [20] : [100]
            },
            containsText: { _ in false },
            loadReferenceDistance: { _, path in path == "/large-match.jpg" ? 10 : 80 }
        )

        let loaded = await probe.fingerprints
        XCTAssertTrue(loaded.contains("/large-match.jpg"))
        XCTAssertLessThanOrEqual(loaded.filter { $0 != "/primary.jpg" }.count, 12)
        XCTAssertEqual(selected?.filePath, "/large-match.jpg")
    }

    func testReservedLowRatedSlotsPreserveEveryEndorsedCandidateWithinTheLimit() async {
        for (endorsedCount, expectedUnrated, expectedLowRated) in [(3, 6, 3), (11, 0, 1), (12, 0, 0)] {
            let probe = PosterSelectionProbe()
            let endorsed = (0..<endorsedCount).map {
                poster(path: "/endorsed-\($0).jpg", language: nil, average: 8, votes: 3)
            }
            let unrated = (0..<14).map {
                poster(path: "/unrated-\($0).jpg", language: nil, average: 0, votes: 0)
            }
            let lowRated = (0..<6).map {
                poster(path: "/low-rated-\($0).jpg", language: nil, average: 1, votes: 3)
            }
            let selected = await service.bestAlternatePoster(
                from: response(endorsed + unrated + lowRated),
                excluding: [],
                matching: "/primary.jpg",
                loadFingerprint: { path in
                    await probe.recordFingerprint(path)
                    return path == "/primary.jpg" ? [0] : [100]
                },
                containsText: { _ in false },
                loadReferenceDistance: { _, _ in 100 }
            )

            let loaded = await probe.fingerprints.filter { $0 != "/primary.jpg" }
            XCTAssertEqual(loaded.count, 12)
            XCTAssertEqual(loaded.filter { $0.hasPrefix("/endorsed-") }.count, endorsedCount)
            XCTAssertEqual(loaded.filter { $0.hasPrefix("/unrated-") }.count, expectedUnrated)
            XCTAssertEqual(loaded.filter { $0.hasPrefix("/low-rated-") }.count, expectedLowRated)
            XCTAssertTrue(selected?.filePath.hasPrefix("/endorsed-") == true)
        }
    }

    func testExactLocalizedTwinUsesReservedSpareSlotInACrowdedUnratedPool() async {
        let probe = PosterSelectionProbe()
        let images = response([
            poster(path: "/endorsed.jpg", language: nil, average: 8, votes: 3),
            poster(path: "/localized-anchor.jpg", language: "en", average: 8, votes: 3)
        ] + (0..<14).map {
            poster(path: "/unrated-\($0).jpg", language: nil, average: 0, votes: 0)
        } + (0..<5).map {
            poster(path: "/small-low-rated-\($0).jpg", language: nil, average: 1, votes: 3, width: 500, height: 750)
        } + [poster(path: "/large-low-rated-twin.jpg", language: nil, average: 1, votes: 3, width: 2000, height: 3000)])
        let selected = await service.bestAlternatePoster(
            from: images,
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                await probe.recordFingerprint(path)
                return path == "/primary.jpg" ? [0] : [90]
            },
            containsText: { path in
                XCTAssertEqual(path, "/large-low-rated-twin.jpg")
                return false
            },
            loadReferenceDistance: { reference, candidate in
                reference == "/localized-anchor.jpg" && candidate == "/large-low-rated-twin.jpg" ? 0 : 90
            }
        )

        let loaded = await probe.fingerprints.filter { $0 != "/primary.jpg" }
        XCTAssertEqual(loaded.count, 12)
        XCTAssertTrue(loaded.contains("/endorsed.jpg"))
        XCTAssertTrue(loaded.contains("/large-low-rated-twin.jpg"))
        XCTAssertEqual(loaded.filter { $0.contains("low-rated") }.count, 3)
        XCTAssertEqual(selected?.filePath, "/large-low-rated-twin.jpg")
    }

    func testUsesOnlyTwoBestLocalizedAnchorsAlongsideThePrimary() async {
        let probe = PosterSelectionProbe()
        let images = response([
            poster(path: "/weak.jpg", language: nil, average: 3.334, votes: 1),
            poster(path: "/best-anchor.jpg", language: "ja", average: 9, votes: 4),
            poster(path: "/second-anchor.jpg", language: "en", average: 8, votes: 3),
            poster(path: "/third-anchor.jpg", language: "es", average: 7, votes: 2),
            poster(path: "/single-vote-anchor.jpg", language: "fr", average: 10, votes: 1),
            poster(path: "/wide-anchor.jpg", language: "zh", average: 10, votes: 20, aspectRatio: 1.5, width: 1200, height: 800)
        ])
        let selected = await service.bestAlternatePoster(
            from: images,
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [80] },
            containsText: { _ in false },
            loadReferenceDistance: { reference, _ in
                await probe.recordReference(reference)
                return reference == "/best-anchor.jpg" ? 10 : 80
            }
        )

        let references = await probe.references
        XCTAssertEqual(Set(references), Set(["/primary.jpg", "/best-anchor.jpg", "/second-anchor.jpg"]))
        XCTAssertEqual(references.count, 3)
        XCTAssertEqual(selected?.filePath, "/weak.jpg")
    }

    func testLocalizedDuplicateCannotProvideSelfCorroborationForUnratedArtwork() async {
        let probe = PosterSelectionProbe()
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/same.jpg", language: nil, average: 0, votes: 0),
                poster(path: "/same.jpg", language: "en", average: 9, votes: 4),
                poster(path: "/same.jpg", language: "ja", average: 8, votes: 3)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [100] },
            containsText: { _ in
                XCTFail("A distant unrated image cannot corroborate its own localized duplicate")
                return false
            },
            loadReferenceDistance: { reference, candidate in
                await probe.recordReference(reference)
                if reference == candidate {
                    XCTFail("Self comparisons must be excluded before measuring a reference")
                    return 0
                }
                return 100
            }
        )

        let references = await probe.references
        XCTAssertEqual(references, ["/primary.jpg"])
        XCTAssertNil(selected)
    }

    func testPartialReferenceFailureWithMissingGrayscaleCanRetryAndSelect() async {
        let images = response([
            poster(path: "/weak.jpg", language: nil, average: 3.334, votes: 1),
            poster(path: "/localized-anchor.jpg", language: "en", average: 8, votes: 3)
        ])
        let unavailable = await service.resolveAlternatePoster(
            from: images,
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/weak.jpg" ? [10] : nil },
            containsText: { _ in
                XCTFail("A distant anchor cannot replace the unavailable primary comparison")
                return false
            },
            loadReferenceDistance: { reference, _ in reference == "/localized-anchor.jpg" ? 40 : nil }
        )
        let retried = await service.resolveAlternatePoster(
            from: images,
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [10] },
            containsText: { _ in false },
            loadReferenceDistance: { reference, _ in reference == "/primary.jpg" ? 10 : 40 }
        )

        XCTAssertFalse(unavailable.isComplete)
        XCTAssertNil(unavailable.poster)
        XCTAssertTrue(retried.isComplete)
        XCTAssertEqual(retried.poster?.filePath, "/weak.jpg")
    }

    func testUnavailableTextEvidenceDoesNotCompletePosterResolution() async {
        let result = await service.resolveAlternatePoster(
            from: response([poster(path: "/unreadable-text.jpg", language: nil, average: 8, votes: 3)]),
            excluding: [],
            matching: nil,
            loadFingerprint: { _ in nil },
            containsText: { _ in nil }
        )

        XCTAssertFalse(result.isComplete)
        XCTAssertNil(result.poster)
    }

    func testUnavailableReferenceEvidenceRemainsRetryable() async {
        let result = await service.resolveAlternatePoster(
            from: response([poster(path: "/weak.jpg", language: nil, average: 8, votes: 2)]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [10] },
            containsText: { _ in
                XCTFail("Unavailable reference evidence cannot admit weak artwork")
                return false
            },
            loadReferenceDistance: { _, _ in nil }
        )

        XCTAssertFalse(result.isComplete)
        XCTAssertNil(result.poster)
    }

    func testNoEligibleCandidateConcludesPosterResolution() async {
        let result = await service.resolveAlternatePoster(
            from: response([poster(path: "/localized.jpg", language: "en", average: 9, votes: 20)]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { _ in
                XCTFail("An empty neutral pool needs no fingerprint request")
                return nil
            },
            containsText: { _ in
                XCTFail("An empty neutral pool needs no OCR request")
                return nil
            }
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.poster)
    }

    func testKnownVisualMismatchConcludesPosterResolution() async {
        let result = await service.resolveAlternatePoster(
            from: response([poster(path: "/mismatch.jpg", language: nil, average: 0, votes: 0)]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [80] },
            containsText: { _ in
                XCTFail("A conclusive visual mismatch must not reach OCR")
                return false
            },
            loadReferenceDistance: { _, _ in 80 }
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.poster)
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

    func testDuplicatePosterRowsDoNotConsumeBudgetOrRepeatTextChecks() async {
        let probe = PosterSelectionProbe()
        let duplicate = poster(path: "/duplicate-title.jpg", language: nil, average: 9, votes: 100)
        let images = response(Array(repeating: duplicate, count: 12) + [
            poster(path: "/unique-clean.jpg", language: nil, average: 8, votes: 3)
        ])
        let selected = await service.bestAlternatePoster(
            from: images,
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                await probe.recordFingerprint(path)
                if path == "/primary.jpg" { return [0] }
                return path == "/duplicate-title.jpg" ? [1] : [10]
            },
            containsText: { path in
                await probe.recordText(path)
                return path == "/duplicate-title.jpg"
            },
            loadReferenceDistance: { _, path in path == "/duplicate-title.jpg" ? 1 : 10 }
        )

        let loaded = await probe.fingerprints
        let checked = await probe.textChecks
        XCTAssertEqual(loaded.filter { $0 == "/duplicate-title.jpg" }.count, 1)
        XCTAssertEqual(checked, ["/duplicate-title.jpg", "/unique-clean.jpg"])
        XCTAssertEqual(selected?.filePath, "/unique-clean.jpg")
    }

    func testUnreadableCandidateIsLoadedOnceWithoutReferenceRetriesAndCanRetry() async {
        let probe = PosterSelectionProbe()
        let images = response([
            poster(path: "/unreadable.jpg", language: nil, average: 0, votes: 0),
            poster(path: "/localized-one.jpg", language: "en", average: 9, votes: 3),
            poster(path: "/localized-two.jpg", language: "ja", average: 8, votes: 3)
        ])
        let unavailable = await service.resolveAlternatePoster(
            from: images,
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                await probe.recordFingerprint(path)
                return path == "/primary.jpg" ? [0] : nil
            },
            containsText: { _ in
                XCTFail("An unreadable unrated candidate cannot reach OCR")
                return false
            },
            loadReferenceDistance: { _, _ in
                XCTFail("An unreadable candidate must not trigger reference retries")
                return 0
            }
        )
        let loaded = await probe.fingerprints
        XCTAssertEqual(loaded.filter { $0 == "/unreadable.jpg" }.count, 1)
        XCTAssertFalse(unavailable.isComplete)
        XCTAssertNil(unavailable.poster)

        let retried = await service.resolveAlternatePoster(
            from: images,
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [10] },
            containsText: { _ in false },
            loadReferenceDistance: { _, _ in 10 }
        )
        XCTAssertTrue(retried.isComplete)
        XCTAssertEqual(retried.poster?.filePath, "/unreadable.jpg")
    }

    func testOrdinaryTitlePunctuationPreservesGlyphsWithoutAdmittingSymbolNoise() {
        XCTAssertEqual(TMDBService.alternatePosterTextGlyphs("K-ON!"), "KON")
        XCTAssertEqual(TMDBService.alternatePosterTextGlyphs("[REC]"), "REC")
        XCTAssertEqual(TMDBService.alternatePosterTextGlyphs("M*A*S*H*"), "MASH")
        XCTAssertNil(TMDBService.alternatePosterTextGlyphs("![]-()*"))
        XCTAssertNil(TMDBService.alternatePosterTextGlyphs("%%A~~B"))
        XCTAssertNil(TMDBService.alternatePosterTextGlyphs(" \n\t "))
    }

    func testLowConfidenceVerticalArabicObservationRetainsGenericRecognitionThreshold() {
        XCTAssertTrue(TMDBService.significantAlternatePosterText(
            "ادوربة اك",
            confidence: 0.30000001,
            box: CGRect(x: 0.42367, y: 0.81992, width: 0.05197, height: 0.18080),
            minimumConfidence: 0.3
        ))
    }

    func testReviewedTextFreeThumbnailDigestAcceptsOnlyExactEmmaEvidence() {
        XCTAssertTrue(TMDBService.isReviewedTextFreePosterThumbnailSHA256(
            "307b037bfc0544ee350fb4182d6639d1e0a40175885387bb67690819a7fc8f9a",
            filePath: "/6DInU0gIRWhsTQgCA9sBmUugGOv.jpg",
            id: 29310,
            mediaType: .tv
        ))
    }

    func testReviewedTextFreeThumbnailDigestRejectsNamespaceIdentityAndContentChanges() {
        let checksum = "307b037bfc0544ee350fb4182d6639d1e0a40175885387bb67690819a7fc8f9a"
        let path = "/6DInU0gIRWhsTQgCA9sBmUugGOv.jpg"
        let cases: [(String, String, Int?, TMDBAlternatePosterMediaType?)] = [
            (checksum, path, 29310, .movie),
            (checksum, path, 29310, nil),
            (checksum, path, 29311, .tv),
            (checksum, path, nil, .tv),
            (checksum, "/same-scene-alias.jpg", 29310, .tv),
            (String(repeating: "0", count: 64), path, 29310, .tv),
            (checksum.uppercased(), path, 29310, .tv)
        ]
        for (digest, filePath, id, mediaType) in cases {
            XCTAssertFalse(TMDBService.isReviewedTextFreePosterThumbnailSHA256(
                digest,
                filePath: filePath,
                id: id,
                mediaType: mediaType
            ))
        }
    }

    func testReviewedTextFreeThumbnailRejectsEmptyAndChangedBodies() {
        for data in [Data(), Data("corrupt-image".utf8), Data(repeating: 0, count: 45_279)] {
            XCTAssertFalse(TMDBService.isReviewedTextFreePosterThumbnail(
                data,
                filePath: "/6DInU0gIRWhsTQgCA9sBmUugGOv.jpg",
                id: 29310,
                mediaType: .tv
            ))
        }
    }

    func testHorizontalArabicTitleRetainsAccurateRecognitionThreshold() {
        XCTAssertTrue(TMDBService.significantAlternatePosterText(
            "القلعة المتحركة",
            confidence: 0.3,
            box: CGRect(x: 0.15, y: 0.1, width: 0.6, height: 0.04),
            minimumConfidence: 0.3
        ))
    }

    func testConfidentVerticalArabicTitleStillCountsAsText() {
        let box = CGRect(x: 0.4, y: 0.2, width: 0.05, height: 0.3)
        XCTAssertTrue(TMDBService.significantAlternatePosterText(
            "القلعة",
            confidence: 0.7,
            box: box,
            minimumConfidence: 0.3
        ))
        XCTAssertTrue(TMDBService.significantAlternatePosterText(
            "القلعة",
            confidence: 0.699,
            box: box,
            minimumConfidence: 0.3
        ))
    }

    func testMixedScriptVerticalTitleRetainsConfidentRecognition() {
        XCTAssertTrue(TMDBService.significantAlternatePosterText(
            "AKIRA أكيرا",
            confidence: 0.8,
            box: CGRect(x: 0.4, y: 0.2, width: 0.04, height: 0.3),
            minimumConfidence: 0.3
        ))
        XCTAssertTrue(TMDBService.significantAlternatePosterText(
            "AKIRA ا",
            confidence: 0.3,
            box: CGRect(x: 0.4, y: 0.2, width: 0.04, height: 0.3),
            minimumConfidence: 0.3
        ))
    }

    func testVerticalCJKLatinAndCyrillicTitlesRetainAccurateRecognitionThreshold() {
        for title in ["十二国記", "AKIRA", "АКИРА"] {
            XCTAssertTrue(TMDBService.significantAlternatePosterText(
                title,
                confidence: 0.3,
                box: CGRect(x: 0.4, y: 0.2, width: 0.04, height: 0.3),
                minimumConfidence: 0.3
            ))
        }
    }

    func testOneAdditionalLocalizedMisuploadCannotCorroborateUnratedArtwork() async {
        let probe = PosterSelectionProbe()
        let result = await service.resolveAlternatePoster(
            from: responseWithSupplementaryAnchors([
                poster(path: "/wrong-neutral.jpg", language: nil, average: 0, votes: 0)
            ], additionalCount: 1),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [90] },
            containsText: { _ in
                XCTFail("One additional matching misupload cannot authorize an unrated image")
                return false
            },
            loadReferenceDistance: { reference, _ in
                await probe.recordReference(reference)
                return reference.hasPrefix("/late-") ? 0 : 90
            }
        )

        let references = await probe.references
        XCTAssertTrue(references.contains("/late-0.jpg"))
        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.poster)
    }

    func testTwoAdditionalLocalizedAnchorsRescueArtworkWithinTheBound() async {
        let probe = PosterSelectionProbe()
        let selected = await service.bestAlternatePoster(
            from: responseWithSupplementaryAnchors([
                poster(path: "/clean.jpg", language: nil, average: 0, votes: 0)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                await probe.recordFingerprint(path)
                return path == "/primary.jpg" ? [0] : [90]
            },
            containsText: { _ in false },
            loadReferenceDistance: { reference, _ in
                await probe.recordReference(reference)
                return ["/late-0.jpg", "/late-1.jpg"].contains(reference) ? 10 : 90
            }
        )

        let references = await probe.references
        let loaded = await probe.fingerprints
        XCTAssertEqual(references.count, 6)
        XCTAssertEqual(Set(references), Set(["/primary.jpg", "/initial-one.jpg", "/initial-two.jpg", "/late-0.jpg", "/late-1.jpg", "/late-2.jpg"]))
        XCTAssertEqual(loaded.filter { $0 == "/clean.jpg" }.count, 1)
        XCTAssertEqual(selected?.filePath, "/clean.jpg")
    }

    func testExpandedUnratedCompetitorStillBlocksInsufficientLowRatedSeparation() async {
        let probe = PosterSelectionProbe()
        let selected = await service.bestAlternatePoster(
            from: responseWithSupplementaryAnchors([
                poster(path: "/low-rated.jpg", language: nil, average: 1, votes: 3),
                poster(path: "/unrated.jpg", language: nil, average: 0, votes: 0)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                if path == "/primary.jpg" { return [0] }
                return path == "/low-rated.jpg" ? [50] : [80]
            },
            containsText: { path in
                await probe.recordText(path)
                XCTAssertEqual(path, "/unrated.jpg")
                return false
            },
            loadReferenceDistance: { reference, candidate in
                if reference.hasPrefix("/late-") { return candidate == "/low-rated.jpg" ? 10 : 20 }
                return candidate == "/low-rated.jpg" ? 50 : 80
            }
        )

        let checked = await probe.textChecks
        XCTAssertEqual(checked, ["/unrated.jpg"])
        XCTAssertEqual(selected?.filePath, "/unrated.jpg")
    }

    func testInitialUnavailableEvidenceDoesNotScanAdditionalReferences() async {
        for referenceUnavailable in [true, false] {
            let probe = PosterSelectionProbe()
            let result = await service.resolveAlternatePoster(
                from: responseWithSupplementaryAnchors([
                    poster(path: "/candidate.jpg", language: nil, average: 0, votes: 0)
                ]),
                excluding: [],
                matching: "/primary.jpg",
                loadFingerprint: { $0 == "/primary.jpg" ? [0] : [10] },
                containsText: { _ in
                    if referenceUnavailable { XCTFail("Unavailable references must not reach OCR") }
                    return nil
                },
                loadReferenceDistance: { reference, _ in
                    await probe.recordReference(reference)
                    XCTAssertFalse(reference.hasPrefix("/late-"))
                    return referenceUnavailable ? nil : 10
                }
            )

            let references = await probe.references
            XCTAssertEqual(references.count, 3)
            XCTAssertFalse(result.isComplete)
            XCTAssertNil(result.poster)
        }
    }

    func testInitialSelectedArtworkSkipsAdditionalReferencesAndLoadsCandidateOnce() async {
        let probe = PosterSelectionProbe()
        let selected = await service.bestAlternatePoster(
            from: responseWithSupplementaryAnchors([
                poster(path: "/clean.jpg", language: nil, average: 0, votes: 0)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                await probe.recordFingerprint(path)
                return path == "/primary.jpg" ? [0] : [10]
            },
            containsText: { _ in false },
            loadReferenceDistance: { reference, _ in
                await probe.recordReference(reference)
                XCTAssertFalse(reference.hasPrefix("/late-"))
                return 10
            }
        )

        let references = await probe.references
        let loaded = await probe.fingerprints
        XCTAssertEqual(references.count, 3)
        XCTAssertEqual(loaded.filter { $0 == "/clean.jpg" }.count, 1)
        XCTAssertEqual(selected?.filePath, "/clean.jpg")
    }

    func testCorroboratedPosterOrderingIsTransitiveAcrossAllArrivalPermutations() {
        typealias Measurement = (index: Int, grayscale: Double?, referenceDistance: Double?, corroborated: Bool)
        let a: Measurement = (0, 70, 10, true)
        let b: Measurement = (1, 30, nil, true)
        let c: Measurement = (2, 0, 20, true)
        let permutations = [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]]
        for separated in [true, false] {
            let precedes: (Measurement, Measurement) -> Bool = {
                TMDBService.alternatePosterOrderingPrecedes($0, $1, separatedGrayscaleTwin: separated)
            }
            for values in permutations {
                XCTAssertEqual(values.sorted(by: precedes).map(\.index), [0, 2, 1])
            }
            for lhs in [a, b, c] {
                XCTAssertFalse(precedes(lhs, lhs))
                for rhs in [a, b, c] where precedes(lhs, rhs) {
                    XCTAssertFalse(precedes(rhs, lhs))
                    for third in [a, b, c] where precedes(rhs, third) {
                        XCTAssertTrue(precedes(lhs, third))
                    }
                }
            }
        }
        let laterIndex: Measurement = (6, 100, nil, true)
        let earlierIndex: Measurement = (5, 110, nil, true)
        XCTAssertTrue(TMDBService.alternatePosterOrderingPrecedes(laterIndex, earlierIndex, separatedGrayscaleTwin: true))
        XCTAssertTrue(TMDBService.alternatePosterOrderingPrecedes(earlierIndex, laterIndex, separatedGrayscaleTwin: false))
        XCTAssertTrue(TMDBService.alternatePosterOrderingPrecedes(b, (3, 0, 0, false), separatedGrayscaleTwin: true))
        XCTAssertTrue(TMDBService.alternatePosterOrderingPrecedes((3, 90, 90, false), (4, 0, 0, false), separatedGrayscaleTwin: true))
    }

    func testReviewedIdentityDigestRequiresExactTVContentTuple() {
        for asset in reviewedIdentityAssets {
            XCTAssertTrue(TMDBService.isReviewedPosterIdentitySHA256(asset.sha256, filePath: asset.path, id: asset.id, mediaType: .tv))
            XCTAssertFalse(TMDBService.isReviewedPosterIdentitySHA256(asset.sha256, filePath: asset.path, id: asset.id, mediaType: .movie))
            XCTAssertFalse(TMDBService.isReviewedPosterIdentitySHA256(asset.sha256, filePath: asset.path, id: asset.id, mediaType: nil))
            XCTAssertFalse(TMDBService.isReviewedPosterIdentitySHA256(asset.sha256, filePath: asset.path, id: asset.id + 1, mediaType: .tv))
            XCTAssertFalse(TMDBService.isReviewedPosterIdentitySHA256(asset.sha256, filePath: "/alias.jpg", id: asset.id, mediaType: .tv))
            XCTAssertFalse(TMDBService.isReviewedPosterIdentitySHA256(String(repeating: "0", count: 64), filePath: asset.path, id: asset.id, mediaType: .tv))
            XCTAssertFalse(TMDBService.isReviewedPosterIdentitySHA256(nil, filePath: asset.path, id: asset.id, mediaType: .tv))
        }
    }

    func testDecodedFingerprintDigestIncludesEncodedBodyBytes() throws {
        let data = try posterImage(text: nil)
        let first = try XCTUnwrap(TMDBService.alternatePosterVisualFingerprint(in: data))
        var changed = data
        changed.append(0)
        let second = try XCTUnwrap(TMDBService.alternatePosterVisualFingerprint(in: changed))

        XCTAssertEqual(first.sourceSHA256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(second.sourceSHA256, SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(first.grayscale, second.grayscale)
        XCTAssertEqual(first.aligned, second.aligned)
        XCTAssertNotEqual(first.sourceSHA256, second.sourceSHA256)
    }

    func testReviewedIdentityDigestSurvivesGlobalAndInvocationCaches() async {
        for asset in reviewedIdentityAssets {
            let global = TMDBPosterFingerprintCache()
            let invocation = TMDBPosterInvocationFingerprintCache()
            let first = await invocation.value(for: asset.path) {
                await global.visualFingerprint(for: asset.path) {
                    TMDBPosterVisualFingerprint(grayscale: [10], aligned: [[11]], sourceSHA256: asset.sha256)
                }
            }
            let nextInvocation = TMDBPosterInvocationFingerprintCache()
            let retained = await nextInvocation.value(for: asset.path) {
                await global.visualFingerprint(for: asset.path) {
                    XCTFail("The globally cached fingerprint must retain its fetched-body digest")
                    return nil
                }
            }

            XCTAssertEqual(first?.sourceSHA256, asset.sha256)
            XCTAssertEqual(retained?.sourceSHA256, asset.sha256)
            XCTAssertEqual(retained?.grayscale, [10])
            XCTAssertEqual(retained?.aligned, [[11]])
        }
        XCTAssertNil(TMDBPosterVisualFingerprint(grayscale: [10]).sourceSHA256)
    }

    func testReviewedIdentityAdmitsWeakArtWithoutRewritingMetadataOrReferenceDistance() async {
        let probe = PosterSelectionProbe()
        let candidate = poster(path: "/certified.jpg", language: nil, average: 0, votes: 0)
        let selected = await service.bestAlternatePoster(
            from: response([candidate]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [90] },
            containsText: { _ in false },
            loadReferenceDistance: { reference, _ in
                await probe.recordReference(reference)
                return 80
            },
            hasReviewedIdentity: { $0 == "/certified.jpg" }
        )

        XCTAssertEqual(selected?.filePath, candidate.filePath)
        XCTAssertEqual(selected?.voteAverage, 0)
        XCTAssertEqual(selected?.voteCount, 0)
        let references = await probe.references
        XCTAssertEqual(references, ["/primary.jpg"])
    }

    func testUnknownIdentityDoesNotRelaxOrdinaryTwinDistance() async {
        let probe = PosterSelectionProbe()
        let result = await service.resolveAlternatePoster(
            from: response([poster(path: "/uncertified.jpg", language: nil, average: 0, votes: 0)]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [37] },
            containsText: { path in
                await probe.recordText(path)
                return false
            },
            loadReferenceDistance: { _, _ in 37 },
            hasReviewedIdentity: { _ in false }
        )

        let textChecks = await probe.textChecks
        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.poster)
        XCTAssertTrue(textChecks.isEmpty)
    }

    func testReviewedIdentityCannotResurrectPrimaryExclusionsInvalidGeometryOrKnownNegatives() async {
        let path = "/candidate.jpg"
        for (primary, excluded, width) in [(path, [String?](), 1000), ("/primary.jpg", [Optional(path)], 1000), ("/primary.jpg", [String?](), 499)] {
            let result = await service.resolveAlternatePoster(
                from: response([poster(path: path, language: nil, average: 0, votes: 0, width: width)]),
                excluding: excluded,
                matching: primary,
                loadFingerprint: { _ in XCTFail("Rejected candidates must not load fingerprints"); return [0] },
                containsText: { _ in XCTFail("Rejected candidates must not reach OCR"); return false },
                hasReviewedIdentity: { _ in XCTFail("A certificate cannot resurrect a rejected candidate"); return true }
            )

            XCTAssertTrue(result.isComplete)
            XCTAssertNil(result.poster)
        }
        for asset in reviewedRejectedTVAssets {
            let result = await service.resolveAlternatePoster(
                from: response([poster(path: asset.path, language: nil, average: 0, votes: 0)], id: asset.id),
                excluding: [],
                matching: "/primary.jpg",
                mediaType: .tv,
                loadFingerprint: { _ in XCTFail("Known negatives must be filtered before loading"); return [0] },
                containsText: { _ in XCTFail("Known negatives must not reach OCR"); return false },
                hasReviewedIdentity: { _ in XCTFail("Negative corrections take precedence over certificates"); return true }
            )

            XCTAssertTrue(result.isComplete)
            XCTAssertNil(result.poster)
        }
    }

    func testReviewedIdentityRespectsDuplicateGeometryAndTwelveCandidateBudget() async {
        let fingerprints = PosterSelectionProbe()
        let identities = PosterSelectionProbe()
        let duplicate = poster(path: "/largest.jpg", language: nil, average: 0, votes: 0, width: 2000, height: 3000)
        let others = (0..<14).map { poster(path: "/candidate-\($0).jpg", language: nil, average: 0, votes: 0) }
        let selected = await service.bestAlternatePoster(
            from: response([poster(path: "/bad-geometry.jpg", language: nil, average: 0, votes: 0, width: 499)] + Array(repeating: duplicate, count: 12) + others),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                await fingerprints.recordFingerprint(path)
                return path == "/primary.jpg" ? [0] : [90]
            },
            containsText: { _ in false },
            loadReferenceDistance: { _, _ in 80 },
            hasReviewedIdentity: { path in
                await identities.recordFingerprint(path)
                return true
            }
        )

        let loaded = await fingerprints.fingerprints.filter { $0 != "/primary.jpg" }
        let checked = await identities.fingerprints
        XCTAssertEqual(loaded.count, 12)
        XCTAssertEqual(checked.count, 12)
        XCTAssertEqual(loaded.filter { $0 == "/largest.jpg" }.count, 1)
        XCTAssertEqual(checked.filter { $0 == "/largest.jpg" }.count, 1)
        XCTAssertFalse(loaded.contains("/bad-geometry.jpg"))
        XCTAssertFalse(checked.contains("/bad-geometry.jpg"))
        XCTAssertEqual(selected?.filePath, "/largest.jpg")
    }

    func testReviewedIdentityDoesNotPromoteAnAnchorOrItsNeighbor() async {
        let probe = PosterSelectionProbe()
        let result = await service.resolveAlternatePoster(
            from: response([
                poster(path: "/certified-with-text.jpg", language: nil, average: 0, votes: 0),
                poster(path: "/uncertified-neighbor.jpg", language: nil, average: 0, votes: 0)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [90] },
            containsText: { _ in true },
            loadReferenceDistance: { reference, _ in
                await probe.recordReference(reference)
                return reference == "/certified-with-text.jpg" ? 0 : 80
            },
            hasReviewedIdentity: { $0 == "/certified-with-text.jpg" }
        )

        let references = await probe.references
        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.poster)
        XCTAssertEqual(references.count, 2)
        XCTAssertTrue(references.allSatisfy { $0 == "/primary.jpg" })
    }

    func testReviewedIdentityRetainsActualLowRatedSeparation() async {
        for gap in [10.0, 20.0] {
            let selected = await service.bestAlternatePoster(
                from: response([
                    poster(path: "/certified-low.jpg", language: nil, average: 1, votes: 3),
                    poster(path: "/unrated.jpg", language: nil, average: 0, votes: 0)
                ]),
                excluding: [],
                matching: "/primary.jpg",
                loadFingerprint: { $0 == "/primary.jpg" ? [0] : [90] },
                containsText: { _ in false },
                loadReferenceDistance: { _, candidate in candidate == "/certified-low.jpg" ? 80 : 80 + gap },
                hasReviewedIdentity: { $0 == "/certified-low.jpg" }
            )

            XCTAssertEqual(selected?.filePath, gap == 20 ? "/certified-low.jpg" : nil)
        }
    }

    func testCertifiedLowRatedPosterWithoutDistanceRemainsRetryableOrAllowsLegitimateFallback() async {
        for fallbackDistance in [nil, Optional(80.0), Optional(10.0)] {
            let probe = PosterSelectionProbe()
            var posters = [poster(path: "/certified-low.jpg", language: nil, average: 1, votes: 3)]
            if fallbackDistance != nil {
                posters.append(poster(path: "/fallback.jpg", language: nil, average: 0, votes: 0))
            }
            let result = await service.resolveAlternatePoster(
                from: response(posters),
                excluding: [],
                matching: "/unavailable-primary.jpg",
                loadFingerprint: { $0 == "/unavailable-primary.jpg" ? nil : [90] },
                containsText: { path in
                    await probe.recordText(path)
                    return false
                },
                loadReferenceDistance: { _, candidate in candidate == "/certified-low.jpg" ? nil : fallbackDistance },
                hasReviewedIdentity: { $0 == "/certified-low.jpg" }
            )

            let textChecks = await probe.textChecks
            if fallbackDistance == 10 {
                XCTAssertEqual(result.poster?.filePath, "/fallback.jpg")
                XCTAssertTrue(result.isComplete)
                XCTAssertEqual(textChecks, ["/fallback.jpg"])
            } else {
                XCTAssertNil(result.poster)
                XCTAssertFalse(result.isComplete)
                XCTAssertTrue(textChecks.isEmpty)
            }
        }
    }

    func testReviewedIdentityRetainsTextUnavailableAndCancellationVetoes() async {
        let service = self.service
        let images = response([poster(path: "/certified.jpg", language: nil, average: 0, votes: 0)])
        for mode in 0..<3 {
            let lookup = Task {
                await service.resolveAlternatePoster(
                    from: images,
                    excluding: [],
                    matching: "/primary.jpg",
                    loadFingerprint: { $0 == "/primary.jpg" ? [0] : [90] },
                    containsText: { _ in
                        if mode == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                        return mode == 1 ? nil : mode == 0
                    },
                    loadReferenceDistance: { _, _ in 80 },
                    hasReviewedIdentity: { _ in true }
                )
            }
            let result = await lookup.value

            XCTAssertNil(result.poster)
            XCTAssertEqual(result.isComplete, mode == 0)
            XCTAssertFalse(Task.isCancelled)
        }
    }

    func testReviewedIdentityCannotBypassUnavailableFingerprint() async {
        let result = await service.resolveAlternatePoster(
            from: response([poster(path: "/certified.jpg", language: nil, average: 0, votes: 0)]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : nil },
            containsText: { _ in XCTFail("A missing fingerprint remains unavailable"); return false },
            hasReviewedIdentity: { _ in XCTFail("A missing decoded fingerprint cannot supply a certificate"); return true }
        )

        XCTAssertNil(result.poster)
        XCTAssertFalse(result.isComplete)
    }

    func testReviewedShikiIdentityUsesOnlyTMDBReferencesWithinExistingBudget() async {
        let probe = PosterSelectionProbe()
        let path = "/m2MwjhUs1DEWYrrFAkyVPD7buKw.jpg"
        let digest = "d03f3fa5201d6d2faec3cba76dec2ddcccc3e3f81dd4b2aa275f69c0a36f9729"
        let selected = await service.bestAlternatePoster(
            from: TMDBImagesResponse(id: 36581, backdrops: nil, logos: nil, posters: [
                poster(path: path, language: nil, average: 0, votes: 0),
                poster(path: "/best-localized.jpg", language: "en", average: 9, votes: 3),
                poster(path: "/second-localized.jpg", language: "ja", average: 8, votes: 3),
                poster(path: "/third-localized.jpg", language: "fr", average: 7, votes: 3)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            mediaType: .tv,
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [90] },
            containsText: { _ in false },
            loadReferenceDistance: { reference, _ in
                await probe.recordReference(reference)
                return 80
            },
            hasReviewedIdentity: {
                TMDBService.isReviewedPosterIdentitySHA256(digest, filePath: $0, id: 36581, mediaType: .tv)
            }
        )

        let references = await probe.references
        XCTAssertEqual(references, ["/primary.jpg", "/best-localized.jpg", "/second-localized.jpg"])
        XCTAssertFalse(references.contains(path))
        XCTAssertEqual(selected?.filePath, path)
    }

    func testAlternatePosterRejectsNonTMDBURLsAndTraversalBeforeAnalysis() async {
        for path in [
            "https://example.com/poster.jpg",
            "https://image.tmdb.org/t/p/original/poster.jpg",
            "//example.com/poster.jpg",
            "/nested/poster.jpg",
            "/../poster.jpg",
            "/poster.jpg?source=external",
            "/poster.jpg#fragment",
            "/poster%2Fother.jpg",
            "/poster\\other.jpg",
            "/poster\n.jpg",
            "official:tv:36581:reference",
            "/.",
            "/..",
            "/"
        ] {
            let result = await service.resolveAlternatePoster(
                from: response([poster(path: path, language: nil, average: 9, votes: 99)]),
                excluding: [],
                matching: "/primary.jpg",
                loadFingerprint: { _ in XCTFail("Invalid TMDB paths must not start analysis"); return [0] },
                containsText: { _ in XCTFail("Invalid TMDB paths must not start OCR"); return false },
                loadReferenceDistance: { _, _ in XCTFail("Invalid TMDB paths must not compare references"); return 0 },
                hasReviewedIdentity: { _ in XCTFail("A certificate cannot admit a foreign path"); return true }
            )

            XCTAssertNil(result.poster)
            XCTAssertTrue(result.isComplete)
        }
    }

    func testTMDBReferenceAdmissionRejectsExternalURLsAndPreservesCanonicalArt() async {
        for path in ["/poster.jpg", "/Mixed_CASE-123.png", "/image.webp", "/image.avif"] {
            XCTAssertTrue(TMDBService.isAlternatePosterTMDBFilePath(path))
        }
        let probe = PosterSelectionProbe()
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/candidate.jpg", language: nil, average: 0, votes: 0),
                poster(path: "https://example.com/reference.jpg", language: "ja", average: 9, votes: 99),
                poster(path: "/localized.jpg", language: "en", average: 8, votes: 3)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [90] },
            containsText: { _ in false },
            loadReferenceDistance: { reference, _ in
                await probe.recordReference(reference)
                return reference == "/localized.jpg" ? 10 : 80
            }
        )

        let references = await probe.references
        XCTAssertEqual(references, ["/primary.jpg", "/localized.jpg"])
        XCTAssertEqual(selected?.filePath, "/candidate.jpg")
    }

    func testUnreviewedShikiCandidateCannotInheritExternalReferenceAuthority() async {
        let probe = PosterSelectionProbe()
        let selected = await service.bestAlternatePoster(
            from: TMDBImagesResponse(id: 36581, backdrops: nil, logos: nil, posters: [
                poster(path: "/unreviewed.jpg", language: nil, average: 0, votes: 0)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            mediaType: .tv,
            loadFingerprint: { $0 == "/primary.jpg" ? [0] : [90] },
            containsText: { _ in XCTFail("Unknown artwork retains ordinary matching checks"); return false },
            loadReferenceDistance: { reference, _ in
                await probe.recordReference(reference)
                return reference.hasPrefix("/") ? 80 : 0
            }
        )

        let references = await probe.references
        XCTAssertEqual(references, ["/primary.jpg"])
        XCTAssertNil(selected)
    }

    func testUnratedCoverageIncludesEarliestEligibleImageAndPreservesLargest() async {
        let probe = PosterSelectionProbe()
        let larger = (0..<14).map {
            poster(path: "/larger-\($0).jpg", language: nil, average: 0, votes: 0, width: 1000 + $0 * 10, height: 1500 + $0 * 15)
        }
        let result = await service.resolveAlternatePoster(
            from: response([
                poster(path: "/invalid-earliest.jpg", language: nil, average: 0, votes: 0, width: 499),
                poster(path: "/localized-earliest.jpg", language: "en", average: 0, votes: 0),
                poster(path: "/excluded-earliest.jpg", language: nil, average: 0, votes: 0),
                poster(path: "/earliest-eligible.jpg", language: nil, average: 0, votes: 0, width: 500, height: 750)
            ] + larger),
            excluding: ["/excluded-earliest.jpg"],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                await probe.recordFingerprint(path)
                return path == "/primary.jpg" ? [0] : [80]
            },
            containsText: { _ in false },
            loadReferenceDistance: { _, _ in 80 }
        )

        let loaded = await probe.fingerprints.filter { $0 != "/primary.jpg" }
        XCTAssertEqual(loaded.count, 12)
        XCTAssertTrue(loaded.contains("/earliest-eligible.jpg"))
        XCTAssertTrue(loaded.contains("/larger-13.jpg"))
        XCTAssertFalse(loaded.contains("/invalid-earliest.jpg"))
        XCTAssertFalse(loaded.contains("/localized-earliest.jpg"))
        XCTAssertFalse(loaded.contains("/excluded-earliest.jpg"))
        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.poster)
    }

    func testSingleUnratedSlotRetainsLargestInsteadOfEarliest() async {
        let probe = PosterSelectionProbe()
        let endorsed = (0..<11).map {
            poster(path: "/endorsed-\($0).jpg", language: nil, average: 8, votes: 3)
        }
        let selected = await service.bestAlternatePoster(
            from: response(endorsed + [
                poster(path: "/earliest.jpg", language: nil, average: 0, votes: 0, width: 500, height: 750),
                poster(path: "/largest.jpg", language: nil, average: 0, votes: 0, width: 2000, height: 3000)
            ]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                await probe.recordFingerprint(path)
                return path == "/primary.jpg" ? [0] : [80]
            },
            containsText: { _ in false },
            loadReferenceDistance: { _, _ in 80 }
        )

        let loaded = await probe.fingerprints.filter { $0 != "/primary.jpg" }
        XCTAssertEqual(loaded.count, 12)
        XCTAssertEqual(loaded.filter { $0.hasPrefix("/endorsed-") }.count, 11)
        XCTAssertTrue(loaded.contains("/largest.jpg"))
        XCTAssertFalse(loaded.contains("/earliest.jpg"))
        XCTAssertNotNil(selected)
    }

    func testEarliestUnratedCoverageDoesNotDisplaceSoleLowRatedTwin() async {
        let probe = PosterSelectionProbe()
        let larger = (0..<14).map {
            poster(path: "/unrated-\($0).jpg", language: nil, average: 0, votes: 0, width: 1000 + $0 * 10, height: 1500 + $0 * 15)
        }
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/earliest.jpg", language: nil, average: 0, votes: 0, width: 500, height: 750)
            ] + larger + [poster(path: "/only-low.jpg", language: nil, average: 1, votes: 3)]),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                await probe.recordFingerprint(path)
                if path == "/primary.jpg" { return [0] }
                return path == "/only-low.jpg" ? [10] : [90]
            },
            containsText: { _ in false },
            loadReferenceDistance: { _, candidate in candidate == "/only-low.jpg" ? 10 : 90 }
        )

        let loaded = await probe.fingerprints.filter { $0 != "/primary.jpg" }
        XCTAssertEqual(loaded.count, 12)
        XCTAssertTrue(loaded.contains("/only-low.jpg"))
        XCTAssertFalse(loaded.contains("/earliest.jpg"))
        XCTAssertEqual(selected?.filePath, "/only-low.jpg")
    }

    func testEarliestUnratedCoveragePreservesExistingSeparationCompetitors() async {
        let probe = PosterSelectionProbe()
        let larger = (0..<14).map {
            poster(path: "/unrated-\($0).jpg", language: nil, average: 0, votes: 0, width: 1000 + $0 * 10, height: 1500 + $0 * 15)
        }
        let lows = (0..<3).map {
            poster(path: "/low-\($0).jpg", language: nil, average: 1.9 - Double($0) / 10, votes: 3)
        }
        _ = await service.resolveAlternatePoster(
            from: response([
                poster(path: "/earliest.jpg", language: nil, average: 0, votes: 0, width: 500, height: 750)
            ] + larger + lows),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                await probe.recordFingerprint(path)
                return path == "/primary.jpg" ? [0] : [80]
            },
            containsText: { _ in false },
            loadReferenceDistance: { _, _ in 80 }
        )

        let loaded = await probe.fingerprints.filter { $0 != "/primary.jpg" }
        XCTAssertEqual(loaded.count, 12)
        for index in 5..<14 { XCTAssertTrue(loaded.contains("/unrated-\(index).jpg")) }
        XCTAssertTrue(loaded.contains("/earliest.jpg"))
        XCTAssertTrue(loaded.contains("/low-0.jpg"))
        XCTAssertTrue(loaded.contains("/low-1.jpg"))
        XCTAssertFalse(loaded.contains("/low-2.jpg"))
    }

    func testEarliestUnratedCoverageCanStrengthenLowRatedSeparation() async {
        let larger = (0..<14).map {
            poster(path: "/unrated-\($0).jpg", language: nil, average: 0, votes: 0, width: 1000 + $0 * 10, height: 1500 + $0 * 15)
        }
        let lows = (0..<3).map {
            poster(path: "/low-\($0).jpg", language: nil, average: 1.9 - Double($0) / 10, votes: 3)
        }
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/earliest.jpg", language: nil, average: 0, votes: 0, width: 500, height: 750)
            ] + larger + lows),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                if path == "/primary.jpg" { return [0] }
                if path == "/low-0.jpg" { return [10] }
                return path == "/earliest.jpg" ? [15] : [90]
            },
            containsText: { _ in false },
            loadReferenceDistance: { _, candidate in
                if candidate == "/low-0.jpg" { return 10 }
                return candidate == "/earliest.jpg" ? 15 : 90
            }
        )

        XCTAssertEqual(selected?.filePath, "/earliest.jpg")
    }

    func testEarliestUnratedCoverageRetainsSizePriorityForEquallyMatchingCandidates() async {
        let larger = (0..<14).map {
            poster(path: "/unrated-\($0).jpg", language: nil, average: 0, votes: 0, width: 1000 + $0 * 10, height: 1500 + $0 * 15)
        }
        let selected = await service.bestAlternatePoster(
            from: response([
                poster(path: "/earliest.jpg", language: nil, average: 0, votes: 0, width: 500, height: 750)
            ] + larger),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                if path == "/primary.jpg" { return [0] }
                return path == "/unrated-13.jpg" || path == "/earliest.jpg" ? [10] : [90]
            },
            containsText: { _ in false },
            loadReferenceDistance: { _, candidate in candidate == "/unrated-13.jpg" || candidate == "/earliest.jpg" ? 10 : 90 }
        )

        XCTAssertEqual(selected?.filePath, "/unrated-13.jpg")
    }

    func testReviewedReferenceRescuesWeakCandidateWithoutChangingItsMetadata() async {
        for asset in reviewedReferenceAssets {
            let images = response([
                poster(path: "/candidate.jpg", language: nil, average: 0, votes: 0),
                poster(path: asset.path, language: "ja", average: 0, votes: 0)
            ], id: asset.id)
            let selected = await service.bestAlternatePoster(
                from: images,
                excluding: [],
                matching: "/primary.jpg",
                mediaType: asset.mediaType,
                loadFingerprint: { $0 == "/primary.jpg" ? [0] : [80] },
                containsText: { _ in false },
                loadReferenceDistance: { reference, _ in reference == asset.path ? 10 : 80 }
            )

            XCTAssertEqual(selected?.filePath, "/candidate.jpg")
            XCTAssertEqual(selected?.voteCount, 0)
            XCTAssertEqual(selected?.voteAverage, 0)
            XCTAssertNil(selected?.iso6391)
        }
    }

    func testReviewedReferenceAdmissionIsScopedToMovieOrTVNamespace() async {
        for asset in reviewedReferenceAssets {
            let probe = PosterSelectionProbe()
            let otherType: TMDBAlternatePosterMediaType = asset.mediaType == .movie ? .tv : .movie
            let result = await service.resolveAlternatePoster(
                from: response([
                    poster(path: "/candidate.jpg", language: nil, average: 0, votes: 0),
                    poster(path: asset.path, language: "ja", average: 0, votes: 0)
                ], id: asset.id),
                excluding: [],
                matching: "/primary.jpg",
                mediaType: otherType,
                loadFingerprint: { $0 == "/primary.jpg" ? [0] : [80] },
                containsText: { _ in
                    XCTFail("A reference correction cannot cross the media namespace")
                    return false
                },
                loadReferenceDistance: { reference, _ in
                    await probe.recordReference(reference)
                    return reference == asset.path ? 10 : 80
                }
            )

            let references = await probe.references
            XCTAssertEqual(references, ["/primary.jpg"])
            XCTAssertTrue(result.isComplete)
            XCTAssertNil(result.poster)
        }
    }

    func testReviewedReferenceMustExistAndHaveValidPosterGeometry() async {
        for asset in reviewedReferenceAssets {
            let invalidReferences: [TMDBImage?] = [
                nil,
                poster(path: asset.path, language: "ja", average: 0, votes: 0, width: 499),
                poster(path: asset.path, language: "ja", average: 0, votes: 0, height: 749),
                poster(path: asset.path, language: "ja", average: 0, votes: 0, aspectRatio: 0.8),
                poster(path: asset.path, language: "ja", average: 0, votes: 0, width: 0)
            ]
            for reference in invalidReferences {
                let probe = PosterSelectionProbe()
                let posters = [poster(path: "/candidate.jpg", language: nil, average: 0, votes: 0)] + (reference.map { [$0] } ?? [])
                let result = await service.resolveAlternatePoster(
                    from: response(posters, id: asset.id),
                    excluding: [],
                    matching: "/primary.jpg",
                    mediaType: asset.mediaType,
                    loadFingerprint: { $0 == "/primary.jpg" ? [0] : [80] },
                    containsText: { _ in
                        XCTFail("A missing or malformed reviewed reference cannot admit a weak candidate")
                        return false
                    },
                    loadReferenceDistance: { path, _ in
                        await probe.recordReference(path)
                        return path == asset.path ? 10 : 80
                    }
                )

                let references = await probe.references
                XCTAssertEqual(references, ["/primary.jpg"])
                XCTAssertTrue(result.isComplete)
                XCTAssertNil(result.poster)
            }
        }
    }

    func testReviewedReferenceCannotSelectItsOwnNeutralAlias() async {
        for asset in reviewedReferenceAssets {
            let result = await service.resolveAlternatePoster(
                from: response([
                    poster(path: asset.path, language: nil, average: 9, votes: 100),
                    poster(path: asset.path, language: "ja", average: 0, votes: 0)
                ], id: asset.id),
                excluding: [],
                matching: asset.path,
                mediaType: asset.mediaType,
                loadFingerprint: { _ in
                    XCTFail("Reference-only aliases must be removed before loading fingerprints")
                    return [0]
                },
                containsText: { _ in
                    XCTFail("Reference-only aliases must never become poster winners")
                    return false
                },
                loadReferenceDistance: { _, _ in
                    XCTFail("A reference cannot corroborate itself")
                    return 0
                }
            )

            XCTAssertTrue(result.isComplete)
            XCTAssertNil(result.poster)
        }
    }

    func testUnavailableReviewedReferenceRemainsRetryable() async {
        for asset in reviewedReferenceAssets {
            let images = response([
                poster(path: "/candidate.jpg", language: nil, average: 0, votes: 0),
                poster(path: asset.path, language: "ja", average: 0, votes: 0)
            ], id: asset.id)
            let unavailable = await service.resolveAlternatePoster(
                from: images,
                excluding: [],
                matching: "/primary.jpg",
                mediaType: asset.mediaType,
                loadFingerprint: { $0 == "/primary.jpg" ? [0] : [80] },
                containsText: { _ in
                    XCTFail("Unavailable reference evidence must not reach OCR")
                    return false
                },
                loadReferenceDistance: { reference, _ in reference == asset.path ? nil : 80 }
            )
            let retry = await service.resolveAlternatePoster(
                from: images,
                excluding: [],
                matching: "/primary.jpg",
                mediaType: asset.mediaType,
                loadFingerprint: { $0 == "/primary.jpg" ? [0] : [80] },
                containsText: { _ in false },
                loadReferenceDistance: { reference, _ in reference == asset.path ? 10 : 80 }
            )

            XCTAssertFalse(unavailable.isComplete)
            XCTAssertNil(unavailable.poster)
            XCTAssertEqual(retry.poster?.filePath, "/candidate.jpg")
        }
    }

    func testReviewedReferenceStillRequiresTextFreeWinner() async {
        for asset in reviewedReferenceAssets {
            let probe = PosterSelectionProbe()
            let result = await service.resolveAlternatePoster(
                from: response([
                    poster(path: "/candidate.jpg", language: nil, average: 0, votes: 0),
                    poster(path: asset.path, language: "ja", average: 0, votes: 0)
                ], id: asset.id),
                excluding: [],
                matching: "/primary.jpg",
                mediaType: asset.mediaType,
                loadFingerprint: { $0 == "/primary.jpg" ? [0] : [80] },
                containsText: { path in
                    await probe.recordText(path)
                    return true
                },
                loadReferenceDistance: { reference, _ in reference == asset.path ? 10 : 80 }
            )

            let checkedText = await probe.textChecks
            XCTAssertEqual(checkedText, ["/candidate.jpg"])
            XCTAssertTrue(result.isComplete)
            XCTAssertNil(result.poster)
        }
    }

    func testReviewedReferenceDoesNotRelaxLowRatedSeparation() async {
        for asset in reviewedReferenceAssets {
            let selected = await service.bestAlternatePoster(
                from: response([
                    poster(path: "/low-rated.jpg", language: nil, average: 1, votes: 3),
                    poster(path: "/unrated.jpg", language: nil, average: 0, votes: 0),
                    poster(path: asset.path, language: "ja", average: 0, votes: 0)
                ], id: asset.id),
                excluding: [],
                matching: "/primary.jpg",
                mediaType: asset.mediaType,
                loadFingerprint: { $0 == "/primary.jpg" ? [0] : [80] },
                containsText: { _ in false },
                loadReferenceDistance: { reference, candidate in
                    guard reference == asset.path else { return 80 }
                    return candidate == "/low-rated.jpg" ? 10 : 15
                }
            )

            XCTAssertEqual(selected?.filePath, "/unrated.jpg")
        }
    }

    func testReviewedReferenceDoesNotRelaxTwinDistance() async {
        for asset in reviewedReferenceAssets {
            let result = await service.resolveAlternatePoster(
                from: response([
                    poster(path: "/candidate.jpg", language: nil, average: 0, votes: 0),
                    poster(path: asset.path, language: "ja", average: 0, votes: 0)
                ], id: asset.id),
                excluding: [],
                matching: "/primary.jpg",
                mediaType: asset.mediaType,
                loadFingerprint: { $0 == "/primary.jpg" ? [0] : [80] },
                containsText: { _ in
                    XCTFail("Reviewed provenance does not relax the pixel distance threshold")
                    return false
                },
                loadReferenceDistance: { reference, _ in reference == asset.path ? 37 : 80 }
            )

            XCTAssertTrue(result.isComplete)
            XCTAssertNil(result.poster)
        }
    }

    func testReviewedReferenceUsesExistingInitialReferenceBudget() async {
        for asset in reviewedReferenceAssets {
            let probe = PosterSelectionProbe()
            let selected = await service.bestAlternatePoster(
                from: response([
                    poster(path: "/candidate.jpg", language: nil, average: 0, votes: 0),
                    poster(path: asset.path, language: "ja", average: 0, votes: 0),
                    poster(path: "/best-localized.jpg", language: "en", average: 9, votes: 4),
                    poster(path: "/next-localized.jpg", language: "ja", average: 8, votes: 4),
                    poster(path: "/last-localized.jpg", language: "fr", average: 7, votes: 4)
                ], id: asset.id),
                excluding: [],
                matching: "/primary.jpg",
                mediaType: asset.mediaType,
                loadFingerprint: { $0 == "/primary.jpg" ? [0] : [80] },
                containsText: { _ in false },
                loadReferenceDistance: { reference, _ in
                    await probe.recordReference(reference)
                    return reference == asset.path ? 10 : 80
                }
            )

            let references = await probe.references
            XCTAssertEqual(Set(references), Set(["/primary.jpg", asset.path, "/best-localized.jpg"]))
            XCTAssertEqual(references.count, 3)
            XCTAssertEqual(selected?.filePath, "/candidate.jpg")
        }
    }

    func testCandidateFingerprintStartsWhilePrimaryFingerprintIsHeld() async {
        let primaryStarted = expectation(description: "Primary fingerprint started")
        let candidateStarted = expectation(description: "Candidate fingerprint started")
        let primaryLatch = PosterCacheTestLatch()
        let job = Task {
            await service.resolveAlternatePoster(
                from: response([poster(path: "/candidate.jpg", language: nil, average: 0, votes: 0)]),
                excluding: [],
                matching: "/primary.jpg",
                loadFingerprint: { path in
                    if path == "/primary.jpg" {
                        primaryStarted.fulfill()
                        await primaryLatch.wait()
                        return [0]
                    }
                    candidateStarted.fulfill()
                    return [10]
                },
                containsText: { _ in false },
                loadReferenceDistance: { _, _ in 10 }
            )
        }

        await fulfillment(of: [primaryStarted, candidateStarted], timeout: 2)
        await primaryLatch.release()
        let result = await job.value

        XCTAssertEqual(result.poster?.filePath, "/candidate.jpg")
        XCTAssertTrue(result.isComplete)
    }

    func testUnavailablePrimaryFingerprintIsLoadedOnceAcrossTwelveCandidates() async {
        let probe = PosterSelectionProbe()
        let candidates = (0..<12).map {
            poster(path: "/candidate-\($0).jpg", language: nil, average: 3.334, votes: 1)
        }
        let result = await service.resolveAlternatePoster(
            from: response(candidates),
            excluding: [],
            matching: "/primary.jpg",
            loadFingerprint: { path in
                await probe.recordFingerprint(path)
                return path == "/primary.jpg" ? nil : [10]
            },
            containsText: { path in
                await probe.recordText(path)
                return false
            },
            loadReferenceDistance: { _, _ in nil }
        )

        let loaded = await probe.fingerprints
        let checkedText = await probe.textChecks
        XCTAssertEqual(loaded.filter { $0 == "/primary.jpg" }.count, 1)
        XCTAssertEqual(loaded.count, 13)
        XCTAssertEqual(Set(loaded), Set(candidates.map(\.filePath) + ["/primary.jpg"]))
        XCTAssertTrue(checkedText.isEmpty)
        XCTAssertFalse(result.isComplete)
        XCTAssertNil(result.poster)
    }

    func testCancellationDuringFingerprintGroupDrainsWaitersBeforeReferenceOrTextWork() async {
        let cache = TMDBPosterFingerprintCache(maximumActiveLoads: 1)
        let probe = PosterSelectionProbe()
        let latch = PosterCacheTestLatch()
        let pathsStarted = expectation(description: "Both fingerprint callbacks started")
        pathsStarted.expectedFulfillmentCount = 2
        let job = Task {
            await service.resolveAlternatePoster(
                from: response([poster(path: "/candidate.jpg", language: nil, average: 0, votes: 0)]),
                excluding: [],
                matching: "/primary.jpg",
                loadFingerprint: { path in
                    await probe.recordFingerprint(path)
                    pathsStarted.fulfill()
                    return await cache.visualFingerprint(for: path) {
                        await latch.wait()
                        return TMDBPosterVisualFingerprint(grayscale: [255])
                    }?.grayscale
                },
                containsText: { path in
                    await probe.recordText(path)
                    return false
                },
                loadReferenceDistance: { reference, _ in
                    await probe.recordReference(reference)
                    return 10
                }
            )
        }

        await fulfillment(of: [pathsStarted], timeout: 2)
        let started = await probe.fingerprints
        if started.count == 2 {
            await cache.waitForFingerprintWaiters(for: "/primary.jpg", count: 1)
            await cache.waitForFingerprintWaiters(for: "/candidate.jpg", count: 1)
        }
        job.cancel()
        let result = await job.value
        await latch.release()
        let retry = await cache.visualFingerprint(for: "/primary.jpg") {
            TMDBPosterVisualFingerprint(grayscale: [10])
        }
        let references = await probe.references
        let checkedText = await probe.textChecks

        XCTAssertEqual(Set(started), Set(["/primary.jpg", "/candidate.jpg"]))
        XCTAssertFalse(result.isComplete)
        XCTAssertNil(result.poster)
        XCTAssertTrue(references.isEmpty)
        XCTAssertTrue(checkedText.isEmpty)
        XCTAssertEqual(retry?.grayscale, [10])
    }

    func testCandidateAlignmentCanRescueADifferentCanonicalCrop() {
        let reference = TMDBPosterVisualFingerprint(grayscale: [0])
        let candidate = TMDBPosterVisualFingerprint(grayscale: [80], aligned: [[10]])

        XCTAssertEqual(TMDBService.alternatePosterReferenceDistance(reference, candidate), 10)
        XCTAssertEqual(TMDBService.alternatePosterReferenceDistance(candidate, reference), 10)
    }

    func testTwoAlignedRegionsCannotCorroborateEachOther() {
        let reference = TMDBPosterVisualFingerprint(grayscale: [0], aligned: [[100]])
        let candidate = TMDBPosterVisualFingerprint(grayscale: [50], aligned: [[100]])

        XCTAssertEqual(TMDBService.alternatePosterReferenceDistance(reference, candidate), 50)
    }

    func testAlignmentRequiresCompatibleNonemptyCanonicalFingerprints() {
        let valid = TMDBPosterVisualFingerprint(grayscale: [0], aligned: [[0]])
        let empty = TMDBPosterVisualFingerprint(grayscale: [], aligned: [[0]])
        let differentCount = TMDBPosterVisualFingerprint(grayscale: [0, 0], aligned: [[0]])

        XCTAssertNil(TMDBService.alternatePosterReferenceDistance(empty, valid))
        XCTAssertNil(TMDBService.alternatePosterReferenceDistance(valid, empty))
        XCTAssertNil(TMDBService.alternatePosterReferenceDistance(valid, differentCount))
    }

    func testDetectsTitleTextInPosterPixels() throws {
        let data = try posterImage(text: "SHIELD\nHERO")
        XCTAssertEqual(TMDBService.alternatePosterContainsText(in: data), true)
    }

    func testDetectsLargeBracketedTitleInPosterPixels() throws {
        let data = try posterImage(text: "[REC]")
        XCTAssertEqual(TMDBService.alternatePosterContainsText(in: data), true)
    }

    func testAcceptsPosterPixelsWithoutText() throws {
        let data = try posterImage(text: nil)
        XCTAssertEqual(TMDBService.alternatePosterContainsText(in: data), false)
    }

    func testUnreadablePosterPixelsAreNotTreatedAsTextFree() {
        XCTAssertNil(TMDBService.alternatePosterContainsText(in: Data([0, 1, 2])))
        XCTAssertNil(TMDBService.alternatePosterVisualFingerprint(in: Data([0, 1, 2])))
    }

    func testOnePixelPosterIsUnavailableInsteadOfTextFree() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        let data = try XCTUnwrap(image.pngData())
        XCTAssertNil(TMDBService.alternatePosterContainsText(in: data))
        XCTAssertNil(TMDBService.alternatePosterVisualFingerprint(in: data))
    }

    func testLandscapePosterPixelsAreUnavailableInsteadOfTextFree() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 192, height: 128), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 192, height: 128))
        }

        let data = try XCTUnwrap(image.pngData())
        XCTAssertNil(TMDBService.alternatePosterContainsText(in: data))
        XCTAssertNil(TMDBService.alternatePosterVisualFingerprint(in: data))
    }

    func testInvocationFingerprintFailureIsSharedAndMemoizedUntilLookupEnds() async {
        let cache = TMDBPosterInvocationFingerprintCache()
        let loads = PosterCacheLoadCounter()
        let latch = PosterCacheTestLatch()
        let tasks = (0..<12).map { _ in
            Task {
                await cache.value(for: "/failed-reference.jpg") {
                    await loads.increment()
                    await latch.wait()
                    return nil
                }
            }
        }

        await loads.waitForFirstLoad()
        await latch.release()
        for task in tasks {
            let value = await task.value
            XCTAssertNil(value)
        }
        let repeated = await cache.value(for: "/failed-reference.jpg") {
            await loads.increment()
            return TMDBPosterVisualFingerprint(grayscale: [10])
        }
        let count = await loads.count

        XCTAssertNil(repeated)
        XCTAssertEqual(count, 1)
    }

    func testFreshInvocationFingerprintCacheRetriesPreviousLookupFailure() async {
        let loads = PosterCacheLoadCounter()
        let first = TMDBPosterInvocationFingerprintCache()
        let unavailable = await first.value(for: "/retry-reference.jpg") {
            await loads.increment()
            return nil
        }
        let second = TMDBPosterInvocationFingerprintCache()
        let recovered = await second.value(for: "/retry-reference.jpg") {
            await loads.increment()
            return TMDBPosterVisualFingerprint(grayscale: [10])
        }
        let count = await loads.count

        XCTAssertNil(unavailable)
        XCTAssertEqual(recovered?.grayscale, [10])
        XCTAssertEqual(count, 2)
    }

    func testCancelledInvocationFingerprintProducerCannotCommitUnavailable() async {
        let cache = TMDBPosterInvocationFingerprintCache()
        let loads = PosterCacheLoadCounter()
        let latch = PosterCacheTestLatch()
        let retiredCompleted = expectation(description: "Retired fingerprint producer completed")
        let retired = Task {
            await cache.value(for: "/cancelled-reference.jpg") {
                await loads.increment()
                await latch.wait()
                retiredCompleted.fulfill()
                return nil
            }
        }

        await loads.waitForFirstLoad()
        retired.cancel()
        let cancelled = await retired.value
        let recovered = await cache.value(for: "/cancelled-reference.jpg") {
            await loads.increment()
            return TMDBPosterVisualFingerprint(grayscale: [10])
        }
        await latch.release()
        await fulfillment(of: [retiredCompleted], timeout: 2)
        let retained = await cache.value(for: "/cancelled-reference.jpg") {
            await loads.increment()
            return nil
        }
        let count = await loads.count

        XCTAssertNil(cancelled)
        XCTAssertEqual(recovered?.grayscale, [10])
        XCTAssertEqual(retained?.grayscale, [10])
        XCTAssertEqual(count, 2)
    }

    func testConcurrentFingerprintLoadsShareOneProducer() async {
        let cache = TMDBPosterFingerprintCache()
        let loads = PosterCacheLoadCounter()
        let latch = PosterCacheTestLatch()
        let tasks = (0..<3).map { _ in
            Task {
                await cache.visualFingerprint(for: "/shared.jpg") {
                    await loads.increment()
                    await latch.wait()
                    return TMDBPosterVisualFingerprint(grayscale: [10, 20])
                }?.grayscale
            }
        }
        await cache.waitForFingerprintWaiters(for: "/shared.jpg", count: 3)
        await latch.release()
        var values: [[UInt8]?] = []
        for task in tasks { values.append(await task.value) }

        let count = await loads.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(values.count, 3)
        XCTAssertTrue(values.allSatisfy { $0 == [10, 20] })
    }

    func testCancelledTextWaiterDoesNotCancelSharedProducer() async {
        let cache = TMDBPosterFingerprintCache()
        let loads = PosterCacheLoadCounter()
        let latch = PosterCacheTestLatch()
        let first = Task {
            await cache.textPresence(for: "/shared.jpg") {
                await loads.increment()
                await latch.wait()
                return Task.isCancelled ? nil : false
            }
        }
        await loads.waitForFirstLoad()
        let peer = Task {
            await cache.textPresence(for: "/shared.jpg") {
                await loads.increment()
                return true
            }
        }
        await cache.waitForTextWaiters(for: "/shared.jpg", count: 2)
        first.cancel()
        let cancelled = await first.value
        await latch.release()
        let second = await peer.value
        let count = await loads.count
        let cached = await cache.containsText(for: "/shared.jpg")

        XCTAssertNil(cancelled)
        XCTAssertEqual(second, false)
        XCTAssertEqual(cached, false)
        XCTAssertEqual(count, 1)
    }

    func testUnavailableTextAnalysisRemainsRetryable() async {
        let cache = TMDBPosterFingerprintCache()
        let unavailable = await cache.textPresence(for: "/retry.jpg") { nil }
        let retried = await cache.textPresence(for: "/retry.jpg") { false }

        XCTAssertNil(unavailable)
        XCTAssertEqual(retried, false)
    }

    func testUnavailableFingerprintAnalysisRemainsRetryable() async {
        let cache = TMDBPosterFingerprintCache()
        let unavailable = await cache.visualFingerprint(for: "/retry.jpg") { nil }
        let retried = await cache.visualFingerprint(for: "/retry.jpg") {
            TMDBPosterVisualFingerprint(grayscale: [10, 20])
        }
        let cached = await cache.fingerprint(for: "/retry.jpg")

        XCTAssertNil(unavailable)
        XCTAssertEqual(retried?.grayscale, [10, 20])
        XCTAssertEqual(cached, [10, 20])
    }

    func testCompletingTextLoadDoesNotReopenProducerBeforeCacheCommit() async {
        let cache = TMDBPosterFingerprintCache()
        let loads = PosterCacheLoadCounter()
        let values = await withTaskGroup(of: Bool?.self) { group in
            for _ in 0..<80 {
                group.addTask {
                    await cache.textPresence(for: "/completed.jpg") {
                        await loads.increment()
                        return false
                    }
                }
            }
            var values: [Bool?] = []
            for await value in group { values.append(value) }
            return values
        }
        let count = await loads.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(values.count, 80)
        XCTAssertTrue(values.allSatisfy { $0 == false })
    }

    func testLastCancelledQueuedWaiterDoesNotStartLoadAndCanRetry() async {
        let cache = TMDBPosterFingerprintCache(maximumActiveLoads: 1)
        let ledger = PosterCacheWorkerLedger()
        let latch = PosterCacheTestLatch()
        let busy = Task {
            await cache.textPresence(for: "/busy.jpg") {
                await ledger.begin("busy")
                await latch.wait()
                await ledger.end()
                return false
            }
        }
        await ledger.waitForStarts(1)
        let queued = Task {
            await cache.textPresence(for: "/queued.jpg") {
                await ledger.begin("cancelled")
                await ledger.end()
                return true
            }
        }
        await cache.waitForTextWaiters(for: "/queued.jpg", count: 1)
        queued.cancel()
        let cancelled = await queued.value
        await latch.release()
        _ = await busy.value
        let retried = await cache.textPresence(for: "/queued.jpg") {
            await ledger.begin("retry")
            await ledger.end()
            return false
        }
        let starts = await ledger.starts
        XCTAssertNil(cancelled)
        XCTAssertEqual(retried, false)
        XCTAssertEqual(starts, ["busy", "retry"])
    }

    func testCancelledActiveProducerRetainsPermitUntilCompletionAndCannotRemoveReplacement() async {
        let cache = TMDBPosterFingerprintCache(maximumActiveLoads: 1)
        let ledger = PosterCacheWorkerLedger()
        let retiringLatch = PosterCacheTestLatch()
        let replacementLatch = PosterCacheTestLatch()
        let first = Task {
            await cache.textPresence(for: "/replace.jpg") {
                await ledger.begin("retiring")
                await retiringLatch.wait()
                await ledger.end()
                return true
            }
        }
        await ledger.waitForStarts(1)
        first.cancel()
        let cancelled = await first.value
        let replacement = Task {
            await cache.textPresence(for: "/replace.jpg") {
                await ledger.begin("replacement")
                await replacementLatch.wait()
                await ledger.end()
                return false
            }
        }
        await cache.waitForTextWaiters(for: "/replace.jpg", count: 1)
        let beforeRelease = await ledger.starts
        await retiringLatch.release()
        await ledger.waitForStarts(2)
        let peer = Task {
            await cache.textPresence(for: "/replace.jpg") {
                await ledger.begin("unexpected")
                await ledger.end()
                return true
            }
        }
        await cache.waitForTextWaiters(for: "/replace.jpg", count: 2)
        await replacementLatch.release()
        let replacementValue = await replacement.value
        let peerValue = await peer.value
        let peak = await ledger.peak
        let cached = await cache.containsText(for: "/replace.jpg")
        XCTAssertNil(cancelled)
        XCTAssertEqual(beforeRelease, ["retiring"])
        XCTAssertEqual(replacementValue, false)
        XCTAssertEqual(peerValue, false)
        XCTAssertEqual(cached, false)
        XCTAssertEqual(peak, 1)
    }

    func testPhysicalLoadLimitIsSharedByTextAndFingerprintWork() async {
        let cache = TMDBPosterFingerprintCache()
        let ledger = PosterCacheWorkerLedger()
        let latch = PosterCacheTestLatch()
        let tasks = (0..<8).map { index in
            Task {
                if index.isMultiple(of: 2) {
                    return await cache.textPresence(for: "/text-\(index).jpg") {
                        await ledger.begin("text-\(index)")
                        await latch.wait()
                        await ledger.end()
                        return false
                    } != nil
                }
                return await cache.visualFingerprint(for: "/fingerprint-\(index).jpg") {
                    await ledger.begin("fingerprint-\(index)")
                    await latch.wait()
                    await ledger.end()
                    return TMDBPosterVisualFingerprint(grayscale: [UInt8(index)])
                } != nil
            }
        }
        await ledger.waitForStarts(4)
        for index in 0..<8 {
            if index.isMultiple(of: 2) {
                await cache.waitForTextWaiters(for: "/text-\(index).jpg", count: 1)
            } else {
                await cache.waitForFingerprintWaiters(for: "/fingerprint-\(index).jpg", count: 1)
            }
        }
        let firstWave = await ledger.starts.count
        await latch.release()
        var succeeded = 0
        for task in tasks { if await task.value { succeeded += 1 } }
        let peak = await ledger.peak
        XCTAssertEqual(firstWave, 4)
        XCTAssertEqual(peak, 4)
        XCTAssertEqual(succeeded, 8)
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

    private func response(_ posters: [TMDBImage], id: Int = 1) -> TMDBImagesResponse {
        TMDBImagesResponse(id: id, backdrops: nil, logos: nil, posters: posters)
    }

    private func responseWithSupplementaryAnchors(_ posters: [TMDBImage], additionalCount: Int = 3) -> TMDBImagesResponse {
        let initial = [
            poster(path: "/initial-one.jpg", language: "en", average: 9, votes: 5),
            poster(path: "/initial-two.jpg", language: "ja", average: 8, votes: 5)
        ]
        let additional = (0..<additionalCount).map {
            poster(path: "/late-\($0).jpg", language: "fr", average: 7 - Double($0), votes: 5)
        }
        return response(posters + initial + additional)
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

private actor PosterSelectionProbe {
    private(set) var fingerprints: [String] = []
    private(set) var textChecks: [String] = []
    private(set) var references: [String] = []

    func recordFingerprint(_ path: String) { fingerprints.append(path) }
    func recordText(_ path: String) { textChecks.append(path) }
    func recordReference(_ path: String) { references.append(path) }
}

private actor PosterCacheTestLatch {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor PosterCacheWorkerLedger {
    private(set) var starts: [String] = []
    private(set) var peak = 0
    private var active = 0
    private var observers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func begin(_ name: String) {
        starts.append(name)
        active += 1
        peak = max(peak, active)
        let pending = observers
        observers.removeAll()
        for observer in pending {
            if starts.count >= observer.count { observer.continuation.resume() }
            else { observers.append(observer) }
        }
    }

    func end() { active -= 1 }

    func waitForStarts(_ count: Int) async {
        guard starts.count < count else { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
}

private actor PosterCacheLoadCounter {
    private(set) var count = 0
    private var firstLoadWaiters: [CheckedContinuation<Void, Never>] = []

    func increment() {
        count += 1
        let waiters = firstLoadWaiters
        firstLoadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitForFirstLoad() async {
        guard count == 0 else { return }
        await withCheckedContinuation { firstLoadWaiters.append($0) }
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
