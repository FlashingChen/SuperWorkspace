import AVFoundation
import CoreGraphics
import Foundation
import XCTest
@testable import SuperWorkspace

final class AIPackagingAndMattingTests: XCTestCase {
    func testReferenceMediaRequiredAssignmentRoundTrip() throws {
        let videoA = UUID()
        let videoB = UUID()
        var media = ReferenceMedia(name: "demo.mp4", kind: .video, duration: 6.5)

        XCTAssertFalse(media.hasRequiredTargets)
        XCTAssertFalse(media.isRequired(for: videoA))

        media.setRequired(true, for: videoA)
        XCTAssertTrue(media.hasRequiredTargets)
        XCTAssertTrue(media.isRequired(for: videoA))
        XCTAssertFalse(media.isRequired(for: videoB))

        media.setRequired(true, for: videoB)
        XCTAssertEqual(media.requiredForMediaIDs, [videoA, videoB])

        let encoded = try JSONEncoder().encode(media)
        let decoded = try JSONDecoder().decode(ReferenceMedia.self, from: encoded)
        XCTAssertEqual(decoded, media)
        XCTAssertTrue(decoded.isRequired(for: videoA))
        XCTAssertTrue(decoded.isRequired(for: videoB))

        media.setRequired(false, for: videoA)
        media.setRequired(false, for: videoB)
        XCTAssertNil(media.requiredForMediaIDs)
        XCTAssertFalse(media.hasRequiredTargets)
    }

    func testMaterialPendingAIPackagingLabel() {
        var material = Material()
        material.wantsMotion = false
        material.motionState = .idle
        XCTAssertNil(material.motionLabel)

        material.wantsMotion = true
        material.motionState = .idle
        XCTAssertEqual(material.motionLabel, "待开始包装")

        material.motionState = .queued
        XCTAssertEqual(material.motionLabel, "AI 包装排队中")

        material.motionState = .running
        XCTAssertEqual(material.motionLabel, "AI 包装中")

        material.motionState = .complete
        XCTAssertEqual(material.motionLabel, "AI 包装已完成")

        material.motionState = .failed
        XCTAssertEqual(material.motionLabel, "AI 包装失败")
    }

    func testMotionManifestDecodesMatteFields() throws {
        let json = """
        {
          "version": 1,
          "fps": 60,
          "width": 1920,
          "height": 1080,
          "shots": [
            {
              "id": "Act1",
              "composition": "Act1",
              "start": 1.0,
              "end": 6.0,
              "files": ["src/Act1.tsx"],
              "matte": "personForeground",
              "personScale": 0.55,
              "personX": 860,
              "personY": 480
            }
          ],
          "overlays": [
            {
              "id": "HeroTitle",
              "composition": "HeroTitle",
              "start": 0.0,
              "end": 1.5,
              "x": 0,
              "y": 0,
              "width": 1920,
              "height": 1080,
              "matte": "behindPerson"
            }
          ]
        }
        """
        let manifest = try JSONDecoder().decode(MotionManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.shots.count, 1)
        XCTAssertEqual(manifest.shots[0].matte, "personForeground")
        XCTAssertEqual(manifest.shots[0].personScale, 0.55)
        XCTAssertEqual(manifest.shots[0].personX, 860)
        XCTAssertEqual(manifest.shots[0].personY, 480)
        XCTAssertEqual(manifest.overlays.count, 1)
        XCTAssertEqual(manifest.overlays[0].matte, "behindPerson")
    }

    func testCLIParseRecordStopLibraryFlag() throws {
        let req = try AutomationCLI.parseRequest(["record", "stop", "--library", "--raw", "--name", "settings-demo"])
        XCTAssertEqual(req.command, "record_stop")
        XCTAssertEqual(req.args["toLibrary"]?.boolValue, true)
        XCTAssertEqual(req.args["styled"]?.boolValue, false)
        XCTAssertEqual(req.args["name"]?.stringValue, "settings-demo")
    }

    func testPersonMattingServiceRejectsInvalidRange() async {
        let tmp = FileManager.default.temporaryDirectory
        do {
            _ = try await PersonMattingService.generateMask(
                sourceURL: tmp.appendingPathComponent("nonexistent.mp4"),
                start: 5.0,
                end: 2.0,
                outputURL: tmp.appendingPathComponent("out.mp4")
            )
            XCTFail("Expected invalidRange error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("抠像时间范围无效"))
        }
    }
}
