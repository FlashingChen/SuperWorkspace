import SwiftUI

/// Neutral workspace surfaces with restrained semantic accents.
enum Theme {
    enum Mocha {
        static let bgBase = Color(hex: 0x202124)
        static let bgSidebar = Color(hex: 0x1b1c1f)
        static let bgDeep = Color(hex: 0x151619)
        static let surface1 = Color(hex: 0x2a2c30)
        static let surface2 = Color(hex: 0x383b40)
        static let surface3 = Color(hex: 0x52565e)
        static let textPrimary = Color(hex: 0xe9eaec)
        static let textSecondary = Color(hex: 0xb0b4bc)
        static let textMuted = Color(hex: 0x999fa9)
        static let accent = Color(hex: 0x89b4fa)
        static let ai = Color(hex: 0xcba6f7)
        static let success = Color(hex: 0xa6e3a1)
        static let warning = Color(hex: 0xf9e2af)
        static let danger = Color(hex: 0xf38ba8)
    }

    enum Latte {
        static let bgBase = Color(hex: 0xfdfcf9)
        static let bgSidebar = Color(hex: 0xf3f2ee)
        static let bgDeep = Color(hex: 0xeaeae7)
        static let surface1 = Color(hex: 0xf3f2ee)
        static let surface2 = Color(hex: 0xe5e3dd)
        static let surface3 = Color(hex: 0xc8cac4)
        static let textPrimary = Color(hex: 0x252622)
        static let textSecondary = Color(hex: 0x6b6b63)
        static let textMuted = Color(hex: 0x6d736b)
        static let accent = Color(hex: 0x1e66f5)
        static let ai = Color(hex: 0x8839ef)
        static let success = Color(hex: 0x40a02b)
        static let warning = Color(hex: 0xdf8e1d)
        static let danger = Color(hex: 0xd20f39)
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

/// Theme palette resolved for the current color scheme.
struct Palette {
    let bgBase: Color
    let bgSidebar: Color
    let bgDeep: Color
    let surface1: Color
    let surface2: Color
    let surface3: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let accent: Color
    let ai: Color
    let success: Color
    let warning: Color
    let danger: Color

    static func current(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? dark : light
    }

    static let dark = Palette(
        bgBase: Theme.Mocha.bgBase, bgSidebar: Theme.Mocha.bgSidebar, bgDeep: Theme.Mocha.bgDeep,
        surface1: Theme.Mocha.surface1, surface2: Theme.Mocha.surface2, surface3: Theme.Mocha.surface3,
        textPrimary: Theme.Mocha.textPrimary, textSecondary: Theme.Mocha.textSecondary, textMuted: Theme.Mocha.textMuted,
        accent: Theme.Mocha.accent, ai: Theme.Mocha.ai, success: Theme.Mocha.success, warning: Theme.Mocha.warning, danger: Theme.Mocha.danger
    )

    static let light = Palette(
        bgBase: Theme.Latte.bgBase, bgSidebar: Theme.Latte.bgSidebar, bgDeep: Theme.Latte.bgDeep,
        surface1: Theme.Latte.surface1, surface2: Theme.Latte.surface2, surface3: Theme.Latte.surface3,
        textPrimary: Theme.Latte.textPrimary, textSecondary: Theme.Latte.textSecondary, textMuted: Theme.Latte.textMuted,
        accent: Theme.Latte.accent, ai: Theme.Latte.ai, success: Theme.Latte.success, warning: Theme.Latte.warning, danger: Theme.Latte.danger
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

struct WorkspaceHeading: View {
    @Environment(\.palette) private var palette
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 36, weight: .medium))
                .tracking(-0.8)
                .foregroundStyle(palette.textPrimary)
            Text(detail)
                .font(.system(size: 13))
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
