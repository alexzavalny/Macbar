import AppKit
import ApplicationServices
import Combine

/// What Zoom's Meeting menu says about the current meeting. A nil value means the
/// control is unavailable: Zoom is outside a meeting or hasn't joined audio yet.
struct ZoomMeetingState: Equatable {
    var muted: Bool?
    var videoOn: Bool?

    init(muted: Bool? = nil, videoOn: Bool? = nil) {
        self.muted = muted
        self.videoOn = videoOn
    }

    init(controls: some Sequence<ZoomMenuTitles.Control>) {
        for control in controls {
            switch control {
            case .mute: muted = false
            case .unmute: muted = true
            case .startVideo: videoOn = false
            case .stopVideo: videoOn = true
            }
        }
    }

    var inMeeting: Bool { muted != nil || videoOn != nil }
    var audioSymbol: String { muted == true ? "mic.slash.fill" : "mic.fill" }
    var audioTitle: String { muted.map { $0 ? "Unmute audio" : "Mute audio" } ?? "Mute or unmute audio" }
    var videoSymbol: String { videoOn == false ? "video.slash.fill" : "video.fill" }
    var videoTitle: String { videoOn.map { $0 ? "Stop video" : "Start video" } ?? "Start or stop video" }
}

/// Zoom has no scripting dictionary. During a meeting its Meeting menu offers
/// "Mute audio" or "Unmute audio" (likewise for video), so the item titles carry
/// the state and pressing the item toggles it. Titles follow Zoom's localization.
struct ZoomMenuTitles {
    enum Control: Hashable { case mute, unmute, startVideo, stopVideo }

    private(set) var meeting: Set<String>
    private(set) var controls: [String: Control]

    /// Zoom's Localizable.strings keys for the menu titles Macbar reads.
    static let keys: [String: Control?] = [
        "Meeting": nil, "Mute Audio": .mute, "Unmute Audio": .unmute, "Start Video": .startVideo, "Stop Video": .stopVideo
    ]

    static let english = ZoomMenuTitles(meeting: ["meeting"], controls: [
        "mute audio": .mute, "unmute audio": .unmute, "start video": .startVideo, "stop video": .stopVideo
    ])

    static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func control(for title: String) -> Control? { controls[Self.normalized(title)] }
    func isMeetingMenu(_ title: String) -> Bool { meeting.contains(Self.normalized(title)) }
    func state(for titles: [String]) -> ZoomMeetingState { ZoomMeetingState(controls: titles.compactMap(control(for:))) }

    /// Adds Zoom's translations so a localized Zoom reads the same as English.
    mutating func add(strings: [String: String]) {
        for (key, control) in Self.keys {
            guard let translated = strings[key].map(Self.normalized), !translated.isEmpty else { continue }
            if let control { controls[translated] = control } else { meeting.insert(translated) }
        }
    }

    static func load(appURL: URL?, preferredLanguages: [String] = Locale.preferredLanguages) -> ZoomMenuTitles {
        var titles = english
        guard let appURL, let bundle = Bundle(url: appURL) else { return titles }
        for localization in Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: preferredLanguages)
        where !localization.hasPrefix("en") {
            guard let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: localization),
                  let strings = NSDictionary(contentsOf: url) as? [String: String] else { continue }
            titles.add(strings: strings)
        }
        return titles
    }
}

/// Accessibility calls wait on Zoom's main thread, so they run on the store's queue only.
private final class ZoomMenuReader: @unchecked Sendable {
    private var processID: pid_t?
    private var titles = ZoomMenuTitles.english
    private var meetingMenu: AXUIElement?

    func state(processID: pid_t, appURL: URL?) -> ZoomMeetingState {
        ZoomMeetingState(controls: items(processID: processID, appURL: appURL).keys)
    }

    func press(_ toggle: ZoomStore.Toggle, processID: pid_t, appURL: URL?) -> Bool {
        let items = items(processID: processID, appURL: appURL)
        let item = toggle == .audio ? items[.mute] ?? items[.unmute] : items[.startVideo] ?? items[.stopVideo]
        guard let item else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private func items(processID: pid_t, appURL: URL?) -> [ZoomMenuTitles.Control: AXUIElement] {
        if self.processID != processID {
            self.processID = processID
            titles = .load(appURL: appURL)
            meetingMenu = nil
        }
        if let meetingMenu {
            let items = controls(in: meetingMenu)
            if !items.isEmpty { return items }
            self.meetingMenu = nil
        }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let menuBar = element(application, kAXMenuBarAttribute) else { return [:] }
        // The Apple menu never holds meeting controls. Zoom adds its Meeting menu
        // only during a meeting, so check it first and the rest only as a fallback.
        let menus = children(menuBar).dropFirst().compactMap { item in children(item).first.map { (title(item), $0) } }
        for (_, menu) in menus.filter({ titles.isMeetingMenu($0.0) }) + menus.filter({ !titles.isMeetingMenu($0.0) }) {
            let items = controls(in: menu)
            if !items.isEmpty {
                meetingMenu = menu
                return items
            }
        }
        return [:]
    }

    private func controls(in menu: AXUIElement) -> [ZoomMenuTitles.Control: AXUIElement] {
        var result: [ZoomMenuTitles.Control: AXUIElement] = [:]
        for item in children(menu) {
            if let control = titles.control(for: title(item)) { result[control] = item }
        }
        return result
    }

    private func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func title(_ element: AXUIElement) -> String {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }
}

/// Reads Zoom's microphone and camera state while Zoom runs, polling faster during a meeting.
@MainActor
final class ZoomStore: ObservableObject {
    enum Toggle { case audio, video }

    @Published private(set) var state = ZoomMeetingState()
    @Published private(set) var hasAccess = AXIsProcessTrusted()
    @Published var error: String?
    private let queue = DispatchQueue(label: "studio.macbar.zoom-controls", qos: .userInitiated)
    private let reader = ZoomMenuReader()
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var scanning = false
    private var rescan = false

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == SpecialTile.zoom.rawValue else { return }
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }

    deinit {
        timer?.invalidate()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func toggle(_ toggle: Toggle) {
        guard let zoom = runningZoom else { return }
        guard AXIsProcessTrusted() else {
            NSApp.activate(ignoringOtherApps: true)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }
        let processID = zoom.processIdentifier, appURL = zoom.bundleURL
        queue.async { [reader] in
            let pressed = reader.press(toggle, processID: processID, appURL: appURL)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !pressed {
                    self.error = toggle == .audio
                        ? "Zoom has no microphone control right now. Join the meeting's audio in Zoom, then try again."
                        : "Zoom has no camera control right now. Join a meeting in Zoom, then try again."
                }
                // Zoom renames the menu item once it has applied the change.
                try? await Task.sleep(for: .milliseconds(250))
                self.refresh()
            }
        }
    }

    private var runningZoom: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: SpecialTile.zoom.rawValue).first { !$0.isTerminated }
    }

    private func refresh() {
        timer?.invalidate()
        timer = nil
        let trusted = AXIsProcessTrusted()
        if hasAccess != trusted { hasAccess = trusted }
        guard let zoom = runningZoom else {
            if state != ZoomMeetingState() { state = ZoomMeetingState() }
            return
        }
        guard trusted else {
            if state != ZoomMeetingState() { state = ZoomMeetingState() }
            schedule(after: 3)
            return
        }
        guard !scanning else {
            rescan = true
            return
        }
        scanning = true
        let processID = zoom.processIdentifier, appURL = zoom.bundleURL
        queue.async { [reader] in
            let next = reader.state(processID: processID, appURL: appURL)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scanning = false
                if self.rescan {
                    self.rescan = false
                    self.refresh()
                    return
                }
                if self.state != next { self.state = next }
                // Follow changes made in Zoom itself; idle Zoom only needs to notice a meeting starting.
                self.schedule(after: next.inMeeting ? 1 : 3)
            }
        }
    }

    private func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}
