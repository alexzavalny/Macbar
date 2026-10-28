import AppKit
import Combine

/// Music broadcasts player changes even when playback is controlled outside Macbar.
@MainActor
final class AppleMusicStore: ObservableObject {
    enum Command: String {
        case previous = "previous track"
        case playPause = "playpause"
        case next = "next track"
    }

    @Published private(set) var playing: Bool?
    @Published var error: String?
    private let queue = DispatchQueue(label: "studio.macbar.music-controls", qos: .userInitiated)
    private var playerObserver: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?

    init() {
        playerObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] notification in
            let state = notification.userInfo?["Player State"] as? String
            Task { @MainActor in self?.update(state: state) }
        }
        quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == SpecialTile.appleMusic.rawValue else { return }
            Task { @MainActor in self?.playing = nil }
        }
    }

    deinit {
        if let playerObserver { DistributedNotificationCenter.default().removeObserver(playerObserver) }
        if let quitObserver { NSWorkspace.shared.notificationCenter.removeObserver(quitObserver) }
    }

    var playbackSymbol: String { playing.map { $0 ? "pause.fill" : "play.fill" } ?? "playpause.fill" }
    var playbackTitle: String { playing.map { $0 ? "Pause" : "Play" } ?? "Play or pause" }

    func perform(_ command: Command) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: SpecialTile.appleMusic.rawValue).isEmpty else { return }
        queue.async { [weak self] in
            let source = """
            if application id "com.apple.Music" is running then
                tell application id "com.apple.Music"
                    \(command.rawValue)
                    return player state as text
                end tell
            end if
            """
            var details: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&details)
            let state = result?.stringValue
            let message = details?[NSAppleScript.errorMessage] as? String
            Task { @MainActor [weak self] in
                if let message {
                    self?.error = "\(message) You can allow Macbar to control Music in System Settings → Privacy & Security → Automation."
                } else {
                    self?.update(state: state)
                }
            }
        }
    }

    private func update(state: String?) {
        switch state?.lowercased() {
        case "playing": playing = true
        case "paused", "stopped": playing = false
        default: break
        }
    }
}
