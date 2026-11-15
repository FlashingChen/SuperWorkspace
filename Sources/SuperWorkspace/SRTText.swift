import Foundation

/// SRT serialisation shared by the transcript files and the exported sidecar, so both round the
/// millisecond carry the same way and both drop entries that cannot be written.
enum SRTText {
    static func text(_ subtitles: [TranscriptSegment]) -> String {
        let entries = subtitles.filter {
            $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return entries.enumerated().map { index, subtitle in
            "\(index + 1)\n\(time(subtitle.start)) --> \(time(subtitle.end))\n"
                + "\(subtitle.text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n\n", with: "\n"))\n"
        }.joined(separator: "\n")
    }

    /// Rounds the whole duration to milliseconds first, so a boundary like 2.9996 s becomes
    /// `00:00:03,000` instead of the invalid `00:00:02,1000`.
    static func time(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000, (milliseconds / 60_000) % 60,
                      (milliseconds / 1000) % 60, milliseconds % 1000)
    }
}
