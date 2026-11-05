import AppKit

/// A single caption treatment for the player and the rendered movie.
@MainActor
enum SubtitleRenderer {
    struct Caption {
        let image: CGImage
        let frame: CGRect
    }
    static func caption(_ text: String, canvas: CGSize) -> Caption? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        var fontSize = max(18, canvas.height * 0.035)
        let maxWidth = canvas.width * 0.86
        var attributed: NSAttributedString
        var measured: CGRect
        repeat {
            attributed = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
            ])
            measured = attributed.boundingRect(with: CGSize(width: max(1, maxWidth - fontSize), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            if measured.height <= canvas.height * 0.25 || fontSize <= 10 { break }
            fontSize = max(10, fontSize * 0.9)
        } while true
        let padding = max(5, fontSize * 0.5)
        let size = CGSize(width: min(maxWidth, ceil(measured.width) + padding * 2), height: ceil(measured.height) + padding * 2)
        guard let context = CGContext(data: nil, width: Int(ceil(size.width * 2)), height: Int(ceil(size.height * 2)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(CGColor(gray: 0, alpha: 0.65))
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: fontSize * 0.3,
                               cornerHeight: fontSize * 0.3, transform: nil))
        context.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(with: CGRect(x: padding, y: padding, width: size.width - padding * 2, height: size.height - padding * 2),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return Caption(image: image, frame: CGRect(x: (canvas.width - size.width) / 2, y: canvas.height * 0.06,
                                                  width: size.width, height: size.height))
    }
}
