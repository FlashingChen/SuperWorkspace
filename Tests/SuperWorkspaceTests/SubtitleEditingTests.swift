import XCTest
@testable import SuperWorkspace

final class SubtitleEditingTests: XCTestCase {
    private func material(_ subtitles: [TranscriptSegment], from start: Double = 0, to end: Double = 10) -> Material {
        var material = Material()
        material.duration = end
        material.exportState = .complete
        material.transcriptState = .complete
        material.subtitles = subtitles
        material.trimStart = start
        material.trimEnd = end
        return material
    }

    func testInsertionFindsTheGapAroundThePlayhead() {
        let material = material([.init(start: 1, end: 2, text: "A"), .init(start: 4, end: 6, text: "B")])
        let afterFirst = SubtitleEditing.insertion(at: 2.5, in: material)
        XCTAssertEqual(afterFirst?.start, 2.5)
        XCTAssertEqual(afterFirst?.end, 4)
        XCTAssertNil(SubtitleEditing.insertion(at: 1.5, in: material))
        XCTAssertNil(SubtitleEditing.insertion(at: 1, in: material))
        XCTAssertEqual(SubtitleEditing.insertion(at: 2, in: material)?.start, 2)
        XCTAssertEqual(SubtitleEditing.insertion(at: 8, in: material)?.end, 10)
        XCTAssertNil(SubtitleEditing.insertion(at: 9.99, in: material))
    }

    func testInsertionRespectsTrimmedClipBounds() {
        let material = material([.init(start: 0.2, end: 0.6, text: "head")], from: 0.5, to: 8)
        XCTAssertNil(SubtitleEditing.insertion(at: 0.5, in: material))
        XCTAssertNil(SubtitleEditing.insertion(at: 0.3, in: material))
        let slot = SubtitleEditing.insertion(at: 1, in: material)
        XCTAssertEqual(slot?.start, 1)
        XCTAssertEqual(slot?.end, 3)
    }

    func testInsertingKeepsOrderAndRejectsOverlap() {
        let base = [TranscriptSegment(start: 1, end: 2, text: "A")]
        XCTAssertNil(SubtitleEditing.inserting(.init(start: 1.5, end: 2.5, text: "B"), into: base))
        XCTAssertNil(SubtitleEditing.inserting(.init(start: 3, end: 3, text: "B"), into: base))
        XCTAssertEqual(SubtitleEditing.inserting(.init(start: 0, end: 1, text: "B"), into: base)?.map(\.text), ["B", "A"])
        XCTAssertEqual(SubtitleEditing.inserting(.init(start: 2, end: 3, text: "B"), into: base)?.map(\.text), ["A", "B"])
    }

    func testMergeJoinsChineseWithoutSpacesAndLatinWithOne() {
        let cjk: [TranscriptSegment] = [.init(start: 0, end: 1, text: "你好"), .init(start: 1, end: 2, text: "世界")]
        XCTAssertEqual(SubtitleEditing.merging(cjk, at: 0)?.first?.text, "你好世界")
        XCTAssertEqual(SubtitleEditing.merging(cjk, at: 0)?.count, 1)
        let latin: [TranscriptSegment] = [.init(start: 0, end: 1, text: "Hello"), .init(start: 1, end: 2, text: "world")]
        XCTAssertEqual(SubtitleEditing.merging(latin, at: 0)?.first?.text, "Hello world")
        XCTAssertNil(SubtitleEditing.merging(latin, at: 1))
    }

    func testSplitTextUsesTimeShareAndKeepsLatinWordsWhole() {
        let chinese = SubtitleEditing.splitText("我们开始录制", at: 0.5)
        XCTAssertEqual(chinese?.left, "我们开")
        XCTAssertEqual(chinese?.right, "始录制")
        let english = SubtitleEditing.splitText("First Second Third", at: 0.4)
        XCTAssertEqual(english?.left, "First")
        XCTAssertEqual(english?.right, "Second Third")
        XCTAssertNil(SubtitleEditing.splitText("Hello", at: 0.5))
        XCTAssertNil(SubtitleEditing.splitText("A", at: 0.5))
    }

    func testSplittingKeepsTotalTextAndTime() {
        let subtitles = [TranscriptSegment(start: 1, end: 3, text: "我们开始录制")]
        let split = SubtitleEditing.splitting(subtitles, at: 0, time: 2)
        XCTAssertEqual(split?.count, 2)
        XCTAssertEqual(split?[0].start, 1)
        XCTAssertEqual(split?[0].end, 2)
        XCTAssertEqual(split?[1].start, 2)
        XCTAssertEqual(split?[1].end, 3)
        XCTAssertEqual((split?[0].text ?? "") + (split?[1].text ?? ""), "我们开始录制")
        XCTAssertNil(SubtitleEditing.splitting(subtitles, at: 0, time: 1))
        XCTAssertNil(SubtitleEditing.splitting(subtitles, at: 0, time: 1.02))
    }

    func testSelectionKeysRoundTrip() {
        let id = UUID()
        let key = SubtitleKey.make(id, 7)
        let parsed = SubtitleKey.parse(key)
        XCTAssertEqual(parsed?.materialID, id)
        XCTAssertEqual(parsed?.index, 7)
        XCTAssertNil(SubtitleKey.parse("not-a-subtitle"))
    }
}
