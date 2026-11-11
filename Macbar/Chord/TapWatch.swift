import AppKit

/// Tells when the trigger modifiers are tapped alone, from modifier changes in any app (global
/// monitors of key events need Accessibility). Keys and clicks during the hold are read from the
/// system's idle times, so nothing else is monitored.
@MainActor
final class TapWatch {
    var onTap: @MainActor () -> Void = {}

    private let modifiers: @MainActor () -> Modifiers
    private var tap = ModifierTap()
    private var monitors: [Any] = []

    /// Input that makes a hold of the modifiers more than a tap.
    private static let inputs: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]

    init(modifiers: @escaping @MainActor () -> Modifiers) {
        self.modifiers = modifiers
    }

    /// Starts watching; does nothing if already watching.
    func start() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let held = Modifiers(event.modifierFlags)
            MainActor.assumeIsolated { self?.changed(to: held) }
        }) {
            monitors.append(global)
        }
        // Chord's own windows (Settings) aren't seen by the global monitor.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let held = Modifiers(event.modifierFlags)
            MainActor.assumeIsolated { self?.changed(to: held) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func changed(to held: Modifiers) {
        let now = ProcessInfo.processInfo.systemUptime
        let quiet = Self.inputs.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? .infinity
        if tap.changed(to: held, trigger: modifiers(), at: now, lastInput: now - quiet) { onTap() }
    }
}
