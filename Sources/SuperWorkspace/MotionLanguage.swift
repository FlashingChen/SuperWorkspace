import Foundation

/// Spoken language of one material, so on-screen wording follows the narration instead of
/// defaulting to the language of the prompt template.
enum MotionLanguage: String, Sendable {
    case english, chinese, mixed

    struct Detection: Sendable {
        let language: MotionLanguage
        /// Latin share of the spoken text, 0–100.
        let latinShare: Int
    }

    static func detect(from subtitles: [TranscriptSegment]) -> Detection? {
        let text = subtitles.map(\.text).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        var cjk = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
                cjk += 1
            } else if scalar.isASCII, CharacterSet.letters.contains(scalar) {
                latin += 1
            }
        }
        let total = cjk + latin
        guard total >= 8 else { return nil }
        let latinShare = Double(latin) / Double(total)
        let percent = Int((latinShare * 100).rounded())
        if latinShare >= 0.85 { return Detection(language: .english, latinShare: percent) }
        if latinShare <= 0.15 { return Detection(language: .chinese, latinShare: percent) }
        return Detection(language: .mixed, latinShare: percent)
    }

    /// Instruction appended to the motion brief.
    func instruction(latinShare: Int) -> String {
        switch self {
        case .english:
            return "口播语言：英文（英文占比 \(latinShare)%）。画面里的标题、标签、注释、按钮文字一律用英文，不得出现中文；"
                + "专有名词保持原文大小写。"
        case .chinese:
            return "口播语言：中文。画面文字用中文（英文专有名词保留原文）。"
        case .mixed:
            return "口播语言：中英混合（英文占比 \(latinShare)%）。画面文字跟随所讲段落：英文句子用英文，中文句子用中文，"
                + "同一条镜头内不混排。"
        }
    }
}
