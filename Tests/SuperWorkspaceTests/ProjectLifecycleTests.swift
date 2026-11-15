import AVFoundation
import XCTest
@testable import SuperWorkspace

@MainActor
final class ProjectLifecycleTests: XCTestCase {
    private func withStorage(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["SUPERWORKSPACE_TEST_ROOT"]
        setenv("SUPERWORKSPACE_TEST_ROOT", root.path, 1)
        defer {
            if let previous { setenv("SUPERWORKSPACE_TEST_ROOT", previous, 1) } else { unsetenv("SUPERWORKSPACE_TEST_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    private func touch(_ url: URL, bytes: Int = 16) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private func readyMaterial(duration: Double = 2, motion: Bool = false) -> Material {
        var material = Material()
        material.duration = duration
        material.exportState = .complete
        material.transcriptState = .complete
        if motion {
            material.wantsMotion = true
            material.motionState = .complete
        }
        return material
    }

    func testFrozenStateRoundTripsAndDefaultsToEditable() throws {
        var project = VideoProject(name: "Frozen")
        XCTAssertFalse(project.isFrozen)
        project.frozenAt = Date(timeIntervalSince1970: 1_700_000_000)
        let decoded = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(project))
        XCTAssertTrue(decoded.isFrozen)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        legacy.removeValue(forKey: "frozenAt")
        let restored = try JSONDecoder().decode(VideoProject.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(restored.isFrozen)
    }

    func testFreezeRemovesRuntimeAndKeepsProjectMedia() throws {
        try withStorage { _ in
            var project = VideoProject(name: "Freeze fixture")
            let material = readyMaterial(motion: true)
            project.materials = [material]
            let directory = ProjectLayout.materialDirectory(material, in: project)
            let kept = ["source.mp4", "motion.mp4", "transcript.json", "transcript-raw.json",
                        "motion-analysis.json", "audio-16k.wav", "src/scene.tsx"]
            for name in kept { try touch(directory.appendingPathComponent(name)) }
            for name in ["node_modules/dep/index.js", "package.json", "out/render.mp4", "motion-pending.mp4"] {
                try touch(directory.appendingPathComponent(name))
            }

            let reclaimed = try ProjectFreeze.freeze(project)
            XCTAssertGreaterThan(reclaimed, 0)
            let files = FileManager.default
            for name in kept {
                XCTAssertTrue(files.fileExists(atPath: directory.appendingPathComponent(name).path), "\(name) must stay")
            }
            for name in ProjectFreeze.runtimeEntries {
                XCTAssertFalse(files.fileExists(atPath: directory.appendingPathComponent(name).path), "\(name) must go")
            }
            XCTAssertTrue(ProjectFreeze.workspacesNeedingRebuild(project).contains(directory.standardizedFileURL),
                          "A workspace with src/ or motion.mp4 must be rebuilt on unfreeze")
        }
    }

    func testFreezeRemovesDependencyLinkWithoutTouchingSharedCache() throws {
        try withStorage { _ in
            var project = VideoProject(name: "Link fixture")
            let material = readyMaterial(motion: true)
            project.materials = [material]
            let directory = ProjectLayout.materialDirectory(material, in: project)
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: cache) }
            try touch(cache.appendingPathComponent("remotion/index.js"))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("node_modules"),
                                                       withDestinationURL: cache)

            XCTAssertEqual(try ProjectFreeze.freeze(project), 0, "A link to the shared cache carries no bytes")
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("node_modules").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("remotion/index.js").path))
        }
    }

    func testArchiveLayoutUsesSourcesAndFinishedMotionsOnly() {
        var project = VideoProject(name: "Layout fixture")
        var first = readyMaterial(duration: 2, motion: true)
        var second = readyMaterial(duration: 3)
        second.motionState = .failed
        second.wantsMotion = true
        var third = readyMaterial(duration: 4)
        third.exportState = .failed
        project.materials = [first, second, third]

        let layout = ProjectArchive.layout(of: project)
        XCTAssertEqual(layout.sources.map(\.id), [first.id, second.id])
        XCTAssertEqual(layout.motions.map(\.id), [first.id])
        first.useOriginal = true
        project.materials[0] = first
        XCTAssertEqual(ProjectLayout.picture(project.materials[0], in: project),
                       ProjectLayout.source(project.materials[0], in: project))
    }

    func testBundleFolderNameStripsPathSeparators() {
        XCTAssertEqual(ProjectArchive.folderName(for: VideoProject(name: "  ")), "未命名项目")
        XCTAssertEqual(ProjectArchive.folderName(for: VideoProject(name: "Ep 12: a/b")), "Ep 12- a-b")
    }

    func testOnlyExportedProjectsCanFreeze() throws {
        try withStorage { _ in
            var project = VideoProject(name: "Completion fixture")
            let material = readyMaterial()
            project.materials = [material]
            try ProjectLayout.save(project)
            let state = AppState()
            XCTAssertFalse(state.canFreeze(project.id), "Freezing follows a finished film")

            let output = ProjectLayout.url("export-\(UUID().uuidString).mp4", for: project)
            try Data().write(to: output)
            XCTAssertTrue(state.updateProject(project.id) { $0.lastExportName = output.lastPathComponent })
            XCTAssertTrue(state.canFreeze(project.id))

            XCTAssertTrue(state.updateProject(project.id) { $0.frozenAt = Date() })
            XCTAssertFalse(state.canFreeze(project.id))
            state.export(projectID: project.id)
            XCTAssertTrue(state.exportingProjects.isEmpty, "A frozen project must not start an export")
        }
    }

    func testBundleZipsSourceMotionAndFilm() async throws {
        guard let ffmpeg = ToolPaths.ffmpeg else { throw XCTSkip("ffmpeg is required for synthetic media fixtures") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let previous = ProcessInfo.processInfo.environment["SUPERWORKSPACE_TEST_ROOT"]
        setenv("SUPERWORKSPACE_TEST_ROOT", root.path, 1)
        defer {
            if let previous { setenv("SUPERWORKSPACE_TEST_ROOT", previous, 1) } else { unsetenv("SUPERWORKSPACE_TEST_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        let name = "Bundle fixture"
        var project = VideoProject(name: name)
        for (index, color) in ["red", "blue"].enumerated() {
            var material = readyMaterial(duration: 1)
            material.createdAt = Date(timeIntervalSince1970: TimeInterval(index))
            try FileManager.default.createDirectory(at: ProjectLayout.materialDirectory(material, in: project),
                                                    withIntermediateDirectories: true)
            try await Shell.run(ffmpeg, arguments: ["-y", "-f", "lavfi", "-i", "color=c=\(color):s=320x180:r=30:d=1",
                                                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-t", "1",
                                                    ProjectLayout.source(material, in: project).path])
            project.materials.append(material)
        }
        project.materials[0].wantsMotion = true
        project.materials[0].motionState = .complete
        try await Shell.run(ffmpeg, arguments: ["-y", "-f", "lavfi", "-i", "color=c=green:s=320x180:r=30:d=1",
                                                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-t", "1",
                                                ProjectLayout.motion(project.materials[0], in: project).path])
        let film = ProjectLayout.url("export-fixture.mp4", for: project)
        try Data(repeating: 0x46, count: 64).write(to: film)
        project.lastExportName = film.lastPathComponent
        try ProjectLayout.save(project)

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: destination) }
        let bundle = try await ProjectArchive.export(project: project, to: destination)
        XCTAssertEqual(bundle, destination)

        let unpacked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        try await Shell.run("/usr/bin/unzip", arguments: ["-q", destination.path, "-d", unpacked.path])
        let folder = unpacked.appendingPathComponent(name, isDirectory: true)
        let files = FileManager.default
        XCTAssertTrue(files.fileExists(atPath: folder.appendingPathComponent("source.mp4").path))
        XCTAssertTrue(files.fileExists(atPath: folder.appendingPathComponent("motion.mp4").path))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("film.mp4")), Data(repeating: 0x46, count: 64))
        let sourceDuration = try await AVURLAsset(url: folder.appendingPathComponent("source.mp4")).load(.duration).seconds
        XCTAssertEqual(sourceDuration, 2, accuracy: 0.15)
        let motionDuration = try await AVURLAsset(url: folder.appendingPathComponent("motion.mp4")).load(.duration).seconds
        XCTAssertEqual(motionDuration, 1, accuracy: 0.15)
    }
}
