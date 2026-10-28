import XCTest
import CoreWLAN
@testable import Macbar

private final class MockAudioOutput: AudioOutputControlling {
    var state = AudioOutputState(deviceID: 42, name: "Test speakers", volume: 0.6, muted: false, canSetVolume: true, canSetMute: true)
    var writes = 0
    var failWrites = false
    func readOutput() throws -> AudioOutputState { state }
    func setVolume(_ volume: Double, device: UInt32) throws {
        if failWrites { throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Output disconnected"]) }
        XCTAssertEqual(device, state.deviceID)
        writes += 1
        state.volume = volume
        if !state.canSetMute { state.muted = volume == 0 }
    }
    func setMuted(_ muted: Bool, device: UInt32) throws {
        XCTAssertEqual(device, state.deviceID)
        writes += 1
        state.muted = muted
    }
}

@MainActor
private final class MockKeyboardInput: KeyboardInputControlling {
    let english = KeyboardInputSource(id: "test.english", name: "ABC", languages: ["en"])
    let russian = KeyboardInputSource(id: "test.russian", name: "Russian", languages: ["ru"])
    var state: KeyboardInputState
    var selections: [String] = []
    var failSelection = false

    init() {
        state = KeyboardInputState(sources: [english, russian], current: english)
    }

    func readState() -> KeyboardInputState { state }
    func select(id: String) throws {
        selections.append(id)
        guard !failSelection, let source = state.sources.first(where: { $0.id == id }) else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Input source unavailable"])
        }
        state.current = source
    }
}

final class TrayControlTests: XCTestCase {
    @MainActor
    func testKeyboardDisplayReadsCurrentSourceWithoutChangingIt() {
        let backend = MockKeyboardInput()
        let store = KeyboardInputStore(backend: backend, observeChanges: false)
        XCTAssertEqual(store.current, backend.english)
        XCTAssertEqual(store.sources.map(\.id), [backend.english.id, backend.russian.id])
        XCTAssertTrue(backend.selections.isEmpty)
    }

    @MainActor
    func testKeyboardRefreshFollowsExternalChangesAndRemovedSources() {
        let backend = MockKeyboardInput()
        let store = KeyboardInputStore(backend: backend, observeChanges: false)
        backend.state = KeyboardInputState(sources: [backend.russian], current: backend.russian)
        store.refresh()
        XCTAssertEqual(store.current?.shortLabel, "RU")
        XCTAssertEqual(store.sources, [backend.russian])
        XCTAssertTrue(backend.selections.isEmpty)
        backend.state = KeyboardInputState(sources: [], current: nil)
        store.refresh()
        XCTAssertNil(store.current)
        XCTAssertTrue(store.sources.isEmpty)
    }

    @MainActor
    func testKeyboardSelectionReportsFailureAndShowsActualSystemState() {
        let backend = MockKeyboardInput()
        let store = KeyboardInputStore(backend: backend, observeChanges: false)
        backend.failSelection = true
        store.select(backend.russian.id)
        XCTAssertEqual(store.current, backend.english)
        XCTAssertEqual(store.error, "Input source unavailable")
        backend.failSelection = false
        store.select(backend.russian.id)
        XCTAssertEqual(store.current, backend.russian)
        XCTAssertNil(store.error)
        XCTAssertEqual(backend.selections, [backend.russian.id, backend.russian.id])
    }

    func testKeyboardLabelsHandleRegionalLanguagesAndSpecialLayouts() {
        XCTAssertEqual(KeyboardInputSource(id: "abc", name: "ABC", languages: ["en"]).shortLabel, "ABC")
        XCTAssertEqual(KeyboardInputSource(id: "lv", name: "Latvian", languages: ["lv-LV"]).shortLabel, "LV")
        XCTAssertEqual(KeyboardInputSource(id: "hex", name: "Unicode Hex Input", languages: [""]).shortLabel, "UNI")
        XCTAssertEqual(KeyboardInputSource(id: "unknown", name: "", languages: []).shortLabel, "⌨")
    }

    @MainActor
    func testOpeningVolumeOnlyReadsOutput() {
        let backend = MockAudioOutput()
        let store = AudioStore(backend: backend, observeChanges: false)
        XCTAssertEqual(store.output.volume, 0.6)
        XCTAssertEqual(store.output.name, "Test speakers")
        XCTAssertEqual(backend.writes, 0)
    }

    @MainActor
    func testSliderClampsAndUnmutes() {
        let backend = MockAudioOutput()
        backend.state.muted = true
        let store = AudioStore(backend: backend, observeChanges: false)
        store.setVolume(1.5)
        XCTAssertEqual(store.output.volume, 1)
        XCTAssertFalse(store.output.muted)
        store.setVolume(-0.2)
        XCTAssertEqual(store.output.volume, 0)
    }

    @MainActor
    func testMuteFallbackRestoresPreviousVolume() {
        let backend = MockAudioOutput()
        backend.state.canSetMute = false
        let store = AudioStore(backend: backend, observeChanges: false)
        store.toggleMute()
        XCTAssertEqual(store.output.volume, 0)
        store.toggleMute()
        XCTAssertEqual(store.output.volume, 0.6, accuracy: 0.001)
    }

    @MainActor
    func testFixedVolumeOutputDoesNotWrite() {
        let backend = MockAudioOutput()
        backend.state.canSetVolume = false
        backend.state.canSetMute = false
        let store = AudioStore(backend: backend, observeChanges: false)
        store.setVolume(0.4)
        store.toggleMute()
        XCTAssertEqual(backend.writes, 0)
        XCTAssertEqual(store.symbol, "speaker.wave.2")
    }

    @MainActor
    func testFailedWriteKeepsActualVolumeAndReportsError() {
        let backend = MockAudioOutput()
        backend.failWrites = true
        let store = AudioStore(backend: backend, observeChanges: false)
        store.setVolume(0.8)
        XCTAssertEqual(store.output.volume, 0.6)
        XCTAssertEqual(store.error, "Output disconnected")
    }

    @MainActor
    func testRefreshFollowsNewOutputDevice() {
        let backend = MockAudioOutput()
        let store = AudioStore(backend: backend, observeChanges: false)
        backend.state.deviceID = 99
        backend.state.name = "Headphones"
        backend.state.volume = 0.25
        store.refresh()
        store.setVolume(0.3)
        XCTAssertEqual(store.output.deviceID, 99)
        XCTAssertEqual(store.output.name, "Headphones")
    }

    func testWiFiDeduplicatesAccessPointsAndPinsConnectedNetworkFirst() {
        func item(_ ssid: String, _ signal: Int) -> WiFiNetworkItem {
            WiFiNetworkItem(ssid: ssid, signal: signal, secured: true, enterprise: false, network: CWNetwork())
        }
        let results = WiFiNetworkItem.sortedUnique([
            item("Home", -80), item("Home", -45), item("Connected", -90), item("Other", -60), item("", -20)
        ], connectedSSID: "Connected")
        XCTAssertEqual(results.map(\.ssid), ["Connected", "Home", "Other"])
        XCTAssertEqual(results[1].signal, -45)
    }
}
