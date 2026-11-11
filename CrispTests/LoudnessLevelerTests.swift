import XCTest

/// Headless tests for the loudness leveler. `LoudnessLeveler` compiles directly into this
/// test target (see project.yml), so no `@testable import Crisp` is needed.
final class LoudnessLevelerTests: XCTestCase {
    private let rate = 48000.0
    private let target = Double(LoudnessLeveler.targetDB)
    private let ceilingLinear = Float(pow(10, (Double(LoudnessLeveler.ceilingDB) + 0.1) / 20))

    /// Value of one sample, from the global frame number and the channel.
    private typealias Source = (_ frame: Int, _ channel: Int) -> Float

    private func dB(_ linear: Double) -> Double { 20 * log10(max(linear, 1e-12)) }
    private func linear(_ db: Double) -> Double { pow(10, db / 20) }

    /// Sine whose RMS is `rmsDB` dBFS (the peak is 3 dB higher).
    private func sine(rmsDB: Double, hz: Double = 1000) -> Source {
        let amp = linear(rmsDB) * 2.0.squareRoot()
        let step = 2 * Double.pi * hz / rate
        return { frame, _ in Float(amp * sin(step * Double(frame))) }
    }

    /// Deterministic uniform noise with RMS `rmsDB` dBFS.
    private func noise(rmsDB: Double) -> Source {
        let amp = linear(rmsDB) * 3.0.squareRoot()
        return { frame, channel in
            var x = UInt64(truncatingIfNeeded: frame &* 8 &+ channel) &* 6364136223846793005 &+ 1442695040888963407
            x ^= x >> 33
            x = x &* 0xff51afd7ed558ccd
            x ^= x >> 33
            return Float(amp * (Double(x % 2_000_001) / 1_000_000 - 1))
        }
    }

    private func silence() -> Source { { _, _ in 0 } }

    /// Full-scale square wave, 1 kHz.
    private func square() -> Source { { f, _ in (f / 24) % 2 == 0 ? 1 : -1 } }

    /// Runs the leveler over `seconds` of `source` and returns the output. `startFrame` keeps
    /// the source phase continuous across calls.
    @discardableResult
    private func run(_ leveler: LoudnessLeveler, seconds: Double, startFrame: Int = 0, chunk: Int = 512,
                     source: Source) -> [Float] {
        let channels = leveler.channelCount
        let total = Int(seconds * rate)
        var output: [Float] = []
        output.reserveCapacity(total * channels)
        var buffer = [Float](repeating: 0, count: chunk * channels)
        var done = 0
        while done < total {
            let n = min(chunk, total - done)
            for f in 0..<n {
                for c in 0..<channels { buffer[f * channels + c] = source(startFrame + done + f, c) }
            }
            buffer.withUnsafeMutableBufferPointer { leveler.process($0.baseAddress!, frames: n) }
            output.append(contentsOf: buffer[0..<(n * channels)])
            done += n
        }
        return output
    }

    /// RMS of one channel over the last `seconds` of `output`, in dBFS.
    private func tailRMS(_ output: [Float], channels: Int, channel: Int = 0, seconds: Double = 0.5) -> Double {
        let frames = output.count / channels
        let n = Int(seconds * rate)
        var sum = 0.0
        for f in (frames - n)..<frames {
            let v = Double(output[f * channels + channel])
            sum += v * v
        }
        return dB((sum / Double(n)).squareRoot())
    }

    // MARK: - Level

    /// -30 dBFS needs +10 dB, inside the +12 dB limit, so it reaches the target.
    func testQuietSineConvergesToTarget() {
        let leveler = LoudnessLeveler(sampleRate: rate, channelCount: 2)
        let src = sine(rmsDB: -30)
        let out = run(leveler, seconds: 15, source: src)
        XCTAssertEqual(tailRMS(out, channels: 2), target, accuracy: 2)
    }

    /// -40 dBFS needs +20 dB but the gain stops at +12 dB: it must get there and go no further.
    func testVeryQuietSineStopsAtMaxGain() {
        let leveler = LoudnessLeveler(sampleRate: rate, channelCount: 2)
        let out = run(leveler, seconds: 25, source: sine(rmsDB: -40))
        let maxGain = Double(LoudnessLeveler.maxGainDB)
        XCTAssertEqual(tailRMS(out, channels: 2), -40 + maxGain, accuracy: 2)
        XCTAssertLessThanOrEqual(Double(leveler.gainDB), maxGain + 0.001)
        XCTAssertGreaterThan(Double(leveler.gainDB), maxGain - 1)
    }

    func testLoudSineIsReducedToTarget() {
        let leveler = LoudnessLeveler(sampleRate: rate, channelCount: 2)
        let out = run(leveler, seconds: 8, source: sine(rmsDB: -6))
        XCTAssertEqual(tailRMS(out, channels: 2), target, accuracy: 2)
    }

    // MARK: - Limiter

    func testFullScaleBurstAfterQuietNeverExceedsCeiling() {
        let leveler = LoudnessLeveler(sampleRate: rate, channelCount: 2)
        run(leveler, seconds: 12, source: sine(rmsDB: -40))
        XCTAssertGreaterThan(leveler.gainDB, 6, "precondition: gain has risen")
        let fullScaleSine: Source = { f, _ in Float(sin(2 * Double.pi * 1000 * Double(f) / self.rate)) }
        for source in [fullScaleSine, square()] {
            let out = run(leveler, seconds: 1, source: source)
            XCTAssertLessThanOrEqual(out.map { abs($0) }.max() ?? 0, ceilingLinear)
        }
    }

    // MARK: - Silence gate

    func testGainDoesNotRiseDuringDigitalSilence() {
        let leveler = LoudnessLeveler(sampleRate: rate, channelCount: 2)
        run(leveler, seconds: 3, source: sine(rmsDB: -40))
        // Let the 400 ms measurement window drain below the gate, then check the gain holds.
        run(leveler, seconds: 3, startFrame: 3 * 48000, source: silence())
        let held = leveler.gainDB
        run(leveler, seconds: 10, startFrame: 6 * 48000, source: silence())
        XCTAssertEqual(leveler.gainDB, held, accuracy: 0.0001)
    }

    func testGainDoesNotRiseForQuietNoise() {
        let leveler = LoudnessLeveler(sampleRate: rate, channelCount: 2)
        run(leveler, seconds: 15, source: noise(rmsDB: -60))
        XCTAssertEqual(leveler.gainDB, 0, accuracy: 0.0001)
    }

    func testGainHoldsWhenLoudMaterialStops() {
        let leveler = LoudnessLeveler(sampleRate: rate, channelCount: 2)
        run(leveler, seconds: 4, source: sine(rmsDB: -6))
        XCTAssertLessThan(leveler.gainDB, -10, "precondition: gain was pulled down")
        // The 400 ms window needs about 4 s to fall from -9 dB to the -50 dB gate.
        run(leveler, seconds: 8, startFrame: 4 * 48000, source: silence())
        let held = leveler.gainDB
        run(leveler, seconds: 10, startFrame: 12 * 48000, source: noise(rmsDB: -70))
        XCTAssertEqual(leveler.gainDB, held, accuracy: 0.0001)
    }

    // MARK: - Gain range

    func testGainStaysWithinRange() {
        let leveler = LoudnessLeveler(sampleRate: rate, channelCount: 2)
        let lo = Double(LoudnessLeveler.minGainDB) - 0.001
        let hi = Double(LoudnessLeveler.maxGainDB) + 0.001
        let scenarios: [(Double, Source)] = [
            (6, square()), (6, silence()), (20, sine(rmsDB: -55)), (6, sine(rmsDB: -3)), (6, silence()),
            (20, sine(rmsDB: -45)), (6, square())
        ]
        var start = 0
        for (seconds, source) in scenarios {
            // Check every half second, not only at the end.
            for _ in 0..<Int(seconds * 2) {
                run(leveler, seconds: 0.5, startFrame: start, source: source)
                start += 24000
                XCTAssertGreaterThanOrEqual(Double(leveler.gainDB), lo)
                XCTAssertLessThanOrEqual(Double(leveler.gainDB), hi)
            }
        }
        // A long full-scale square must sit on the lower limit.
        run(leveler, seconds: 10, startFrame: start, source: square())
        XCTAssertEqual(Double(leveler.gainDB), Double(LoudnessLeveler.minGainDB), accuracy: 0.5)
    }

    // MARK: - Determinism and layout

    func testProcessingIsDeterministicAndIndependentOfChunkSize() {
        let src = sine(rmsDB: -30)
        let a = run(LoudnessLeveler(sampleRate: rate, channelCount: 2), seconds: 3, chunk: 512, source: src)
        let b = run(LoudnessLeveler(sampleRate: rate, channelCount: 2), seconds: 3, chunk: 512, source: src)
        let c = run(LoudnessLeveler(sampleRate: rate, channelCount: 2), seconds: 3, chunk: 37, source: src)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c)
    }

    func testHandlesOneTwoAndSixChannels() {
        for channels in [1, 2, 6] {
            let leveler = LoudnessLeveler(sampleRate: rate, channelCount: channels)
            // Channel 1 (when present) is 6 dB quieter: linked gain must keep that difference.
            let base = sine(rmsDB: -30)
            let out = run(leveler, seconds: 15) { f, c in c == 1 ? base(f, 0) * 0.5 : base(f, 0) }
            XCTAssertTrue(out.allSatisfy { $0.isFinite }, "\(channels) channels")
            XCTAssertEqual(tailRMS(out, channels: channels), target, accuracy: 2, "\(channels) channels")
            if channels > 1 {
                let diff = tailRMS(out, channels: channels, channel: 0) - tailRMS(out, channels: channels, channel: 1)
                XCTAssertEqual(diff, 6.02, accuracy: 0.2, "\(channels) channels")
            }
        }
    }

    func testNonFiniteInputProducesFiniteOutput() {
        let leveler = LoudnessLeveler(sampleRate: rate, channelCount: 2)
        let src = sine(rmsDB: -20)
        let out = run(leveler, seconds: 1) { f, c in
            f % 1000 == 0 ? (c == 0 ? .nan : .infinity) : src(f, 0)
        }
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
        XCTAssertTrue(leveler.gainDB.isFinite)
    }
}
