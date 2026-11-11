import XCTest

/// Headless tests for the per-display volume limit math. `VolumeLimit` compiles
/// directly into this test target, so no `@testable import Crisp` is needed.
final class VolumeLimitTests: XCTestCase {

    func testNoLimitIsIdentity() {
        for value in [0.0, 12.5, 50.0, 100.0] {
            XCTAssertEqual(VolumeLimit.hardware(fromUser: value, limit: nil), value)
            XCTAssertEqual(VolumeLimit.user(fromHardware: value, limit: nil), value)
        }
    }

    func testFullUserVolumeIsTheLimit() {
        XCTAssertEqual(VolumeLimit.hardware(fromUser: 100, limit: 30), 30, accuracy: 0.001)
    }

    func testHalfUserVolumeIsHalfTheLimit() {
        XCTAssertEqual(VolumeLimit.hardware(fromUser: 50, limit: 30), 15, accuracy: 0.001)
    }

    func testHardwareAboveLimitClampsToFullUserVolume() {
        XCTAssertEqual(VolumeLimit.user(fromHardware: 45, limit: 30), 100, accuracy: 0.001)
    }

    func testRoundTrip() {
        for limit in [1.0, 10, 25, 50, 75, 100] {
            for user in [0.0, 6.25, 50, 93.75, 100] {
                let hardware = VolumeLimit.hardware(fromUser: user, limit: limit)
                XCTAssertEqual(VolumeLimit.user(fromHardware: hardware, limit: limit), user, accuracy: 0.001)
            }
        }
    }

    func testLimitClamping() {
        XCTAssertEqual(VolumeLimit.clamped(0), 1)
        XCTAssertEqual(VolumeLimit.clamped(150), 100)
        XCTAssertEqual(VolumeLimit.clamped(40), 40)
        XCTAssertNil(VolumeLimit.clamped(nil))
    }

    func testExceedsComparesRawSteps() {
        XCTAssertFalse(VolumeLimit.exceeds(raw: 100, ddcMax: 100, limit: nil))
        XCTAssertFalse(VolumeLimit.exceeds(raw: 30, ddcMax: 100, limit: 30))
        XCTAssertTrue(VolumeLimit.exceeds(raw: 31, ddcMax: 100, limit: 30))
        // 10% of 255 is 25.5, written as 26: reading 26 back is not over the limit.
        XCTAssertFalse(VolumeLimit.exceeds(raw: 26, ddcMax: 255, limit: 10))
        XCTAssertTrue(VolumeLimit.exceeds(raw: 27, ddcMax: 255, limit: 10))
    }

    func testParseAcceptsWholePercents() {
        XCTAssertEqual(VolumeLimit.parse("30"), 30)
        XCTAssertEqual(VolumeLimit.parse("30%"), 30)
        XCTAssertEqual(VolumeLimit.parse(" 30 % "), 30)
        XCTAssertEqual(VolumeLimit.parse("1"), 1)
        XCTAssertEqual(VolumeLimit.parse("100"), 100)
    }

    func testParseRejectsOutOfRangeAndJunk() {
        for text in ["", "%", "0", "101", "-5", "12.5", "abc", "30%%"] {
            XCTAssertNil(VolumeLimit.parse(text), "\"\(text)\" should be rejected")
        }
    }
}
