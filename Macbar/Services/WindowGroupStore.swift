import AppKit
import ApplicationServices
import Combine

struct WindowGroupMember {
    let tile: TaskbarTile
    let processID: pid_t
    let element: AXUIElement
}

struct WindowGroup: Identifiable {
    let id = UUID()
    let first: WindowGroupMember
    let second: WindowGroupMember

    func contains(_ tile: TaskbarTile) -> Bool {
        [first, second].contains { member in
            if let element = tile.window?.element { return CFEqual(element, member.element) }
            return tile.app.id == member.tile.app.id
        }
    }
}

enum WindowGroupGeometry {
    static func frames(workArea: CGRect, taskbar: CGRect?) -> (full: CGRect, left: CGRect, right: CGRect) {
        var area = workArea
        if let taskbar, area.intersects(taskbar), taskbar.minY > area.minY {
            area.size.height = min(area.maxY, taskbar.minY) - area.minY
        }
        let leftWidth = floor(area.width / 2)
        return (area, CGRect(x: area.minX, y: area.minY, width: leftWidth, height: area.height),
                CGRect(x: area.minX + leftWidth, y: area.minY, width: area.width - leftWidth, height: area.height))
    }
}

@MainActor
final class WindowGroupStore: ObservableObject {
    @Published private(set) var groups: [WindowGroup] = []
    @Published var error: String?
    private var first: (tile: TaskbarTile, task: Task<WindowGroupMember?, Never>)?
    private var checkingWindows = false
    private let queue = DispatchQueue(label: "studio.macbar.window-group", qos: .userInitiated)

    func endGesture() { first = nil }

    func group(for tile: TaskbarTile) -> WindowGroup? { groups.first { $0.contains(tile) } }
    func ungroup(_ group: WindowGroup) { groups.removeAll { $0.id == group.id } }
    func prune(running: [NSRunningApplication]) {
        let pids = Set(running.map(\.processIdentifier))
        groups.removeAll { !pids.contains($0.first.processID) || !pids.contains($0.second.processID) }
    }

    func validateWindows() {
        guard !checkingWindows, !groups.isEmpty else { return }
        checkingWindows = true
        let current = groups
        Task {
            let closed: [UUID] = await withCheckedContinuation { continuation in
                queue.async {
                    let ids = current.filter { group in
                        [group.first, group.second].contains { member in
                            var value: CFTypeRef?
                            AXUIElementSetMessagingTimeout(member.element, 0.2)
                            return AXUIElementCopyAttributeValue(member.element, kAXRoleAttribute as CFString, &value) == .invalidUIElement
                        }
                    }.map(\.id)
                    continuation.resume(returning: ids)
                }
            }
            groups.removeAll { closed.contains($0.id) }
            checkingWindows = false
        }
    }

    func click(_ tile: TaskbarTile, screen: NSScreen, taskbar: CGRect?, applications: ApplicationStore) {
        guard AXIsProcessTrusted() else {
            error = "Allow Macbar in System Settings → Privacy & Security → Accessibility to arrange windows."
            return
        }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let work = WindowFitGeometry.accessibilityFrame(from: screen.visibleFrame, primaryScreenTop: primaryTop)
        let bar = taskbar.map { WindowFitGeometry.accessibilityFrame(from: $0, primaryScreenTop: primaryTop) }
        let frames = WindowGroupGeometry.frames(workArea: work, taskbar: bar)
        if let previous = first {
            first = nil
            guard previous.tile.id != tile.id else { return }
            let secondTask = resolve(tile, applications: applications)
            Task {
                guard let one = await previous.task.value, let two = await secondTask.value else { return }
                guard !CFEqual(one.element, two.element) else { return }
                let success = await arrange([(one, frames.left), (two, frames.right)])
                guard success else {
                    _ = await arrange([(one, frames.full)])
                    error = "Couldn’t split these windows. One of the apps may not allow the requested size."
                    return
                }
                groups.removeAll { $0.contains(previous.tile) || $0.contains(tile) }
                groups.append(WindowGroup(first: one, second: two))
                raise([one, two])
            }
        } else {
            groups.removeAll { $0.contains(tile) }
            let task = resolve(tile, applications: applications, target: frames.full)
            first = (tile, task)
        }
    }

    private func resolve(_ tile: TaskbarTile, applications: ApplicationStore, target: CGRect? = nil) -> Task<WindowGroupMember?, Never> {
        Task {
            applications.activate(tile.app, window: tile.window)
            var process = tile.window.flatMap { NSRunningApplication(processIdentifier: $0.processID) }
                ?? applications.running.first { $0.bundleIdentifier == tile.app.id }
            for _ in 0..<30 where process == nil {
                try? await Task.sleep(for: .milliseconds(100))
                process = NSRunningApplication.runningApplications(withBundleIdentifier: tile.app.id).first
            }
            guard let process else { error = "Couldn’t open \(tile.app.name)."; return nil }
            let member: WindowGroupMember? = await withCheckedContinuation { continuation in
                queue.async {
                    let app = AXUIElementCreateApplication(process.processIdentifier)
                    AXUIElementSetMessagingTimeout(app, 0.3)
                    var element = tile.window?.element
                    for _ in 0..<30 where element == nil {
                        element = Self.window(app)
                        if element == nil { Thread.sleep(forTimeInterval: 0.1) }
                    }
                    continuation.resume(returning: element.map { WindowGroupMember(tile: tile, processID: process.processIdentifier, element: $0) })
                }
            }
            guard let member else { error = "Couldn’t find a window for \(tile.app.name)."; return nil }
            if let target, !(await arrange([(member, target)])) {
                error = "Couldn’t resize the window for \(tile.app.name). It may be in macOS full screen or refuse resizing."
                return nil
            }
            return member
        }
    }

    nonisolated private static func window(_ app: AXUIElement) -> AXUIElement? {
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, name as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() { return (value as! AXUIElement) }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { window in
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            return (subrole as? String) == kAXStandardWindowSubrole as String
        }
    }

    private func arrange(_ requests: [(WindowGroupMember, CGRect)]) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                var succeeded = true
                for (member, frame) in requests {
                    let window = member.element
                    AXUIElementSetMessagingTimeout(window, 0.3)
                    var fullScreen: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen)
                    if (fullScreen as? Bool) == true { succeeded = false; continue }
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    var position = frame.origin
                    var size = frame.size
                    guard let point = AXValueCreate(.cgPoint, &position), let dimensions = AXValueCreate(.cgSize, &size),
                          AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, point) == .success,
                          AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions) == .success else { succeeded = false; continue }
                    // Some applications anchor their resize; set the origin again.
                    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, point)
                    var actualPosition: CFTypeRef?
                    var actualSize: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &actualPosition) == .success,
                          AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &actualSize) == .success,
                          let actualPosition, let actualSize, CFGetTypeID(actualPosition) == AXValueGetTypeID(),
                          CFGetTypeID(actualSize) == AXValueGetTypeID() else { succeeded = false; continue }
                    var p = CGPoint.zero; var s = CGSize.zero
                    guard AXValueGetValue(actualPosition as! AXValue, .cgPoint, &p),
                          AXValueGetValue(actualSize as! AXValue, .cgSize, &s),
                          WindowFitGeometry.approximatelyEqual(CGRect(origin: p, size: s), frame, tolerance: 3) else { succeeded = false; continue }
                }
                continuation.resume(returning: succeeded)
            }
        }
    }

    func activate(_ group: WindowGroup) { raise([group.first, group.second]) }
    private func raise(_ members: [WindowGroupMember]) {
        Task {
            for member in members {
                let application = NSRunningApplication(processIdentifier: member.processID)
                application?.unhide()
                application?.activate(options: [])
                await withCheckedContinuation { continuation in
                    queue.async {
                        let window = member.element
                        let app = AXUIElementCreateApplication(member.processID)
                        AXUIElementSetMessagingTimeout(window, 0.3)
                        AXUIElementSetMessagingTimeout(app, 0.3)
                        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
                        continuation.resume()
                    }
                }
            }
        }
    }
}
