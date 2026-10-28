import XCTest
@testable import Macbar

final class WindowFitTests: XCTestCase {
    private let context = WindowFitContext(
        screen: CGRect(x: 0, y: 0, width: 1440, height: 900),
        workArea: CGRect(x: 0, y: 25, width: 1440, height: 875),
        taskbar: CGRect(x: 0, y: 846, width: 1440, height: 54))

    func testMaximizedWindowStopsExactlyAboveTaskbar() throws {
        let adjustment = try XCTUnwrap(WindowFitGeometry.adjustment(for: context.workArea, context: context))
        XCTAssertEqual(adjustment.adjusted, CGRect(x: 0, y: 25, width: 1440, height: 821))
        XCTAssertEqual(adjustment.original, context.workArea)
        XCTAssertEqual(adjustment.adjusted.maxY, context.taskbar.minY)
    }

    func testShortcutThatUsesEntireScreenPreservesTopAndWidth() throws {
        let adjusted = try XCTUnwrap(WindowFitGeometry.adjustment(for: context.screen, context: context)).adjusted
        XCTAssertEqual(adjusted.origin, context.screen.origin)
        XCTAssertEqual(adjusted.width, context.screen.width)
        XCTAssertEqual(adjusted.maxY, context.taskbar.minY)
    }

    func testSmallerAndTiledWindowsAreNotChangedEvenWhenOverlappingBar() {
        for window in [CGRect(x: 200, y: 200, width: 900, height: 700),
                       CGRect(x: 0, y: 25, width: 720, height: 875),
                       CGRect(x: 720, y: 25, width: 720, height: 875),
                       CGRect(x: 0, y: 200, width: 1440, height: 700)] {
            XCTAssertNil(WindowFitGeometry.adjustment(for: window, context: context))
        }
    }

    func testWindowOnOtherDisplayOrSpanningDisplaysIsNotChanged() {
        XCTAssertNil(WindowFitGeometry.adjustment(for: CGRect(x: 1440, y: 25, width: 1440, height: 875), context: context))
        XCTAssertNil(WindowFitGeometry.adjustment(for: CGRect(x: 0, y: 25, width: 2880, height: 875), context: context))
    }

    func testNativeFullScreenMinimizedAndDialogWindowsAreSkipped() {
        XCTAssertNil(WindowFitGeometry.adjustment(for: context.workArea, context: context, isFullScreen: true))
        XCTAssertNil(WindowFitGeometry.adjustment(for: context.workArea, context: context, isMinimized: true))
        XCTAssertNil(WindowFitGeometry.adjustment(for: context.workArea, context: context, isStandardWindow: false))
    }

    func testSystemDockAlreadyReservingEnoughRoomDoesNotLoseMoreSpace() {
        let dockWorkArea = CGRect(x: 0, y: 25, width: 1440, height: 795)
        let dockContext = WindowFitContext(screen: context.screen, workArea: dockWorkArea, taskbar: context.taskbar)
        XCTAssertNil(WindowFitGeometry.adjustment(for: dockWorkArea, context: dockContext))
    }

    func testSideDockWorkAreaKeepsItsHorizontalBounds() throws {
        let workArea = CGRect(x: 60, y: 25, width: 1380, height: 875)
        let dockContext = WindowFitContext(screen: context.screen, workArea: workArea, taskbar: context.taskbar)
        let adjusted = try XCTUnwrap(WindowFitGeometry.adjustment(for: workArea, context: dockContext)).adjusted
        XCTAssertEqual(adjusted.minX, 60)
        XCTAssertEqual(adjusted.width, 1380)
    }

    func testAdjustmentIsIdempotent() throws {
        let first = try XCTUnwrap(WindowFitGeometry.adjustment(for: context.workArea, context: context))
        XCTAssertNil(WindowFitGeometry.adjustment(for: first.adjusted, context: context))
        XCTAssertNil(WindowFitGeometry.adjustment(for: first.adjusted, context: context, previous: first))
    }

    func testCompactBarReturnsSpaceOnlyToPreviouslyManagedWindow() throws {
        let first = try XCTUnwrap(WindowFitGeometry.adjustment(for: context.workArea, context: context))
        let compact = WindowFitContext(screen: context.screen, workArea: context.workArea,
                                       taskbar: CGRect(x: 0, y: 854, width: 1440, height: 46))
        let second = try XCTUnwrap(WindowFitGeometry.adjustment(for: first.adjusted, context: compact, previous: first))
        XCTAssertEqual(second.adjusted.height, first.adjusted.height + 8)
        XCTAssertEqual(second.original, context.workArea)
        XCTAssertNil(WindowFitGeometry.adjustment(for: first.adjusted, context: compact))
    }

    func testManualResizeDoesNotGetExpandedBackToMaximized() throws {
        let first = try XCTUnwrap(WindowFitGeometry.adjustment(for: context.workArea, context: context))
        let manuallyResized = CGRect(x: 100, y: 100, width: 1000, height: 600)
        XCTAssertNil(WindowFitGeometry.adjustment(for: manuallyResized, context: context, previous: first))
    }

    func testCoordinateConversionUsesPrimaryTopWithoutRetinaScaling() {
        XCTAssertEqual(WindowFitGeometry.accessibilityFrame(from: CGRect(x: 0, y: 0, width: 1440, height: 54), primaryScreenTop: 900),
                       CGRect(x: 0, y: 846, width: 1440, height: 54))
        XCTAssertEqual(WindowFitGeometry.accessibilityFrame(from: CGRect(x: -1920, y: -1080, width: 1920, height: 1080), primaryScreenTop: 900),
                       CGRect(x: -1920, y: 900, width: 1920, height: 1080))
    }

    func testNegativeGlobalCoordinatesFitCorrectly() throws {
        let negative = WindowFitContext(screen: CGRect(x: -1920, y: -1080, width: 1920, height: 1080),
                                        workArea: CGRect(x: -1920, y: -1055, width: 1920, height: 1055),
                                        taskbar: CGRect(x: -1920, y: -54, width: 1920, height: 54))
        let adjusted = try XCTUnwrap(WindowFitGeometry.adjustment(for: negative.workArea, context: negative)).adjusted
        XCTAssertEqual(adjusted.origin, negative.workArea.origin)
        XCTAssertEqual(adjusted.maxY, -54)
    }

    func testInvalidFrameDoesNotProduceResize() {
        XCTAssertNil(WindowFitGeometry.adjustment(for: .infinite, context: context))
        XCTAssertNil(WindowFitGeometry.adjustment(for: .zero, context: context))
    }

    @MainActor
    func testWindowManagementDefaultsOnAndExplicitOffPersists() {
        let suite = "MacbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(preferences.keepWindowsAboveTaskbar)
        preferences.keepWindowsAboveTaskbar = false
        XCTAssertFalse(Preferences(defaults: defaults).keepWindowsAboveTaskbar)
    }
}
