import AppKit
import ApplicationServices

@MainActor
final class AccessibilityStatus: ObservableObject {
    @Published private(set) var trusted = AXIsProcessTrusted()

    private var timer: Timer?

    /// Asks once, so the app appears in System Settings, then checks every 2 s until granted.
    func start() {
        trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        guard !trusted, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.trusted = true
                self.timer?.invalidate()
                self.timer = nil
            }
        }
    }

    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
