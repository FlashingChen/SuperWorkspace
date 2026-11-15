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

    func testCorrectSimplifiedWordsThatLookTraditionalAreKept() {
        for line in ["乾隆皇帝", "著名作家", "显著提升", "瞭望台", "乾坤"] {
            XCTAssertEqual(TranscriptScript.simplified(line), line, "corrupted: \(line)")
        }
    }

    func testTraditionalWordsWithAnAmbiguousCharacterStillConvert() {
        XCTAssertEqual(TranscriptScript.simplified("於是我們出發了"), "于是我们出发了")
        XCTAssertEqual(TranscriptScript.simplified("著手處理這個問題"), "着手处理这个问题")
        XCTAssertEqual(TranscriptScript.simplified("乾杯"), "干杯")
        XCTAssertEqual(TranscriptScript.simplified("瞭解這件事的人"), "了解这件事的人")
    }

    func testJapaneseAndKoreanMaterialIsNotRewritten() {
        XCTAssertEqual(TranscriptScript.simplified("日本語の漢字を勉強します"), "日本語の漢字を勉強します")
        XCTAssertEqual(TranscriptScript.simplified("漢字 한자"), "漢字 한자")
        let lines = [TranscriptSegment(start: 0, end: 1, text: "東京大学"), .init(start: 1, end: 2, text: "の学生")]
        XCTAssertEqual(TranscriptScript.simplified(lines), lines)
    }

    func testChineseLineWithAQuotedKanaWordStillConverts() {
        XCTAssertEqual(TranscriptScript.simplified("他說「コーヒー」很好喝"), "他說「コーヒー」很好喝")
        XCTAssertEqual(TranscriptScript.simplifiedChinese("他說「コーヒー」很好喝"), "他说「コーヒー」很好喝")
    }

    func testWhisperLanguageDecidesWhetherTheScriptIsSimplified() {
        let chineseLog = "whisper_full_with_state: auto-detected language: zh (p = 0.99)"
        let japaneseLog = "whisper_full_with_state: auto-detected language: ja (p = 0.99)"
        XCTAssertTrue(TranscriptService.usesSimplifiedScript(language: "zh", whisperOutput: ""))
        XCTAssertTrue(TranscriptService.usesSimplifiedScript(language: "auto", whisperOutput: chineseLog))
        XCTAssertFalse(TranscriptService.usesSimplifiedScript(language: "auto", whisperOutput: japaneseLog))
        XCTAssertFalse(TranscriptService.usesSimplifiedScript(language: "ja", whisperOutput: chineseLog))
        XCTAssertEqual(TranscriptService.detectedLanguage(in: chineseLog), "zh")
        XCTAssertNil(TranscriptService.detectedLanguage(in: "no detection here"))
        XCTAssertEqual(TranscriptService.resolvedLanguage(configured: "auto", whisperOutput: japaneseLog), "ja")
        XCTAssertEqual(TranscriptService.resolvedLanguage(configured: "zh", whisperOutput: ""), "zh")
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
        let srt = SRTText.text(segments)
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:02,240"))
        XCTAssertTrue(srt.contains("00:00:02,240 --> 00:00:03,720"))
        XCTAssertEqual(TranscriptService.parseSRT(srt), segments)
    }

    func testSRTRoundsTheMillisecondCarryIntoTheNextSecond() {
        XCTAssertEqual(SRTText.time(2.9996), "00:00:03,000")
        XCTAssertEqual(SRTText.time(59.9999), "00:01:00,000")
        XCTAssertEqual(SRTText.time(0), "00:00:00,000")
        let boundary = [TranscriptSegment(start: 0, end: 2.9996, text: "边界")]
        let srt = SRTText.text(boundary)
        XCTAssertTrue(srt.contains("00:00:03,000"))
        XCTAssertEqual(TranscriptService.parseSRT(srt).first?.end, 3.0)
    }

    func testSRTSkipsEntriesThatCannotBeWritten() {
        let segments = [
            TranscriptSegment(start: 1, end: 1, text: "zero length"),
            TranscriptSegment(start: 0, end: .infinity, text: "infinite"),
            TranscriptSegment(start: 2, end: 3, text: "   "),
            TranscriptSegment(start: 4, end: 5, text: "kept"),
        ]
        let srt = SRTText.text(segments)
        XCTAssertEqual(srt, "1\n00:00:04,000 --> 00:00:05,000\nkept\n")
    }
}
