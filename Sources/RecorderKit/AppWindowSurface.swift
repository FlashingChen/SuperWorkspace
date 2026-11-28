import AppKit
import QuartzCore

/// Match the native host's alpha silhouette to its SwiftUI surface before
/// WindowServer samples it for a shadow, including intermediate resize frames.
@MainActor
enum AppWindowSurface {
    static func clip(_ view: NSView, radius: CGFloat) {
        view.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.cornerRadius = min(radius, min(view.bounds.width, view.bounds.height) / 2)
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        CATransaction.commit()
    }
}
