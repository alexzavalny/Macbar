import AppKit
import ApplicationServices
import Combine

@MainActor
final class WindowManagementStore: ObservableObject {
    @Published private(set) var hasAccessibilityAccess = AXIsProcessTrusted()

    private let preferences: Preferences
    private let worker = WindowFitWorker()
    private var timer: Timer?
    private var observations = Set<AnyCancellable>()
    private var taskbarFrame: CGRect?

    init(preferences: Preferences) { self.preferences = preferences }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.didActivateApplicationNotification,
                             NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            center.publisher(for: notification).sink { [weak self] _ in self?.refresh() }.store(in: &observations)
        }
        center.publisher(for: NSWorkspace.didTerminateApplicationNotification).sink { [weak self] notification in
            if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.worker.forget(processID: application.processIdentifier)
            }
        }.store(in: &observations)
        // Notifications handle prompt adjustment. The timer notices newly granted
        // permission and covers applications that omit AX resize notifications.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    deinit { timer?.invalidate() }

    func updateTaskbar(frame: CGRect?) {
        taskbarFrame = frame
        refresh()
    }

    func requestAccessibilityAccess() {
        NSApp.activate(ignoringOtherApps: true)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        refresh()
    }

    private func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != hasAccessibilityAccess { hasAccessibilityAccess = trusted }
        guard preferences.keepWindowsAboveTaskbar, trusted, let taskbarFrame,
              let screen = NSScreen.screens.first,
              let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            worker.configure(processID: nil, context: nil,
                             forgetAdjustments: !preferences.keepWindowsAboveTaskbar || !trusted || taskbarFrame == nil)
            return
        }
        let primaryTop = screen.frame.maxY
        let context = WindowFitContext(
            screen: WindowFitGeometry.accessibilityFrame(from: screen.frame, primaryScreenTop: primaryTop),
            workArea: WindowFitGeometry.accessibilityFrame(from: screen.visibleFrame, primaryScreenTop: primaryTop),
            taskbar: WindowFitGeometry.accessibilityFrame(from: taskbarFrame, primaryScreenTop: primaryTop))
        worker.configure(processID: app.processIdentifier, context: context)
    }
}

/// AX communication stays off the main thread: an unresponsive application must
/// never stall Macbar's launcher, volume slider, or settings.
private final class WindowFitWorker {
    private struct ManagedWindow {
        let element: AXUIElement
        var adjustment: WindowAdjustment
    }
    private struct ResizeAttempt {
        let element: AXUIElement
        let observed: CGRect
        let requested: CGRect
    }

    private let queue = DispatchQueue(label: "studio.macbar.window-fitting", qos: .userInitiated)
    private var processID: pid_t?
    private var context: WindowFitContext?
    private var application: AXUIElement?
    private var observer: AXObserver?
    private var observedWindows: [AXUIElement] = []
    private var managed: [pid_t: [ManagedWindow]] = [:]
    private var attempts: [ResizeAttempt] = []
    private var pendingCheck: DispatchWorkItem?

    func configure(processID: pid_t?, context: WindowFitContext?, forgetAdjustments: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            if forgetAdjustments { self.managed = [:]; self.attempts = [] }
            if self.processID != processID || self.context != context {
                if self.processID != processID { self.detachObserver() }
                self.processID = processID
                self.context = context
                self.attempts = []
                if processID != nil && self.application == nil { self.attachObserver() }
            }
            self.scheduleCheckOnQueue()
        }
    }

    func forget(processID: pid_t) {
        queue.async { [weak self] in self?.managed.removeValue(forKey: processID) }
    }

    fileprivate func scheduleCheck() {
        queue.async { [weak self] in self?.scheduleCheckOnQueue() }
    }

    private func scheduleCheckOnQueue() {
        pendingCheck?.cancel()
        guard processID != nil, context != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.inspectFocusedWindow() }
        pendingCheck = work
        queue.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
    }

    private func attachObserver() {
        guard let processID else { return }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.2)
        application = app
        var created: AXObserver?
        let result = AXObserverCreate(processID, { _, _, _, reference in
            guard let reference else { return }
            Unmanaged<WindowFitWorker>.fromOpaque(reference).takeUnretainedValue().scheduleCheck()
        }, &created)
        guard result == .success, let created else { return }
        observer = created
        let reference = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(created, app, name as CFString, reference)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    private func detachObserver() {
        pendingCheck?.cancel()
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        observedWindows = []
        application = nil
    }

    private func inspectFocusedWindow() {
        guard let application, let processID, let context else { return }
        // Don't fight a user's in-progress drag. Check once the mouse is released.
        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            scheduleCheckOnQueue()
            return
        }
        guard let windowValue = attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return }
        let window = windowValue as! AXUIElement
        guard boolAttribute(application, kAXFrontmostAttribute) == true,
              let frame = readFrame(window) else { return }
        observe(window)

        guard let fullScreen = boolAttribute(window, "AXFullScreen"),
              let minimized = boolAttribute(window, kAXMinimizedAttribute),
              let subrole = attribute(window, kAXSubroleAttribute) as? String,
              subrole == kAXStandardWindowSubrole as String else { return }
        let previous = managed[processID]?.first { CFEqual($0.element, window) }?.adjustment

        if let last = attempts.first(where: { CFEqual($0.element, window) }) {
            if WindowFitGeometry.approximatelyEqual(frame, last.requested) {
                attempts.removeAll { CFEqual($0.element, window) }
            } else if WindowFitGeometry.approximatelyEqual(frame, last.observed) {
                // This app rejected/clamped the last request. Leave it alone until
                // its bounds or the taskbar configuration actually change.
                return
            } else { attempts.removeAll { CFEqual($0.element, window) } }
        }

        guard let adjustment = WindowFitGeometry.adjustment(for: frame, context: context, previous: previous,
                                                            isFullScreen: fullScreen, isMinimized: minimized) else {
            if let previous, !WindowFitGeometry.approximatelyEqual(frame, previous.adjusted) {
                managed[processID]?.removeAll { CFEqual($0.element, window) }
            }
            return
        }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return }

        attempts.removeAll { CFEqual($0.element, window) }
        attempts.append(ResizeAttempt(element: window, observed: frame, requested: adjustment.adjusted))
        attempts = Array(attempts.suffix(32))
        var size = adjustment.adjusted.size
        guard let value = AXValueCreate(.cgSize, &size),
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success else { return }

        // Some apps anchor a resize at another corner. Preserve the original top-left.
        if let actual = readFrame(window) {
            if abs(actual.minX - frame.minX) > 1 || abs(actual.minY - frame.minY) > 1 {
                var position = frame.origin
                if let positionValue = AXValueCreate(.cgPoint, &position) {
                    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
                }
            }
            if WindowFitGeometry.approximatelyEqual(actual, adjustment.adjusted) {
                attempts.removeAll { CFEqual($0.element, window) }
            }
        }
        var entries = managed[processID] ?? []
        entries.removeAll { CFEqual($0.element, window) }
        entries.append(ManagedWindow(element: window, adjustment: adjustment))
        managed[processID] = Array(entries.suffix(32))
        // Read back after apps have completed their own resize processing.
        scheduleCheckOnQueue()
    }

    private func observe(_ window: AXUIElement) {
        guard let observer, !observedWindows.contains(where: { CFEqual($0, window) }) else { return }
        AXUIElementSetMessagingTimeout(window, 0.2)
        let reference = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXMovedNotification, kAXResizedNotification] {
            AXObserverAddNotification(observer, window, name as CFString, reference)
        }
        observedWindows.append(window)
        // Bound registrations even for apps that keep creating transient windows.
        if observedWindows.count > 32 {
            let old = observedWindows.removeFirst()
            for name in [kAXMovedNotification, kAXResizedNotification] {
                AXObserverRemoveNotification(observer, old, name as CFString)
            }
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? { attribute(element, name) as? Bool }

    private func readFrame(_ window: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(window, kAXPositionAttribute),
              let sizeValue = attribute(window, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
