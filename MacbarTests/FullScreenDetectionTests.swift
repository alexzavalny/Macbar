import XCTest
@testable import Macbar

final class FullScreenDetectionTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testFullScreenAndNormalWindows() {
        XCTAssertTrue(FullScreenDetection.isCovered(display: display, windows: [display]))
        XCTAssertFalse(FullScreenDetection.isCovered(display: display, windows: [CGRect(x: 0, y: 25, width: 1440, height: 875)]))
        XCTAssertFalse(FullScreenDetection.isCovered(display: display, windows: []))
    }

    func testFloatingWindowDoesNotRevealBarOverVideo() {
        let floating = CGRect(x: 100, y: 100, width: 250, height: 200)
        XCTAssertTrue(FullScreenDetection.isCovered(display: display, windows: [floating, display]))
    }

    func testForemostLargeWindowAndOtherDisplay() {
        let ordinary = CGRect(x: 0, y: 25, width: 1440, height: 875)
        XCTAssertFalse(FullScreenDetection.isCovered(display: display, windows: [ordinary, display]))
        XCTAssertFalse(FullScreenDetection.isCovered(display: display, windows: [display.offsetBy(dx: 1440, dy: 0)]))
        let offset = display.offsetBy(dx: -1440, dy: 300)
        XCTAssertTrue(FullScreenDetection.isCovered(display: offset, windows: [offset]))
    }
}
