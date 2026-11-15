import Foundation

/// Chinese wording is always written in Simplified characters.
///
/// Speech recognition can return Traditional characters, or a single Simplified sentence with
/// Traditional words mixed in, and the models that rewrite a line can flip the script back.
/// Every Chinese line therefore passes through one normaliser instead of trusting the source.
enum TranscriptScript {
    /// Characters that are correct Simplified as they stand but that ICU rewrites when it reads
    /// them as Traditional (`乾隆`, `著名`, `於是`, `瞭望`). They are held aside during the
    /// conversion so a correct Simplified line is never corrupted.
    private static let ambiguousInSimplified: Set<Character> = ["乾", "著", "於", "瞭"]

    static func simplified(_ text: String) -> String {
        guard containsHan(text), !containsKanaOrHangul(text) else { return text }
        var placeholders: [Character: Character] = [:]
        var buffer = ""
        buffer.reserveCapacity(text.count)
        var next = 0xE000 as UInt32
        for character in text {
            guard ambiguousInSimplified.contains(character), let scalar = UnicodeScalar(next) else {
                buffer.append(character)
                continue
            }
            let placeholder = Character(scalar)
            placeholders[placeholder] = character
            buffer.append(placeholder)
            next += 1
        }
        guard let converted = buffer.applyingTransform(StringTransform("Hant-Hans"), reverse: false) else {
            return text
        }
        var output = ""
        output.reserveCapacity(converted.count)
        for character in converted {
            output.append(placeholders[character] ?? character)
        }
        return output
    }

    static func simplified(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.map { TranscriptSegment(start: $0.start, end: $0.end, text: simplified($0.text)) }
    }

    /// CJK Unified Ideographs plus Extension A; the blocks speech recognition produces for Chinese.
    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    /// Japanese and Korean share Han characters but not the Simplified convention, so their
    /// material is left untouched rather than rewritten as Chinese.
    private static func containsKanaOrHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)
                || (0x31F0...0x31FF).contains(scalar.value)
                || (0x1100...0x11FF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}
