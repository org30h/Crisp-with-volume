import SwiftUI

/// Per-display Combined Volume switch, styled like LoudnessNormalizationView. Shown for a
/// display with DDC volume that has its own CoreAudio output, on macOS 14.2 or later (the
/// Core Audio tap the software half needs does not exist before).
struct CombinedVolumeView: View {
    @ObservedObject var display: DisplayInfo

    var body: some View {
        if #available(macOS 14.2, *) {
            CombinedVolumeRow(display: display)
        }
    }
}

@available(macOS 14.2, *)
private struct CombinedVolumeRow: View {
    @ObservedObject var display: DisplayInfo
    @ObservedObject private var volume = VolumeService.shared
    @ObservedObject private var loudness = LoudnessNormalizationService.shared
    @State private var isHovered = false

    var body: some View {
        if display.volumeSupported, loudness.isAvailable(for: display) {
            HStack {
                MenuItemIcon(systemName: "speaker.wave.1.fill", color: .indigo, active: volume.isCombined(display))
                Text("Combined Volume")
                    .font(.body)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { volume.isCombined(display) },
                    set: { volume.setCombined($0, for: display) }
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
                Goes below the monitor's quietest volume step by lowering the sound on this Mac. \
                The bottom quarter of the volume slider is software.
                """)
        }
    }
}
