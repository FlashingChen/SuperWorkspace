import AppKit
import SwiftUI

/// Single source of truth for the Graphite / Soft Silver floating-island palette,
/// shared by the main SuperWorkspace host and the integrated RecorderKit windows.
public enum StudioTokens {
    public enum Dark {
        public static let stageNS = NSColor(srgbRed: 0x07 / 255.0, green: 0x07 / 255.0, blue: 0x08 / 255.0, alpha: 1)
        public static let islandNS = NSColor(srgbRed: 0x10 / 255.0, green: 0x11 / 255.0, blue: 0x12 / 255.0, alpha: 1)
        public static let panelRaisedNS = NSColor(srgbRed: 0x19 / 255.0, green: 0x19 / 255.0, blue: 0x1C / 255.0, alpha: 1)
        public static let surface3NS = NSColor(srgbRed: 0x2A / 255.0, green: 0x2C / 255.0, blue: 0x32 / 255.0, alpha: 1)
        public static let controlWellNS = NSColor.white.withAlphaComponent(0.06)
        public static let cardFillNS = NSColor.white.withAlphaComponent(0.045)
        public static let selectionWashNS = NSColor.white.withAlphaComponent(0.14)
        public static let hoverWashNS = NSColor.white.withAlphaComponent(0.07)
        public static let hairlineNS = NSColor.white.withAlphaComponent(0.06)
        public static let islandOutlineNS = NSColor.white.withAlphaComponent(0.08)
        public static let borderStrongNS = NSColor.white.withAlphaComponent(0.13)
        public static let topHighlightNS = NSColor.white.withAlphaComponent(0.15)
        public static let shadowContactNS = NSColor.black.withAlphaComponent(0.50)
        public static let shadowSoftNS = NSColor.black.withAlphaComponent(0.42)
        public static let stageLightNS = NSColor(srgbRed: 0.55, green: 0.58, blue: 0.68, alpha: 0.08)

        public static let textPrimaryNS = NSColor(srgbRed: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF5 / 255.0, alpha: 1)
        public static let textSecondaryNS = NSColor(srgbRed: 0xA8 / 255.0, green: 0xA8 / 255.0, blue: 0xA8 / 255.0, alpha: 1)
        public static let textMutedNS = NSColor(srgbRed: 0x80 / 255.0, green: 0x80 / 255.0, blue: 0x80 / 255.0, alpha: 1)
        public static let accentNS = NSColor(srgbRed: 0xF7 / 255.0, green: 0xF7 / 255.0, blue: 0xF7 / 255.0, alpha: 1)
        public static let onAccentNS = NSColor(srgbRed: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 1)
        public static let brandNS = NSColor(srgbRed: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0, alpha: 1)
        public static let aiNS = NSColor(srgbRed: 0xC4 / 255.0, green: 0xB5 / 255.0, blue: 0xFD / 255.0, alpha: 1)
        public static let successNS = NSColor(srgbRed: 0x85 / 255.0, green: 0xD1 / 255.0, blue: 0x42 / 255.0, alpha: 1)
        public static let warningNS = NSColor(srgbRed: 0xF2 / 255.0, green: 0xAD / 255.0, blue: 0x47 / 255.0, alpha: 1)
        public static let dangerNS = NSColor(srgbRed: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0, alpha: 1)
        public static let mediaGroundNS = NSColor(srgbRed: 0x0B / 255.0, green: 0x0B / 255.0, blue: 0x0D / 255.0, alpha: 1)
    }

    public enum Light {
        public static let stageNS = NSColor(srgbRed: 0xEC / 255.0, green: 0xEE / 255.0, blue: 0xF0 / 255.0, alpha: 1)
        public static let islandNS = NSColor(srgbRed: 0xFD / 255.0, green: 0xFD / 255.0, blue: 0xFE / 255.0, alpha: 1)
        public static let panelRaisedNS = NSColor(srgbRed: 0xF3 / 255.0, green: 0xF4 / 255.0, blue: 0xF6 / 255.0, alpha: 1)
        public static let surface3NS = NSColor(srgbRed: 0xD5 / 255.0, green: 0xD8 / 255.0, blue: 0xDF / 255.0, alpha: 1)
        public static let controlWellNS = NSColor.black.withAlphaComponent(0.05)
        public static let cardFillNS = NSColor.black.withAlphaComponent(0.038)
        public static let selectionWashNS = NSColor.black.withAlphaComponent(0.08)
        public static let hoverWashNS = NSColor.black.withAlphaComponent(0.05)
        public static let hairlineNS = NSColor.black.withAlphaComponent(0.06)
        public static let islandOutlineNS = NSColor(srgbRed: 0x0F / 255.0, green: 0x17 / 255.0, blue: 0x2A / 255.0, alpha: 0.08)
        public static let borderStrongNS = NSColor(srgbRed: 0x0F / 255.0, green: 0x17 / 255.0, blue: 0x2A / 255.0, alpha: 0.14)
        public static let topHighlightNS = NSColor.white.withAlphaComponent(0.95)
        public static let shadowContactNS = NSColor(srgbRed: 0x0F / 255.0, green: 0x17 / 255.0, blue: 0x2A / 255.0, alpha: 0.06)
        public static let shadowSoftNS = NSColor(srgbRed: 0x0F / 255.0, green: 0x17 / 255.0, blue: 0x2A / 255.0, alpha: 0.10)
        public static let stageLightNS = NSColor.white.withAlphaComponent(0.72)

        public static let textPrimaryNS = NSColor(srgbRed: 0x19 / 255.0, green: 0x19 / 255.0, blue: 0x19 / 255.0, alpha: 1)
        public static let textSecondaryNS = NSColor(srgbRed: 0x5C / 255.0, green: 0x5C / 255.0, blue: 0x5C / 255.0, alpha: 1)
        public static let textMutedNS = NSColor(srgbRed: 0x76 / 255.0, green: 0x76 / 255.0, blue: 0x76 / 255.0, alpha: 1)
        public static let accentNS = NSColor(srgbRed: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0, alpha: 1)
        public static let onAccentNS = NSColor.white
        public static let brandNS = NSColor(srgbRed: 0xFF / 255.0, green: 0x3B / 255.0, blue: 0x30 / 255.0, alpha: 1)
        public static let aiNS = NSColor(srgbRed: 0x6D / 255.0, green: 0x4A / 255.0, blue: 0xFF / 255.0, alpha: 1)
        public static let successNS = NSColor(srgbRed: 0x4D / 255.0, green: 0x9A / 255.0, blue: 0x1B / 255.0, alpha: 1)
        public static let warningNS = NSColor(srgbRed: 0xC7 / 255.0, green: 0x77 / 255.0, blue: 0x00 / 255.0, alpha: 1)
        public static let dangerNS = NSColor(srgbRed: 0xD9 / 255.0, green: 0x2D / 255.0, blue: 0x20 / 255.0, alpha: 1)
        public static let mediaGroundNS = NSColor(srgbRed: 0x12 / 255.0, green: 0x13 / 255.0, blue: 0x16 / 255.0, alpha: 1)
    }

    public static func adaptiveNS(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    public static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: adaptiveNS(light: light, dark: dark))
    }
}
