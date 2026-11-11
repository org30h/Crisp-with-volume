import Foundation

/// Per-display maximum speaker volume. The app's volume (slider, keys, HUD) stays
/// on a 0-100 "user" scale meaning percent of the allowed range. This maps it to
/// and from the monitor's own hardware percent. A nil limit means no limit and
/// leaves every value untouched.
enum VolumeLimit {
    /// Limits the user can set: 1...100. Anything outside is pulled in, nil stays nil.
    static func clamped(_ limit: Double?) -> Double? {
        limit.map { max(1.0, min(100.0, $0)) }
    }

    /// Hardware percent for a user-scale volume.
    static func hardware(fromUser user: Double, limit: Double?) -> Double {
        guard let limit = clamped(limit) else { return user }
        return user * limit / 100.0
    }

    /// User-scale volume for a hardware percent, capped at 100 for levels above the limit.
    static func user(fromHardware hardware: Double, limit: Double?) -> Double {
        guard let limit = clamped(limit) else { return hardware }
        return min(100.0, hardware * 100.0 / limit)
    }

    /// True when a raw DDC reading is above the limit. Compares in raw steps, so a
    /// monitor with a coarse range (whose raw value for the limit rounds up) is not
    /// seen as over the limit after we wrote the limit itself.
    static func exceeds(raw: UInt16, ddcMax: UInt16, limit: Double?) -> Bool {
        guard let limit = clamped(limit) else { return false }
        return Double(raw) > (limit / 100.0 * Double(ddcMax)).rounded()
    }

    /// A limit typed by the user: a whole percent from 1 to 100, with an optional
    /// "%" and spaces ("30", "30%", " 30 % "). Anything else is nil.
    static func parse(_ text: String) -> Double? {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.hasSuffix("%") { digits = String(digits.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard let value = Int(digits), (1...100).contains(value) else { return nil }
        return Double(value)
    }
}
