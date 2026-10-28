import SwiftUI

@main
struct MacbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: TaskbarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // XCTest loads the application without putting a second bar on the desktop.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        NSApp.setActivationPolicy(.accessory)
        coordinator = TaskbarController()
        coordinator?.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
