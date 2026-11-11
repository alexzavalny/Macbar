import AppKit
import os

private let log = Logger(subsystem: "studio.macbar.chord", category: "launcher")

@MainActor
final class AppLauncher {
    static let windowTimeout: Duration = .seconds(5)
    static let pollInterval: Duration = .milliseconds(100)
    static let settleTimeout: Duration = .milliseconds(1500)

    /// Opens the app as a Dock click does: a stopped app launches; a running one unhides,
    /// comes forward and opens a window if it has none. Returns its pid, or nil (with a beep)
    /// if the app can't be found or opened.
    func open(_ binding: AppBinding) async -> pid_t? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: binding.bundleID).first
        let url = running?.bundleURL ?? AppLocation.resolve(
            binding,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            lookup: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        )
        guard let url else {
            log.error("App not found: \(binding.bundleID, privacy: .public)")
            NSSound.beep()
            return nil
        }
        let pid: pid_t? = await withCheckedContinuation { continuation in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let error { log.error("Open \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
                continuation.resume(returning: app?.processIdentifier)
            }
        }
        if pid == nil { NSSound.beep() }
        return pid
    }

    /// Waits for a window of the app that `pick` takes from `AX.orderedWindows` (it chooses
    /// and claims one in the same turn), and readies it to be moved: restores it if minimized
    /// and takes it out of native fullscreen. nil after `windowTimeout`, or as soon as
    /// `isCurrent` turns false, before touching the window. Needs Accessibility.
    func window(of pid: pid_t, pick: ([AXUIElement]) -> AXUIElement?, while isCurrent: () -> Bool) async -> AXUIElement? {
        let deadline = ContinuousClock.now + Self.windowTimeout
        while ContinuousClock.now < deadline {
            guard isCurrent() else { return nil }
            if let w = pick(AX.orderedWindows(of: pid)) { return await ready(w, while: isCurrent) }
            try? await Task.sleep(for: Self.pollInterval)
        }
        log.info("No window for pid \(pid)")
        return nil
    }

    private func ready(_ w: AXUIElement, while isCurrent: () -> Bool) async -> AXUIElement? {
        if AX.isMinimized(w) {
            guard isCurrent() else { return nil }
            AX.setMinimized(w, false)
            await wait(while: { AX.isMinimized(w) })
        }
        if AX.isFullScreen(w) {
            guard isCurrent() else { return nil }
            AX.setFullScreen(w, false)
            await wait(while: { AX.isFullScreen(w) })
            // The window keeps animating out of its fullscreen Space after the flag flips.
            try? await Task.sleep(for: .milliseconds(500))
        }
        return isCurrent() ? w : nil
    }

    private func wait(while condition: () -> Bool) async {
        let deadline = ContinuousClock.now + Self.settleTimeout
        while condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
