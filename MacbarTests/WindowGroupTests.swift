import XCTest
@testable import Macbar

final class WindowGroupTests: XCTestCase {
    func testSplitUsesUsableAreaAndExcludesTaskbar() {
        let result = WindowGroupGeometry.frames(workArea: CGRect(x: 20, y: 25, width: 1001, height: 775),
                                                taskbar: CGRect(x: 0, y: 740, width: 1200, height: 60))
        XCTAssertEqual(result.full, CGRect(x: 20, y: 25, width: 1001, height: 715))
        XCTAssertEqual(result.left, CGRect(x: 20, y: 25, width: 500, height: 715))
        XCTAssertEqual(result.right, CGRect(x: 520, y: 25, width: 501, height: 715))
    }

    func testTaskbarOnAnotherDisplayDoesNotChangeFrames() {
        let area = CGRect(x: -1200, y: 50, width: 1200, height: 800)
        let result = WindowGroupGeometry.frames(workArea: area, taskbar: CGRect(x: 0, y: 700, width: 1000, height: 50))
        XCTAssertEqual(result.full, area)
        XCTAssertEqual(result.left.union(result.right), area)
    }

    func testGroupedTilesStayTogetherInStripAndWhenMoved() {
        func app(_ id: String) -> ApplicationItem {
            ApplicationItem(id: id, name: id, url: URL(fileURLWithPath: "/tmp/\(id).app"), icon: NSImage())
        }
        let one = TaskbarTile(app: app("one"), window: nil)
        let two = TaskbarTile(app: app("two"), window: nil)
        let other = TaskbarTile(app: app("other"), window: nil)
        let first = AXUIElementCreateApplication(100001)
        let second = AXUIElementCreateApplication(100002)
        let group = WindowGroup(first: WindowGroupMember(tile: one, processID: 1, element: first),
                                second: WindowGroupMember(tile: two, processID: 2, element: second))
        let items = TaskbarStripItem.make(tiles: [one, other, two], groups: [group])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].tiles.map(\.id), [one.id, two.id])
        let moved = TaskbarStripItem.moving(items[0].id, relativeTo: items[1].id, after: true, in: items)
        XCTAssertEqual(moved.flatMap(\.tiles).map(\.id), [other.id, one.id, two.id])
    }

    func testGroupIsActiveForEitherMemberAndInactiveForOtherApps() {
        func app(_ id: String) -> ApplicationItem {
            ApplicationItem(id: id, name: id, url: URL(fileURLWithPath: "/tmp/\(id).app"), icon: NSImage())
        }
        let first = TaskbarTile(app: app("first"), window: nil)
        let second = TaskbarTile(app: app("second"), window: nil)
        let pair = TaskbarStripItem(tiles: [first, second], groupID: UUID())
        XCTAssertTrue(pair.isActive(activeID: "first"))
        XCTAssertTrue(pair.isActive(activeID: "second"))
        XCTAssertFalse(pair.isActive(activeID: "other"))
        XCTAssertFalse(pair.isActive(activeID: nil))
    }

    func testGroupWithIndividualWindowTilesUsesFocusedWindow() {
        let app = ApplicationItem(id: "editor", name: "Editor", url: URL(fileURLWithPath: "/tmp/editor.app"), icon: NSImage())
        func window(_ focused: Bool) -> TaskbarTile {
            TaskbarTile(app: app, window: TaskbarWindow(id: UUID(), bundleID: app.id, processID: 1,
                title: "Document", isMinimized: false, isFocused: focused))
        }
        let inactive = TaskbarStripItem(tiles: [window(false), window(false)], groupID: UUID())
        let active = TaskbarStripItem(tiles: [window(false), window(true)], groupID: UUID())
        XCTAssertFalse(inactive.isActive(activeID: app.id))
        XCTAssertTrue(active.isActive(activeID: app.id))
    }

    func testGroupedWidthIsNeverCompactedOrSplitByOverflow() {
        let layout = TaskbarStripLayout(screenWidth: 800, alignment: .left,
            preferredWidths: [120, 88] + Array(repeating: 200, count: 8), mode: .windows,
            titledTiles: [true, false] + Array(repeating: true, count: 8),
            iconWidths: [44, 88] + Array(repeating: 44, count: 8))
        XCTAssertGreaterThan(layout.capacity, 1)
        XCTAssertEqual(layout.tileWidths[1], 88)
        let overflow: CGFloat = layout.capacity < 10 ? 38 : 0
        XCTAssertLessThanOrEqual(layout.tilesWidth + layout.headerWidth + overflow, layout.availableWidth + 0.01)
    }

    func testWindowTilesMatchOnlyTheSelectedWindow() {
        let app = ApplicationItem(id: "editor", name: "Editor", url: URL(fileURLWithPath: "/tmp/editor.app"), icon: NSImage())
        let first = AXUIElementCreateApplication(100001)
        let second = AXUIElementCreateApplication(100002)
        let other = AXUIElementCreateApplication(100003)
        func tile(_ element: AXUIElement) -> TaskbarTile {
            TaskbarTile(app: app, window: TaskbarWindow(id: UUID(), bundleID: app.id, processID: 1,
                title: "", isMinimized: false, isFocused: false, element: element))
        }
        let a = tile(first), b = tile(second)
        let group = WindowGroup(first: WindowGroupMember(tile: a, processID: 1, element: first),
                                second: WindowGroupMember(tile: b, processID: 1, element: second))
        XCTAssertTrue(group.contains(a))
        XCTAssertTrue(group.contains(b))
        XCTAssertFalse(group.contains(tile(other)))
        XCTAssertTrue(group.contains(TaskbarTile(app: app, window: nil)))
    }
}
