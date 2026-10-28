import Combine
import IOKit.ps

struct BatteryState: Equatable {
    let percentage: Int?
    let isCharging: Bool
    let isOnACPower: Bool

    init(description: [String: Any]) {
        if let current = description[kIOPSCurrentCapacityKey] as? Int,
           let maximum = description[kIOPSMaxCapacityKey] as? Int,
           current >= 0, maximum > 0 {
            percentage = Int((min(Double(current) / Double(maximum), 1) * 100).rounded())
        } else {
            percentage = nil
        }
        isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
        isOnACPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
    }

    var symbol: String {
        if isCharging { return "battery.100.bolt" }
        guard let percentage else { return "battery.0" }
        switch percentage {
        case 0..<10: return "battery.0"
        case 10..<38: return "battery.25"
        case 38..<63: return "battery.50"
        case 63..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    var isLow: Bool { !isOnACPower && (percentage.map { $0 <= 20 } ?? false) }
    var percentageLabel: String { percentage.map { "\($0)%" } ?? "—" }
    var status: String {
        if isCharging { return "Charging" }
        if isOnACPower { return percentage == 100 ? "Fully Charged" : "Not Charging" }
        return "On Battery"
    }
    var summary: String { "Battery: \(percentageLabel) · \(status)" }

    static func internalBattery(in descriptions: [[String: Any]]) -> BatteryState? {
        guard let description = descriptions.first(where: {
            $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType &&
            $0[kIOPSIsPresentKey] as? Bool != false
        }) else { return nil }
        return BatteryState(description: description)
    }
}

struct SystemBattery {
    func readState() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let descriptions = sources.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return BatteryState.internalBattery(in: descriptions)
    }
}

@MainActor
final class BatteryStore: ObservableObject {
    @Published private(set) var state: BatteryState?
    private var notificationSource: CFRunLoopSource?

    init() {
        notificationSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let store = Unmanaged<BatteryStore>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak store] in store?.refresh() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let notificationSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), notificationSource, .commonModes)
        }
        refresh()
    }

    deinit {
        if let notificationSource { CFRunLoopSourceInvalidate(notificationSource) }
    }

    func refresh() {
        let updated = SystemBattery().readState()
        if state != updated { state = updated }
    }
}
