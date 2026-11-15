import XCTest
@testable import SuperWorkspace

@MainActor
final class MotionBudgetTests: XCTestCase {
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

    private func fixture() throws -> (VideoProject, URL) {
        var project = VideoProject(name: "Budget")
        var material = Material()
        material.duration = 80
        material.exportState = .complete
        material.transcriptState = .complete
        material.wantsMotion = true
        material.motionState = .running
        project.materials = [material]
        try ProjectLayout.save(project)
        let directory = ProjectLayout.materialDirectory(material, in: project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (project, directory)
    }

    func testProjectRootUsesTheLiveTestOverride() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = getenv("SUPERWORKSPACE_TEST_ROOT").map { String(cString: $0) }
        setenv("SUPERWORKSPACE_TEST_ROOT", root.path, 1)
        defer {
            if let previous { setenv("SUPERWORKSPACE_TEST_ROOT", previous, 1) } else { unsetenv("SUPERWORKSPACE_TEST_ROOT") }
        }
        XCTAssertEqual(ProjectLayout.projectsRoot.standardizedFileURL.path, root.standardizedFileURL.path)
    }

    func testHoldReportsTheActualExtension() {
        let hold = MotionBudgetHold(mediaID: UUID(), limit: 40, maxTotal: 120, waitSeconds: 900)
        XCTAssertTrue(hold.canExtend)
        XCTAssertEqual(hold.extendMinutes, 30)

        let partial = MotionBudgetHold(mediaID: UUID(), limit: 110, maxTotal: 120, waitSeconds: 900)
        XCTAssertTrue(partial.canExtend)
        XCTAssertEqual(partial.extendMinutes, 10)

        let capped = MotionBudgetHold(mediaID: UUID(), limit: 120, maxTotal: 120, waitSeconds: 900)
        XCTAssertFalse(capped.canExtend)
        XCTAssertEqual(capped.extendMinutes, 0)
    }

    func testContinueWritesAnExtendRequest() async throws {
        try await withStorage { _ in
            let (project, _) = try fixture()
            let material = try XCTUnwrap(project.materials.first)
            let state = AppState()
            state.select(project.id)
            state.motionBudgetHolds[material.mediaID] = MotionBudgetHold(
                mediaID: material.mediaID, limit: 40, maxTotal: 120, waitSeconds: 900)

            state.continueMotion(project.id, material.id)

            let url = AppState.motionControlURL(material, in: project)
            let data = try Data(contentsOf: url)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["action"] as? String, "extend")
            XCTAssertEqual(json["minutes"] as? Int, 30)
            XCTAssertNotNil(json["id"] as? String)
            XCTAssertEqual(state.motionPhases[material.mediaID], "正在继续：再加 30 分钟")
        }
    }

    func testContinueUsesOnlyTheRemainingAllowance() async throws {
        try await withStorage { _ in
            let (project, _) = try fixture()
            let material = try XCTUnwrap(project.materials.first)
            let state = AppState()
            state.select(project.id)
            state.motionBudgetHolds[material.mediaID] = MotionBudgetHold(
                mediaID: material.mediaID, limit: 110, maxTotal: 120, waitSeconds: 900)

            state.continueMotion(project.id, material.id)

            let data = try Data(contentsOf: AppState.motionControlURL(material, in: project))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["minutes"] as? Int, 10)
            XCTAssertEqual(state.motionPhases[material.mediaID], "正在继续：再加 10 分钟")
        }
    }

    func testRemovingMaterialClearsTheWaitAndControlFile() async throws {
        try await withStorage { _ in
            let (project, _) = try fixture()
            let material = try XCTUnwrap(project.materials.first)
            let state = AppState()
            state.select(project.id)
            state.motionBudgetHolds[material.mediaID] = MotionBudgetHold(
                mediaID: material.mediaID, limit: 40, maxTotal: 120, waitSeconds: 900)
            let url = AppState.motionControlURL(material, in: project)
            try Data("{}".utf8).write(to: url)

            XCTAssertTrue(state.removeMaterial(project.id, material.id))
            XCTAssertNil(state.motionBudgetHolds[material.mediaID])
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testContinueAtTheOverallCapWritesNothing() async throws {
        try await withStorage { _ in
            let (project, _) = try fixture()
            let material = try XCTUnwrap(project.materials.first)
            let state = AppState()
            state.select(project.id)
            state.motionBudgetHolds[material.mediaID] = MotionBudgetHold(
                mediaID: material.mediaID, limit: 120, maxTotal: 120, waitSeconds: 900)

            state.continueMotion(project.id, material.id)

            let url = AppState.motionControlURL(material, in: project)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testCancellingClearsTheWaitAndControlFile() async throws {
        try await withStorage { _ in
            let (project, _) = try fixture()
            let material = try XCTUnwrap(project.materials.first)
            let state = AppState()
            state.select(project.id)
            state.motionBudgetHolds[material.mediaID] = MotionBudgetHold(
                mediaID: material.mediaID, limit: 40, maxTotal: 120, waitSeconds: 900)
            let url = AppState.motionControlURL(material, in: project)
            try Data("{}".utf8).write(to: url)

            state.cancelProcessing(project.id, material.id, motion: true)

            XCTAssertNil(state.motionBudgetHolds[material.mediaID])
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
