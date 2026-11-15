import AppKit
import SwiftUI

/// A native small NSSlider whose bar is a light-to-deep orange gradient, so the bar
/// itself reads as "less warm" to "more warm" with no caption row. AppKit tracking,
/// not a SwiftUI DragGesture, because the panel's ScrollView steals drag gestures.
struct WarmthSlider: NSViewRepresentable {
    /// 0...1. nil shows the thumb at 0.
    let value: Double?
    let onChange: (Double) -> Void
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.cell = GradientSliderCell()
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = value ?? 0
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.isContinuous = true
        slider.controlSize = .small
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        // Leave the thumb alone mid-drag; the controller already ignores stale reads.
        guard !context.coordinator.editing, let value else { return }
        if abs(slider.doubleValue - value) > 0.001 { slider.doubleValue = value }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: WarmthSlider
        var editing = false

        init(_ parent: WarmthSlider) { self.parent = parent }

        @objc func changed(_ sender: NSSlider) {
            if !editing {
                editing = true
                parent.onEditingChanged(true)
            }
            parent.onChange(sender.doubleValue)
            // A continuous slider sends its last action on mouse-up (also for a plain click).
            let type = NSApp.currentEvent?.type
            if type == .leftMouseUp || type == nil {
                editing = false
                parent.onEditingChanged(false)
            }
        }
    }
}

/// Draws the bar as a rounded orange gradient; the knob stays the system one.
private final class GradientSliderCell: NSSliderCell {
    private static let gradient = NSGradient(
        starting: NSColor(srgbRed: 1.0, green: 0.86, blue: 0.62, alpha: 1),
        ending: NSColor(srgbRed: 0.93, green: 0.40, blue: 0.0, alpha: 1)
    )

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let height: CGFloat = 4
        let bar = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        let path = NSBezierPath(roundedRect: bar, xRadius: height / 2, yRadius: height / 2)
        Self.gradient?.draw(in: path, angle: 0)
    }
}
