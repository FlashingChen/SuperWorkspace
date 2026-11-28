import XCTest
@testable import SuperWorkspace

final class AntigravityCLITests: XCTestCase {
    func testParsesModelsCatalogAndDeduplicates() {
        let output = """
        MODEL\tDISPLAY NAME
        gemini-3-pro\tGemini 3 Pro
        gemini-3-flash   Gemini 3 Flash
        gemini-3-pro\tDuplicate Entry
        invalid line without separator
        claude-sonnet-4.6  Claude Sonnet 4.6
        """
        let models = AntigravityCLI.models(from: output)
        XCTAssertEqual(models, [
            .init(slug: "gemini-3-pro", name: "Gemini 3 Pro"),
            .init(slug: "gemini-3-flash", name: "Gemini 3 Flash"),
            .init(slug: "claude-sonnet-4.6", name: "Claude Sonnet 4.6"),
        ])
    }

    func testDecodesStreamEvents() {
        var decoder = AntigravityCLI.StreamDecoder()

        let initUpdate = decoder.consume(["event": "init", "conversation_id": "conv-1"])
        XCTAssertEqual(initUpdate.event, "init")
        XCTAssertEqual(initUpdate.conversationID, "conv-1")

        let toolStart = decoder.consume([
            "event": "step_update",
            "step_update": [
                "step_index": 1,
                "step_type": "tool",
                "state": "RUNNING",
                "tool_name": "run_command",
                "tool_info": ["parameters": ["CommandLine": "node sw-motion.mjs render"]],
            ],
        ])
        XCTAssertEqual(toolStart.toolName, "run_command")
        XCTAssertEqual(toolStart.toolDetail, "node sw-motion.mjs render")
        XCTAssertFalse(toolStart.finishedTool)

        let toolDone = decoder.consume([
            "event": "step_update",
            "step_update": [
                "step_index": 1,
                "step_type": "tool",
                "state": "DONE",
                "tool_name": "run_command",
            ],
        ])
        XCTAssertTrue(toolDone.finishedTool)

        let responseDelta = decoder.consume([
            "event": "step_update",
            "step_update": [
                "step_index": 2,
                "step_type": "agent_response",
                "text_delta": "Rendered successfully.",
            ],
        ])
        XCTAssertEqual(responseDelta.textDelta, "Rendered successfully.")

        let resultUpdate = decoder.consume([
            "event": "result",
            "result": [
                "status": "SUCCESS",
                "conversation_id": "conv-1",
            ],
        ])
        XCTAssertEqual(resultUpdate.status, "SUCCESS")
        XCTAssertEqual(resultUpdate.responseText, "Rendered successfully.")
        XCTAssertNil(resultUpdate.error)
    }

    func testMotionArgumentsIncludeModelWhenConfigured() {
        XCTAssertEqual(
            AntigravityCLI.motionArguments(model: ""),
            ["--input-format", "stream-json", "--output-format", "stream-json", "--dangerously-skip-permissions"]
        )
        XCTAssertEqual(
            AntigravityCLI.motionArguments(model: "gemini-3-pro", extraArgs: ["--effort", "high"]),
            ["--input-format", "stream-json", "--output-format", "stream-json", "--dangerously-skip-permissions",
             "--model", "gemini-3-pro", "--effort", "high"]
        )
    }

    func testRunStreamTurnStreamsProgressAndCapturesResult() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("agy-test-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stub = tempDir.appendingPathComponent("agy")
        let script = """
        #!/bin/sh
        read -r line
        echo '{"event":"init","conversation_id":"c-1"}'
        echo '{"event":"step_update","step_update":{"step_index":1,"step_type":"tool","state":"RUNNING","tool_name":"run_command","tool_info":{"parameters":{"CommandLine":"node sw-motion.mjs render"}}}}'
        echo '{"event":"step_update","step_update":{"step_index":1,"step_type":"tool","state":"DONE","tool_name":"run_command"}}'
        echo '{"event":"result","result":{"status":"SUCCESS","response":"motion ready"}}'
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)

        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            var events: [EmbeddedPi.Progress] = []
            func append(_ item: EmbeddedPi.Progress) { lock.withLock { events.append(item) } }
        }
        let collector = Collector()

        let reply = try await AntigravityCLI.runMotion(
            executable: stub.path,
            model: "gemini-3-pro",
            system: "sys",
            prompt: "render",
            directory: tempDir,
            timeout: 10,
            prepareRemotion: false,
            onProgress: { collector.append($0) }
        )
        XCTAssertEqual(reply, "motion ready")
        XCTAssertEqual(collector.events.map(\.type), ["start", "tool", "tool_end", "done"])
        XCTAssertEqual(collector.events[1].name, "run_command")
        XCTAssertEqual(collector.events[1].detail, "node sw-motion.mjs render")
    }

    func testRunStreamTurnPropagatesErrorStatus() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("agy-err-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stub = tempDir.appendingPathComponent("agy")
        let script = """
        #!/bin/sh
        read -r line
        echo '{"event":"result","result":{"status":"ERROR","error":"quota exceeded"}}'
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)

        do {
            _ = try await AntigravityCLI.runMotion(
                executable: stub.path,
                model: "",
                system: "sys",
                prompt: "render",
                directory: tempDir,
                timeout: 10,
                prepareRemotion: false
            )
            XCTFail("Expected AntigravityCLI.runMotion to throw on ERROR result")
        } catch let error as ShellError {
            XCTAssertTrue(error.output.contains("quota exceeded"))
        }
    }

    @MainActor
    func testPerWorkflowRoutingKeepsGeneralAgentIndependentFromMotionAgent() throws {
        let settings = SettingsStore.shared
        let prevMotion = settings.aiMotionAgent
        let prevGeneral = settings.aiGeneralAgent
        let prevAgyPath = settings.aiAntigravityLaunchPath
        defer {
            settings.aiMotionAgent = prevMotion
            settings.aiGeneralAgent = prevGeneral
            settings.aiAntigravityLaunchPath = prevAgyPath
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("agy-route-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let stub = tempDir.appendingPathComponent("agy")
        try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)

        settings.aiMotionAgent = MotionAgent.antigravity.rawValue
        settings.aiGeneralAgent = GeneralAgent.api.rawValue
        settings.aiAntigravityLaunchPath = stub.path

        XCTAssertEqual(settings.selectedAgent, .antigravity)
        XCTAssertEqual(settings.selectedGeneralAgent, .api)
        XCTAssertEqual(settings.resolvedAntigravityPath(), stub.path)
        XCTAssertTrue(settings.hasAIConnection)
    }
}
