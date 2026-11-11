import CoreGraphics

/// Where the windows of a combo go, in press order.
///
/// 1: the whole area · 2: left | right · 3: left | right top / right bottom · 4: 2×2.
/// `gap` separates slots and insets the screen edges. Slots plus gaps fill the area exactly;
/// the left or top slot of a split gets `splits.x` / `splits.y` of the space, rounded down.
public enum GridLayout {
    public static let maxCount = 4

    public static func frames(count: Int, in visible: CGRect, gap: Double, splits: Splits = Splits()) -> [CGRect] {
        guard (1...maxCount).contains(count) else { return [] }
        let (r, g) = area(visible, gap: gap)
        let (leftW, rightW) = split(r.width, gap: g, fraction: splits.x)
        let (topH, bottomH) = split(r.height, gap: g, fraction: splits.y)
        let rightX = r.minX + leftW + g
        let bottomY = r.minY + topH + g

        switch count {
        case 1:
            return [r]
        case 2:
            return [
                CGRect(x: r.minX, y: r.minY, width: leftW, height: r.height),
                CGRect(x: rightX, y: r.minY, width: rightW, height: r.height),
            ]
        case 3:
            return [
                CGRect(x: r.minX, y: r.minY, width: leftW, height: r.height),
                CGRect(x: rightX, y: r.minY, width: rightW, height: topH),
                CGRect(x: rightX, y: bottomY, width: rightW, height: bottomH),
            ]
        default:
            return [
                CGRect(x: r.minX, y: r.minY, width: leftW, height: topH),
                CGRect(x: rightX, y: r.minY, width: rightW, height: topH),
                CGRect(x: r.minX, y: bottomY, width: leftW, height: bottomH),
                CGRect(x: rightX, y: bottomY, width: rightW, height: bottomH),
            ]
        }
    }

    /// The splits that put the inner edges of window `slot` where `frame` has them, measured
    /// from the `splits` its slot was laid out with. Outer edges, moves and jitter of up to
    /// `tolerance` change nothing; the result keeps to `Splits.range`.
    public static func splits(dragging slot: Int, to frame: CGRect, count: Int, in visible: CGRect,
                              gap: Double, from splits: Splits) -> Splits {
        let slots = frames(count: count, in: visible, gap: gap, splits: splits)
        guard count >= 2, slots.indices.contains(slot) else { return splits }
        let (r, g) = area(visible, gap: gap)
        let old = slots[slot]
        func moved(_ a: Double, _ b: Double) -> Bool { abs(a - b) > tolerance }
        func clamped(_ v: Double) -> Double { min(max(v, Splits.range.lowerBound), Splits.range.upperBound) }

        var next = splits
        let leftColumn = old.minX == r.minX
        if leftColumn, moved(frame.maxX, old.maxX), !moved(frame.minX, old.minX) {
            next.x = clamped((frame.maxX - r.minX) / (r.width - g))
        } else if !leftColumn, moved(frame.minX, old.minX), !moved(frame.maxX, old.maxX) {
            next.x = clamped((frame.minX - g - r.minX) / (r.width - g))
        }
        guard count >= 3, slot > 0 || count == 4 else { return next }
        let topRow = old.minY == r.minY
        if topRow, moved(frame.maxY, old.maxY), !moved(frame.minY, old.minY) {
            next.y = clamped((frame.maxY - r.minY) / (r.height - g))
        } else if !topRow, moved(frame.minY, old.minY), !moved(frame.maxY, old.maxY) {
            next.y = clamped((frame.minY - g - r.minY) / (r.height - g))
        }
        return next
    }

    /// How far adopted sizes may move a divider.
    public static let fitRange: ClosedRange<Double> = 0.05...0.95

    /// The splits that give each window in `actual` (by slot; nil where there is none) the size
    /// it has, where that differs from its slot's by more than `tolerance`: an app with a
    /// minimum or maximum size, or a character grid, keeps its size and the divider moves. Only
    /// windows at their slot's top-left corner count; only inner dividers move; a later slot wins.
    public static func splits(fitting actual: [CGRect?], count: Int, in visible: CGRect,
                              gap: Double, from splits: Splits) -> Splits {
        let slots = frames(count: count, in: visible, gap: gap, splits: splits)
        guard count >= 2 else { return splits }
        let (r, g) = area(visible, gap: gap)
        func clamped(_ v: Double) -> Double { min(max(v, fitRange.lowerBound), fitRange.upperBound) }

        var next = splits
        for (slot, frame) in zip(slots, actual) {
            // A window away from its slot's corner never took its place (native fullscreen,
            // a late or refused move): its size says nothing.
            guard let frame, abs(frame.minX - slot.minX) <= tolerance, abs(frame.minY - slot.minY) <= tolerance
            else { continue }
            let leftColumn = slot.minX == r.minX
            if abs(frame.width - slot.width) > tolerance {
                let leftWidth = leftColumn ? frame.width : r.width - g - frame.width
                next.x = clamped(leftWidth / (r.width - g))
            }
            let stacked = count == 4 || (count == 3 && !leftColumn)
            if stacked, abs(frame.height - slot.height) > tolerance {
                let topHeight = slot.minY == r.minY ? frame.height : r.height - g - frame.height
                next.y = clamped(topHeight / (r.height - g))
            }
        }
        return next
    }

    /// The first of `frames` that sits where `target` is, every edge within `tolerance`: the
    /// sibling tab that is left when a native tab of a tiled window closes.
    public static func match(_ target: CGRect, in frames: [CGRect?]) -> Int? {
        frames.firstIndex { f in
            guard let f else { return false }
            return [f.minX - target.minX, f.minY - target.minY, f.maxX - target.maxX, f.maxY - target.maxY]
                .allSatisfy { abs($0) <= tolerance }
        }
    }

    /// How far an edge may drift before it counts as dragged.
    static let tolerance = 2.0

    /// The area the slots fill: `visible` inset by the gap, on whole points.
    private static func area(_ visible: CGRect, gap: Double) -> (rect: CGRect, gap: Double) {
        let g = max(0, gap.rounded())
        let inset = visible.insetBy(dx: g, dy: g)
        let r = CGRect(x: inset.minX.rounded(), y: inset.minY.rounded(),
                       width: inset.width.rounded(.down), height: inset.height.rounded(.down))
        return (r, g)
    }

    /// Two lengths that, with `gap` between them, add up to `size`; the first gets `fraction`
    /// of the space (the epsilon keeps 0.3 × 1000 from flooring to 299).
    private static func split(_ size: Double, gap: Double, fraction: Double) -> (Double, Double) {
        let first = ((size - gap) * fraction + 1e-9).rounded(.down)
        return (first, size - gap - first)
    }
}
