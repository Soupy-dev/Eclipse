import XCTest
@testable import Eclipse

final class PlaybackInputSafetyTests: XCTestCase {
    func testSkipSegmentKeysRejectUnrepresentableTimes() {
        for value in [Double.nan, .infinity, -.infinity, -1, Double(Int.max), .greatestFiniteMagnitude] {
            XCTAssertEqual(SkipSegment(startTime: value, endTime: value, type: .intro).uniqueKey, "intro_unknown")
        }
        XCTAssertEqual(SkipSegment(startTime: 12.9, endTime: 90, type: .intro).uniqueKey, "intro_12")
        XCTAssertEqual(SkipSegment(startTime: 0, endTime: 90, type: .recap).uniqueKey, "recap_0")
    }

    func testAniSkipDurationHandlesUnknownAndOutOfRangeRendererValues() {
        for value in [Double.nan, .infinity, -.infinity, -1, 0, Double(Int.max), .greatestFiniteMagnitude] {
            XCTAssertEqual(AniSkipService.episodeLengthParameter(for: value), 0)
        }
        XCTAssertEqual(AniSkipService.episodeLengthParameter(for: 1440.75), 1440)
        XCTAssertEqual(AniSkipService.episodeLengthParameter(for: Double(Int.max).nextDown), Int.max - 1023)
    }
}
