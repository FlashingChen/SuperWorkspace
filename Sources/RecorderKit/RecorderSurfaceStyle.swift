import AppKit
import QuartzCore
import StudioTheme
import SwiftUI

/// Shared opaque surfaces for the recorder, backed by StudioTokens so the
/// floating recording island matches the host Graphite / Soft Silver palette.
enum RecorderStyle {
    static func adaptive(_ light: NSColor, _ dark: NSColor) -> NSColor {
        StudioTokens.adaptiveNS(light: light, dark: dark)
    }
    static let chromeNSColor = adaptive(.black, .white)
    static let inkNSColor = adaptive(StudioTokens.Light.textPrimaryNS, StudioTokens.Dark.textPrimaryNS)
    static let baseNSColor = adaptive(StudioTokens.Light.islandNS, StudioTokens.Dark.islandNS)
    static let canvasNSColor = adaptive(StudioTokens.Light.stageNS, StudioTokens.Dark.stageNS)
    static let ink = Color(nsColor: inkNSColor)
    static let chrome = Color(nsColor: chromeNSColor)
    static let muted = Color(nsColor: adaptive(StudioTokens.Light.textSecondaryNS, StudioTokens.Dark.textSecondaryNS))
    static let faint = Color(nsColor: adaptive(StudioTokens.Light.textMutedNS, StudioTokens.Dark.textMutedNS))
    /// Live indicators retain green; text/icons use a darker green on paper.
    static let mint = Color(nsColor: StudioTokens.Dark.successNS)
    static let positiveInk = Color(nsColor: adaptive(StudioTokens.Light.successNS, StudioTokens.Dark.successNS))
    static let mintWash = mint.opacity(0.18)
    static let silver = chrome.opacity(0.06)
    static let well = Color(nsColor: adaptive(StudioTokens.Light.controlWellNS, StudioTokens.Dark.controlWellNS))
    static let selectionNSColor = adaptive(StudioTokens.Light.selectionWashNS, StudioTokens.Dark.selectionWashNS)
    static let selection = Color(nsColor: selectionNSColor)
    static let line = Color(nsColor: adaptive(StudioTokens.Light.islandOutlineNS, StudioTokens.Dark.islandOutlineNS))
    static let lift = Color(nsColor: adaptive(StudioTokens.Light.shadowSoftNS, StudioTokens.Dark.shadowSoftNS))
    static let recording = Color(nsColor: adaptive(StudioTokens.Light.brandNS, StudioTokens.Dark.brandNS))
    static let destructiveInk = Color(nsColor: adaptive(StudioTokens.Light.dangerNS, StudioTokens.Dark.dangerNS))
    static let amberInk = Color(nsColor: adaptive(StudioTokens.Light.warningNS, StudioTokens.Dark.warningNS))
    static let base = Color(nsColor: baseNSColor)
    // Small controls sit over arbitrary camera/recording pixels. Their own
    // contrasting backdrop adapts; the media itself is never recoloured.
    static let mediaOverlay = Color(nsColor: adaptive(NSColor(white: 0.99, alpha: 0.94), .black.withAlphaComponent(0.55)))
    static let mediaInk = Color(nsColor: adaptive(NSColor(white: 0.1, alpha: 1), .white))
    static let primaryFill = Color(nsColor: adaptive(StudioTokens.Light.accentNS, StudioTokens.Dark.accentNS))
    static let onPrimary = Color(nsColor: adaptive(StudioTokens.Light.onAccentNS, StudioTokens.Dark.onAccentNS))
    static let edgeTop = Color(nsColor: adaptive(StudioTokens.Light.topHighlightNS, StudioTokens.Dark.topHighlightNS))
    static let edgeBottom = Color(nsColor: adaptive(StudioTokens.Light.hairlineNS, StudioTokens.Dark.hairlineNS))
}

/// Shared timing. Shapes travel on a soft spring; content follows a beat later
/// so a surface never arrives empty.
enum RecorderMotion {
    // AppKit card transitions sample these same springs on their frame clock.
    static let morphSpring = Spring(response: 0.5, dampingRatio: 0.82)
    static let settleSpring = Spring(response: 0.36, dampingRatio: 0.84)
    static var reduces: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var morph: Animation? {
        reduces ? nil : .spring(response: morphSpring.response, dampingFraction: morphSpring.dampingRatio)
    }
    static var settle: Animation? {
        reduces ? nil : .spring(response: settleSpring.response, dampingFraction: settleSpring.dampingRatio)
    }
    static var quick: Animation? { reduces ? nil : .spring(response: 0.26, dampingFraction: 0.86) }
    static var fade: Animation { .easeOut(duration: 0.18) }
}

/// The one surface: a solid shape with a machined top edge.
struct RecorderSurface: ViewModifier {
    let radius: CGFloat
    /// A surface inside a larger transparent window draws its own shadow.
    var castsShadow = false
    func body(content: Content) -> some View {
        content.background { RecorderSurfaceShape(radius: radius, castsShadow: castsShadow) }
    }
}

struct RecorderSurfaceShape: View {
    let radius: CGFloat
    var castsShadow = false
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(RecorderStyle.base)
            .shadow(color: RecorderStyle.lift.opacity(castsShadow ? 0.85 : 0), radius: 22, y: 10)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [RecorderStyle.edgeTop, RecorderStyle.edgeBottom],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func recorderSurface(radius: CGFloat, castsShadow: Bool = false) -> some View {
        modifier(RecorderSurface(radius: radius, castsShadow: castsShadow))
    }
}

/// The three weights of action on an island: the take itself, an ordinary
/// confirmation, and everything quieter.
struct RecorderPillButtonStyle: ButtonStyle {
    enum Kind { case record, primary, soft, quiet }
    var kind: Kind = .quiet
    func makeBody(configuration: Configuration) -> some View { Pill(kind: kind, configuration: configuration) }

    private struct Pill: View {
        let kind: Kind
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            configuration.label
                .font(.appUI(size: 13, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, kind == .quiet ? 14 : 18)
                .frame(height: 44)
                .background(fill(hovered: hovered && isEnabled, pressed: pressed), in: Capsule())
                .contentShape(Capsule())
                .appKeyboardFocus(in: Capsule(), color: (kind == .primary ? RecorderStyle.onPrimary : RecorderStyle.chrome).opacity(0.7))
                .scaleEffect(pressed && !RecorderMotion.reduces ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = $0 }
                .animation(RecorderMotion.quick, value: pressed)
                .animation(RecorderMotion.fade, value: hovered)
        }

        private var foreground: Color {
            switch kind {
            case .record: .white
            case .primary: RecorderStyle.onPrimary
            case .soft: RecorderStyle.ink
            case .quiet: RecorderStyle.ink.opacity(0.78)
            }
        }

        private func fill(hovered: Bool, pressed: Bool) -> Color {
            switch kind {
            case .record: RecorderStyle.recording.opacity(pressed ? 0.78 : hovered ? 0.9 : 1)
            case .primary: RecorderStyle.primaryFill.opacity(pressed ? 0.78 : hovered ? 0.9 : 0.96)
            case .soft: RecorderStyle.chrome.opacity(pressed ? 0.2 : hovered ? 0.15 : 0.1)
            case .quiet: RecorderStyle.chrome.opacity(pressed ? 0.14 : hovered ? 0.09 : 0)
            }
        }
    }
}

/// A small key legend that travels with the action it triggers.
struct RecorderKeyHint: View {
    let key: String
    var body: some View {
        Text(key).font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .opacity(0.62)
            .accessibilityHidden(true)
    }
}

/// Four open corners of a camera viewfinder, inset from the edges of the
/// thing being framed. The inset animates, so the frame can close in.
struct CaptureViewfinder: Shape {
    var inset: CGFloat
    var arm: CGFloat
    var radius: CGFloat = 16

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(inset, arm) }
        set { inset = newValue.first; arm = newValue.second }
    }

    func path(in bounds: CGRect) -> Path {
        let rect = bounds.insetBy(dx: inset, dy: inset)
        var path = Path()
        let corners: [(corner: CGPoint, dx: CGFloat, dy: CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
        ]
        for (corner, dx, dy) in corners {
            let end = CGPoint(x: corner.x + arm * dx, y: corner.y)
            path.move(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
            path.addArc(tangent1End: corner, tangent2End: end, radius: radius)
            path.addLine(to: end)
        }
        return path
    }
}

/// The few controls that keep a fill use one quiet tone, with no outline and
/// no drop shadow.
struct RecorderRaisedSurface: ViewModifier {
    var radius: CGFloat = EditorInterfaceRadius.group
    var selected = false
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(selected ? RecorderStyle.selection : RecorderStyle.well)
        }
    }
}

struct RecorderButtonStyle: ButtonStyle {
    var primary = false
    /// The primary action starts a take: the one red button on the glass.
    var records = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        return configuration.label
            .foregroundStyle(primary ? (records ? Color.white : RecorderStyle.onPrimary) : RecorderStyle.ink)
            .background(primary ? AnyShapeStyle(records ? RecorderStyle.recording.opacity(pressed ? 0.8 : 1) : RecorderStyle.primaryFill.opacity(pressed ? 0.8 : 0.95))
                                : AnyShapeStyle(RecorderStyle.well), in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous))
            .appKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.control, style: .continuous),
                              color: RecorderStyle.chrome.opacity(0.65))
            .modifier(RecorderPressFeedback(isPressed: pressed, cornerRadius: EditorInterfaceRadius.control))
    }
}

/// Keep compact configuration actions inside their existing hit bounds while
/// sharing the toolbar's short pressed settle and reduced-motion behavior.
struct RecorderPlainPressButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(RecorderPressFeedback(isPressed: configuration.isPressed,
                                           isEnabled: isEnabled, cornerRadius: cornerRadius))
    }
}

/// Artwork reacts inside its existing native hit target. The inset edge and
/// shade remain visible when accessibility settings suppress physical motion.
struct RecorderPressFeedback: ViewModifier {
    let isPressed: Bool
    var isEnabled = true
    var cornerRadius: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let pressed = isPressed && isEnabled
        return content
            .scaleEffect(pressed && !reduceMotion ? 0.92 : 1)
            .opacity(pressed ? 0.62 : 1)
            .animation(reduceMotion ? nil : .spring(response: pressed ? 0.14 : 0.3, dampingFraction: 0.7), value: pressed)
            .animation(nil, value: reduceMotion)
    }
}

/// Each action keeps its press state through updates to the recording bar.
/// The original AppKit control still owns mouse-up actions and accessibility.
struct RecorderNativeActionButton<Label: View>: View {
    let accessibilityLabel: String
    var accessibilityIdentifier: String? = nil
    var isEnabled = true
    let width: CGFloat
    let height: CGFloat
    var cornerRadius: CGFloat = 10
    var highlightOpacity: Double = 0.04
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var pressed = false

    var body: some View {
        ZStack {
            label()
                .frame(width: width, height: height)
                .modifier(RecorderPressFeedback(isPressed: pressed, isEnabled: isEnabled,
                                               cornerRadius: cornerRadius))
                .accessibilityHidden(true)
            RecorderActionTrigger(action: action, accessibilityLabel: accessibilityLabel,
                isEnabled: isEnabled, accessibilityIdentifier: accessibilityIdentifier,
                cornerRadius: cornerRadius, highlightOpacity: highlightOpacity,
                onPressChange: { pressed = $0 })
        }
        .frame(width: width, height: height)
        .opacity(isEnabled ? 1 : 0.4)
        .help(accessibilityLabel)
    }
}

struct RecorderSelectionEntrance: ViewModifier {
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 7)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.985)
            .onAppear { withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.2)) { appeared = true } }
    }
}

@MainActor
func animateRecorderOverlayIn(_ window: NSWindow) {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    window.alphaValue = 0
    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        window.animator().alphaValue = 1
    }
}

struct RecorderCirclePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }
    private struct HoverBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        var body: some View {
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(RecorderStyle.chrome.opacity(isEnabled && hovered && !configuration.isPressed ? 0.1 : 0))
                        .allowsHitTesting(false)
                }
                .appKeyboardFocus(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .modifier(RecorderPressFeedback(isPressed: configuration.isPressed, isEnabled: isEnabled,
                                               cornerRadius: 18))
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
        }
    }
}
