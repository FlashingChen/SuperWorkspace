import AppKit
import OSLog
import QuartzCore
import RecorderCore
import SwiftUI

/// Pure geometry/style policy for the native recorder panel. Keeping the
/// canonical sizes outside AppKit keeps phase transitions deterministic and
/// prevents title-bar chrome from appearing between phases.
enum RecorderPanelPolicy {
    static let styleMask: NSWindow.StyleMask = [.borderless]
    /// Bootstrap sizes only. The localized content reports its intrinsic size;
    /// shadow drawing is owned by AppKit and needs no transparent canvas.
    static let setupSize = NSSize(width: 570, height: 56)
    static let progressSize = NSSize(width: 240, height: 48)
    static let savedFrameKey = "recorder.panel.last-frame"

    static func contentSize(
        for phase: AppPhase,
        recordsMicrophone: Bool
    ) -> NSSize? {
        switch phase {
        case .setup:
            setupSize
        case .preparing, .finishing:
            progressSize
        case .recording:
            NSSize(width: recordingWindowWidth(recordsMicrophone: recordsMicrophone), height: 48)
        case .editor, .recordingComplete:
            nil
        }
    }

    static func measuredContentSize(_ size: NSSize) -> NSSize? {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    static func measuredWindowLayout(_ layout: RecorderIslandLayout) -> RecorderIslandLayout? {
        guard let canvas = measuredContentSize(layout.canvasSize),
              let placement = measuredContentSize(layout.placementSize),
              canvas.width >= placement.width, canvas.height >= placement.height else { return nil }
        return RecorderIslandLayout(canvasSize: canvas, placementSize: placement)
    }

    static func frame(
        centeredOn currentFrame: NSRect,
        layout: RecorderIslandLayout,
        visibleFrame: NSRect?
    ) -> NSRect {
        // Constrain the visible capsule, not its temporary drawing margin.
        let placement = frame(centeredOn: currentFrame,
            contentSize: layout.placementSize, visibleFrame: visibleFrame)
        return frame(centeredOn: placement,
            contentSize: layout.canvasSize, visibleFrame: nil)
    }

    /// Resize around the current visual center and clamp the result into the
    /// selected screen. This avoids the old left-edge anchored collapse and
    /// preserves the destination screen after a cross-display drag.
    static func frame(
        centeredOn currentFrame: NSRect,
        contentSize: NSSize,
        visibleFrame: NSRect?
    ) -> NSRect {
        var frame = NSRect(
            x: currentFrame.midX - contentSize.width / 2,
            y: currentFrame.midY - contentSize.height / 2,
            width: contentSize.width,
            height: contentSize.height
        )
        frame.origin.x = frame.origin.x.rounded()
        frame.origin.y = frame.origin.y.rounded()
        guard let visibleFrame else { return frame }

        frame.origin.x = min(
            max(frame.origin.x, visibleFrame.minX),
            max(visibleFrame.maxX - frame.width, visibleFrame.minX)
        )
        frame.origin.y = min(
            max(frame.origin.y, visibleFrame.minY),
            max(visibleFrame.maxY - frame.height, visibleFrame.minY)
        )
        return frame
    }

    static func initialFrame(
        contentSize: NSSize,
        visibleFrame: NSRect
    ) -> NSRect {
        frame(centeredOn: visibleFrame, contentSize: contentSize,
              visibleFrame: visibleFrame)
    }
}

@MainActor
final class RecorderPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let panel: RecorderPanel
    private let hostingView: RecorderHostingView<RecorderMainWindowRoot>
    private var hasPositionedPanel = false
    private var currentPhase: AppPhase
    private var measuredWindowLayout: RecorderIslandLayout?
    private var contentPresentationRevision: UInt64 = 0
    private var selectionIsActive = false
    private var selectionSource: CaptureSource?
    private let transition = RecorderPanelTransition()
    private let logger = Logger(
        subsystem: "cn.laogou.dogsc",
        category: "recorder-panel"
    )

    init(model: AppModel) {
        self.model = model
        currentPhase = model.phase
        let initialSize = RecorderPanelPolicy.contentSize(
            for: model.phase,
            recordsMicrophone: model.configuration.recordsMicrophone
        )
            ?? RecorderPanelPolicy.setupSize
        hostingView = RecorderHostingView(
            rootView: RecorderMainWindowRoot(
                model: model,
                phase: model.phase,
                presentationRevision: 0,
                acceptsMeasurement: { false }
            )
        )
        panel = RecorderPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [RecorderPanelPolicy.styleMask, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        contentPresentationRevision &+= 1
        hostingView.rootView = makeRoot(for: model.phase)
        configurePanel(initialSize: initialSize)
    }

    var window: NSPanel { panel }

    private var hidesSetupForSelection: Bool {
        currentPhase == .setup && selectionIsActive && selectionSource != .device
    }

    private func makeRoot(for phase: AppPhase) -> RecorderMainWindowRoot {
        let revision = contentPresentationRevision
        return RecorderMainWindowRoot(model: model, phase: phase,
            presentationRevision: revision,
            onWindowLayoutChange: { [weak self] layout in
                self?.resizeContent(to: layout, for: phase, revision: revision)
            },
            acceptsMeasurement: { [weak self] in
                guard let self else { return false }
                return revision == self.contentPresentationRevision
                    && phase == self.currentPhase
            })
    }

    private func resizeContent(
        to requested: RecorderIslandLayout,
        for phase: AppPhase,
        revision: UInt64
    ) {
        guard revision == contentPresentationRevision, phase == currentPhase,
              RecorderPanelPolicy.contentSize(for: phase,
                recordsMicrophone: model.configuration.recordsMicrophone) != nil,
              let layout = RecorderPanelPolicy.measuredWindowLayout(requested) else { return }
        measuredWindowLayout = layout
        let destination = RecorderPanelPolicy.frame(
            centeredOn: panel.frame, layout: layout,
            visibleFrame: panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        )
        guard panel.frame != destination else { return }
        panel.contentMinSize = layout.canvasSize
        panel.contentMaxSize = layout.canvasSize
        // Preserve the host, focus, press state and current screen. This runs
        // only for real content size changes, never for pointer drag updates.
        panel.setFrame(destination, display: true, animate: false)
        panel.invalidateShadow()
        panel.refreshPointerInteraction()
    }

    func present(phase: AppPhase) {
        let positionedFrame = hasPositionedPanel ? panel.frame : nil
        let phaseChanged = currentPhase != phase
        if phaseChanged {
            measuredWindowLayout = nil
            contentPresentationRevision &+= 1
        }
        // Saving a corner result should return the recorder quietly while
        // the user's other application keeps its typing focus.
        let returnsFromCompletion = currentPhase == .recordingComplete && phase == .setup
        let shouldActivateSetup = (phaseChanged || !panel.isVisible) && !returnsFromCompletion
        if phaseChanged { RecorderPopoverPresenter.shared.dismiss() }
        currentPhase = phase
        panel.presentedPhase = phase
        // SwiftUI may rebuild its scene-contributed menu when the editor
        // window closes. Reinstall our AppKit-owned File/Edit commands after
        // the phase transition settles, otherwise returning to the recorder
        // can lose the entire File menu and ⌘O stops working.

        guard let fallbackSize = RecorderPanelPolicy.contentSize(
            for: phase,
            recordsMicrophone: model.configuration.recordsMicrophone
        ) else {
            transition.hide(panel, animated: false)
            return
        }
        let layout = measuredWindowLayout ?? .compact(fallbackSize)
        let contentSize = layout.canvasSize
        let keepsAnimationCanvas = phaseChanged && hasPositionedPanel && panel.isVisible

        panel.level = CaptureWindowLevelPolicy.level(for: .recorderPanel(
            phase: phase,
            selectionActive: selectionIsActive
        ))
        // CaptureSurfaceFilter excludes this process's helper windows. Keep
        // the panel readable by other recorders throughout every phase.
        panel.sharingType = .readOnly
        if !keepsAnimationCanvas && (phaseChanged || phase != .recording) {
            panel.contentMinSize = contentSize
            panel.contentMaxSize = contentSize
        }

        if !hasPositionedPanel {
            panel.setContentSize(contentSize)
            let savedFrame = UserDefaults.standard.string(
                forKey: RecorderPanelPolicy.savedFrameKey
            ).map(NSRectFromString)
            let pointer = NSEvent.mouseLocation
            let pointerScreen = NSScreen.screens.first { $0.frame.contains(pointer) }
                ?? NSScreen.main
            let savedScreen = savedFrame.flatMap { saved in
                NSScreen.screens.first { !$0.frame.intersection(saved).isEmpty }
            }
            let destinationScreen = savedScreen ?? pointerScreen
            if let savedFrame, let destinationScreen {
                panel.setFrame(
                    RecorderPanelPolicy.frame(
                        centeredOn: savedFrame,
                        contentSize: contentSize,
                        visibleFrame: destinationScreen.visibleFrame
                    ),
                    display: false
                )
            } else if let destinationScreen {
                panel.setFrame(
                    RecorderPanelPolicy.initialFrame(
                        contentSize: contentSize,
                        visibleFrame: destinationScreen.visibleFrame
                    ),
                    display: false
                )
            } else {
                panel.center()
            }
            hasPositionedPanel = true
        }

        let destination = RecorderPanelPolicy.frame(
            centeredOn: positionedFrame ?? panel.frame,
            layout: layout,
            visibleFrame: panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        )

        // Readiness updates are observed by the existing root. Replacing it
        // inside a zero-duration transaction interrupted press/selection state.
        if phaseChanged || (phase != .recording && panel.frame.size != destination.size) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                // Do not collapse to a phase's bootstrap frame before SwiftUI
                // measures it and reserves space for the original size spring.
                if !keepsAnimationCanvas {
                    panel.setFrame(destination, display: false, animate: false)
                }
                if phaseChanged {
                    hostingView.rootView = makeRoot(for: phase)
                }
                panel.contentView?.layoutSubtreeIfNeeded()
                panel.contentView?.needsDisplay = true
                panel.invalidateShadow()
            }
            CATransaction.commit()
        }

        logger.info(
            "phase=\(String(describing: phase), privacy: .public) frame=\(self.panel.frame.width, privacy: .public)x\(self.panel.frame.height, privacy: .public)"
        )
        guard !hidesSetupForSelection else {
            transition.hide(panel, animated: true)
            return
        }
        if phaseChanged || !panel.isVisible || panel.alphaValue < 1 {
            transition.show(panel, animated: true)
        }
        if phase == .setup, shouldActivateSetup {
            NSApplication.shared.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func setCaptureSelectionActive(
        _ active: Bool,
        source: CaptureSource? = nil,
        restoringSetup: Bool = true
    ) {
        if selectionIsActive != active {
            if active { FirstUseTourController.controller(for: .recorder).suspend() }
            else { FirstUseTourController.controller(for: .recorder).resume() }
        }
        selectionIsActive = active
        selectionSource = active ? source : nil
        panel.level = CaptureWindowLevelPolicy.level(for: .recorderPanel(
            phase: currentPhase,
            selectionActive: active
        ))
        if hidesSetupForSelection {
            RecorderPopoverPresenter.shared.dismiss()
            panel.makeFirstResponder(nil)
            transition.hide(panel, animated: true)
        } else if !active, restoringSetup, currentPhase == .setup {
            present(phase: .setup)
        } else if active, currentPhase == .setup {
            present(phase: .setup)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        FirstUseTourController.controller(for: .recorder).suspend()
        transition.hide(panel, animated: false)
    }

    func bringToFront() {
        guard currentPhase != .editor, !hidesSetupForSelection else { return }
        transition.show(panel, animated: !panel.isVisible)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func shutdown() {
        RecorderPopoverPresenter.shared.dismiss()
        transition.hide(panel, animated: false)
        panel.setIslandInteractionView(nil)
        panel.contentView = nil
        panel.close()
    }

    private func configurePanel(initialSize: NSSize) {
        panel.identifier = recorderMainWindowIdentifier
        panel.presentedPhase = currentPhase
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.appearance = nil
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Native shadow extends outside the compact content frame.
        panel.hasShadow = true
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Keep the context current after a real move changes ColorSync profile.
        // No display-link, frame correction or drag-session patch participates.
        panel.displaysWhenScreenProfileChanges = true
        // macOS 15+ uses exactly one official SwiftUI WindowDragGesture. Older
        // systems retain AppKit's background movement as the compatibility
        // path; the two owners are never active together.
        if #available(macOS 15.0, *) {
            panel.isMovableByWindowBackground = false
        } else {
            panel.isMovableByWindowBackground = true
        }
        panel.acceptsMouseMovedEvents = true
        panel.tabbingMode = .disallowed
        panel.level = CaptureWindowLevelPolicy.level(for: .recorderPanel(
            phase: currentPhase,
            selectionActive: selectionIsActive
        ))
        // A recorder HUD must keep one stable overlay identity while moving
        // between displays with separate Spaces. This mirrors the camera HUD:
        // the behavior is fixed at construction and never toggled while held.
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        panel.contentMinSize = initialSize
        panel.contentMaxSize = initialSize
        panel.delegate = self
    }

    func windowDidMove(_ notification: Notification) {
        guard hasPositionedPanel, notification.object as? NSWindow === panel else { return }
        panel.refreshPointerInteraction()
        let savedFrame = measuredWindowLayout.map {
            RecorderPanelPolicy.frame(centeredOn: panel.frame,
                contentSize: $0.placementSize, visibleFrame: nil)
        } ?? panel.frame
        UserDefaults.standard.set(
            NSStringFromRect(savedFrame),
            forKey: RecorderPanelPolicy.savedFrameKey
        )
    }
}

final class RecorderPanel: NSPanel {
    var presentedPhase: AppPhase = .setup
    private lazy var pointerRegion = RecorderPanelPointerRegion(window: self)

    func setPointerInteractionEnabled(_ enabled: Bool) {
        pointerRegion.setEnabled(enabled)
    }

    func setIslandInteractionView(_ view: NSView?) {
        pointerRegion.setIslandView(view)
    }

    func refreshPointerInteraction() {
        pointerRegion.refresh()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
