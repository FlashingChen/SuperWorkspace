import XCTest
import AVFoundation
@testable import SuperWorkspace

@MainActor
final class WorkflowTests: XCTestCase {
    func testSubtitleOffsetsFollowMaterialOrderAndEdits() throws {
        var project = VideoProject(name: "Test")
        var first = Material()
        first.duration = 2
        first.exportState = .complete
        first.transcriptState = .complete
        first.subtitles = [.init(start: 0.2, end: 1.2, text: "第一句")]
        var second = first
        second.id = UUID()
        second.duration = 3
        second.subtitles = [.init(start: 0.5, end: 2, text: "第二句")]
        project.materials = [first, second]
        XCTAssertTrue(project.canExport)
        XCTAssertEqual(project.assembledSubtitles.map(\.start), [0.2, 2.5])
        project.materials.swapAt(0, 1)
        project.materials[0].subtitles[0].text = "已校对"
        let restored = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(restored.assembledSubtitles.map(\.start), [0.5, 3.2])
        XCTAssertEqual(restored.assembledSubtitles.first?.text, "已校对")
    }

    func testRequiredMotionAndTranscriptGateExport() {
        var project = VideoProject(name: "Test")
        var material = Material()
        material.duration = 1
        material.exportState = .complete
        material.transcriptState = .complete
        material.wantsMotion = true
        material.motionState = .failed
        project.materials = [material]
        XCTAssertFalse(project.canExport)
        project.materials[0].motionState = .complete
        XCTAssertTrue(project.canExport)
        project.materials[0].transcriptState = .running
        XCTAssertFalse(project.canExport)
    }

    func testLegacyMetadataStillDecodes() throws {
        let project = VideoProject(name: "Legacy")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        json.removeValue(forKey: "materials")
        json["wantsAIMotion"] = true
        let decoded = try JSONDecoder().decode(VideoProject.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.id, project.id)
        XCTAssertTrue(decoded.materials.isEmpty)
    }

    func testInterruptedTasksArePersistedAsRetryableFailures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["SUPERWORKSPACE_TEST_ROOT"]
        setenv("SUPERWORKSPACE_TEST_ROOT", root.path, 1)
        defer {
            if let previous { setenv("SUPERWORKSPACE_TEST_ROOT", previous, 1) } else { unsetenv("SUPERWORKSPACE_TEST_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        var project = VideoProject(name: "Interrupted")
        var material = Material()
        material.exportState = .complete
        material.duration = 1
        material.wantsMotion = true
        material.motionState = .running
        material.transcriptState = .running
        project.materials = [material]
        try ProjectLayout.save(project)
        let state = AppState()
        XCTAssertEqual(state.projects.first?.materials.first?.motionState, .failed)
        let restored = try XCTUnwrap(ProjectLayout.loadAll().first?.materials.first)
        XCTAssertEqual(restored.motionState, .failed)
        XCTAssertEqual(restored.transcriptState, .failed)
        XCTAssertEqual(restored.exportState, .complete)
    }

    func testSRTParsingMultilineAndNumericSpeech() {
        let segments = TranscriptService.parseSRT("1\n00:00:00,100 --> 00:00:01,000\n123\n下一行\n\n2\n00:00:01,000 --> 00:00:02,000\n第二句\n")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "123 下一行")
        XCTAssertEqual(segments[1].start, 1)
    }

    func testAssemblyExportsOrderedMixedGeometryWithEditedSubtitles() async throws {
        guard let ffmpeg = ToolPaths.ffmpeg else { throw XCTSkip("ffmpeg is required for synthetic media fixtures") }
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let previous = ProcessInfo.processInfo.environment["SUPERWORKSPACE_TEST_ROOT"]
        setenv("SUPERWORKSPACE_TEST_ROOT", testRoot.path, 1)
        defer {
            if let previous { setenv("SUPERWORKSPACE_TEST_ROOT", previous, 1) } else { unsetenv("SUPERWORKSPACE_TEST_ROOT") }
            try? FileManager.default.removeItem(at: testRoot)
        }
        var project = VideoProject(name: "Synthetic")
        for index in 0..<2 {
            var material = Material()
            material.duration = 1
            material.exportState = .complete
            material.transcriptState = .complete
            material.subtitles = [.init(start: 0.1, end: 0.9, text: index == 0 ? "校对后的字幕" : "第二段")]
            try FileManager.default.createDirectory(at: ProjectLayout.materialDirectory(material, in: project), withIntermediateDirectories: true)
            var arguments = ["-y", "-f", "lavfi", "-i", index == 0 ? "color=c=red:s=320x180:r=30:d=1" : "color=c=blue:s=180x320:r=30:d=1"]
            if index == 0 { arguments += ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "aac"] }
            arguments += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-t", "1", ProjectLayout.source(material, in: project).path]
            try await Shell.run(ffmpeg, arguments: arguments)
            project.materials.append(material)
        }
        try ProjectLayout.save(project)
        let state = AppState()
        let other = VideoProject(name: "Other")
        state.projects.append(other)
        state.select(other.id)
        let settings = SettingsStore.shared
        let previousLaunch = settings.aiMotionLaunchPath
        let previousArgs = settings.aiMotionExtraArgs
        let previousAgent = settings.aiMotionAgent
        defer {
            settings.aiMotionLaunchPath = previousLaunch
            settings.aiMotionExtraArgs = previousArgs
            settings.aiMotionAgent = previousAgent
        }
        settings.aiMotionAgent = MotionAgent.automatic.rawValue
        let stub = testRoot.appendingPathComponent("agent-stub")
        try "#!/bin/bash\ncp \"${@: -2:1}\" \"${@: -1}\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        settings.aiMotionLaunchPath = stub.path
        settings.aiMotionExtraArgs = "{source1}\n{source2}"
        let materialID = project.materials[0].id
        state.updateProject(project.id) { $0.materials[0].wantsMotion = true }
        state.enqueueMotion(project.id, materialID)
        for _ in 0..<100 {
            let status = state.projects.first { $0.id == project.id }?.materials[0].motionState
            if status == .complete || status == .failed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        project = try XCTUnwrap(state.projects.first { $0.id == project.id })
        XCTAssertEqual(project.materials[0].motionState, .complete, project.materials[0].motionError ?? "")
        XCTAssertEqual(state.selectedProjectID, other.id, "Background completion must not switch projects")
        XCTAssertTrue(state.projects.first { $0.id == other.id }!.materials.isEmpty)
        let result = try await ExportService.export(project: project)
        let duration = try await AVURLAsset(url: result).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.1)
        let imageGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: result))
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero
        let first = try await imageGenerator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let last = try await imageGenerator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
        XCTAssertEqual(first.width, 320)
        XCTAssertEqual(last.height, 180)
        let firstPixels = pixels(first)
        let lastPixels = pixels(last)
        XCTAssertGreaterThan(firstPixels.red, firstPixels.blue)
        XCTAssertGreaterThan(lastPixels.blue, lastPixels.red)
        XCTAssertGreaterThan(firstPixels.white, 20, "Edited subtitles must be burned into the exported video")
        XCTAssertGreaterThan(lastPixels.white, 20)
    }

    private func pixels(_ image: CGImage) -> (red: Int, blue: Int, white: Int) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var red = 0, blue = 0, white = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[i] > 180 && bytes[i + 2] < 80 { red += 1 }
            if bytes[i + 2] > 180 && bytes[i] < 80 { blue += 1 }
            if bytes[i] > 200 && bytes[i + 1] > 200 && bytes[i + 2] > 200 { white += 1 }
        }
        return (red, blue, white)
    }
}
