import AppKit
import AVFoundation
import Foundation
import ImageIO

/// Asks a vision-capable model for one short Chinese sentence describing a
/// library asset, so the editing planner knows what the asset is for.
///
/// Failures stay local: every entry point returns `nil` instead of throwing and
/// callers keep the description they already had.
enum MediaDescription {
    /// Longest description kept. The editor only needs one glance at the tile.
    static let maxCharacters = 60
    /// Anything longer than this is not a sentence, so it is dropped instead of cut.
    static let hardLimit = 200
    /// A reasoning model can spend its whole budget before producing text; retry once.
    static let attempts = 2

    static let instructions = """
    你是视频素材分析助手。用户会给你一张来自素材库的图片。用一句中文说明画面展示了什么，以及它适合用在视频的哪类位置。
    只输出这一句话，不要加编号、列表、引号或额外解释。
    """

    /// The bundled runner sends images only when requested, and a vision model is required.
    static func needsDescription(_ media: ReferenceMedia) -> Bool {
        media.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func describe(_ media: ReferenceMedia, at url: URL, connection: AIConnection) async -> String? {
        guard let attachment = await attachment(for: media, at: url) else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-description-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { return nil }
        defer { try? FileManager.default.removeItem(at: directory) }

        for _ in 0..<attempts {
            // A transport failure is not worth a second slow request: the model never answered.
            guard let reply = try? await EmbeddedPi.run(
                connection, system: instructions, prompt: prompt(for: media), directory: directory,
                tools: false, images: true, attachments: [attachment], timeout: 45,
                budgetMinutes: 1, budgetToolCalls: 1
            ) else { return nil }
            // An empty or unusable reply is retryable; a good one is returned at once.
            if let description = clean(reply) { return description }
        }
        return nil
    }

    /// Reduces a raw model reply to a single short line, or `nil` when useless.
    static func clean(_ raw: String) -> String? {
        var text = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= hardLimit else { return nil }

        for prefix in ["- ", "* ", "• ", "· ", "> ", "### ", "## ", "# "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        text = unquoted(text)
        for label in ["素材说明：", "素材描述：", "描述：", "说明："] where text.hasPrefix(label) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        guard !text.isEmpty, !isRefusal(text),
              !text.allSatisfy({ $0.isPunctuation || $0.isWhitespace || $0.isSymbol }) else { return nil }
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters))
            while let last = text.last, "，,、；;：:".contains(last) { text.removeLast() }
        }
        return text.count >= 2 ? text : nil
    }

    static func prompt(for media: ReferenceMedia) -> String {
        """
        素材名：\(media.name)
        这是一张\(media.kind == .image ? "图片" : "视频")素材的截图。请用一句中文说明画面展示了什么，以及适合用在视频的哪类位置（如开场、操作演示、结果展示）。
        只输出这一句话，不超过 40 个字；不要引号、不要 Markdown、不要解释。
        """
    }

    private static func unquoted(_ input: String) -> String {
        var text = input
        let wrappers: Set<Character> = ["\"", "'", "`", "“", "”", "「", "」", "『", "』", "‘", "’"]
        while text.count > 1, let first = text.first, let last = text.last,
              wrappers.contains(first), wrappers.contains(last) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// A refusal reads like a description until it reaches the user.
    private static func isRefusal(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return ["抱歉", "对不起", "我无法", "无法判断", "无法识别", "无法确定", "无法看清", "无法查看",
                "sorry", "i'm sorry", "i am sorry", "i can't", "i cannot", "unable to", "as an ai"]
            .contains { lowercased.hasPrefix($0) }
    }

    private static func attachment(for media: ReferenceMedia, at url: URL) async -> EmbeddedPi.ImageAttachment? {
        let frame: CGImage?
        switch media.kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            frame = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 768
            ] as CFDictionary)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 768, height: 768)
            let time = CMTime(seconds: (media.duration ?? 0) / 2, preferredTimescale: 600)
            frame = try? await generator.image(at: time).image
        }
        guard let frame,
              let jpeg = NSBitmapImageRep(cgImage: frame).representation(using: .jpeg, properties: [.compressionFactor: 0.75])
        else { return nil }
        return EmbeddedPi.ImageAttachment(data: jpeg, mimeType: "image/jpeg")
    }
}
