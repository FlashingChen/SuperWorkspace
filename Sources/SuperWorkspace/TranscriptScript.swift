import Foundation

/// Chinese wording is always written in Simplified characters.
///
/// Speech recognition can return Traditional characters, or a single Simplified sentence with
/// Traditional words mixed in, and the models that rewrite a line can flip the script back.
/// Every Chinese line therefore passes through one normaliser instead of trusting the source.
enum TranscriptScript {
    static func simplified(_ text: String) -> String {
        guard containsHan(text) else { return text }
        return text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }

    static func simplified(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.map { TranscriptSegment(start: $0.start, end: $0.end, text: simplified($0.text)) }
    }

    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
    }
}
