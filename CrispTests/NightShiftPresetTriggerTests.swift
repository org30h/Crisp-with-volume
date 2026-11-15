import XCTest

final class NightShiftPresetTriggerTests: XCTestCase {
    private let on = UUID()
    private let off = UUID()
    private var existing: Set<UUID> { [on, off] }

    private func apply(_ trigger: inout NightShiftPresetTrigger, _ enabled: Bool,
                       onPreset: UUID? = nil, offPreset: UUID? = nil,
                       existing: Set<UUID>? = nil) -> UUID? {
        trigger.presetToApply(enabled: enabled, onPreset: onPreset ?? self.on, offPreset: offPreset ?? self.off,
                              existing: existing ?? self.existing)
    }

    func testFirstReadIsOnlyABaseline() {
        var onAtLaunch = NightShiftPresetTrigger()
        XCTAssertNil(apply(&onAtLaunch, true))
        var offAtLaunch = NightShiftPresetTrigger()
        XCTAssertNil(apply(&offAtLaunch, false))
    }

    func testTurningOnAppliesTheOnPreset() {
        var trigger = NightShiftPresetTrigger()
        _ = apply(&trigger, false)
        XCTAssertEqual(apply(&trigger, true), on)
    }

    func testTurningOffAppliesTheOffPreset() {
        var trigger = NightShiftPresetTrigger()
        _ = apply(&trigger, true)
        XCTAssertEqual(apply(&trigger, false), off)
    }

    func testRepeatedReadsApplyNothing() {
        var trigger = NightShiftPresetTrigger()
        _ = apply(&trigger, false)
        XCTAssertEqual(apply(&trigger, true), on)
        XCTAssertNil(apply(&trigger, true))
        XCTAssertNil(apply(&trigger, true))
        XCTAssertEqual(apply(&trigger, false), off)
        XCTAssertNil(apply(&trigger, false))
    }

    func testNoPresetChosenDoesNothingButStillTracksTheState() {
        var trigger = NightShiftPresetTrigger()
        _ = trigger.presetToApply(enabled: false, onPreset: nil, offPreset: nil, existing: existing)
        XCTAssertNil(trigger.presetToApply(enabled: true, onPreset: nil, offPreset: off, existing: existing))
        // The flip above was consumed: turning off now applies the off preset once.
        XCTAssertEqual(trigger.presetToApply(enabled: false, onPreset: nil, offPreset: off, existing: existing), off)
    }

    func testDeletedPresetIsTreatedAsNone() {
        var trigger = NightShiftPresetTrigger()
        _ = apply(&trigger, false)
        XCTAssertNil(apply(&trigger, true, existing: [off]))
        XCTAssertNil(apply(&trigger, false, existing: []))
    }

    func testOnlyTheMatchingSideIsUsed() {
        var trigger = NightShiftPresetTrigger()
        _ = trigger.presetToApply(enabled: false, onPreset: on, offPreset: nil, existing: existing)
        XCTAssertEqual(trigger.presetToApply(enabled: true, onPreset: on, offPreset: nil, existing: existing), on)
        XCTAssertNil(trigger.presetToApply(enabled: false, onPreset: on, offPreset: nil, existing: existing))
    }
}
