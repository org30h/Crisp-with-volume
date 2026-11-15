import Foundation

/// Combined hardware and software volume. The 0-100 user scale splits in two. The top
/// three quarters drive the monitor's DDC volume from its quietest step up to the
/// allowed top. The bottom quarter holds the monitor at that quietest step and lowers
/// the sound on this Mac instead, from 0 dB at the split down to `minSoftwareDB`. User 0
/// is mute on both sides, so mute holds even if the software stage is not running.
///
/// Failure behavior: when the software stage stops or never starts, the monitor sits at
/// its floor step for 0 < user < splitUser. That is the monitor's quietest level, never
/// louder than what the user picked.
enum CombinedVolume {
    /// User-scale point where software attenuation ends and hardware control begins.
    static let splitUser = 25.0
    /// Software attenuation just above user 0.
    static let minSoftwareDB = -40.0

    /// One raw DDC step as a hardware percent.
    static func floorPercent(ddcMax: UInt16) -> Double {
        100.0 / Double(max(1, ddcMax))
    }

    /// Hardware percent to write and linear software gain for a user-scale volume.
    static func split(user: Double, limit: Double?, floor: Double) -> (hardwarePercent: Double, softwareGain: Float) {
        guard user > 0 else { return (0, 0) }
        if user < splitUser {
            let dB = minSoftwareDB * (1 - user / splitUser)
            return (floor, Float(pow(10.0, dB / 20.0)))
        }
        let top = VolumeLimit.clamped(limit) ?? 100.0
        guard floor < top else { return (top, 1) }
        let hardware = floor + (min(user, 100.0) - splitUser) / (100.0 - splitUser) * (top - floor)
        return (hardware, 1)
    }

    /// User-scale volume for a hardware percent read back from the monitor.
    /// `current` is the volume the user had set, used to keep a software-region level
    /// when the monitor reports its floor.
    static func user(fromHardware hardware: Double, limit: Double?, floor: Double, current: Double) -> Double {
        guard hardware > 0 else { return 0 }
        let top = VolumeLimit.clamped(limit) ?? 100.0
        guard floor < top else { return hardware >= top ? 100.0 : splitUser }
        // Within half a raw step of the floor. The step is `floor` percent wide.
        if hardware < floor + floor / 2 {
            return current > 0 && current < splitUser ? current : splitUser
        }
        let user = splitUser + (hardware - floor) / (top - floor) * (100.0 - splitUser)
        return min(100.0, user)
    }
}
