import XCTest
import IOKit.ps
@testable import Macbar

final class BatteryTests: XCTestCase {
    private func description(current: Int = 60, maximum: Int = 100,
                             charging: Bool = false, pluggedIn: Bool = false) -> [String: Any] {
        [kIOPSTypeKey: kIOPSInternalBatteryType,
         kIOPSIsPresentKey: true,
         kIOPSCurrentCapacityKey: current,
         kIOPSMaxCapacityKey: maximum,
         kIOPSIsChargingKey: charging,
         kIOPSPowerSourceStateKey: pluggedIn ? kIOPSACPowerValue : kIOPSBatteryPowerValue]
    }

    func testCapacityUsesReportedScaleAndClampsOverfullReadings() {
        XCTAssertEqual(BatteryState(description: description(current: 1500, maximum: 2000)).percentage, 75)
        XCTAssertEqual(BatteryState(description: description(current: 101)).percentage, 100)
        XCTAssertNil(BatteryState(description: description(current: -1)).percentage)
        XCTAssertNil(BatteryState(description: description(maximum: 0)).percentage)
        XCTAssertEqual(BatteryState(description: [:]).percentageLabel, "—")
    }

    func testChargingAndPausedChargingHaveDifferentStatus() {
        let charging = BatteryState(description: description(current: 20, charging: true, pluggedIn: true))
        XCTAssertEqual(charging.status, "Charging")
        XCTAssertEqual(charging.symbol, "battery.100.bolt")
        XCTAssertFalse(charging.isLow)
        let paused = BatteryState(description: description(current: 80, pluggedIn: true))
        XCTAssertEqual(paused.status, "Not Charging")
        XCTAssertEqual(paused.symbol, "battery.75")
        XCTAssertEqual(BatteryState(description: description(current: 100, pluggedIn: true)).status, "Fully Charged")
    }

    func testDischargingBatteryShowsChargeAndLowState() {
        let low = BatteryState(description: description(current: 20))
        XCTAssertEqual(low.percentageLabel, "20%")
        XCTAssertEqual(low.status, "On Battery")
        XCTAssertTrue(low.isLow)
        XCTAssertEqual(low.symbol, "battery.25")
        XCTAssertFalse(BatteryState(description: description(current: 21)).isLow)
        XCTAssertEqual(BatteryState(description: description(current: 0)).symbol, "battery.0")
        XCTAssertEqual(BatteryState(description: description(current: 50)).symbol, "battery.50")
        XCTAssertEqual(BatteryState(description: description(current: 100)).symbol, "battery.100")
    }

    func testOnlyPresentInternalBatteryIsSelected() {
        var ups = description(current: 95)
        ups[kIOPSTypeKey] = kIOPSUPSType
        var absent = description()
        absent[kIOPSIsPresentKey] = false
        XCTAssertNil(BatteryState.internalBattery(in: []))
        XCTAssertNil(BatteryState.internalBattery(in: [ups, absent]))
        XCTAssertEqual(BatteryState.internalBattery(in: [ups, description(current: 42)])?.percentage, 42)
    }

    @MainActor
    func testBatteryVisibilityReturnsItsSpaceToAppTiles() {
        let suite = "BatteryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(preferences.shows(.battery))
        XCTAssertEqual(preferences.trayWidth - preferences.trayWidth(hasBattery: false), 34)
        preferences.setVisible(false, for: .battery)
        XCTAssertEqual(preferences.trayWidth, preferences.trayWidth(hasBattery: false))
        XCTAssertFalse(Preferences(defaults: defaults).shows(.battery))
    }
}
