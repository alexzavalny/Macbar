import AppKit

/// Turns hotkey presses into combo sessions: brings each app up and tiles the session's windows.
///
/// A session opens on the first press and closes when the trigger modifiers are released.
/// Windows that show up after the release still get placed for that session; a new session
/// drops whatever an older one was still waiting for. Each chord played is recorded in a
/// history that ⌃⌥[ / ⌃⌥] replay, sizes included. Dragging an edge between tiled windows
/// with the mouse moves the divider. A key pressed again in a chord tiles another window of its
/// app; a tiled window that closes leaves the tile.
@MainActor
final class ChordCoordinator {
    /// How long a launch Chord started is watched for taking focus when it finishes.
    static let launchWatch: Duration = .seconds(5)
    /// Move and resize events this soon after Chord set a window's frame are its own doing.
    static let echoWindow: CFTimeInterval = 0.15
    /// How often the neighbours follow a dragged window, and the mouse is checked for release.
    static let followInterval: Duration = .milliseconds(33)
    /// How many times a layout re-reads sizes the apps insist on.
    static let adoptRounds = 2
    /// How long displays must stay unchanged before the tile and hidden windows follow them.
    static let screensSettle: Duration = .seconds(1)

    /// A place in the tile: the app pressed for it and, once known, its pid and window.
    private struct Slot {
        let id: Int
        let binding: AppBinding
        var pid: pid_t?
        var window: AXUIElement?
    }

    private let settings: SettingsStore
    private let launcher = AppLauncher()
    private let watch = ModifierWatch()
    /// Watches the hold a digit was pressed in, so the next hold's first digit sets the width again.
    private let sizeWatch = ModifierWatch()
    private let hider = WindowHider()
    private let tileWatcher = TileWatcher()
    /// When Chord last set each tile window's frame.
    private var wroteAt: [AXUIElement: CFTimeInterval] = [:]
    /// The tile window being dragged with the mouse (by slot id), and the splits the drag started from.
    private var drag: (slot: Int, base: Splits)?
    private var followPending = false
    private var session = ComboSession()
    /// The tile in press order; `session.keys[i]` is `slots[i]`'s key. A replay brings the apps
    /// it recorded.
    private var slots: [Slot] = []
    private var nextSlotID = 0
    /// Windows taken by a slot of the current tile (by slot id), so two slots never share one.
    private var claims: [AXUIElement: Int] = [:]
    private var isOpen = false
    /// The tile on screen is a chord being played that the history hasn't recorded yet.
    private var pendingRecord = false
    private var history = ComboHistory()
    private var generation = 0
    private var display: Screens.Display?
    private var splits = Splits()
    private var sizePresses = SizePresses()
    /// Apps Chord opened that were still launching. A launch activates the app when it
    /// finishes, which must not take focus from a key pressed since, in this session or a newer one.
    private var launching: Set<pid_t> = []
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var screensObserver: NSObjectProtocol?
    private var screensChange: Task<Void, Never>?
    /// The displays as last acted on.
    private var knownDisplays: [Screens.Display] = []

    /// Called when the number of windows in the current tile changes.
    var onTileCount: @MainActor (Int) -> Void = { _ in }

    var tileCount: Int { slots.count }

    init(settings: SettingsStore) {
        self.settings = settings
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid else { return }
                self.activated(pid, bundleID: bundleID)
            }
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid else { return }
                self.hider.drop(pid: pid)
                self.removeSlots { $0.pid == pid }
            }
        }
        tileWatcher.onChange = { [weak self] in self?.windowChanged($0) }
        tileWatcher.onClose = { [weak self] _ in self?.windowsClosed() }
        knownDisplays = Screens.all()
        screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    func handle(_ key: TriggerKey) {
        guard let binding = settings.bindings.binding(for: key) else { return }
        if !isOpen { begin() }
        guard session.press(key, windows: { self.windowCount(binding) }) else { return }
        addSlot(binding)
    }

    /// The trigger key was let go: its next press may tile another window of its app.
    func release(_ key: TriggerKey) {
        session.release(key)
    }

    private func begin() {
        isOpen = true
        pendingRecord = true
        reset(splits: Splits())
    }

    /// A new tile replaces the current one: work still pending for the old one is dropped.
    private func reset(splits: Splits) {
        generation += 1
        session = ComboSession()
        slots = []
        claims = [:]
        display = Screens.underMouse()
        self.splits = splits
        sizePresses.reset()
        tileWatcher.stop()
        wroteAt = [:]
        drag = nil
        watch.start(settings.modifiers) { [weak self] in self?.end() }
    }

    /// The modifiers were released: record the chord, hide everything on the display but the tile.
    private func end() {
        isOpen = false
        record()
        guard settings.hideOthers, AXIsProcessTrusted(), let display else { return }
        let kept = Set(settings.keptApps.map(\.bundleID))
        let keepPIDs = Set(NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier.map(kept.contains) ?? false }
            .map(\.processIdentifier))
        hider.hideOthers(keep: Set(slots.compactMap(\.window)), keepPIDs: keepPIDs, display: display, displays: Screens.all())
    }

    /// Adds the chord just played to the history, once.
    private func record() {
        guard pendingRecord, !slots.isEmpty else { return }
        pendingRecord = false
        history.record(Combo(apps: slots.map(\.binding), splits: splits))
    }

    /// ⌃⌥[ / ⌃⌥]: replays the previous / next chord with its sizes, without recording it again.
    /// A chord still held is recorded first. Beeps at either end.
    func step(_ move: HistoryMove) {
        isOpen = false
        record()
        guard let combo = move == .back ? history.back() : history.forward() else {
            NSSound.beep()
            return
        }
        reset(splits: combo.splits)
        for binding in combo.apps {
            if session.add(binding.key, windows: { self.windowCount(binding) }) { addSlot(binding) }
        }
    }

    /// Standard windows of `binding`'s app on this Space, minimized and parked ones included;
    /// 0 when it isn't running or without Accessibility.
    private func windowCount(_ binding: AppBinding) -> Int {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: binding.bundleID).first
        else { return 0 }
        return AX.orderedWindows(of: app.processIdentifier).count
    }

    /// A slot for `binding`, whose key the session just took, at the end of the tile.
    private func addSlot(_ binding: AppBinding) {
        let id = nextSlotID
        nextSlotID += 1
        slots.append(Slot(id: id, binding: binding))
        onTileCount(slots.count)
        let gen = generation
        Task { await self.bring(slot: id, binding, generation: gen) }
    }

    /// Takes the slots matching `gone` out of the tile; the rest fill the space.
    private func removeSlots(where gone: (Slot) -> Bool) {
        let doomed = slots.indices.filter { gone(slots[$0]) }
        guard !doomed.isEmpty else { return }
        for i in doomed.reversed() {
            let id = slots[i].id
            if drag?.slot == id { drag = nil }
            claims = claims.filter { $0.value != id }
            slots.remove(at: i)
            session.remove(at: i)
        }
        onTileCount(slots.count)
        watchTile()
        layout(focus: false)
    }

    /// Tiled windows were closed. Closing a native tab leaves a sibling tab where it was: that
    /// window takes the slot over. Any other slot whose window is gone leaves the tile.
    private func windowsClosed() {
        if let screen = display?.visible {
            let frames = GridLayout.frames(count: slots.count, in: screen, gap: settings.gap, splits: splits)
            var tookOver = false
            for (i, frame) in zip(slots.indices, frames) {
                guard let w = slots[i].window, !AX.exists(w), let pid = slots[i].pid else { continue }
                let free = AX.orderedWindows(of: pid).filter { claims[$0] == nil }
                guard let j = GridLayout.match(frame, in: free.map { AX.frame($0) }) else { continue }
                let id = slots[i].id
                claims = claims.filter { $0.value != id }
                claims[free[j]] = id
                slots[i].window = free[j]
                tookOver = true
            }
            if tookOver { watchTile() }
        }
        removeSlots { $0.window.map { !AX.exists($0) } ?? false }
    }

    private func index(of id: Int) -> Int? {
        slots.firstIndex { $0.id == id }
    }

    /// The first of `windows` no other slot has taken, now taken by slot `id`.
    private func claim(_ windows: [AXUIElement], for id: Int) -> AXUIElement? {
        guard let w = windows.first(where: { claims[$0] == nil || claims[$0] == id }) else { return nil }
        claims[w] = id
        return w
    }

    private func watchTile() {
        tileWatcher.watch(slots.compactMap { s -> (window: AXUIElement, pid: pid_t)? in
            guard let w = s.window, let pid = s.pid else { return nil }
            return (w, pid)
        })
    }

    /// Menu → Show All Windows: every hidden window back, strays from a crash gathered.
    func showAll() {
        hider.restoreAll()
        if AXIsProcessTrusted() { hider.gatherStrays(displays: Screens.all()) }
    }

    /// Puts back the hidden windows of `bundleID`'s app (just added to the never-hide list).
    func restore(bundleID: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            hider.restore(pid: app.processIdentifier)
        }
    }

    /// Chord was disabled, or the trigger modifiers were tapped alone: the tile is let go, so
    /// nothing moves its windows any more. They stay where they are.
    func dropTile() {
        generation += 1
        watch.stop()
        isOpen = false
        pendingRecord = false
        session = ComboSession()
        slots = []
        claims = [:]
        tileWatcher.stop()
        drag = nil
        onTileCount(0)
    }

    /// Disable, hide toggle off, quit.
    func restoreAll() {
        hider.restoreAll()
    }

    /// Any app came to the front. A launch Chord started finishing late must not take focus
    /// from a newer key; an app outside the current session gets its hidden windows back.
    private func activated(_ pid: pid_t, bundleID: String?) {
        if launching.remove(pid) != nil { keepLatestInFront(over: pid) }
        let sessionApps = Set(slots.map(\.binding.bundleID))
        guard !sessionApps.contains(bundleID ?? "") else { return }
        hider.restore(pid: pid)
        if AXIsProcessTrusted() { hider.gatherStrays(displays: Screens.all(), pid: pid) }
    }

    private func bring(slot id: Int, _ binding: AppBinding, generation gen: Int) async {
        guard let pid = await launcher.open(binding) else { return }
        watchLaunch(pid)
        guard gen == generation, let i = index(of: id) else { return }
        slots[i].pid = pid
        guard AXIsProcessTrusted() else { return }
        let window = await launcher.window(
            of: pid, pick: { self.claim($0, for: id) },
            while: { gen == self.generation && self.index(of: id) != nil }
        )
        guard gen == generation, let i = index(of: id) else { return }
        guard let window else {
            // The app showed no window: its slot leaves the tile.
            removeSlots { $0.id == id }
            return
        }
        slots[i].window = window
        watchTile()
        layout()
    }

    /// Watches a still-launching app for the activation its launch ends with.
    private func watchLaunch(_ pid: pid_t) {
        guard NSRunningApplication(processIdentifier: pid)?.isFinishedLaunching == false else { return }
        launching.insert(pid)
        Task {
            try? await Task.sleep(for: Self.launchWatch)
            self.launching.remove(pid)
        }
    }

    /// `pid` just came to the front. If it isn't the app of the current session's last key,
    /// puts that app back in front.
    private func keepLatestInFront(over pid: pid_t) {
        guard let last = slots.last, let latest = last.pid, latest != pid else { return }
        if let w = last.window {
            AX.focus(w, pid: latest)
        } else {
            // Without a placed window (no Accessibility, or still loading) go through
            // LaunchServices: activate() from a background app may be refused.
            Task { _ = await self.launcher.open(last.binding) }
        }
    }

    /// Displays came, went or changed size (Dock, resolution, arrangement). Once macOS has
    /// moved windows around, the hidden windows and the tile follow.
    private func screensChanged() {
        screensChange?.cancel()
        screensChange = Task {
            try? await Task.sleep(for: Self.screensSettle)
            guard !Task.isCancelled else { return }
            self.displaysSettled()
        }
    }

    /// Hidden windows go to the corner of the display they are on now; the tile is laid out
    /// again on its display, or where its windows landed if that display is gone.
    private func displaysSettled() {
        let displays = Screens.all()
        guard displays != knownDisplays else { return }
        knownDisplays = displays
        guard AXIsProcessTrusted() else { return }
        hider.repark(displays: displays)
        guard let old = display, !slots.isEmpty else { return }
        let frames = displays.map(\.frame)
        let landed = slots.lazy.compactMap { $0.window.flatMap { AX.frame($0) } }.first
            .flatMap { Parking.home(of: $0, displays: frames) }.map { displays[$0] }
        let next = displays.first { $0.id == old.id } ?? landed ?? displays.first
        // A change to another display leaves the tile (and windows moved since) alone.
        guard next != old else { return }
        display = next
        layout(focus: false)
    }

    /// Moves a divider of the current tile (also after the modifiers are released).
    func nudge(_ direction: Direction) {
        guard Splits.applies(direction, count: slots.count), AXIsProcessTrusted() else { return }
        splits.nudge(direction)
        if !pendingRecord { history.setSplits(splits) }
        layout(focus: false)
    }

    /// ⌃⌥2…5: gives the right window, then the bottom one, 1/N of the tile (also after the
    /// modifiers are released). Each hold of the modifiers starts again at the width.
    func size(_ key: SizeKey) {
        guard AXIsProcessTrusted(), let next = sizePresses.press(key, count: slots.count, splits: splits) else { return }
        sizeWatch.start(settings.modifiers) { [weak self] in self?.sizePresses.reset() }
        splits = next
        if !pendingRecord { history.setSplits(splits) }
        layout(focus: false)
    }

    /// A tile window moved or resized. Only a mouse drag counts: while the button is down the
    /// neighbours follow the window's inner edges, and on release the whole tile snaps into place.
    private func windowChanged(_ window: AXUIElement) {
        guard settings.enabled, NSEvent.pressedMouseButtons & 1 != 0, slots.count >= 2 else { return }
        if let t = wroteAt[window], CACurrentMediaTime() - t < Self.echoWindow { return }
        guard let slot = slots.first(where: { $0.window == window }) else { return }
        if drag == nil {
            drag = (slot: slot.id, base: splits)
            trackDrag()
        }
        guard drag?.slot == slot.id, !followPending else { return }
        followPending = true
        Task {
            try? await Task.sleep(for: Self.followInterval)
            self.followPending = false
            self.follow()
        }
    }

    /// Lays the other windows out around the dragged one's inner edges.
    private func follow() {
        guard let drag, let i = index(of: drag.slot), let w = slots[i].window,
              let screen = display?.visible, let frame = AX.frame(w) else { return }
        let next = GridLayout.splits(dragging: i, to: frame, count: slots.count, in: screen,
                                     gap: settings.gap, from: drag.base)
        guard next != splits else { return }
        splits = next
        layout(focus: false, skip: drag.slot)
    }

    /// Waits for the mouse button to come up, then snaps the whole tile into place: a moved
    /// window or a dragged outer edge goes back to its slot.
    private func trackDrag() {
        let gen = generation
        Task {
            while NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: Self.followInterval)
            }
            guard gen == self.generation, self.drag != nil else { return }
            self.follow()
            self.drag = nil
            if !self.pendingRecord { self.history.setSplits(self.splits) }
            self.layout(focus: false)
        }
    }

    /// Puts every window that has arrived into its slot for the tile's count, except slot
    /// `skip`'s (a window being dragged). With `focus`, raises them and focuses the last-pressed
    /// app if its window is among them. Then sizes the apps insist on are adopted, unless a drag
    /// is deciding the dividers.
    private func layout(focus: Bool = true, skip: Int? = nil) {
        guard let screen = display?.visible else { return }
        place(on: screen, focus: focus, skip: skip)
        if skip == nil { adoptSizes(on: screen) }
    }

    private func place(on screen: CGRect, focus: Bool, skip: Int?) {
        let frames = GridLayout.frames(count: slots.count, in: screen, gap: settings.gap, splits: splits)
        for (slot, frame) in zip(slots, frames) where slot.id != skip {
            guard let w = slot.window, let pid = slot.pid else { continue }
            hider.forget(w)
            AX.setFrame(w, frame, pid: pid)
            wroteAt[w] = CACurrentMediaTime()
            if focus { AX.raise(w) }
        }
        if focus, let last = slots.last, let w = last.window, let pid = last.pid {
            AX.focus(w, pid: pid)
        }
    }

    /// Windows that didn't take their slot's size (a minimum or maximum size, a character grid)
    /// keep theirs, and the dividers move so nothing overlaps.
    private func adoptSizes(on screen: CGRect) {
        let before = splits
        for _ in 0..<Self.adoptRounds {
            let actual = slots.map { s in
                s.window.flatMap { w in AX.isFullScreen(w) || AX.isMinimized(w) ? nil : AX.frame(w) }
            }
            let next = GridLayout.splits(fitting: actual, count: slots.count, in: screen, gap: settings.gap, from: splits)
            guard next != splits else { break }
            splits = next
            place(on: screen, focus: false, skip: nil)
        }
        if splits != before, !pendingRecord { history.setSplits(splits) }
    }
}
