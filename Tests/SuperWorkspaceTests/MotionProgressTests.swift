import XCTest
@testable import SuperWorkspace

final class MotionProgressTests: XCTestCase {
    func testParsesStartAndTurnLines() throws {
        let start = try XCTUnwrap(EmbeddedPi.Progress(line: #"SW_PROGRESS {"type":"start","model":"auto/step-5","at":1700000000000}"#))
        XCTAssertEqual(start.type, "start")
        XCTAssertNil(start.n)

        let turn = try XCTUnwrap(EmbeddedPi.Progress(line: #"SW_PROGRESS {"type":"turn","n":3,"at":1700000000000}"#))
        XCTAssertEqual(turn.type, "turn")
        XCTAssertEqual(turn.n, 3)
    }

    func testParsesToolLifecycleLines() throws {
        let tool = try XCTUnwrap(EmbeddedPi.Progress(
            line: #"SW_PROGRESS {"type":"tool","n":2,"name":"bash","detail":"npx remotion render","at":1700000000000}"#))
        XCTAssertEqual(tool.type, "tool")
        XCTAssertEqual(tool.name, "bash")
        XCTAssertEqual(tool.detail, "npx remotion render")

        let end = try XCTUnwrap(EmbeddedPi.Progress(
            line: #"SW_PROGRESS {"type":"tool_end","n":2,"name":"bash","ms":1200,"ok":true,"at":1700000000000}"#))
        XCTAssertEqual(end.type, "tool_end")
        XCTAssertEqual(end.ms, 1200)
        XCTAssertEqual(end.ok, true)
    }

    func testParsesRetryBudgetAndDoneLines() throws {
        let retry = try XCTUnwrap(EmbeddedPi.Progress(
            line: #"SW_PROGRESS {"type":"retry","attempt":1,"max":3,"delayMs":2000,"error":"connection lost","at":1700000000000}"#))
        XCTAssertEqual(retry.attempt, 1)
        XCTAssertEqual(retry.max, 3)
        XCTAssertEqual(retry.delayMs, 2000)
        XCTAssertEqual(retry.error, "connection lost")

        let retryEnd = try XCTUnwrap(EmbeddedPi.Progress(
            line: #"SW_PROGRESS {"type":"retry_end","success":true,"attempt":1,"at":1700000000000}"#))
        XCTAssertEqual(retryEnd.type, "retry_end")

        let budget = try XCTUnwrap(EmbeddedPi.Progress(
            line: #"SW_PROGRESS {"type":"budget","reason":"toolCalls","limit":100,"at":1700000000000}"#))
        XCTAssertEqual(budget.reason, "toolCalls")
        XCTAssertEqual(budget.limit, 100)

        let done = try XCTUnwrap(EmbeddedPi.Progress(
            line: #"SW_PROGRESS {"type":"done","ms":90000,"tools":12,"at":1700000000000}"#))
        XCTAssertEqual(done.ms, 90000)
        XCTAssertEqual(done.tools, 12)
    }

    func testRejectsLinesWithoutPrefixOrValidJSON() {
        XCTAssertNil(EmbeddedPi.Progress(line: #"{"type":"start"}"#))
        XCTAssertNil(EmbeddedPi.Progress(line: "SW_PROGRESS_NOT_A_LINE"))
        XCTAssertNil(EmbeddedPi.Progress(line: "SW_PROGRESS not-json"))
        XCTAssertNil(EmbeddedPi.Progress(line: "SW_PROGRESS {}"), "A progress record must carry a type")
        XCTAssertNil(EmbeddedPi.Progress(line: ""))
    }

    func testStrippingRemovesOnlyProgressLines() {
        let log = """
        SW_PROGRESS {"type":"start"}
        final assistant text
        SW_PROGRESS {"type":"done","ms":1}
        """
        XCTAssertEqual(EmbeddedPi.Progress.stripping(from: log), "final assistant text")
        XCTAssertEqual(EmbeddedPi.Progress.stripping(from: "plain log\n"), "plain log\n")
    }
}
