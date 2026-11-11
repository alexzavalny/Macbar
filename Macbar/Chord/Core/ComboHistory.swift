/// The keys that walk the chord history: [ back, ] forward.
public enum HistoryMove: CaseIterable, Sendable {
    case back, forward

    /// Carbon virtual key code (`kVK_ANSI_LeftBracket` / `kVK_ANSI_RightBracket`).
    public var keyCode: UInt32 {
        switch self {
        case .back: 0x21
        case .forward: 0x1E
        }
    }
}

/// A chord as played: its apps in press order and where its dividers ended up.
public struct Combo: Equatable, Sendable {
    public var apps: [AppBinding]
    public var splits: Splits

    public init(apps: [AppBinding], splits: Splits) {
        self.apps = apps
        self.splits = splits
    }
}

/// The chords played, like a browser's history: back and forward walk it without adding to it.
public struct ComboHistory: Sendable {
    public static let limit = 50

    public private(set) var entries: [Combo] = []
    private var index: Int?

    public init() {}

    /// The entry on screen.
    public var current: Combo? { index.map { entries[$0] } }

    /// A chord was played. The same apps as the entry on screen (by bundle ID, in order) update
    /// it; any other chord drops the entries ahead of it and becomes the latest.
    public mutating func record(_ combo: Combo) {
        if let i = index, entries[i].apps.map(\.bundleID) == combo.apps.map(\.bundleID) {
            entries[i] = combo
            return
        }
        entries.removeSubrange((index.map { $0 + 1 } ?? 0)...)
        entries.append(combo)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        index = entries.count - 1
    }

    /// The tile on screen was resized.
    public mutating func setSplits(_ splits: Splits) {
        if let i = index { entries[i].splits = splits }
    }

    public mutating func back() -> Combo? {
        guard let i = index, i > 0 else { return nil }
        index = i - 1
        return entries[i - 1]
    }

    public mutating func forward() -> Combo? {
        guard let i = index, i + 1 < entries.count else { return nil }
        index = i + 1
        return entries[i + 1]
    }
}
