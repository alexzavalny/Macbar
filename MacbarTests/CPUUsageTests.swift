import XCTest
@testable import Macbar

final class CPUUsageTests: XCTestCase {
    func testUsageUsesChangesAcrossAllTickCategories() throws {
        let previous = CPUTicks(user: 100, system: 200, idle: 300, nice: 50)
        let current = CPUTicks(user: 120, system: 210, idle: 360, nice: 60)
        let usage = try XCTUnwrap(CPUUsage.between(previous, and: current))
        XCTAssertEqual(usage.user, 0.3, accuracy: 0.0001)
        XCTAssertEqual(usage.system, 0.1, accuracy: 0.0001)
        XCTAssertEqual(usage.percentage, 40)
        XCTAssertNil(CPUUsage.between(current, and: current))
    }

    func testTickCounterWrap() throws {
        let previous = CPUTicks(user: UInt32.max - 4, system: 0, idle: 0, nice: 0)
        let current = CPUTicks(user: 5, system: 0, idle: 10, nice: 0)
        XCTAssertEqual(try XCTUnwrap(CPUUsage.between(previous, and: current)).percentage, 50)
    }

    func testResourceCapacityHandlesMissingAndExcessValues() throws {
        XCTAssertNil(ResourceCapacity(amount: 5, total: 0))
        let capacity = try XCTUnwrap(ResourceCapacity(amount: 25, total: 100))
        XCTAssertEqual(capacity.percentage, 25)
        XCTAssertEqual(capacity.fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(ResourceCapacity(amount: 120, total: 100)?.percentage, 100)
    }

    func testProcessCPUTimeIsInNanoseconds() throws {
        // Spin so the process has enough CPU time for a meaningful comparison.
        let deadline = Date().addingTimeInterval(0.2)
        var spins = 0
        while Date() < deadline { spins &+= 1 }
        XCTAssertGreaterThan(spins, 0)

        let sampled = try XCTUnwrap(ProcessCPUTime.nanoseconds(for: getpid()))
        var usage = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
        func nanoseconds(_ time: timeval) -> Double { Double(time.tv_sec) * 1e9 + Double(time.tv_usec) * 1e3 }
        let expected = nanoseconds(usage.ru_utime) + nanoseconds(usage.ru_stime)
        XCTAssertEqual(Double(sampled) / expected, 1, accuracy: 0.1)
    }

    func testTileFlameIsSubtleAndGrowsWithHeat() throws {
        XCTAssertNil(TileFlame(level: 0))
        let flames = try (1...3).map { try XCTUnwrap(TileFlame(level: $0)) }
        XCTAssertEqual(flames.map(\.height), flames.map(\.height).sorted())
        XCTAssertEqual(flames.map(\.birthRate), flames.map(\.birthRate).sorted())
        XCTAssertLessThan(flames[2].height, 0.6)
        XCTAssertTrue(flames.allSatisfy { $0.peakOpacity <= 0.45 })
        XCTAssertEqual(TileFlame(level: 7), flames[2])
    }

    @MainActor
    func testSamplingFailureAndDisableClearOldValue() {
        var ticks: CPUTicks? = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let store = CPUStore(readTicks: { ticks })
        store.setEnabled(true)
        XCTAssertEqual(store.percentageLabel, "—")
        ticks = CPUTicks(user: 25, system: 0, idle: 75, nice: 0)
        store.refresh()
        XCTAssertEqual(store.percentageLabel, "25%")
        ticks = nil
        store.refresh()
        XCTAssertNil(store.usage)
        ticks = CPUTicks(user: 100, system: 0, idle: 100, nice: 0)
        store.refresh()
        XCTAssertNil(store.usage)
        store.setEnabled(false)
        XCTAssertNil(store.usage)
    }
}
