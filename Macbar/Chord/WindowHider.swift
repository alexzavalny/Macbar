import AppKit

/// Parks windows out of sight (Strip's corner method) and puts them back where they were.
@MainActor
final class WindowHider {
    private var hidden = HiddenWindows<AXUIElement>()

    /// Parks every window centred on `display` except `keep` and those of apps in `keepPIDs`.
    /// A window that is already hidden keeps its first recorded frame.
    func hideOthers(keep: Set<AXUIElement>, keepPIDs: Set<pid_t>, display: Screens.Display, displays: [Screens.Display]) {
        let others = displays.map(\.frame).filter { $0 != display.frame }
        let candidates = Self.visibleWindows().filter { !hidden.contains($0.id) }
        for w in HideSelection.toHide(candidates, keep: keep, keepPIDs: keepPIDs, display: display.frame, ownPID: getpid()) {
            hidden.add(w.id, pid: w.pid, frame: w.frame)
            AX.setFrame(w.id, Parking.frame(for: w.frame.size, display: display.frame, otherDisplays: others), pid: w.pid)
        }
    }

    /// `window` is part of a tile now: it must never be put back over it.
    func forget(_ window: AXUIElement) {
        hidden.remove(window)
    }

    func restore(pid: pid_t) {
        put(hidden.removeAll(pid: pid))
    }

    func restoreAll() {
        put(hidden.removeAll())
    }

    /// Windows left parked with no record go to the middle of the display they peek out of:
    /// left by a crash or force quit of Chord, or by an app that quit (or a logout) while hidden
    /// and reopened them where they were. `pid` limits it to one app.
    func gatherStrays(displays: [Screens.Display], pid: pid_t? = nil) {
        let frames = displays.map(\.frame)
        for w in Self.visibleWindows(pid: pid) where !hidden.contains(w.id) && Parking.isParked(w.frame, displays: frames) {
            guard let d = Parking.home(of: w.frame, displays: frames).map({ displays[$0] }) ?? displays.first else { continue }
            AX.setFrame(w.id, Parking.centered(w.frame.size, in: d.visible), pid: w.pid)
        }
    }

    /// Displays changed: each hidden window goes to the corner of the display it is on now
    /// (the main one if none).
    func repark(displays: [Screens.Display]) {
        let frames = displays.map(\.frame)
        for e in hidden.entries {
            guard let now = AX.frame(e.id),
                  let d = Parking.home(of: now, displays: frames).map({ frames[$0] }) ?? frames.first else { continue }
            let target = Parking.frame(for: now.size, display: d, otherDisplays: frames.filter { $0 != d })
            if target != now { AX.setFrame(e.id, target, pid: e.pid) }
        }
    }

    /// `pid` quit: its windows are gone, and a relaunch makes new ones.
    func drop(pid: pid_t) {
        _ = hidden.removeAll(pid: pid)
    }

    /// Back to the recorded frames; a frame whose display is gone is centred on the display the
    /// window is parked on.
    private func put(_ entries: [HiddenWindows<AXUIElement>.Entry]) {
        guard !entries.isEmpty else { return }
        let displays = Screens.all()
        let frames = displays.map(\.frame)
        for e in entries {
            let parkedOn = AX.frame(e.id).flatMap { Parking.home(of: $0, displays: frames) }.map { displays[$0].visible }
                ?? displays.first?.visible
            let target = parkedOn.map { Parking.restored(e.frame, displays: frames, fallback: $0) } ?? e.frame
            AX.setFrame(e.id, target, pid: e.pid)
        }
    }

    /// Standard, unminimized, non-fullscreen windows of visible regular apps other than us (or
    /// of `pid` only), as AX lists them (the current Space's).
    private static func visibleWindows(pid: pid_t? = nil) -> [WindowInfo<AXUIElement>] {
        let own = getpid()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != own }
            .filter { pid == nil || $0.processIdentifier == pid }
            .flatMap { app in
                AX.windows(of: app.processIdentifier).compactMap { w -> WindowInfo<AXUIElement>? in
                    guard AX.isStandard(w), !AX.isMinimized(w), !AX.isFullScreen(w), let f = AX.frame(w) else { return nil }
                    return WindowInfo(id: w, pid: app.processIdentifier, frame: f)
                }
            }
    }
}
