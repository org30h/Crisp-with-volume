import XCTest

/// Headless tests for the combined hardware and software volume split.
final class CombinedVolumeTests: XCTestCase {
    private let floor = CombinedVolume.floorPercent(ddcMax: 100)

    private func dB(_ gain: Float) -> Double { 20 * log10(Double(gain)) }

    func testFloorPercent() {
        XCTAssertEqual(CombinedVolume.floorPercent(ddcMax: 100), 1, accuracy: 1e-9)
        XCTAssertEqual(CombinedVolume.floorPercent(ddcMax: 255), 0.392, accuracy: 0.001)
    }

    func testZeroIsSilentOnBothSides() {
        let s = CombinedVolume.split(user: 0, limit: nil, floor: floor)
        XCTAssertEqual(s.hardwarePercent, 0)
        XCTAssertEqual(s.softwareGain, 0)
    }

    func testSoftwareRegionHoldsFloor() {
        let half = CombinedVolume.split(user: 12.5, limit: nil, floor: floor)
        XCTAssertEqual(half.hardwarePercent, floor, accuracy: 1e-9)
        XCTAssertEqual(dB(half.softwareGain), -20, accuracy: 0.01)

        let split = CombinedVolume.split(user: 25, limit: nil, floor: floor)
        XCTAssertEqual(split.hardwarePercent, floor, accuracy: 1e-9)
        XCTAssertEqual(dB(split.softwareGain), 0, accuracy: 0.01)
    }

    func testFullVolumeIsTop() {
        let full = CombinedVolume.split(user: 100, limit: nil, floor: floor)
        XCTAssertEqual(full.hardwarePercent, 100, accuracy: 1e-9)
        XCTAssertEqual(full.softwareGain, 1)
        let limited = CombinedVolume.split(user: 100, limit: 30, floor: floor)
        XCTAssertEqual(limited.hardwarePercent, 30, accuracy: 1e-9)
    }

    func testFloorAtOrAboveTopUsesTop() {
        let s = CombinedVolume.split(user: 60, limit: 1, floor: 1)
        XCTAssertEqual(s.hardwarePercent, 1, accuracy: 1e-9)
        XCTAssertEqual(s.softwareGain, 1)
    }

    func testPerceivedLevelNeverDecreases() {
        for limit in [nil, 30.0, 100.0] as [Double?] {
            for ddcMax in [UInt16(100), 255] {
                let f = CombinedVolume.floorPercent(ddcMax: ddcMax)
                var previous = -1.0
                var user = 0.0
                while user <= 100 {
                    let s = CombinedVolume.split(user: user, limit: limit, floor: f)
                    let level = s.hardwarePercent * Double(s.softwareGain)
                    XCTAssertGreaterThanOrEqual(level, previous - 1e-9, "user \(user)")
                    previous = level
                    user += 0.5
                }
            }
        }
    }

    func testReadbackInvertsUpperRegion() {
        var user = 25.0
        while user <= 100 {
            let hardware = CombinedVolume.split(user: user, limit: nil, floor: floor).hardwarePercent
            let back = CombinedVolume.user(fromHardware: hardware, limit: nil, floor: floor, current: 0)
            XCTAssertEqual(back, user, accuracy: 0.01, "user \(user)")
            user += 0.5
        }
    }

    /// With a limit one raw step spans several user points, so a monitor can only report whole
    /// steps. Every whole step reads back to the user value that wrote it.
    func testReadbackInvertsEveryWholeStepUnderALimit() {
        for raw in 1...30 {
            let user = 25.0 + Double(raw - 1) / 29.0 * 75.0
            let hardware = CombinedVolume.split(user: user, limit: 30, floor: floor).hardwarePercent
            XCTAssertEqual(hardware, Double(raw), accuracy: 1e-9)
            let back = CombinedVolume.user(fromHardware: Double(raw), limit: 30, floor: floor, current: 0)
            XCTAssertEqual(back, user, accuracy: 0.01, "raw \(raw)")
        }
    }

    func testReadbackAtFloor() {
        XCTAssertEqual(CombinedVolume.user(fromHardware: floor, limit: nil, floor: floor, current: 10), 10)
        XCTAssertEqual(CombinedVolume.user(fromHardware: floor, limit: nil, floor: floor, current: 0), 25)
        XCTAssertEqual(CombinedVolume.user(fromHardware: floor, limit: nil, floor: floor, current: 25), 25)
        XCTAssertEqual(CombinedVolume.user(fromHardware: floor, limit: nil, floor: floor, current: 80), 25)
    }

    func testReadbackOfMuteAndOverLimit() {
        XCTAssertEqual(CombinedVolume.user(fromHardware: 0, limit: nil, floor: floor, current: 10), 0)
        XCTAssertEqual(CombinedVolume.user(fromHardware: 45, limit: 30, floor: floor, current: 50), 100)
    }
}
