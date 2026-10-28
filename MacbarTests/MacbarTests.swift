import XCTest
@testable import Macbar

final class MacbarTests: XCTestCase {
    func testSearchIgnoresCaseAccentsAndExtraWhitespace() {
        XCTAssertTrue(ApplicationItem.matches("Café Studio", query: " CAFE   stu "))
        XCTAssertTrue(ApplicationItem.matches("System Settings", query: "settings system"))
        XCTAssertTrue(ApplicationItem.matches("Safari", query: "   "))
        XCTAssertFalse(ApplicationItem.matches("Safari", query: "safari mail"))
    }

    @MainActor
    func testPinsPersistAndAnEmptyPinListStaysEmpty() {
        let suite = "MacbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.pinnedIDs, Preferences.defaultPins)
        preferences.pinnedIDs = []
        XCTAssertEqual(Preferences(defaults: defaults).pinnedIDs, [])
        preferences.togglePin("example.app")
        XCTAssertEqual(Preferences(defaults: defaults).pinnedIDs, ["example.app"])
        preferences.togglePin("example.app")
        XCTAssertEqual(preferences.pinnedIDs, [])
    }

    func testBarUsesEntireDisplayIncludingNegativeOrigins() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        XCTAssertEqual(BarGeometry.frame(on: screen, height: 68), CGRect(x: -1920, y: -200, width: 1920, height: 68))
        let popup = BarGeometry.popupFrame(screen: screen, barHeight: 68, size: CGSize(width: 640, height: 600), alignment: .center)
        XCTAssertEqual(popup.midX, screen.midX)
        XCTAssertEqual(popup.minY, screen.minY + 80)
        XCTAssertTrue(screen.contains(popup))
        let leftPopup = BarGeometry.popupFrame(screen: screen, barHeight: 54, size: CGSize(width: 640, height: 600), alignment: .left)
        XCTAssertEqual(leftPopup.minX, screen.minX + 12)
        XCTAssertTrue(screen.contains(leftPopup))
    }

    @MainActor
    func testAlignmentDefaultsToCenterAndPersistsChoice() {
        let suite = "MacbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.alignment, .center)
        preferences.alignment = .left
        XCTAssertEqual(Preferences(defaults: defaults).alignment, .left)
        defaults.set("unknown", forKey: "alignment")
        XCTAssertEqual(Preferences(defaults: defaults).alignment, .center)
    }

    func testFlyoutFitsSmallScreen() {
        let screen = CGRect(x: 0, y: 0, width: 540, height: 480)
        let popup = BarGeometry.popupFrame(screen: screen, barHeight: 68, size: CGSize(width: 640, height: 600), alignment: .right)
        XCTAssertTrue(screen.contains(popup))
        XCTAssertEqual(popup.maxX, screen.maxX - 12)
        XCTAssertEqual(popup.maxY, screen.maxY - 12)
    }

    func testCalendarLeapMonthAndLocaleWeekStart() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let date = calendar.date(from: DateComponents(year: 2024, month: 2, day: 17))!
        let month = CalendarMonth(date: date, calendar: calendar)
        XCTAssertEqual(month.days.compactMap { $0 }.count, 29)
        XCTAssertEqual(month.days.prefix(while: { $0 == nil }).count, 3)
        XCTAssertEqual(calendar.component(.day, from: month.days.compactMap { $0 }.last!), 29)
        XCTAssertEqual(month.weekdaySymbols.first, calendar.veryShortStandaloneWeekdaySymbols[1])
    }
}
