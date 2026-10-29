import SwiftUI

struct CPUFlyout: View {
    @ObservedObject var cpu: CPUStore
    @StateObject private var resources = SystemResourcesStore()

    var body: some View {
        FlyoutSurface {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Text("System Usage").font(.system(size: 16, weight: .semibold))
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("CPU", systemImage: "cpu")
                        Spacer()
                        Text(cpu.percentageLabel)
                    }.font(.system(size: 12, weight: .medium))
                    if let usage = cpu.usage {
                        ProgressView(value: usage.total).tint(.accentColor)
                        HStack {
                            Text("User \(Int((usage.user * 100).rounded()))%")
                            Spacer()
                            Text("System \(Int((usage.system * 100).rounded()))%")
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Text("Waiting for CPU usage…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                resourceRow("RAM in use", symbol: "memorychip", capacity: resources.memory)
                resourceRow("Disk used", symbol: "internaldrive", capacity: resources.disk, showFree: true)
                Spacer(minLength: 0)
                Text("CPU across all cores · updates every 2 seconds")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { resources.start() }
        .onDisappear { resources.stop() }
    }

    private func resourceRow(_ title: String, symbol: String, capacity: ResourceCapacity?, showFree: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text(capacity.map { "\($0.percentage)%" } ?? "—")
            }.font(.system(size: 12, weight: .medium))
            if let capacity {
                ProgressView(value: capacity.fraction).tint(.accentColor)
                HStack {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(capacity.amount), countStyle: .memory)) of \(ByteCountFormatter.string(fromByteCount: Int64(capacity.total), countStyle: .memory))")
                    if showFree {
                        Spacer()
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(capacity.total - capacity.amount), countStyle: .memory)) free")
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("Unavailable").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
