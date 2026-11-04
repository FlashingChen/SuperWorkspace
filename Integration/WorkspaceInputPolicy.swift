import AVFoundation
import Foundation

@MainActor
enum WorkspaceInputPolicy {
    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [CaptureDevicePreferenceKey.microphoneEnabled: true])
    }

    static func preferredMicrophoneID(availableIDs: [String], systemDefaultID: String?) -> String? {
        if let systemDefaultID, availableIDs.contains(systemDefaultID) { return systemDefaultID }
        return availableIDs.first
    }

    static func defaultMicrophone(in devices: [CaptureDeviceInfo]) -> CaptureDeviceInfo? {
        let id = preferredMicrophoneID(availableIDs: devices.map(\.id),
            systemDefaultID: AVCaptureDevice.default(for: .audio)?.uniqueID)
        return devices.first { $0.id == id }
    }
}
