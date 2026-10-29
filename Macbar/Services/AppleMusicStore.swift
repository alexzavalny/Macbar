import AppKit
import Combine
import Carbon

/// Music broadcasts player changes even when playback is controlled outside Macbar.
@MainActor
final class AppleMusicStore: ObservableObject {
    enum Command: String {
        case previous = "previous track"
        case playPause = "playpause"
        case next = "next track"
    }

    @Published private(set) var playing: Bool?
    @Published private(set) var artwork: NSImage?
    @Published var error: String?
    private let queue = DispatchQueue(label: "studio.macbar.music-controls", qos: .userInitiated)
    private var playerObserver: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    private var artworkGeneration = UUID()

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
            Task { @MainActor in self?.clearPlayback() }
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == SpecialTile.appleMusic.rawValue else { return }
            Task { @MainActor in self?.refreshPlayback() }
        }
        refreshPlayback()
    }

    deinit {
        if let playerObserver { DistributedNotificationCenter.default().removeObserver(playerObserver) }
        if let quitObserver { NSWorkspace.shared.notificationCenter.removeObserver(quitObserver) }
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
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
        case "playing":
            playing = true
            refreshPlayback()
        case "paused", "stopped":
            playing = false
            artworkGeneration = UUID()
            artwork = nil
        default: break
        }
    }

    private func clearPlayback() {
        artworkGeneration = UUID()
        artwork = nil
        playing = nil
    }

    /// Query only after permission was granted by a playback action. Background
    /// refreshes never trigger the system Automation permission prompt.
    private func refreshPlayback() {
        artworkGeneration = UUID()
        let generation = artworkGeneration
        artwork = nil
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: SpecialTile.appleMusic.rawValue).isEmpty else { return }
        queue.async { [weak self] in
            let bundleID = Data(SpecialTile.appleMusic.rawValue.utf8)
            var target = AEAddressDesc()
            let created = bundleID.withUnsafeBytes { bytes in
                AECreateDesc(DescType(typeApplicationBundleID), bytes.baseAddress, bytes.count, &target)
            }
            guard created == noErr else { return }
            defer { AEDisposeDesc(&target) }
            guard AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) == noErr else { return }
            let source = """
            if application id "com.apple.Music" is running then
                tell application id "com.apple.Music"
                    set currentState to player state as text
                    set imageData to missing value
                    if currentState is "playing" then
                        try
                            set imageData to raw data of artwork 1 of current track
                        end try
                    end if
                    set trackName to ""
                    set trackArtist to ""
                    set trackAlbum to ""
                    if currentState is "playing" then
                        try
                            set trackName to name of current track
                            set trackArtist to artist of current track
                            set trackAlbum to album of current track
                        end try
                    end if
                    return {currentState, imageData, trackName, trackArtist, trackAlbum}
                end tell
            end if
            """
            var details: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&details)
            let state = result?.atIndex(1)?.stringValue?.lowercased()
            let imageData = result?.atIndex(2)?.data
            let track = MusicArtworkLookup.Track(
                name: result?.atIndex(3)?.stringValue ?? "",
                artist: result?.atIndex(4)?.stringValue ?? "",
                album: result?.atIndex(5)?.stringValue ?? "")
            Task { @MainActor [weak self] in
                guard let self, self.artworkGeneration == generation else { return }
                switch state {
                case "playing":
                    self.playing = true
                    self.artwork = imageData.flatMap { NSImage(data: $0) }
                    if self.artwork == nil {
                        Task {
                            let data = await MusicArtworkLookup.fetch(track: track)
                            guard self.artworkGeneration == generation, self.playing == true else { return }
                            self.artwork = data.flatMap { NSImage(data: $0) }
                        }
                    }
                case "paused", "stopped":
                    self.playing = false
                    self.artwork = nil
                default: break
                }
            }
        }
    }

}

/// Some streamed tracks expose no embedded artwork through Music's scripting API.
/// Only use catalog art when the title, artist, and (when known) album all match.
enum MusicArtworkLookup {
    struct Track {
        let name: String
        let artist: String
        let album: String
    }
    struct Response: Decodable { let results: [Match] }
    struct Match: Decodable {
        let trackName: String
        let artistName: String
        let collectionName: String
        let artworkUrl100: URL
    }

    static func matches(_ result: Match, track: Track) -> Bool {
        func normalized(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !normalized(track.name).isEmpty, !normalized(track.artist).isEmpty else { return false }
        return normalized(result.trackName) == normalized(track.name) &&
            normalized(result.artistName) == normalized(track.artist) &&
            (normalized(track.album).isEmpty || normalized(result.collectionName) == normalized(track.album))
    }

    static func fetch(track: Track) async -> Data? {
        guard !track.name.isEmpty, !track.artist.isEmpty else { return nil }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: [track.name, track.artist, track.album].joined(separator: " ")),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US")
        ]
        guard let url = components.url else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let results = try? JSONDecoder().decode(Response.self, from: data),
                  let result = results.results.first(where: { matches($0, track: track) }),
                  result.artworkUrl100.scheme == "https",
                  let host = result.artworkUrl100.host?.lowercased(),
                  host == "mzstatic.com" || host.hasSuffix(".mzstatic.com") else { return nil }
            let (artwork, imageResponse) = try await session.data(from: result.artworkUrl100)
            guard (imageResponse as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return artwork
        } catch { return nil }
    }
}
