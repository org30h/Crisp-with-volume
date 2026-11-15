import XCTest

final class GainRampTests: XCTestCase {
    private let rate = 48_000.0

    func testReachesTargetWithin100ms() {
        var ramp = GainRamp(sampleRate: rate)
        ramp.target = 0.1
        var gain: Float = 1
        for _ in 0..<Int(rate * 0.1) { gain = ramp.next() }
        // Within 1% of the 1.0 -> 0.1 step.
        XCTAssertEqual(gain, 0.1, accuracy: 0.9 * 0.01)
    }

    func testStepIsSmoothPerSample() {
        var ramp = GainRamp(sampleRate: rate)
        ramp.target = 0.1
        var last: Float = 1
        for _ in 0..<Int(rate) {
            let gain = ramp.next()
            XCTAssertLessThanOrEqual(abs(gain - last), 0.01)
            last = gain
        }
    }

    func testZeroTargetEndsAtExactlyZero() {
        var ramp = GainRamp(sampleRate: rate)
        ramp.target = 0
        var gain: Float = 1
        for _ in 0..<Int(rate) { gain = ramp.next() }
        XCTAssertEqual(gain, 0)
    }

    func testDeterministic() {
        func run() -> [Float] {
            var ramp = GainRamp(sampleRate: rate)
            ramp.target = 0.3
            return (0..<1000).map { _ in ramp.next() }
        }
        XCTAssertEqual(run(), run())
    }

    func testStaysAtTarget() {
        var ramp = GainRamp(sampleRate: rate)
        for _ in 0..<100 { XCTAssertEqual(ramp.next(), 1) }
    }
}
