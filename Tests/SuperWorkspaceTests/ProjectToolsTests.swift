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

    func testClipSpeedRenameAndInsertUpdateRoundTripWithUndo() async throws {
        try await withStorage { _ in
            var project = fixture()
            project.referenceMedia = [ReferenceMedia(name: "diagram.png", kind: .image, description: "结构图")]
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)

            _ = try success(run("clip_rename", ["clip": .number(1), "title": .string("开场")], project: project, state: state))
            var saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertEqual(saved.materials[0].displayTitle(index: 0), "开场")

            // Resolve clip by custom title and set 2x speed.
            _ = try success(run("clip_speed", ["clip": .string("开场"), "speed": .number(2.0)], project: saved, state: state))
            saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertEqual(saved.materials[0].playbackSpeed, 2.0, accuracy: 0.001)
            XCTAssertEqual(saved.materials[0].timelineDuration, saved.materials[0].duration / 2.0, accuracy: 0.001)
            XCTAssertEqual(saved.materials[0].visibleSubtitles.first?.end ?? 0, 1.5, accuracy: 0.001)

            // Undo restores 1x speed.
            state.undo()
            saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertEqual(saved.materials[0].playbackSpeed, 1.0, accuracy: 0.001)

            // Add and update insert.
            _ = try success(run("insert_add", [
                "clip": .number(1), "asset": .number(1), "start": .number(1), "end": .number(3),
            ], project: saved, state: state))
            saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            _ = try success(run("insert_update", [
                "clip": .number(1), "index": .number(1), "start": .number(2), "end": .number(5),
            ], project: saved, state: state))
            saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertEqual(saved.materials[0].inserts?.first?.start ?? 0, 2.0, accuracy: 0.001)
            XCTAssertEqual(saved.materials[0].inserts?.first?.end ?? 0, 5.0, accuracy: 0.001)
        }
    }

    func testPreviewInputsIgnoreSubtitleTextChangesButTrackSpeedAndInserts() {
        var project = fixture()
        let initial = AssemblyPreviewInputs(project: project)

        project.materials[0].subtitles[0].text = "修改后的字幕"
        XCTAssertEqual(AssemblyPreviewInputs(project: project), initial)

        project.materials[0].speed = 1.5
        XCTAssertNotEqual(AssemblyPreviewInputs(project: project), initial)
    }

    func testCalloutAndAudioToolsRoundTripWithUndoAndRenderer() async throws {
        try await withStorage { _ in
            var project = fixture()
            project.referenceMedia = [ReferenceMedia(name: "bgm.mp3", kind: .audio, description: "轻快配乐", duration: 60)]
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)

            _ = try success(run("callout_add", [
                "text": .string("第一步：准备素材"),
                "subtitle": .string("导入图片与配乐"),
                "start": .number(1.0),
                "end": .number(4.0),
                "style": .string("title"),
            ], project: project, state: state))
            var saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertEqual(saved.callouts?.count, 1)
            let callout = try XCTUnwrap(saved.callouts?.first)
            let rendered = CalloutRenderer.render(callout, canvas: CGSize(width: 1920, height: 1080))
            XCTAssertNotNil(rendered)

            _ = try success(run("callout_update", [
                "index": .number(1),
                "text": .string("第一步：导入素材"),
            ], project: saved, state: state))
            saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertEqual(saved.callouts?.first?.text, "第一步：导入素材")

            _ = try success(run("audio_add", [
                "asset": .number(1),
                "kind": .string("music"),
                "start": .number(0),
                "end": .number(15),
                "volume": .number(0.22),
            ], project: saved, state: state))
            saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertEqual(saved.audioClips?.count, 1)
            XCTAssertEqual(saved.audioClips?.first?.duckUnderSpeech, true)

            state.undo()
            saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertTrue((saved.audioClips ?? []).isEmpty)

            _ = try success(run("callout_remove", ["index": .number(1)], project: saved, state: state))
            saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertTrue((saved.callouts ?? []).isEmpty)

            // Instant HTML motion overlay across any clip range.
            _ = try success(run("motion_html_add", [
                "name": .string("片头动画"),
                "start": .number(0),
                "end": .number(3.0),
                "mode": .string("overlay"),
                "html": .string("<html><body style='background:transparent'><h1>Hello</h1></body></html>"),
            ], project: saved, state: state))
            saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertEqual(saved.htmlMotions?.count, 1)
            let motionItem = try XCTUnwrap(saved.htmlMotions?.first)
            XCTAssertTrue(FileManager.default.fileExists(atPath: ProjectLayout.htmlMotion(motionItem, in: saved).path))

            _ = try success(run("motion_html_update", [
                "index": .number(1),
                "end": .number(4.5),
                "html": .string("<html><body style='background:transparent'><h1>Updated</h1></body></html>"),
            ], project: saved, state: state))
            saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            let updatedMotion = try XCTUnwrap(saved.htmlMotions?.first)
            XCTAssertEqual(updatedMotion.end, 4.5, accuracy: 0.001)
            XCTAssertEqual(updatedMotion.revision, 2)
            XCTAssertTrue((try String(contentsOf: ProjectLayout.htmlMotion(updatedMotion, in: saved), encoding: .utf8)).contains("Updated"))

            // P0 regression: undoing an HTML motion update must restore the original HTML content on disk.
            state.undo()
            saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            let restoredMotion = try XCTUnwrap(saved.htmlMotions?.first)
            XCTAssertEqual(restoredMotion.revision, 1)
            XCTAssertEqual(restoredMotion.end, 3.0, accuracy: 0.001)
            XCTAssertTrue((try String(contentsOf: ProjectLayout.htmlMotion(restoredMotion, in: saved), encoding: .utf8)).contains("Hello"))

            _ = try success(run("motion_html_remove", ["index": .number(1)], project: saved, state: state))
            saved = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertTrue((saved.htmlMotions ?? []).isEmpty)
        }
    }
}
