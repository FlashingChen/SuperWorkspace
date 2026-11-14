import Foundation

/// Manual caption edits. Every operation keeps the list ordered, inside the material and free of
/// overlaps; the caller decides whether a missing slot is reported to the editor.
enum SubtitleEditing {
    static let minimumDuration = 1.0 / 30
    /// A new caption starts at two seconds unless the free gap is shorter.
    static let defaultDuration = 2.0

    /// A free slot at `time`; nil when the playhead already sits on a caption or the gap is shorter
    /// than one frame.
    static func insertion(at time: Double, in material: Material) -> TranscriptSegment? {
        guard time.isFinite, material.sourceReady else { return nil }
        let lower = material.inPoint
        let upper = material.outPoint
        guard upper - lower >= minimumDuration - 0.000_001 else { return nil }
        let ordered = material.subtitles.sorted { $0.start < $1.start }
        var start = min(upper, max(lower, time))
        // The playhead is on or inside a caption: splitting it is the explicit edit, not this one.
        guard !ordered.contains(where: { $0.start <= start + 0.000_001 && $0.end > start + 0.000_001 })
        else { return nil }
        if let previousEnd = ordered.last(where: { $0.end <= start + 0.000_001 })?.end {
            start = max(start, previousEnd)
        }
        guard let next = ordered.first(where: { $0.start >= start - 0.000_001 }) else {
            guard upper - start >= minimumDuration - 0.000_001 else { return nil }
            return TranscriptSegment(start: start, end: min(upper, start + defaultDuration), text: "")
        }
        guard next.start - start >= minimumDuration - 0.000_001 else { return nil }
        return TranscriptSegment(start: start, end: min(next.start, start + defaultDuration), text: "")
    }

    /// Inserts a caption at its sorted position. Adjacent captions are allowed; overlapping ones
    /// are not.
    static func inserting(_ subtitle: TranscriptSegment, into subtitles: [TranscriptSegment]) -> [TranscriptSegment]? {
        guard subtitle.start.isFinite, subtitle.end.isFinite,
              subtitle.end - subtitle.start >= minimumDuration - 0.000_001 else { return nil }
        var result = subtitles
        let index = result.firstIndex { $0.start > subtitle.start } ?? result.count
        if index > 0, result[index - 1].end > subtitle.start + 0.000_001 { return nil }
        if index < result.count, result[index].start < subtitle.end - 0.000_001 { return nil }
        result.insert(subtitle, at: index)
        return result
    }

    static func removing(_ subtitles: [TranscriptSegment], at index: Int) -> [TranscriptSegment]? {
        guard subtitles.indices.contains(index) else { return nil }
        var result = subtitles
        result.remove(at: index)
        return result
    }

    /// Joins a caption with its successor. Text is joined without a separator unless both sides
    /// continue a Latin word.
    static func merging(_ subtitles: [TranscriptSegment], at index: Int) -> [TranscriptSegment]? {
        guard subtitles.indices.contains(index), index + 1 < subtitles.count else { return nil }
        let first = subtitles[index]
        let second = subtitles[index + 1]
        guard second.end > first.start else { return nil }
        let text = (first.text + joinSeparator(first.text, second.text) + second.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = subtitles
        result[index] = TranscriptSegment(start: first.start, end: max(first.end, second.end), text: text)
        result.remove(at: index + 1)
        return result
    }

    /// Splits a caption at a source time; the text follows the same time share.
    static func splitting(_ subtitles: [TranscriptSegment], at index: Int, time: Double) -> [TranscriptSegment]? {
        guard subtitles.indices.contains(index) else { return nil }
        let subtitle = subtitles[index]
        guard time.isFinite,
              time - subtitle.start >= minimumDuration - 0.000_001,
              subtitle.end - time >= minimumDuration - 0.000_001,
              subtitle.end > subtitle.start else { return nil }
        let fraction = (time - subtitle.start) / (subtitle.end - subtitle.start)
        guard let (left, right) = splitText(subtitle.text, at: fraction) else { return nil }
        var result = subtitles
        result[index] = TranscriptSegment(start: subtitle.start, end: time, text: left)
        result.insert(TranscriptSegment(start: time, end: subtitle.end, text: right), at: index + 1)
        return result
    }

    /// Splits text by time share without breaking a Latin word. Text with no split point (a single
    /// word) cannot be splitted; the editor keeps the line whole and asks the user to edit it.
    static func splitText(_ text: String, at fraction: Double) -> (left: String, right: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let characters = Array(trimmed)
        guard characters.count >= 2 else { return nil }
        let share = min(max(fraction, 0.05), 0.95)
        var cut = min(characters.count - 1, max(1, Int((Double(characters.count) * share).rounded())))
        func isLatinWord(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber)
        }
        if isLatinWord(characters[cut - 1]), isLatinWord(characters[cut]) {
            var best: (distance: Int, index: Int)?
            for candidate in max(1, cut - 12)...min(characters.count - 1, cut + 12)
            where !(isLatinWord(characters[candidate - 1]) && isLatinWord(characters[candidate])) {
                let distance = abs(candidate - cut)
                if best == nil || distance < best!.distance { best = (distance, candidate) }
            }
            guard let best else { return nil }
            cut = best.index
        }
        let left = String(characters[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(characters[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return (left, right)
    }

    static func joinSeparator(_ left: String, _ right: String) -> String {
        guard let last = left.last, let first = right.first,
              last.isASCII, first.isASCII,
              (last.isLetter || last.isNumber), (first.isLetter || first.isNumber) else { return "" }
        return " "
    }
}

/// Caption selection keys keep the material and the index in one string, so a selection survives
/// the inspector and the timeline being separate views.
enum SubtitleKey {
    static func make(_ materialID: UUID, _ index: Int) -> String { "\(materialID)-\(index)" }

    static func parse(_ key: String) -> (materialID: UUID, index: Int)? {
        guard let dash = key.lastIndex(of: "-"), dash > key.startIndex,
              let index = Int(key[key.index(after: dash)...]),
              let materialID = UUID(uuidString: String(key[..<dash])) else { return nil }
        return (materialID, index)
    }
}
