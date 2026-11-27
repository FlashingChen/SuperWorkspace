import Foundation
import RecorderKit
import XCTest
@testable import SuperWorkspace

final class RoughCutResumeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-roughcut-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @MainActor
    func testMotionLayerStoreInactiveWhenNilOrEmpty() {
        let store = RoughCutMotionLayerStore.shared
        store.clear()
        XCTAssertFalse(store.hasMotionLayer)
        XCTAssertNil(store.activeClip(at: 1.0))

        store.load(RoughCutMotionLayerContext(materialID: UUID(), clips: []))
        XCTAssertFalse(store.hasMotionLayer)
        XCTAssertNil(store.activeClip(at: 1.0))
        store.clear()
    }

    @MainActor
    func testReadOnlyMotionOverlayPrefersOverlayAndDispatchesRefinement() {
        let store = RoughCutMotionLayerStore.shared
        let shotClip = RoughCutMotionClip(
            id: "shot:Act1",
            targetID: "Act1",
            title: "Act1",
            kind: .shot,
            start: 0.0,
            end: 4.0,
            mediaPath: "/tmp/shot-act1.mp4"
        )
        let overlayClip = RoughCutMotionClip(
            id: "overlay:O2Run",
            targetID: "O2Run",
            title: "O2Run",
            kind: .overlay,
            start: 1.0,
            end: 3.0,
            mediaPath: "/tmp/overlay-o2run.mov",
            x: 56,
            y: 18,
            width: 1080,
            height: 120
        )

        var capturedClipID: String?
        var capturedInstruction: String?
        store.load(RoughCutMotionLayerContext(
            materialID: UUID(),
            clips: [shotClip, overlayClip],
            canvasWidth: 3024,
            canvasHeight: 1702
        ))
        store.onRequestRefinement = { clip, instruction in
            capturedClipID = clip.id
            capturedInstruction = instruction
        }
        defer { store.clear() }

        XCTAssertTrue(store.hasMotionLayer)
        XCTAssertEqual(store.activeClip(at: 0.5)?.id, "shot:Act1")
        XCTAssertEqual(store.activeClip(at: 2.0)?.id, "overlay:O2Run")

        // Preview visibility toggle hides overlay without mutating clips
        store.isLayerVisible = false
        XCTAssertNil(store.activeClip(at: 2.0))
        store.isLayerVisible = true
        XCTAssertEqual(store.activeClip(at: 2.0)?.id, "overlay:O2Run")

        // Submit AI refinement prompt for clicked clip
        store.promptClipID = overlayClip.id
        store.submitRefinement(for: overlayClip, instruction: "  放大标题字体  ")
        XCTAssertEqual(capturedClipID, "overlay:O2Run")
        XCTAssertEqual(capturedInstruction, "放大标题字体")
        XCTAssertEqual(store.refiningClipID, "overlay:O2Run")
        XCTAssertNil(store.promptClipID)

        // Hot-reload after AI refinement completes clears refining state
        store.reloadAfterRefinement(store.context)
        XCTAssertNil(store.refiningClipID)
        XCTAssertNil(store.refiningStatusMessage)
    }

    func testEnsurePackageWrapsLegacySourceAndIsIdempotent() throws {
        let sourceURL = tempDir.appendingPathComponent("source.mp4")
        let payload = Data("mock-mp4-bytes".utf8)
        try payload.write(to: sourceURL)

        let packageURL = tempDir.appendingPathComponent("roughcut.dogscproject", isDirectory: true)
        let created = try RoughCutPackageHelper.ensurePackage(
            at: packageURL,
            fallbackSourceURL: sourceURL,
            title: "测试素材"
        )
        XCTAssertEqual(created, packageURL)

        let projectJSON = packageURL.appendingPathComponent("project.json")
        let screenFile = packageURL.appendingPathComponent("media/screen-0001.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectJSON.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenFile.path))
        XCTAssertEqual(try Data(contentsOf: screenFile), payload)

        // Idempotent second call must not overwrite existing project.json
        let marker = Data("{\"custom\":true}".utf8)
        try marker.write(to: projectJSON)
        _ = try RoughCutPackageHelper.ensurePackage(
            at: packageURL,
            fallbackSourceURL: sourceURL,
            title: "新标题"
        )
        XCTAssertEqual(try Data(contentsOf: projectJSON), marker)
    }

    @MainActor
    func testBuildRoughCutMotionLayerOnlyActiveWhenMotionExists() throws {
        var project = VideoProject(name: "MotionLayerTest")
        let material = Material()
        project.materials = [material]

        let materialDir = ProjectLayout.materialDirectory(material, in: project)
        defer { try? FileManager.default.removeItem(at: ProjectLayout.directory(for: project)) }
        try FileManager.default.createDirectory(at: materialDir, withIntermediateDirectories: true)

        // Material without AI motion → must return nil
        XCTAssertNil(AppState.buildRoughCutMotionLayer(for: material, in: project))

        // Add motion-manifest.json + cached overlay file → returns active read-only layer
        let cacheDir = materialDir.appendingPathComponent(".sw-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cachedOverlay = cacheDir.appendingPathComponent("overlay-ov1-abc123.mov")
        try Data("mov".utf8).write(to: cachedOverlay)

        let manifest = MotionManifest(
            version: 1,
            fps: 30,
            width: 3024,
            height: 1702,
            shots: [],
            overlays: [
                .init(id: "ov1", composition: "KeyPointCallout", start: 2.0, end: 5.0, x: 56, y: 18, width: 980, height: 120, files: nil)
            ]
        )
        try JSONEncoder().encode(manifest).write(to: materialDir.appendingPathComponent(MotionManifest.filename))

        var motionMaterial = material
        motionMaterial.wantsMotion = true
        motionMaterial.motionState = .complete

        let ctx = AppState.buildRoughCutMotionLayer(for: motionMaterial, in: project)
        XCTAssertNotNil(ctx)
        XCTAssertEqual(ctx?.clips.count, 1)
        XCTAssertEqual(ctx?.clips.first?.id, "overlay:ov1")
        XCTAssertEqual(ctx?.clips.first?.targetID, "ov1")
        XCTAssertEqual(ctx?.clips.first?.kind, .overlay)
        XCTAssertEqual(ctx?.canvasWidth, 3024)
        XCTAssertEqual(ctx?.canvasHeight, 1702)
        XCTAssertEqual(ctx?.clips.first?.mediaPath, cachedOverlay.path)
    }
}
