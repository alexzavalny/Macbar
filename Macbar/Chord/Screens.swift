import AppKit

@MainActor
enum Screens {
    /// A display in AX coordinates: its ID, its whole frame, and the part the menu bar and Dock leave.
    struct Display: Equatable {
        let id: CGDirectDisplayID
        let frame: CGRect
        let visible: CGRect
    }

    /// Height at the bottom of every display that the taskbar covers; set by the app.
    static var bottomInset: () -> CGFloat = { 0 }

    /// The visible frame with the taskbar's strip taken off the bottom.
    private static func visible(_ screen: NSScreen) -> CGRect {
        var v = screen.visibleFrame
        let minY = max(v.minY, screen.frame.minY + bottomInset())
        v.size.height -= minY - v.minY
        v.origin.y = minY
        return v
    }

    /// Every display, the main one (with the menu bar) first.
    static func all() -> [Display] {
        guard let primary = NSScreen.screens.first else { return [] }
        let h = primary.frame.height
        return NSScreen.screens.map {
            Display(id: ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                    frame: Coordinates.toAX($0.frame, primaryHeight: h),
                    visible: Coordinates.toAX(visible($0), primaryHeight: h))
        }
    }

    /// The display under the mouse pointer (the main one if none contains it).
    static func underMouse() -> Display? {
        let mouse = NSEvent.mouseLocation
        let i = NSScreen.screens.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0
        let displays = all()
        return displays.indices.contains(i) ? displays[i] : nil
    }
}
