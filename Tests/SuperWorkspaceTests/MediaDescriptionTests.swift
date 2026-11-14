import XCTest
@testable import SuperWorkspace

final class MediaDescriptionTests: XCTestCase {
    func testNeedsDescriptionOnlyForBlankText() {
        var media = ReferenceMedia(name: "cover.png", kind: .image)
        XCTAssertTrue(MediaDescription.needsDescription(media))
        media.description = " \n\t "
        XCTAssertTrue(MediaDescription.needsDescription(media))
        media.description = "展示完成后的界面"
        XCTAssertFalse(MediaDescription.needsDescription(media))
    }

    func testCleanTakesFirstLineAndDropsWrappingQuotes() {
        let raw = "\n\n「五名年轻人在现场举牌合影。」\n补充：背景还有展板。"
        XCTAssertEqual(MediaDescription.clean(raw), "五名年轻人在现场举牌合影。")
        XCTAssertEqual(MediaDescription.clean("`展示完成后的界面`"), "展示完成后的界面")
        XCTAssertEqual(MediaDescription.clean("\"A laptop screen showing a dashboard.\""),
                       "A laptop screen showing a dashboard.")
    }

    func testCleanStripsLabelsAndListMarkers() {
        XCTAssertEqual(MediaDescription.clean("描述：结果页面的截图。"), "结果页面的截图。")
        XCTAssertEqual(MediaDescription.clean("- 结果页面的截图。"), "结果页面的截图。")
        XCTAssertEqual(MediaDescription.clean("  展示界面  \n"), "展示界面")
    }

    func testCleanCapsLongTextAtSixtyCharacters() {
        let raw = String(repeating: "画面", count: 80)
        let cleaned = MediaDescription.clean(raw)
        XCTAssertEqual(MediaDescription.maxCharacters, 60)
        XCTAssertEqual(cleaned?.count, MediaDescription.maxCharacters)
        XCTAssertEqual(cleaned, String(raw.prefix(MediaDescription.maxCharacters)))
    }

    func testCleanRejectsUnusableReplies() {
        XCTAssertNil(MediaDescription.clean(""))
        XCTAssertNil(MediaDescription.clean("   \n\t "))
        XCTAssertNil(MediaDescription.clean("抱歉，我无法判断这张图片。"))
        XCTAssertNil(MediaDescription.clean("Sorry, I can't help with that."))
        XCTAssertNil(MediaDescription.clean("——。"))
        XCTAssertNil(MediaDescription.clean(String(repeating: "长", count: MediaDescription.hardLimit + 1)))
        XCTAssertNil(MediaDescription.clean("了"))
    }

    func testPromptCarriesTheAssetName() {
        let media = ReferenceMedia(name: "cover.png", kind: .image)
        XCTAssertTrue(MediaDescription.prompt(for: media).contains("cover.png"))
        XCTAssertTrue(MediaDescription.prompt(for: ReferenceMedia(name: "clip.mov", kind: .video, duration: 4)).contains("clip.mov"))
    }

    func testDescribeReturnsNilInsteadOfThrowingForUnreadableMedia() async throws {
        let connection = try AIConnection(endpoint: AIEndpoint("https://example.com/v1"), model: "vision-model", key: "test")
        let media = ReferenceMedia(name: "missing.png", kind: .image)
        let description = await MediaDescription.describe(
            media, at: URL(fileURLWithPath: "/nonexistent/missing.png"), connection: connection)
        XCTAssertNil(description)
    }
}
