import CoreAudio
import Foundation

/// A CoreAudio output device that belongs to a display (HDMI or DisplayPort transport).
struct DisplayAudioDevice: Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Small CoreAudio property readers shared by the loudness service and engine.
/// Every call here is blocking HAL I/O: main thread or a utility thread, never the IOProc.
enum AudioDevices {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        as _: T.Type = T.self, default fallback: T) -> T? {
        var addr = address(selector, scope)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr && size == UInt32(MemoryLayout<T>.size) ? value : nil
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    static func readIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        let id = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                      default: AudioDeviceID(0))
        return id == 0 ? nil : id
    }

    static func uid(_ device: AudioDeviceID) -> String? { readString(device, kAudioDevicePropertyDeviceUID) }
    static func name(_ device: AudioDeviceID) -> String? { readString(device, kAudioObjectPropertyName) }

    static func hasOutputStreams(_ device: AudioDeviceID) -> Bool {
        !(readIDs(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput) ?? []).isEmpty
    }

    /// Buffer layout of a device scope: the number of buffers and the channels in each, as the
    /// IOProc will see them.
    static func bufferChannels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> [UInt32]? {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size >= 4 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { $0.mNumberChannels }
    }

    /// Every output device with HDMI or DisplayPort transport: the speakers built into monitors.
    static func displayOutputDevices() -> [DisplayAudioDevice] {
        let all = readIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) ?? []
        return all.compactMap { id in
            guard hasOutputStreams(id),
                  let transport = read(id, kAudioDevicePropertyTransportType, default: UInt32(0)),
                  transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort,
                  let uid = uid(id), let name = name(id) else { return nil }
            return DisplayAudioDevice(id: id, uid: uid, name: name)
        }
    }

    /// Another process is sending audio right now. A tap that reads only zeros while this is true
    /// is most likely missing the System Audio Recording permission.
    @available(macOS 14.2, *)
    static func otherProcessIsRunningOutput() -> Bool {
        let me = getpid()
        let processes = readIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) ?? []
        return processes.contains { process in
            guard let pid = read(process, kAudioProcessPropertyPID, default: pid_t(0)), pid != me else { return false }
            return read(process, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) == 1
        }
    }
}
