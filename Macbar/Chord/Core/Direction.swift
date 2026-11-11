/// An arrow key that moves one of the tile's dividers.
public enum Direction: CaseIterable, Sendable {
    case left, right, up, down

    /// Carbon virtual key code (`kVK_*Arrow`).
    public var keyCode: UInt32 {
        switch self {
        case .left: 0x7B
        case .right: 0x7C
        case .down: 0x7D
        case .up: 0x7E
        }
    }
}
