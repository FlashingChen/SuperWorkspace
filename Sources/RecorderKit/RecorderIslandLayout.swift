import Foundation

/// The capsule stays compact at rest. During its SwiftUI spring, the native
/// window only supplies drawing room; it does not animate or mask the capsule.
struct RecorderIslandLayout: Equatable {
    let canvasSize: CGSize
    let placementSize: CGSize

    static func compact(_ size: CGSize) -> Self {
        Self(canvasSize: size, placementSize: size)
    }

    static func morph(
        from oldSize: CGSize,
        to newSize: CGSize,
        retaining current: Self
    ) -> Self {
        let peak = CGSize(
            width: max(oldSize.width, newSize.width, current.placementSize.width),
            height: max(oldSize.height, newSize.height, current.placementSize.height)
        )
        // Leave room for the original spring's overshoot and the content's
        // 6 pt blur. Retargeting must never shrink a running animation's canvas.
        return Self(
            canvasSize: CGSize(
                width: max(current.canvasSize.width, peak.width + 2 * max(16, ceil(peak.width * 0.05))),
                height: max(current.canvasSize.height, peak.height + 32)
            ),
            placementSize: peak
        )
    }
}
