import SwiftUI

struct BatteryFlyout: View {
    @ObservedObject var battery: BatteryStore
    let openSettings: () -> Void

    var body: some View {
        FlyoutSurface {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Battery").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(battery.state?.percentageLabel ?? "—")
                        .font(.system(size: 16, weight: .medium)).monospacedDigit()
                }
                if let state = battery.state {
                    HStack(spacing: 12) {
                        Image(systemName: state.symbol).font(.system(size: 28))
                            .foregroundStyle(state.isLow ? Color.red : state.isCharging ? Color.green : Color.primary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(state.status).font(.system(size: 13, weight: .medium))
                            Text("Power Source: \(state.isOnACPower ? "Power Adapter" : "Battery")")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Battery information unavailable").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Divider().opacity(0.5)
                Button(action: openSettings) {
                    HStack { Text("Battery settings"); Spacer(); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { battery.refresh() }
    }
}
