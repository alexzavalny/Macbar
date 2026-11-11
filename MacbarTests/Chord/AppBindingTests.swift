import Foundation
import Testing
@testable import Macbar

private let arc = AppBinding(key: .a, bundleID: "company.thebrowser.Browser", appName: "Arc", appPath: "/Applications/Arc.app")
private let mail = AppBinding(key: .m, bundleID: "com.apple.mail", appName: "Mail", appPath: "/System/Applications/Mail.app")

@Suite struct BindingLists {
    @Test func settingAddsSortedByKey() {
        #expect([mail].setting(arc) == [arc, mail])
    }

    @Test func settingReplacesTheSameKey() {
        let notes = AppBinding(key: .a, bundleID: "com.apple.Notes", appName: "Notes", appPath: "/System/Applications/Notes.app")
        #expect([arc, mail].setting(notes) == [notes, mail])
    }

    @Test func removing() {
        #expect([arc, mail].removing(.a) == [mail])
        #expect([mail].removing(.a) == [mail])
    }

    @Test func lookup() {
        #expect([arc, mail].binding(for: .m) == mail)
        #expect([arc].binding(for: .m) == nil)
    }
}

@Suite struct BindingStorage {
    @Test func roundTrip() {
        #expect(BindingList.decode(BindingList.encode([arc, mail])) == [arc, mail])
    }

    @Test func storesKeysAsCharacters() {
        #expect(BindingList.encode([arc]).contains(#""key":"A""#))
    }

    @Test func emptyList() {
        #expect(BindingList.decode("[]") == [])
    }

    @Test func malformedIsNil() {
        #expect(BindingList.decode("{") == nil)
        #expect(BindingList.decode("") == nil)
        #expect(BindingList.decode(#"{"key":"A"}"#) == nil)
    }

    /// Digits used to be bindable; a list saved back then keeps its letter bindings.
    @Test func skipsEntriesItCannotRead() {
        let json = #"[{"key":"A","bundleID":"company.thebrowser.Browser","appName":"Arc","appPath":"\/Applications\/Arc.app"},"#
            + #"{"key":"3","bundleID":"x","appName":"x","appPath":"/x"},"#
            + #"{"key":"M"},"#
            + #"{"key":"M","bundleID":"com.apple.mail","appName":"Mail","appPath":"\/System\/Applications\/Mail.app"}]"#
        #expect(BindingList.decode(json) == [arc, mail])
    }
}

@Suite struct AppLocations {
    @Test func prefersTheStoredPath() {
        let url = AppLocation.resolve(arc, fileExists: { _ in true }, lookup: { _ in URL(fileURLWithPath: "/Elsewhere/Arc.app") })
        #expect(url?.path == "/Applications/Arc.app")
    }

    @Test func fallsBackToTheBundleID() {
        let url = AppLocation.resolve(
            arc, fileExists: { _ in false },
            lookup: { $0 == "company.thebrowser.Browser" ? URL(fileURLWithPath: "/Elsewhere/Arc.app") : nil }
        )
        #expect(url?.path == "/Elsewhere/Arc.app")
    }

    @Test func missingEverywhereIsNil() {
        #expect(AppLocation.resolve(arc, fileExists: { _ in false }, lookup: { _ in nil }) == nil)
    }
}
