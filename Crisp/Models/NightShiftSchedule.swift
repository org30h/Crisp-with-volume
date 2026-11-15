import Foundation

/// How macOS schedules Night Shift. Raw values are CoreBrightness's `mode` field.
enum NightShiftScheduleMode: Int32, CaseIterable {
    case off = 0
    case sunsetToSunrise = 1
    case custom = 2

    /// An unknown value reads as off: no schedule is the safe thing to show.
    init(systemValue: Int32) {
        self = Self(rawValue: systemValue) ?? .off
    }
}

/// A wall-clock time of day, as CoreBrightness stores a schedule edge.
struct NightShiftTime: Equatable {
    let hour: Int
    let minute: Int

    /// Clamps to a valid time, so a bad system value cannot produce an out-of-range picker.
    init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    init(_ components: DateComponents) {
        self.init(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }

    var minutesSinceMidnight: Int { hour * 60 + minute }

    var dateComponents: DateComponents { DateComponents(hour: hour, minute: minute) }
}

/// The system Night Shift schedule. `from` and `to` are kept exactly as the system holds
/// them: a range such as 22:00 to 07:00 runs overnight, and nothing here reorders it.
struct NightShiftSchedule: Equatable {
    var mode: NightShiftScheduleMode
    var from: NightShiftTime
    var to: NightShiftTime
    /// False when Location Services are off, so Sunset to Sunrise cannot work.
    var sunSchedulePermitted: Bool

    /// True when the schedule wraps past midnight (`to` is earlier than `from`).
    var isOvernight: Bool { to.minutesSinceMidnight < from.minutesSinceMidnight }
}
