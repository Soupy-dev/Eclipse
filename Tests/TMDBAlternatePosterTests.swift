import XCTest
@testable import Eclipse

#if os(iOS)
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
#endif
