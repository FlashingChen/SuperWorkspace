import AVFoundation
import Foundation
import RecorderCore

/// Analyzes the recording's primary audio track (preferring microphone) to find
/// removable silence pauses for one-click rough-cut breath removal.
enum SilenceDetector {
    static let bucketDuration: TimeInterval = 0.05

    static func analyze(
        audioURL: URL,
        totalDuration: TimeInterval,
        options: SilenceCutPlanner.Options = .init()
    ) async throws -> [MediaTimeRange] {
        let asset = AVURLAsset(url: audioURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { return [] }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 16_000,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let samplesPerBucket = max(1, Int(16_000 * bucketDuration))
        var buckets: [Float] = []
        var sumSquares: Double = 0
        var countInBucket = 0

        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer, length >= MemoryLayout<Float>.size else { continue }
            let sampleCount = length / MemoryLayout<Float>.size
            let floats = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: sampleCount)
            for i in 0..<sampleCount {
                let value = Double(floats[i])
                sumSquares += value * value
                countInBucket += 1
                if countInBucket >= samplesPerBucket {
                    buckets.append(Float(sqrt(sumSquares / Double(countInBucket))))
                    sumSquares = 0
                    countInBucket = 0
                }
            }
        }
        if countInBucket > 0 {
            buckets.append(Float(sqrt(sumSquares / Double(countInBucket))))
        }

        return SilenceCutPlanner.detectSilentRanges(
            rmsBuckets: buckets,
            bucketDuration: bucketDuration,
            totalDuration: totalDuration,
            options: options
        )
    }
}
