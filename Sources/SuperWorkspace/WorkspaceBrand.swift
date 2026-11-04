import AppKit

/// Vector master shared by the sidebar and the packaged application icon.
enum WorkspaceBrand {
    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.scaleBy(x: bounds.width / 1024, y: bounds.height / 1024)
            func rounded(_ rect: CGRect, radius: CGFloat, color: NSColor) {
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            }
            rounded(CGRect(x: 100, y: 100, width: 824, height: 824), radius: 184,
                    color: NSColor(srgbRed: 0.10, green: 0.16, blue: 0.25, alpha: 1))
            rounded(CGRect(x: 240, y: 370, width: 468, height: 350), radius: 66,
                    color: NSColor(srgbRed: 0.49, green: 0.62, blue: 0.73, alpha: 1))
            rounded(CGRect(x: 316, y: 280, width: 468, height: 350), radius: 66,
                    color: NSColor(srgbRed: 0.98, green: 0.96, blue: 0.90, alpha: 1))
            let play = NSBezierPath()
            play.move(to: NSPoint(x: 500, y: 368))
            play.line(to: NSPoint(x: 500, y: 542))
            play.line(to: NSPoint(x: 638, y: 455))
            play.close()
            play.lineJoinStyle = .round
            play.lineWidth = 20
            NSColor(srgbRed: 0.90, green: 0.34, blue: 0.18, alpha: 1).set()
            play.fill()
            play.stroke()
            context.restoreGState()
            return true
        }
    }
}
