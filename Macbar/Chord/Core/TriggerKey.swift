/// A key that can be bound to an app: A–Z, by its physical position on an ANSI keyboard.
/// (Digits size the tile instead, see `SizeKey`.)
public enum TriggerKey: String, CaseIterable, Codable, Hashable, Sendable, Comparable {
    case a = "A", b = "B", c = "C", d = "D", e = "E", f = "F", g = "G", h = "H", i = "I"
    case j = "J", k = "K", l = "L", m = "M", n = "N", o = "O", p = "P", q = "Q", r = "R"
    case s = "S", t = "T", u = "U", v = "V", w = "W", x = "X", y = "Y", z = "Z"

    /// Carbon virtual key code (`kVK_ANSI_*`).
    public var keyCode: UInt32 {
        switch self {
        case .a: 0x00
        case .s: 0x01
        case .d: 0x02
        case .f: 0x03
        case .h: 0x04
        case .g: 0x05
        case .z: 0x06
        case .x: 0x07
        case .c: 0x08
        case .v: 0x09
        case .b: 0x0B
        case .q: 0x0C
        case .w: 0x0D
        case .e: 0x0E
        case .r: 0x0F
        case .y: 0x10
        case .t: 0x11
        case .o: 0x1F
        case .u: 0x20
        case .i: 0x22
        case .p: 0x23
        case .l: 0x25
        case .j: 0x26
        case .k: 0x28
        case .n: 0x2D
        case .m: 0x2E
        }
    }

    /// Alphabetical (declaration order).
    public static func < (lhs: TriggerKey, rhs: TriggerKey) -> Bool {
        lhs.order < rhs.order
    }

    private var order: Int { Self.allCases.firstIndex(of: self)! }
}
