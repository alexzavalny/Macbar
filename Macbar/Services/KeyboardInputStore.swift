import AppKit
import Carbon
import Combine

struct KeyboardInputSource: Identifiable, Equatable {
    let id: String
    let name: String
    let languages: [String]

    var shortLabel: String {
        if !name.isEmpty && name.count <= 4 { return name }
        if let language = languages.first?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first,
           !language.isEmpty { return language.uppercased() }
        return name.isEmpty ? "⌨" : String(name.prefix(3)).uppercased()
    }
}

struct KeyboardInputState {
    var sources: [KeyboardInputSource]
    var current: KeyboardInputSource?
}

@MainActor
protocol KeyboardInputControlling {
    func readState() -> KeyboardInputState
    func select(id: String) throws
}

@MainActor
struct SystemKeyboardInput: KeyboardInputControlling {
    func readState() -> KeyboardInputState {
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        var seen = Set<String>()
        return KeyboardInputState(
            sources: enabledSources().compactMap(Self.item).filter { seen.insert($0.id).inserted },
            current: current.flatMap(Self.item))
    }

    func select(id: String) throws {
        // Re-resolve at selection time: settings may have removed a menu item.
        guard let source = enabledSources().first(where: { Self.item($0)?.id == id }) else {
            throw NSError(domain: "Macbar.KeyboardInput", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This input source is no longer available. Check Keyboard Settings and try again."])
        }
        let status = TISSelectInputSource(source)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "macOS couldn’t select this input source (\(status))."])
        }
    }

    private func enabledSources() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
                      kTISPropertyInputSourceIsEnabled as String: true,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        return TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    private static func item(_ source: TISInputSource) -> KeyboardInputSource? {
        guard let id = property(source, kTISPropertyInputSourceID) as? String else { return nil }
        return KeyboardInputSource(id: id,
                                   name: property(source, kTISPropertyLocalizedName) as? String ?? id,
                                   languages: property(source, kTISPropertyInputSourceLanguages) as? [String] ?? [])
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
}

@MainActor
final class KeyboardInputStore: ObservableObject {
    @Published private(set) var sources: [KeyboardInputSource] = []
    @Published private(set) var current: KeyboardInputSource?
    @Published private(set) var error: String?
    private let backend: KeyboardInputControlling
    private var observations = Set<AnyCancellable>()

    init(backend: KeyboardInputControlling? = nil, observeChanges: Bool = true) {
        self.backend = backend ?? SystemKeyboardInput()
        refresh()
        guard observeChanges else { return }
        for name in [kTISNotifySelectedKeyboardInputSourceChanged, kTISNotifyEnabledKeyboardInputSourcesChanged].compactMap({ $0 }) {
            DistributedNotificationCenter.default().publisher(for: Notification.Name(name as String))
                .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }.store(in: &observations)
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }.store(in: &observations)
        }
    }

    func refresh() {
        let state = backend.readState()
        if sources != state.sources { sources = state.sources }
        if current != state.current { current = state.current }
    }

    func select(_ id: String) {
        do {
            try backend.select(id: id)
            error = nil
        } catch { self.error = error.localizedDescription }
        // Display what macOS actually selected, including after a failed request.
        refresh()
    }
}
