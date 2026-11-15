import SwiftUI

/// Settings rows that pick the preset applied when Night Shift turns on and off.
struct NightShiftPresetPickers: View {
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var presets = PresetService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NightShiftScheduleRows()
            row("When Night Shift turns on", selection: $settings.nightShiftOnPresetID)
            row("When Night Shift turns off", selection: $settings.nightShiftOffPresetID)
        }
    }

    private func row(_ label: LocalizedStringKey, selection: Binding<UUID?>) -> some View {
        HStack(spacing: 8) {
            MenuItemIcon(systemName: "moon.stars.fill", color: .orange, active: selection.wrappedValue != nil)
                .accessibilityHidden(true)
            Text(label)
                .font(.callout)
            Spacer()
            if presets.presets.isEmpty {
                // An empty menu only says None, which hides why there is nothing to pick.
                Text("Save a preset first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // A deleted preset's stale ID has no tag, so the menu shows None, which is
                // also what the trigger does with it.
                Picker(label, selection: selection) {
                    Text("None").tag(UUID?.none)
                    ForEach(presets.presets) { preset in
                        Text(verbatim: preset.name).tag(UUID?.some(preset.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}
