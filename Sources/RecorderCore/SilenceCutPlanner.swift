import Foundation

/// Pure silence-cutting planner for rough-cut breath/pause removal.
/// Operates on normalized RMS energy buckets and produces retained primary
/// recording segments without modifying audio or video files on disk.
public enum SilenceCutPlanner {
    public struct Options: Equatable, Sendable {
        public var amplitudeThreshold: Float
        public var minimumSilenceDuration: TimeInterval
        public var breathPadding: TimeInterval
        public var minimumSegmentDuration: TimeInterval

        public init(
            amplitudeThreshold: Float = 0.03,
            minimumSilenceDuration: TimeInterval = 0.65,
            breathPadding: TimeInterval = 0.14,
            minimumSegmentDuration: TimeInterval = 0.15
        ) {
            self.amplitudeThreshold = amplitudeThreshold
            self.minimumSilenceDuration = minimumSilenceDuration
            self.breathPadding = breathPadding
            self.minimumSegmentDuration = minimumSegmentDuration
        }
    }

    public struct Plan: Equatable, Sendable {
        public let removedRanges: [MediaTimeRange]
        public let retainedSegments: [RecordingSegment]
        public let removedDuration: TimeInterval
    }

    /// Detects removable silence ranges from uniform-step RMS energy buckets.
    /// Keeps `breathPadding` on each side of speech so cuts never clip words.
    public static func detectSilentRanges(
        rmsBuckets: [Float],
        bucketDuration: TimeInterval,
        totalDuration: TimeInterval,
        options: Options = Options()
    ) -> [MediaTimeRange] {
        guard !rmsBuckets.isEmpty, bucketDuration > 0, totalDuration > 0 else { return [] }
        var silentRuns: [(start: TimeInterval, end: TimeInterval)] = []
        var runStart: Int?
        for (index, level) in rmsBuckets.enumerated() {
            if level < options.amplitudeThreshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                silentRuns.append((Double(start) * bucketDuration, min(totalDuration, Double(index) * bucketDuration)))
                runStart = nil
            }
        }
        if let start = runStart {
            silentRuns.append((Double(start) * bucketDuration, totalDuration))
        }

        var removable: [MediaTimeRange] = []
        for run in silentRuns {
            let duration = run.end - run.start
            guard duration >= options.minimumSilenceDuration else { continue }
            let cutStart = run.start == 0 ? 0 : run.start + options.breathPadding
            let cutEnd = run.end >= totalDuration ? totalDuration : run.end - options.breathPadding
            let cutDuration = cutEnd - cutStart
            guard cutDuration >= options.minimumSegmentDuration,
                  let range = MediaTimeRange(start: cutStart, duration: cutDuration) else { continue }
            removable.append(range)
        }
        return removable
    }

    /// Subtracts `silentRanges` from the current timeline's primary segments.
    /// Returns `nil` if no silence can be removed or if removal would leave no segments.
    public static func plan(
        removing silentRanges: [MediaTimeRange],
        from timeline: ProjectTimeline,
        fullSourceDuration: TimeInterval,
        options: Options = Options()
    ) -> Plan? {
        guard !silentRanges.isEmpty, fullSourceDuration > 0 else { return nil }
        let currentSegments: [RecordingSegment]
        switch timeline.sourceSequence {
        case .fullRecording:
            currentSegments = [RecordingSegment(id: TimelineMap.fullRecordingSegmentID, sourceStart: 0, sourceDuration: fullSourceDuration)]
        case let .edited(segments):
            currentSegments = segments
        }
        guard !currentSegments.isEmpty else { return nil }

        let sortedCuts = silentRanges.sorted { $0.start < $1.start }
        var retained: [RecordingSegment] = []
        var removedDuration: TimeInterval = 0
        var actuallyRemoved: [MediaTimeRange] = []

        for segment in currentSegments {
            var cursor = segment.sourceStart
            let segEnd = segment.sourceEnd
            for cut in sortedCuts {
                if cut.end <= cursor { continue }
                if cut.start >= segEnd { break }
                let overlapStart = max(cursor, cut.start)
                let overlapEnd = min(segEnd, cut.end)
                if overlapEnd - overlapStart < options.minimumSegmentDuration { continue }
                if overlapStart - cursor >= options.minimumSegmentDuration {
                    retained.append(RecordingSegment(
                        sourceStart: cursor,
                        sourceDuration: overlapStart - cursor,
                        playbackRate: segment.playbackRate
                    ))
                }
                if let range = MediaTimeRange(start: overlapStart, duration: overlapEnd - overlapStart) {
                    actuallyRemoved.append(range)
                }
                removedDuration += (overlapEnd - overlapStart)
                cursor = overlapEnd
            }
            if segEnd - cursor >= options.minimumSegmentDuration {
                retained.append(RecordingSegment(
                    sourceStart: cursor,
                    sourceDuration: segEnd - cursor,
                    playbackRate: segment.playbackRate
                ))
            }
        }

        guard !actuallyRemoved.isEmpty, !retained.isEmpty else { return nil }
        return Plan(removedRanges: actuallyRemoved, retainedSegments: retained, removedDuration: removedDuration)
    }
}
