import Foundation

/// Decides which preset a Night Shift change should apply. The first state it sees
/// is only the baseline (Night Shift can already be on at launch, and that is not a
/// switch), so a preset is applied on a real flip and never on a repeated read.
struct NightShiftPresetTrigger {
    private var lastEnabled: Bool?

    /// Records `enabled` and returns the preset to apply when it just flipped. nil when
    /// nothing changed, no preset is chosen for the new state, or that preset was deleted.
    mutating func presetToApply(enabled: Bool, onPreset: UUID?, offPreset: UUID?,
                                existing: Set<UUID>) -> UUID? {
        defer { lastEnabled = enabled }
        guard let last = lastEnabled, last != enabled else { return nil }
        guard let id = enabled ? onPreset : offPreset, existing.contains(id) else { return nil }
        return id
    }
}
