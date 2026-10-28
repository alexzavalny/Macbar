import XCTest
@testable import Macbar

final class TrayOrderTests: XCTestCase {
    func testMovingDifferentWidthControlsInBothDirections() {
        let original = TrayItem.allCases
        let moved = TrayItem.moving(.clock, relativeTo: .inputLanguage, after: false, in: original)
        XCTAssertEqual(moved, [.aiLimits, .clock, .inputLanguage, .wifi, .sound, .battery, .settings])
        XCTAssertEqual(TrayItem.moving(.clock, relativeTo: .battery, after: true, in: moved), original)
        XCTAssertEqual(TrayItem.moving(.settings, relativeTo: .aiLimits, after: false, in: original).first, .settings)
        XCTAssertEqual(TrayItem.moving(.aiLimits, relativeTo: .settings, after: true, in: original).last, .aiLimits)
    }

    func testNormalizationHandlesUnknownDuplicateAndNewControls() {
        let order = TrayItem.normalized(["settings", "sound", "settings", "future-control", "search"])
        XCTAssertEqual(order, [.settings, .sound, .aiLimits, .inputLanguage, .wifi, .battery, .clock])
        XCTAssertEqual(Set(order), Set(TrayItem.allCases))
        XCTAssertEqual(TrayItem.moving(.wifi, relativeTo: .wifi, after: true, in: order), order)
        XCTAssertEqual(TrayItem.moving(.wifi, relativeTo: .clock, after: false, in: [.wifi]), [.wifi])
    }

    @MainActor
    func testOrderPersistsWithoutChangingAppOrderOrVisibility() {
        withPreferences { preferences, defaults in
            preferences.setVisible(false, for: .sound)
            preferences.rememberTaskbarOrder(["com.apple.finder", "com.apple.Safari"])
            let appOrder = preferences.taskbarAppOrder
            let reordered = TrayItem.moving(.settings, relativeTo: .aiLimits, after: false, in: preferences.trayOrder)
            preferences.rememberTrayOrder(reordered)
            let restored = Preferences(defaults: defaults)
            XCTAssertEqual(restored.trayOrder, reordered)
            XCTAssertEqual(restored.taskbarAppOrder, appOrder)
            XCTAssertFalse(restored.shows(.sound))
            restored.setVisible(true, for: .sound)
            XCTAssertEqual(restored.trayOrder, reordered)
        }
    }

    @MainActor
    func testHiddenControlsKeepTheirPositionWhenOtherControlsMove() {
        withPreferences { preferences, _ in
            preferences.setVisible(false, for: .battery)
            let reordered = TrayItem.moving(.wifi, relativeTo: .aiLimits, after: false, in: preferences.trayOrder)
            preferences.rememberTrayOrder(reordered)
            preferences.setVisible(true, for: .battery)
            XCTAssertEqual(preferences.trayOrder, [.wifi, .aiLimits, .inputLanguage, .sound, .battery, .clock, .settings])
        }
    }

    @MainActor
    func testDrawerPlacementPersistsAndDoesNotChangeControlVisibility() {
        withPreferences { preferences, defaults in
            let originalWidth = preferences.trayWidth
            preferences.setInDrawer(true, for: .wifi)
            preferences.setInDrawer(true, for: .settings)
            XCTAssertEqual(preferences.trayWidth, originalWidth - 60)
            XCTAssertTrue(preferences.shows(.wifi))
            preferences.setVisible(false, for: .wifi)
            let restored = Preferences(defaults: defaults)
            XCTAssertTrue(restored.isInDrawer(.wifi))
            XCTAssertTrue(restored.isInDrawer(.settings))
            XCTAssertFalse(restored.shows(.wifi))
            restored.setVisible(true, for: .wifi)
            XCTAssertTrue(restored.isInDrawer(.wifi))
            restored.setInDrawer(false, for: .wifi)
            XCTAssertFalse(Preferences(defaults: defaults).isInDrawer(.wifi))
        }
    }

    @MainActor
    func testUnknownDrawerItemsAreIgnored() {
        withPreferences { _, defaults in
            defaults.set(["wifi", "future-control"], forKey: "trayDrawerItems")
            XCTAssertEqual(Preferences(defaults: defaults).drawerItems, ["wifi"])
        }
    }

    @MainActor
    private func withPreferences(_ body: (Preferences, UserDefaults) -> Void) {
        let suite = "TrayOrderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(Preferences(defaults: defaults), defaults)
    }
}
