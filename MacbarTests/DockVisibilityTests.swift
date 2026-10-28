import XCTest
@testable import Macbar

final class DockVisibilityTests: XCTestCase {
    private var domain = ""
    private var journal = ""
    private var lock: URL!

    override func setUp() {
        domain = "studio.macbar.tests.dock.\(UUID().uuidString)"
        journal = "\(domain).recovery"
        lock = FileManager.default.temporaryDirectory.appendingPathComponent("\(domain).lock")
    }

    override func tearDown() {
        _ = defaults("delete", domain)
        _ = defaults("delete", journal)
        try? FileManager.default.removeItem(at: lock)
    }

    private func defaults(_ arguments: String...) -> String? {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = arguments
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        try! task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func controller() -> DockVisibilityController {
        DockVisibilityController(domain: domain, recoveryDomain: journal, lockURL: lock, restartPath: "/usr/bin/true")
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if condition() { return }
            usleep(50_000)
        }
        XCTFail("Timed out waiting for Dock preferences", file: file, line: line)
    }

    func testRestoresPreviouslySetValues() {
        _ = defaults("write", domain, "autohide", "-bool", "false")
        _ = defaults("write", domain, "autohide-delay", "-float", "0.25")
        let manager = controller()
        manager.setHidden(true)
        waitUntil { self.defaults("read", self.domain, "autohide-delay") == "1000" }
        XCTAssertEqual(defaults("read", domain, "autohide"), "1")
        manager.setHidden(false)
        waitUntil { self.defaults("read", self.domain, "autohide") == "0" && self.defaults("read", self.domain, "autohide-delay") == "0.25" }
    }

    func testRestoresMissingKeysAndPreservesExternalChanges() {
        let manager = controller()
        manager.setHidden(true)
        waitUntil { self.defaults("read", self.domain, "autohide-delay") == "1000" }
        _ = defaults("write", domain, "autohide", "-bool", "false")
        manager.setHidden(false)
        waitUntil { self.defaults("read", self.domain, "autohide-delay") == nil }
        XCTAssertEqual(defaults("read", domain, "autohide"), "0")
    }

    func testRecoveryJournalRestoresAfterInterruptedSession() {
        _ = defaults("write", domain, "autohide", "-bool", "true")
        _ = defaults("write", domain, "autohide-delay", "-float", "1000")
        _ = defaults("write", journal, "hasAutohide", "-bool", "true")
        _ = defaults("write", journal, "autohide", "-bool", "false")
        _ = defaults("write", journal, "hasDelay", "-bool", "false")
        _ = defaults("write", journal, "ready", "-bool", "true")
        controller().recover()
        waitUntil { self.defaults("read", self.domain, "autohide") == "0" && self.defaults("read", self.domain, "autohide-delay") == nil }
    }

    @MainActor
    func testPreferenceDefaultsOffAndPersists() {
        let suite = "MacbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertFalse(preferences.hideDockWhileRunning)
        preferences.hideDockWhileRunning = true
        XCTAssertTrue(Preferences(defaults: defaults).hideDockWhileRunning)
    }
}
