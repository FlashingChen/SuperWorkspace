import CoreImage
import Foundation
import RecorderCore
import RecorderKit
import XCTest
@testable import SuperWorkspace

final class UnifiedEditingPanelTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-unified-editor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testEnsurePackageCreatesValidNonDestructiveRoughCutPackage() throws {
        let sourceURL = tempDir.appendingPathComponent("source.mp4")
        let payload = Data("mock-video".utf8)
        try payload.write(to: sourceURL)

        let packageURL = tempDir.appendingPathComponent("roughcut.dogscproject", isDirectory: true)
        let loaded = try RoughCutPackageStore.ensurePackage(
            at: packageURL,
            fallbackSourceURL: sourceURL,
            title: "统一编辑片段"
        )
        XCTAssertEqual(loaded.project.title, "统一编辑片段")
        XCTAssertEqual(loaded.project.canvas.padding, 0)
        XCTAssertEqual(loaded.project.cursorStyle.assetID, .hidden)
        XCTAssertEqual(loaded.screenURL?.lastPathComponent, "screen-0001.mp4")

        // Mutate & save back, then reload
        var edited = loaded.project
        edited.canvas.padding = 64
        edited.canvas.cornerRadius = 18
        edited.canvas.backgroundSource = .pattern(.obsidianGrid)
        try RoughCutPackageStore.save(edited, at: packageURL)

        let reloaded = try XCTUnwrap(RoughCutPackageStore.load(at: packageURL))
        XCTAssertEqual(reloaded.project.canvas.padding, 64)
        XCTAssertEqual(reloaded.project.canvas.cornerRadius, 18)
        XCTAssertEqual(reloaded.project.canvas.backgroundSource, .pattern(.obsidianGrid))
    }

    func testRoughCutFrameCompositorRendersLiveFrame() {
        var project = RecorderProject()
        project.canvas.backgroundSource = .pattern(.obsidianGrid)
        project.canvas.padding = 48
        project.canvas.cornerRadius = 16
        project.canvas.shadowStrength = 0.5
        project.zoomAnimations = [
            ZoomAnimationClip(
                startTime: 0.5,
                endTime: 3.0,
                scale: 1.8,
                focus: NormalizedPoint(x: 0.5, y: 0.5),
                origin: .manual,
                easing: .spring
            )
        ]

        let compositor = RoughCutFrameCompositor(
            project: project,
            packageURL: nil,
            pointerEvents: [],
            outputDuration: 5.0
        )
        let input = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        let canvas = CGSize(width: 1280, height: 720)
        let output = compositor.render(screenFrame: input, cameraFrame: nil, at: 1.5, canvasSize: canvas)
        XCTAssertNotNil(output)
        XCTAssertEqual(output?.extent.width ?? 0, 1280, accuracy: 1.0)
        XCTAssertEqual(output?.extent.height ?? 0, 720, accuracy: 1.0)
    }

    func testAssemblyPreviewInputsInvalidatesOnRoughCutRevisionChange() {
        var project = VideoProject(name: "RevisionTest")
        var mat = Material()
        mat.duration = 10
        mat.exportState = .complete
        mat.roughCutRevision = 1
        project.materials = [mat]

        let sig1 = AssemblyPreviewInputs(project: project)
        project.materials[0].roughCutRevision = 2
        let sig2 = AssemblyPreviewInputs(project: project)
        XCTAssertNotEqual(sig1, sig2)
    }
}
