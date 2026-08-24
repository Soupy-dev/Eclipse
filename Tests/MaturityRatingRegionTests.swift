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

    func testBrowseAgeRatingUsesSharedMaturityTiersAndFailsClosedForUnknowns() {
        XCTAssertEqual(BrowseAgeRating.general.title, "All Ages")
        XCTAssertEqual(BrowseAgeRating.teen.title, "Up to 14+")
        XCTAssertEqual(BrowseAgeRating.mature.title, "Up to 17+")
        XCTAssertEqual(BrowseAgeRating.adult.title, "18+ Only")
        XCTAssertTrue(BrowseAgeRating.general.includes(.general))
        XCTAssertFalse(BrowseAgeRating.general.includes(.teen))
        XCTAssertTrue(BrowseAgeRating.teen.includes(.general))
        XCTAssertTrue(BrowseAgeRating.teen.includes(.teen))
        XCTAssertFalse(BrowseAgeRating.teen.includes(.mature))
        XCTAssertTrue(BrowseAgeRating.mature.includes(.mature))
        XCTAssertFalse(BrowseAgeRating.mature.includes(.adult))
        XCTAssertTrue(BrowseAgeRating.adult.includes(.adult))
        XCTAssertFalse(BrowseAgeRating.adult.includes(.mature))
        XCTAssertFalse(BrowseAgeRating.teen.includes(.unknown))
        XCTAssertFalse(BrowseAgeRating.teen.includes(nil))
        XCTAssertTrue(BrowseAgeRating.all.includes(nil))
    }

    func testLegacyBrowsePreferencesKeepAnimeAgeFilterOwnedByAnime() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "mediaTypeRawValue": "TV Shows",
            "selectedGenreKeys": ["tmdb-10765"],
            "excludedGenreKeys": ["tmdb-16"],
            "selectedYears": [2026],
            "excludedYears": [2025],
            "selectedCountryCode": "ES",
            "sortRawValue": "newest",
            "minimumRating": 6.0,
            "animeAgeRatingRawValue": "excludeAdults"
        ])

        let decoded = try JSONDecoder().decode(BrowseFilterPreferences.self, from: data)
        let television = try XCTUnwrap(decoded.configurationsByMediaType["TV Shows"])
        let anime = try XCTUnwrap(decoded.configurationsByMediaType["Anime"])

        XCTAssertEqual(television.selectedGenreKeys, ["tmdb-10765"])
        XCTAssertEqual(television.selectedCountryCodes, ["ES"])
        XCTAssertEqual(television.minimumRating, 6)
        XCTAssertEqual(television.ageRatingRawValue, BrowseAgeRating.all.rawValue)
        XCTAssertEqual(anime.selectedGenreKeys, [])
        XCTAssertEqual(anime.selectedCountryCodes, ["JP"])
        XCTAssertEqual(anime.minimumRating, 0)
        XCTAssertEqual(anime.ageRatingRawValue, BrowseAgeRating.mature.rawValue)
        XCTAssertNil(decoded.configurationsByMediaType["Movies"])
    }

    func testLegacyAnimePreferencesCombineFiltersAndAgeSelection() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "mediaTypeRawValue": "Anime",
            "selectedGenreKeys": ["keyword-isekai"],
            "selectedYears": [2026],
            "selectedCountryCode": "CN",
            "sortRawValue": "newest",
            "minimumRating": 7.0,
            "animeAgeRatingRawValue": "excludeAdults"
        ])

        let decoded = try JSONDecoder().decode(BrowseFilterPreferences.self, from: data)
        let anime = try XCTUnwrap(decoded.configurationsByMediaType["Anime"])

        XCTAssertEqual(decoded.configurationsByMediaType.count, 1)
        XCTAssertEqual(anime.selectedGenreKeys, ["keyword-isekai"])
        XCTAssertEqual(anime.selectedYears, [2026])
        XCTAssertEqual(anime.selectedCountryCodes, ["CN"])
        XCTAssertEqual(anime.minimumRating, 7)
        XCTAssertEqual(anime.ageRatingRawValue, BrowseAgeRating.mature.rawValue)
    }

    func testBrowsePreferencesRoundTripIndependentConfigurations() throws {
        let television = BrowseFilterConfiguration(
            selectedGenreKeys: ["tmdb-10765"],
            excludedGenreKeys: [],
            selectedYears: [2026],
            excludedYears: [],
            selectedCountryCodes: ["ES", "US"],
            sortRawValue: "newest",
            minimumRating: 6,
            ageRatingRawValue: BrowseAgeRating.teen.rawValue
        )
        let anime = BrowseFilterConfiguration(
            selectedGenreKeys: ["keyword-isekai"],
            excludedGenreKeys: [],
            selectedYears: [],
            excludedYears: [2025],
            selectedCountryCodes: ["JP"],
            sortRawValue: "popularity.desc",
            minimumRating: 8,
            ageRatingRawValue: BrowseAgeRating.mature.rawValue
        )
        let preferences = BrowseFilterPreferences(
            mediaTypeRawValue: "Anime",
            configurationsByMediaType: ["TV Shows": television, "Anime": anime]
        )

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(BrowseFilterPreferences.self, from: data)

        XCTAssertEqual(decoded, preferences)
        XCTAssertEqual(decoded.configurationsByMediaType["TV Shows"]?.selectedCountryCodes, ["ES", "US"])
        XCTAssertEqual(decoded.configurationsByMediaType["Anime"]?.selectedCountryCodes, ["JP"])
    }

    func testBrowseConfigurationSanitizesSelectionsWithoutCrossContamination() {
        let configuration = BrowseFilterConfiguration(
            selectedGenreKeys: ["tv", "missing"],
            excludedGenreKeys: ["tv", "other"],
            selectedYears: [2026, 1949],
            excludedYears: [2026, 2025],
            selectedCountryCodes: ["us", "ES", "XX"],
            sortRawValue: "invalid",
            minimumRating: .infinity,
            ageRatingRawValue: "invalid"
        )

        let sanitized = configuration.sanitized(
            validGenreKeys: ["tv", "other"],
            validCountryCodes: ["US", "ES"],
            validYearRange: 1950...2026
        )

        XCTAssertEqual(sanitized.selectedGenreKeys, ["tv"])
        XCTAssertEqual(sanitized.excludedGenreKeys, ["other"])
        XCTAssertEqual(sanitized.selectedYears, [2026])
        XCTAssertEqual(sanitized.excludedYears, [2025])
        XCTAssertEqual(sanitized.selectedCountryCodes, ["ES", "US"])
        XCTAssertEqual(sanitized.sortRawValue, "popularity.desc")
        XCTAssertEqual(sanitized.minimumRating, 0)
        XCTAssertEqual(sanitized.ageRatingRawValue, BrowseAgeRating.all.rawValue)
    }

    func testDiscoverCountrySelectionUsesOneORQuery() {
        XCTAssertEqual(
            TMDBDiscoverFilterPolicy.originCountryQueryValue(["US", "es", "US"]),
            "ES|US"
        )
        XCTAssertNil(TMDBDiscoverFilterPolicy.originCountryQueryValue(["", "invalid"]))
    }

    func testMinimumUserRatingDoesNotImposeRankVoteCountFloor() {
        XCTAssertNil(
            BrowseDiscoverRatingPolicy.minimumVoteCount(
                isRankSort: false,
                minimumRating: 6
            )
        )
        XCTAssertEqual(
            BrowseDiscoverRatingPolicy.minimumVoteCount(
                isRankSort: true,
                minimumRating: 6
            ),
            100
        )
    }
}
#endif
