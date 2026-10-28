import AppKit
import Combine

@MainActor
final class ApplicationStore: ObservableObject {
    @Published private(set) var installed: [ApplicationItem] = []
    @Published private(set) var running: [NSRunningApplication] = []
    @Published private(set) var activeID: String?
    @Published var launchError: String?
    @Published var recentIDs: [String] = []

    private var observations: [NSObjectProtocol] = []
    private var hiddenApplications: [NSRunningApplication] = []
    private var previousFrontmost: NSRunningApplication?
    private let preferences: Preferences
    private var cancellables = Set<AnyCancellable>()

    init(preferences: Preferences) {
        self.preferences = preferences
        preferences.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshRunning() }
            })
        }
        refreshRunning()
        reloadCatalog()
    }

    deinit { observations.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }

    var pinnedApps: [ApplicationItem] { preferences.pinnedIDs.compactMap { application(for: $0) } }
    var unpinnedRunningApps: [ApplicationItem] {
        running.compactMap { app in
            guard let id = app.bundleIdentifier, !preferences.pinnedIDs.contains(id) else { return nil }
            return item(from: app)
        }
    }
    var recentApps: [ApplicationItem] { recentIDs.compactMap { application(for: $0) } }

    func refreshRunning() {
        running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && !$0.isTerminated
        }
        activeID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func reloadCatalog() {
        // Only walk application locations; never inspect documents or ask for disk access.
        Task.detached(priority: .userInitiated) { [weak self] in
            let roots = ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications",
                         NSHomeDirectory() + "/Applications"]
            var urls: [URL] = []
            let manager = FileManager.default
            for root in roots {
                guard let enumerator = manager.enumerator(at: URL(fileURLWithPath: root),
                    includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
                while let url = enumerator.nextObject() as? URL {
                    if url.pathExtension.lowercased() == "app" {
                        urls.append(url)
                        enumerator.skipDescendants()
                    }
                    // Applications may be grouped into folders, but don't crawl arbitrary deep trees.
                    if enumerator.level > 3 { enumerator.skipDescendants() }
                }
            }
            let applications = urls.compactMap { url -> (String, String, URL)? in
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      id != Bundle.main.bundleIdentifier,
                      bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true,
                      bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true else { return nil }
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                return (id, name, url)
            }
            await MainActor.run { [weak self] in
                var seen = Set<String>()
                self?.installed = applications.filter { seen.insert($0.0).inserted }.map {
                    ApplicationItem(id: $0.0, name: $0.1, url: $0.2, icon: NSWorkspace.shared.icon(forFile: $0.2.path))
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
    }

    func application(for id: String) -> ApplicationItem? {
        if let installed = installed.first(where: { $0.id == id }) { return installed }
        if let app = running.first(where: { $0.bundleIdentifier == id }) { return item(from: app) }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return ApplicationItem(id: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                               url: url, icon: NSWorkspace.shared.icon(forFile: url.path))
    }

    func isRunning(_ id: String) -> Bool { running.contains { $0.bundleIdentifier == id } }

    func activate(_ item: ApplicationItem, window: TaskbarWindow? = nil) {
        recentIDs.removeAll { $0 == item.id }
        recentIDs.insert(item.id, at: 0)
        recentIDs = Array(recentIDs.prefix(6))
        if let app = running.first(where: { window?.processID == $0.processIdentifier }) {
            app.unhide()
            app.activate(options: [])
            if let window { TaskbarWindowActivation.raise(window) }
        } else if let app = running.first(where: { $0.bundleIdentifier == item.id }) {
            app.unhide()
            app.activate(options: [.activateAllWindows])
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: item.url, configuration: configuration) { [weak self] _, error in
                guard let error else { return }
                Task { @MainActor in self?.launchError = "Couldn’t open \(item.name): \(error.localizedDescription)" }
            }
        }
    }

    func quit(_ item: ApplicationItem) { running.first { $0.bundleIdentifier == item.id }?.terminate() }
    func reveal(_ item: ApplicationItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    func showDesktop() {
        if !hiddenApplications.isEmpty {
            hiddenApplications.filter { !$0.isTerminated }.forEach { $0.unhide() }
            previousFrontmost?.activate(options: [])
            hiddenApplications = []
            previousFrontmost = nil
        } else {
            previousFrontmost = NSWorkspace.shared.frontmostApplication
            hiddenApplications = running.filter { !$0.isHidden && $0.bundleIdentifier != "com.apple.finder" }
            hiddenApplications.forEach { $0.hide() }
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate(options: [])
        }
    }

    private func item(from app: NSRunningApplication) -> ApplicationItem? {
        guard let id = app.bundleIdentifier, let url = app.bundleURL else { return nil }
        return ApplicationItem(id: id, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                               url: url, icon: app.icon ?? NSWorkspace.shared.icon(forFile: url.path))
    }
}
