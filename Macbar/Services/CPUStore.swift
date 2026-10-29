import Combine
import Foundation
import Darwin
import AppKit

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
    @Published private(set) var appHeatLevels: [String: Int] = [:]
    private var previous: CPUTicks?
    private var timer: Timer?
    private var appTimer: Timer?
    private var systemUsage: CPUUsage?
    private var recentSystemLoads: [Double] = []
    private var showSystemMeter = true
    private let readTicks: () -> CPUTicks?
    private let appProcessQueue = DispatchQueue(label: "studio.macbar.application-cpu", qos: .utility)
    private let appProcessSampler = ApplicationProcessCPUSampler()
    private var recentAppLoads: [String: [Double]] = [:]
    private var appSampleInFlight = false
    private var samplingGeneration = 0

    init(readTicks: @escaping () -> CPUTicks? = { SystemCPU().readTicks() }) {
        self.readTicks = readTicks
    }

    var percentageLabel: String { usage.map { "\($0.percentage)%" } ?? "—" }
    var summary: String { usage.map { "CPU usage: \($0.percentage)%" } ?? "CPU usage unavailable" }

    func setEnabled(_ enabled: Bool, showSystem: Bool = true) {
        if !enabled {
            timer?.invalidate()
            timer = nil
            appTimer?.invalidate()
            appTimer = nil
            previous = nil
            usage = nil
            appHeatLevels = [:]
            recentAppLoads = [:]
            appSampleInFlight = false
            systemUsage = nil
            recentSystemLoads = []
            samplingGeneration += 1
            appProcessQueue.async { [appProcessSampler] in appProcessSampler.reset() }
            return
        }

        showSystemMeter = showSystem
        if timer == nil {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        if !showSystem {
            usage = nil
        }

        if appTimer == nil {
            sampleApplicationCPU()
            appTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sampleApplicationCPU() }
            }
        }
    }

    func refresh() {
        guard let current = readTicks() else {
            previous = nil
            systemUsage = nil
            recentSystemLoads = []
            if showSystemMeter { usage = nil }
            return
        }
        if let previous {
            systemUsage = CPUUsage.between(previous, and: current)
            if let systemUsage {
                recentSystemLoads.append(systemUsage.total)
                if recentSystemLoads.count > 2 { recentSystemLoads.removeFirst() }
            } else {
                recentSystemLoads = []
            }
            if showSystemMeter { usage = systemUsage }
        }
        self.previous = current
    }

    private func sampleApplicationCPU() {
        guard !appSampleInFlight else { return }
        appSampleInFlight = true
        let generation = samplingGeneration
        let applications = NSWorkspace.shared.runningApplications.compactMap { app -> ApplicationProcessIdentity? in
            guard let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  !app.isTerminated else { return nil }
            return ApplicationProcessIdentity(bundleID: bundleID, processID: app.processIdentifier)
        }
        appProcessQueue.async { [weak self, appProcessSampler] in
            let loads = appProcessSampler.sample(applications)
            Task { @MainActor in
                guard let self, self.samplingGeneration == generation else { return }
                self.appSampleInFlight = false
                self.updateHeatLevels(with: loads)
            }
        }
    }

    private func updateHeatLevels(with loads: [String: Double]) {
        let averageSystemLoad = recentSystemLoads.isEmpty ? 0 : recentSystemLoads.reduce(0, +) / Double(recentSystemLoads.count)
        guard averageSystemLoad > 0.30 else {
            recentAppLoads = [:]
            if !appHeatLevels.isEmpty { appHeatLevels = [:] }
            return
        }
        let identifiers = Set(recentAppLoads.keys).union(loads.keys)
        var nextLevels: [String: Int] = [:]
        for identifier in identifiers {
            var samples = recentAppLoads[identifier, default: []]
            samples.append(loads[identifier] ?? 0)
            if samples.count > 2 { samples.removeFirst(samples.count - 2) }
            recentAppLoads[identifier] = samples

            let average = samples.reduce(0, +) / Double(samples.count)
            let level = average >= 1.5 ? 3 : average >= 0.75 ? 2 : average >= 0.30 ? 1 : 0
            if level > 0 { nextLevels[identifier] = level }
        }
        recentAppLoads = recentAppLoads.filter { identifiers.contains($0.key) }
        if nextLevels != appHeatLevels { appHeatLevels = nextLevels }
    }

    deinit {
        timer?.invalidate()
        appTimer?.invalidate()
    }
}

/// `proc_taskinfo` reports CPU time in Mach absolute-time units, which are not nanoseconds on Apple silicon.
enum ProcessCPUTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nanoseconds(for processID: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(processID, PROC_PIDTASKINFO, 0, $0, Int32(MemoryLayout<proc_taskinfo>.size))
        }
        guard result == MemoryLayout<proc_taskinfo>.size, timebase.denom > 0 else { return nil }
        let ticks = info.pti_total_user &+ info.pti_total_system
        return ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}

private struct ApplicationProcessIdentity {
    let bundleID: String
    let processID: pid_t
}

/// Samples app processes and their descendants, so bundled helpers are charged to their app tile.
/// These libproc interfaces are best-effort: macOS can deny or omit individual processes.
/// Its mutable sample history is only touched on CPUStore's serial process queue.
private final class ApplicationProcessCPUSampler: @unchecked Sendable {
    private struct PreviousSample {
        let bundleID: String
        let cpuNanoseconds: UInt64
    }

    private var previousSamples: [pid_t: PreviousSample] = [:]
    private var previousTime: UInt64?

    func reset() {
        previousSamples = [:]
        previousTime = nil
    }

    func sample(_ applications: [ApplicationProcessIdentity]) -> [String: Double] {
        let now = DispatchTime.now().uptimeNanoseconds
        var currentSamples: [pid_t: PreviousSample] = [:]
        for application in applications {
            for processID in processTree(rootedAt: application.processID) {
                guard let cpuNanoseconds = ProcessCPUTime.nanoseconds(for: processID) else { continue }
                currentSamples[processID] = PreviousSample(bundleID: application.bundleID, cpuNanoseconds: cpuNanoseconds)
            }
        }

        defer {
            previousSamples = currentSamples
            previousTime = now
        }
        guard let previousTime, now > previousTime else { return [:] }
        let elapsed = Double(now - previousTime)
        var loads: [String: Double] = [:]
        for (processID, current) in currentSamples {
            guard let previous = previousSamples[processID], previous.bundleID == current.bundleID,
                  current.cpuNanoseconds >= previous.cpuNanoseconds else { continue }
            loads[current.bundleID, default: 0] += Double(current.cpuNanoseconds - previous.cpuNanoseconds) / elapsed
        }
        return loads
    }

    private func processTree(rootedAt root: pid_t) -> Set<pid_t> {
        var result: Set<pid_t> = [root]
        var pending = [root]
        while let parent = pending.popLast() {
            var children = [pid_t](repeating: 0, count: 512)
            let childCount = children.withUnsafeMutableBufferPointer { buffer in
                proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
            }
            guard childCount > 0 else { continue }
            let count = min(children.count, Int(childCount))
            for child in children.prefix(count) where child > 0 && result.insert(child).inserted {
                pending.append(child)
            }
        }
        return result
    }
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
