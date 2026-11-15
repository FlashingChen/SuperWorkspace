import XCTest
@testable import SuperWorkspace

@MainActor
final class ProjectToolsTests: XCTestCase {
    private func withStorage(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["SUPERWORKSPACE_TEST_ROOT"]
        setenv("SUPERWORKSPACE_TEST_ROOT", root.path, 1)
        defer {
            if let previous { setenv("SUPERWORKSPACE_TEST_ROOT", previous, 1) } else { unsetenv("SUPERWORKSPACE_TEST_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        try await body(root)
    }

    private func fixture() -> VideoProject {
        var project = VideoProject(name: "Agent")
        var first = Material()
        first.duration = 20
        first.exportState = .complete
        first.transcriptState = .complete
        first.subtitleLayoutVersion = SubtitleSegmentation.version
        first.subtitles = [
            .init(start: 1, end: 3, text: "第一条"),
            .init(start: 5, end: 7, text: "第二条"),
        ]
        var second = Material()
        second.duration = 10
        second.exportState = .complete
        second.transcriptState = .complete
        second.subtitleLayoutVersion = SubtitleSegmentation.version
        project.materials = [first, second]
        project.referenceMedia = [ReferenceMedia(name: "chart.png", kind: .image, description: "趋势图")]
        return project
    }

    private func run(_ tool: String, _ args: [String: JSONValue] = [:],
                     project: VideoProject, state: AppState) -> ProjectToolOutcome {
        ProjectTools.execute(ProjectToolCall(id: 1, tool: tool, args: args), projectID: project.id, state: state)
    }

    private func success(_ outcome: ProjectToolOutcome) throws -> JSONValue {
        guard case let .success(value) = outcome else {
            if case let .failure(message) = outcome { XCTFail("Unexpected failure: \(message)") }
            throw XCTSkip("No value")
        }
        return value
    }

    private func failure(_ outcome: ProjectToolOutcome) -> String? {
        if case let .failure(message) = outcome { return message }
        return nil
    }

    func testReadExposesClipsSubtitlesAndTimeline() async throws {
        try await withStorage { _ in
            let project = fixture()
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            let snapshot = try success(run("project_read", project: project, state: state))
            let clips = try XCTUnwrap(snapshot["clips"]?.arrayValue)
            XCTAssertEqual(clips.count, 2)
            XCTAssertEqual(clips[0]["index"]?.intValue, 1)
            XCTAssertEqual(clips[0]["sourceDuration"]?.numberValue, 20)
            let subtitles = try XCTUnwrap(clips[0]["subtitles"]?.arrayValue)
            XCTAssertEqual(subtitles.count, 2)
            XCTAssertEqual(subtitles[1]["text"]?.stringValue, "第二条")
            XCTAssertEqual(clips[1]["timelineStart"]?.numberValue, 20)
        }
    }

    func testSubtitleEditIsUndoableAndValidated() async throws {
        try await withStorage { _ in
            let project = fixture()
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            let outcome = run("subtitle_update", [
                "clip": .number(1), "index": .number(2), "text": .string("改好了"),
            ], project: project, state: state)
            _ = try success(outcome)
            var saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertEqual(saved.materials[0].subtitles[1].text, "改好了")

            XCTAssertNotNil(failure(run("subtitle_update", [
                "clip": .number(1), "index": .number(99), "text": .string("越界"),
            ], project: project, state: state)))

            state.undo()
            saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertEqual(saved.materials[0].subtitles[1].text, "第二条")
        }
    }

    func testTrimAndMoveAreApplied() async throws {
        try await withStorage { _ in
            let project = fixture()
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            _ = try success(run("clip_trim", [
                "clip": .number(1), "start": .number(2), "end": .number(8),
            ], project: project, state: state))
            _ = try success(run("clip_move", [
                "clip": .number(1), "position": .number(2),
            ], project: project, state: state))

            let saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertEqual(saved.materials[1].inPoint, 2)
            XCTAssertEqual(saved.materials[1].outPoint, 8)
            XCTAssertEqual(saved.materials[0].duration, 10)
        }
    }

    func testInsertRequiresAValidRangeAndLibraryAsset() async throws {
        try await withStorage { _ in
            let project = fixture()
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            _ = try success(run("insert_add", [
                "clip": .number(1), "asset": .number(1), "start": .number(2), "end": .number(4),
            ], project: project, state: state))
            var saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertEqual(saved.materials[0].inserts?.count, 1)

            XCTAssertNotNil(failure(run("insert_add", [
                "clip": .number(1), "asset": .number(1), "start": .number(2), "end": .number(30),
            ], project: project, state: state)))
            saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertEqual(saved.materials[0].inserts?.count, 1)
        }
    }

    func testFrozenProjectRejectsWrites() async throws {
        try await withStorage { _ in
            var project = fixture()
            project.frozenAt = Date()
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            let message = failure(run("clip_trim", [
                "clip": .number(1), "start": .number(1), "end": .number(2),
            ], project: project, state: state))
            XCTAssertNotNil(message)
        }
    }

    func testUnknownToolReportsAvailableOperations() async throws {
        try await withStorage { _ in
            let project = fixture()
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            let message = failure(run("delete_everything", project: project, state: state))
            XCTAssertNotNil(message)
        }
    }
}
