import Combine
import Foundation
import Darwin

struct CPUTicks: Equatable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32
}

struct CPUUsage: Equatable {
    let user: Double
    let system: Double
    var total: Double { user + system }
    var percentage: Int { Int((total * 100).rounded()) }

    static func between(_ previous: CPUTicks, and current: CPUTicks) -> CPUUsage? {
        // Mach counters are 32-bit and can wrap between samples.
        let user = UInt64(current.user &- previous.user) + UInt64(current.nice &- previous.nice)
        let system = UInt64(current.system &- previous.system)
        let idle = UInt64(current.idle &- previous.idle)
        let total = user + system + idle
        guard total > 0 else { return nil }
        return CPUUsage(user: Double(user) / Double(total), system: Double(system) / Double(total))
    }
}

struct SystemCPU {
    func readTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                        idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }
}

@MainActor
final class CPUStore: ObservableObject {
    @Published private(set) var usage: CPUUsage?
    private var previous: CPUTicks?
    private var timer: Timer?
    private let readTicks: () -> CPUTicks?

    init(readTicks: @escaping () -> CPUTicks? = { SystemCPU().readTicks() }) {
        self.readTicks = readTicks
    }

    var percentageLabel: String { usage.map { "\($0.percentage)%" } ?? "—" }
    var summary: String { usage.map { "CPU usage: \($0.percentage)%" } ?? "CPU usage unavailable" }

    func setEnabled(_ enabled: Bool) {
        if !enabled {
            timer?.invalidate()
            timer = nil
            previous = nil
            usage = nil
        } else if timer == nil {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    func refresh() {
        guard let current = readTicks() else {
            previous = nil
            usage = nil
            return
        }
        if let previous { usage = CPUUsage.between(previous, and: current) }
        self.previous = current
    }

    deinit { timer?.invalidate() }
}


struct ResourceCapacity: Equatable {
    let amount: UInt64
    let total: UInt64
    var fraction: Double { min(1, Double(amount) / Double(total)) }
    var percentage: Int { Int((fraction * 100).rounded()) }

    init?(amount: UInt64, total: UInt64) {
        guard total > 0 else { return nil }
        self.amount = min(amount, total)
        self.total = total
    }
}

struct SystemResources {
    func memoryInUse() -> ResourceCapacity? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        let bytes = pages * UInt64(vm_kernel_page_size)
        return ResourceCapacity(amount: bytes, total: ProcessInfo.processInfo.physicalMemory)
    }

    func diskUsed() -> ResourceCapacity? {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, total > 0,
              let free = values.volumeAvailableCapacity, free >= 0 else { return nil }
        return ResourceCapacity(amount: UInt64(max(0, total - free)), total: UInt64(total))
    }
}

@MainActor
final class SystemResourcesStore: ObservableObject {
    @Published private(set) var memory: ResourceCapacity?
    @Published private(set) var disk: ResourceCapacity?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let resources = SystemResources()
        memory = resources.memoryInUse()
        disk = resources.diskUsed()
    }

    deinit { timer?.invalidate() }
}
