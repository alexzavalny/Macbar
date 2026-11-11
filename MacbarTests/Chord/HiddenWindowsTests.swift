import CoreGraphics
import Testing
@testable import Macbar

private let f1 = CGRect(x: 10, y: 10, width: 100, height: 100)
private let f2 = CGRect(x: 20, y: 20, width: 200, height: 200)
private let parked = CGRect(x: 1439, y: 899, width: 100, height: 100)

@Suite struct HiddenRegistry {
    @Test func keepsTheFirstRecord() {
        var h = HiddenWindows<Int>()
        h.add(1, pid: 7, frame: f1)
        h.add(1, pid: 7, frame: parked)
        #expect(h.entries.map(\.frame) == [f1])
        #expect(h.contains(1))
    }

    @Test func removeByID() {
        var h = HiddenWindows<Int>()
        h.add(1, pid: 7, frame: f1)
        #expect(h.remove(1)?.frame == f1)
        #expect(h.remove(1) == nil)
        #expect(!h.contains(1))
    }

    @Test func removeByPIDInHideOrder() {
        var h = HiddenWindows<Int>()
        h.add(1, pid: 7, frame: f1)
        h.add(2, pid: 8, frame: f2)
        h.add(3, pid: 7, frame: f2)
        #expect(h.removeAll(pid: 7).map(\.id) == [1, 3])
        #expect(h.entries.map(\.id) == [2])
    }

    @Test func removeAll() {
        var h = HiddenWindows<Int>()
        h.add(1, pid: 7, frame: f1)
        h.add(2, pid: 8, frame: f2)
        #expect(h.removeAll().map(\.id) == [1, 2])
        #expect(h.entries.isEmpty)
    }
}

private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

@Suite struct HidePicks {
    private func w(_ id: Int, pid: Int32 = 7, _ frame: CGRect) -> WindowInfo<Int> { WindowInfo(id: id, pid: pid, frame: frame) }

    @Test func hidesEverythingElseOnTheDisplay() {
        let all = [w(1, f1), w(2, pid: 8, f2)]
        #expect(HideSelection.toHide(all, keep: [], display: display, ownPID: 99) == all)
    }

    @Test func skipsKeptOwnOffDisplayAndParked() {
        let kept = w(1, f1)
        let own = w(2, pid: 99, f1)
        let elsewhere = w(3, CGRect(x: 2000, y: 100, width: 800, height: 600))   // centre on another display
        let straddling = w(4, CGRect(x: 1000, y: 100, width: 800, height: 600))  // centre x 1400: still here
        let alreadyParked = w(5, parked)
        let result = HideSelection.toHide([kept, own, elsewhere, straddling, alreadyParked], keep: [1], display: display, ownPID: 99)
        #expect(result.map(\.id) == [4])
    }

    @Test func skipsAppsThatAreNeverHidden() {
        let all = [w(1, f1), w(2, pid: 8, f2), w(3, pid: 9, f1)]
        #expect(HideSelection.toHide(all, keep: [], keepPIDs: [8, 9], display: display, ownPID: 99).map(\.id) == [1])
    }
}
