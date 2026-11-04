import XCTest
import AppKit
@testable import RecorderKit

@MainActor
final class RecorderInputTests: XCTestCase {
    func testEmbeddedRecorderHasNoStandaloneApplicationLifecycle() {
        XCTAssertNil(NSClassFromString("RecorderKit.DogSCApplicationDelegate"))
        let windows = NSApplication.shared.windows.count
        XCTAssertFalse(WorkspaceRecorder.shared.hasOpenSession)
        XCTAssertEqual(NSApplication.shared.windows.count, windows)
    }

    func testInitialMicrophoneEnabledAndExplicitOffPreserved() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        WorkspaceInputPolicy.registerDefaults(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: "capture.microphone.enabled"))
        defaults.set(false, forKey: "capture.microphone.enabled")
        WorkspaceInputPolicy.registerDefaults(in: defaults)
        XCTAssertFalse(defaults.bool(forKey: "capture.microphone.enabled"))
    }

    func testSystemInputWinsOverDeviceEnumerationOrder() {
        XCTAssertEqual(WorkspaceInputPolicy.preferredMicrophoneID(
            availableIDs: ["virtual-input", "system-input"], systemDefaultID: "system-input"), "system-input")
        XCTAssertEqual(WorkspaceInputPolicy.preferredMicrophoneID(
            availableIDs: ["available-input"], systemDefaultID: "disconnected-input"), "available-input")
        XCTAssertNil(WorkspaceInputPolicy.preferredMicrophoneID(availableIDs: [], systemDefaultID: "missing"))
    }
}
