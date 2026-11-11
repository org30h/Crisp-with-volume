import AppKit
import CoreAudio
import os.log

/// Per-display loudness normalization for the speakers built into external monitors.
///
/// Opt-in per display (UserDefaults, default off). Audio is processed only while the default
/// output device is the audio device of an enabled display: a `LoudnessTapEngine` session taps
/// everything the Mac plays to that device, levels it, and plays it back. The session is torn
/// down and rebuilt on any route, format, sleep or device change, and stopped on quit.
@available(macOS 14.2, *)
@MainActor
final class LoudnessNormalizationService: ObservableObject {
    static let shared = LoudnessNormalizationService()

    private static let log = Logger(subsystem: "com.crisp.app", category: "audio")
    private static let defaultsPrefix = "crisp.loudnessNormalization.uuid."
    /// This many invalidations inside `stormWindow` stop the automatic restarts.
    private static let stormLimit = 5
    private static let stormWindow: TimeInterval = 30
    /// Seconds of all-zero tap data, while another process is playing, before the permission
    /// caption shows.
    private static let deniedAfterSeconds = 3

    /// Bumped on every setting or device-list change so rows re-read them.
    @Published private var revision = 0
    /// UUID of the display being normalized right now, nil when idle.
    @Published private(set) var activeDisplayUUID: String?
    /// The tap delivered only zeros while something was playing: System Audio Recording is
    /// most likely not allowed. There is no API to ask.
    @Published private(set) var permissionLikelyDenied = false

    private var displayAudioDevices: [DisplayAudioDevice] = []
    private var engine: LoudnessTapEngine?
    private var sessionDisplayUUID: String?
    /// `engine.start()` is running on a background thread: the first start can wait on the
    /// System Audio Recording prompt, and that must not freeze the menu bar UI.
    private var starting = false
    /// A stop that arrived while `starting`; applied as soon as the start returns.
    private var pendingStop: String?
    /// A stopped engine whose HAL objects have not been seen gone yet.
    private var retiring: LoudnessTapEngine?
    private var retireChecks = 0
    /// Set when a stop failed or the objects never went away: no new session until Crisp restarts.
    private var cleanupUncertain = false
    private var sleeping = false
    private var invalidations: [Date] = []
    private var stormBlocked = false
    private var meterTimer: Timer?
    private var zeroSecondsWithPlayback = 0
    private var reevaluateTask: Task<Void, Never>?
    private var started = false
    private let listenerQueue = DispatchQueue.main
    private var hardwareListener: AudioObjectPropertyListenerBlock?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - Settings

    private func key(_ display: DisplayInfo) -> String { Self.defaultsPrefix + display.displayUUID }

    func isEnabled(_ display: DisplayInfo) -> Bool {
        UserDefaults.standard.bool(forKey: key(display))
    }

    func setEnabled(_ on: Bool, for display: DisplayInfo) {
        UserDefaults.standard.set(on, forKey: key(display))
        revision += 1
        Self.log.notice("\(display.name, privacy: .public): loudness normalization \(on ? "enabled" : "disabled", privacy: .public)")
        stormBlocked = false
        reevaluate("setting changed")
    }

    // MARK: - Availability

    /// The row shows only for an external, non-virtual display with its own CoreAudio output.
    func isAvailable(for display: DisplayInfo) -> Bool {
        _ = revision
        return !display.isBuiltin && !VirtualDisplayService.shared.isVirtualDisplay(display.displayID)
            && audioDevice(for: display) != nil
    }

    /// The monitor's audio device: same name as the display (and unique on both sides), or the
    /// only HDMI/DisplayPort output when there is exactly one external display.
    func audioDevice(for display: DisplayInfo) -> DisplayAudioDevice? {
        let externals = DisplayManagerAccessor.shared.displays.filter {
            !$0.isBuiltin && $0.isOnline && !VirtualDisplayService.shared.isVirtualDisplay($0.displayID)
        }
        let norm = { (s: String) in s.trimmingCharacters(in: .whitespaces).lowercased() }
        let sameName = externals.filter { norm($0.name) == norm(display.name) }
        let named = displayAudioDevices.filter { norm($0.name) == norm(display.name) }
        if named.count == 1, sameName.count == 1 { return named[0] }
        if named.isEmpty, externals.count == 1, externals[0].displayID == display.displayID,
           displayAudioDevices.count == 1 {
            return displayAudioDevices[0]
        }
        return nil
    }

    // MARK: - Lifecycle

    /// Starts observing the hardware and restores sessions for displays that are enabled.
    func start() {
        guard !started else { return }
        started = true
        displayAudioDevices = AudioDevices.displayOutputDevices()

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, addresses in
            let selector = addresses.pointee.mSelector
            MainActor.assumeIsolated {
                guard let self else { return }
                if selector == kAudioHardwarePropertyDevices {
                    self.displayAudioDevices = AudioDevices.displayOutputDevices()
                    self.revision += 1
                } else {
                    self.stormBlocked = false
                }
                self.reevaluate("audio hardware changed", after: 0.3)
            }
        }
        hardwareListener = listener
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, listener)
        }

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.shared.willSleep() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.shared.didWake() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            // DisplayManager refreshes its list on the same notification; look after it did.
            MainActor.assumeIsolated {
                Self.shared.revision += 1
                Self.shared.reevaluate("displays changed", after: 1.5)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Self.shared.terminate() }
        })
        reevaluate("launch", after: 1)
    }

    private func willSleep() {
        sleeping = true
        reevaluateTask?.cancel()
        stopSession("system sleep")
    }

    private func didWake() {
        sleeping = false
        stormBlocked = false
        reevaluate("wake", after: 2)
    }

    private func terminate() {
        reevaluateTask?.cancel()
        sleeping = true
        stopSession("app quit")
    }

    // MARK: - Session control

    private func reevaluate(_ reason: String, after delay: TimeInterval = 0) {
        reevaluateTask?.cancel()
        reevaluateTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.reevaluateNow(reason)
        }
    }

    /// The display and device that should be normalized right now, if any.
    private func desiredTarget() -> (display: DisplayInfo, device: DisplayAudioDevice)? {
        guard let output = AudioDevices.defaultOutputDevice() else { return nil }
        for display in DisplayManagerAccessor.shared.displays where isEnabled(display) && display.isOnline {
            if let device = audioDevice(for: display), device.id == output { return (display, device) }
        }
        return nil
    }

    private func reevaluateNow(_ reason: String) {
        guard !cleanupUncertain, !sleeping, !starting else { return }
        let target = desiredTarget()
        if let engine {
            if let target, target.device == engine.device, target.display.displayUUID == sessionDisplayUUID,
               engine.isHealthy() {
                return
            }
            stopSession(target == nil ? "no enabled display on the default output" : "route changed (\(reason))")
        }
        guard let target, !stormBlocked else { return }
        if let retiring {
            // The last session's aggregate and tap must be gone before another starts.
            if retiring.objectsGone() {
                self.retiring = nil
            } else {
                retireChecks += 1
                if retireChecks > 20 {
                    cleanupUncertain = true
                    Self.log.error("previous loudness session never released its audio objects; not restarting until Crisp is relaunched")
                } else {
                    reevaluate("waiting for previous session cleanup", after: 0.25)
                }
                return
            }
        }
        startSession(target.display, target.device, reason: reason)
    }

    private func startSession(_ display: DisplayInfo, _ device: DisplayAudioDevice, reason: String) {
        let engine = LoudnessTapEngine(device: device)
        engine.onInvalidated = { reason in
            Task { @MainActor in Self.shared.engineInvalidated(engine, reason: reason) }
        }
        self.engine = engine
        sessionDisplayUUID = display.displayUUID
        starting = true
        pendingStop = nil
        let uuid = display.displayUUID
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do {
                try engine.start()
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { Self.shared.sessionStartFinished(engine, uuid: uuid, reason: reason, failure: failure) }
        }
    }

    private func sessionStartFinished(_ started: LoudnessTapEngine, uuid: String, reason: String, failure: String?) {
        starting = false
        guard started === engine else { return }
        if let failure {
            Self.log.error("loudness start failed on \(started.device.name, privacy: .public): \(failure, privacy: .public)")
            pendingStop = nil
            stopSession("start failed")
            return
        }
        if let stopReason = pendingStop {
            pendingStop = nil
            stopSession(stopReason)
            reevaluate("start was cancelled", after: 0.5)
            return
        }
        zeroSecondsWithPlayback = 0
        permissionLikelyDenied = false
        activeDisplayUUID = uuid
        Self.log.notice("""
            loudness started on \(started.device.name, privacy: .public) (\(reason, privacy: .public)): \
            \(started.channelCount, privacy: .public) ch, \(started.sampleRate, privacy: .public) Hz
            """)
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { Self.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
        // Anything that changed while the start was running.
        reevaluate("start finished")
    }

    private func stopSession(_ reason: String) {
        meterTimer?.invalidate()
        meterTimer = nil
        activeDisplayUUID = nil
        permissionLikelyDenied = false
        if starting {
            pendingStop = reason
            return
        }
        sessionDisplayUUID = nil
        guard let engine else { return }
        self.engine = nil
        let clean = engine.stop()
        Self.log.notice("loudness stopped: \(reason, privacy: .public), cleanup \(clean ? "ok" : "FAILED", privacy: .public)")
        if clean {
            retiring = engine
            retireChecks = 0
        } else {
            // The HAL may still touch this session's memory: keep it alive, never start again.
            retiring = engine
            cleanupUncertain = true
        }
    }

    private func engineInvalidated(_ source: LoudnessTapEngine, reason: String) {
        guard source === engine else { return }
        Self.log.notice("loudness session invalidated: \(reason, privacy: .public)")
        recordInvalidation()
        stopSession(reason)
        reevaluate("session invalidated", after: 1)
    }

    private func recordInvalidation() {
        let now = Date()
        invalidations = invalidations.filter { now.timeIntervalSince($0) < Self.stormWindow } + [now]
        if invalidations.count >= Self.stormLimit {
            stormBlocked = true
            Self.log.error("loudness session keeps restarting; paused until the setting, default output or power state changes")
        }
    }

    // MARK: - Once-per-second meter and health check

    private func tick() {
        guard let engine else { return }
        guard engine.isHealthy() else {
            let reason = engine.unhealthyReason()
            Self.log.notice("loudness health check failed: \(reason, privacy: .public)")
            recordInvalidation()
            stopSession(reason)
            reevaluate("health check", after: 1)
            return
        }
        let m = engine.meters()
        Self.log.notice("""
            loudness input \(String(format: "%.1f", m.inputDB), privacy: .public) dBFS, \
            gain \(String(format: "%+.1f", m.gainDB), privacy: .public) dB, \
            zero-run \(String(format: "%.1f", m.consecutiveZeroSeconds), privacy: .public) s
            """)
        if m.sawSignal {
            zeroSecondsWithPlayback = 0
            if permissionLikelyDenied { permissionLikelyDenied = false }
        } else if m.consecutiveZeroSeconds >= 0.9, AudioDevices.otherProcessIsRunningOutput() {
            zeroSecondsWithPlayback += 1
            if zeroSecondsWithPlayback >= Self.deniedAfterSeconds, !permissionLikelyDenied {
                permissionLikelyDenied = true
                Self.log.error("tap delivered only zeros for \(self.zeroSecondsWithPlayback, privacy: .public) s while another process is playing: System Audio Recording is probably not allowed for Crisp")
            }
        } else {
            zeroSecondsWithPlayback = 0
        }
    }
}
