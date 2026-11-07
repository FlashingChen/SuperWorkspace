import AppKit
import QuartzCore
import RecorderKit

/// Keeps the real workspace windows and their SwiftUI state intact. Only
/// disposable, click-through snapshots move between the two surfaces.
@MainActor
final class WorkspaceRecordingTransition {
    static let shared = WorkspaceRecordingTransition()

    private struct WorkspaceWindow {
        let window: NSWindow
        let frame: NSRect
        let image: CGImage?

        @MainActor
        init(_ window: NSWindow, snapshot: Bool) {
            self.window = window
            frame = window.frame
            if snapshot, let view = window.contentView?.superview ?? window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                image = bitmap.cgImage
            } else {
                image = nil
            }
        }
    }

    private let registeredWindows = NSHashTable<NSWindow>.weakObjects()
    private weak var previousKeyWindow: NSWindow?
    private var hiddenWindows: [WorkspaceWindow]?
    private var overlays: [NSPanel] = []
    private var animationID = UUID()
    private var keyObserver: NSObjectProtocol?

    private init() {
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = (note.object as? NSWindow).map(ObjectIdentifier.init) else { return }
            MainActor.assumeIsolated {
                guard let self, let window = self.registeredWindows.allObjects.first(where: { ObjectIdentifier($0) == id })
                else { return }
                self.redirectWhileRecording(window)
            }
        }
    }

    func register(_ window: NSWindow) {
        registeredWindows.add(window)
        if window.isKeyWindow { redirectWhileRecording(window) }
    }

    func prepare() {
        guard hiddenWindows == nil else { return }
        previousKeyWindow = NSApp.keyWindow
        hiddenWindows = NSApp.orderedWindows
            .filter { registeredWindows.contains($0) && $0.isVisible && !$0.isMiniaturized }
            .map { WorkspaceWindow($0, snapshot: $0.isOnActiveSpace) }
    }

    func collapse(into recorderFrame: NSRect?) {
        guard let hiddenWindows else { return }
        animate(hiddenWindows, at: recorderFrame, returning: false) {}
        hiddenWindows.forEach { $0.window.orderOut(nil) }
    }

    func restore(from recorderFrame: NSRect?) {
        guard let windows = hiddenWindows else { return }
        animate(windows, at: recorderFrame, returning: true) { [self] in
            let windows = hiddenWindows ?? []
            hiddenWindows = nil
            windows.reversed().forEach { $0.window.orderFront(nil) }
            let key = windows.first { $0.window === previousKeyWindow } ?? windows.first
            NSApp.activate(ignoringOtherApps: true)
            key?.window.makeKeyAndOrderFront(nil)
            previousKeyWindow = nil
        }
    }

    private func redirectWhileRecording(_ window: NSWindow) {
        guard hiddenWindows != nil, registeredWindows.contains(window) else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, hiddenWindows != nil,
                  WorkspaceRecorder.shared.hasOpenSession, window.isVisible else { return }
            if hiddenWindows?.contains(where: { $0.window === window }) == false {
                hiddenWindows?.insert(WorkspaceWindow(window, snapshot: false), at: 0)
            }
            window.orderOut(nil)
            WorkspaceRecorder.shared.bringToFront()
        }
    }

    private func animate(
        _ windows: [WorkspaceWindow], at recorderFrame: NSRect?, returning: Bool,
        completion: @escaping @MainActor () -> Void
    ) {
        animationID = UUID()
        let id = animationID
        removeOverlays()
        let reducesMotion = UserDefaults.standard.bool(forKey: "reduceMotion")
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let target = reducesMotion ? nil : recorderFrame
        let duration = target == nil ? 0.12 : (returning ? 0.32 : 0.42)
        var layers: [(CALayer, CAAnimation)] = []
        for screen in NSScreen.screens {
            let screenFrame = screen.frame
            let root = CALayer()
            for item in windows.reversed() {
                guard let image = item.image else { continue }
                let compact = target ?? item.frame
                guard item.frame.union(compact).intersects(screenFrame) else { continue }
                let start = returning ? compact : item.frame
                let end = returning ? item.frame : compact
                let layer = CALayer()
                layer.contents = image
                layer.contentsGravity = .resizeAspectFill
                layer.masksToBounds = true
                layer.cornerCurve = .continuous
                layer.position = localCenter(of: end, in: screenFrame)
                layer.bounds = NSRect(origin: .zero, size: end.size)
                layer.cornerRadius = returning || target == nil ? Metrics.radiusL : compact.height / 2
                layer.opacity = returning ? 1 : 0
                root.addSublayer(layer)

                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = returning ? [0, 1, 1] : [1, 1, 0]
                fade.keyTimes = returning ? [0, 0.28, 1] : [0, 0.53, 1]
                fade.duration = duration
                let motion = CAAnimationGroup()
                motion.duration = duration
                motion.animations = [
                    property("position", from: localCenter(of: start, in: screenFrame),
                             to: layer.position, duration: duration),
                    property("bounds", from: NSRect(origin: .zero, size: start.size),
                             to: layer.bounds, duration: duration),
                    property("cornerRadius", from: returning && target != nil ? compact.height / 2 : Metrics.radiusL,
                             to: layer.cornerRadius, duration: duration),
                    fade,
                ]
                layers.append((layer, motion))
            }
            guard root.sublayers?.isEmpty == false else { continue }
            let view = NSView(frame: NSRect(origin: .zero, size: screenFrame.size))
            view.layer = root
            view.wantsLayer = true
            let overlay = NSPanel(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            overlay.contentView = view
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.hasShadow = false
            overlay.ignoresMouseEvents = true
            overlay.hidesOnDeactivate = false
            overlay.animationBehavior = .none
            overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            overlay.level = .floating
            overlays.append(overlay)
        }
        guard !layers.isEmpty else { completion(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.animationID == id else { return }
                completion()
                self.removeOverlays()
            }
        }
        for (layer, motion) in layers { layer.add(motion, forKey: "workspace-handoff") }
        overlays.forEach { $0.orderFrontRegardless() }
        CATransaction.commit()
    }

    private func localCenter(of frame: NSRect, in screen: NSRect) -> NSPoint {
        NSPoint(x: frame.midX - screen.minX, y: frame.midY - screen.minY)
    }

    private func property(_ key: String, from: Any, to: Any, duration: TimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.75, 0.26, 1)
        return animation
    }

    private func removeOverlays() {
        for overlay in overlays {
            overlay.orderOut(nil)
            overlay.contentView = nil
        }
        overlays.removeAll()
    }
}
