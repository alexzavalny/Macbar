import ApplicationServices
import os

private let log = Logger(subsystem: "studio.macbar.chord", category: "tile-watcher")

/// Tells when a window of the tile on screen is moved, resized or closed, through one
/// AXObserver per app.
@MainActor
final class TileWatcher {
    var onChange: @MainActor (AXUIElement) -> Void = { _ in }
    var onClose: @MainActor (AXUIElement) -> Void = { _ in }

    private var observers: [pid_t: AXObserver] = [:]

    private static let notifications = [
        kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification,
    ]

    /// Watches exactly `windows`; whatever was watched before is let go.
    func watch(_ windows: [(window: AXUIElement, pid: pid_t)]) {
        stop()
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for (window, pid) in windows {
            guard let observer = observer(for: pid) else { continue }
            for name in Self.notifications {
                AXObserverAddNotification(observer, window, name as CFString, refcon)
            }
        }
    }

    func stop() {
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
    }

    private func observer(for pid: pid_t) -> AXObserver? {
        if let observer = observers[pid] { return observer }
        var observer: AXObserver?
        guard AXObserverCreate(pid, tileWatcherCallback, &observer) == .success, let observer else {
            log.debug("AXObserverCreate failed for pid \(pid)")
            return nil
        }
        // .commonModes so drags are seen while a menu or a live resize is tracking.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
        return observer
    }

    fileprivate func handle(_ name: String, _ window: AXUIElement) {
        name == kAXUIElementDestroyedNotification ? onClose(window) : onChange(window)
    }
}

/// AXObserver callbacks arrive on the main run loop (sources are added to CFRunLoopGetMain).
private func tileWatcherCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let watcher = Unmanaged<TileWatcher>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated { watcher.handle(name, element) }
}
