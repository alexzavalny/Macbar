import AppKit
import CoreGraphics

/// Window-list bounds use the same top-left coordinate system as display bounds.
enum FullScreenDetection {
    static func coversDisplay(_ window: CGRect, display: CGRect) -> Bool {
        guard !display.isEmpty, !window.isEmpty else { return false }
        let tolerance: CGFloat = 2
        return window.minX <= display.minX + tolerance && window.maxX >= display.maxX - tolerance &&
            window.minY <= display.minY + tolerance && window.maxY >= display.maxY - tolerance
    }

    static func isCovered(display: CGRect, windows: [CGRect]) -> Bool {
        // Ignore small floating windows over a video, but let a substantial window
        // in front of it determine the visible state of the display.
        guard let foremost = windows.first(where: {
            let intersection = $0.intersection(display)
            return !intersection.isNull && intersection.width >= display.width * 0.8 &&
                intersection.height >= display.height * 0.8
        }) else { return false }
        return coversDisplay(foremost, display: display)
    }

    static func isMainDisplayCovered() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frames = windows.compactMap { info -> CGRect? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer >= 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return frame
        }
        return isCovered(display: CGDisplayBounds(CGMainDisplayID()), windows: frames)
    }
}
