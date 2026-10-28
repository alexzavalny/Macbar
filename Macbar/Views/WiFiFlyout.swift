import SwiftUI
import CoreLocation

struct WiFiFlyout: View {
    @ObservedObject var wifi: WiFiStore
    let openSettings: () -> Void
    @State private var selected: WiFiNetworkItem?
    @State private var password = ""

    var body: some View {
        FlyoutSurface {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Wi-Fi").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    if wifi.isScanning { ProgressView().controlSize(.small) }
                    Button { wifi.refresh() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 13)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(TileButtonStyle())
                    .disabled(wifi.isScanning || wifi.joiningSSID != nil)
                    .help("Refresh networks").accessibilityLabel("Refresh networks")
                }

                if !wifi.isAvailable {
                    message(symbol: "wifi.slash", title: "Wi-Fi isn’t available", detail: "No wireless adapter was found on this Mac.")
                } else if !wifi.isPowered {
                    message(symbol: "wifi.slash", title: "Wi-Fi is off", detail: "Turn on Wi-Fi in macOS settings to see nearby networks.")
                    Button("Open Wi-Fi settings", action: openSettings).buttonStyle(.bordered)
                } else if !wifi.hasAccess {
                    permissionView
                } else if wifi.namesUnavailable {
                    message(symbol: "location.slash", title: "Network names are unavailable", detail: "Check that Location Services is on and Macbar has permission, then refresh.")
                    locationSettingsButton
                } else {
                    networkList
                }

                if let error = wifi.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(4)
                }
                Spacer(minLength: 0)
                Divider().opacity(0.5)
                Button(action: openSettings) {
                    HStack { Text("Wi-Fi settings"); Spacer(); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { wifi.refresh() }
        .onDisappear { password = "" }
    }

    private var permissionView: some View {
        VStack(alignment: .leading, spacing: 16) {
            message(symbol: "wifi", title: "See nearby networks", detail: "macOS requires Location permission to show Wi-Fi network names. Macbar uses it only for this list.")
            if wifi.authorization == .notDetermined {
                Button("Allow network discovery") { wifi.requestAccess() }.buttonStyle(.borderedProminent)
            }
            locationSettingsButton
        }
    }

    private var locationSettingsButton: some View {
        Button("Open Location settings") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
        }.buttonStyle(.bordered)
    }

    private var networkList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let ssid = wifi.connectedSSID {
                Label("Connected to \(ssid)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(wifi.isScanning ? "Looking for networks…" : "Available networks")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(wifi.networks) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                guard item.ssid != wifi.connectedSSID else { return }
                                selected = selected?.id == item.id ? nil : item
                                password = ""
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "wifi", variableValue: item.signalLevel).font(.system(size: 17)).foregroundStyle(item.ssid == wifi.connectedSSID ? Color.accentColor : Color.primary)
                                    Text(item.ssid).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if wifi.joiningSSID == item.ssid { ProgressView().controlSize(.small) }
                                    else if item.ssid == wifi.connectedSSID { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor) }
                                    else if item.secured { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                                }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(TileButtonStyle(selected: selected?.id == item.id || item.ssid == wifi.connectedSSID))
                            .disabled(wifi.joiningSSID != nil || wifi.isScanning)
                            .accessibilityLabel(item.ssid + (item.ssid == wifi.connectedSSID ? ", connected" : item.secured ? ", secured" : ", open network"))

                            if selected?.id == item.id && item.ssid != wifi.connectedSSID {
                                VStack(alignment: .leading, spacing: 10) {
                                    if item.enterprise {
                                        Text("Join this enterprise network in Wi-Fi settings.")
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                        Button("Open Wi-Fi settings", action: openSettings).buttonStyle(.bordered)
                                    } else {
                                        if item.secured {
                                            SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                                                .accessibilityLabel("Wi-Fi password")
                                        } else {
                                            Text("This is an open network.").font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                        HStack {
                                            Spacer()
                                            Button("Cancel") { selected = nil; password = "" }.buttonStyle(.bordered)
                                            Button("Join") {
                                                wifi.join(item, password: password)
                                                password = ""
                                                selected = nil
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .disabled((item.secured && password.isEmpty) || wifi.joiningSSID != nil)
                                        }
                                    }
                                }.padding(.horizontal, 11).padding(.bottom, 10)
                            }
                        }
                    }
                    if wifi.networks.isEmpty && !wifi.isScanning && wifi.error == nil {
                        Text("No nearby networks found.").font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }

    private func message(symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Color.accentColor).padding(.top, 8)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
