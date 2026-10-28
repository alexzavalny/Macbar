import XCTest
@testable import Macbar

@MainActor
private final class LimitsProviderStub: AILimitsProviding {
    var requests: [(AIProvider, Bool)] = []
    var pending: [(AIProvider, CheckedContinuation<AIUsageSnapshot, Error>)] = []
    func fetch(_ provider: AIProvider, allowKeychainPrompt: Bool) async throws -> AIUsageSnapshot {
        requests.append((provider, allowKeychainPrompt))
        return try await withCheckedThrowingContinuation { pending.append((provider, $0)) }
    }
}

final class AILimitsTests: XCTestCase {
    func testCodexUsageReadsPreferredBucketsAndConvertsUsedToRemaining() throws {
        let data = Data("""
        {"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{
          "codex":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1893456000},
                   "secondary":{"usedPercent":10,"windowDurationMins":10080}}}}
        """.utf8)
        let result = try AIUsageDecoder.codex(data)
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows[0].title, "5 hours")
        XCTAssertEqual(result.windows[0].remainingPercent, 75)
        XCTAssertEqual(result.windows[0].resetsAt, Date(timeIntervalSince1970: 1893456000))
        XCTAssertEqual(result.windows[1].title, "Weekly")
        XCTAssertEqual(result.remainingPercent, 75)
    }

    func testCodexLegacyAndMultipleBucketsKeepDistinctWindows() throws {
        let legacy = try AIUsageDecoder.codex(Data("""
        {"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":300},"secondary":null}}
        """.utf8))
        XCTAssertEqual(legacy.remainingPercent, 100)
        let multiple = try AIUsageDecoder.codex(Data("""
        {"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":12}},
          "other":{"limitName":"Other models","primary":{"usedPercent":97}}}}
        """.utf8))
        XCTAssertEqual(Set(multiple.windows.map(\.id)).count, 2)
        XCTAssertEqual(multiple.remainingPercent, 88)
        XCTAssertTrue(multiple.windows.contains { $0.title.contains("Other models") })
    }

    func testClaudeNullWindowsAreUnknownAndFractionalResetDatesDecode() throws {
        let result = try AIUsageDecoder.claude(Data("""
        {"five_hour":{"utilization":32.5,"resets_at":"2030-01-01T00:00:00.000Z"},
         "seven_day":null,"seven_day_opus":{"utilization":0,"resets_at":null}}
        """.utf8))
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows[0].remainingPercent, 67.5)
        XCTAssertEqual(result.windows[0].resetsAt, Date(timeIntervalSince1970: 1893456000))
        XCTAssertEqual(result.windows[1].remainingPercent, 100)
        XCTAssertNil(result.windows[1].resetsAt)
    }

    func testAbsentOrMalformedPercentagesNeverBecomeZeroUsage() {
        for json in ["{}", "{\"five_hour\":null}", "{\"five_hour\":{\"utilization\":true}}", "{\"five_hour\":{\"utilization\":\"25\"}}"] {
            XCTAssertThrowsError(try AIUsageDecoder.claude(Data(json.utf8)))
        }
        XCTAssertThrowsError(try AIUsageDecoder.codex(Data("{\"rateLimits\":{\"primary\":{}}}".utf8)))
    }

    @MainActor
    func testVisibilityChoicesPersistAndRestoreEveryControl() {
        let suite = "MacbarVisibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(TaskbarControl.allCases.allSatisfy(preferences.shows))
        let fullWidth = preferences.trayWidth
        for control in TaskbarControl.allCases { preferences.setVisible(false, for: control) }
        let restored = Preferences(defaults: defaults)
        XCTAssertTrue(TaskbarControl.allCases.allSatisfy { !restored.shows($0) })
        XCTAssertEqual(restored.trayWidth, 28)
        XCTAssertLessThan(restored.trayWidth, fullWidth)
        for control in TaskbarControl.allCases { restored.setVisible(true, for: control) }
        XCTAssertTrue(TaskbarControl.allCases.allSatisfy(Preferences(defaults: defaults).shows))
    }

    func testHidingControlsReturnsRoomAndCrowdedTrayDoesNotOverlapTiles() {
        let widths = Array(repeating: CGFloat(200), count: 30)
        let full = TaskbarStripLayout(screenWidth: 1440, alignment: .center, preferredWidths: widths,
                                     mode: .windows, trayWidth: 344)
        let hidden = TaskbarStripLayout(screenWidth: 1440, alignment: .center, preferredWidths: widths,
                                       mode: .windows, trayWidth: 28, showSearch: false, showMissionControl: false)
        XCTAssertEqual(hidden.headerWidth, 0)
        XCTAssertGreaterThan(hidden.capacity, full.capacity)
        XCTAssertLessThanOrEqual(full.tilesWidth + full.headerWidth + 38, full.availableWidth + 0.01)
    }

    @MainActor
    func testProvidersFinishIndependentlyAndBackgroundRefreshDoesNotRequestKeychainUI() async {
        let provider = LimitsProviderStub()
        let store = AILimitsStore(provider: provider)
        store.setEnabled(true)
        for _ in 0..<1000 where provider.pending.count < 2 { await Task.yield() }
        XCTAssertEqual(provider.pending.count, 2)
        XCTAssertTrue(provider.requests.allSatisfy { !$0.1 })
        let snapshot = AIUsageSnapshot(windows: [AIUsageWindow(id: "primary", title: "5 hours", usedPercent: 40, resetsAt: nil)], fetchedAt: Date())
        for (key, continuation) in provider.pending {
            if key == .codex { continuation.resume(returning: snapshot) }
            else { continuation.resume(throwing: AIUsageError.keychainAccess) }
        }
        for _ in 0..<1000 where store.state(for: .codex).isRefreshing || store.state(for: .claude).isRefreshing { await Task.yield() }
        XCTAssertEqual(store.state(for: .codex).snapshot?.remainingPercent, 60)
        XCTAssertNil(store.state(for: .claude).snapshot)
        if case .keychainAccess = store.state(for: .claude).error {} else { XCTFail("Expected Claude access state") }
        store.setEnabled(false)
    }

    @MainActor
    func testHidingLimitsDiscardsInFlightResults() async {
        let provider = LimitsProviderStub()
        let store = AILimitsStore(provider: provider)
        store.setEnabled(true)
        for _ in 0..<1000 where provider.pending.count < 2 { await Task.yield() }
        store.setEnabled(false)
        for (_, continuation) in provider.pending { continuation.resume(throwing: AIUsageError.unavailable) }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(AIProvider.allCases.allSatisfy { !store.state(for: $0).isRefreshing && store.state(for: $0).error == nil })
    }
}
