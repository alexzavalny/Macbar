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
    let previews = WindowPreviewStore()
    let windowTiles = TaskbarWindowStore()
    let windowGroups = WindowGroupStore()
    @Published private(set) var popup: Popup?
    @Published private(set) var isVisible = true
    private var manuallyVisible = true
    private var fullScreenCovered = false

    private var bar: BarPanel?
    private var flyout: FlyoutPanel?
    private var startHeight: CGFloat = 800
    private var statusItem: NSStatusItem?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var previewPanel: BarPanel?
    private var previewItem: ApplicationItem?
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
        dockVisibility.recover()
        dockVisibility.setHidden(preferences.hideDockWhileRunning)
        preferences.$hideDockWhileRunning.dropFirst().sink { [weak self] hidden in
            self?.dockVisibility.setHidden(hidden)
        }.store(in: &cancellables)
        let panel = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = TaskbarHostingView(rootView: TaskbarView(controller: self, applications: applications, preferences: preferences, audio: audio, battery: battery, cpu: cpu, wifi: wifi, keyboard: keyboard, aiLimits: aiLimits, windowTiles: windowTiles, windowGroups: windowGroups, music: music))
        bar = panel
        fullScreenCovered = FullScreenDetection.isMainDisplayCovered()
        isVisible = manuallyVisible && !fullScreenCovered
        applyPreferences()
        if isVisible { panel.orderFrontRegardless() }

        preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyPreferences() }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.dismissPreviews(); self?.positionWindows(); self?.refreshFullScreenVisibility() }.store(in: &cancellables)
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
            .sink { [weak self] _ in self?.dismissPopup(); self?.refreshWindowTiles(); self?.refreshFullScreenVisibility() }.store(in: &cancellables)

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
            if event.type != .keyDown && event.window !== self.flyout && event.window !== self.bar {
                if event.window !== self.previewPanel { self.dismissPopup() }
            }
            return event
        }
        createStatusItem()
        windowManagement.start()
    }

    func restoreDock() { dockVisibility.setHidden(false) }

    var screen: NSScreen? {
        // The display with the menu bar is first, even when another app has focus.
        NSScreen.screens.first
    }

    func toggle(_ requested: Popup) {
        if popup == requested { dismissPopup(); return }
        dismissPopup()
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
    }

    func hoverApplication(_ item: ApplicationItem, inside: Bool, frame: CGRect) {
        if !inside {
            if hoveredAppID == item.id {
                hoveredAppID = nil
                pendingPreview?.cancel()
                pendingPreview = nil
            }
            return
        }
        guard isVisible, popup == nil, applications.isRunning(item.id), NSEvent.pressedMouseButtons == 0 else { return }
        if previewItem?.id == item.id {
            hoveredAppID = item.id
            previewAnchor = frame
            return
        }
        dismissPreviews()
        hoveredAppID = item.id
        previewAnchor = frame
        pendingPreview = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.hoveredAppID == item.id, self.popup == nil,
                  self.applications.isRunning(item.id), self.isVisible,
                  self.previewAnchor.contains(NSEvent.mouseLocation), NSEvent.pressedMouseButtons == 0 else { return }
            self.showPreviews(for: item)
        }
    }

    private func showPreviews(for item: ApplicationItem) {
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
        previews.show(item)
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
        guard let screen, let bar, let panel = previewPanel else { return }
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
        previews.cancel()
    }

    func launch(_ item: ApplicationItem) {
        dismissPopup()
        applications.activate(item)
    }

    func activate(_ tile: TaskbarTile) {
        dismissPopup()
        if CGEventSource.keyState(.combinedSessionState, key: 55), let screen {
            windowGroups.click(tile, screen: screen, taskbar: isVisible ? bar?.frame : nil, applications: applications)
        } else if let group = windowGroups.group(for: tile) {
            windowGroups.activate(group)
        } else {
            applications.activate(tile.app, window: tile.window)
        }
    }

    func beginTileDrag(frame: CGRect, translation: CGSize, sourceWindow: NSWindow? = nil) {
        endTileDrag()
        guard let window = sourceWindow ?? bar, let content = window.contentView else { return }
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

    private func refreshWindowTiles() {
        let processes = applications.running.compactMap { app -> TaskbarWindowProcess? in
            guard let id = app.bundleIdentifier else { return nil }
            return TaskbarWindowProcess(id: app.processIdentifier, bundleID: id)
        }
        windowTiles.refresh(processes: processes, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                            enabled: isVisible && preferences.usesWindowTiles)
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
        cpu.setEnabled(isVisible && preferences.shows(.cpu))
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
        bar?.appearance = preferences.appearance.nsAppearance
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
        guard let screen else { return }
        bar?.setFrame(BarGeometry.frame(on: screen.frame, height: preferences.barHeight), display: true)
        windowManagement.updateTaskbar(frame: isVisible ? bar?.frame : nil)
        if let popup {
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
    @objc private func showDockSettings() { openSettings("com.apple.Desktop-Settings.extension") }
    @objc private func toggleVisibility() {
        manuallyVisible.toggle()
        updateVisibility()
    }

    private func refreshFullScreenVisibility() {
        let covered = FullScreenDetection.isMainDisplayCovered()
        guard covered != fullScreenCovered else { return }
        fullScreenCovered = covered
        updateVisibility()
    }

    private func updateVisibility() {
        let visible = manuallyVisible && !fullScreenCovered
        guard visible != isVisible else { return }
        endTileDrag()
        dismissPopup()
        isVisible = visible
        aiLimits.setEnabled(isVisible && preferences.shows(.aiLimits))
        cpu.setEnabled(isVisible && preferences.shows(.cpu))
        refreshWindowTiles()
        if isVisible { bar?.orderFrontRegardless() } else { bar?.orderOut(nil) }
        windowManagement.updateTaskbar(frame: isVisible ? bar?.frame : nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
