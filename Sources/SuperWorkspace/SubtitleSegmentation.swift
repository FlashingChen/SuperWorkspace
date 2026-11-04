import Foundation
import NaturalLanguage

enum SubtitleSegmentation {
    /// 36 display units: approximately 18 Chinese characters or 36 Latin letters.
    static let maximumWidth = 36
    static let version = 1

    static func sameSpeech(_ lhs: [TranscriptSegment], _ rhs: [TranscriptSegment]) -> Bool {
        lhs.map(\.text).joined().filter { !$0.isWhitespace } == rhs.map(\.text).joined().filter { !$0.isWhitespace }
    }

    static func width(_ text: String) -> Int {
        text.reduce(0) { $0 + units($1) }
    }

    private static func units(_ character: Character) -> Int {
        character.unicodeScalars.allSatisfy { $0.isASCII } ? 1 : 2
    }

    static func split(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.flatMap { segment -> [TranscriptSegment] in
            guard segment.start.isFinite, segment.end.isFinite, segment.end > segment.start else { return [] }
            let characters = Array(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !characters.isEmpty else { return [] }
            let tokenizer = NLTokenizer(unit: .word)
            let original = String(characters)
            tokenizer.string = original
            var wordBoundaries = Set<Int>()
            tokenizer.enumerateTokens(in: original.startIndex..<original.endIndex) { range, _ in
                wordBoundaries.insert(original.distance(from: original.startIndex, to: range.upperBound))
                return true
            }
            func isLatinToken(_ character: Character) -> Bool {
                character.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
            }
            var chunks: [(String, Int)] = []
            var start = 0
            var remainingWidth = width(original)
            while start < characters.count {
                let desiredParts = max(1, (remainingWidth + maximumWidth - 1) / maximumWidth)
                let target = (remainingWidth + desiredParts - 1) / desiredParts
                var end = start
                var consumed = 0
                var best: (end: Int, score: Int)?
                while end < characters.count, consumed + units(characters[end]) <= maximumWidth {
                    consumed += units(characters[end])
                    end += 1
                    if remainingWidth <= maximumWidth { continue }
                    if end < characters.count, isLatinToken(characters[end - 1]), isLatinToken(characters[end]) { continue }
                    let previous = characters[end - 1]
                    let penalty = "，。！？；：,.!?;:".contains(previous) ? -6
                        : previous.isWhitespace || wordBoundaries.contains(end) ? 6 : 20
                    let score = abs(consumed - target) + penalty
                    if best == nil || score < best!.score { best = (end, score) }
                }
                if end < characters.count, let best { end = best.end }
                let part = String(characters[start..<end])
                let count = width(part)
                chunks.append((part.trimmingCharacters(in: .whitespacesAndNewlines), count))
                remainingWidth -= count
                start = end
            }
            let total = chunks.reduce(0) { $0 + $1.1 }
            var consumed = 0
            return chunks.compactMap { text, count -> TranscriptSegment? in
                let start = segment.start + (segment.end - segment.start) * Double(consumed) / Double(total)
                consumed += count
                let end = consumed == total ? segment.end : segment.start + (segment.end - segment.start) * Double(consumed) / Double(total)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(start: start, end: end, text: text)
            }
        }
    }
}
