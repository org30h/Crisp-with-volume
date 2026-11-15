import Foundation

/// Smooths a linear gain toward a target, one sample at a time, with a one-pole filter
/// so a volume change never clicks. It never allocates. A target of 0 ends at exactly 0.
struct GainRamp {
    /// Below this and heading for 0, the gain snaps to 0.
    private static let silence: Float = 1e-5

    private let coefficient: Float
    private(set) var current: Float
    var target: Float

    init(sampleRate: Double, timeConstant: Double = 0.02, initial: Float = 1) {
        coefficient = Float(1 - exp(-1 / (timeConstant * sampleRate)))
        current = initial
        target = initial
    }

    /// The gain for the next sample.
    mutating func next() -> Float {
        if current != target {
            current += (target - current) * coefficient
            if target == 0, current < Self.silence {
                current = 0
            } else if abs(target - current) < Self.silence {
                current = target
            }
        }
        return current
    }
}
