import XCTest
@testable import RecorderKit

final class RecorderExportContinuityTests: XCTestCase {
    func testScreenCutKeepsNearestFrameBeforeSlice() {
        XCTAssertEqual(ExportScreenCutContinuity.frame(previous: 10, lastFrameBeforeSlice: 20), 20)
    }

    func testScreenCutFallsBackToPreviousFrameWhenNothingPrecedesSlice() {
        XCTAssertEqual(ExportScreenCutContinuity.frame(previous: 10, lastFrameBeforeSlice: nil), 10)
    }

    func testScreenCutWithoutAnyFrameStaysEmpty() {
        XCTAssertNil(ExportScreenCutContinuity.frame(previous: Int?.none, lastFrameBeforeSlice: Int?.none))
    }
}
