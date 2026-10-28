import AppKit
import ApplicationServices
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
    private let provider: TaskbarWindowProviding
    private let hasAccess: () -> Bool
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(provider: TaskbarWindowProviding = AccessibilityTaskbarWindowProvider(),
         hasAccess: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.provider = provider
        self.hasAccess = hasAccess
    }

    func refresh(processes: [TaskbarWindowProcess], frontmostPID: pid_t?, enabled: Bool) {
        guard enabled, hasAccess() else { clear(); return }
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

    init(readAttribute: @escaping (AXUIElement, String) -> CFTypeRef? = AccessibilityTaskbarWindowProvider.systemAttribute) {
        self.readAttribute = readAttribute
    }

    func windows(for processes: [TaskbarWindowProcess], frontmostPID: pid_t?) async -> [TaskbarWindow] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
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
                        result.append(TaskbarWindow(id: id, bundleID: process.bundleID, processID: process.id,
                            title: readAttribute(element, kAXTitleAttribute) as? String ?? previous?.title ?? "",
                            isMinimized: minimized ?? previous?.isMinimized ?? false,
                            isFocused: process.id == frontmostPID && focused.map { CFEqual($0, element) } == true,
                            element: element))
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

    private static func systemAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

enum TaskbarWindowActivation {
    static func raise(_ window: TaskbarWindow) {
        guard AXIsProcessTrusted(), let element = window.element else { return }
        DispatchQueue.global(qos: .userInitiated).async {
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
