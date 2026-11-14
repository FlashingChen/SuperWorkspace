import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads the clip once and reports what the motion agent would otherwise probe for by hand:
/// where the A-Roll is, where the screen demo must stay untouched, where the picture cuts,
/// and which side of a mixed frame is free for an overlay.
///
/// It deliberately reports facts only. What may be animated where is decided by
/// `MotionPolicy`, so editorial rules can change without touching detection.
enum MotionPreanalysis {
    struct Keyframe: Sendable {
        let time: Double
        let data: Data
    }

    /// `aRoll`: presenter fills the frame. `screenDemo`: UI/desktop fills it.
    /// `mixed`: presenter and demo share the frame.
    struct Segment: Codable, Sendable, Equatable {
        let start: Double
        let end: Double
        let kind: String
        /// Side of the frame with no presenter, for mixed segments only (`left` / `right`).
        let safeSide: String?
    }

    struct Report: Sendable {
        let duration: Double
        let fps: Double
        let cuts: [Double]
        let segments: [Segment]
        let keyframes: [Keyframe]
        let hasAroll: Bool
        let hasMixed: Bool

        var overlayZones: [Segment] { segments.filter { $0.kind == "mixed" } }
        var aRollSegments: [Segment] { segments.filter { $0.kind == "aRoll" } }

        var json: Data? {
            let payload: [String: Any] = [
                "duration": duration, "fps": fps, "cuts": cuts,
                "hasARoll": hasAroll, "hasMixed": hasMixed,
                "segments": segments.map {
                    ["start": $0.start, "end": $0.end, "kind": $0.kind, "safeSide": $0.safeSide ?? ""]
                },
                "keyframes": keyframes.map { ["time": $0.time] },
            ]
            return try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        }

        static func label(_ kind: String) -> String {
            switch kind {
            case "aRoll": return "A-Roll（全屏人物）"
            case "screenDemo": return "录屏/演示"
            default: return "混合（人物+演示）"
            }
        }
    }

    /// Editorial rules: which picture may receive which effect, and how much may be drawn in
    /// total. Keeping this separate from detection means a new rule is a data change, not a
    /// rewrite of the analyser. Defaults match today's product behaviour.
    struct MotionPolicy: Sendable {
        /// Full-screen diagram inserts are only allowed over these picture kinds.
        var fullScreenKinds: Set<String> = ["aRoll"]
        /// Corner/overlay accents are allowed over these kinds.
        var overlayKinds: Set<String> = ["aRoll", "mixed"]
        /// Everything here must keep its original picture, motion and timing.
        var protectedKinds: Set<String> = ["screenDemo"]
        /// Coverage over scarcity: every suitable window may carry an insert.
        var maxFullScreenSegments = 99
        /// Generous ceiling; the caller scales it with the clip length.
        var maxOnScreenSeconds = 3600.0
        /// Delivery target shown to the agent; the hard budget stays in the runner.
        var targetMinutes = 0

        static let standard = MotionPolicy()

        func prompt(for report: Report) -> String {
            var lines: [String] = []
            lines.append("时长 \(String(format: "%.2f", report.duration))s，\(String(format: "%.0f", report.fps))fps。")
            if !report.cuts.isEmpty {
                lines.append("画面切点：" + report.cuts.map { String(format: "%.2f", $0) }.joined(separator: "、") + "s。")
            }
            lines.append("画面分区（自动检测，可直接采用）：" + report.segments.map {
                let side = $0.safeSide.map { "，空侧 \($0)" } ?? ""
                return "\(String(format: "%.2f", $0.start))–\(String(format: "%.2f", $0.end))s \(Report.label($0.kind))\(side)"
            }.joined(separator: "；") + "。")

            let blocked = report.segments.filter { protectedKinds.contains($0.kind) }
            if !blocked.isEmpty {
                lines.append("这些区间不得添加全屏动效，保持原画面与原时间关系：" +
                    blocked.map { "\(String(format: "%.2f", $0.start))–\(String(format: "%.2f", $0.end))s" }.joined(separator: "、") + "。")
            }
            let fullScreen = report.segments.filter { fullScreenKinds.contains($0.kind) }
            if !fullScreen.isEmpty {
                lines.append("可插入全屏图解的区间（A-Roll）：" +
                    fullScreen.map { "\(String(format: "%.2f", $0.start))–\(String(format: "%.2f", $0.end))s" }.joined(separator: "、") + "。")
            } else {
                lines.append("本片没有可插入全屏图解的 A-Roll，不要做全屏动效。")
            }
            let overlay = report.segments.filter { overlayKinds.contains($0.kind) }
            if !overlay.isEmpty {
                lines.append("可做局部叠加的区间：" + overlay.map {
                    let side = $0.safeSide.map { "（空侧 \($0)）" } ?? ""
                    return "\(String(format: "%.2f", $0.start))–\(String(format: "%.2f", $0.end))s\(side)"
                }.joined(separator: "、") + "。")
            }
            if maxFullScreenSegments < 90 {
                lines.append(String(format: "本次上限：全屏图解最多 %d 段、入画总时长不超过 %.0f 秒。",
                                   maxFullScreenSegments, maxOnScreenSeconds))
            } else {
                lines.append("覆盖要求：每个可动区间都要有动效，全屏图解与局部点缀可以同时用；不要只做开头几处。")
            }
            if targetMinutes > 0 {
                lines.append("目标 \(targetMinutes) 分钟内交付；时间紧时先停新增、保住已完成的镜头。")
            }
            return lines.joined(separator: "\n")
        }
    }

    private struct Sample {
        let time: Double
        let luma: [UInt8]
        let faceRatio: Double
        let faceCenterX: Double
    }

    static func analyze(source: URL, sampleInterval: Double = 0.5) async -> Report? {
        let asset = AVURLAsset(url: source)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0.2 else { return nil }
        let nominal = (try? await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)) ?? 30
        let fps = Double(nominal.isFinite && nominal > 0 ? nominal : 30)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)

        let step = max(0.2, sampleInterval)
        var times: [CMTime] = []
        var cursor = 0.0
        while cursor < duration {
            times.append(CMTime(seconds: min(cursor, max(0, duration - 0.05)), preferredTimescale: 600))
            cursor += step
        }

        var samples: [Sample] = []
        for await result in generator.images(for: times) {
            if Task.isCancelled { return nil }
            guard let image = try? result.image else { continue }
            let faces = detectFaces(image)
            samples.append(Sample(time: result.requestedTime.seconds,
                                  luma: thumbnail(image, width: 64, height: 36),
                                  faceRatio: faces.ratio, faceCenterX: faces.centerX))
        }
        guard samples.count >= 2 else { return nil }

        var cuts: [Double] = []
        for index in 1..<samples.count where meanDifference(samples[index - 1].luma, samples[index].luma) > 0.28 {
            if let last = cuts.last, samples[index].time - last < 0.6 { continue }
            cuts.append(samples[index].time)
        }

        // Segment runs first, so a side decision can use every sample inside the run.
        var runs: [(start: Double, end: Double, kind: String, side: String?)] = []
        var runStart = samples[0].time
        var runKind = classify(samples[0])
        for index in 1..<samples.count {
            let kind = classify(samples[index])
            if kind != runKind {
                runs.append((runStart, samples[index].time, runKind, nil))
                runStart = samples[index].time
                runKind = kind
            }
        }
        runs.append((runStart, duration, runKind, nil))
        runs = mergeRuns(runs, minDuration: 1.0)
        if runs.isEmpty { runs = [(0, duration, "screenDemo", nil)] }

        var segments: [Segment] = []
        for run in runs {
            var side: String?
            if run.kind == "mixed" {
                let inside = samples.filter { $0.time >= run.start - 0.01 && $0.time <= run.end + 0.01 }
                let center = inside.map(\.faceCenterX).reduce(0, +) / Double(max(inside.count, 1))
                side = center > 0.5 ? "left" : "right"
            }
            segments.append(Segment(start: run.start, end: run.end, kind: run.kind, safeSide: side))
        }

        var picks: [Double] = segments.map { ($0.start + $0.end) / 2 }
        if picks.isEmpty { picks = [duration / 2] }
        // One picture per segment is not enough when a clip is a single talking-head shot:
        // top up with evenly spaced samples so the agent always sees the whole timeline.
        let frameBudget = duration > 180 ? 24 : (duration > 60 ? 16 : 10)
        let minimum = duration > 60 ? 10 : 6
        if picks.count < minimum {
            let extra = minimum - picks.count
            for index in 0..<extra {
                let time = duration * (Double(index) + 0.5) / Double(extra)
                picks.append(time)
            }
            picks.sort()
        }
        if picks.count > frameBudget {
            let stride = Double(picks.count) / Double(frameBudget)
            picks = (0..<frameBudget).map { picks[min(picks.count - 1, Int(Double($0) * stride))] }
        }
        var keyframes: [Keyframe] = []
        for time in picks {
            let target = CMTime(seconds: min(time, max(0, duration - 0.05)), preferredTimescale: 600)
            if let image = try? await generator.image(at: target).image, let data = jpeg(image) {
                keyframes.append(Keyframe(time: time, data: data))
            }
        }
        return Report(duration: duration, fps: fps, cuts: cuts, segments: segments, keyframes: keyframes,
                      hasAroll: segments.contains { $0.kind == "aRoll" },
                      hasMixed: segments.contains { $0.kind == "mixed" })
    }

    // MARK: - classification

    /// A presenter filling the frame reads ~15%+ face area; a corner bubble stays small.
    private static func classify(_ sample: Sample) -> String {
        let centered = abs(sample.faceCenterX - 0.5) < 0.22
        if sample.faceRatio >= 0.10, centered { return "aRoll" }
        if sample.faceRatio >= 0.015 { return "mixed" }
        return "screenDemo"
    }

    private static func mergeRuns(_ runs: [(start: Double, end: Double, kind: String, side: String?)],
                                  minDuration: Double) -> [(start: Double, end: Double, kind: String, side: String?)] {
        guard runs.count > 1 else { return runs }
        var coalesced: [(start: Double, end: Double, kind: String, side: String?)] = []
        for run in runs {
            if let last = coalesced.last, last.kind == run.kind {
                coalesced[coalesced.count - 1] = (last.start, run.end, run.kind, nil)
            } else {
                coalesced.append(run)
            }
        }
        var result = coalesced
        var folded = true
        while folded, result.count > 1 {
            folded = false
            for index in result.indices where result[index].end - result[index].start < minDuration {
                if index == 0 {
                    result[1] = (result[0].start, result[1].end, result[1].kind, nil)
                    result.remove(at: 0)
                } else {
                    result[index - 1] = (result[index - 1].start, result[index].end, result[index - 1].kind, nil)
                    result.remove(at: index)
                }
                folded = true
                break
            }
            if folded {
                var rec: [(start: Double, end: Double, kind: String, side: String?)] = []
                for run in result {
                    if let last = rec.last, last.kind == run.kind {
                        rec[rec.count - 1] = (last.start, run.end, run.kind, nil)
                    } else { rec.append(run) }
                }
                result = rec
            }
        }
        return result
    }

    // MARK: - pixels

    private static func detectFaces(_ image: CGImage) -> (ratio: Double, centerX: Double) {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let faces = request.results, !faces.isEmpty else { return (0, 0.5) }
        var best = faces[0]
        for face in faces where face.boundingBox.width * face.boundingBox.height >
            best.boundingBox.width * best.boundingBox.height {
            best = face
        }
        let box = best.boundingBox
        return (Double(box.width * box.height), Double(box.midX))
    }

    private static func thumbnail(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return pixels }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var total = 0
        for index in a.indices { total += abs(Int(a[index]) - Int(b[index])) }
        return Double(total) / Double(a.count) / 255.0
    }

    private static func jpeg(_ image: CGImage, quality: Double = 0.6) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
