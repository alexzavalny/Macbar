import CoreGraphics
import Testing
@testable import Macbar

// Primary display 1440×900 (Cocoa: origin bottom-left, y up).
@Suite struct CocoaToAX {
    @Test func primaryVisibleFrameBelowMenuBar() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        #expect(Coordinates.toAX(visible, primaryHeight: 900) == CGRect(x: 0, y: 25, width: 1440, height: 875))
    }

    @Test func displayAbovePrimaryHasNegativeY() {
        let above = CGRect(x: 0, y: 900, width: 1920, height: 1055)
        #expect(Coordinates.toAX(above, primaryHeight: 900) == CGRect(x: 0, y: -1055, width: 1920, height: 1055))
    }

    @Test func displayLeftOfPrimaryKeepsNegativeX() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        #expect(Coordinates.toAX(left, primaryHeight: 900) == CGRect(x: -1920, y: -180, width: 1920, height: 1080))
    }
}
