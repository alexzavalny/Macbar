/// Trigger modifiers + 2…5: gives the right window, then the bottom one, 1/N of the tile.
public enum SizeKey: Int, CaseIterable, Sendable {
    case two = 2, three, four, five

    /// Carbon virtual key code (`kVK_ANSI_2` … `kVK_ANSI_5`).
    public var keyCode: UInt32 {
        switch self {
        case .two: 0x13
        case .three: 0x14
        case .four: 0x15
        case .five: 0x17
        }
    }

    /// The divider's position: the slot before it keeps what the 1/N after it leaves.
    var split: Double { Double(rawValue - 1) / Double(rawValue) }

    /// The digits a tile of `count` windows can use; only these are taken from other apps.
    public static func available(for count: Int) -> [SizeKey] {
        count >= 2 ? allCases : []
    }
}

/// Which divider the next digit sets: the vertical one first, then the horizontal one, and so
/// on in turn. A tile without a horizontal divider only has the vertical one.
public struct SizePresses: Sendable {
    private var presses = 0

    public init() {}

    /// `splits` with the divider for this press moved to `key`, or nil when the tile has none.
    public mutating func press(_ key: SizeKey, count: Int, splits: Splits) -> Splits? {
        guard count >= 2 else { return nil }
        var next = splits
        if presses % 2 == 1, Splits.applies(.down, count: count) {
            next.y = key.split
        } else {
            next.x = key.split
        }
        presses += 1
        return next
    }

    /// The trigger modifiers were released or a new tile came up: the next digit sets the width.
    public mutating func reset() {
        presses = 0
    }
}
