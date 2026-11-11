/// Spots a tap of the trigger modifiers alone: pressed (together or one at a time) and all let go
/// within `limit`, with no other modifier, key or click in between.
public struct ModifierTap: Sendable {
    /// The longest hold that still counts as a tap, in seconds.
    public static let limit = 0.5

    /// When the first modifier of the current hold went down.
    private var start: Double?
    private var reachedTrigger = false
    private var extra = false

    public init() {}

    /// The modifiers held changed to `held` at `time`; `lastInput` is when the latest key press or
    /// click happened, on the same clock. True when this change completes a tap of `trigger`.
    @discardableResult
    public mutating func changed(to held: Modifiers, trigger: Modifiers, at time: Double, lastInput: Double) -> Bool {
        guard held.isEmpty else {
            if start == nil {
                start = time
                reachedTrigger = false
                extra = false
            }
            if held == trigger { reachedTrigger = true }
            if !trigger.isSuperset(of: held) { extra = true }
            return false
        }
        guard let began = start else { return false }
        start = nil
        return reachedTrigger && !extra && time - began <= Self.limit && lastInput < began
    }
}
