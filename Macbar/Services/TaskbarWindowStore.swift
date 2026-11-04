import AppKit
@preconcurrency import ApplicationServices
import Combine

struct TaskbarWindowProcess {
    let id: pid_t
    let bundleID: String
}

protocol TaskbarWindowProviding {
    func windows(for processes: [TaskbarWindowProcess], frontmostPID: pid_t?) async -> [TaskbarWindow]
}

@MainActor
final class TaskbarWindowStore: ObservableObject {
    @Published private(set) var windows: [TaskbarWindow] = []
    @Published private(set) var hasWindowAccess = false
    @Published private(set) var placement = AppDisplayPlacement()
    private let provider: TaskbarWindowProviding
    private let hasAccess: () -> Bool
    private let visibility: @Sendable () -> WindowVisibilitySnapshot
    private var task: Task<Void, Never>?
    private var placementTask: Task<Void, Never>?
    private var generation = UUID()

    init(provider: TaskbarWindowProviding = AccessibilityTaskbarWindowProvider(),
         hasAccess: @escaping () -> Bool = { AXIsProcessTrusted() },
         visibility: @escaping @Sendable () -> WindowVisibilitySnapshot = WindowVisibilitySnapshot.current) {
        self.provider = provider
        self.hasAccess = hasAccess
        self.visibility = visibility
    }

    func refreshPlacement(processes: [TaskbarWindowProcess]) {
        guard placementTask == nil else { return }
        placementTask = Task { [weak self, visibility] in
            let snapshot = await Task.detached(priority: .userInitiated) { visibility() }.value
            guard let self else { return }
            let next = snapshot.placement(for: processes)
            if placement != next { placement = next }
            placementTask = nil
        }
    }

    func refresh(processes: [TaskbarWindowProcess], frontmostPID: pid_t?, enabled: Bool) {
        let allowed = hasAccess()
        if hasWindowAccess != allowed { hasWindowAccess = allowed }
        guard enabled, allowed else { clear(); return }
        guard task == nil else { return }
        let request = generation
        task = Task { [weak self] in
            guard let self else { return }
            let result = await provider.windows(for: processes, frontmostPID: frontmostPID)
            guard !Task.isCancelled, generation == request else { return }
            if windows != result { windows = result }
            task = nil
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        generation = UUID()
        if !windows.isEmpty { windows = [] }
    }
}

/// Window titles and minimized windows come from Accessibility; no screenshots or
/// Screen Recording grant are needed. Slow applications never block the bar's UI.
final class AccessibilityTaskbarWindowProvider: TaskbarWindowProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "studio.macbar.window-tiles", qos: .userInitiated)
    private var known: [pid_t: [(element: AXUIElement, id: UUID)]] = [:]
    private var snapshots: [pid_t: [TaskbarWindow]] = [:]
    private let readAttribute: (AXUIElement, String) -> CFTypeRef?
    private let visibility: () -> WindowVisibilitySnapshot

    init(visibility: @escaping () -> WindowVisibilitySnapshot = WindowVisibilitySnapshot.current,
         readAttribute: @escaping (AXUIElement, String) -> CFTypeRef? = AccessibilityTaskbarWindowProvider.systemAttribute) {
        self.visibility = visibility
        self.readAttribute = readAttribute
    }

    func windows(for processes: [TaskbarWindowProcess], frontmostPID: pid_t?) async -> [TaskbarWindow] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let visibleWindows = visibility()
                var next: [pid_t: [(element: AXUIElement, id: UUID)]] = [:]
                var result: [TaskbarWindow] = []
                for process in processes {
                    let application = AXUIElementCreateApplication(process.id)
                    AXUIElementSetMessagingTimeout(application, 0.3)
                    guard var elements = readAttribute(application, kAXWindowsAttribute) as? [AXUIElement] else {
                        // An app can stop answering briefly during a minimize animation.
                        // Keep its last tiles until it responds, rather than losing their identities.
                        next[process.id] = known[process.id]
                        result += (snapshots[process.id] ?? []).map { window in
                            var retained = window
                            if process.id != frontmostPID { retained.isFocused = false }
                            retained.isOnScreen = visibleWindows.isOnScreen(processID: retained.processID,
                                title: retained.title, frame: retained.frame)
                            return retained
                        }
                        continue
                    }
                    // Some apps omit minimized windows from AXWindows. Their retained
                    // AX elements still report AXMinimized; closed windows do not.
                    for previous in known[process.id] ?? [] where !elements.contains(where: { CFEqual($0, previous.element) }) {
                        let minimized = readAttribute(previous.element, kAXMinimizedAttribute) as? Bool
                        if minimized == true {
                            elements.append(previous.element)
                        }
                    }
                    let focused = process.id == frontmostPID ? readAttribute(application, kAXFocusedWindowAttribute) : nil
                    for element in elements {
                        let subrole = readAttribute(element, kAXSubroleAttribute) as? String
                        let minimized = readAttribute(element, kAXMinimizedAttribute) as? Bool
                        // Finder reports AXDialog for a minimized normal window.
                        guard subrole == nil || subrole == kAXStandardWindowSubrole as String || minimized == true else { continue }
                        let id = known[process.id]?.first { CFEqual($0.element, element) }?.id ?? UUID()
                        let previous = snapshots[process.id]?.first { $0.id == id }
                        next[process.id, default: []].append((element, id))
                        // Minimized windows stay on the display that held their normal frame.
                        let frame = minimized == true ? (previous?.frame ?? readFrame(element)) : (readFrame(element) ?? previous?.frame)
                        let title = readAttribute(element, kAXTitleAttribute) as? String ?? previous?.title ?? ""
                        result.append(TaskbarWindow(id: id, bundleID: process.bundleID, processID: process.id,
                            title: title,
                            isMinimized: minimized ?? previous?.isMinimized ?? false,
                            isFocused: process.id == frontmostPID && focused.map { CFEqual($0, element) } == true,
                            element: element, frame: frame,
                            isOnScreen: visibleWindows.isOnScreen(processID: process.id, title: title, frame: frame)))
                    }
                }
                // AX window arrays often reorder on focus changes. Keep tile positions stable.
                let order = Dictionary(uniqueKeysWithValues: processes.flatMap { known[$0.id] ?? [] }.enumerated().map { ($0.element.id, $0.offset) })
                result.sort { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
                for process in processes {
                    next[process.id]?.sort { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
                }
                known = next
                snapshots = Dictionary(grouping: result, by: \.processID)
                continuation.resume(returning: result)
            }
        }
    }

    private func readFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = readAttribute(element, kAXPositionAttribute),
              let sizeValue = readAttribute(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func systemAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

enum TaskbarWindowActivation {
    enum ClickResult {
        case minimized, restore
        case failed(String)
    }

    private static let queue = DispatchQueue(label: "studio.macbar.window-activation", qos: .userInitiated)

    static func click(_ window: TaskbarWindow) async -> ClickResult {
        guard AXIsProcessTrusted() else {
            return .failed("Allow Macbar in System Settings → Privacy & Security → Accessibility to minimize and restore windows.")
        }
        guard let element = window.element else { return .failed("This window is no longer available.") }
        return await withCheckedContinuation { continuation in
            queue.async {
                let application = AXUIElementCreateApplication(window.processID)
                AXUIElementSetMessagingTimeout(application, 0.2)
                AXUIElementSetMessagingTimeout(element, 0.2)
                var minimized: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized) == .success else {
                    continuation.resume(returning: .failed("Couldn’t read this window. It may have closed or stopped responding."))
                    return
                }
                var frontmost: CFTypeRef?
                var focused: CFTypeRef?
                AXUIElementCopyAttributeValue(application, kAXFrontmostAttribute as CFString, &frontmost)
                AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused)
                // Recheck the live AX state: the tile snapshot may predate the last click.
                if minimized as? Bool == false, frontmost as? Bool == true,
                   let focused, CFEqual(focused, element) {
                    let result = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                    continuation.resume(returning: result == .success ? .minimized :
                        .failed("Couldn’t minimize this window. The app may not support minimizing it."))
                } else {
                    continuation.resume(returning: .restore)
                }
            }
        }
    }

    static func raise(_ window: TaskbarWindow) {
        guard AXIsProcessTrusted(), let element = window.element else { return }
        queue.async {
            AXUIElementSetMessagingTimeout(element, 0.2)
            let application = AXUIElementCreateApplication(window.processID)
            AXUIElementSetMessagingTimeout(application, 0.2)
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, element)
        }
    }
}

/// The window server supplies Space visibility without requesting Screen Recording.
/// AX supplies titles even when the window-server title is redacted. Match all
/// windows before checking visibility so a window on another Space at the same
/// bounds cannot be mistaken for a visible one.
struct WindowVisibilitySnapshot: Sendable {
    struct Window: Sendable {
        let processID: pid_t
        let title: String?
        let frame: CGRect
        let isOnScreen: Bool
    }
    let windows: [Window]

    func isOnScreen(processID: pid_t, title: String, frame: CGRect?) -> Bool {
        guard let frame else { return false }
        var matches = windows.filter {
            $0.processID == processID && WindowFitGeometry.approximatelyEqual($0.frame, frame, tolerance: 3)
        }
        let titled = matches.filter { $0.title == title }
        if !titled.isEmpty { matches = titled }
        // With redacted titles and identical bounds across Spaces, prefer omitting
        // an ambiguous tile to showing a window from a different desktop.
        return !matches.isEmpty && matches.allSatisfy(\.isOnScreen)
    }

    func placement(for processes: [TaskbarWindowProcess]) -> AppDisplayPlacement {
        let bundleIDs = Dictionary(processes.map { ($0.id, $0.bundleID) }, uniquingKeysWith: { first, _ in first })
        var placement = AppDisplayPlacement()
        for window in windows where window.isOnScreen {
            guard let bundleID = bundleIDs[window.processID] else { continue }
            placement.framesByApp[bundleID, default: []].append(window.frame)
        }
        return placement
    }

    static func current() -> Self {
        let infos = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Self(windows: infos.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 1, frame.height > 1 else { return nil }
            return Window(processID: pid, title: info[kCGWindowName as String] as? String,
                          frame: frame, isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false)
        })
    }
}
