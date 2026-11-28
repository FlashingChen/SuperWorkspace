import Foundation
import XCTest
@testable import SuperWorkspace

final class MotionAdapterTests: XCTestCase {
    func testManifestDecodingAndTargetResolution() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        {
          "version": 1,
          "fps": 60,
          "width": 3024,
          "height": 1702,
          "shots": [
            { "id": "Act1", "composition": "Act1Shot", "start": 2.0, "end": 8.5, "files": ["src/shots/Act1.tsx"] },
            { "id": "Act2", "composition": "Act2Shot", "start": 10.0, "end": 18.0 }
          ],
          "overlays": [
            { "id": "Badge1", "composition": "OvBadge", "start": 0.2, "end": 1.8, "x": 1800, "y": 200, "width": 720, "height": 280, "files": ["src/overlays/Overlays.tsx"] }
          ]
        }
        """
        try json.write(to: dir.appendingPathComponent(MotionManifest.filename), atomically: true, encoding: .utf8)

        let manifest = try XCTUnwrap(MotionManifest.load(in: dir))
        XCTAssertEqual(manifest.fps, 60)
        XCTAssertEqual(manifest.shots.count, 2)
        XCTAssertEqual(manifest.overlays.count, 1)

        // ID & composition case-insensitive lookup
        XCTAssertEqual(manifest.target(id: "act1")?.id, "Act1")
        XCTAssertEqual(manifest.target(id: "ovbadge")?.id, "Badge1")
        XCTAssertNil(manifest.target(id: "missing"))

        // Time-based lookup: direct hit, tolerance fallback, and out-of-range
        XCTAssertEqual(manifest.targets(at: 5.0).first?.id, "Act1")
        XCTAssertEqual(manifest.targets(at: 1.0).first?.id, "Badge1")
        XCTAssertEqual(manifest.targets(at: 9.8).first?.id, "Act2")
        XCTAssertTrue(manifest.targets(at: 25.0).isEmpty)

        // Refinement brief includes exact files and adapter commands
        let target = try XCTUnwrap(manifest.target(id: "Act1"))
        let brief = MotionManifest.refinementBrief(target: target, instruction: "卡片向右移 40px")
        XCTAssertTrue(brief.contains("src/shots/Act1.tsx"))
        XCTAssertTrue(brief.contains("node sw-motion.mjs inspect --shots Act1"))
        XCTAssertTrue(brief.contains("node sw-motion.mjs render"))
    }

    func testInstallScaffoldSeedsKitAndPreservesCustomFiles() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let seed = root.appendingPathComponent("Integration/RemotionRuntime")
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // Pre-create a custom tsconfig.json to verify it is NOT overwritten
        let customConfig = workspace.appendingPathComponent("tsconfig.json")
        try "{\"custom\":true}".write(to: customConfig, atomically: true, encoding: .utf8)

        try RemotionRuntime.installScaffold(from: seed, into: workspace)

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("sw-motion.mjs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("src/sw-kit/WorldCamera.tsx").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("src/sw-kit/StageFrame.tsx").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("src/sw-kit/DeviceMockup.tsx").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("src/sw-kit/EditorialUI.tsx").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("src/sw-kit/theme.ts").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("remotion.config.ts").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("src/index.ts").path))
        let cameraSource = try String(
            contentsOf: workspace.appendingPathComponent("src/sw-kit/WorldCamera.tsx"),
            encoding: .utf8
        )
        XCTAssertTrue(cameraSource.contains("useVideoConfig"))
        XCTAssertTrue(cameraSource.contains("viewportWidth ?? width ?? stage?.width ?? config.width"))
        XCTAssertTrue(cameraSource.contains("rotateY"))
        XCTAssertTrue(cameraSource.contains("perspective"))

        let editorialSource = try String(
            contentsOf: workspace.appendingPathComponent("src/sw-kit/EditorialUI.tsx"),
            encoding: .utf8
        )
        XCTAssertTrue(editorialSource.contains("export const SpokenMicroPill"))
        XCTAssertTrue(editorialSource.contains("export const LiquidMeter"))
        XCTAssertTrue(editorialSource.contains("export const MacWindowStage"))

        let libSource = try String(
            contentsOf: workspace.appendingPathComponent("src/sw-kit/lib.ts"),
            encoding: .utf8
        )
        XCTAssertTrue(libSource.contains("export const springIn"))
        XCTAssertTrue(libSource.contains("export const springMorph"))

        let adapterSource = try String(
            contentsOf: workspace.appendingPathComponent("sw-motion.mjs"),
            encoding: .utf8
        )
        XCTAssertTrue(adapterSource.contains("contact-sheet-${sheets.length + 1}.jpg"))
        XCTAssertTrue(adapterSource.contains("'-c:v', 'mjpeg'"))
        XCTAssertTrue(adapterSource.contains("personAnchor"))
        XCTAssertTrue(adapterSource.contains("eval=frame"))
        XCTAssertEqual(try String(contentsOf: customConfig, encoding: .utf8), "{\"custom\":true}")
    }

    @MainActor
    func testExportResolvedFrameRatePreservesSixtyFPS() {
        XCTAssertEqual(ExportService.resolvedFrameRate(from: [60]), 60)
        XCTAssertEqual(ExportService.resolvedFrameRate(from: [59.94]), 60)
        XCTAssertEqual(ExportService.resolvedFrameRate(from: [30, 60]), 60)
        XCTAssertEqual(ExportService.resolvedFrameRate(from: [30]), 30)
        XCTAssertEqual(ExportService.resolvedFrameRate(from: [29.97]), 30)
        XCTAssertEqual(ExportService.resolvedFrameRate(from: []), 30)
    }

    func testFreezeRemovesCacheAndAdapterWhileKeepingManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["SUPERWORKSPACE_TEST_ROOT"]
        setenv("SUPERWORKSPACE_TEST_ROOT", root.path, 1)
        defer {
            if let previous { setenv("SUPERWORKSPACE_TEST_ROOT", previous, 1) } else { unsetenv("SUPERWORKSPACE_TEST_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }

        var p = VideoProject(name: "FreezeManifestTest")
        var material = Material(duration: 10, exportState: .complete)
        material.motionState = .complete
        p.materials = [material]

        let dir = ProjectLayout.materialDirectory(material, in: p)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".sw-cache"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)

        try Data("cached".utf8).write(to: dir.appendingPathComponent(".sw-cache/shot-a.mp4"))
        try Data("adapter".utf8).write(to: dir.appendingPathComponent("sw-motion.mjs"))
        try Data("{\"version\":1}".utf8).write(to: dir.appendingPathComponent(MotionManifest.filename))
        try Data("export {}".utf8).write(to: dir.appendingPathComponent("src/Root.tsx"))

        _ = try ProjectFreeze.freeze(p)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".sw-cache").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sw-motion.mjs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(MotionManifest.filename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("src/Root.tsx").path))
    }
}
