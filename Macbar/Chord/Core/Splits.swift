/// Where the tile's dividers sit: `x` is the share of the usable width left of the vertical
/// divider, `y` the share of the usable height above the horizontal one.
public struct Splits: Equatable, Sendable {
    public static let step = 0.05
    public static let range: ClosedRange<Double> = 0.2...0.8

    public var x: Double
    public var y: Double

    public init(x: Double = 0.5, y: Double = 0.5) {
        self.x = x
        self.y = y
    }

    /// Moves the divider along the arrow: ← → the vertical one, ↑ ↓ the horizontal one.
    public mutating func nudge(_ direction: Direction) {
        switch direction {
        case .left: x = Self.clamped(x - Self.step)
        case .right: x = Self.clamped(x + Self.step)
        case .up: y = Self.clamped(y - Self.step)
        case .down: y = Self.clamped(y + Self.step)
        }
    }

    /// Whether a tile of `count` windows has the divider `direction` moves.
    public static func applies(_ direction: Direction, count: Int) -> Bool {
        switch direction {
        case .left, .right: count >= 2
        case .up, .down: count >= 3
        }
    }

    /// The arrows a tile of `count` windows can use; only these are taken from other apps.
    public static func directions(for count: Int) -> [Direction] {
        Direction.allCases.filter { applies($0, count: count) }
    }

    /// Rounded to 2 decimals so repeated steps land exactly on 0.2, 0.25, … 0.8.
    private static func clamped(_ value: Double) -> Double {
        min(max((value * 100).rounded() / 100, range.lowerBound), range.upperBound)
    }
}
