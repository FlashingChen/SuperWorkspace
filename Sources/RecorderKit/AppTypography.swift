import AppKit
import SwiftUI

/// Uses the macOS system typography consistently with the host workspace.
enum AppTypography {
    static func font(size: CGFloat, weight: Font.Weight, design: Font.Design) -> Font {
        .system(size: size, weight: weight, design: design)
    }

    static func regularTextWidth(_ text: String, size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}

extension Font {
    static func appUI(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        AppTypography.font(size: size, weight: weight, design: design)
    }

    static func appUI(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 26
        case .title: size = 22
        case .title2: size = 18
        case .title3: size = 16
        case .headline, .body: size = 13
        case .subheadline, .callout: size = 12
        case .footnote, .caption: size = 11
        case .caption2: size = 10
        @unknown default: size = 13
        }
        return appUI(size: size, weight: weight ?? (style == .headline ? .semibold : .regular))
    }
}
