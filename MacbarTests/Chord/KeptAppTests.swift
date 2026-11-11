import Testing
@testable import Macbar

private let zoom = KeptApp(bundleID: "us.zoom.xos", appName: "zoom.us", appPath: "/Applications/zoom.us.app")
private let music = KeptApp(bundleID: "com.apple.Music", appName: "Music", appPath: "/System/Applications/Music.app")

@Suite struct KeptApps {
    @Test func addingSortsByName() {
        #expect([zoom].adding(music) == [music, zoom])
    }

    @Test func addingTheSameAppAgainKeepsOne() {
        let moved = KeptApp(bundleID: "us.zoom.xos", appName: "zoom.us", appPath: "/Elsewhere/zoom.us.app")
        #expect([music, zoom].adding(moved) == [music, moved])
    }

    @Test func removing() {
        #expect([music, zoom].removing(bundleID: "us.zoom.xos") == [music])
    }

    @Test func roundTrip() {
        #expect(KeptAppList.decode(KeptAppList.encode([music, zoom])) == [music, zoom])
    }

    @Test func skipsEntriesItCannotRead() {
        let json = #"[{"bundleID":"com.apple.Music","appName":"Music","appPath":"\/System\/Applications\/Music.app"},{"bundleID":"x"}]"#
        #expect(KeptAppList.decode(json) == [music])
        #expect(KeptAppList.decode("{") == nil)
    }
}
