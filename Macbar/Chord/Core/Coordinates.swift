import CoreGraphics

public enum Coordinates {
    /// Converts a Cocoa rect (origin at the primary display's bottom-left, y up) to the
    /// Accessibility space (origin at the primary display's top-left, y down).
    public static func toAX(_ rect: CGRect, primaryHeight: Double) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
