import Foundation

/// All rectangles here use Accessibility coordinates: global origin at the main
/// display's top-left, with Y increasing downwards. These are points, not pixels.
struct WindowFitContext: Equatable {
    let screen: CGRect
    let workArea: CGRect
    let taskbar: CGRect
}

struct WindowAdjustment {
    let original: CGRect
    let adjusted: CGRect
    let context: WindowFitContext
}

enum WindowFitGeometry {
    static func accessibilityFrame(from appKitFrame: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: appKitFrame.minX, y: primaryScreenTop - appKitFrame.maxY,
               width: appKitFrame.width, height: appKitFrame.height)
    }

    static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 1.5) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance &&
        abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }

    static func adjustment(for current: CGRect, context: WindowFitContext,
                           previous: WindowAdjustment? = nil, isFullScreen: Bool = false,
                           isMinimized: Bool = false, isStandardWindow: Bool = true) -> WindowAdjustment? {
        guard !isFullScreen, !isMinimized, isStandardWindow else { return nil }

        var original = current
        // Only expand windows we previously fitted when the taskbar gets shorter.
        // A manual resize breaks this link, so ordinary windows stay untouched.
        if let previous, approximatelyEqual(current, previous.adjusted),
           previous.context.screen == context.screen, previous.context.workArea == context.workArea {
            original = previous.original
        }
        guard let target = constrainedMaximizedFrame(original, context: context),
              !approximatelyEqual(current, target, tolerance: 0.5) else { return nil }
        return WindowAdjustment(original: original, adjusted: target, context: context)
    }

    private static func constrainedMaximizedFrame(_ frame: CGRect, context: WindowFitContext) -> CGRect? {
        let screen = context.screen
        let work = context.workArea
        let bar = context.taskbar
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0, !screen.isEmpty, !work.isEmpty, !bar.isEmpty else { return nil }

        let tolerance: CGFloat = 16
        func spansWidth(_ reference: CGRect) -> Bool {
            abs(frame.minX - reference.minX) <= tolerance && abs(frame.maxX - reference.maxX) <= tolerance
        }
        // Accept normal maximization and shortcuts that use the entire display.
        guard spansWidth(work) || spansWidth(screen),
              frame.minY >= screen.minY - tolerance,
              frame.minY <= work.minY + tolerance,
              frame.maxY <= screen.maxY + tolerance,
              frame.maxY > bar.minY + 0.5,
              frame.maxY >= work.maxY - tolerance else { return nil }

        let height = bar.minY - frame.minY
        guard height >= 120 else { return nil }
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: height)
    }
}
