import Foundation

/// Chinese wording is always written in Simplified characters.
///
/// Speech recognition can return Traditional characters, or a single Simplified sentence with
/// Traditional words mixed in, and the models that rewrite a line can flip the script back.
/// Every Chinese line therefore passes through one normaliser instead of trusting the source.
enum TranscriptScript {
    /// Words that are already correct Simplified but that ICU rewrites when it reads the
    /// character as Traditional. They are held aside during conversion so a correct Simplified
    /// line is never corrupted; ordinary Traditional text (`於是`, `著手`, `乾杯`) still converts.
    private static let protectedWords = [
        "瞭望台", "瞭望", "乾隆", "乾坤", "乾县", "乾陵",
        "显著", "著名", "著作", "著述", "著者", "著书", "著录",
        "土著", "编著", "论著", "巨著", "原著", "名著",
    ].map(Array.init).sorted { $0.count > $1.count }

    static func simplified(_ text: String) -> String {
        guard !containsKanaOrHangul(text) else { return text }
        return simplifiedChinese(text)
    }

    static func simplifiedChinese(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.map { TranscriptSegment(start: $0.start, end: $0.end, text: simplifiedChinese($0.text)) }
    }

    /// Conversion for material the caller already knows is Chinese, so a quoted kana word in a
    /// Chinese line does not stop the rest of the line from being normalised.
    static func simplifiedChinese(_ text: String) -> String {
        guard containsHan(text) else { return text }
        let characters = Array(text)
        var placeholders: [Character: String] = [:]
        var used = Set(text.unicodeScalars.map(\.value))
        var buffer = ""
        buffer.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            if let word = protectedWords.first(where: { matches($0, in: characters, at: index) }),
               let placeholder = nextPlaceholder(&used) {
                placeholders[placeholder] = String(word)
                buffer.append(placeholder)
                index += word.count
            } else {
                buffer.append(characters[index])
                index += 1
            }
        }
        guard let converted = buffer.applyingTransform(StringTransform("Hant-Hans"), reverse: false) else {
            return text
        }
        var output = ""
        output.reserveCapacity(converted.count)
        for character in converted {
            output.append(placeholders[character] ?? String(character))
        }
        return output
    }

    static func simplified(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        // A material with kana or hangul is Japanese or Korean; its Han characters do not follow
        // the Simplified convention even when a single line has none of those scripts.
        let joined = segments.map(\.text).joined(separator: " ")
        guard !containsKanaOrHangul(joined) else { return segments }
        return segments.map { TranscriptSegment(start: $0.start, end: $0.end, text: simplifiedChinese($0.text)) }
    }

    /// CJK Unified Ideographs plus Extension A; the blocks speech recognition produces for Chinese.
    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    /// Japanese and Korean share Han characters but not the Simplified convention.
    static func containsKanaOrHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)
                || (0x31F0...0x31FF).contains(scalar.value)
                || (0x1100...0x11FF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    private static func matches(_ word: [Character], in characters: [Character], at index: Int) -> Bool {
        guard index + word.count <= characters.count else { return false }
        return Array(characters[index..<(index + word.count)]) == word
    }

    /// A private-use marker the input does not already contain, so no character can be swapped
    /// for a protected word by accident.
    private static func nextPlaceholder(_ used: inout Set<UInt32>) -> Character? {
        var value: UInt32 = 0xE000
        while value <= 0xF8FF {
            if !used.contains(value), let scalar = UnicodeScalar(value) {
                used.insert(value)
                return Character(scalar)
            }
            value += 1
        }
        return nil
    }
}
