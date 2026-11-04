import XCTest
@testable import SuperWorkspace

final class TimelineTests: XCTestCase {
    func testTimelineUsesDurationsAndClampsScrubbing() {
        var first = Material(), second = Material()
        first.duration = 3
        second.duration = 7
        let layout = AssemblyTimelineLayout(materials: [first, second])
        XCTAssertEqual(layout.clips.map(\.start), [0, 3])
        XCTAssertEqual(layout.clips.map(\.end), [3, 10])
        XCTAssertEqual(layout.time(at: 60, scale: 10), 6)
        XCTAssertEqual(layout.time(at: -10, scale: 10), 0)
        XCTAssertEqual(layout.time(at: 300, scale: 10), 10)
        XCTAssertEqual(layout.time(at: .nan, scale: 10), 0)
        XCTAssertEqual(AssemblyTimelineLayout.timecode(61.5), "01:01:15")
    }

    func testUnfinishedClipsHaveFiniteTimelineGeometry() {
        var unknown = Material(), invalid = Material()
        unknown.duration = .nan
        invalid.duration = -4
        let layout = AssemblyTimelineLayout(materials: [unknown, invalid])
        XCTAssertEqual(layout.duration, 0)
        XCTAssertTrue(layout.clips.allSatisfy { $0.start.isFinite && $0.duration == 0 })
        XCTAssertEqual(layout.time(at: 20, scale: 0), 0)
    }

    @MainActor
    func testDragReorderPersistsAndKeepsSubtitlesAttached() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["SUPERWORKSPACE_TEST_ROOT"]
        setenv("SUPERWORKSPACE_TEST_ROOT", root.path, 1)
        defer {
            if let previous { setenv("SUPERWORKSPACE_TEST_ROOT", previous, 1) } else { unsetenv("SUPERWORKSPACE_TEST_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        var project = VideoProject(name: "Timeline")
        project.materials = (1...3).map { number in
            var material = Material()
            material.duration = Double(number)
            material.exportState = .complete
            material.transcriptState = .complete
            material.subtitles = [.init(start: 0, end: 0.5, text: "Clip \(number)")]
            return material
        }
        let ids = project.materials.map(\.id)
        try ProjectLayout.save(project)
        let state = AppState()
        state.reorderMaterial(project.id, source: ids[0], target: ids[2], after: true)
        var result = try XCTUnwrap(ProjectLayout.loadAll().first)
        XCTAssertEqual(result.materials.map(\.id), [ids[1], ids[2], ids[0]])
        XCTAssertEqual(result.assembledSubtitles.map(\.start), [0, 2, 5])
        state.reorderMaterial(project.id, source: ids[0], target: ids[1], after: false)
        result = try XCTUnwrap(ProjectLayout.loadAll().first)
        XCTAssertEqual(result.materials.map(\.id), ids)
        XCTAssertEqual(result.assembledSubtitles.map(\.text), ["Clip 1", "Clip 2", "Clip 3"])
        state.reorderMaterial(project.id, source: ids[0], target: UUID(), after: false)
        XCTAssertEqual(ProjectLayout.loadAll().first?.materials.map(\.id), ids)
    }
}
