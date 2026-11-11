import AppKit
import ApplicationServices

// AXUIElement is an immutable CF reference; the AX API is safe to call with it from the main thread.
extension AXUIElement: @retroactive @unchecked Sendable {}

/// Thin wrappers over the Accessibility C API.
enum AX {
    static let messagingTimeout: Float = 0.25

    static func appElement(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }

    /// The app's standard windows, the one to tile first leading: the focused one, the main
    /// one, then the rest in AX order, unminimized before minimized.
    static func orderedWindows(of pid: pid_t) -> [AXUIElement] {
        let app = appElement(pid)
        let all = windows(of: pid).filter(isStandard)
        let lead = [element(app, kAXFocusedWindowAttribute), element(app, kAXMainWindowAttribute)]
            .compactMap { $0 }.filter(isStandard)
        var ordered: [AXUIElement] = []
        for w in lead + all.filter({ !isMinimized($0) }) + all.filter(isMinimized) where !ordered.contains(w) {
            ordered.append(w)
        }
        return ordered
    }

    /// False once the window is gone (closed, or its app quit). A busy app counts as there.
    static func exists(_ w: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(w, kAXRoleAttribute as CFString, &value) != .invalidUIElement
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        copy(appElement(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    static func frame(_ w: AXUIElement) -> CGRect? {
        guard let p = axValue(w, kAXPositionAttribute), let s = axValue(w, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &origin), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func isStandard(_ w: AXUIElement) -> Bool {
        copy(w, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
    }

    static func isMinimized(_ w: AXUIElement) -> Bool {
        copy(w, kAXMinimizedAttribute) as? Bool == true
    }

    static func setMinimized(_ w: AXUIElement, _ on: Bool) {
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, cfBool(on))
    }

    static func isFullScreen(_ w: AXUIElement) -> Bool {
        copy(w, "AXFullScreen") as? Bool == true
    }

    static func setFullScreen(_ w: AXUIElement, _ on: Bool) {
        AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, cfBool(on))
    }

    /// Size is set before and after the move because macOS limits size to the space
    /// available at the window's current position. Apps with AXEnhancedUserInterface on
    /// (set by assistive tools) animate every change, so it is off while we move.
    static func setFrame(_ w: AXUIElement, _ f: CGRect, pid: pid_t) {
        let app = appElement(pid)
        let enhanced = copy(app, "AXEnhancedUserInterface") as? Bool == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer {
            if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        }
        // A hung app fails the first call; don't spend two more timeouts on it.
        guard set(w, kAXSizeAttribute, size: f.size) != .cannotComplete else { return }
        _ = set(w, kAXPositionAttribute, point: f.origin)
        _ = set(w, kAXSizeAttribute, size: f.size)
    }

    static func raise(_ w: AXUIElement) {
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    }

    @MainActor
    static func focus(_ w: AXUIElement, pid: pid_t) {
        raise(w)
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        // Works even when activate() is not honoured for a background (accessory) caller.
        AXUIElementSetAttributeValue(appElement(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = NSRunningApplication(processIdentifier: pid)?.activate()
    }

    // MARK: - Private

    private static func cfBool(_ on: Bool) -> CFBoolean {
        on ? kCFBooleanTrue! : kCFBooleanFalse!
    }

    private static func axValue(_ el: AXUIElement, _ attribute: String) -> AXValue? {
        guard let v = copy(el, attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(v, to: AXValue.self)
    }

    private static func copy(_ el: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ el: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = copy(el, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(v, to: AXUIElement.self)
    }

    private static func set(_ w: AXUIElement, _ attribute: String, point: CGPoint) -> AXError {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return .failure }
        return AXUIElementSetAttributeValue(w, attribute as CFString, v)
    }

    private static func set(_ w: AXUIElement, _ attribute: String, size: CGSize) -> AXError {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return .failure }
        return AXUIElementSetAttributeValue(w, attribute as CFString, v)
    }
}
