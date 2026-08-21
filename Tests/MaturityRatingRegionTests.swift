import XCTest
@testable import Eclipse

#if os(iOS)

final class MaturityRatingRegionTests: XCTestCase {

    func testIndianCBFCAdultsOnlyIsNotAllAges() {
        XCTAssertEqual(MaturityRating.classify(certification: "A", region: "IN"), .adult)
        XCTAssertTrue(MaturityRating.classify(certification: "A", region: "IN").isBlockedForKids)
    }

    func testAllAgesBoardsKeepTheirMeaning() {
        for region in ["ES", "SE", "JP"] {
            XCTAssertEqual(
                MaturityRating.classify(certification: "A", region: region), .general,
                "\(region) uses A for all ages; a global adult mapping would over-block it"
            )
        }

        XCTAssertEqual(MaturityRating.classify(certification: "A"), .general)
    }

    func testIndianParentalGuidanceAndRestrictedTiers() {
        XCTAssertEqual(MaturityRating.classify(certification: "UA", region: "IN"), .teen)
        XCTAssertEqual(MaturityRating.classify(certification: "S", region: "IN"), .adult)
        XCTAssertEqual(MaturityRating.classify(certification: "U", region: "IN"), .general)
    }

    func testGroupedClassificationUsesTheIssuingRegion() {

        XCTAssertEqual(MaturityRating.classify(certificationsByRegion: ["IN": ["A"]]), .adult)
    }

    func testWorldwideFallbackStillClassifiesPerRegion() {

        let preferred = Set(MaturityRating.preferredRegions)
        guard let adultsOnlyRegion = ["IN", "CA"].first(where: { !preferred.contains($0) }),
              let allAgesRegion = ["ES", "SE", "JP"].first(where: { !preferred.contains($0) }) else {
            return XCTFail("no unpreferred board left to pin the fallback on this host")
        }
        XCTAssertEqual(
            MaturityRating.classify(certificationsByRegion: [adultsOnlyRegion: ["A"]]), .adult
        )
        XCTAssertEqual(
            MaturityRating.classify(
                certificationsByRegion: [adultsOnlyRegion: ["A"], allAgesRegion: ["A"]]
            ), .adult,
            "the strictest reading across regions wins once no preferred region rated it"
        )
    }

    func testPreferredRegionWinsOverAStricterForeignBoard() {

        let preferred = MaturityRating.preferredRegions
        guard let localRegion = preferred.first,
              let foreignRegion = ["IN", "CA"].first(where: { !preferred.contains($0) }) else {
            return XCTFail("no unpreferred strict board left to contrast on this host")
        }
        XCTAssertEqual(
            MaturityRating.classify(
                certificationsByRegion: [localRegion: ["G"], foreignRegion: ["A"]]
            ), .general
        )
    }

    func testGulfStylePGTiersReadTheirAgeNotTheBarePrefix() {

        XCTAssertEqual(MaturityRating.classify(certification: "PG18"), .adult)
        XCTAssertEqual(MaturityRating.classify(certification: "PG15"), .mature)
        XCTAssertEqual(MaturityRating.classify(certification: "PG13"), .teen)
        XCTAssertEqual(MaturityRating.classify(certification: "PG12"), .teen)
    }

    func testBarePGIsStillGeneral() {
        XCTAssertEqual(MaturityRating.classify(certification: "PG"), .general)
        XCTAssertEqual(MaturityRating.classify(certification: "TV-PG"), .general)
    }

    func testPGTiersAgreeWithTheBareAgeBoards() {

        XCTAssertEqual(
            MaturityRating.classify(certification: "PG15"),
            MaturityRating.classify(certification: "15")
        )
    }

    func testCommonBoardsAreUnaffectedByTheRegionParameter() {
        XCTAssertEqual(MaturityRating.classify(certification: "TV-MA", region: "US"), .mature)
        XCTAssertEqual(MaturityRating.classify(certification: "R", region: "US"), .mature)
        XCTAssertEqual(MaturityRating.classify(certification: "NC-17", region: "US"), .adult)
        XCTAssertEqual(MaturityRating.classify(certification: "18", region: "GB"), .adult)
        XCTAssertEqual(MaturityRating.classify(certification: "U", region: "GB"), .general)
    }

    func testStrictestWithinOneRegionStillWins() {

        XCTAssertEqual(
            MaturityRating.classify(certifications: ["TV-14", "TV-MA"], region: "US"), .mature
        )
    }

    func testFullKidsPolicyRejectsAdultAndBlockedGenreSignals() {
        XCTAssertFalse(
            TMDBContentFilter.kidsDetailPolicyAllows(
                title: "Innocent title",
                isAdult: true,
                genreIds: [],
                overview: nil
            )
        )
        XCTAssertFalse(
            TMDBContentFilter.kidsDetailPolicyAllows(
                title: "Innocent title",
                isAdult: false,
                genreIds: [53],
                overview: nil
            ),
            "a permissive certification must not override the persisted Thriller verdict"
        )
    }

    func testFullKidsPolicyAppliesOverviewAndAllowsBenignDetails() {
        XCTAssertFalse(
            TMDBContentFilter.kidsDetailPolicyAllows(
                title: "Innocent title",
                isAdult: false,
                genreIds: [16],
                overview: "A serial killer stalks the city."
            )
        )
        XCTAssertTrue(
            TMDBContentFilter.kidsDetailPolicyAllows(
                title: "A Friendly Adventure",
                isAdult: false,
                genreIds: [16, 10751],
                overview: "Friends travel together and learn to help one another."
            )
        )
    }
}
#endif
