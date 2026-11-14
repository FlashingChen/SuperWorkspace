import XCTest
@testable import SuperWorkspace

@MainActor
final class RecorderAIEditingTests: XCTestCase {
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

    private func fixture() -> (material: Material, image: ReferenceMedia, video: ReferenceMedia) {
        var material = Material()
        material.duration = 30
        material.exportState = .complete
        material.wantsAIEditing = true
        material.inserts = []
        let image = ReferenceMedia(name: "chart.png", kind: .image)
        var video = ReferenceMedia(name: "broll.mp4", kind: .video)
        video.duration = 10
        return (material, image, video)
    }

    func testMaterialRoundTripsChosenInsertsAndFlag() throws {
        var material = Material()
        material.duration = 12
        material.exportState = .complete
        material.wantsAIEditing = true
        let asset = ReferenceMedia(name: "chart.png", kind: .image)
        let insert = AIEditing.Insert(clipID: material.id, assetID: asset.id, start: 2, end: 4, assetStart: nil)
        material.inserts = [insert]

        let decoded = try JSONDecoder().decode(Material.self, from: JSONEncoder().encode(material))
        XCTAssertEqual(decoded, material)
        XCTAssertEqual(decoded.inserts, [insert])
        XCTAssertEqual(decoded.wantsAIEditing, true)
        XCTAssertNil(decoded.aiEditWarning)
    }

    func testMaterialWithoutAIEditingKeysStillDecodes() throws {
        var material = Material()
        material.duration = 5
        material.exportState = .complete

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(material)) as? [String: Any])
        XCTAssertNil(object["inserts"])
        XCTAssertNil(object["wantsAIEditing"])
        for key in ["inserts", "wantsAIEditing", "aiEditWarning"] { object.removeValue(forKey: key) }
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Material.self, from: legacy)
        XCTAssertNil(decoded.inserts)
        XCTAssertNil(decoded.wantsAIEditing)
        XCTAssertNil(decoded.aiEditWarning)
        XCTAssertEqual(decoded.duration, 5)
        XCTAssertEqual(decoded.exportState, .complete)
    }

    func testInsertJSONShapeIsStable() throws {
        let clipID = UUID(), assetID = UUID()
        let json = Data("""
        {"clipID":"\(clipID.uuidString)","assetID":"\(assetID.uuidString)","start":1.5,"end":3.5,"assetStart":0.25}
        """.utf8)
        let insert = try JSONDecoder().decode(AIEditing.Insert.self, from: json)
        XCTAssertEqual(insert.clipID, clipID)
        XCTAssertEqual(insert.assetID, assetID)
        XCTAssertEqual(insert.start, 1.5)
        XCTAssertEqual(insert.end, 3.5)
        XCTAssertEqual(insert.assetStart, 0.25)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(insert)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["clipID", "assetID", "start", "end", "assetStart"])
    }

    func testValidatedInsertsKeepsWhatFitsAndDropsTheRest() throws {
        let (material, image, video) = fixture()
        let clipStart = 10.0, clipEnd = 30.0
        let library = [image.id: image, video.id: video]
        let keepImage = AIEditing.Insert(clipID: material.id, assetID: image.id, start: 12, end: 14, assetStart: nil)
        let keepVideo = AIEditing.Insert(clipID: material.id, assetID: video.id, start: 16, end: 18, assetStart: 1)
        let keepLaterImage = AIEditing.Insert(clipID: material.id, assetID: image.id, start: 20, end: 22, assetStart: 0)
        let candidates = [
            // Order is irrelevant; results come back in timeline order.
            AIEditing.Insert(clipID: material.id, assetID: image.id, start: 29, end: 31, assetStart: nil),
            AIEditing.Insert(clipID: material.id, assetID: video.id, start: 27, end: 29, assetStart: 9.5),
            keepLaterImage,
            AIEditing.Insert(clipID: material.id, assetID: UUID(), start: 25, end: 27, assetStart: nil),
            AIEditing.Insert(clipID: material.id, assetID: video.id, start: 24, end: 26, assetStart: 9),
            AIEditing.Insert(clipID: material.id, assetID: image.id, start: 23, end: 25, assetStart: 1),
            AIEditing.Insert(clipID: material.id, assetID: image.id, start: 24, end: 24.02, assetStart: nil),
            AIEditing.Insert(clipID: material.id, assetID: image.id, start: 21, end: 23, assetStart: nil),
            keepVideo,
            AIEditing.Insert(clipID: material.id, assetID: image.id, start: 13, end: 15, assetStart: nil),
            keepImage,
            AIEditing.Insert(clipID: material.id, assetID: image.id, start: 9, end: 11, assetStart: nil),
            AIEditing.Insert(clipID: UUID(), assetID: image.id, start: 26, end: 28, assetStart: nil),
        ]

        let validated = AIEditing.validatedInserts(candidates, clipID: material.id,
                                                   clipStart: clipStart, clipEnd: clipEnd, library: library)
        XCTAssertEqual(validated, [keepImage, keepVideo, keepLaterImage])
    }

    func testValidatedInsertsRejectsMissingLibraryAndEmptyRange() {
        let (material, _, _) = fixture()
        let insert = AIEditing.Insert(clipID: material.id, assetID: UUID(), start: 12, end: 14, assetStart: nil)
        XCTAssertTrue(AIEditing.validatedInserts([insert], clipID: material.id,
                                                 clipStart: 0, clipEnd: 30, library: [:]).isEmpty)
        XCTAssertTrue(AIEditing.validatedInserts([insert], clipID: material.id,
                                                 clipStart: 5, clipEnd: 5, library: [:]).isEmpty)
    }

    func testProjectFileStoresInsertsOnTheMaterial() throws {
        try withStorage { _ in
            let (material, image, _) = fixture()
            let insert = AIEditing.Insert(clipID: material.id, assetID: image.id, start: 3, end: 5, assetStart: nil)
            var project = VideoProject(name: "Recorder AI")
            var stored = material
            stored.inserts = [insert]
            project.materials = [stored]
            try ProjectLayout.save(project)

            let raw = try String(contentsOf: ProjectLayout.url("project.json", for: project), encoding: .utf8)
            XCTAssertTrue(raw.contains("\"inserts\""))
            let loaded = try XCTUnwrap(ProjectLayout.loadAll().first { $0.id == project.id })
            XCTAssertEqual(loaded.materials.first?.inserts, [insert])
            XCTAssertEqual(loaded.materials.first?.wantsAIEditing, true)
        }
    }
}
