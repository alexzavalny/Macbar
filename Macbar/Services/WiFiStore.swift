import AppKit
import CoreWLAN
import CoreLocation

struct WiFiNetworkItem: Identifiable {
    let ssid: String
    let signal: Int
    let secured: Bool
    let enterprise: Bool
    let network: CWNetwork
    var id: String { ssid }
    var signalLevel: Double { signal > -60 ? 1 : signal > -75 ? 0.66 : 0.33 }

    static func sortedUnique(_ items: [WiFiNetworkItem], connectedSSID: String?) -> [WiFiNetworkItem] {
        var strongest: [String: WiFiNetworkItem] = [:]
        for item in items where !item.ssid.isEmpty {
            if item.signal > (strongest[item.ssid]?.signal ?? Int.min) { strongest[item.ssid] = item }
        }
        return strongest.values.sorted {
            if ($0.ssid == connectedSSID) != ($1.ssid == connectedSSID) { return $0.ssid == connectedSSID }
            if $0.signal != $1.signal { return $0.signal > $1.signal }
            return $0.ssid.localizedStandardCompare($1.ssid) == .orderedAscending
        }
    }
}

@MainActor
final class WiFiStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var networks: [WiFiNetworkItem] = []
    @Published private(set) var connectedSSID: String?
    @Published private(set) var isPowered = true
    @Published private(set) var isAvailable = true
    @Published private(set) var isScanning = false
    @Published private(set) var joiningSSID: String?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var error: String?
    @Published private(set) var namesUnavailable = false

    private let location = CLLocationManager()
    private let queue = DispatchQueue(label: "studio.macbar.wifi", qos: .userInitiated)

    // macOS reports a granted location request as authorizedAlways.
    var hasAccess: Bool { authorization == .authorizedAlways }
    var symbol: String { isAvailable && isPowered ? "wifi" : "wifi.slash" }

    override init() {
        super.init()
        authorization = location.authorizationStatus
        location.delegate = self
    }

    func requestAccess() {
        NSApp.activate(ignoringOtherApps: true)
        location.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorization = self.location.authorizationStatus
            if self.hasAccess { self.refresh() }
            else { self.networks = []; self.connectedSSID = nil }
        }
    }

    func refresh() {
        guard !isScanning, joiningSSID == nil else { return }
        authorization = location.authorizationStatus
        let allowed = hasAccess
        isScanning = allowed
        error = nil
        namesUnavailable = false
        queue.async { [weak self] in
            let interface = CWWiFiClient.shared().interface()
            let powered = interface?.powerOn() ?? false
            let connected = allowed ? interface?.ssid() : nil
            var items: [WiFiNetworkItem] = []
            var scanError: String?
            var redacted = false
            if let interface, powered, allowed {
                do {
                    let scanned = try interface.scanForNetworks(withName: nil)
                    redacted = !scanned.isEmpty && scanned.allSatisfy { $0.ssid == nil }
                    items = scanned.compactMap { network in
                        guard let name = network.ssid, !name.isEmpty else { return nil }
                        return WiFiNetworkItem(ssid: name, signal: network.rssiValue,
                                               secured: !network.supportsSecurity(.none),
                                               enterprise: network.supportsSecurity(.enterprise), network: network)
                    }
                } catch { scanError = error.localizedDescription }
            }
            let sorted = WiFiNetworkItem.sortedUnique(items, connectedSSID: connected)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isAvailable = interface != nil
                self.isPowered = powered
                self.connectedSSID = connected
                self.networks = sorted
                self.isScanning = false
                self.namesUnavailable = redacted
                self.error = scanError
            }
        }
    }

    func join(_ item: WiFiNetworkItem, password: String) {
        guard joiningSSID == nil, !isScanning else { return }
        joiningSSID = item.ssid
        error = nil
        queue.async { [weak self] in
            var failure: String?
            do {
                guard let interface = CWWiFiClient.shared().interface() else {
                    throw NSError(domain: "Macbar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Wi-Fi isn’t available."])
                }
                try interface.associate(to: item.network, password: password.isEmpty ? nil : password)
            } catch { failure = error.localizedDescription }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.joiningSSID = nil
                if let failure { self.error = "Couldn’t join \(item.ssid). \(failure)" }
                else { self.refresh() }
            }
        }
    }
}
