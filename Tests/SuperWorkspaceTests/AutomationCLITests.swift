import XCTest
@testable import SuperWorkspace

final class AutomationCLITests: XCTestCase {
    func testParsesStatusWindowsAndProjectCommands() throws {
        XCTAssertEqual(try AutomationCLI.parseRequest(["status"]).command, "status")
        XCTAssertEqual(try AutomationCLI.parseRequest(["windows"]).command, "windows")
        XCTAssertEqual(try AutomationCLI.parseRequest(["project"]).command, "project")
    }

    func testParsesRecordStartAndStopFlags() throws {
        let start = try AutomationCLI.parseRequest([
            "record", "start",
            "--app", "Safari",
            "--system-audio", "off",
            "--fps", "30",
            "--project", "Demo",
        ])
        XCTAssertEqual(start.command, "record_start")
        XCTAssertEqual(start.args["appName"], .string("Safari"))
        XCTAssertEqual(start.args["systemAudio"], .bool(false))
        XCTAssertEqual(start.args["fps"], .number(30))
        XCTAssertEqual(start.args["projectName"], .string("Demo"))

        let stop = try AutomationCLI.parseRequest([
            "record", "stop", "--motion", "--prompt", "Highlight CTA",
        ])
        XCTAssertEqual(stop.command, "record_stop")
        XCTAssertEqual(stop.args["wantsMotion"], .bool(true))
        XCTAssertEqual(stop.args["editingPrompt"], .string("Highlight CTA"))
    }

    func testRejectsUnknownCommands() {
        XCTAssertThrowsError(try AutomationCLI.parseRequest([]))
        XCTAssertThrowsError(try AutomationCLI.parseRequest(["unknown"]))
        XCTAssertThrowsError(try AutomationCLI.parseRequest(["record"]))
    }
}
