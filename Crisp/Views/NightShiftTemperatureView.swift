import SwiftUI

/// One global Night Shift control, below the system effects and above Presets.
struct NightShiftTemperatureView: View {
    @ObservedObject var temperature: NightShiftTemperatureController

    var body: some View {
        // One row: the Night Shift glyph, then a bar shaded light to deep orange, so
        // neither a title nor "less/more warm" captions are needed.
        HStack(spacing: 8) {
            EffectGlyphView(glyph: .nightShift, color: .secondary)
                .scaleEffect(0.85)
                .accessibilityHidden(true)
            WarmthSlider(
                value: temperature.strength,
                onChange: { value in Task { await temperature.setStrength(value) } },
                onEditingChanged: { editing in
                    temperature.setEditing(editing)
                    if !editing { Task { await temperature.refresh() } }
                }
            )
            .accessibilityLabel("Night Shift Temperature")
        }
        .help("Night Shift Temperature")
        .disabled(temperature.strength == nil)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            temperature.setEditing(false)
            Task { await temperature.refresh() }
        }
    }
}
