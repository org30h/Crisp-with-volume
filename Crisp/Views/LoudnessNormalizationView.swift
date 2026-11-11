import SwiftUI

/// Per-display Normalize Loudness switch, styled like VolumeOverrideView. Shown for an
/// external, non-virtual display that has its own CoreAudio output, on macOS 14.2 or later
/// (the Core Audio tap it needs does not exist before).
struct LoudnessNormalizationView: View {
    @ObservedObject var display: DisplayInfo

    var body: some View {
        if #available(macOS 14.2, *) {
            LoudnessNormalizationRow(display: display)
        }
    }
}

@available(macOS 14.2, *)
private struct LoudnessNormalizationRow: View {
    @ObservedObject var display: DisplayInfo
    @ObservedObject private var service = LoudnessNormalizationService.shared
    @State private var isHovered = false

    var body: some View {
        if service.isAvailable(for: display) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    MenuItemIcon(systemName: "waveform", color: .teal, active: service.isEnabled(display))
                    Text("Normalize Loudness")
                        .font(.body)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { service.isEnabled(display) },
                        set: { service.setEnabled($0, for: display) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .menuRowHover(isHovered)
                .onHover { isHovered = $0 }
                .help("Evens out loud and quiet parts on this monitor's speakers. Audio is processed on this Mac only.")

                if service.activeDisplayUUID == display.displayUUID, service.permissionLikelyDenied {
                    Text("""
                        No sound is reaching Crisp. Allow Crisp under System Settings > Privacy & Security > \
                        Screen & System Audio Recording > System Audio Recording Only.
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 3)
                }
            }
        }
    }
}
