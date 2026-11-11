import AppKit
import Combine

/// Chord's hotkey window tiling, run inside Macbar (it used to be a separate app).
@MainActor
final class ChordService {
    let settings = SettingsStore()
    let access = AccessibilityStatus()
    private let hotkeys = Hotkeys()
    private lazy var coordinator = ChordCoordinator(settings: settings)
    private let settingsWindow = SettingsWindow()
    private lazy var tapWatch = TapWatch { [unowned self] in self.settings.modifiers }
    private var trustSubscription: AnyCancellable?

    /// The tile's placed windows, for the taskbar to show as one group.
    var onTileWindows: @MainActor ([(bundleID: String, pid: pid_t, window: AXUIElement)]) -> Void = { _ in }

    func start() {
        coordinator.onTileWindows = { [weak self] in self?.onTileWindows($0) }
        // Per-element timeouts only cover the element they are set on; this sets the default
        // for every element, including window elements copied from apps.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AX.messagingTimeout)
        access.start()
        hotkeys.onPress = { [weak self] in self?.coordinator.handle($0) }
        hotkeys.onRelease = { [weak self] in self?.coordinator.release($0) }
        hotkeys.onArrow = { [weak self] in self?.coordinator.nudge($0) }
        hotkeys.onHistory = { [weak self] in self?.coordinator.step($0) }
        hotkeys.onSize = { [weak self] in self?.coordinator.size($0) }
        coordinator.onTileCount = { [weak self] in self?.hotkeys.setTileKeys(for: $0) }
        hotkeys.install()
        tapWatch.onTap = { [weak self] in
            guard let self, self.coordinator.tileCount > 0 else { return }
            self.coordinator.dropTile()
        }
        // Watching modifiers in other apps needs Accessibility, which may be granted later.
        trustSubscription = access.$trusted.sink { [weak self] trusted in
            if trusted { self?.tapWatch.start() }
        }
        settings.onHotkeysChanged = { [weak self] in self?.syncHotkeys() }
        syncHotkeys()
        settings.onHideOthersChanged = { [weak self] on in if !on { self?.coordinator.restoreAll() } }
        settings.onKeptAppAdded = { [weak self] in self?.coordinator.restore(bundleID: $0.bundleID) }
        if AXIsProcessTrusted() { coordinator.showAll() }
    }

    func dropTile() { coordinator.dropTile() }
    func stop() { coordinator.restoreAll() }
    func showAllWindows() { coordinator.showAll() }
    func showSettings() { settingsWindow.show(settings: settings, access: access) }

    private func syncHotkeys() {
        if settings.enabled {
            settings.failedKeys = hotkeys.register(settings.bindings.map(\.key), modifiers: settings.modifiers)
            hotkeys.setTileKeys(for: coordinator.tileCount)
        } else {
            hotkeys.unregisterAll()
            settings.failedKeys = []
            coordinator.dropTile()
            coordinator.restoreAll()
        }
    }
}
