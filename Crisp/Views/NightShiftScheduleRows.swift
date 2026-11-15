import SwiftUI

/// Settings rows that show and edit the macOS Night Shift schedule, the same setting as
/// System Settings > Displays > Night Shift. Stays live when the system changes it.
struct NightShiftScheduleRows: View {
    @ObservedObject private var service = CoreBrightnessService.shared

    var body: some View {
        if let schedule = service.nightShiftSchedule {
            VStack(alignment: .leading, spacing: 0) {
                modeRow(schedule)
                if schedule.mode == .custom {
                    timeRow("From", time: schedule.from) {
                        service.setNightShiftSchedule(from: $0, to: schedule.to)
                    }
                    timeRow("To", time: schedule.to) {
                        service.setNightShiftSchedule(from: schedule.from, to: $0)
                    }
                }
            }
        }
    }

    private func modeRow(_ schedule: NightShiftSchedule) -> some View {
        HStack(spacing: 8) {
            MenuItemIcon(systemName: "moon.stars.fill", color: .orange, active: schedule.mode != .off)
                .accessibilityHidden(true)
            Text("Night Shift Schedule")
                .font(.callout)
            Spacer()
            Picker("Night Shift Schedule", selection: Binding(
                get: { schedule.mode },
                set: { service.setNightShiftMode($0) }
            )) {
                Text("Off").tag(NightShiftScheduleMode.off)
                // Sunset to Sunrise needs Location Services; the system refuses it without them.
                Text("Sunset to Sunrise").tag(NightShiftScheduleMode.sunsetToSunrise)
                    .disabled(!schedule.sunSchedulePermitted)
                Text("Custom").tag(NightShiftScheduleMode.custom)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private func timeRow(_ label: LocalizedStringKey, time: NightShiftTime,
                         onChange: @escaping (NightShiftTime) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .padding(.leading, 28)
            Spacer()
            DatePicker(label, selection: Binding(
                get: { Self.date(for: time) },
                set: { onChange(Self.time(for: $0)) }
            ), displayedComponents: .hourAndMinute)
            .datePickerStyle(.compact)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private static func date(for time: NightShiftTime) -> Date {
        Calendar.current.date(from: time.dateComponents) ?? Date()
    }

    private static func time(for date: Date) -> NightShiftTime {
        NightShiftTime(Calendar.current.dateComponents([.hour, .minute], from: date))
    }
}
