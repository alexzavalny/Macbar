import Carbon.HIToolbox
import Testing
@testable import Macbar

@Suite struct Directions {
    @Test func keyCodesMatchCarbon() {
        #expect(Direction.left.keyCode == UInt32(kVK_LeftArrow))
        #expect(Direction.right.keyCode == UInt32(kVK_RightArrow))
        #expect(Direction.up.keyCode == UInt32(kVK_UpArrow))
        #expect(Direction.down.keyCode == UInt32(kVK_DownArrow))
    }
}

@Suite struct SplitNudges {
    @Test func startsEven() {
        #expect(Splits() == Splits(x: 0.5, y: 0.5))
    }

    @Test func arrowsMoveTheirDivider() {
        var s = Splits()
        s.nudge(.left)
        #expect(s == Splits(x: 0.45, y: 0.5))
        s.nudge(.down)
        s.nudge(.down)
        #expect(s == Splits(x: 0.45, y: 0.6))
        s.nudge(.right)
        s.nudge(.up)
        #expect(s == Splits(x: 0.5, y: 0.55))
    }

    @Test func clampsWithoutDrift() {
        var s = Splits()
        for _ in 0..<20 { s.nudge(.left); s.nudge(.up) }
        #expect(s == Splits(x: 0.2, y: 0.2))
        for _ in 0..<20 { s.nudge(.right); s.nudge(.down) }
        #expect(s == Splits(x: 0.8, y: 0.8))
        for _ in 0..<6 { s.nudge(.left) }
        #expect(s.x == 0.5)
    }

    @Test func appliesOnlyWhereADividerExists() {
        #expect(!Splits.applies(.left, count: 1))
        #expect(Splits.applies(.right, count: 2))
        #expect(!Splits.applies(.down, count: 2))
        #expect(Splits.applies(.up, count: 3))
        #expect(Splits.applies(.down, count: 4))
        #expect(Splits.applies(.left, count: 4))
    }
}

@Suite struct ArrowsInUse {
    @Test func onlyArrowsWithADividerAreTaken() {
        #expect(Splits.directions(for: 0).isEmpty)
        #expect(Splits.directions(for: 1).isEmpty)
        #expect(Splits.directions(for: 2) == [.left, .right])
        #expect(Splits.directions(for: 3) == [.left, .right, .up, .down])
        #expect(Splits.directions(for: 4) == [.left, .right, .up, .down])
    }
}
