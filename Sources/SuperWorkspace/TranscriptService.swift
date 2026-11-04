import AVFoundation
import Foundation

/// Part 3：本地 whisper 字幕识别，产出带时间轴的 metadata（不烧进画面）。
struct TranscriptSegment: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

/// whisper-cli 的 SRT 输出解析为 metadata。
enum TranscriptService {
    static func extractAudio(from video: URL, to wav: URL) async throws {
        guard let ffmpeg = ToolPaths.ffmpeg else {
            throw ShellError.exitStatus(-1, "未找到 ffmpeg")
        }
        try await Shell.run(ffmpeg, arguments: [
            "-y", "-i", video.path, "-vn", "-ac", "1", "-ar", "16000", wav.path,
        ])
    }

    static func transcribe(video: URL, directory dir: URL, whisperModel model: String, language: String,
                           correction: TranscriptCorrectionConfiguration? = nil) async throws -> TranscriptResult {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if try await AVURLAsset(url: video).loadTracks(withMediaType: .audio).isEmpty {
            try Data("[]".utf8).write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
            return TranscriptResult(segments: [], warning: nil)
        }
        guard let whisper = ToolPaths.whisperCLI else {
            throw ShellError.exitStatus(-1, "未找到 whisper-cli（brew install whisper-cpp）")
        }
        guard !model.isEmpty else {
            throw ShellError.exitStatus(-1, "未配置 whisper 模型文件（.bin），请在设置中指定")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("audio-16k.wav")
        try await extractAudio(from: video, to: wav)

        // whisper-cli 输出 srt 到 <outbase>.srt
        let outBase = dir.appendingPathComponent("transcript")
        _ = try await Shell.run(whisper, arguments: [
            "-m", model,
            "-f", wav.path,
            "-l", language,
            "-ml", "36", "-sow",
            "-osrt", "-of", outBase.path,
        ])
        let srtURL = dir.appendingPathComponent("transcript.srt")
        guard let srt = try? String(contentsOf: srtURL, encoding: .utf8) else {
            throw ShellError.exitStatus(-1, "whisper 未生成字幕文件")
        }
        let segments = parseSRT(srt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(segments).write(to: dir.appendingPathComponent("transcript-raw.json"), options: .atomic)
        let result: TranscriptResult
        if let correction {
            result = try await TranscriptCorrection.apply(segments, video: video, directory: dir, configuration: correction)
        } else {
            result = TranscriptResult(segments: segments, warning: nil)
        }
        let final = SubtitleSegmentation.split(result.segments)
        let metadata = try encoder.encode(final)
        try metadata.write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        return TranscriptResult(segments: final, warning: result.warning)
    }

    static func parseSRT(_ srt: String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var start = 0.0, end = 0.0
        var lines: [String] = []
        func flush() {
            let text = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if end > 0 || !text.isEmpty {
                segments.append(TranscriptSegment(start: start, end: end, text: text))
            }
            lines = []
        }
        for raw in srt.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                start = 0; end = 0
                continue
            }
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                start = parseTime(parts[0]) ?? 0
                end = parseTime(parts.count > 1 ? parts[1] : "") ?? 0
                continue
            }
            if line.allSatisfy(\.isNumber), end == 0, lines.isEmpty { continue } // 序号
            lines.append(line)
        }
        flush()
        return segments
    }

    /// 解析 "HH:MM:SS,mmm" 或 "HH:MM:SS.mmm"。
    static func parseTime(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":").map(String.init)
        guard parts.count == 3 else { return nil }
        guard let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }
}
