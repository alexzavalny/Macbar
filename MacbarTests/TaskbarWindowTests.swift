import XCTest
import ApplicationServices
@testable import Macbar

@MainActor
private final class TaskbarWindowProviderStub: TaskbarWindowProviding {
    var requests = 0
    var pending: [CheckedContinuation<[TaskbarWindow], Never>] = []
    func windows(for processes: [TaskbarWindowProcess], frontmostPID: pid_t?) async -> [TaskbarWindow] {
        requests += 1
        return await withCheckedContinuation { pending.append($0) }
    }
}

final class TaskbarWindowTests: XCTestCase {
    func testProviderRetainsOmittedMinimizedWindowsAndRemovesClosedWindows() async {
        let first = AXUIElementCreateApplication(100001)
        let second = AXUIElementCreateApplication(100002)
        var pass = 0
        let provider = AccessibilityTaskbarWindowProvider { element, name in
            if name == kAXWindowsAttribute {
                pass += 1
                return (pass == 1 ? [first, second] : [first]) as CFArray
            }
            if name == kAXSubroleAttribute {
                return (CFEqual(element, second) && pass == 2 ? kAXDialogSubrole : kAXStandardWindowSubrole) as CFString
            }
            if name == kAXTitleAttribute { return (CFEqual(element, first) ? "First" : "Second") as CFString }
            if name == kAXMinimizedAttribute {
                if CFEqual(element, second) { return pass == 2 ? kCFBooleanTrue : nil }
                return kCFBooleanFalse
            }
            return nil
        }
        let processes = [TaskbarWindowProcess(id: 123, bundleID: "editor")]
        let original = await provider.windows(for: processes, frontmostPID: nil)
        let minimized = await provider.windows(for: processes, frontmostPID: nil)
        XCTAssertEqual(minimized.map(\.id), original.map(\.id))
        XCTAssertTrue(minimized[1].isMinimized)
        let closed = await provider.windows(for: processes, frontmostPID: nil)
        XCTAssertEqual(closed.map(\.id), [original[0].id])
    }

    func testProviderDiscoversAlreadyMinimizedFinderWindowsDespiteDialogSubrole() async {
        let element = AXUIElementCreateApplication(100001)
        let provider = AccessibilityTaskbarWindowProvider { _, name in
            switch name {
            case kAXWindowsAttribute: return [element] as CFArray
            case kAXSubroleAttribute: return kAXDialogSubrole as CFString
            case kAXTitleAttribute: return "Minimized Finder window" as CFString
            case kAXMinimizedAttribute: return kCFBooleanTrue
            default: return nil
            }
        }
        let windows = await provider.windows(for: [TaskbarWindowProcess(id: 123, bundleID: "com.apple.finder")], frontmostPID: nil)
        XCTAssertEqual(windows.count, 1)
        XCTAssertTrue(windows.first?.isMinimized == true)
    }

    func testProviderRetainsTilesDuringEnumerationFailureAndStableOrderOnRecovery() async {
        let first = AXUIElementCreateApplication(100001)
        let second = AXUIElementCreateApplication(100002)
        var pass = 0
        let provider = AccessibilityTaskbarWindowProvider { element, name in
            if name == kAXWindowsAttribute {
                pass += 1
                if pass == 2 { return nil }
                return (pass == 1 ? [first, second] : [second, first]) as CFArray
            }
            if name == kAXSubroleAttribute { return kAXStandardWindowSubrole as CFString }
            if name == kAXTitleAttribute { return (CFEqual(element, first) ? "First" : "Second") as CFString }
            if name == kAXMinimizedAttribute { return kCFBooleanFalse }
            return nil
        }
        let processes = [TaskbarWindowProcess(id: 123, bundleID: "editor")]
        let original = await provider.windows(for: processes, frontmostPID: nil)
        let failed = await provider.windows(for: processes, frontmostPID: nil)
        XCTAssertEqual(failed, original)
        for _ in 0..<2 {
            let recovered = await provider.windows(for: processes, frontmostPID: nil)
            XCTAssertEqual(recovered.map(\.id), original.map(\.id))
            XCTAssertEqual(recovered.map(\.title), ["First", "Second"])
        }
    }

    private func app(_ id: String) -> ApplicationItem {
        ApplicationItem(id: id, name: id, url: URL(fileURLWithPath: "/Applications/\(id).app"), icon: NSImage())
    }
    private func window(_ title: String, minimized: Bool = false, focused: Bool = false) -> TaskbarWindow {
        TaskbarWindow(id: UUID(), bundleID: "editor", processID: 123, title: title, isMinimized: minimized, isFocused: focused)
    }

    @MainActor
    func testModeDefaultsPersistsAndPreservesLegacyLabels() {
        let suite = "MacbarWindowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "showAppLabels")
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.taskbarMode, .icons)
        XCTAssertFalse(preferences.separateMultipleWindows)
        preferences.separateMultipleWindows = true
        XCTAssertTrue(Preferences(defaults: defaults).separateMultipleWindows)
        preferences.taskbarMode = .windows
        XCTAssertEqual(Preferences(defaults: defaults).taskbarMode, .windows)
        XCTAssertTrue(Preferences(defaults: defaults).showAppLabels)
        defaults.set("invalid", forKey: "taskbarMode")
        XCTAssertEqual(Preferences(defaults: defaults).taskbarMode, .icons)
    }

    func testTwoWindowsReplacePinnedAppInPlaceAndRetainSelectedWindow() {
        let first = window("First document", focused: true)
        let second = window("Second document", minimized: true)
        let tiles = TaskbarTile.make(apps: [app("pinned"), app("editor"), app("browser")], windows: [first, second], mode: .windows)
        XCTAssertEqual(tiles.map(\.title), ["pinned", "First document", "Second document", "browser"])
        XCTAssertEqual(tiles[1].window?.id, first.id)
        XCTAssertEqual(tiles[2].window?.id, second.id)
        XCTAssertTrue(tiles[1].window!.isFocused)
        XCTAssertTrue(tiles[2].window!.isMinimized)
        XCTAssertEqual(Set(tiles.map(\.id)).count, 4)
        XCTAssertNil(tiles[0].window)
    }

    func testIdenticalAndEmptyTitlesDoNotMergeWindows() {
        let windows = [window("Same"), window("Same"), window(" \n ")]
        let tiles = TaskbarTile.make(apps: [app("editor"), app("editor")], windows: windows, mode: .windows)
        XCTAssertEqual(tiles.map(\.title), ["Same", "Same", "editor"])
        XCTAssertEqual(Set(tiles.map(\.id)).count, 3)
        XCTAssertEqual(tiles.compactMap { $0.window?.id }, windows.map(\.id))
    }

    func testIconModeGroupsWindowsAndClosedWindowsDisappear() {
        let windows = [window("First"), window("Second")]
        XCTAssertEqual(TaskbarTile.make(apps: [app("editor")], windows: windows, mode: .icons).count, 1)
        XCTAssertEqual(TaskbarTile.make(apps: [app("editor")], windows: [windows[1]], mode: .windows).map(\.title), ["Second"])
        XCTAssertEqual(TaskbarTile.make(apps: [app("editor")], windows: [], mode: .windows).map(\.title), ["editor"])
    }

    func testIconModeSeparatesOnlyAppsWithMultipleWindows() {
        let first = window("First", focused: true)
        let second = window("Second", minimized: true)
        let apps = [app("editor"), app("browser")]
        let single = TaskbarTile.make(apps: apps, windows: [first], mode: .icons, separateMultipleWindows: true)
        XCTAssertEqual(single.map(\.id), ["app:editor", "app:browser"])
        let expanded = TaskbarTile.make(apps: apps, windows: [first, second], mode: .icons, separateMultipleWindows: true)
        XCTAssertEqual(expanded.compactMap { $0.window?.id }, [first.id, second.id])
        XCTAssertTrue(expanded[1].window?.isMinimized == true)
        var order = TaskbarTileOrder()
        order.remember(single.reversed())
        let arranged = order.ordered(expanded)
        XCTAssertEqual(arranged.map(\.title), ["browser", "First", "Second"])
        order.remember(arranged)
        XCTAssertEqual(order.ordered(single).map(\.id), ["app:browser", "app:editor"])
    }

    func testIndividualWindowsCanMoveAcrossAppsWithoutMergingDuplicateTitles() {
        let first = window("Same")
        let second = window("Same", minimized: true)
        let original = TaskbarTile.make(apps: [app("editor"), app("browser")], windows: [first, second], mode: .windows)
        let reordered = TaskbarTileOrder.moving(original[2].id, relativeTo: original[1].id, after: false, in: original)
        XCTAssertEqual(reordered.map(\.id), [original[0].id, original[2].id, original[1].id])
        XCTAssertTrue(reordered[2].window?.isMinimized == true)
        var order = TaskbarTileOrder()
        order.remember(reordered)
        XCTAssertEqual(order.ordered(original.reversed()).map(\.id), reordered.map(\.id))
        XCTAssertEqual(TaskbarTileOrder.moving(original[0].id, relativeTo: original[2].id, after: true, in: original).map(\.id),
                       [original[1].id, original[2].id, original[0].id])
        XCTAssertEqual(TaskbarTileOrder.moving("closed-window", relativeTo: original[0].id, after: false, in: original).map(\.id), original.map(\.id))
    }

    func testWindowOrderSurvivesRenamingClosingAndAddingWindows() {
        let first = window("First")
        let second = window("Second")
        let original = TaskbarTile.make(apps: [app("editor"), app("browser")], windows: [first, second], mode: .windows)
        var order = TaskbarTileOrder()
        order.remember([original[1], original[2], original[0]])
        let renamed = TaskbarWindow(id: second.id, bundleID: second.bundleID, processID: second.processID,
                                   title: "Renamed", isMinimized: true, isFocused: false)
        let third = window("Third")
        let refreshed = TaskbarTile.make(apps: [app("editor"), app("browser")], windows: [first, renamed, third], mode: .windows)
        XCTAssertEqual(order.ordered(refreshed).map(\.title), ["Renamed", "browser", "First", "Third"])
        let closed = TaskbarTile.make(apps: [app("editor"), app("browser")], windows: [renamed], mode: .windows)
        XCTAssertEqual(order.ordered(closed).map(\.id), [original[1].id, original[2].id])
    }

    func testLauncherReplacementKeepsItsReorderedPosition() {
        let apps = [app("editor"), app("browser")]
        let launchers = TaskbarTile.make(apps: apps, windows: [], mode: .windows)
        var order = TaskbarTileOrder()
        order.remember(launchers.reversed())
        let expanded = TaskbarTile.make(apps: apps, windows: [window("First"), window("Second")], mode: .windows)
        let arranged = order.ordered(expanded)
        XCTAssertEqual(arranged.map(\.title), ["browser", "First", "Second"])
        order.remember(arranged)
        XCTAssertEqual(order.ordered(launchers).map(\.title), ["browser", "editor"])
    }

    @MainActor
    func testAppOrderPersistsWithoutPinningRunningAppsAndPreservesAbsentApps() {
        let suite = "MacbarOrderingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.pinnedIDs = ["editor", "browser"]
        preferences.rememberTaskbarOrder(["browser", "running", "editor", "editor"])
        let restored = Preferences(defaults: defaults)
        XCTAssertEqual(restored.pinnedIDs, ["browser", "editor"])
        XCTAssertEqual(restored.orderedTaskbarApps([app("editor"), app("browser"), app("running"), app("new")]).map(\.id),
                       ["browser", "running", "editor", "new"])
        restored.rememberTaskbarOrder(["editor", "browser"])
        XCTAssertEqual(Preferences(defaults: defaults).orderedTaskbarApps([app("editor"), app("running"), app("browser")]).map(\.id),
                       ["editor", "running", "browser"])
    }

    func testTileLayoutReservesOverflowAndAvoidsTray() {
        for mode in TaskbarMode.allCases {
            for width: CGFloat in [640, 800, 1100, 1440, 2560] {
                for count in [0, 1, 2, 12, 50] {
                    let layout = TaskbarStripLayout(screenWidth: width, alignment: .center,
                        preferredWidths: Array(repeating: 200, count: count), mode: mode)
                    let overflow: CGFloat = count > layout.capacity ? (layout.capacity > 0 ? 38 : 34) : 0
                    XCTAssertLessThanOrEqual(layout.tilesWidth + layout.headerWidth + overflow, layout.availableWidth + 0.01)
                    XCTAssertLessThanOrEqual(layout.capacity, count)
                }
            }
        }
    }

    func testCrowdedStripMovesLeftAndShowsAllFourteenTitlesOnLaptop() {
        let layout = TaskbarStripLayout(screenWidth: 1440, alignment: .center,
            preferredWidths: Array(repeating: 200, count: 14), mode: .windows)
        XCTAssertFalse(layout.centered)
        XCTAssertTrue(layout.showsSearchLabel)
        XCTAssertEqual(layout.capacity, 14)
        XCTAssertTrue(layout.tileWidths.allSatisfy { $0 >= 64 && $0 < 88 })
    }

    func testMixedIconAndWindowTilesUseAppropriateWidthsAndCompactTogether() {
        let spacious = TaskbarStripLayout(screenWidth: 1440, alignment: .left,
            preferredWidths: [150, 120, 180], mode: .icons, titledTiles: [false, true, true])
        XCTAssertEqual(spacious.tileWidths, [44, 120, 180])
        let crowded = TaskbarStripLayout(screenWidth: 800, alignment: .left,
            preferredWidths: [150] + Array(repeating: 200, count: 5), mode: .icons,
            titledTiles: [false] + Array(repeating: true, count: 5))
        XCTAssertEqual(crowded.capacity, 6)
        XCTAssertEqual(crowded.tileWidths[0], 44)
        XCTAssertTrue(crowded.tileWidths.dropFirst().allSatisfy { $0 >= 64 && $0 < 200 })
        XCTAssertLessThanOrEqual(crowded.tilesWidth + crowded.headerWidth, crowded.availableWidth + 0.01)
    }

    func testUncrowdedStripStaysCenteredAndShortTitlesDoNotWasteSpace() {
        let centered = TaskbarStripLayout(screenWidth: 1440, alignment: .center,
            preferredWidths: [95, 105, 180], mode: .windows)
        XCTAssertTrue(centered.centered)
        XCTAssertTrue(centered.showsSearchLabel)
        XCTAssertEqual(centered.tileWidths, [95, 105, 180])
        let mixed = TaskbarStripLayout(screenWidth: 1440, alignment: .center,
            preferredWidths: [88, 90] + Array(repeating: 200, count: 8), mode: .windows)
        XCTAssertFalse(mixed.centered)
        XCTAssertEqual(mixed.capacity, 10)
        XCTAssertEqual(mixed.tileWidths[0], 88)
        XCTAssertEqual(mixed.tileWidths[1], 90)
        XCTAssertGreaterThan(mixed.tileWidths[2], 90)
        XCTAssertLessThan(mixed.tileWidths[2], 200)
    }

    func testExtremeCrowdingUsesSeparateIconsBeforeOverflow() {
        let icons = TaskbarStripLayout(screenWidth: 1440, alignment: .center,
            preferredWidths: Array(repeating: 200, count: 20), mode: .windows)
        XCTAssertEqual(icons.capacity, 20)
        XCTAssertEqual(Set(icons.tileWidths), [44])
        let overflow = TaskbarStripLayout(screenWidth: 1440, alignment: .center,
            preferredWidths: Array(repeating: 200, count: 40), mode: .windows)
        XCTAssertGreaterThan(overflow.capacity, 20)
        XCTAssertLessThan(overflow.capacity, 40)
    }

    @MainActor
    func testNoAccessOrDisabledModeDoesNotReadWindows() async {
        let provider = TaskbarWindowProviderStub()
        let store = TaskbarWindowStore(provider: provider, hasAccess: { false })
        store.refresh(processes: [], frontmostPID: nil, enabled: true)
        let disabled = TaskbarWindowStore(provider: provider, hasAccess: { true })
        disabled.refresh(processes: [], frontmostPID: nil, enabled: false)
        await Task.yield()
        XCTAssertEqual(provider.requests, 0)
        XCTAssertTrue(store.windows.isEmpty)
    }

    @MainActor
    func testDisablingDiscardsOldEnumerationAfterReenabling() async {
        let provider = TaskbarWindowProviderStub()
        let store = TaskbarWindowStore(provider: provider, hasAccess: { true })
        store.refresh(processes: [], frontmostPID: nil, enabled: true)
        while provider.requests < 1 { await Task.yield() }
        store.refresh(processes: [], frontmostPID: nil, enabled: false)
        store.refresh(processes: [], frontmostPID: nil, enabled: true)
        while provider.requests < 2 { await Task.yield() }
        let current = window("New")
        provider.pending[1].resume(returning: [current])
        for _ in 0..<100 where store.windows.isEmpty { await Task.yield() }
        provider.pending[0].resume(returning: [window("Old")])
        await Task.yield()
        XCTAssertEqual(store.windows.map(\.id), [current.id])
    }

    @MainActor
    func testRefreshUpdatesTitlesFocusMinimizedStateAndClearsOnPermissionLoss() async {
        let provider = TaskbarWindowProviderStub()
        var allowed = true
        let store = TaskbarWindowStore(provider: provider, hasAccess: { allowed })
        let original = window("Original", focused: true)
        store.refresh(processes: [], frontmostPID: nil, enabled: true)
        while provider.requests < 1 { await Task.yield() }
        provider.pending[0].resume(returning: [original])
        for _ in 0..<100 where store.windows.isEmpty { await Task.yield() }
        store.refresh(processes: [], frontmostPID: nil, enabled: true)
        while provider.requests < 2 { await Task.yield() }
        let changed = TaskbarWindow(id: original.id, bundleID: original.bundleID, processID: original.processID,
                                   title: "Renamed", isMinimized: true, isFocused: false)
        provider.pending[1].resume(returning: [changed])
        for _ in 0..<100 where store.windows.first?.title != "Renamed" { await Task.yield() }
        XCTAssertEqual(store.windows.first, changed)
        allowed = false
        store.refresh(processes: [], frontmostPID: nil, enabled: true)
        XCTAssertTrue(store.windows.isEmpty)
    }
}
