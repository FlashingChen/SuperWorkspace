import AVFoundation
import AppKit
import Foundation

/// Extracts a handful of source frames to pre-attach to the motion prompt, so the
/// agent starts from key visuals instead of spending turns re-extracting them.
enum MotionInput {
    struct Keyframe: Sendable {
        let time: Double
        let data: Data
    }

    /// Evenly spaced JPEG frames across the source video. Extraction is nonisolated
    /// async, so AVFoundation work never blocks the main actor. Returns [] on failure.
    static func keyframes(from url: URL, count: Int = 4, maxWidth: CGFloat = 900) async -> [Keyframe] {
        guard count > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        // Fast, approximate frames are enough for visual context.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        do {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0.2 else { return [] }
            let first = 0.1
            let last = duration - 0.1
            let span = max(0, last - first)
            var frames: [Keyframe] = []
            for index in 0..<count {
                let fraction = Double(index) / Double(max(count - 1, 1))
                let seconds = first + span * fraction
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                guard let image = try? await generator.image(at: time).image,
                      let jpeg = NSBitmapImageRep(cgImage: image).representation(
                        using: .jpeg, properties: [.compressionFactor: 0.6]) else { continue }
                frames.append(Keyframe(time: seconds, data: jpeg))
            }
            return frames
        } catch {
            return []
        }
    }
}
