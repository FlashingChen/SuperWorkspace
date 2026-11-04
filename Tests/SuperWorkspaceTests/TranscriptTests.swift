import AppKit
import AVFoundation
import XCTest
@testable import SuperWorkspace

final class TranscriptTests: XCTestCase {
    @MainActor
    func testExistingSubtitlesSplitAndInterruptedCorrectionKeepsThemUsable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["SUPERWORKSPACE_TEST_ROOT"]
        setenv("SUPERWORKSPACE_TEST_ROOT", root.path, 1)
        defer {
            if let previous { setenv("SUPERWORKSPACE_TEST_ROOT", previous, 1) } else { unsetenv("SUPERWORKSPACE_TEST_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        var project = VideoProject(name: "Subtitle migration")
        var material = Material()
        material.duration = 8
        material.exportState = .complete
        material.transcriptState = .running
        let speech = "我们先录制一段视频，然后打开字幕面板检查识别结果，最后再导出成片。"
        material.subtitles = [.init(start: 0, end: 8, text: speech)]
        project.materials = [material]
        try ProjectLayout.save(project)
        let state = AppState()
        let restored = try XCTUnwrap(state.projects.first?.materials.first)
        XCTAssertEqual(restored.transcriptState, .complete)
        XCTAssertNotNil(restored.transcriptWarning)
        XCTAssertTrue(state.projects.first!.canExport)
        XCTAssertGreaterThan(restored.subtitles.count, 1)
        XCTAssertEqual(restored.subtitles.map(\.text).joined(), speech)
        XCTAssertEqual(ProjectLayout.loadAll().first?.materials.first?.subtitles, restored.subtitles)
        XCTAssertEqual(AppState().projects.first?.materials.first?.subtitles, restored.subtitles)
    }

    func testChineseSplitsPreserveSpeechAndTimeRange() {
        let text = "我们先创建一个新的项目，然后把屏幕录制的素材添加进来，最后调整字幕并导出视频。"
        let split = SubtitleSegmentation.split([.init(start: 2, end: 14, text: text)])
        XCTAssertGreaterThan(split.count, 1)
        XCTAssertEqual(split.map(\.text).joined(), text)
        XCTAssertEqual(split.first?.start, 2)
        XCTAssertEqual(split.last?.end, 14)
        XCTAssertTrue(split.allSatisfy { SubtitleSegmentation.width($0.text) <= 36 && $0.end > $0.start })
        for index in 1..<split.count { XCTAssertEqual(split[index].start, split[index - 1].end) }
        XCTAssertEqual(SubtitleSegmentation.split(split), split)
    }

    func testEnglishWordsAndMixedTechnicalNamesStayIntact() {
        let text = "Use AVFoundation and SuperWorkspace to preview the edited video before exporting."
        let result = SubtitleSegmentation.split([.init(start: 0, end: 10, text: text)])
        XCTAssertEqual(result.map(\.text).joined(separator: " "), text)
        XCTAssertTrue(result.contains { $0.text.contains("AVFoundation") })
        XCTAssertTrue(result.contains { $0.text.contains("SuperWorkspace") })
        XCTAssertTrue(result.allSatisfy { SubtitleSegmentation.width($0.text) <= 36 })
        let mixed = "我们来讲解一下codex跟chatgpt的区别以及如何选择工具执行操作"
        let chunks = SubtitleSegmentation.split([.init(start: 0, end: 8, text: mixed)])
        XCTAssertEqual(chunks.map(\.text).joined(), mixed)
        XCTAssertTrue(chunks.contains { $0.text.contains("chatgpt") })
        XCTAssertTrue(chunks.contains { $0.text.contains("codex") })
        XCTAssertTrue(chunks.allSatisfy { $0.text.count >= 6 })
    }

    func testCorrectionValidationRejectsMissingDuplicateAndInventedSpeech() throws {
        let source = [TranscriptSegment(start: 0, end: 2, text: "字幕校对"), .init(start: 2, end: 4, text: "导出视频")]
        XCTAssertThrowsError(try TranscriptCorrection.validate("[]", original: source))
        XCTAssertThrowsError(try TranscriptCorrection.validate("[{\"id\":0,\"text\":\"字幕校对\"},{\"id\":0,\"text\":\"导出视频\"}]", original: source))
        XCTAssertThrowsError(try TranscriptCorrection.validate("[{\"id\":0,\"text\":\"完全无关的长篇内容和新增台词\"},{\"id\":1,\"text\":\"导出视频\"}]", original: source))
        let corrected = try TranscriptCorrection.validate("```json\n[{\"id\":1,\"text\":\"导出视频\"},{\"id\":0,\"text\":\"字幕校正\"}]\n```", original: source)
        XCTAssertEqual(corrected, ["字幕校正", "导出视频"])
    }

    func testCorrectionUsesConfiguredCLIAndKeepsTimestamps() async throws {
        let source = [TranscriptSegment(start: 1, end: 3, text: "视频字慕")]
        let directory = FileManager.default.temporaryDirectory
        let config = TranscriptCorrectionConfiguration(launchPath: "/bin/sh",
            arguments: ["-c", "printf '%s' '[{\"id\":0,\"text\":\"视频字幕\"}]'", "subtitle-test"])
        let result = try await TranscriptCorrection.apply(source,
            video: directory.appendingPathComponent("missing-fixture.mp4"), directory: directory, configuration: config)
        XCTAssertEqual(result.segments, [.init(start: 1, end: 3, text: "视频字幕")])
        XCTAssertNil(result.warning)
    }

    func testFailurePreservesLocalRecognitionAndProvidesWarning() async throws {
        let source = [TranscriptSegment(start: 0, end: 2, text: "原始识别字幕")]
        let directory = FileManager.default.temporaryDirectory
        for launch in ["/bin/true", "/usr/bin/false"] {
            let result = try await TranscriptCorrection.apply(source,
                video: directory.appendingPathComponent("missing-fixture.mp4"), directory: directory,
                configuration: .init(launchPath: launch, arguments: []))
            XCTAssertEqual(result.segments, source)
            XCTAssertNotNil(result.warning)
        }
    }

    func testCorrectionConfigurationDoesNotLoadMotionSkillsOrTools() {
        let pi = TranscriptCorrectionConfiguration.arguments(isPi: true, deepSeekModel: "test-model")
        for flag in ["--no-tools", "--no-session", "--no-mcp", "--no-skills", "--no-context-files"] { XCTAssertTrue(pi.contains(flag)) }
        XCTAssertTrue(pi.contains("test-model"))
        XCTAssertFalse(pi.contains("--skill"))
        let claude = TranscriptCorrectionConfiguration.arguments(isPi: false)
        XCTAssertTrue(claude.contains("--no-session-persistence"))
        XCTAssertFalse(claude.contains("--provider"))
    }

    func testExternalCorrectionTimeoutIsBounded() async throws {
        do {
            try await Shell.run("/bin/sleep", arguments: ["2"], timeout: 0.05)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
    }

    @MainActor
    func testScreenTextContextAndOptionalLiveCorrection() async throws {
        guard let ffmpeg = ToolPaths.ffmpeg else { throw XCTSkip("ffmpeg required for synthetic screen fixture") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 675,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 675).fill()
        ("SuperWorkspace" as NSString).draw(at: NSPoint(x: 120, y: 300), withAttributes:
            [.font: NSFont.systemFont(ofSize: 76), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let still = directory.appendingPathComponent("screen.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: still)
        let video = directory.appendingPathComponent("screen.mp4")
        try await Shell.run(ffmpeg, arguments: ["-y", "-loop", "1", "-i", still.path, "-t", "1", "-vf", "scale=1200:674", "-pix_fmt", "yuv420p", video.path])
        let source = [TranscriptSegment(start: 0, end: 1, text: "打开 SuperWorkspase 项目")]
        let text = await TranscriptCorrection.visibleText(video: video, segments: source)
        XCTAssertTrue(text.joined().contains("SuperWorkspace"))
        if ProcessInfo.processInfo.environment["SUPERWORKSPACE_AI_SMOKE"] == "1" {
            let config = try XCTUnwrap(SettingsStore.shared.transcriptCorrectionConfiguration())
            let result = try await TranscriptCorrection.apply(source, video: video, directory: directory, configuration: config)
            XCTAssertNil(result.warning, result.warning ?? "")
            XCTAssertEqual(result.segments[0].text, "打开 SuperWorkspace 项目")
        }
    }
}
