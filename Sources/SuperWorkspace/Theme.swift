import SwiftUI

/// Brand palette. Two complete themes; the dark one is the primary surface for
/// video work, the light one is its equal. Every value here is a design-system
/// token — change it in the system first, then here.
enum Theme {
    /// Brand mark colours are fixed (see WorkspaceBrand); these are the UI roles.
    enum Dark {
        static let bgBase = Color(hex: 0x101823)
        static let bgSidebar = Color(hex: 0x0C121B)
        static let bgDeep = Color(hex: 0x080D15)
        static let surface1 = Color(hex: 0x1A2333)
        static let surface2 = Color(hex: 0x283244)
        static let surface3 = Color(hex: 0x3D4A5D)
        static let borderStrong = Color(hex: 0x6E7C90)
        static let textPrimary = Color(hex: 0xF3EEE3)
        static let textSecondary = Color(hex: 0xB7C0CD)
        static let textMuted = Color(hex: 0x96A2B2)
        static let accent = Color(hex: 0x8FB0CB)
        static let brand = Color(hex: 0xF0713F)
        static let ai = Color(hex: 0xC7AEEA)
        static let success = Color(hex: 0x7FC98A)
        static let warning = Color(hex: 0xE3A757)
        static let danger = Color(hex: 0xF08A86)
        /// Video ground: neutral in both themes so it never biases colour judgement.
        static let mediaGround = Color(hex: 0x191A1C)
    }

    enum Light {
        static let bgBase = Color(hex: 0xFBF8F1)
        static let bgSidebar = Color(hex: 0xF4EFE3)
        static let bgDeep = Color(hex: 0xE9E2D0)
        static let surface1 = Color(hex: 0xF1EBDD)
        static let surface2 = Color(hex: 0xE3DBC8)
        static let surface3 = Color(hex: 0xC9C0A9)
        static let borderStrong = Color(hex: 0x877D64)
        static let textPrimary = Color(hex: 0x1A2940)
        static let textSecondary = Color(hex: 0x46505F)
        static let textMuted = Color(hex: 0x5A6474)
        static let accent = Color(hex: 0x3A6488)
        static let brand = Color(hex: 0xE6572E)
        static let ai = Color(hex: 0x6B4C93)
        static let success = Color(hex: 0x2A702E)
        static let warning = Color(hex: 0x8F5405)
        static let danger = Color(hex: 0xB53326)
        static let mediaGround = Color(hex: 0x191A1C)
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
    let bgBase: Color
    let bgSidebar: Color
    let bgDeep: Color
    let surface1: Color
    let surface2: Color
    let surface3: Color
    /// Control outlines that need 3:1. Dividers use surface2 instead.
    let borderStrong: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let accent: Color
    /// Signal only: recording state, brand presence. Never small text on a light ground.
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
        bgBase: Theme.Dark.bgBase, bgSidebar: Theme.Dark.bgSidebar, bgDeep: Theme.Dark.bgDeep,
        surface1: Theme.Dark.surface1, surface2: Theme.Dark.surface2, surface3: Theme.Dark.surface3,
        borderStrong: Theme.Dark.borderStrong,
        textPrimary: Theme.Dark.textPrimary, textSecondary: Theme.Dark.textSecondary, textMuted: Theme.Dark.textMuted,
        accent: Theme.Dark.accent, brand: Theme.Dark.brand, ai: Theme.Dark.ai,
        success: Theme.Dark.success, warning: Theme.Dark.warning, danger: Theme.Dark.danger,
        mediaGround: Theme.Dark.mediaGround
    )

    static let light = Palette(
        bgBase: Theme.Light.bgBase, bgSidebar: Theme.Light.bgSidebar, bgDeep: Theme.Light.bgDeep,
        surface1: Theme.Light.surface1, surface2: Theme.Light.surface2, surface3: Theme.Light.surface3,
        borderStrong: Theme.Light.borderStrong,
        textPrimary: Theme.Light.textPrimary, textSecondary: Theme.Light.textSecondary, textMuted: Theme.Light.textMuted,
        accent: Theme.Light.accent, brand: Theme.Light.brand, ai: Theme.Light.ai,
        success: Theme.Light.success, warning: Theme.Light.warning, danger: Theme.Light.danger,
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

/// Design-system metrics: the only numbers layout code should use for rhythm.
/// Spacing is a 4pt grid; the half steps exist for compact controls.
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

    // radius-*
    static let radiusXS: CGFloat = 4
    static let radiusS: CGFloat = 6
    static let radiusM: CGFloat = 8
    static let radiusL: CGFloat = 12

    // size-* — control heights and fixed layout widths
    static let controlCompact: CGFloat = 28
    static let control: CGFloat = 38
    static let row: CGFloat = 34
    static let choice: CGFloat = 36
    static let bar: CGFloat = 42
    static let toggleRow: CGFloat = 46
    static let header: CGFloat = 80
    static let sidebar: CGFloat = 220
    static let sidebarRail: CGFloat = 56
    static let content: CGFloat = 1000
    static let contentWide: CGFloat = 1200
    static let inspector: CGFloat = 260

    // opacity-*
    static let opacityPressed: Double = 0.72
    static let opacityDisabled: Double = 0.38
    static let opacitySelected: Double = 0.10
}

/// Type scale. Sizes, weights and tracking come from tokens.json; use these
/// instead of `.system(size:)` so the scale stays in one place.
enum StudioType {
    case display, title, heading, subhead
    case bodyLarge, bodyLargeMedium
    case body, bodyMedium
    case small, smallStrong
    case caption, micro
    case timecode

    var size: CGFloat {
        switch self {
        case .display: 36
        case .title: 24
        case .heading: 22
        case .subhead: 18
        case .bodyLarge, .bodyLargeMedium: 15
        case .body, .bodyMedium: 13
        case .small, .smallStrong: 12
        case .caption: 11
        case .micro: 10
        case .timecode: 11
        }
    }

    var weight: Font.Weight {
        switch self {
        case .display, .title, .subhead, .bodyLargeMedium, .bodyMedium, .caption, .micro: .medium
        case .heading, .smallStrong: .semibold
        case .bodyLarge, .body, .small, .timecode: .regular
        }
    }

    /// Display sizes carry negative tracking; text sizes carry none.
    var tracking: CGFloat {
        switch self {
        case .display: -0.8
        case .title: -0.4
        case .heading: -0.3
        case .subhead: -0.2
        default: 0
        }
    }
}

extension Font {
    /// Scale style, with an optional weight override for component variants that
    /// the scale does not name (a compact button is 12/500, for instance).
    static func studio(_ type: StudioType, weight: Font.Weight? = nil) -> Font {
        if type == .timecode {
            return .system(size: type.size, weight: weight ?? type.weight, design: .monospaced)
        }
        return .system(size: type.size, weight: weight ?? type.weight)
    }
}

struct WorkspaceHeading: View {
    @Environment(\.palette) private var palette
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            Text(title)
                .font(.studio(.display))
                .tracking(StudioType.display.tracking)
                .foregroundStyle(palette.textPrimary)
            Text(detail)
                .font(.studio(.body))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
