import CoreGraphics

/// Windows Chord has parked, with the frames to put them back to, in hiding order.
public struct HiddenWindows<ID: Hashable> {
    public struct Entry {
        public let id: ID
        public let pid: Int32
        public let frame: CGRect
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public func contains(_ id: ID) -> Bool {
        entries.contains { $0.id == id }
    }

    /// Records a hidden window. One already recorded keeps its first frame: its current
    /// frame is the parked one.
    public mutating func add(_ id: ID, pid: Int32, frame: CGRect) {
        guard !contains(id) else { return }
        entries.append(Entry(id: id, pid: pid, frame: frame))
    }

    @discardableResult
    public mutating func remove(_ id: ID) -> Entry? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: i)
    }

    public mutating func removeAll(pid: Int32) -> [Entry] {
        let out = entries.filter { $0.pid == pid }
        entries.removeAll { $0.pid == pid }
        return out
    }

    public mutating func removeAll() -> [Entry] {
        defer { entries = [] }
        return entries
    }
}

extension HiddenWindows: Sendable where ID: Sendable {}
extension HiddenWindows.Entry: Sendable where ID: Sendable {}
extension HiddenWindows.Entry: Equatable {}
