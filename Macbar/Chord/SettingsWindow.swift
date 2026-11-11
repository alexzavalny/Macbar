import AppKit
import SwiftUI

/// The settings window, created on first use. A plain NSWindow: SwiftUI's Settings and Window
/// scenes are unreliable to bring forward from a menu bar-only app.
@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show(settings: SettingsStore, access: AccessibilityStatus) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings, access: access)))
            w.title = "Chord Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // The hosting controller sizes the window lazily; size it now so center() is right.
            w.setContentSize(w.contentViewController!.view.fittingSize)
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // activate() is only a request on macOS 14+; keep the window visible even if it's refused.
        window?.orderFrontRegardless()
    }
}
