import XCTest
@testable import RecorderCore

final class SilenceCutPlannerTests: XCTestCase {
    func testDetectsLongSilenceWithBreathPadding() {
        // 5.0 seconds at 50ms/bucket = 100 buckets:
        // [0.0..1.0s] speech, [1.0..2.5s] silence (1.5s), [2.5..5.0s] speech
        var buckets = Array(repeating: Float(0.2), count: 100)
        for i in 20..<50 { buckets[i] = 0.005 }

        let cuts = SilenceCutPlanner.detectSilentRanges(
            rmsBuckets: buckets,
            bucketDuration: 0.05,
            totalDuration: 5.0
        )
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].start, 1.14, accuracy: 0.01)
        XCTAssertEqual(cuts[0].end, 2.36, accuracy: 0.01)
    }

    func testIgnoresShortNaturalPauses() {
        // 0.4s pause is shorter than default 0.65s threshold
        var buckets = Array(repeating: Float(0.2), count: 60)
        for i in 20..<28 { buckets[i] = 0.002 }

        let cuts = SilenceCutPlanner.detectSilentRanges(
            rmsBuckets: buckets,
            bucketDuration: 0.05,
            totalDuration: 3.0
        )
        XCTAssertTrue(cuts.isEmpty)
    }

    func testPlanBuildsRetainedSegmentsAndProtectsAllSilentTrack() throws {
        let timeline = ProjectTimeline()
        let silence = [try XCTUnwrap(MediaTimeRange(start: 1.2, duration: 1.0))]
        let plan = SilenceCutPlanner.plan(removing: silence, from: timeline, fullSourceDuration: 5.0)
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.retainedSegments.count, 2)
        XCTAssertEqual(plan?.retainedSegments[0].sourceStart ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(plan?.retainedSegments[0].sourceDuration ?? -1, 1.2, accuracy: 0.001)
        XCTAssertEqual(plan?.retainedSegments[1].sourceStart ?? -1, 2.2, accuracy: 0.001)
        XCTAssertEqual(plan?.retainedSegments[1].sourceDuration ?? -1, 2.8, accuracy: 0.001)
        XCTAssertEqual(plan?.removedDuration ?? -1, 1.0, accuracy: 0.001)

        // All-silent clip must never produce an empty segment list
        let allSilent = [try XCTUnwrap(MediaTimeRange(start: 0, duration: 5.0))]
        XCTAssertNil(SilenceCutPlanner.plan(removing: allSilent, from: timeline, fullSourceDuration: 5.0))
    }
}
