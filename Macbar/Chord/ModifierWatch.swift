import AppKit

/// Tells when the trigger modifiers are let go, by polling the keyboard state
/// (needs no permission, and can't miss a release the way an event monitor can).
@MainActor
final class ModifierWatch {
    static let interval: TimeInterval = 0.05

    private var timer: Timer?

    /// Calls `onRelease` once, as soon as any of `modifiers` is no longer held.
    func start(_ modifiers: Modifiers, onRelease: @escaping @MainActor @Sendable () -> Void) {
        stop()
        let required = modifiers.eventFlags.rawValue
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard !NSEvent.modifierFlags.isSuperset(of: NSEvent.ModifierFlags(rawValue: required)) else { return }
                self?.stop()
                onRelease()
            }
        }
        // .common so it keeps firing while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

extension Modifiers {
    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.command) { flags.insert(.command) }
        return flags
    }

    /// The trigger modifiers among `flags`; Caps Lock, fn and the like are left out.
    init(_ flags: NSEvent.ModifierFlags) {
        self = Modifiers.ordered.map(\.flag).filter { flags.contains($0.eventFlags) }
            .reduce(into: []) { $0.formUnion($1) }
    }
}
