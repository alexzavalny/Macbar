import XCTest
@testable import Macbar

final class ZoomTests: XCTestCase {
    func testMeetingMenuTitlesDescribeMicrophoneAndCamera() {
        let titles = ZoomMenuTitles.english
        let live = titles.state(for: ["Mute audio", "Stop video", "Share screen", ""])
        XCTAssertEqual(live, ZoomMeetingState(muted: false, videoOn: true))
        XCTAssertEqual(live.audioSymbol, "mic.fill")
        XCTAssertEqual(live.audioTitle, "Mute audio")
        XCTAssertEqual(live.videoSymbol, "video.fill")
        XCTAssertEqual(live.videoTitle, "Stop video")

        // Older Zoom releases title-case the menu.
        let quiet = titles.state(for: ["Unmute Audio", " Start Video "])
        XCTAssertEqual(quiet, ZoomMeetingState(muted: true, videoOn: false))
        XCTAssertEqual(quiet.audioSymbol, "mic.slash.fill")
        XCTAssertEqual(quiet.videoSymbol, "video.slash.fill")
    }

    func testControlsAreUnavailableOutsideMeetingOrBeforeJoiningAudio() {
        let idle = ZoomMenuTitles.english.state(for: ["New Meeting", "Join Meeting", "Mute my audio"])
        XCTAssertFalse(idle.inMeeting)
        XCTAssertEqual(idle.audioTitle, "Mute or unmute audio")

        let videoOnly = ZoomMenuTitles.english.state(for: ["Join Audio", "Start video"])
        XCTAssertTrue(videoOnly.inMeeting)
        XCTAssertNil(videoOnly.muted)
        XCTAssertEqual(videoOnly.videoOn, false)
    }

    func testLocalizedZoomTitlesAreRecognized() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("ZoomTests-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let resources = app.appendingPathComponent("Contents/Resources/ru.lproj")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources/en.lproj"), withIntermediateDirectories: true)
        try "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>us.zoom.test</string></dict></plist>"
            .write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        try """
        "Meeting" = "Конференция";
        "Mute Audio" = "Выключить звук";
        "Unmute Audio" = "Включить звук";
        "Start Video" = "Включить видео";
        "Stop Video" = "Остановить видео";
        """.write(to: resources.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)

        let russian = ZoomMenuTitles.load(appURL: app, preferredLanguages: ["ru-RU"])
        XCTAssertTrue(russian.isMeetingMenu("Конференция"))
        XCTAssertTrue(russian.isMeetingMenu("Meeting"))
        XCTAssertEqual(russian.state(for: ["Включить звук", "Остановить видео"]), ZoomMeetingState(muted: true, videoOn: true))
        XCTAssertEqual(russian.state(for: ["Mute audio"]), ZoomMeetingState(muted: false))

        let english = ZoomMenuTitles.load(appURL: app, preferredLanguages: ["en-US"])
        XCTAssertFalse(english.isMeetingMenu("Конференция"))
        XCTAssertFalse(ZoomMenuTitles.load(appURL: nil).isMeetingMenu("Конференция"))
    }

    func testZoomIsSpecialTileWithInlineControls() {
        let zoom = ApplicationItem(id: "us.zoom.xos", name: "zoom.us", url: URL(fileURLWithPath: "/Applications/zoom.us.app"), icon: NSImage())
        let editor = ApplicationItem(id: "editor", name: "Editor", url: URL(fileURLWithPath: "/Applications/Editor.app"), icon: NSImage())
        let meeting = TaskbarWindow(id: UUID(), bundleID: zoom.id, processID: 1, title: "Zoom Meeting", isMinimized: false, isFocused: true)
        let main = TaskbarWindow(id: UUID(), bundleID: zoom.id, processID: 1, title: "Zoom Workplace", isMinimized: false, isFocused: false)
        let tiles = TaskbarTile.make(apps: [zoom, editor], windows: [meeting, main], mode: .windows)
        XCTAssertEqual(tiles.filter { $0.app.id == zoom.id }.count, 1)
        XCTAssertEqual(tiles[0].special, .zoom)
        XCTAssertNil(tiles[0].window)
        XCTAssertFalse(tiles[0].showsTitle(mode: .windows, isRunning: true))
        XCTAssertEqual(SpecialTile.zoom.width, 100)
        XCTAssertEqual(SpecialTile.appleMusic.width, 122)
    }
}
