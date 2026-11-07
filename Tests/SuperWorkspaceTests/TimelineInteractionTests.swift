import XCTest
import AVFoundation
@testable import SuperWorkspace

@MainActor
final class TimelineInteractionTests: XCTestCase {
    private func withProject(_ body: (AppState, VideoProject, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["SUPERWORKSPACE_TEST_ROOT"]
        setenv("SUPERWORKSPACE_TEST_ROOT", root.path, 1)
        defer {
            if let previous { setenv("SUPERWORKSPACE_TEST_ROOT", previous, 1) } else { unsetenv("SUPERWORKSPACE_TEST_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        var project = VideoProject(name: "Timeline fixture")
        var material = Material()
        material.duration = 3; material.exportState = .complete; material.transcriptState = .complete
        material.subtitleLayoutVersion = SubtitleSegmentation.version
        material.subtitles = [.init(start: 0.2, end: 1, text: "First"), .init(start: 1.5, end: 2.5, text: "Second")]
        project.materials = [material]
        try ProjectLayout.save(project)
        let state = AppState(); state.select(project.id)
        try await body(state, project, root)
    }
    func testDraggingEdgesAndMovingClampAtNeighborsAndSource() {
        XCTAssertEqual(TimelineRangeEdit.range(start: 1, end: 2, edge: .start, delta: -5, lower: 0.5, upper: 3), 0.5...2)
        let collapsed = TimelineRangeEdit.range(start: 1, end: 2, edge: .end, delta: -5, lower: 0.5, upper: 3)
        XCTAssertEqual(collapsed.upperBound - collapsed.lowerBound, 1 / 30, accuracy: 0.000_001)
        XCTAssertEqual(TimelineRangeEdit.range(start: 1, end: 2, edge: .move, delta: 9, lower: 0.5, upper: 3), 2...3)
        let snapped = TimelineRangeEdit.range(start: 1, end: 2, edge: .end, delta: 0.31, lower: 0.5, upper: 3,
                                              snapPoints: [2.333], snapDistance: 0.05)
        XCTAssertEqual(snapped.upperBound, 2.333)
    }
    func testSplitSharesMediaPreservesTimeAndUndoesInOneStep() async throws {
        try await withProject { state, project, _ in
            let original = project.materials[0]
            let rightID = try XCTUnwrap(state.splitMaterial(project.id, original.id, at: 1.2))
            var edited = try XCTUnwrap(state.currentProject)
            XCTAssertEqual(edited.materials.map(\.timelineDuration), [1.2, 1.8])
            XCTAssertEqual(edited.assembledSubtitles, project.assembledSubtitles)
            XCTAssertEqual(ProjectLayout.source(edited.materials[1], in: project), ProjectLayout.source(original, in: project))
            XCTAssertEqual(edited.materials[1].mediaID, original.id)
            state.undo()
            XCTAssertEqual(state.currentProject?.materials.count, 1)
            XCTAssertEqual(state.currentProject?.materials[0].timelineDuration, 3)
            state.redo()
            edited = try XCTUnwrap(state.currentProject)
            XCTAssertEqual(edited.materials[1].id, rightID)
            XCTAssertTrue(state.removeMaterial(project.id, original.id))
            state.undo()
            XCTAssertEqual(state.currentProject?.materials.map(\.id), [original.id, rightID])
            XCTAssertNil(state.splitMaterial(project.id, original.id, at: 0))
        }
    }
    func testSplitDuringMotionKeepsSharedJobAfterRemovingOriginalClip() async throws {
        guard let ffmpeg = ToolPaths.ffmpeg else { throw XCTSkip("Synthetic media requires ffmpeg") }
        try await withProject { state, project, root in
            let source = ProjectLayout.source(project.materials[0], in: project)
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await Shell.run(ffmpeg, arguments: ["-y", "-f", "lavfi", "-i", "color=c=blue:s=320x180:r=30:d=3", "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path])
            let settings = SettingsStore.shared
            let oldAgent = settings.aiMotionAgent, oldPath = settings.aiMotionLaunchPath, oldArgs = settings.aiMotionExtraArgs
            defer { settings.aiMotionAgent = oldAgent; settings.aiMotionLaunchPath = oldPath; settings.aiMotionExtraArgs = oldArgs }
            let stub = root.appendingPathComponent("claude")
            try "#!/bin/bash\nsleep 0.3\ncp \"${@: -2:1}\" \"${@: -1}\"\n".write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
            settings.aiMotionAgent = MotionAgent.claude.rawValue; settings.aiMotionLaunchPath = stub.path
            settings.aiMotionExtraArgs = "{source1}\n{source2}"
            let id = project.materials[0].id
            state.enqueueMotion(project.id, id)
            let rightID = try XCTUnwrap(state.splitMaterial(project.id, id, at: 1))
            XCTAssertTrue(state.removeMaterial(project.id, id))
            for _ in 0..<60 {
                if state.currentProject?.materials.first?.motionState == .complete { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let right = try XCTUnwrap(state.currentProject?.materials.first)
            XCTAssertEqual(right.id, rightID)
            XCTAssertEqual(right.motionState, .complete, right.motionError ?? "")
            XCTAssertTrue(FileManager.default.fileExists(atPath: ProjectLayout.motion(right, in: project).path))
        }
    }
    func testSRTExportUsesEditedTrimmedTimelineAndRequiresReadyCaptions() async throws {
        try await withProject { state, project, _ in
            var edited = project
            edited.materials[0].trimStart = 0.5; edited.materials[0].trimEnd = 2
            let text = ExportService.srt(edited.assembledSubtitles)
            XCTAssertTrue(text.contains("00:00:00,000 --> 00:00:00,500\nFirst"))
            XCTAssertTrue(text.contains("00:00:01,000 --> 00:00:01,500\nSecond"))
            XCTAssertEqual(TranscriptService.parseSRT(text), edited.assembledSubtitles)
            edited.includeSubtitles = false; edited.exportSRT = true; edited.materials[0].transcriptState = .failed
            XCTAssertFalse(edited.canExport)
            edited.exportSRT = false
            XCTAssertTrue(edited.canExport)
            var exportOnly = project
            exportOnly.includeSubtitles = false; exportOnly.exportSRT = true
            XCTAssertEqual(AssemblyPreviewInputs(project: project), AssemblyPreviewInputs(project: exportOnly), "Export preferences must not remove editor caption styling")
        }
    }
    func testCaptionHasRoundedTranslucentBackground() throws {
        let caption = try XCTUnwrap(SubtitleRenderer.caption("字幕样式", canvas: CGSize(width: 640, height: 360)))
        XCTAssertLessThan(caption.frame.width, 400)
        XCTAssertEqual(caption.frame.midX, 320, accuracy: 0.1)
        var pixels = [UInt8](repeating: 0, count: caption.image.width * caption.image.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: caption.image.width, height: caption.image.height,
                                    bitsPerComponent: 8, bytesPerRow: caption.image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(caption.image, in: CGRect(x: 0, y: 0, width: caption.image.width, height: caption.image.height))
        }
        var background = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let dark = pixels[index] < 20 && pixels[index + 1] < 20 && pixels[index + 2] < 20
            if dark && pixels[index + 3] > 150 && pixels[index + 3] < 180 { background += 1 }
        }
        XCTAssertGreaterThan(background, caption.image.width * caption.image.height / 3)
        XCTAssertEqual(pixels[3], 0, "Rounded corners must remain transparent")
    }
}
