import AVFoundation
import Foundation

/// 粗剪：trim（裁剪）、reorder（排序）、retime（变速），输出 source1。
/// 采用 ffmpeg filter_complex：每段独立裁剪/变速，再按顺序拼接。
enum RoughCutService {
    struct Segment: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var start: Double
        var end: Double
        /// 1.0 为原速；0.5 慢放一倍，2.0 快放一倍。
        var speed: Double = 1.0

        var duration: Double { max(0, (end - start) / max(speed, 0.01)) }
    }

    static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        return try? await asset.load(.duration).seconds
    }

    static func cut(
        input: URL,
        segments: [Segment],
        output: URL,
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        guard let ffmpeg = ToolPaths.ffmpeg else {
            throw ShellError.exitStatus(-1, "未找到 ffmpeg（brew install ffmpeg）")
        }
        let valid = segments.filter { $0.end - $0.start > 0.01 }
        guard !valid.isEmpty else {
            throw ShellError.exitStatus(-1, "没有有效的片段")
        }

        // 单段且原速、覆盖整片：直接重封装，避免无意义重编码。
        if valid.count == 1, abs(valid[0].speed - 1) < 0.001,
           let d = await duration(of: input),
           valid[0].start <= 0.05, valid[0].end >= d - 0.05 {
            try await Shell.run(ffmpeg, arguments: [
                "-y", "-i", input.path, "-c", "copy", output.path,
            ], onLine: onLine)
            return
        }

        var filters: [String] = []
        var labels: [String] = []
        for (i, seg) in valid.enumerated() {
            let speed = min(max(seg.speed, 0.25), 4.0)
            var chain = "[0:v]trim=start=\(seg.start):end=\(seg.end),setpts=PTS-STARTPTS"
            if abs(speed - 1) > 0.001 { chain += ",setpts=PTS/\(speed)" }
            filters.append(chain + "[v\(i)]")
            var audio = "[0:a]atrim=start=\(seg.start):end=\(seg.end),asetpts=PTS-STARTPTS"
            if abs(speed - 1) > 0.001 { audio += ",atempo=\(speed)" }
            filters.append(audio + "[a\(i)]")
            labels.append("[v\(i)][a\(i)]")
        }
        filters.append("\(labels.joined())concat=n=\(valid.count):v=1:a=1[v][a]")

        try await Shell.run(ffmpeg, arguments: [
            "-y", "-i", input.path,
            "-filter_complex", filters.joined(separator: ";"),
            "-map", "[v]", "-map", "[a]",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
            "-c:a", "aac", "-b:a", "192k",
            output.path,
        ], onLine: onLine)
    }
}
