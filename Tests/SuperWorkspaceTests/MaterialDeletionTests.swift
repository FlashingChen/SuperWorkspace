import XCTest
@testable import SuperWorkspace

@MainActor
final class MaterialDeletionTests: XCTestCase {
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

    func testRemovalPersistsAndPreservesFilesAndOtherProjects() throws {
        try withStorage { _ in
            var project = VideoProject(name: "Delete fixture")
            var first = Material(), second = Material()
            first.exportState = .complete
            first.duration = 2
            first.subtitles = [.init(start: 0, end: 1, text: "First")]
            second.exportState = .complete
            second.duration = 3
            second.subtitles = [.init(start: 0, end: 1, text: "Second")]
            project.materials = [first, second]
            var other = VideoProject(name: "Other fixture")
            other.materials = [second]
            try ProjectLayout.save(project)
            try ProjectLayout.save(other)
            let source = ProjectLayout.source(first, in: project)
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic fixture".utf8).write(to: source)
            let state = AppState()
            XCTAssertTrue(state.removeMaterial(project.id, first.id))
            let restored = try XCTUnwrap(ProjectLayout.loadAll().first { $0.id == project.id })
            XCTAssertEqual(restored.materials.map(\.id), [second.id])
            XCTAssertEqual(restored.assembledSubtitles.map(\.text), ["Second"])
            XCTAssertEqual(restored.assembledSubtitles.first?.start, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(ProjectLayout.loadAll().first { $0.id == other.id }?.materials.count, 1)
            state.enqueueMotion(project.id, first.id)
            XCTAssertEqual(ProjectLayout.loadAll().first { $0.id == project.id }, restored)
            XCTAssertTrue(state.removeMaterial(project.id, second.id))
            XCTAssertTrue(ProjectLayout.loadAll().first { $0.id == project.id }!.materials.isEmpty)
            XCTAssertFalse(state.removeMaterial(project.id, second.id))
        }
    }

    func testRunningExportsCannotBeRemoved() throws {
        try withStorage { _ in
            var project = VideoProject(name: "Export fixture")
            var material = Material()
            material.exportState = .complete
            project.materials = [material]
            try ProjectLayout.save(project)
            let state = AppState()
            state.exportingProjects.insert(project.id)
            XCTAssertFalse(state.removeMaterial(project.id, material.id))
            state.exportingProjects.remove(project.id)
            state.updateProject(project.id) { $0.materials[0].exportState = .running }
            XCTAssertFalse(state.removeMaterial(project.id, material.id))
            XCTAssertEqual(ProjectLayout.loadAll().first?.materials.count, 1)
        }
    }

    func testFailedSaveKeepsMaterialInMemory() throws {
        try withStorage { _ in
            var project = VideoProject(name: "Save failure fixture")
            var material = Material()
            material.exportState = .complete
            project.materials = [material]
            try ProjectLayout.save(project)
            let state = AppState()
            let metadata = ProjectLayout.url("project.json", for: project)
            try FileManager.default.removeItem(at: metadata)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
            XCTAssertFalse(state.removeMaterial(project.id, material.id))
            XCTAssertEqual(state.projects.first?.materials.map(\.id), [material.id])
            XCTAssertNotNil(state.error)
        }
    }
}
