import XCTest
@testable import SuperWorkspace

final class MotionLanguageTests: XCTestCase {
    private func detect(_ lines: [String]) -> MotionLanguage.Detection? {
        MotionLanguage.detect(from: lines.map { TranscriptSegment(start: 0, end: 1, text: $0) })
    }

    func testEnglishNarrationAsksForEnglishWording() throws {
        let detected = try XCTUnwrap(detect(["In part two we compare the agent and the harness", "The model only answers"]))
        XCTAssertEqual(detected.language, .english)
        XCTAssertGreaterThanOrEqual(detected.latinShare, 85)
        XCTAssertTrue(detected.language.instruction(latinShare: detected.latinShare).contains("一律用英文"))
    }

    func testChineseNarrationAsksForChineseWording() throws {
        let detected = try XCTUnwrap(detect(["我们今天讲一下这个智能体的原理", "它是怎么调用工具的"]))
        XCTAssertEqual(detected.language, .chinese)
        XCTAssertTrue(detected.language.instruction(latinShare: detected.latinShare).contains("用中文"))
    }

    func testMixedNarrationFollowsEachSentence() throws {
        let detected = try XCTUnwrap(detect(["这是 agent 和 harness 的区别，我们接下来看它的调用流程",
                                             "the model answers one turn"]))
        XCTAssertEqual(detected.language, .mixed)
        XCTAssertTrue(detected.language.instruction(latinShare: detected.latinShare).contains("跟随所讲段落"))
    }

    func testShortOrEmptyTranscriptHasNoVerdict() {
        XCTAssertNil(detect([]))
        XCTAssertNil(detect(["ok"]))
    }
}
