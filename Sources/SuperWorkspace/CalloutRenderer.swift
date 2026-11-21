import AppKit
import CoreGraphics

/// Renders callout overlays (titles, badges, highlight callouts, lower-thirds)
/// at full canvas resolution so preview and exported video match pixel for pixel.
@MainActor
enum CalloutRenderer {
    static func render(_ callout: CalloutOverlay, canvas: CGSize) -> SubtitleOverlay? {
        let primary = callout.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !primary.isEmpty, callout.end > callout.start, canvas.width >= 2, canvas.height >= 2 else { return nil }
        let secondary = callout.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = max(0.5, min(canvas.width, canvas.height) / 1080.0)
        let accent = parseHexColor(callout.accentHex) ?? NSColor(srgbRed: 0.941, green: 0.443, blue: 0.247, alpha: 1)

        let titleSize: CGFloat
        let subtitleSize: CGFloat
        let maxTextWidth: CGFloat
        let alignment: NSTextAlignment
        switch callout.style {
        case .title:
            titleSize = 54 * unit
            subtitleSize = 26 * unit
            maxTextWidth = canvas.width * 0.76
            alignment = .center
        case .badge:
            titleSize = 24 * unit
            subtitleSize = 16 * unit
            maxTextWidth = canvas.width * 0.45
            alignment = .center
        case .callout:
            titleSize = 34 * unit
            subtitleSize = 20 * unit
            maxTextWidth = canvas.width * 0.68
            alignment = .center
        case .lowerThird:
            titleSize = 34 * unit
            subtitleSize = 21 * unit
            maxTextWidth = canvas.width * 0.56
            alignment = .left
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping

        let titleAttr = NSAttributedString(string: primary, attributes: [
            .font: NSFont.systemFont(ofSize: titleSize, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])
        let titleRect = titleAttr.boundingRect(
            with: CGSize(width: max(40, maxTextWidth), height: canvas.height * 0.4),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        var subAttr: NSAttributedString?
        var subRect = CGRect.zero
        if let secondary, !secondary.isEmpty {
            let attr = NSAttributedString(string: secondary, attributes: [
                .font: NSFont.systemFont(ofSize: subtitleSize, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.82),
                .paragraphStyle: paragraph,
            ])
            subRect = attr.boundingRect(
                with: CGSize(width: max(40, maxTextWidth), height: canvas.height * 0.25),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            subAttr = attr
        }

        let padX: CGFloat = (callout.style == .badge ? 22 : 30) * unit
        let padY: CGFloat = (callout.style == .badge ? 12 : 20) * unit
        let gap: CGFloat = subAttr != nil ? 8 * unit : 0
        let accentBarWidth: CGFloat = callout.style == .lowerThird ? 6 * unit : 0
        let accentBarGap: CGFloat = callout.style == .lowerThird ? 16 * unit : 0

        let contentW = max(ceil(titleRect.width), ceil(subRect.width))
        let contentH = ceil(titleRect.height) + gap + ceil(subRect.height)
        let boxW = min(canvas.width * 0.9, contentW + padX * 2 + accentBarWidth + accentBarGap)
        let boxH = min(canvas.height * 0.5, contentH + padY * 2)
        let size = CGSize(width: max(2, ceil(boxW)), height: max(2, ceil(boxH)))

        guard let context = CGContext(
            data: nil,
            width: Int(size.width * 2),
            height: Int(size.height * 2),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.scaleBy(x: 2, y: 2)
        let bounds = CGRect(origin: .zero, size: size)
        let radius: CGFloat = callout.style == .badge ? size.height / 2 : 16 * unit
        let bgPath = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Backing card
        context.saveGState()
        context.addPath(bgPath)
        switch callout.style {
        case .title:
            context.setFillColor(CGColor(red: 0.06, green: 0.09, blue: 0.14, alpha: 0.86))
        case .badge:
            context.setFillColor(accent.withAlphaComponent(0.92).cgColor)
        case .callout:
            context.setFillColor(CGColor(red: 0.08, green: 0.11, blue: 0.17, alpha: 0.84))
        case .lowerThird:
            context.setFillColor(CGColor(red: 0.06, green: 0.09, blue: 0.14, alpha: 0.82))
        }
        context.fillPath()
        context.restoreGState()

        // Subtle rim border
        if callout.style != .badge {
            context.saveGState()
            context.addPath(bgPath)
            context.setStrokeColor(accent.withAlphaComponent(callout.style == .callout ? 0.72 : 0.35).cgColor)
            context.setLineWidth(callout.style == .callout ? 2.2 * unit : 1.4 * unit)
            context.strokePath()
            context.restoreGState()
        }

        // Left accent bar for lower-third
        if callout.style == .lowerThird {
            let barRect = CGRect(x: padX, y: padY, width: accentBarWidth, height: size.height - padY * 2)
            let barPath = CGPath(roundedRect: barRect, cornerWidth: accentBarWidth / 2, cornerHeight: accentBarWidth / 2, transform: nil)
            context.addPath(barPath)
            context.setFillColor(accent.cgColor)
            context.fillPath()
        }

        // Draw text (CoreGraphics origin is bottom-left)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let textX = padX + accentBarWidth + accentBarGap
        let textW = size.width - textX - padX
        if let subAttr {
            let subY = padY
            subAttr.draw(with: CGRect(x: textX, y: subY, width: textW, height: ceil(subRect.height)),
                         options: [.usesLineFragmentOrigin, .usesFontLeading])
            let titleY = padY + ceil(subRect.height) + gap
            titleAttr.draw(with: CGRect(x: textX, y: titleY, width: textW, height: ceil(titleRect.height)),
                           options: [.usesLineFragmentOrigin, .usesFontLeading])
        } else {
            let titleY = (size.height - ceil(titleRect.height)) / 2
            titleAttr.draw(with: CGRect(x: textX, y: titleY, width: textW, height: ceil(titleRect.height)),
                           options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }

        // Map normalized top-left (x, y) into CoreImage bottom-left frame
        let nx = min(0.95, max(0.05, callout.x.isFinite ? callout.x : 0.5))
        let ny = min(0.92, max(0.08, callout.y.isFinite ? callout.y : 0.2))
        let centerX = canvas.width * nx
        let centerY = canvas.height * (1.0 - ny)
        let originX = min(max(12 * unit, centerX - size.width / 2), max(12 * unit, canvas.width - size.width - 12 * unit))
        let originY = min(max(12 * unit, centerY - size.height / 2), max(12 * unit, canvas.height - size.height - 12 * unit))

        return SubtitleOverlay(
            start: callout.start,
            end: callout.end,
            image: image,
            frame: CGRect(x: originX, y: originY, width: size.width, height: size.height),
            fadeDuration: 0.22
        )
    }

    private static func parseHexColor(_ raw: String?) -> NSColor? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: 1
        )
    }
}
