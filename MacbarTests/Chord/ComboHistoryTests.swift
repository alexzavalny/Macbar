import Carbon.HIToolbox
import Testing
@testable import Macbar

private func app(_ key: TriggerKey, _ id: String) -> AppBinding {
    AppBinding(key: key, bundleID: id, appName: id, appPath: "/Applications/\(id).app")
}

private let arc = app(.a, "arc"), mail = app(.m, "mail"), notes = app(.n, "notes")

private func combo(_ apps: AppBinding..., x: Double = 0.5) -> Combo {
    Combo(apps: apps, splits: Splits(x: x, y: 0.5))
}

@Suite struct HistoryKeys {
    @Test func bracketKeyCodesMatchCarbon() {
        #expect(HistoryMove.back.keyCode == UInt32(kVK_ANSI_LeftBracket))
        #expect(HistoryMove.forward.keyCode == UInt32(kVK_ANSI_RightBracket))
    }
}

@Suite struct History {
    @Test func emptyHasNowhereToGo() {
        var h = ComboHistory()
        let back = h.back(), forward = h.forward()
        #expect(h.current == nil && back == nil && forward == nil)
    }

    @Test func backAndForwardWalkTheChords() {
        var h = ComboHistory()
        h.record(combo(arc))
        h.record(combo(arc, mail))
        h.record(combo(notes))
        let steps = [h.back(), h.back(), h.back()]
        #expect(steps == [combo(arc, mail), combo(arc), nil])
        #expect(h.current == combo(arc))
        let ahead = [h.forward(), h.forward(), h.forward()]
        #expect(ahead == [combo(arc, mail), combo(notes), nil])
    }

    @Test func aNewChordAfterGoingBackDropsWhatWasAhead() {
        var h = ComboHistory()
        h.record(combo(arc))
        h.record(combo(mail))
        h.record(combo(notes))
        _ = h.back()
        _ = h.back()
        h.record(combo(mail, notes))
        let forward = h.forward()
        #expect(h.entries == [combo(arc), combo(mail, notes)])
        #expect(forward == nil)
    }

    @Test func theSameChordAgainIsOneEntry() {
        var h = ComboHistory()
        h.record(combo(arc, mail))
        h.record(combo(arc, mail, x: 0.3))
        #expect(h.entries == [combo(arc, mail, x: 0.3)])
    }

    @Test func sameAppsInAnotherOrderIsANewChord() {
        var h = ComboHistory()
        h.record(combo(arc, mail))
        h.record(combo(mail, arc))
        #expect(h.entries.count == 2)
    }

    @Test func sameAppOnAReboundKeyIsTheSameChord() {
        var h = ComboHistory()
        h.record(combo(arc))
        h.record(combo(app(.b, "arc")))
        #expect(h.entries == [combo(app(.b, "arc"))])
    }

    @Test func replayingTheCurrentChordAfterGoingBackKeepsWhatIsAhead() {
        var h = ComboHistory()
        h.record(combo(arc))
        h.record(combo(mail))
        _ = h.back()
        h.record(combo(arc))
        let forward = h.forward()
        #expect(forward == combo(mail))
    }

    @Test func resizingUpdatesTheEntryOnScreen() {
        var h = ComboHistory()
        h.record(combo(arc, mail))
        h.record(combo(notes, mail))
        _ = h.back()
        h.setSplits(Splits(x: 0.7, y: 0.5))
        let forward = h.forward()
        #expect(h.entries == [combo(arc, mail, x: 0.7), combo(notes, mail)])
        #expect(forward == combo(notes, mail))
    }

    @Test func keepsTheLastFifty() {
        var h = ComboHistory()
        for i in 0..<60 { h.record(combo(app(.a, "app\(i)"))) }
        #expect(h.entries.count == ComboHistory.limit)
        #expect(h.entries.first == combo(app(.a, "app10")))
        #expect(h.current == combo(app(.a, "app59")))
        let back = h.back()
        #expect(back == combo(app(.a, "app58")))
    }
}
