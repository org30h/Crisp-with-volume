import XCTest

final class NightShiftScheduleTests: XCTestCase {
    func testModeRoundTripsThroughTheSystemValue() {
        for mode in NightShiftScheduleMode.allCases {
            XCTAssertEqual(NightShiftScheduleMode(systemValue: mode.rawValue), mode)
        }
        XCTAssertEqual(NightShiftScheduleMode.off.rawValue, 0)
        XCTAssertEqual(NightShiftScheduleMode.sunsetToSunrise.rawValue, 1)
        XCTAssertEqual(NightShiftScheduleMode.custom.rawValue, 2)
    }

    func testUnknownModeReadsAsOff() {
        XCTAssertEqual(NightShiftScheduleMode(systemValue: 3), .off)
        XCTAssertEqual(NightShiftScheduleMode(systemValue: -1), .off)
    }

    func testTimeRoundTripsThroughDateComponents() {
        for (hour, minute) in [(0, 0), (7, 5), (12, 30), (22, 0), (23, 59)] {
            let time = NightShiftTime(hour: hour, minute: minute)
            XCTAssertEqual(NightShiftTime(time.dateComponents), time)
        }
    }

    func testMissingComponentsReadAsMidnight() {
        XCTAssertEqual(NightShiftTime(DateComponents()), NightShiftTime(hour: 0, minute: 0))
    }

    func testOutOfRangeTimeIsClamped() {
        XCTAssertEqual(NightShiftTime(hour: 27, minute: 75), NightShiftTime(hour: 23, minute: 59))
        XCTAssertEqual(NightShiftTime(hour: -1, minute: -5), NightShiftTime(hour: 0, minute: 0))
    }

    func testMinutesSinceMidnight() {
        XCTAssertEqual(NightShiftTime(hour: 0, minute: 0).minutesSinceMidnight, 0)
        XCTAssertEqual(NightShiftTime(hour: 22, minute: 15).minutesSinceMidnight, 1335)
    }

    func testOvernightRangeIsKeptAsIs() {
        let schedule = NightShiftSchedule(
            mode: .custom, from: NightShiftTime(hour: 22, minute: 0),
            to: NightShiftTime(hour: 7, minute: 0), sunSchedulePermitted: true)
        XCTAssertEqual(schedule.from, NightShiftTime(hour: 22, minute: 0))
        XCTAssertEqual(schedule.to, NightShiftTime(hour: 7, minute: 0))
        XCTAssertTrue(schedule.isOvernight)
    }

    func testSameDayRangeIsNotOvernight() {
        let schedule = NightShiftSchedule(
            mode: .custom, from: NightShiftTime(hour: 1, minute: 0),
            to: NightShiftTime(hour: 5, minute: 30), sunSchedulePermitted: false)
        XCTAssertFalse(schedule.isOvernight)
    }
}
