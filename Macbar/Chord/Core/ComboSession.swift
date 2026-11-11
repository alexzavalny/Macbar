/// The keys pressed while the trigger modifiers stay held, in press order. A key can be in it
/// more than once: each time is another window of its app.
public struct ComboSession: Sendable {
    public private(set) var keys: [TriggerKey] = []
    /// Keys pressed and not released since: their auto-repeat must not add windows.
    private var held: Set<TriggerKey> = []

    public init() {}

    /// A press of `key`. Auto-repeat (no release since its last press) adds nothing; otherwise
    /// as `add`.
    @discardableResult
    public mutating func press(_ key: TriggerKey, windows: () -> Int) -> Bool {
        guard held.insert(key).inserted else { return false }
        return add(key, windows: windows)
    }

    public mutating func release(_ key: TriggerKey) {
        held.remove(key)
    }

    /// Adds `key` and returns true, or returns false if the session is full, or `key` is in it
    /// already and its app has no window left for another slot. `windows` (how many its app
    /// has) is asked only in that case.
    @discardableResult
    public mutating func add(_ key: TriggerKey, windows: () -> Int) -> Bool {
        guard keys.count < GridLayout.maxCount else { return false }
        let taken = keys.filter { $0 == key }.count
        guard taken == 0 || windows() > taken else { return false }
        keys.append(key)
        return true
    }

    public mutating func remove(at index: Int) {
        keys.remove(at: index)
    }
}
