import CoreAudio
import Foundation
import os

/// Device-scoped Core Audio process tap feeding a private aggregate device, with one IOProc
/// that levels the tapped audio and writes it to the monitor's output.
///
///   all processes except Crisp -> tap (original path muted) -> aggregate input
///   aggregate IOProc -> LoudnessIOProcessor -> aggregate output (the monitor's own device)
///
/// One engine is one session: any route, format or device change invalidates it and the owner
/// tears it down and builds a new one. After a stop that reports `false` the owner must not
/// start another session: CoreAudio may still be using this one's objects.
/// Design and lifecycle follow closed PR #119 (software volume), which used the same tap.
@available(macOS 14.2, *)
final class LoudnessTapEngine: @unchecked Sendable {
    struct Meters {
        var inputDB: Float
        var gainDB: Float
        var consecutiveZeroSeconds: Double
        var sawSignal: Bool
    }

    struct StartError: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "\(step): OSStatus \(status)" }
    }

    let device: DisplayAudioDevice
    /// Called once, on a CoreAudio queue, with the reason, when the session can no longer be trusted.
    var onInvalidated: (@Sendable (String) -> Void)?

    private var processor: LoudnessIOProcessor?
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var registration: AudioDeviceIOProcID?
    private var replay: AudioDeviceIOProcID?
    private var registrationStarted = false
    private var replayStarted = false
    private var tapUUID = UUID()
    private var aggregateUID = ""
    private var processObject = AudioObjectID(kAudioObjectUnknown)
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress)] = []
    private let listenerQueue = DispatchQueue(label: "com.crisp.loudness.properties")
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private let invalidation = OSAllocatedUnfairLock<String?>(initialState: nil)
    private var stopped = false
    private var stopOK = false

    init(device: DisplayAudioDevice) {
        self.device = device
    }

    // MARK: - Start

    func start() throws {
        var step = "output device"
        var status = noErr
        guard AudioDevices.defaultOutputDevice() == device.id, AudioDevices.hasOutputStreams(device.id),
              AudioDevices.uid(device.id) == device.uid else { throw StartError(step: step, status: -1) }

        // TranslatePID returns "unknown" for a process that has no audio activity yet. Connect a
        // silent client to the device first, and keep it until the real IOProc runs, so Crisp
        // is a known process that the tap can exclude. Otherwise the tap would capture
        // our own output and feed it back.
        step = "register Crisp audio process"
        status = AudioDeviceCreateIOProcID(device.id, loudnessSilenceIOProc, nil, &registration)
        guard status == noErr else { throw StartError(step: step, status: status) }
        status = AudioDeviceStart(device.id, registration)
        registrationStarted = status == noErr
        guard registrationStarted else { throw StartError(step: step, status: status) }
        processObject = try Self.ownProcessObject()

        step = "create device tap (System Audio Recording permission?)"
        let description = CATapDescription(__excludingProcesses: [NSNumber(value: processObject)],
                                           andDeviceUID: device.uid, withStream: 0)
        description.uuid = tapUUID
        description.name = "Crisp Loudness"
        description.isPrivate = true
        description.isMixdown = false
        description.isMono = false
        description.muteBehavior = .muted
        if #available(macOS 26.0, *) {
            description.isProcessRestoreEnabled = false
            description.bundleIDs = []
        }
        status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else { throw StartError(step: step, status: status) }

        step = "tap format"
        guard let tapFormat = AudioDevices.read(tap, kAudioTapPropertyFormat,
                                                default: AudioStreamBasicDescription()),
              Self.isFloat32(tapFormat) else { throw StartError(step: step, status: -2) }

        step = "create private aggregate device"
        aggregateUID = "com.crisp.loudness.\(UUID().uuidString)"
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Crisp Loudness (Private)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID.uuidString]],
            kAudioAggregateDeviceTapAutoStartKey: false
        ]
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else { throw StartError(step: step, status: status) }

        step = "aggregate format"
        let layout = try Self.validateAggregate(aggregate)
        processor = LoudnessIOProcessor(channelCount: layout.channels, sampleRate: layout.sampleRate,
                                        inputPlanar: layout.inputPlanar, outputPlanar: layout.outputPlanar)

        step = "watch output route and format"
        try installListeners(tap: tap)

        step = "start leveling"
        guard let processor else { throw StartError(step: step, status: -3) }
        status = AudioDeviceCreateIOProcID(aggregate, loudnessIOProc,
                                           Unmanaged.passUnretained(processor).toOpaque(), &replay)
        guard status == noErr else { throw StartError(step: step, status: status) }
        processor.disabled = false
        replayStarted = true
        status = AudioDeviceStart(aggregate, replay)
        guard status == noErr else { throw StartError(step: step, status: status) }
    }

    /// Crisp's own audio process object, via the silent registration above (a short retry covers
    /// the HAL creating the object slightly after the device starts).
    private static func ownProcessObject() throws -> AudioObjectID {
        var pid = getpid()
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        for _ in 0..<20 {
            var object = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                    UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
            guard status == noErr else { throw StartError(step: "find Crisp audio process", status: status) }
            if object != kAudioObjectUnknown,
               AudioDevices.read(object, kAudioProcessPropertyPID, default: pid_t(0)) == getpid() { return object }
            usleep(10_000)
        }
        throw StartError(step: "find Crisp audio process", status: -4)
    }

    private static func isFloat32(_ f: AudioStreamBasicDescription) -> Bool {
        f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && f.mBitsPerChannel == 32 && f.mChannelsPerFrame >= 1
            && Int(f.mChannelsPerFrame) <= LoudnessIOProcessor.maxChannels
    }

    private struct AggregateLayout {
        let channels: Int
        let sampleRate: Double
        let inputPlanar: Bool
        let outputPlanar: Bool
    }

    /// The aggregate must expose the same float32 channel count on its input (the tap) and its
    /// output (the monitor), as one interleaved buffer or one buffer per channel.
    private static func validateAggregate(_ aggregate: AudioObjectID) throws -> AggregateLayout {
        func side(_ scope: AudioObjectPropertyScope) throws -> (channels: Int, planar: Bool) {
            guard let buffers = AudioDevices.bufferChannels(aggregate, scope: scope), !buffers.isEmpty,
                  let stream = AudioDevices.readIDs(aggregate, kAudioDevicePropertyStreams, scope)?.first,
                  let format = AudioDevices.read(stream, kAudioStreamPropertyVirtualFormat,
                                                 default: AudioStreamBasicDescription()),
                  isFloat32(format) else { throw StartError(step: "aggregate stream format", status: -5) }
            let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            let channels = buffers.reduce(0) { $0 + Int($1) }
            let shapeOK = planar ? buffers.allSatisfy { $0 == 1 } : buffers.count == 1
            guard shapeOK, channels >= 1, channels <= LoudnessIOProcessor.maxChannels else {
                throw StartError(step: "aggregate buffer layout", status: -6)
            }
            return (channels, planar)
        }
        let input = try side(kAudioObjectPropertyScopeInput)
        let output = try side(kAudioObjectPropertyScopeOutput)
        guard input.channels == output.channels,
              let rate = AudioDevices.read(aggregate, kAudioDevicePropertyNominalSampleRate, default: Float64(0)),
              rate >= 8000 else { throw StartError(step: "aggregate channel count or sample rate", status: -7) }
        return AggregateLayout(channels: output.channels, sampleRate: rate,
                               inputPlanar: input.planar, outputPlanar: output.planar)
    }

    // MARK: - Invalidation

    private func installListeners(tap: AudioObjectID) throws {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, addresses in
            self?.invalidate("audio property \(Self.fourCC(addresses.pointee.mSelector)) changed")
        }
        listenerBlock = block
        let targets: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (device.id, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (device.id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (device.id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
            (device.id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput),
            (aggregate, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (aggregate, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
            (aggregate, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
            (tap, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal)
        ]
        for (object, selector, scope) in targets {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                  mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectAddPropertyListenerBlock(object, &addr, listenerQueue, block)
            guard status == noErr else { throw StartError(step: "add property listener", status: status) }
            listeners.append((object, addr))
        }
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }

    private func invalidate(_ reason: String) {
        let first = invalidation.withLock { current -> Bool in
            guard current == nil else { return false }
            current = reason
            return true
        }
        if first { onInvalidated?(reason) }
    }

    // MARK: - Health and meters

    /// Output route, device identity, layout and listener state still match what start validated.
    func isHealthy() -> Bool {
        guard !stopped, invalidation.withLock({ $0 == nil }), let processor, !processor.layoutMismatch,
              AudioDevices.defaultOutputDevice() == device.id,
              AudioDevices.uid(device.id) == device.uid else { return false }
        return true
    }

    var invalidationReason: String? { invalidation.withLock { $0 } }

    /// Why `isHealthy` is false, for the log.
    func unhealthyReason() -> String {
        if let reason = invalidationReason { return reason }
        if processor?.layoutMismatch == true { return "audio buffer layout changed" }
        if AudioDevices.defaultOutputDevice() != device.id { return "default output changed" }
        return "output device changed"
    }

    var channelCount: Int { processor?.channelCount ?? 0 }
    var sampleRate: Double { processor?.sampleRate ?? 0 }

    func meters() -> Meters {
        guard let processor else { return Meters(inputDB: -120, gainDB: 0, consecutiveZeroSeconds: 0, sawSignal: false) }
        return Meters(inputDB: processor.leveler.inputLevelDB, gainDB: processor.leveler.gainDB,
                      consecutiveZeroSeconds: Double(processor.consecutiveZeroFrames) / processor.sampleRate,
                      sawSignal: processor.sawSignal)
    }

    // MARK: - Stop

    /// Stops the IOProcs, removes listeners and destroys the aggregate and the tap. Returns false
    /// when CoreAudio refused any step. The caller then keeps this object alive and never
    /// starts another session, since the HAL may still reference its memory.
    @discardableResult
    func stop() -> Bool {
        if stopped { return stopOK }
        stopped = true
        processor?.disabled = true
        var ok = true
        if let listenerBlock {
            for entry in listeners {
                var addr = entry.address
                ok = (AudioObjectRemovePropertyListenerBlock(entry.object, &addr, listenerQueue, listenerBlock) == noErr) && ok
            }
        }
        listeners.removeAll()
        // Retire property callbacks that were already queued.
        listenerQueue.sync {}
        if replayStarted { ok = (AudioDeviceStop(aggregate, replay) == noErr) && ok }
        if let replay { ok = (AudioDeviceDestroyIOProcID(aggregate, replay) == noErr) && ok }
        if registrationStarted { ok = (AudioDeviceStop(device.id, registration) == noErr) && ok }
        if let registration { ok = (AudioDeviceDestroyIOProcID(device.id, registration) == noErr) && ok }
        if ok {
            if aggregate != kAudioObjectUnknown { ok = (AudioHardwareDestroyAggregateDevice(aggregate) == noErr) && ok }
            if tap != kAudioObjectUnknown { ok = (AudioHardwareDestroyProcessTap(tap) == noErr) && ok }
        }
        stopOK = ok
        return ok
    }

    /// After a successful stop: the aggregate and the tap no longer appear in the HAL lists.
    func objectsGone() -> Bool {
        guard stopped, stopOK else { return false }
        let devices = AudioDevices.readIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        let taps = AudioDevices.readIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyTapList)
        guard let devices, let taps else { return false }
        if aggregate != kAudioObjectUnknown, devices.contains(aggregate) { return false }
        if tap != kAudioObjectUnknown, taps.contains(tap) { return false }
        return !devices.contains { AudioDevices.uid($0) == aggregateUID }
    }
}

// MARK: - IOProcs (real time)

/// The aggregate IOProc. A plain function, no captures: it calls into the preallocated processor
/// without retain/release, allocation, locks, logging or async work.
@available(macOS 14.2, *)
private func loudnessIOProc(_ device: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>,
                            _ input: UnsafePointer<AudioBufferList>, _ inputTime: UnsafePointer<AudioTimeStamp>,
                            _ output: UnsafeMutablePointer<AudioBufferList>,
                            _ outputTime: UnsafePointer<AudioTimeStamp>,
                            _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let clientData else { return noErr }
    Unmanaged<LoudnessIOProcessor>.fromOpaque(clientData)._withUnsafeGuaranteedRef {
        $0.render(input: input, output: output)
    }
    return noErr
}

/// Registers Crisp as an audio client of the monitor's device and writes silence.
private func loudnessSilenceIOProc(_ device: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>,
                                   _ input: UnsafePointer<AudioBufferList>,
                                   _ inputTime: UnsafePointer<AudioTimeStamp>,
                                   _ output: UnsafeMutablePointer<AudioBufferList>,
                                   _ outputTime: UnsafePointer<AudioTimeStamp>,
                                   _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
    let list = UnsafeMutableAudioBufferListPointer(output)
    for index in 0..<list.count {
        if let data = list[index].mData { memset(data, 0, Int(list[index].mDataByteSize)) }
    }
    return noErr
}
