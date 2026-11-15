import AppKit
import SwiftUI

/// "Maximum Brightness" submenu for an external display's brightness slider row:
/// No Limit, presets, a typed Custom value, and the current level. Meant for a
/// `.contextMenu`, like the Maximum Volume menu on the volume slider.
struct BrightnessLimitMenu: View {
    @ObservedObject var display: DisplayInfo
    @ObservedObject private var brightnessService = BrightnessService.shared

    private static let presetLimits: [Double] = [75, 50, 25, 10]

    private var activeLimit: Double? { brightnessService.brightnessLimit(for: display) }

    var body: some View {
        Menu("Maximum Brightness") {
            limitButton(nil)
            ForEach(Self.presetLimits, id: \.self) { limitButton($0) }
            customButton
            // Hardware level now, so the monitor's current brightness can become the cap.
            let level = Int(VolumeLimit.hardware(fromUser: min(display.brightness, 100), limit: activeLimit).rounded())
            if (1...99).contains(level), level != activeLimit.map({ Int($0.rounded()) }) {
                Button("Current Brightness (\(level)%)") { apply(Double(level)) }
            }
        }
    }

    private func apply(_ limit: Double?) {
        Task { @MainActor in
            await BrightnessService.shared.setBrightnessLimit(limit, for: display)
        }
    }

    @ViewBuilder
    private func limitButton(_ limit: Double?) -> some View {
        let isActive = activeLimit == limit
        Button {
            apply(limit)
        } label: {
            if let limit {
                Text("\(Int(limit))%")
            } else {
                Text("No Limit")
            }
            if isActive { Image(systemName: "checkmark") }
        }
    }

    /// Opens the typed-value prompt. Checked, with its value, while the active limit
    /// is not one of the presets (typed earlier, or picked as Current Brightness).
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
        let start = activeLimit ?? VolumeLimit.hardware(fromUser: min(display.brightness, 100), limit: nil)
        field.stringValue = "\(max(1, min(100, Int(start.rounded()))))"
        field.placeholderString = "1–100"
        let alert = NSAlert()
        alert.messageText = String(localized: "Maximum Brightness")
        // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
        alert.informativeText = String(localized: "The highest brightness Crisp may set on this display, as a percent of its full brightness (1 to 100).")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Set Limit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        // Crisp is a menu bar app with no active window: activate so the field takes typing.
        NSApp.activate()
        while alert.runModal() == .alertFirstButtonReturn {
            if let limit = VolumeLimit.parse(field.stringValue) {
                apply(limit)
                return
            }
            alert.informativeText = String(localized: "Enter a whole number from 1 to 100.")
            field.selectText(nil)
        }
    }
}
