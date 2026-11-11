import Foundation

/// Slow, linked-gain loudness leveler with a final peak limiter. Pure DSP, Foundation only,
/// so it unit-tests headlessly. The audio engine calls `process` from a real-time IOProc:
/// everything it touches is preallocated in `init`, and `process` never allocates, locks or logs.
///
/// Signal path per frame (all channels share one gain, so stereo images stay put):
///   measure : 100 Hz high-pass, mean square over all channels, ~400 ms one-pole window
///   gain    : toward `targetDB`, clamped to `minGainDB...maxGainDB`; falls fast, rises slowly;
///             held while the measured level is under `silenceGateDB`
///   limiter : peak limiter at `ceilingDB` with a short lookahead delay, then a hard clamp
///
/// ponytail: this is a plain RMS estimate, not EBU R128 K-weighting or gating.
final class LoudnessLeveler: @unchecked Sendable {
    // Constants, not UI.
    static let targetDB: Float = -20
    static let minGainDB: Float = -20
    static let maxGainDB: Float = 12
    static let silenceGateDB: Float = -50
    static let ceilingDB: Float = -1
    static let measureWindowSeconds: Double = 0.4
    static let gainFallSeconds: Double = 0.3
    static let gainRiseSeconds: Double = 3.0
    static let highPassHz: Double = 100
    static let limiterLookaheadSeconds: Double = 0.003
    static let limiterReleaseSeconds: Double = 0.08
    /// Frames between gain updates. The log10 runs once per block, not per sample.
    static let controlBlockFrames = 64

    let channelCount: Int
    let sampleRate: Double

    /// Latest measured level (dBFS RMS, high-passed) and applied leveler gain (dB).
    /// Plain stored floats: the audio thread writes, a timer reads, a torn value is harmless.
    private(set) var inputLevelDB: Float = -120
    private(set) var gainDB: Float = 0

    // Measurement.
    private let hpCoef: Float
    private var hpPrevIn: UnsafeMutablePointer<Float>
    private var hpPrevOut: UnsafeMutablePointer<Float>
    private let windowCoef: Float
    private var meanSquare: Float = 0
    private var blockCounter = 0

    // Gain.
    private let fallCoef: Float
    private let riseCoef: Float
    private var currentGain: Float = 1
    private var gainStep: Float = 0
    private var nextGain: Float = 1

    // Limiter.
    private let ceiling: Float
    private let lookahead: Int
    private let delayLine: UnsafeMutablePointer<Float>
    private var delayPos = 0
    private let attackStep: Float
    private let releaseCoef: Float
    private var limiterGain: Float = 1
    private var holdTarget: Float = 1
    private var holdCount = 0

    init(sampleRate: Double, channelCount: Int) {
        precondition(channelCount > 0 && sampleRate > 0)
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        let hpPole = exp(-2 * Double.pi * Self.highPassHz / sampleRate)
        hpCoef = Float(hpPole)
        windowCoef = Float(1 - exp(-1 / (Self.measureWindowSeconds * sampleRate)))
        let blockSeconds = Double(Self.controlBlockFrames) / sampleRate
        fallCoef = Float(1 - exp(-blockSeconds / Self.gainFallSeconds))
        riseCoef = Float(1 - exp(-blockSeconds / Self.gainRiseSeconds))
        ceiling = Float(pow(10, Double(Self.ceilingDB) / 20))
        lookahead = max(1, Int((Self.limiterLookaheadSeconds * sampleRate).rounded()))
        attackStep = 1 / Float(lookahead)
        releaseCoef = Float(1 - exp(-1 / (Self.limiterReleaseSeconds * sampleRate)))
        hpPrevIn = .allocate(capacity: channelCount)
        hpPrevOut = .allocate(capacity: channelCount)
        hpPrevIn.initialize(repeating: 0, count: channelCount)
        hpPrevOut.initialize(repeating: 0, count: channelCount)
        delayLine = .allocate(capacity: (lookahead + 1) * channelCount)
        delayLine.initialize(repeating: 0, count: (lookahead + 1) * channelCount)
    }

    deinit {
        hpPrevIn.deallocate()
        hpPrevOut.deallocate()
        delayLine.deallocate()
    }

    /// Processes `frames` interleaved Float32 frames in place. Non-finite input counts as silence.
    /// The output is delayed by `lookaheadFrames`.
    func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        let channels = channelCount
        let invChannels = 1 / Float(channels)
        var frame = 0
        while frame < frames {
            // The leveler gain moves linearly across each control block.
            let blockEnd = min(frames, frame + (Self.controlBlockFrames - blockCounter))
            blockCounter += blockEnd - frame
            var gain = currentGain
            while frame < blockEnd {
                let base = frame * channels
                let slot = delayPos * channels
                var energy: Float = 0
                var peak: Float = 0
                for c in 0..<channels {
                    var x = samples[base + c]
                    if !x.isFinite { x = 0 }
                    let hp = hpCoef * (hpPrevOut[c] + x - hpPrevIn[c])
                    hpPrevIn[c] = x
                    hpPrevOut[c] = hp
                    energy += hp * hp

                    let leveled = x * gain
                    peak = max(peak, abs(leveled))
                    // Swap the leveled sample into the delay line and emit the old one.
                    samples[base + c] = delayLine[slot + c]
                    delayLine[slot + c] = leveled
                }
                meanSquare += windowCoef * (energy * invChannels - meanSquare)
                gain += gainStep

                // Limiter gain from the incoming peak, applied to the delayed samples.
                let needed: Float = peak > ceiling ? ceiling / peak : 1
                if needed < holdTarget {
                    holdTarget = needed
                    holdCount = lookahead
                } else if holdCount > 0 {
                    holdCount -= 1
                } else {
                    holdTarget = 1
                }
                if limiterGain > holdTarget {
                    limiterGain = max(holdTarget, limiterGain - attackStep)
                } else {
                    limiterGain += (holdTarget - limiterGain) * releaseCoef
                }
                for c in 0..<channels {
                    samples[base + c] = min(max(samples[base + c] * limiterGain, -ceiling), ceiling)
                }
                delayPos += 1
                if delayPos > lookahead { delayPos = 0 }
                frame += 1
            }
            currentGain = gain
            if blockCounter == Self.controlBlockFrames {
                blockCounter = 0
                updateGain()
            }
        }
    }

    /// Delay the limiter adds, in frames.
    var lookaheadFrames: Int { lookahead }

    /// Once per control block: measure, pick the next gain, set the per-sample ramp for the next block.
    private func updateGain() {
        currentGain = nextGain
        let levelDB = 10 * log10(max(meanSquare, 1e-12))
        inputLevelDB = levelDB
        // Below the gate the gain holds, so pauses and noise are not pumped up.
        if levelDB >= Self.silenceGateDB {
            let desired = min(max(Self.targetDB - levelDB, Self.minGainDB), Self.maxGainDB)
            let coef = desired < gainDB ? fallCoef : riseCoef
            gainDB += (desired - gainDB) * coef
        }
        nextGain = pow(10, gainDB / 20)
        gainStep = (nextGain - currentGain) / Float(Self.controlBlockFrames)
    }
}
