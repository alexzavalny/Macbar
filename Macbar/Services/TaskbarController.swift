import AppKit
import SwiftUI
import Combine

enum Popup: Equatable { case start, launcher, calendar, settings, wifi, volume, battery, cpu, aiLimits }

final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class TaskbarHostingView<Content: View>: NSHostingView<Content> {
    private var cursorTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        cursorTracking = tracking
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}

final class FlyoutPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class TaskbarController: NSObject, ObservableObject {
    let preferences = Preferences()
    private let chord = ChordService()
    private let dockVisibility = DockVisibilityController()
    let applications: ApplicationStore
    let windowManagement: WindowManagementStore
    let audio = AudioStore()
    let battery = BatteryStore()
    let cpu = CPUStore()
    let wifi = WiFiStore()
    let keyboard = KeyboardInputStore()
    let aiLimits = AILimitsStore()
    let music = AppleMusicStore()
    let zoom = ZoomStore()
    let previews = WindowPreviewStore()
    let windowTiles = TaskbarWindowStore()
    let windowGroups = WindowGroupStore()
    @Published private(set) var popup: Popup?
    @Published private(set) var isVisible = true
    private var manuallyVisible = true
    @Published private(set) var displays: [TaskbarDisplay] = []
    @Published private(set) var visibleDisplayIDs = Set<CGDirectDisplayID>()
    @Published private(set) var popupDisplayID: CGDirectDisplayID?
    private var coveredDisplayIDs = Set<CGDirectDisplayID>()

    private var bars: [CGDirectDisplayID: BarPanel] = [:]
    private var flyout: FlyoutPanel?
    private var startHeight: CGFloat = 800
    private var statusItem: NSStatusItem?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var previewPanel: BarPanel?
    private var previewItem: ApplicationItem?
    private var previewDisplayID: CGDirectDisplayID?
    private var previewAnchor = CGRect.zero
    private var hoveredAppID: String?
    private var pendingPreview: Task<Void, Never>?
    private var previewTracking: Timer?
    private var previewOutsideSince: Date?
    private var windowTilesTimer: Timer?
    private var tileDragPanel: BarPanel?
    private var tileDragPointerOffset = CGPoint.zero
    private var cancellables = Set<AnyCancellable>()

    override init() {
        applications = ApplicationStore(preferences: preferences)
        windowManagement = WindowManagementStore(preferences: preferences)
        super.init()
    }

    func start() {
        Screens.bottomInset = { [weak self] in self.map { $0.isVisible ? $0.preferences.barHeight : 0 } ?? 0 }
        chord.start()
        dockVisibility.recover()
        dockVisibility.setHidden(preferences.hideDockWhileRunning)
        preferences.$hideDockWhileRunning.dropFirst().sink { [weak self] hidden in
            self?.dockVisibility.setHidden(hidden)
        }.store(in: &cancellables)
        reconcileDisplays()
        applyPreferences()

        preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyPreferences() }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.dismissPopup(); self?.endTileDrag(); self?.reconcileDisplays() }.store(in: &cancellables)
        previews.$windows.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updatePreviewPanel() }
        }.store(in: &cancellables)
        previews.$state.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updatePreviewPanel() }
        }.store(in: &cancellables)
        applications.$running.sink { [weak self] running in
            DispatchQueue.main.async { self?.refreshWindowTiles(); self?.windowGroups.prune(running: running) }
            guard let self, let item = self.previewItem,
                  !running.contains(where: { $0.bundleIdentifier == item.id }) else { return }
            self.dismissPreviews()
        }.store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.dismissPopup(); self?.windowTiles.clear(); self?.refreshFullScreenVisibility(); self?.refreshWindowTiles() }.store(in: &cancellables)

        windowTilesTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFullScreenVisibility(); self?.refreshWindowTiles(); self?.windowGroups.validateWindows() }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismissPopup() }
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
            if !CGEventSource.keyState(.combinedSessionState, key: 55) {
                Task { @MainActor in
                    if !CGEventSource.keyState(.combinedSessionState, key: 55) { self?.windowGroups.endGesture() }
                }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                if !CGEventSource.keyState(.combinedSessionState, key: 55) { self.windowGroups.endGesture() }
                return event
            }
            if event.type == .keyDown && event.keyCode == 53 { self.dismissPopup(); return nil }
            if event.type != .keyDown && event.window !== self.previewPanel { self.dismissPreviews() }
            if event.type != .keyDown && event.window !== self.flyout && !self.bars.values.contains(where: { $0 === event.window }) {
                if event.window !== self.previewPanel { self.dismissPopup() }
            }
            return event
        }
        createStatusItem()
        windowManagement.start()
    }

    func restoreDock() {
        chord.stop()
        dockVisibility.setHidden(false)
    }

    private func reconcileDisplays() {
        let next = NSScreen.screens.map(TaskbarDisplay.init)
        let ids = Set(next.map(\.id))
        for id in bars.keys.filter({ !ids.contains($0) }) {
            bars.removeValue(forKey: id)?.close()
        }
        displays = next
        for display in next where bars[display.id] == nil {
            let panel = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isMovable = false
            panel.appearance = preferences.appearance.nsAppearance
            panel.contentView = TaskbarHostingView(rootView: TaskbarView(controller: self, applications: applications,
                preferences: preferences, audio: audio, battery: battery, cpu: cpu, wifi: wifi, keyboard: keyboard,
                aiLimits: aiLimits, windowTiles: windowTiles, windowGroups: windowGroups, music: music, zoom: zoom, displayID: display.id))
            bars[display.id] = panel
        }
        positionWindows()
        refreshFullScreenVisibility()
        updateVisibility()
        refreshWindowTiles()
    }

    private func screen(on displayID: CGDirectDisplayID?) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    private var interactionDisplayID: CGDirectDisplayID? {
        NSApp.currentEvent?.window?.screen?.displayID ??
            NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.displayID ?? displays.first?.id
    }

    func isPopup(_ requested: Popup, on displayID: CGDirectDisplayID) -> Bool {
        popup == requested && popupDisplayID == displayID
    }

    func toggle(_ requested: Popup, on displayID: CGDirectDisplayID? = nil) {
        let sourceID = displayID ?? popupDisplayID ?? interactionDisplayID
        guard let sourceID, visibleDisplayIDs.contains(sourceID) else { return }
        if popup == requested && popupDisplayID == sourceID { dismissPopup(); return }
        dismissPopup()
        popupDisplayID = sourceID
        popup = requested
        let panel = FlyoutPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.appearance = preferences.appearance.nsAppearance
        panel.onEscape = { [weak self] in self?.dismissPopup() }
        switch requested {
        case .start:
            applications.reloadCatalog()
            panel.contentView = NSHostingView(rootView: StartFlyout(applications: applications, preferences: preferences, controller: self))
        case .launcher:
            applications.reloadCatalog()
            panel.contentView = NSHostingView(rootView: LauncherView(applications: applications, preferences: preferences, controller: self))
        case .calendar:
            panel.contentView = NSHostingView(rootView: CalendarFlyout())
        case .settings:
            panel.contentView = NSHostingView(rootView: SettingsFlyout(preferences: preferences, windowManagement: windowManagement))
        case .wifi:
            panel.contentView = NSHostingView(rootView: WiFiFlyout(wifi: wifi) { [weak self] in
                self?.openSettings("com.apple.wifi-settings-extension")
            })
        case .volume:
            panel.contentView = NSHostingView(rootView: VolumeFlyout(audio: audio) { [weak self] in
                self?.openSettings("com.apple.Sound-Settings.extension")
            })
        case .aiLimits:
            panel.contentView = NSHostingView(rootView: AILimitsFlyout(limits: aiLimits))
        case .cpu:
            panel.contentView = NSHostingView(rootView: CPUFlyout(cpu: cpu))
        case .battery:
            panel.contentView = NSHostingView(rootView: BatteryFlyout(battery: battery) { [weak self] in
                self?.openSettings("com.apple.preference.battery")
            })
        }
        flyout = panel
        positionWindows()
        panel.makeKeyAndOrderFront(nil)
    }

    func dismissPopup() {
        dismissPreviews()
        flyout?.orderOut(nil)
        flyout = nil
        popup = nil
        popupDisplayID = nil
    }

    func hoverApplication(_ item: ApplicationItem, inside: Bool, frame: CGRect, on displayID: CGDirectDisplayID) {
        if !inside {
            if hoveredAppID == item.id && previewDisplayID == displayID {
                hoveredAppID = nil
                pendingPreview?.cancel()
                pendingPreview = nil
            }
            return
        }
        guard visibleDisplayIDs.contains(displayID), popup == nil, applications.isRunning(item.id), NSEvent.pressedMouseButtons == 0 else { return }
        if previewItem?.id == item.id && previewDisplayID == displayID {
            hoveredAppID = item.id
            previewAnchor = frame
            return
        }
        dismissPreviews()
        hoveredAppID = item.id
        previewDisplayID = displayID
        previewAnchor = frame
        pendingPreview = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.hoveredAppID == item.id, self.popup == nil,
                  self.applications.isRunning(item.id), self.visibleDisplayIDs.contains(displayID),
                  self.previewAnchor.contains(NSEvent.mouseLocation), NSEvent.pressedMouseButtons == 0 else { return }
            self.showPreviews(for: item)
        }
    }

    private func showPreviews(for item: ApplicationItem) {
        guard let display = displays.first(where: { $0.id == previewDisplayID }) else { return }
        let panel = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.appearance = preferences.appearance.nsAppearance
        panel.contentView = NSHostingView(rootView: WindowPreviewFlyout(item: item, previews: previews) { [weak self] window in
            self?.launch(item)
            PreviewWindowActivation.activate(window)
        })
        previewItem = item
        previewPanel = panel
        previews.show(item, on: display.windowFrame)
        updatePreviewPanel()
        previewTracking = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trackPreviewPointer() }
        }
    }

    private func trackPreviewPointer() {
        guard let panel = previewPanel else { return }
        let point = NSEvent.mouseLocation
        if previewAnchor.contains(point) || (panel.isVisible && panel.frame.contains(point)) {
            previewOutsideSince = nil
        } else if let since = previewOutsideSince {
            if Date().timeIntervalSince(since) >= 0.25 { dismissPreviews() }
        } else { previewOutsideSince = Date() }
    }

    private func updatePreviewPanel() {
        guard let screen = screen(on: previewDisplayID), let id = previewDisplayID, let bar = bars[id], let panel = previewPanel else { return }
        guard previews.state != .idle && previews.state != .loading else {
            panel.orderOut(nil)
            return
        }
        let frame = WindowPreviewGeometry.panelFrame(anchor: previewAnchor, screen: screen.visibleFrame,
                                                      barTop: bar.frame.maxY, windowCount: previews.windows.count)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible {
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.orderFrontRegardless()
        }
    }

    private func dismissPreviews() {
        pendingPreview?.cancel()
        pendingPreview = nil
        hoveredAppID = nil
        previewTracking?.invalidate()
        previewTracking = nil
        previewOutsideSince = nil
        previewPanel?.orderOut(nil)
        previewPanel = nil
        previewItem = nil
        previewDisplayID = nil
        previews.cancel()
    }

    func launch(_ item: ApplicationItem) {
        dismissPopup()
        applications.activate(item)
    }

    func activate(_ tile: TaskbarTile, on displayID: CGDirectDisplayID) {
        dismissPopup()
        if CGEventSource.keyState(.combinedSessionState, key: 55), let screen = screen(on: displayID) {
            windowGroups.click(tile, screen: screen, taskbar: visibleDisplayIDs.contains(displayID) ? bars[displayID]?.frame : nil, applications: applications)
        } else if let window = tile.window {
            Task {
                switch await TaskbarWindowActivation.click(window) {
                case .minimized:
                    applications.refreshRunning()
                case .restore:
                    if let group = windowGroups.group(for: tile) {
                        windowGroups.activate(group)
                    } else {
                        applications.activate(tile.app, window: window)
                    }
                case .failed(let message):
                    applications.actionError = message
                }
                refreshWindowTiles()
            }
        } else if let group = windowGroups.group(for: tile) {
            windowGroups.activate(group)
        } else {
            applications.activate(tile.app, window: tile.window)
        }
    }

    func beginTileDrag(frame: CGRect, translation: CGSize, sourceWindow: NSWindow? = nil) {
        endTileDrag()
        let sourceID = displays.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }?.id
        guard let window = sourceWindow ?? sourceID.flatMap({ bars[$0] }), let content = window.contentView else { return }
        let rect = content.convert(window.convertFromScreen(frame), from: nil)
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: rect) else { return }
        content.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: frame.size)
        image.addRepresentation(bitmap)
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 7
        imageView.layer?.masksToBounds = true

        let panel = BarPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.contentView = imageView
        panel.setFrame(frame, display: true)
        let pointer = NSEvent.mouseLocation
        tileDragPointerOffset = CGPoint(x: pointer.x - frame.minX - translation.width,
                                       y: pointer.y - frame.minY + translation.height)
        tileDragPanel = panel
        panel.orderFrontRegardless()
    }

    func updateTileDrag() {
        let pointer = NSEvent.mouseLocation
        tileDragPanel?.setFrameOrigin(CGPoint(x: pointer.x - tileDragPointerOffset.x,
                                             y: pointer.y - tileDragPointerOffset.y))
    }

    func endTileDrag() {
        tileDragPanel?.orderOut(nil)
        tileDragPanel = nil
    }

    /// Accessibility window data is only read in window-tile modes, and only once granted.
    var readsWindows: Bool { windowTiles.hasWindowAccess && preferences.usesWindowTiles }

    private func refreshWindowTiles() {
        let processes = applications.running.compactMap { app -> TaskbarWindowProcess? in
            guard let id = app.bundleIdentifier else { return nil }
            return TaskbarWindowProcess(id: app.processIdentifier, bundleID: id)
        }
        windowTiles.refresh(processes: processes, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                            enabled: isVisible && preferences.usesWindowTiles)
        if isVisible && displays.count > 1 && !readsWindows { windowTiles.refreshPlacement(processes: processes) }
    }

    func openMissionControl() {
        dismissPopup()
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
    }

    func openStartPlace(_ destination: FinderDestination) {
        dismissPopup()
        if let finder = applications.application(for: "com.apple.finder") {
            applications.openFinderDestination(destination.url, name: destination.title, finder: finder)
        } else {
            applications.launchError = "Finder could not be found."
        }
    }

    func openStartApplication(_ bundleID: String, name: String) {
        guard let item = applications.application(for: bundleID) else {
            dismissPopup()
            applications.launchError = "\(name) could not be found on this Mac."
            return
        }
        launch(item)
    }

    func showDesktop() {
        dismissPopup()
        applications.showDesktop()
    }

    func openDownload(_ file: RecentDownload) {
        dismissPopup()
        guard NSWorkspace.shared.open(file.url) else {
            applications.launchError = "Couldn’t open \(file.name). It may have been moved or removed."
            return
        }
    }

    func revealDownload(_ file: RecentDownload) {
        dismissPopup()
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func openTrash() {
        dismissPopup()
        runFinderCommand("activate\nopen trash")
    }

    func emptyTrash() {
        dismissPopup()
        let alert = NSAlert()
        alert.messageText = "Empty Trash?"
        alert.informativeText = "Items in the Trash will be permanently deleted. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Empty Trash")
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        runFinderCommand("empty trash")
    }

    private func runFinderCommand(_ command: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let source = "tell application \"Finder\"\n\(command)\nend tell"
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error, (error[NSAppleScript.errorNumber] as? Int) != -128 else { return }
            let message = error[NSAppleScript.errorMessage] as? String ?? "Finder could not complete the request."
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Could not use Trash"
                alert.informativeText = message
                alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    func openSettings(_ pane: String) {
        dismissPopup()
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }

    private func applyPreferences() {
        dismissPreviews()
        aiLimits.setEnabled(isVisible && preferences.shows(.aiLimits))
        cpu.setEnabled(isVisible, showSystem: preferences.shows(.cpu))
        let popupControl: TaskbarControl?
        switch popup {
        case .start: popupControl = .start
        case .launcher: popupControl = .search
        case .calendar: popupControl = .clock
        case .wifi: popupControl = .wifi
        case .volume: popupControl = .sound
        case .battery: popupControl = .battery
        case .cpu: popupControl = .cpu
        case .aiLimits: popupControl = .aiLimits
        default: popupControl = nil
        }
        if let popupControl, !preferences.shows(popupControl) { dismissPopup() }
        refreshWindowTiles()
        for bar in bars.values { bar.appearance = preferences.appearance.nsAppearance }
        flyout?.appearance = preferences.appearance.nsAppearance
        positionWindows()
    }

    func fitStart(to height: CGFloat) {
        guard popup == .start, height.isFinite, height > 0 else { return }
        let fitted = height.rounded(.up)
        guard fitted != startHeight else { return }
        startHeight = fitted
        positionWindows()
    }

    private func positionWindows() {
        for display in displays {
            bars[display.id]?.setFrame(BarGeometry.frame(on: display.frame, height: preferences.barHeight), display: true)
        }
        updateWindowManagement()
        if let popup, let screen = screen(on: popupDisplayID) {
            let size: CGSize
            switch popup {
            case .start: size = CGSize(width: 600, height: startHeight)
            case .launcher: size = CGSize(width: 640, height: 600)
            case .calendar: size = CGSize(width: 360, height: 442)
            case .settings: size = CGSize(width: 370, height: 640)
            case .wifi: size = CGSize(width: 370, height: 460)
            case .volume: size = CGSize(width: 360, height: 250)
            case .battery: size = CGSize(width: 320, height: 210)
            case .cpu: size = CGSize(width: 320, height: 345)
            case .aiLimits: size = CGSize(width: 390, height: 560)
            }
            let usable = CGRect(x: screen.frame.minX, y: screen.frame.minY,
                                width: screen.frame.width, height: screen.visibleFrame.maxY - screen.frame.minY)
            flyout?.setFrame(BarGeometry.popupFrame(screen: usable, barHeight: preferences.barHeight, size: size,
                alignment: popup == .start || popup == .launcher ? (preferences.alignment == .left ? .left : .center) : .right), display: true)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleChord) { item.state = chord.settings.enabled ? .on : .off }
        return true
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Macbar")
        item.button?.toolTip = "Macbar"
        let menu = NSMenu()
        menu.addItem(withTitle: "Macbar", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Macbar Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let visibility = menu.addItem(withTitle: "Show / Hide Taskbar", action: #selector(toggleVisibility), keyEquivalent: "")
        visibility.target = self
        menu.addItem(.separator())
        let chordOn = menu.addItem(withTitle: "Chord Window Tiling", action: #selector(toggleChord), keyEquivalent: "")
        chordOn.target = self
        let chordSettings = menu.addItem(withTitle: "Chord Settings…", action: #selector(showChordSettings), keyEquivalent: "")
        chordSettings.target = self
        let chordAll = menu.addItem(withTitle: "Show All Windows", action: #selector(showAllWindows), keyEquivalent: "")
        chordAll.target = self
        menu.addItem(.separator())
        let perms = menu.addItem(withTitle: "Permissions…", action: #selector(showPermissions), keyEquivalent: "")
        perms.target = self
        let dock = menu.addItem(withTitle: "Desktop & Dock Settings…", action: #selector(showDockSettings), keyEquivalent: "")
        dock.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Macbar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func showSettings() {
        if !manuallyVisible { toggleVisibility() }
        if isVisible { toggle(.settings) }
    }
    @objc private func toggleChord() { chord.settings.setEnabled(!chord.settings.enabled) }
    @objc private func showPermissions() { PermissionsWindow.shared.show() }
    @objc private func showChordSettings() { chord.showSettings() }
    @objc private func showAllWindows() { chord.showAllWindows() }
    @objc private func showDockSettings() { openSettings("com.apple.Desktop-Settings.extension") }
    @objc private func toggleVisibility() {
        manuallyVisible.toggle()
        updateVisibility()
    }

    private func refreshFullScreenVisibility() {
        let frames = FullScreenDetection.visibleWindowFrames()
        let covered = Set(displays.filter {
            FullScreenDetection.isCovered(display: $0.windowFrame, windows: frames)
        }.map(\.id))
        guard covered != coveredDisplayIDs else { return }
        coveredDisplayIDs = covered
        updateVisibility()
    }

    private func updateVisibility() {
        let visible = manuallyVisible ? Set(displays.map(\.id)).subtracting(coveredDisplayIDs) : []
        if visible != visibleDisplayIDs {
            endTileDrag()
            if let id = popupDisplayID, !visible.contains(id) { dismissPopup() }
            if let id = previewDisplayID, !visible.contains(id) { dismissPreviews() }
            visibleDisplayIDs = visible
        }
        isVisible = !visible.isEmpty
        aiLimits.setEnabled(isVisible && preferences.shows(.aiLimits))
        cpu.setEnabled(isVisible, showSystem: preferences.shows(.cpu))
        for (id, bar) in bars {
            if visible.contains(id) {
                if !bar.isVisible { bar.orderFrontRegardless() }
            } else if bar.isVisible { bar.orderOut(nil) }
        }
        updateWindowManagement()
        refreshWindowTiles()
    }

    private func updateWindowManagement() {
        windowManagement.updateTaskbars(contexts: displays.compactMap { display in
            guard visibleDisplayIDs.contains(display.id), let bar = bars[display.id] else { return nil }
            return WindowFitContext(screen: display.windowFrame,
                workArea: WindowFitGeometry.accessibilityFrame(from: display.visibleFrame,
                    primaryScreenTop: NSScreen.screens.first?.frame.maxY ?? 0),
                taskbar: WindowFitGeometry.accessibilityFrame(from: bar.frame,
                    primaryScreenTop: NSScreen.screens.first?.frame.maxY ?? 0))
        })
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
