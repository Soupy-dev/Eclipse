import XCTest
@testable import Eclipse

#if os(iOS)

final class ProfileLaunchGateTests: XCTestCase {

    private func decision(
        isLocked: Bool,
        profileCount: Int,
        asksOnLaunch: Bool
    ) -> (presentsPicker: Bool, goesStraightToPIN: Bool) {

        let hasMultiple = profileCount > 1
        let presentsPicker = isLocked || (hasMultiple && asksOnLaunch)
        let goesStraightToPIN = isLocked && (!asksOnLaunch || !hasMultiple)
        return (presentsPicker, goesStraightToPIN)
    }

    func testSingleLockedProfileIsAskedForItsPIN() {
        let d = decision(isLocked: true, profileCount: 1, asksOnLaunch: false)
        XCTAssertTrue(d.presentsPicker, "a locked sole profile must still be gated at launch")
        XCTAssertTrue(d.goesStraightToPIN, "with nobody to choose between, skip the chooser")
    }

    func testSingleLockedProfileSkipsChooserEvenWhenAskOnLaunchIsOn() {
        let d = decision(isLocked: true, profileCount: 1, asksOnLaunch: true)
        XCTAssertTrue(d.presentsPicker)
        XCTAssertTrue(d.goesStraightToPIN, "there is no one to choose between")
    }

    func testSingleUnlockedProfileResumesWithoutAPrompt() {
        let d = decision(isLocked: false, profileCount: 1, asksOnLaunch: true)
        XCTAssertFalse(d.presentsPicker)
        XCTAssertFalse(d.goesStraightToPIN)
    }

    func testTurningOffAskOnLaunchDoesNotBypassALock() {
        let d = decision(isLocked: true, profileCount: 3, asksOnLaunch: false)
        XCTAssertTrue(d.presentsPicker, "\"Ask on Launch\" is a convenience, not a lock override")
        XCTAssertTrue(d.goesStraightToPIN)
    }

    func testMultipleUnlockedProfilesShowTheChooserOnlyWhenAsked() {
        XCTAssertTrue(decision(isLocked: false, profileCount: 3, asksOnLaunch: true).presentsPicker)
        XCTAssertFalse(decision(isLocked: false, profileCount: 3, asksOnLaunch: false).presentsPicker)
    }

    func testLockedProfileAmongManyWithAskOnLaunchShowsTheChooserFirst() {
        let d = decision(isLocked: true, profileCount: 3, asksOnLaunch: true)
        XCTAssertTrue(d.presentsPicker)
        XCTAssertFalse(d.goesStraightToPIN, "who is watching is still a real question here")
    }
}
#endif
