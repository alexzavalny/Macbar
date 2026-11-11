import AppKit
import ServiceManagement
import os

private let log = Logger(subsystem: "studio.macbar.chord", category: "settings")

/// User settings, persisted in UserDefaults. Bindings are written only when the user changes
/// them, so a stored value that fails to decode is left alone.
@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let bindings = "chord.bindings"
        static let modifiers = "chord.modifiers"
        static let gap = "chord.gap"
        static let enabled = "chord.enabled"
        static let hideOthers = "chord.hideOthers"
        static let keepVisible = "chord.keepVisible"
    }

    static let gapRange: ClosedRange<Double> = 0...32

    @Published private(set) var bindings: [AppBinding]
    @Published private(set) var modifiers: Modifiers
    @Published private(set) var enabled: Bool
    @Published private(set) var hideOthers: Bool
    /// Apps whose windows are never hidden.
    @Published private(set) var keptApps: [KeptApp]
    @Published var gap: Double {
        didSet { defaults.set(gap, forKey: Key.gap) }
    }
    /// Keys whose hotkey could not be registered (taken by another app).
    @Published var failedKeys: Set<TriggerKey> = []
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var launchAtLoginError: String?

    /// Called after bindings, modifiers or the enabled flag change.
    var onHotkeysChanged: @MainActor () -> Void = {}
    /// Called after the hide-other-windows toggle changes.
    var onHideOthersChanged: @MainActor (Bool) -> Void = { _ in }
    /// Called after an app is added to the never-hide list.
    var onKeptAppAdded: @MainActor (KeptApp) -> Void = { _ in }

    private let defaults = UserDefaults.standard

    init() {
        let defaults = UserDefaults.standard
        Self.migrateStandaloneChord(into: defaults)
        if let json = defaults.string(forKey: Key.bindings) {
            if let list = BindingList.decode(json) {
                bindings = list
            } else {
                log.error("Stored bindings are not valid JSON; starting with none")
                bindings = []
            }
        } else {
            bindings = []
        }
        let stored = (defaults.object(forKey: Key.modifiers) as? Int).map { Modifiers(rawValue: $0 & 0xF) }
        modifiers = stored.flatMap { $0.isValid ? $0 : nil } ?? .default
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        hideOthers = defaults.object(forKey: Key.hideOthers) as? Bool ?? true
        keptApps = defaults.string(forKey: Key.keepVisible).flatMap(KeptAppList.decode) ?? []
        gap = min(max(defaults.double(forKey: Key.gap), Self.gapRange.lowerBound), Self.gapRange.upperBound)
    }

    /// One-time copy of the settings the standalone Chord app kept under its own bundle ID.
    private static func migrateStandaloneChord(into defaults: UserDefaults) {
        guard defaults.object(forKey: "chord.migrated") == nil else { return }
        defaults.set(true, forKey: "chord.migrated")
        guard let old = UserDefaults.standard.persistentDomain(forName: "com.local.chord") else { return }
        for key in ["bindings", "modifiers", "gap", "enabled", "hideOthers", "keepVisible"] {
            if let value = old[key] { defaults.set(value, forKey: "chord.\(key)") }
        }
    }

    func setBinding(_ binding: AppBinding) {
        bindings = bindings.setting(binding)
        saveBindings()
    }

    func removeBinding(_ key: TriggerKey) {
        bindings = bindings.removing(key)
        saveBindings()
    }

    /// Turns one modifier on or off. Returns false, changing nothing, if that would leave
    /// none of ⌃ ⌥ ⌘.
    func setModifier(_ flag: Modifiers, _ on: Bool) -> Bool {
        guard let next = modifiers.setting(flag, on) else { return false }
        modifiers = next
        defaults.set(next.rawValue, forKey: Key.modifiers)
        onHotkeysChanged()
        return true
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        defaults.set(on, forKey: Key.enabled)
        onHotkeysChanged()
    }

    func setHideOthers(_ on: Bool) {
        hideOthers = on
        defaults.set(on, forKey: Key.hideOthers)
        onHideOthersChanged(on)
    }

    func addKeptApp(_ app: KeptApp) {
        keptApps = keptApps.adding(app)
        defaults.set(KeptAppList.encode(keptApps), forKey: Key.keepVisible)
        onKeptAppAdded(app)
    }

    func removeKeptApp(bundleID: String) {
        keptApps = keptApps.removing(bundleID: bundleID)
        defaults.set(KeptAppList.encode(keptApps), forKey: Key.keepVisible)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func saveBindings() {
        defaults.set(BindingList.encode(bindings), forKey: Key.bindings)
        onHotkeysChanged()
    }
}
