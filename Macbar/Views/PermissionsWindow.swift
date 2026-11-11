import SwiftUI
import AppKit
import CoreLocation
import CoreGraphics
import ApplicationServices

enum PermissionState { case granted, denied, unknown }

struct PermissionItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let purpose: String
    let state: PermissionState
    /// Shown instead of the state when it adds something ("Music isn't running").
    var note: String?
    let grant: () -> Void
}

/// Reads every privacy permission Macbar uses, without prompting, and re-reads while visible.
@MainActor
final class PermissionsStore: ObservableObject {
    @Published private(set) var items: [PermissionItem] = []
    private let location = CLLocationManager()
    private var timer: Timer?

    private static func pane(_ name: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(name)")!)
    }

    /// Automation status for one app without asking: unknown if the app isn't running.
    private static func automation(_ bundleID: String) -> PermissionState {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { return .unknown }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        switch AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unknown
        }
    }

    private static func askAutomation(_ bundleID: String) {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        // Asking needs the app running; with a prompt this shows macOS's own dialog once.
        DispatchQueue.global().async { _ = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true) }
        pane("Privacy_Automation")
    }

    func refresh() {
        let loc = location.authorizationStatus
        let locState: PermissionState = loc == .authorizedAlways ? .granted : (loc == .notDetermined ? .unknown : .denied)
        let music = Self.automation("com.apple.Music")
        items = [
            PermissionItem(id: "ax", icon: "hand.point.up.left", title: "Accessibility",
                           purpose: "Window titles, grouping, tiling and Chord shortcuts.",
                           state: AXIsProcessTrusted() ? .granted : .denied) {
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                Self.pane("Privacy_Accessibility")
            },
            PermissionItem(id: "screen", icon: "rectangle.on.rectangle", title: "Screen Recording",
                           purpose: "Window preview thumbnails when hovering an app.",
                           state: CGPreflightScreenCaptureAccess() ? .granted : .denied) {
                _ = CGRequestScreenCaptureAccess()
                Self.pane("Privacy_ScreenCapture")
            },
            PermissionItem(id: "location", icon: "location", title: "Location",
                           purpose: "Reveals nearby Wi-Fi network names. Never recorded.",
                           state: locState, note: locState == .unknown ? "Not asked yet" : nil) { [location] in
                if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
                else { Self.pane("Privacy_LocationServices") }
            },
            PermissionItem(id: "finder", icon: "trash", title: "Automation: Finder",
                           purpose: "Open and empty the Trash.",
                           state: Self.automation("com.apple.finder")) { Self.askAutomation("com.apple.finder") },
            PermissionItem(id: "music", icon: "music.note", title: "Automation: Music",
                           purpose: "Playback controls on the Music tile.",
                           state: music, note: music == .unknown ? "Music isn't running" : nil) { Self.askAutomation("com.apple.Music") },
        ]
    }

    /// Clears Macbar's privacy entries, so stale ones left by a rebuild (the switch shows on in
    /// System Settings but the signature no longer matches) can be granted afresh.
    func resetAll() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "All", Bundle.main.bundleIdentifier ?? "studio.macbar.app"]
        try? task.run()
        task.waitUntilExit()
        refresh()
    }

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() { timer?.invalidate(); timer = nil }
}

struct PermissionsView: View {
    @ObservedObject var store: PermissionsStore

    private var grantedCount: Int { store.items.filter { $0.state == .granted }.count }

    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions").font(.system(size: 20, weight: .semibold))
                Text("\(grantedCount) of \(store.items.count) granted. Macbar asks only when a feature needs one.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 52) }
                    PermissionRow(item: item)
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                Text("Changes in System Settings show up here automatically.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset…") { confirmReset = true }
                    .help("Clear Macbar's entries, then allow again. Fixes switches that are on in System Settings but not really granted.")
                Button("Open Privacy Settings ↗") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                }.buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 11, weight: .medium))
            }
        }
        .padding(22)
        .frame(width: 480)
        .confirmationDialog("Reset all Macbar permissions?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { store.resetAll() }
        } message: {
            Text("Macbar's entries are removed from System Settings. Allow each permission again afterwards.")
        }
        .onAppear { store.startPolling() }
        .onDisappear { store.stopPolling() }
    }
}

private struct PermissionRow: View {
    let item: PermissionItem

    private var color: Color { item.state == .granted ? .green : (item.state == .denied ? .red : .orange) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 15)).frame(width: 30, height: 30)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13, weight: .medium))
                Text(item.purpose).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if item.state == .granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
            } else {
                VStack(alignment: .trailing, spacing: 3) {
                    Button(item.state == .denied ? "Allow…" : "Ask…", action: item.grant)
                    Text(item.note ?? "Not granted").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

/// The permissions window, created on first use.
@MainActor
final class PermissionsWindow {
    static let shared = PermissionsWindow()
    private let store = PermissionsStore()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PermissionsView(store: store)))
            w.title = "Macbar Permissions"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
