/// The trigger modifiers held together with a `TriggerKey`.
public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let shift = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)

    public static let `default`: Modifiers = [.control, .option]

    /// Each modifier with its symbol, in the order macOS displays them.
    public static let ordered: [(flag: Modifiers, symbol: String)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]

    /// Shift alone would swallow typed capitals, so at least one of ⌃ ⌥ ⌘ is required.
    public var isValid: Bool { !intersection([.control, .option, .command]).isEmpty }

    /// Flags for Carbon's `RegisterEventHotKey` (cmdKey, shiftKey, optionKey, controlKey).
    public var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= 0x0100 }
        if contains(.shift) { flags |= 0x0200 }
        if contains(.option) { flags |= 0x0800 }
        if contains(.control) { flags |= 0x1000 }
        return flags
    }

    public var symbols: String {
        Self.ordered.filter { contains($0.flag) }.map(\.symbol).joined()
    }

    /// `self` with `flag` turned on or off, or nil if the result would not be valid.
    public func setting(_ flag: Modifiers, _ on: Bool) -> Modifiers? {
        let next = on ? union(flag) : subtracting(flag)
        return next.isValid ? next : nil
    }
}
