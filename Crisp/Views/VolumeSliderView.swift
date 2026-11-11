import AppKit
import SwiftUI

/// Speaker volume slider for external monitors with DDC volume (VCP 0x62),
/// shown under the brightness slider only once the probe confirmed support
/// (issue #23). Writes go through VolumeService's coalesced writer, so drags
/// don't flood the I2C bus that brightness shares. No click-glide like the
/// brightness slider: audio has no reason to fade, a jump is correct.
struct VolumeSliderView: View {
    @ObservedObject var display: DisplayInfo
    @ObservedObject private var volumeService = VolumeService.shared
    @State private var localVolume: Double = 0
    @State private var isDragging: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            BrightnessStepButton(systemName: "speaker.fill") { step(-volumeStep) }

            Slider(value: $localVolume, in: 0...100) { editing in
                isDragging = editing
                if !editing {
                    VolumeService.shared.setVolume(localVolume, for: display)
                }
            }
            .controlSize(.small)
            .accessibilityLabel("Speaker volume")
            .accessibilityValue("\(Int(localVolume))%")
            .onChange(of: localVolume) { _, newValue in
                guard isDragging else { return }
                VolumeService.shared.setVolume(newValue, for: display)
            }

            BrightnessStepButton(systemName: "speaker.wave.3.fill") { step(volumeStep) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .help(activeLimit.map { Text("Volume limited to \(Int($0.rounded()))%") } ?? Text(""))
        .contextMenu { limitMenu }
        .task(id: display.displayID) { localVolume = display.volume }
        .onChange(of: display.volume) { _, newValue in
            // External change (volume keys, a probe adopting the OSD level).
            if !isDragging && abs(newValue - localVolume) >= 0.1 {
                localVolume = newValue
            }
        }
    }

    private var activeLimit: Double? { volumeService.volumeLimit(for: display) }

    @ViewBuilder
    private var limitMenu: some View {
        Menu("Maximum Volume") {
            limitButton(nil)
            ForEach(Self.presetLimits, id: \.self) { limitButton($0) }
            customButton
            // Hardware level now, so the monitor's current loudness can become the cap.
            let level = Int(VolumeLimit.hardware(fromUser: display.volume, limit: activeLimit).rounded())
            if (1...99).contains(level), level != activeLimit.map({ Int($0.rounded()) }) {
                Button("Current Level (\(level)%)") {
                    volumeService.setVolumeLimit(Double(level), for: display)
                }
            }
        }
    }

    private static let presetLimits: [Double] = [75, 50, 25, 10]

    /// Opens the typed-value prompt. Checked, with its value, while the active limit
    /// is not one of the presets (typed earlier, or picked as Current Level).
    @ViewBuilder
    private var customButton: some View {
        let custom = activeLimit.flatMap { Self.presetLimits.contains($0) ? nil : Int($0.rounded()) }
        Button {
            promptForLimit()
        } label: {
            if let custom {
                Text("Custom (\(custom)%)…")
                Image(systemName: "checkmark")
            } else {
                Text("Custom…")
            }
        }
    }

    /// A small alert with a text field. A context menu can't hold a text field, and an
    /// inline field would change the panel block's fixed height. Re-asks on bad input.
    private func promptForLimit() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        let start = activeLimit ?? VolumeLimit.hardware(fromUser: display.volume, limit: nil)
        field.stringValue = "\(max(1, min(100, Int(start.rounded()))))"
        field.placeholderString = "1–100"
        let alert = NSAlert()
        alert.messageText = String(localized: "Maximum Volume")
        // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
        alert.informativeText = String(localized: "The highest volume Crisp may set on this display, as a percent of its full volume (1 to 100).")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Set Limit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        // Crisp is a menu bar app with no active window: activate so the field takes typing.
        NSApp.activate()
        while alert.runModal() == .alertFirstButtonReturn {
            if let limit = VolumeLimit.parse(field.stringValue) {
                volumeService.setVolumeLimit(limit, for: display)
                return
            }
            alert.informativeText = String(localized: "Enter a whole number from 1 to 100.")
            field.selectText(nil)
        }
    }

    @ViewBuilder
    private func limitButton(_ limit: Double?) -> some View {
        let isActive = activeLimit == limit
        Button {
            volumeService.setVolumeLimit(limit, for: display)
        } label: {
            if let limit {
                Text("\(Int(limit))%")
            } else {
                Text("No Limit")
            }
            if isActive { Image(systemName: "checkmark") }
        }
    }

    /// Volume change per tap of the speaker buttons, matching the volume keys' step.
    private var volumeStep: Double { 100.0 / 16.0 }

    private func step(_ delta: Double) {
        VolumeService.shared.setVolume(display.volume + delta, for: display)
    }
}
