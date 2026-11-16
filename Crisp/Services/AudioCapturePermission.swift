import AppKit

/// System Audio Recording permission, the TCC service a Core Audio process tap needs.
/// macOS has no public call to read or request it, so this uses the private TCC SPI
/// (TCCAccessPreflight / TCCAccessRequest on kTCCServiceAudioCapture), loaded at runtime
/// with dlopen + dlsym per project convention. If the SPI is missing, the status reads
/// as unknown and the tap's own first start shows the system prompt instead.
enum AudioCapturePermission {
    enum Status { case granted, denied, unknown }

    private static let service = "kTCCServiceAudioCapture"

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW) else {
            return nil
        }
        return dlsym(tcc, name)
    }

    private static var preflight: PreflightFn? {
        symbol("TCCAccessPreflight").map { unsafeBitCast($0, to: PreflightFn.self) }
    }

    private static var request: RequestFn? {
        symbol("TCCAccessRequest").map { unsafeBitCast($0, to: RequestFn.self) }
    }

    /// 0 is granted, 1 is denied, anything else (2) is not asked yet.
    static var status: Status {
        guard let preflight else { return .unknown }
        switch preflight(service as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt when the user hasn't answered yet. Returns the answer;
    /// returns true when the SPI is missing, so the tap's own start can prompt.
    static func requestIfNeeded() async -> Bool {
        switch status {
        case .granted: return true
        case .denied: return false
        case .unknown:
            guard let request else { return true }
            return await withCheckedContinuation { continuation in
                request(service as CFString, nil) { granted in continuation.resume(returning: granted) }
            }
        }
    }

    /// The Screen & System Audio Recording list in System Settings.
    @MainActor
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
