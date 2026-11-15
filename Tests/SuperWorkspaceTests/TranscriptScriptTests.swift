import XCTest
@testable import SuperWorkspace

final class TranscriptScriptTests: XCTestCase {
    func testSimplifiedFixStaysSimplified() {
        let source = "我们参加了一个小红树的黑客松"
        let corrected = "我们参加了一个小红书的黑客松"
        XCTAssertEqual(TranscriptCorrection.matchScript(of: source, corrected: corrected), corrected)
    }

    func testTraditionalSourceIsNormalisedToSimplified() {
        let source = "也就是我們參加了一個小紅樹的黑客松"
        let corrected = "也就是我们参加了一个小红书的黑客松"
        let matched = TranscriptCorrection.matchScript(of: source, corrected: corrected)
        XCTAssertEqual(matched, "也就是我们参加了一个小红书的黑客松")
    }

    func testTraditionalWordingInsideASimplifiedFixDoesNotSurvive() {
        let source = "最近我获得一項獎項"
        let corrected = "最近我獲得一項獎項"
        let matched = TranscriptCorrection.matchScript(of: source, corrected: corrected)
        XCTAssertEqual(matched, "最近我获得一项奖项")
    }

    func testEnglishIsUntouched() {
        let source = "choose the area of the server. It"
        XCTAssertEqual(TranscriptCorrection.matchScript(of: source, corrected: source), source)
        XCTAssertEqual(TranscriptScript.simplified(source), source)
    }

    func testRecognisedTraditionalLineIsRewrittenOnce() {
        let segments = [
            TranscriptSegment(start: 0, end: 2, text: "專案越做越大，AI 卻越來越蠢"),
            TranscriptSegment(start: 2, end: 4, text: "英文 Vibe Coding 保留"),
        ]
        let simplified = TranscriptScript.simplified(segments)
        XCTAssertEqual(simplified.map(\.text), ["专案越做越大，AI 却越来越蠢", "英文 Vibe Coding 保留"])
        XCTAssertEqual(simplified.map(\.start), segments.map(\.start))
        XCTAssertEqual(simplified.map(\.end), segments.map(\.end))
    }

    func testSRTKeepsTheSimplifiedWordingAndTiming() {
        let segments = [
            TranscriptSegment(start: 0, end: 2.24, text: "专案越做越大"),
            TranscriptSegment(start: 2.24, end: 3.72, text: "AI 却越来越蠢"),
        ]
        let srt = TranscriptService.srt(from: segments)
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:02,240"))
        XCTAssertTrue(srt.contains("00:00:02,240 --> 00:00:03,720"))
        XCTAssertEqual(TranscriptService.parseSRT(srt), segments)
    }
}
