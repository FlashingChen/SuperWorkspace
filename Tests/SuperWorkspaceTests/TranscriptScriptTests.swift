import XCTest
@testable import SuperWorkspace

final class TranscriptScriptTests: XCTestCase {
    func testSimplifiedFixStaysSimplified() {
        let source = "我们参加了一个小红树的黑客松"
        let corrected = "我们参加了一个小红书的黑客松"
        XCTAssertEqual(TranscriptCorrection.matchScript(of: source, corrected: corrected), corrected)
    }

    func testTraditionalFixStaysTraditional() {
        let source = "也就是我們參加了一個小紅樹的黑客松"
        let corrected = "也就是我们参加了一个小红书的黑客松"
        let matched = TranscriptCorrection.matchScript(of: source, corrected: corrected)
        XCTAssertEqual(matched, source.replacingOccurrences(of: "樹", with: "書"))
    }

    func testEnglishIsUntouched() {
        let source = "choose the area of the server. It"
        XCTAssertEqual(TranscriptCorrection.matchScript(of: source, corrected: source), source)
    }

    func testMixedCorrectionNormalisesToSpeakerScript() {
        // A simplified fix inside a traditional sentence must not mix scripts.
        let source = "最近我获得一項獎項"
        let corrected = "最近我获得一项奖项"
        let matched = TranscriptCorrection.matchScript(of: source, corrected: corrected)
        XCTAssertEqual(matched, "最近我獲得一項獎項")
    }
}
