import Carbon.HIToolbox
import os

private let log = Logger(subsystem: "studio.macbar.chord", category: "hotkeys")

/// Global hotkeys via Carbon `RegisterEventHotKey` (needs no permission).
@MainActor
final class Hotkeys {
    var onPress: @MainActor (TriggerKey) -> Void = { _ in }
    var onRelease: @MainActor (TriggerKey) -> Void = { _ in }
    var onArrow: @MainActor (Direction) -> Void = { _ in }
    var onHistory: @MainActor (HistoryMove) -> Void = { _ in }
    var onSize: @MainActor (SizeKey) -> Void = { _ in }

    private var handlerRef: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []
    private var keys: [UInt32: TriggerKey] = [:]
    private var moves: [UInt32: HistoryMove] = [:]
    private var tileRefs: [EventHotKeyRef] = []
    private var arrows: [UInt32: Direction] = [:]
    private var sizes: [UInt32: SizeKey] = [:]
    /// Modifiers of the current registration; nil while nothing is registered (disabled).
    private var modifiers: Modifiers?

    func install() {
        guard handlerRef == nil else { return }
        let specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyHandler, specs.count, specs,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        if status != noErr { log.error("InstallEventHandler failed: \(status)") }
    }

    /// Replaces all registered hotkeys with `triggerKeys` + `modifiers`.
    /// Returns the keys that could not be registered (another app holds them exclusively).
    ///
    /// Registration is exclusive: apps that registered the same combo non-exclusively (most do)
    /// stop receiving it while we hold it, so one press doesn't trigger both. Carbon can only
    /// report a conflict with another exclusive registrant.
    func register(_ triggerKeys: [TriggerKey], modifiers: Modifiers) -> Set<TriggerKey> {
        unregisterAll()
        self.modifiers = modifiers
        var failed = Set<TriggerKey>()
        for (i, key) in triggerKeys.enumerated() {
            let id = UInt32(i + 1)
            guard let ref = add(key.keyCode, modifiers, id: id, name: key.rawValue) else {
                failed.insert(key)
                continue
            }
            refs.append(ref)
            keys[id] = key
        }
        for (i, move) in HistoryMove.allCases.enumerated() {
            let id = UInt32(200 + i)
            guard let ref = add(move.keyCode, modifiers, id: id, name: "\(move)") else { continue }
            refs.append(ref)
            moves[id] = move
        }
        return failed
    }

    /// Takes the trigger modifiers + the arrows and digits a tile of `count` windows can use, and
    /// releases the rest to the frontmost app, so they are only held while the tile on screen has
    /// a divider for them. Does nothing while unregistered.
    func setTileKeys(for count: Int) {
        tileRefs.forEach { UnregisterEventHotKey($0) }
        tileRefs.removeAll()
        arrows.removeAll()
        sizes.removeAll()
        guard let modifiers else { return }
        for direction in Splits.directions(for: count) {
            let id = 100 + UInt32(Direction.allCases.firstIndex(of: direction)!)
            guard let ref = add(direction.keyCode, modifiers, id: id, name: "\(direction)") else { continue }
            tileRefs.append(ref)
            arrows[id] = direction
        }
        for size in SizeKey.available(for: count) {
            let id = 300 + UInt32(size.rawValue)
            guard let ref = add(size.keyCode, modifiers, id: id, name: "\(size.rawValue)") else { continue }
            tileRefs.append(ref)
            sizes[id] = size
        }
    }

    func unregisterAll() {
        (refs + tileRefs).forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        tileRefs.removeAll()
        keys.removeAll()
        moves.removeAll()
        arrows.removeAll()
        sizes.removeAll()
        modifiers = nil
    }

    /// Trigger keys report presses and releases; the rest act on presses only.
    fileprivate func fire(_ id: UInt32, pressed: Bool) {
        if let key = keys[id] {
            pressed ? onPress(key) : onRelease(key)
            return
        }
        guard pressed else { return }
        if let direction = arrows[id] {
            onArrow(direction)
        } else if let move = moves[id] {
            onHistory(move)
        } else if let size = sizes[id] {
            onSize(size)
        }
    }

    private func add(_ keyCode: UInt32, _ modifiers: Modifiers, id: UInt32, name: String) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers.carbonFlags,
            EventHotKeyID(signature: 0x4348_5244 /* 'CHRD' */, id: id),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref
        )
        guard status == noErr, let ref else {
            log.error("RegisterEventHotKey failed for \(name): \(status)")
            return nil
        }
        return ref
    }
}

/// Carbon dispatches application-target events on the main thread.
private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr else { return status }
    let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    MainActor.assumeIsolated { hotkeys.fire(id, pressed: pressed) }
    return noErr
}
