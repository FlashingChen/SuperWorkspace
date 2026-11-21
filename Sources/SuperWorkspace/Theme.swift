import AppKit
import SwiftUI

/// Brand palette aligned with the Graphite / Soft Silver floating-island studio language.
/// Dark mode is the primary video surface; light mode is its neutral silver counterpart.
enum Theme {
    enum Dark {
        static let stage = Color(hex: 0x070708)
        static let island = Color(hex: 0x101112)
        static let panelRaised = Color(hex: 0x19191C)
        static let surface3 = Color(hex: 0x2A2C32)
        static let controlWell = Color.white.opacity(0.06)
        static let cardFill = Color.white.opacity(0.045)
        static let selectionWash = Color.white.opacity(0.14)
        static let hoverWash = Color.white.opacity(0.07)
        static let hairline = Color.white.opacity(0.06)
        static let islandOutline = Color.white.opacity(0.08)
        static let borderStrong = Color.white.opacity(0.13)
        static let topHighlight = Color.white.opacity(0.15)
        static let shadowContact = Color.black.opacity(0.50)
        static let shadowSoft = Color.black.opacity(0.42)
        static let stageLight = Color(red: 0.55, green: 0.58, blue: 0.68).opacity(0.08)

        static let textPrimary = Color(hex: 0xF5F5F5)
        static let textSecondary = Color(hex: 0xA8A8A8)
        static let textMuted = Color(hex: 0x808080)
        static let accent = Color(hex: 0xF7F7F7)
        static let onAccent = Color(hex: 0x121212)
        static let brand = Color(hex: 0xFF453A)
        static let ai = Color(hex: 0xC4B5FD)
        static let success = Color(hex: 0x85D142)
        static let warning = Color(hex: 0xF2AD47)
        static let danger = Color(hex: 0xFF453A)
        static let mediaGround = Color(hex: 0x0B0B0D)
    }

    enum Light {
        static let stage = Color(hex: 0xECEEF0)
        static let island = Color(hex: 0xFDFDFE)
        static let panelRaised = Color(hex: 0xF3F4F6)
        static let surface3 = Color(hex: 0xD5D8DF)
        static let controlWell = Color.black.opacity(0.05)
        static let cardFill = Color.black.opacity(0.038)
        static let selectionWash = Color.black.opacity(0.08)
        static let hoverWash = Color.black.opacity(0.05)
        static let hairline = Color.black.opacity(0.06)
        static let islandOutline = Color(hex: 0x0F172A).opacity(0.08)
        static let borderStrong = Color(hex: 0x0F172A).opacity(0.14)
        static let topHighlight = Color.white.opacity(0.95)
        static let shadowContact = Color(hex: 0x0F172A).opacity(0.06)
        static let shadowSoft = Color(hex: 0x0F172A).opacity(0.10)
        static let stageLight = Color.white.opacity(0.72)

        static let textPrimary = Color(hex: 0x191919)
        static let textSecondary = Color(hex: 0x5C5C5C)
        static let textMuted = Color(hex: 0x767676)
        static let accent = Color(hex: 0x1C1C1E)
        static let onAccent = Color.white
        static let brand = Color(hex: 0xFF3B30)
        static let ai = Color(hex: 0x6D4AFF)
        static let success = Color(hex: 0x4D9A1B)
        static let warning = Color(hex: 0xC77700)
        static let danger = Color(hex: 0xD92D20)
        static let mediaGround = Color(hex: 0x121316)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}

/// Theme palette resolved for the current colour scheme.
struct Palette {
    // Primary studio surfaces
    let stage: Color
    let island: Color
    let panelRaised: Color
    let controlWell: Color
    let cardFill: Color
    let selectionWash: Color
    let hoverWash: Color
    let hairline: Color
    let islandOutline: Color
    let topHighlight: Color
    let shadowContact: Color
    let shadowSoft: Color
    let stageLight: Color
    let onAccent: Color

    // Compatibility roles mapped onto the studio hierarchy
    let bgBase: Color
    let bgSidebar: Color
    let bgDeep: Color
    let surface1: Color
    let surface2: Color
    let surface3: Color
    let borderStrong: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let accent: Color
    /// Signal only: recording state and live indicators.
    let brand: Color
    let ai: Color
    let success: Color
    let warning: Color
    let danger: Color
    let mediaGround: Color

    static func current(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? dark : light
    }

    static let dark = Palette(
        stage: Theme.Dark.stage,
        island: Theme.Dark.island,
        panelRaised: Theme.Dark.panelRaised,
        controlWell: Theme.Dark.controlWell,
        cardFill: Theme.Dark.cardFill,
        selectionWash: Theme.Dark.selectionWash,
        hoverWash: Theme.Dark.hoverWash,
        hairline: Theme.Dark.hairline,
        islandOutline: Theme.Dark.islandOutline,
        topHighlight: Theme.Dark.topHighlight,
        shadowContact: Theme.Dark.shadowContact,
        shadowSoft: Theme.Dark.shadowSoft,
        stageLight: Theme.Dark.stageLight,
        onAccent: Theme.Dark.onAccent,
        bgBase: Theme.Dark.stage,
        bgSidebar: Theme.Dark.island,
        bgDeep: Theme.Dark.stage,
        surface1: Theme.Dark.island,
        surface2: Theme.Dark.panelRaised,
        surface3: Theme.Dark.surface3,
        borderStrong: Theme.Dark.borderStrong,
        textPrimary: Theme.Dark.textPrimary,
        textSecondary: Theme.Dark.textSecondary,
        textMuted: Theme.Dark.textMuted,
        accent: Theme.Dark.accent,
        brand: Theme.Dark.brand,
        ai: Theme.Dark.ai,
        success: Theme.Dark.success,
        warning: Theme.Dark.warning,
        danger: Theme.Dark.danger,
        mediaGround: Theme.Dark.mediaGround
    )

    static let light = Palette(
        stage: Theme.Light.stage,
        island: Theme.Light.island,
        panelRaised: Theme.Light.panelRaised,
        controlWell: Theme.Light.controlWell,
        cardFill: Theme.Light.cardFill,
        selectionWash: Theme.Light.selectionWash,
        hoverWash: Theme.Light.hoverWash,
        hairline: Theme.Light.hairline,
        islandOutline: Theme.Light.islandOutline,
        topHighlight: Theme.Light.topHighlight,
        shadowContact: Theme.Light.shadowContact,
        shadowSoft: Theme.Light.shadowSoft,
        stageLight: Theme.Light.stageLight,
        onAccent: Theme.Light.onAccent,
        bgBase: Theme.Light.stage,
        bgSidebar: Theme.Light.island,
        bgDeep: Theme.Light.stage,
        surface1: Theme.Light.island,
        surface2: Theme.Light.panelRaised,
        surface3: Theme.Light.surface3,
        borderStrong: Theme.Light.borderStrong,
        textPrimary: Theme.Light.textPrimary,
        textSecondary: Theme.Light.textSecondary,
        textMuted: Theme.Light.textMuted,
        accent: Theme.Light.accent,
        brand: Theme.Light.brand,
        ai: Theme.Light.ai,
        success: Theme.Light.success,
        warning: Theme.Light.warning,
        danger: Theme.Light.danger,
        mediaGround: Theme.Light.mediaGround
    )
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.current(.dark)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Root view that injects the palette for the active appearance.
struct ThemedContent<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environment(\.palette, Palette.current(scheme))
    }
}

/// Design-system metrics: spacing, nested island radii, and control dimensions.
enum Metrics {
    // space-*
    static let space0_5: CGFloat = 2
    static let space1: CGFloat = 4
    static let space1_5: CGFloat = 6
    static let space2: CGFloat = 8
    static let space2_5: CGFloat = 10
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20
    static let space6: CGFloat = 24
    static let space7: CGFloat = 28
    static let space8: CGFloat = 32
    static let space9: CGFloat = 36
    static let space10: CGFloat = 40
    static let space11: CGFloat = 44
    static let space13: CGFloat = 52

    // radius-* (nested from inner controls out to detached floating islands)
    static let radiusXS: CGFloat = 6
    static let radiusS: CGFloat = 8
    static let radiusM: CGFloat = 10
    static let radiusL: CGFloat = 14
    static let radiusIsland: CGFloat = 16
    static let radiusTile: CGFloat = 18
    static let radiusFloating: CGFloat = 20

    // size-* — control heights and fixed layout widths
    static let controlCompact: CGFloat = 28
    static let control: CGFloat = 34
    static let row: CGFloat = 34
    static let choice: CGFloat = 34
    static let bar: CGFloat = 42
    static let toggleRow: CGFloat = 44
    static let header: CGFloat = 46
    static let sidebar: CGFloat = 220
    static let sidebarRail: CGFloat = 56
    static let content: CGFloat = 1000
    static let contentWide: CGFloat = 1200
    static let inspector: CGFloat = 260
    static let chatPanel: CGFloat = 332

    // opacity-*
    static let opacityPressed: Double = 0.78
    static let opacityDisabled: Double = 0.38
    static let opacitySelected: Double = 0.14
}

/// Critically damped studio motion respecting Reduce Motion.
enum StudioMotion {
    private static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || UserDefaults.standard.bool(forKey: "reduceMotion")
    }

    static var interactive: Animation? {
        reducesMotion ? nil : .spring(response: 0.28, dampingFraction: 1)
    }

    static var settle: Animation? {
        reducesMotion ? nil : .spring(response: 0.36, dampingFraction: 1)
    }

    static var hover: Animation {
        reducesMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.14)
    }
}

/// Tight tool typography scale. Use `monospacedDigit()` on timecodes and counters.
enum StudioType {
    case display, title, heading, subhead
    case bodyLarge, bodyLargeMedium
    case body, bodyMedium
    case small, smallStrong
    case caption, micro
    case timecode

    var size: CGFloat {
        switch self {
        case .display: 22
        case .title: 18
        case .heading: 16
        case .subhead: 14
        case .bodyLarge, .bodyLargeMedium: 14
        case .body, .bodyMedium: 13
        case .small, .smallStrong: 12
        case .caption: 11
        case .micro: 10
        case .timecode: 11
        }
    }

    var weight: Font.Weight {
        switch self {
        case .display, .title, .heading, .smallStrong: .semibold
        case .subhead, .bodyLargeMedium, .bodyMedium, .caption, .micro: .medium
        case .bodyLarge, .body, .small, .timecode: .regular
        }
    }

    var tracking: CGFloat {
        switch self {
        case .display: -0.4
        case .title: -0.3
        case .heading: -0.2
        case .subhead: -0.1
        default: 0
        }
    }
}

extension Font {
    static func studio(_ type: StudioType, weight: Font.Weight? = nil) -> Font {
        if type == .timecode {
            return .system(size: type.size, weight: weight ?? type.weight, design: .monospaced)
        }
        return .system(size: type.size, weight: weight ?? type.weight)
    }
}

/// Floating graphite/silver island surface with subtle machined top highlight and layered shadow.
struct StudioIslandModifier: ViewModifier {
    @Environment(\.palette) private var palette
    var cornerRadius: CGFloat = Metrics.radiusIsland
    var shadow: Bool = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(palette.island, in: shape)
            .overlay {
                shape.strokeBorder(palette.islandOutline, lineWidth: 1)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [palette.topHighlight, .clear],
                        startPoint: .top,
                        endPoint: .center
                    ),
                    lineWidth: 0.75
                )
                .allowsHitTesting(false)
            }
            .shadow(color: shadow ? palette.shadowContact : .clear, radius: 2, y: 1)
            .shadow(color: shadow ? palette.shadowSoft : .clear, radius: 14, y: 8)
    }
}

/// Quiet grouped tile inside an island or sheet. Flat, no heavy outline.
struct StudioTileModifier: ViewModifier {
    @Environment(\.palette) private var palette
    var cornerRadius: CGFloat = Metrics.radiusTile
    var padding: CGFloat = Metrics.space4

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(palette.cardFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func studioIsland(cornerRadius: CGFloat = Metrics.radiusIsland, shadow: Bool = true) -> some View {
        modifier(StudioIslandModifier(cornerRadius: cornerRadius, shadow: shadow))
    }

    func studioTile(cornerRadius: CGFloat = Metrics.radiusTile, padding: CGFloat = Metrics.space4) -> some View {
        modifier(StudioTileModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

struct WorkspaceHeading: View {
    @Environment(\.palette) private var palette
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space1_5) {
            Text(title)
                .font(.studio(.heading))
                .tracking(StudioType.heading.tracking)
                .foregroundStyle(palette.textPrimary)
            if !detail.isEmpty {
                Text(detail)
                    .font(.studio(.small))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct WorkspaceEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        StudioWorkspace(title: title, detail: detail) {
            StudioPreview(symbol: symbol, title: "等待视频素材")
        } controls: {
            actions()
                .buttonStyle(StudioButtonStyle(kind: .primary))
        }
    }
}
