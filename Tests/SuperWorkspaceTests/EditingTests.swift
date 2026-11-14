import XCTest
import AVFoundation
import AppKit
@testable import SuperWorkspace

@MainActor
final class EditingTests: XCTestCase {
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
        var project = VideoProject(name: "Editing")
        var material = Material()
        material.duration = 3
        material.exportState = .complete
        material.transcriptState = .complete
        material.subtitleLayoutVersion = SubtitleSegmentation.version
        material.subtitles = [.init(start: 0.2, end: 1, text: "First"), .init(start: 1.5, end: 2.5, text: "Second")]
        project.materials = [material]
        return project
    }

    func testTrimClipsSubtitlesAndOffsetsWithoutChangingSourceDuration() async throws {
        try await withStorage { _ in
            var project = fixture()
            let id = project.materials[0].id
            var second = project.materials[0]
            second.id = UUID()
            project.materials.append(second)
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            XCTAssertTrue(state.setTrim(project.id, id, start: 0.5, end: 2))
            var edited = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertEqual(edited.materials[0].duration, 3)
            XCTAssertEqual(edited.materials[0].timelineDuration, 1.5)
            XCTAssertEqual(edited.assembledSubtitles.map(\.start), [0, 1, 1.7, 3])
            XCTAssertEqual(edited.assembledSubtitles.map(\.end), [0.5, 1.5, 2.5, 4])
            XCTAssertEqual(AssemblyTimelineLayout(materials: edited.materials).duration, 4.5)
            XCTAssertFalse(state.setTrim(project.id, id, start: 2, end: 1))
            XCTAssertFalse(state.setTrim(project.id, id, start: 0, end: .nan))
            state.undo()
            edited = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertEqual(edited.materials[0].timelineDuration, 3)
            state.redo()
            XCTAssertEqual(ProjectLayout.loadAll().first?.materials[0].timelineDuration, 1.5)
        }
    }

    func testSubtitleTimingAndTextUndoStayWithinMaterialAndNeighbors() async throws {
        try await withStorage { _ in
            let project = fixture(), id = project.materials[0].id
            try ProjectLayout.save(project)
            let state = AppState()
            state.select(project.id)
            XCTAssertFalse(state.setSubtitleTiming(project.id, id, index: 0, start: -1, end: 1))
            XCTAssertFalse(state.setSubtitleTiming(project.id, id, index: 0, start: 0, end: 2))
            XCTAssertFalse(state.setSubtitleTiming(project.id, id, index: 1, start: 1.5, end: 4))
            XCTAssertTrue(state.setSubtitleTiming(project.id, id, index: 0, start: 0.3, end: 1.2))
            state.editSubtitle(projectID: project.id, materialID: id, index: 0, text: "Edited")
            state.undo()
            XCTAssertEqual(state.currentProject?.materials[0].subtitles[0].text, "First")
            state.undo()
            XCTAssertEqual(state.currentProject?.materials[0].subtitles[0].start, 0.2)
            state.redo()
            XCTAssertEqual(state.currentProject?.materials[0].subtitles[0].end, 1.2)
            let restored = AppState()
            XCTAssertEqual(restored.currentProject?.materials[0].subtitles[0].start, 0.3)
        }
    }

    func testWorkspaceRestoresProjectsStagePositionAndSelection() async throws {
        try await withStorage { _ in
            let first = fixture(), second = VideoProject(name: "Other")
            try ProjectLayout.save(first); try ProjectLayout.save(second)
            let state = AppState()
            state.select(first.id); state.stage = .assemble
            var session = state.editorSession(first.id)
            session.playhead = 1.4; session.zoom = 3; session.previewHeight = 0.6
            session.selectedMaterial = first.materials[0].id
            session.selectedSubtitle = "\(first.materials[0].id)-1"
            state.rememberEditor(first.id, session, flush: true)
            state.select(second.id)
            XCTAssertEqual(state.stage, .record)
            state.select(first.id)
            XCTAssertEqual(state.stage, .assemble)
            let restored = AppState()
            XCTAssertEqual(restored.selectedProjectID, first.id)
            XCTAssertEqual(restored.stage, .assemble)
            XCTAssertEqual(restored.editorSession(first.id).playhead, 1.4)
            XCTAssertEqual(restored.editorSession(first.id).zoom, 3)
            XCTAssertEqual(restored.editorSession(first.id).selectedSubtitle, session.selectedSubtitle)
        }
    }

    func testOriginalChoiceCaptionChoiceReorderAndDeleteAreReversible() async throws {
        try await withStorage { _ in
            var project = fixture()
            project.materials[0].wantsMotion = true
            project.materials[0].motionState = .complete
            var second = project.materials[0]; second.id = UUID()
            project.materials.append(second)
            try ProjectLayout.save(project)
            let state = AppState(); state.select(project.id)
            let id = project.materials[0].id
            state.setUseOriginal(project.id, id, true)
            XCTAssertEqual(ProjectLayout.picture(state.currentProject!.materials[0], in: project), ProjectLayout.source(project.materials[0], in: project))
            state.undo()
            XCTAssertEqual(ProjectLayout.picture(state.currentProject!.materials[0], in: project), ProjectLayout.motion(project.materials[0], in: project))
            state.setIncludeSubtitles(project.id, false); state.undo()
            XCTAssertTrue(state.currentProject!.includeSubtitles)
            state.moveMaterial(project.id, index: 0, by: 1); state.undo()
            XCTAssertEqual(state.currentProject?.materials.map(\.id), project.materials.map(\.id))
            XCTAssertTrue(state.removeMaterial(project.id, id)); state.undo()
            XCTAssertEqual(state.currentProject?.materials.map(\.id), project.materials.map(\.id))
            state.redo()
            XCTAssertEqual(state.currentProject?.materials.map(\.id), [second.id])
        }
    }

    func testTrimmedPreviewAndExportUseSameSubtitlesAndCanvas() async throws {
        guard let ffmpeg = ToolPaths.ffmpeg else { throw XCTSkip("Synthetic media requires ffmpeg") }
        try await withStorage { _ in
            var project = fixture()
            project.materials[0].wantsMotion = true
            project.materials[0].motionState = .failed
            project.materials[0].trimStart = 0.5
            project.materials[0].trimEnd = 2
            let material = project.materials[0]
            let source = ProjectLayout.source(material, in: project)
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await Shell.run(ffmpeg, arguments: ["-y", "-f", "lavfi", "-i", "color=c=red:s=320x180:r=30:d=3", "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-t", "3", source.path])
            let assembly = try await ExportService.assemble(project: project, includeSubtitles: true)
            let preview = AVAssetImageGenerator(asset: assembly.composition)
            preview.videoComposition = assembly.videoComposition
            preview.requestedTimeToleranceBefore = .zero; preview.requestedTimeToleranceAfter = .zero
            let time = CMTime(seconds: 0.2, preferredTimescale: 600)
            let previewImage = try preview.copyCGImage(at: time, actualTime: nil)
            project.exportSRT = true
            let output = try await ExportService.export(project: project)
            let sidecar = try String(contentsOf: output.deletingPathExtension().appendingPathExtension("srt"), encoding: .utf8)
            XCTAssertEqual(TranscriptService.parseSRT(sidecar), project.assembledSubtitles)
            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(duration, 1.5, accuracy: 0.05)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertFalse(audioTracks.isEmpty)
            let exported = AVAssetImageGenerator(asset: asset)
            exported.requestedTimeToleranceBefore = .zero; exported.requestedTimeToleranceAfter = .zero
            let exportedImage = try await exported.image(at: time).image
            XCTAssertEqual(previewImage.width, exportedImage.width)
            let a = rgba(previewImage), b = rgba(exportedImage)
            // Video encoding can change the color transfer function; compare caption geometry.
            let previewMask = whiteMask(a), exportMask = whiteMask(b)
            XCTAssertGreaterThan(previewMask.count, 10)
            let overlap = Double(previewMask.intersection(exportMask).count) / Double(previewMask.union(exportMask).count)
            XCTAssertGreaterThan(overlap, 0.85, "Preview and compressed export must have equivalent caption layout")
            project.includeSubtitles = false
            project.exportSRT = false
            project.materials[0].transcriptState = .failed
            let withoutCaptions = try await ExportService.assemble(project: project, includeSubtitles: true)
            XCTAssertFalse((withoutCaptions.videoComposition.instructions[0] as! AssemblyInstruction).overlays.isEmpty, "Export choices must not strip styled captions from the editor")
            let control = ExportProgress(); control.cancel()
            do { _ = try await ExportService.export(project: project, progress: control); XCTFail("Cancelled export must not start") }
            catch is CancellationError { }
            project.canvasWidth = 180; project.canvasHeight = 320
            let portrait = try await ExportService.assemble(project: project)
            XCTAssertEqual(portrait.size, CGSize(width: 180, height: 320))
        }
    }

    func testExportedFileKeepsEveryClipOnOneAudioTrack() async throws {
        guard let ffmpeg = ToolPaths.ffmpeg else { throw XCTSkip("Synthetic media requires ffmpeg") }
        try await withStorage { _ in
            var project = fixture()
            var second = project.materials[0]
            second.id = UUID()
            project.materials.append(second)
            for material in project.materials {
                let source = ProjectLayout.source(material, in: project)
                try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await Shell.run(ffmpeg, arguments: ["-y", "-f", "lavfi", "-i", "color=c=blue:s=160x90:r=30:d=3",
                                                        "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                                                        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-t", "3", source.path])
            }
            let output = try await ExportService.export(project: project)
            let asset = AVURLAsset(url: output)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audioTracks.count, 1, "每个素材单独建音轨会让只播一条音轨的播放器只听到第一段")
            let log = try await Shell.run(ffmpeg, arguments: ["-nostats", "-hide_banner", "-ss", "4.5", "-i", output.path,
                                                              "-map", "0:a:0", "-af", "volumedetect", "-f", "null", "-"])
            var loudness: Double?
            for line in log.split(separator: "\n") where line.contains("mean_volume") {
                if let value = line.split(separator: "mean_volume:").last?.split(separator: " ").first { loudness = Double(value) }
            }
            XCTAssertGreaterThan(try XCTUnwrap(loudness), -60, "第二段素材的声音必须落在同一条音轨上")
        }
    }

    func testProjectLibraryImportsBeforeRecordingAndInsertsOnlyAtPlannedTimes() async throws {
        guard let ffmpeg = ToolPaths.ffmpeg else { throw XCTSkip("Synthetic media requires ffmpeg") }
        try await withStorage { root in
            var project = VideoProject(name: "Library")
            try ProjectLayout.save(project)
            let image = root.appendingPathComponent("still.png")
            let video = root.appendingPathComponent("cutaway.mp4")
            try await Shell.run(ffmpeg, arguments: ["-y", "-f", "lavfi", "-i", "color=blue:s=320x180", "-frames:v", "1", image.path])
            try await Shell.run(ffmpeg, arguments: ["-y", "-f", "lavfi", "-i", "color=green:s=320x180:r=30:d=1", "-c:v", "libx264", video.path])
            let still = try await ReferenceMediaImport.copy(image, into: project)
            let cutaway = try await ReferenceMediaImport.copy(video, into: project)
            project.referenceMedia = [still, cutaway]
            try ProjectLayout.save(project)
            try FileManager.default.removeItem(at: image)
            try FileManager.default.removeItem(at: video)
            project = try XCTUnwrap(ProjectLayout.loadAll().first)
            XCTAssertTrue(project.materials.isEmpty)
            XCTAssertEqual(project.referenceMedia.map(\.kind), [.image, .video])

            var material = fixture().materials[0]
            material.editingPrompt = "Add the photo and then the cutaway."
            project.materials = [material]
            try ProjectLayout.save(project)
            XCTAssertEqual(ProjectLayout.loadAll().first?.materials.first?.editingPrompt, material.editingPrompt)
            project.includeSubtitles = false
            project.exportSRT = true
            let source = ProjectLayout.source(material, in: project)
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await Shell.run(ffmpeg, arguments: ["-y", "-f", "lavfi", "-i", "color=red:s=320x180:r=30:d=3",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-c:v", "libx264", "-c:a", "aac", source.path])
            let clip = AIEditing.Clip(id: material.id, start: 0.5, end: 2.5)
            let imageInsert = AIEditing.Insert(clipID: material.id, assetID: still.id, start: 0.75, end: 1.25, assetStart: nil)
            let videoInsert = AIEditing.Insert(clipID: material.id, assetID: cutaway.id, start: 1.5, end: 2.25, assetStart: 0.2)
            let invalid = AIEditing.Plan(clips: [clip], inserts: [imageInsert, imageInsert])
            XCTAssertThrowsError(try AIEditing.apply(invalid, to: &project))
            XCTAssertEqual(project.materials[0].inPoint, 0)
            let plan = AIEditing.Plan(clips: [clip], inserts: [imageInsert, videoInsert])
            try AIEditing.apply(plan, to: &project)
            let output = try await ExportService.export(project: project, inserts: plan.inserts)
            let subtitles = try String(contentsOf: output.deletingPathExtension().appendingPathExtension("srt"), encoding: .utf8)
            XCTAssertTrue(subtitles.contains("00:00:00,000 --> 00:00:00,500"))
            let asset = AVURLAsset(url: output)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audio.count, 1)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            // 0.25–0.75s shows the still inside its rounded window, 1.0–1.75s the video cutaway
            // over the fallback background; elsewhere the main red picture. Each probe reads the
            // picture's own pixel.
            for (second, channel) in [(0.1, 0), (0.4, 2), (0.85, 0), (1.3, 1), (1.85, 0)] {
                let frame = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image
                let bytes = rgba(frame)
                let center = (frame.width * (frame.height / 2) + frame.width / 2) * 4
                let expected = bytes[center + channel]
                XCTAssertGreaterThan(expected, 95, "Unexpected picture at \(second)s")
                XCTAssertGreaterThan(Int(expected), Int(bytes[center + (channel + 1) % 3]) + 40)
                XCTAssertGreaterThan(Int(expected), Int(bytes[center + (channel + 2) % 3]) + 40)
            }
            // The window sits on the drawn fallback background: the frame corners stay dark and
            // flat background pixels do not soften into their neighbours the way a blur would.
            let stillFrame = try await generator.image(at: CMTime(seconds: 0.4, preferredTimescale: 600)).image
            let stillBytes = rgba(stillFrame)
            let pixel: (Int, Int) -> (Int, Int, Int) = { x, y in
                let offset = (y * stillFrame.width + x) * 4
                return (Int(stillBytes[offset]), Int(stillBytes[offset + 1]), Int(stillBytes[offset + 2]))
            }
            let edge = 4
            for (x, y) in [(edge, edge), (stillFrame.width - edge - 1, edge),
                           (edge, stillFrame.height - edge - 1),
                           (stillFrame.width - edge - 1, stillFrame.height - edge - 1)] {
                let (red, green, blue) = pixel(x, y)
                XCTAssertLessThan(red, 60, "Fallback background must stay dark at \(x),\(y): \(red),\(green),\(blue)")
                XCTAssertLessThan(green, 60, "Fallback background must stay dark at \(x),\(y): \(red),\(green),\(blue)")
                XCTAssertLessThan(blue, 60, "Fallback background must stay dark at \(x),\(y): \(red),\(green),\(blue)")
            }
            for x in [6, 10] {
                let (red, green, blue) = pixel(x, 10)
                let (nextRed, nextGreen, nextBlue) = pixel(x + 1, 10)
                XCTAssertLessThanOrEqual(abs(red - nextRed), 3, "Background pixels must not spread into a blur")
                XCTAssertLessThanOrEqual(abs(green - nextGreen), 3, "Background pixels must not spread into a blur")
                XCTAssertLessThanOrEqual(abs(blue - nextBlue), 3, "Background pixels must not spread into a blur")
            }
        }
    }

    func testInsertBackdropIsDrawnAndExportCodeHasNoBlurPath() throws {
        let canvas = CGSize(width: 1280, height: 720)
        let backdrop = ExportService.backdrop(for: canvas)
        XCTAssertEqual(backdrop.width, 1280)
        XCTAssertEqual(backdrop.height, 720)
        let artifact = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("insert-backdrop-\(UUID().uuidString).png")
        let encoded = try XCTUnwrap(NSBitmapImageRep(cgImage: backdrop).representation(using: .png, properties: [:]))
        try encoded.write(to: artifact)
        print("Insert backdrop PNG: \(artifact.path)")

        let bytes = rgba(backdrop)
        let edge = 4
        let corner = (edge * backdrop.width + edge) * 4
        for channel in 0..<3 {
            XCTAssertLessThan(Int(bytes[corner + channel]), 60, "The fallback backdrop corner must stay dark")
        }
        for x in [40, 44] {
            let offset = (40 * backdrop.width + x) * 4
            let next = (40 * backdrop.width + x + 1) * 4
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(Int(bytes[offset + channel]) - Int(bytes[next + channel])), 3,
                                         "Background pixels must not spread into a blur")
            }
        }

        // Regression guard: the export pipeline must never reintroduce a blurred backdrop.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SuperWorkspace/ExportService.swift")
        let code = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(code.contains("func backdrop(for canvas: CGSize) -> CGImage"),
                      "The fallback background must be drawn in ExportService")
        XCTAssertFalse(code.contains("GaussianBlur"), "Export must not generate a blurred backdrop")
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    private func whiteMask(_ bytes: [UInt8]) -> Set<Int> {
        Set(stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 180 && bytes[$0 + 1] > 180 && bytes[$0 + 2] > 180 })
    }
}
