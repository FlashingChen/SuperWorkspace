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
            "record", "stop", "--styled", "--motion", "--prompt", "Highlight CTA",
        ])
        XCTAssertEqual(stop.command, "record_stop")
        XCTAssertEqual(stop.args["styled"], .bool(true))
        XCTAssertEqual(stop.args["wantsMotion"], .bool(true))
        XCTAssertEqual(stop.args["editingPrompt"], .string("Highlight CTA"))

        let rawStop = try AutomationCLI.parseRequest(["record", "stop", "--raw"])
        XCTAssertEqual(rawStop.args["styled"], .bool(false))
    }

    func testParsesInputAndScreenshotCommands() throws {
        let typeReq = try AutomationCLI.parseRequest(["input", "type", "--text", "whoami", "--interval", "0.14"])
        XCTAssertEqual(typeReq.command, "input_type")
        XCTAssertEqual(typeReq.args["text"], .string("whoami"))
        XCTAssertEqual(typeReq.args["interval"], .number(0.14))

        let dragReq = try AutomationCLI.parseRequest([
            "input", "drag", "--from-x", "4", "--from-y", "162", "--to-x", "155", "--to-y", "162", "--duration", "0.5",
        ])
        XCTAssertEqual(dragReq.command, "input_drag")
        XCTAssertEqual(dragReq.args["fromX"], .number(4))
        XCTAssertEqual(dragReq.args["toX"], .number(155))
        XCTAssertEqual(dragReq.args["duration"], .number(0.5))

        let shot = try AutomationCLI.parseRequest(["screenshot", "--app", "Safari", "--out", "/tmp/shot.png"])
        XCTAssertEqual(shot.command, "screenshot")
        XCTAssertEqual(shot.args["appName"], .string("Safari"))
        XCTAssertEqual(shot.args["out"], .string("/tmp/shot.png"))
    }

    func testRejectsUnknownCommands() {
        XCTAssertThrowsError(try AutomationCLI.parseRequest([]))
        XCTAssertThrowsError(try AutomationCLI.parseRequest(["unknown"]))
        XCTAssertThrowsError(try AutomationCLI.parseRequest(["record"]))
    }
}
