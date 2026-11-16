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
    @State private var permissionDenied = false

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
                        set: { setEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .menuRowHover(isHovered)
                .onHover { isHovered = $0 }
                .help("""
                    Keeps the volume even across sound sources on this monitor's speakers, so a loud \
                    ad, a quiet video and different apps all play at a similar level. Needs the System \
                    Audio Recording permission, because Crisp has to examine the audio first to even out \
                    its loudness. Audio is processed on this Mac only, never recorded or sent anywhere.
                    """)

                if permissionDenied {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Crisp needs System Audio Recording to examine the audio first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Open Settings") { AudioCapturePermission.openSettings() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 3)
                } else if service.activeDisplayUUID == display.displayUUID, service.permissionLikelyDenied {
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

    /// Turning on asks for System Audio Recording first: the system prompt when it was
    /// never answered, or System Settings when it was denied (macOS won't prompt twice).
    /// The switch stays off until the permission is there.
    private func setEnabled(_ on: Bool) {
        guard on else {
            permissionDenied = false
            service.setEnabled(false, for: display)
            return
        }
        Task { @MainActor in
            if await AudioCapturePermission.requestIfNeeded() {
                permissionDenied = false
                service.setEnabled(true, for: display)
            } else {
                permissionDenied = true
                AudioCapturePermission.openSettings()
            }
        }
    }
}
