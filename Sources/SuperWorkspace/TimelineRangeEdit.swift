import Foundation

enum TimelineRangeEdit {
    enum Edge { case start, end, move }
    static let frame = 1.0 / 30

    static func range(start: Double, end: Double, edge: Edge, delta: Double,
                      lower: Double, upper: Double, snapPoints: [Double] = [], snapDistance: Double = 0) -> ClosedRange<Double> {
        guard [start, end, delta, lower, upper].allSatisfy(\.isFinite), upper - lower >= frame - 0.000_001 else { return start...max(start, end) }
        let duration = end - start
        let raw = (edge == .end ? end : start) + delta
        var position = (raw / frame).rounded() * frame
        if let snap = snapPoints.filter({ $0.isFinite && abs($0 - raw) <= snapDistance }).min(by: { abs($0 - raw) < abs($1 - raw) }) {
            position = snap
        }
        switch edge {
        case .start: return min(max(lower, position), end - frame)...end
        case .end: return start...max(min(upper, position), start + frame)
        case .move:
            let moved = min(max(lower, position), max(lower, upper - duration))
            return moved...(moved + duration)
        }
    }
}
