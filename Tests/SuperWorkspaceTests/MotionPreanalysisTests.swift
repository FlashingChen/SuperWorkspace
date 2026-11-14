import AVFoundation
import XCTest
@testable import SuperWorkspace

final class MotionPreanalysisTests: XCTestCase {
    /// Detection reports facts; policy decides what may be drawn where. These tests pin the
    /// contract so a later rule change (e.g. A-Roll only for full-screen inserts) stays a
    /// one-line edit instead of an analyser rewrite.
    func testPolicyGatesFullScreenInsertsToARoll() {
        let report = makeReport(segments: [
            .init(start: 0, end: 5, kind: "screenDemo", safeSide: nil),
            .init(start: 5, end: 9, kind: "aRoll", safeSide: nil),
        ])
        let prompt = MotionPreanalysis.MotionPolicy.standard.prompt(for: report)
        XCTAssertTrue(prompt.contains("可插入全屏图解的区间（A-Roll）：5.00–9.00s"), prompt)
        XCTAssertTrue(prompt.contains("这些区间不得添加全屏动效"), prompt)
        XCTAssertFalse(prompt.contains("可插入全屏图解的区间（A-Roll）：0.00"), prompt)
    }

    func testPolicyForbidsFullScreenWhenOnlyDemosExist() {
        let report = makeReport(segments: [.init(start: 0, end: 6, kind: "screenDemo", safeSide: nil)])
        let prompt = MotionPreanalysis.MotionPolicy.standard.prompt(for: report)
        XCTAssertTrue(prompt.contains("没有可插入全屏图解的 A-Roll"), prompt)
    }

    func testMixedSegmentsExposeSafeSideAndAllowOverlayOnly() {
        let report = makeReport(segments: [
            .init(start: 0, end: 4, kind: "mixed", safeSide: "left"),
            .init(start: 4, end: 8, kind: "aRoll", safeSide: nil),
        ])
        let prompt = MotionPreanalysis.MotionPolicy.standard.prompt(for: report)
        XCTAssertTrue(prompt.contains("混合（人物+演示），空侧 left"), prompt)
        XCTAssertTrue(prompt.contains("可做局部叠加的区间"), prompt)
    }

    func testPolicyAsksForFullCoverageByDefault() {
        let report = makeReport(segments: [.init(start: 0, end: 8, kind: "aRoll", safeSide: nil)])
        let prompt = MotionPreanalysis.MotionPolicy.standard.prompt(for: report)
        XCTAssertTrue(prompt.contains("覆盖要求：每个可动区间都要有动效"), prompt)
        XCTAssertTrue(prompt.contains("全屏图解与局部点缀可以同时用"), prompt)
    }

    func testPolicyStatesOptionalCapsWhenConfigured() {
        let report = makeReport(segments: [.init(start: 0, end: 8, kind: "aRoll", safeSide: nil)])
        var policy = MotionPreanalysis.MotionPolicy.standard
        policy.maxFullScreenSegments = 2
        policy.maxOnScreenSeconds = 9
        policy.targetMinutes = 12
        let prompt = policy.prompt(for: report)
        XCTAssertTrue(prompt.contains("本次上限：全屏图解最多 2 段、入画总时长不超过 9 秒"), prompt)
        XCTAssertTrue(prompt.contains("目标 12 分钟内交付"), prompt)
    }

    func testReportJSONCarriesKindsAndSides() throws {
        let report = makeReport(segments: [
            .init(start: 0, end: 2, kind: "mixed", safeSide: "right"),
            .init(start: 2, end: 6, kind: "aRoll", safeSide: nil),
        ])
        let data = try XCTUnwrap(report.json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["hasARoll"] as? Bool, true)
        XCTAssertEqual(object["hasMixed"] as? Bool, true)
        let segments = try XCTUnwrap(object["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.first?["kind"] as? String, "mixed")
        XCTAssertEqual(segments.first?["safeSide"] as? String, "right")
    }

    private func makeReport(segments: [MotionPreanalysis.Segment]) -> MotionPreanalysis.Report {
        MotionPreanalysis.Report(
            duration: segments.map(\.end).max() ?? 10, fps: 60, cuts: [], segments: segments, keyframes: [],
            hasAroll: segments.contains { $0.kind == "aRoll" },
            hasMixed: segments.contains { $0.kind == "mixed" })
    }
}
