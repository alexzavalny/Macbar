import CoreGraphics

/// A window as the hider sees it.
public struct WindowInfo<ID: Hashable>: Equatable {
    public let id: ID
    public let pid: Int32
    public let frame: CGRect

    public init(id: ID, pid: Int32, frame: CGRect) {
        self.id = id
        self.pid = pid
        self.frame = frame
    }
}

extension WindowInfo: Sendable where ID: Sendable {}

public enum HideSelection {
    /// The windows to park when a tile settles on `display`: everything centred on it except
    /// the tile's windows (`keep`), apps never hidden (`keepPIDs`), our own, and windows
    /// already parked.
    public static func toHide<ID>(_ windows: [WindowInfo<ID>], keep: Set<ID>, keepPIDs: Set<Int32> = [],
                                  display: CGRect, ownPID: Int32) -> [WindowInfo<ID>] {
        windows.filter { w in
            !keep.contains(w.id) && w.pid != ownPID && !keepPIDs.contains(w.pid)
                && display.contains(CGPoint(x: w.frame.midX, y: w.frame.midY))
                && !Parking.isParked(w.frame, displays: [display])
        }
    }
}
