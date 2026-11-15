import Foundation

// SkyLight private API: read/toggle system dark mode
private let _SLSGetAppearanceTheme: (@convention(c) () -> Bool)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let sym = dlsym(h, "SLSGetAppearanceThemeLegacy") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) () -> Bool).self)
}()
private let _SLSSetAppearanceTheme: (@convention(c) (Bool) -> Void)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let sym = dlsym(h, "SLSSetAppearanceThemeLegacy") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (Bool) -> Void).self)
}()
// Animated variant: with notify=true the switch goes through the same crossfade
// Control Center uses, instead of the instant Legacy flip.
private let _SLSSetAppearanceThemeNotifying: (@convention(c) (Bool, Bool) -> Void)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let sym = dlsym(h, "SLSSetAppearanceThemeNotifying") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (Bool, Bool) -> Void).self)
}()

/// System-level Night Shift / True Tone / Dark Mode switches, implemented via private frameworks
/// (CoreBrightness's CBBlueLightClient / CBTrueToneClient + SkyLight).
/// Per project convention, loaded at runtime with dlopen + NSClassFromString/dlsym; private frameworks are not linked.
@MainActor
final class CoreBrightnessService: ObservableObject {
    static let shared = CoreBrightnessService()

    @Published var nightShiftEnabled = false
    /// The system Night Shift schedule, nil until first read.
    @Published private(set) var nightShiftSchedule: NightShiftSchedule?
    @Published var trueToneEnabled = false
    @Published var darkModeEnabled = false
    private(set) var nightShiftAvailable = false
    // Published because availability changes at runtime: CBTrueToneClient reports
    // available=false in clamshell, so an app launched lid-closed must un-latch later.
    @Published private(set) var trueToneAvailable = false
    var darkModeAvailable: Bool { _SLSGetAppearanceTheme != nil && _SLSSetAppearanceTheme != nil }

    private var blueLightClient: NSObject?
    private var trueToneClient: NSObject?
    private var presetTrigger = NightShiftPresetTrigger()
    private(set) var nightShiftTemperature: NightShiftTemperatureController?

    private init() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil else { return }
        if let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type {
            let client = cls.init()
            blueLightClient = client
            nightShiftAvailable = true
            if let temperatureClient = NightShiftTemperatureClient(client: client) {
                nightShiftTemperature = NightShiftTemperatureController(
                    read: { await temperatureClient.read() },
                    write: { await temperatureClient.write($0) }
                )
            }
        }
        if let cls = NSClassFromString("CBTrueToneClient") as? NSObject.Type {
            let client = cls.init()
            trueToneClient = client
            trueToneAvailable = Self.boolCall(client, "supported") && Self.boolCall(client, "available")
        }
        refresh()
        observeSystemChanges()
    }

    /// Keeps published state live while the panel is closed, so it opens
    /// already correct. Dark mode arrives via a distributed notification;
    /// Night Shift and True Tone via a CoreBrightness status callback; both
    /// just call refresh(), event-driven, never polled.
    private func observeSystemChanges() {
        // Dark mode: Control Center / System Settings post this app-wide.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Night Shift / True Tone: each client invokes this block on any status change.
        // responds(to:) guards a client that lacks the selector.
        let onChange: @convention(block) () -> Void = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        let sel = NSSelectorFromString("setStatusNotificationBlock:")
        for client in [blueLightClient, trueToneClient].compactMap({ $0 }) where client.responds(to: sel) {
            typealias Fn = @convention(c) (NSObject, Selector, @convention(block) () -> Void) -> Void
            unsafeBitCast(client.method(for: sel), to: Fn.self)(client, sel, onChange)
        }
    }

    /// Re-read the current system state (the user may have toggled it via Control Center).
    /// The reads are XPC round-trips, so they run off the main thread to keep
    /// panel opening snappy; results publish back on main.
    func refresh() {
        // Strength-only changes do not always emit the status callback. The
        // existing panel-open and visible-panel refreshes cover those too.
        if let nightShiftTemperature {
            Task { await nightShiftTemperature.refresh() }
        }
        // The CoreBrightness XPC client objects are safe to message from any
        // thread, but NSObject is not Sendable; box them across the hop.
        let blueBox = UncheckedSendable(value: blueLightClient)
        let ttBox = UncheckedSendable(value: trueToneClient)
        DispatchQueue.global(qos: .userInitiated).async {
            var nightShift: Bool?
            var schedule: NightShiftSchedule?
            if let c = blueBox.value, let status = Self.readBlueLightStatus(c) {
                nightShift = status.enabled
                schedule = status.schedule
            }
            var trueTone: Bool?
            var ttAvailable = false
            if let c = ttBox.value {
                // Re-check every refresh: availability flips with the lid (clamshell
                // hides True Tone system-wide), and init may have run lid-closed.
                ttAvailable = Self.boolCall(c, "supported") && Self.boolCall(c, "available")
                if ttAvailable { trueTone = Self.boolCall(c, "enabled") }
            }
            let dark = _SLSGetAppearanceTheme?()
            DispatchQueue.main.async {
                if let nightShift {
                    self.nightShiftEnabled = nightShift
                    self.noteNightShift(nightShift)
                }
                if let schedule, self.nightShiftSchedule != schedule { self.nightShiftSchedule = schedule }
                if self.trueToneAvailable != ttAvailable { self.trueToneAvailable = ttAvailable }
                if let trueTone { self.trueToneEnabled = trueTone }
                // Don't clobber an optimistic toggle while the async theme
                // change may still be in flight (see docs/brightness-notes.md).
                if let dark, Date().timeIntervalSince(self.lastDarkModeSetAt) > 3.0 {
                    self.darkModeEnabled = dark
                }
            }
        }
    }

    private var lastDarkModeSetAt = Date.distantPast

    func setDarkMode(_ on: Bool) {
        darkModeEnabled = on
        lastDarkModeSetAt = Date()
        // Crossfades via AppKit's private NSGlobalPreferenceTransition, the
        // same path System Settings and Control Center use. Acquiring it
        // BLOCKS in the window server, so this runs off the main thread; see
        // docs/brightness-notes.md (CoreBrightness).
        Task.detached(priority: .userInitiated) {
            // Let the flipped control reach the screen first: the transition
            // must snapshot it already released and re-tinted.
            try? await Task.sleep(nanoseconds: 120_000_000)
            let transition = (NSClassFromString("NSGlobalPreferenceTransition") as? NSObject.Type)?
                .perform(NSSelectorFromString("transition"))?.takeUnretainedValue() as? NSObject
            if let setNotifying = _SLSSetAppearanceThemeNotifying {
                setNotifying(on, transition == nil)
            } else {
                _SLSSetAppearanceTheme?(on)
            }
            if let transition {
                let sel = NSSelectorFromString("postChangeNotification:completionHandler:")
                typealias Post = @convention(c) (NSObject, Selector, Int, @escaping @convention(block) () -> Void) -> Void
                // Completion keeps the transition alive until the crossfade finishes.
                unsafeBitCast(transition.method(for: sel), to: Post.self)(transition, sel, 0, { _ = transition })
            }
        }
    }

    func setNightShift(_ on: Bool) {
        guard let c = blueLightClient else { return }
        Self.setBoolCall(c, "setEnabled:", on)
        nightShiftEnabled = on
        noteNightShift(on)
    }

    /// Sets how Night Shift is scheduled (the same setting as System Settings > Displays >
    /// Night Shift). The new mode shows at once and refresh() then confirms what the system holds.
    func setNightShiftMode(_ mode: NightShiftScheduleMode) {
        guard let c = blueLightClient else { return }
        nightShiftSchedule?.mode = mode
        let box = UncheckedSendable(value: c)
        DispatchQueue.global(qos: .userInitiated).async {
            let sel = NSSelectorFromString("setMode:")
            if box.value.responds(to: sel) {
                typealias Fn = @convention(c) (NSObject, Selector, Int32) -> Bool
                _ = unsafeBitCast(box.value.method(for: sel), to: Fn.self)(box.value, sel, mode.rawValue)
            }
            DispatchQueue.main.async { self.refresh() }
        }
    }

    /// Sets the custom Night Shift window. Only meaningful in Custom mode.
    func setNightShiftSchedule(from: NightShiftTime, to: NightShiftTime) {
        guard let c = blueLightClient else { return }
        nightShiftSchedule?.from = from
        nightShiftSchedule?.to = to
        let box = UncheckedSendable(value: c)
        DispatchQueue.global(qos: .userInitiated).async {
            let sel = NSSelectorFromString("setSchedule:")
            if box.value.responds(to: sel) {
                var schedule = BlueLightSchedule(from: BlueLightTime(from), to: BlueLightTime(to))
                typealias Fn = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Bool
                _ = withUnsafeMutablePointer(to: &schedule) {
                    unsafeBitCast(box.value.method(for: sel), to: Fn.self)(box.value, sel, UnsafeMutableRawPointer($0))
                }
            }
            DispatchQueue.main.async { self.refresh() }
        }
    }

    /// Applies the preset chosen for this Night Shift state, if it just changed (schedule,
    /// Control Center, System Settings or Crisp's own toggle all land here). The first
    /// state seen is only recorded, so launching with Night Shift on applies nothing.
    private func noteNightShift(_ enabled: Bool) {
        let settings = SettingsService.shared
        let presets = PresetService.shared.presets
        guard let id = presetTrigger.presetToApply(
            enabled: enabled, onPreset: settings.nightShiftOnPresetID,
            offPreset: settings.nightShiftOffPresetID, existing: Set(presets.map(\.id))),
            let preset = presets.first(where: { $0.id == id }) else { return }
        Task { await PresetService.shared.applyPreset(preset) }
    }

    func setTrueTone(_ on: Bool) {
        guard let c = trueToneClient else { return }
        Self.setBoolCall(c, "setEnabled:", on)
        trueToneEnabled = on
    }

    /// Toggles True Tone off and back on to clear a stale tint an external
    /// keeps after a full wake (issue #131). See docs/brightness-notes.md
    /// (CoreBrightness). Reads state live, never the published value, so a
    /// stale read can't switch True Tone on for someone who has it off.
    @discardableResult
    func reassertTrueTone() -> Bool {
        guard let c = trueToneClient, Self.boolCall(c, "supported"), Self.boolCall(c, "available"),
              Self.boolCall(c, "enabled") else { return false }
        Self.setBoolCall(c, "setEnabled:", false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Self.setBoolCall(c, "setEnabled:", true)
            self.trueToneEnabled = true
        }
        return true
    }

    // MARK: - ObjC runtime call helpers

    /// Reads `getBlueLightStatus:` into the typed C struct. The struct sits in a larger zeroed
    /// buffer so a longer layout on a newer macOS cannot write past it.
    private nonisolated static func readBlueLightStatus(_ c: NSObject) -> (enabled: Bool, schedule: NightShiftSchedule)? {
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard c.responds(to: sel) else { return nil }
        let size = max(64, MemoryLayout<BlueLightStatus>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        typealias Fn = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Bool
        guard unsafeBitCast(c.method(for: sel), to: Fn.self)(c, sel, raw) else { return nil }
        let status = raw.load(as: BlueLightStatus.self)
        let schedule = NightShiftSchedule(
            mode: NightShiftScheduleMode(systemValue: status.mode),
            from: NightShiftTime(hour: Int(status.from.hour), minute: Int(status.from.minute)),
            to: NightShiftTime(hour: Int(status.to.hour), minute: Int(status.to.minute)),
            sunSchedulePermitted: status.sunSchedulePermitted)
        return (status.enabled, schedule)
    }

    private nonisolated static func boolCall(_ obj: NSObject, _ name: String) -> Bool {
        let sel = NSSelectorFromString(name)
        guard obj.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (NSObject, Selector) -> Bool
        return unsafeBitCast(obj.method(for: sel), to: Fn.self)(obj, sel)
    }

    private nonisolated static func setBoolCall(_ obj: NSObject, _ name: String, _ v: Bool) {
        let sel = NSSelectorFromString(name)
        guard obj.responds(to: sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Bool) -> Void
        unsafeBitCast(obj.method(for: sel), to: Fn.self)(obj, sel, v)
    }
}

/// CoreBrightness `Time`, `Schedule` and `Status` C structs, as `getBlueLightStatus:` fills them
/// (field order and natural alignment checked against a live read).
private struct BlueLightTime {
    var hour: Int32
    var minute: Int32

    init(hour: Int32, minute: Int32) {
        self.hour = hour
        self.minute = minute
    }

    init(_ time: NightShiftTime) {
        self.init(hour: Int32(time.hour), minute: Int32(time.minute))
    }
}

private struct BlueLightSchedule {
    var from: BlueLightTime
    var to: BlueLightTime
}

private struct BlueLightStatus {
    var active: Bool
    var enabled: Bool
    var sunSchedulePermitted: Bool
    var mode: Int32
    var from: BlueLightTime
    var to: BlueLightTime
    var disableFlags: UInt64
    var available: Bool
}

/// Carries a value across a `@Sendable` boundary the compiler cannot verify.
/// Only for objects that are documented or observed thread-safe to message
/// (here: the CoreBrightness XPC client objects).
private struct UncheckedSendable<T>: @unchecked Sendable { let value: T }
