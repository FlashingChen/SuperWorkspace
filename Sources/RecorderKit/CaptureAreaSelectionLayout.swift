import Foundation

/// Toolbar geometry uses the desktop's available area. The selected recording
/// rectangle continues to use the complete display, including menu bar/Dock.
enum CaptureAreaSelectionLayout {
    static func scale(in available: CGRect, preferred: CGFloat) -> CGFloat {
        min(preferred, available.width / (642 + 24), available.height / (60 + 24))
    }

    static func toolbarFrame(for selection: CGRect, in available: CGRect, scale: CGFloat) -> CGRect {
        let size = CGSize(width: 642 * scale, height: 60 * scale)
        let safe = available.insetBy(dx: 12 * scale, dy: 12 * scale)
        let below = selection.minY - size.height - 14 * scale
        let above = selection.maxY + 14 * scale
        let y: CGFloat
        if below >= safe.minY, below + size.height <= safe.maxY {
            y = below
        } else if above >= safe.minY, above + size.height <= safe.maxY {
            y = above
        } else {
            y = min(max(below, safe.minY), safe.maxY - size.height)
        }
        let x = min(max(selection.midX - size.width / 2, safe.minX), safe.maxX - size.width)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
