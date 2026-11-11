import CoreGraphics

/// Strip's corner method for hiding windows. macOS pulls a window that is entirely off screen
/// back into view, so a hidden window keeps 1 pt on its display, tucked into a bottom corner.
public enum Parking {
    /// Where a window of `size` hides on `display` (its full frame, AX coordinates):
    /// bottom-right; bottom-left if that would cover another display; else just below it.
    public static func frame(for size: CGSize, display d: CGRect, otherDisplays: [CGRect]) -> CGRect {
        let y = d.maxY - 1
        let candidates = [
            CGRect(origin: CGPoint(x: d.maxX - 1, y: y), size: size),
            CGRect(origin: CGPoint(x: d.minX - size.width + 1, y: y), size: size),
            CGRect(origin: CGPoint(x: d.minX, y: y), size: size),
        ]
        return candidates.first { c in !otherDisplays.contains { overlaps($0, c) } } ?? candidates[0]
    }

    /// True when the window shows at most a 1 pt sliver on every display.
    public static func isParked(_ frame: CGRect, displays: [CGRect]) -> Bool {
        displays.allSatisfy { d in
            let i = d.intersection(frame)
            return i.isNull || i.width <= 1 || i.height <= 1
        }
    }

    /// Index of the display `frame` overlaps most (a parked window's sliver counts), or nil.
    public static func home(of frame: CGRect, displays: [CGRect]) -> Int? {
        let areas = displays.map { d -> Double in
            let i = d.intersection(frame)
            return i.isNull ? -1 : Double(i.width * i.height)
        }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] >= 0 else { return nil }
        return best
    }

    /// `size`, capped to `visible`, centred in it.
    public static func centered(_ size: CGSize, in visible: CGRect) -> CGRect {
        let w = min(size.width, visible.width)
        let h = min(size.height, visible.height)
        return CGRect(x: (visible.midX - w / 2).rounded(.down), y: (visible.midY - h / 2).rounded(.down), width: w, height: h)
    }

    /// Where a hidden window goes back to: its recorded frame if that frame's centre is on one
    /// of `displays`, else the middle of `fallback` (the visible frame of the display it is
    /// parked on), its size capped to that.
    public static func restored(_ recorded: CGRect, displays: [CGRect], fallback: CGRect) -> CGRect {
        let centre = CGPoint(x: recorded.midX, y: recorded.midY)
        return displays.contains { $0.contains(centre) } ? recorded : centered(recorded.size, in: fallback)
    }

    /// Shares some area (touching edges do not count).
    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && i.width > 0 && i.height > 0
    }
}
