import CoreAudio
import Foundation

/// Real-time half of loudness normalization and combined volume: copies the tap input into a
/// scratch buffer, levels it (when leveling is on), applies the software volume gain and writes
/// the result to the output buffers.
///
/// `render` runs on the HAL IO thread. It does not allocate, take locks, log, or hop actors:
/// every buffer is allocated in `init`, state lives in plain stored properties, and the
/// non-RT side only reads the meters (a torn or stale value is harmless).
final class LoudnessIOProcessor: @unchecked Sendable {
    /// Frames handled per leveler call. Larger IO buffers are processed in several chunks.
    static let chunkFrames = 512
    static let maxChannels = 8

    let channelCount: Int
    let sampleRate: Double
    let leveler: LoudnessLeveler
    private let inputPlanar: Bool
    private let outputPlanar: Bool
    private let scratch: UnsafeMutablePointer<Float>

    // Written by the IO thread, read by the timer.
    private(set) var consecutiveZeroFrames = 0
    private(set) var sawSignal = false
    /// Set by the IO thread when a buffer does not match the layout validated at start.
    private(set) var layoutMismatch = false
    /// Set by the owner. When false the leveler is skipped and the tap is a plain copy.
    var levelingEnabled = true
    /// Target linear software volume gain, set by the owner. Applied after the leveler so it
    /// cannot undo the attenuation, and smoothed per sample by `GainRamp`.
    var softwareGain: Float = 1
    /// The gain actually applied at the end of the last buffer, for the meter log.
    private(set) var appliedGain: Float = 1
    private var ramp: GainRamp
    /// Set by `stop` before the IOProc is retired. While true, `render` writes silence.
    var disabled = true

    init(channelCount: Int, sampleRate: Double, inputPlanar: Bool, outputPlanar: Bool,
         softwareGain: Float = 1, levelingEnabled: Bool = true) {
        precondition(channelCount >= 1 && channelCount <= Self.maxChannels)
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.inputPlanar = inputPlanar
        self.outputPlanar = outputPlanar
        self.softwareGain = softwareGain
        self.levelingEnabled = levelingEnabled
        appliedGain = softwareGain
        ramp = GainRamp(sampleRate: sampleRate, initial: softwareGain)
        leveler = LoudnessLeveler(sampleRate: sampleRate, channelCount: channelCount)
        scratch = .allocate(capacity: Self.chunkFrames * channelCount)
        scratch.initialize(repeating: 0, count: Self.chunkFrames * channelCount)
    }

    deinit { scratch.deallocate() }

    private static func zero(_ list: UnsafeMutableAudioBufferListPointer) {
        for index in 0..<list.count {
            if let data = list[index].mData { memset(data, 0, Int(list[index].mDataByteSize)) }
        }
    }

    /// Levels the interleaved scratch (when on), then multiplies it by the smoothed software
    /// gain, which is skipped while it sits at exactly 1. The gain comes last so the leveler
    /// cannot undo the attenuation.
    private func levelAndAttenuate(_ ramp: inout GainRamp, leveling: Bool, frames: Int) {
        if leveling { leveler.process(scratch, frames: frames) }
        guard ramp.current != 1 || ramp.target != 1 else { return }
        let channels = channelCount
        for f in 0..<frames {
            let g = ramp.next()
            for c in 0..<channels { scratch[f * channels + c] *= g }
        }
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let out = UnsafeMutableAudioBufferListPointer(output)
        let channels = channelCount
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard !disabled, inList.count == (inputPlanar ? channels : 1), out.count == (outputPlanar ? channels : 1) else {
            Self.zero(out)
            if !disabled { layoutMismatch = true }
            return
        }
        let inBytes = Int(inList[0].mDataByteSize)
        let outBytes = Int(out[0].mDataByteSize)
        let inStride = (inputPlanar ? 1 : channels) * MemoryLayout<Float>.size
        let outStride = (outputPlanar ? 1 : channels) * MemoryLayout<Float>.size
        let frames = inBytes / inStride
        guard inBytes == frames * inStride, outBytes == frames * outStride else {
            Self.zero(out)
            layoutMismatch = true
            return
        }
        for index in 0..<inList.count where inList[index].mData == nil || Int(inList[index].mDataByteSize) != inBytes {
            Self.zero(out)
            layoutMismatch = true
            return
        }
        for index in 0..<out.count where out[index].mData == nil || Int(out[index].mDataByteSize) != outBytes {
            Self.zero(out)
            layoutMismatch = true
            return
        }

        var done = 0
        var chunkPeak: Float = 0
        let leveling = levelingEnabled
        var gainRamp = ramp
        gainRamp.target = softwareGain
        while done < frames {
            let n = min(Self.chunkFrames, frames - done)
            // Gather into interleaved scratch.
            if inputPlanar {
                for c in 0..<channels {
                    let src = inList[c].mData!.assumingMemoryBound(to: Float.self) + done
                    for f in 0..<n {
                        let v = src[f]
                        scratch[f * channels + c] = v
                        chunkPeak = max(chunkPeak, abs(v))
                    }
                }
            } else {
                let src = inList[0].mData!.assumingMemoryBound(to: Float.self) + done * channels
                for i in 0..<(n * channels) {
                    let v = src[i]
                    scratch[i] = v
                    chunkPeak = max(chunkPeak, abs(v))
                }
            }
            levelAndAttenuate(&gainRamp, leveling: leveling, frames: n)
            // Scatter to the output layout.
            if outputPlanar {
                for c in 0..<channels {
                    let dst = out[c].mData!.assumingMemoryBound(to: Float.self) + done
                    for f in 0..<n { dst[f] = scratch[f * channels + c] }
                }
            } else {
                let dst = out[0].mData!.assumingMemoryBound(to: Float.self) + done * channels
                for i in 0..<(n * channels) { dst[i] = scratch[i] }
            }
            done += n
        }
        ramp = gainRamp
        appliedGain = gainRamp.current
        if chunkPeak > 0 {
            sawSignal = true
            consecutiveZeroFrames = 0
        } else {
            consecutiveZeroFrames &+= frames
        }
    }
}
