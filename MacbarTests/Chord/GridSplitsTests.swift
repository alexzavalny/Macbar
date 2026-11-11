import CoreGraphics
import Testing
@testable import Macbar

private let screen = CGRect(x: 0, y: 25, width: 1000, height: 600)

@Suite struct GridWithSplits {
    @Test func twoFollowX() {
        #expect(GridLayout.frames(count: 2, in: screen, gap: 0, splits: Splits(x: 0.3, y: 0.5)) == [
            CGRect(x: 0, y: 25, width: 300, height: 600),
            CGRect(x: 300, y: 25, width: 700, height: 600),
        ])
    }

    @Test func threeFollowXAndRightColumnY() {
        #expect(GridLayout.frames(count: 3, in: screen, gap: 0, splits: Splits(x: 0.6, y: 0.25)) == [
            CGRect(x: 0, y: 25, width: 600, height: 600),
            CGRect(x: 600, y: 25, width: 400, height: 150),
            CGRect(x: 600, y: 175, width: 400, height: 450),
        ])
    }

    @Test func fourShareBothDividers() {
        #expect(GridLayout.frames(count: 4, in: screen, gap: 0, splits: Splits(x: 0.7, y: 0.4)) == [
            CGRect(x: 0, y: 25, width: 700, height: 240),
            CGRect(x: 700, y: 25, width: 300, height: 240),
            CGRect(x: 0, y: 265, width: 700, height: 360),
            CGRect(x: 700, y: 265, width: 300, height: 360),
        ])
    }

    // gap 10 → inner (10, 35, 980, 580); left = floor(970 × 0.3) = 291, right = 970 − 291 = 679.
    @Test func gapStillFillsExactly() {
        #expect(GridLayout.frames(count: 2, in: screen, gap: 10, splits: Splits(x: 0.3, y: 0.5)) == [
            CGRect(x: 10, y: 35, width: 291, height: 580),
            CGRect(x: 311, y: 35, width: 679, height: 580),
        ])
    }

    @Test func everyReachableSplitFillsTheArea() {
        var s = Splits()
        for _ in 0..<6 { s.nudge(.left); s.nudge(.up) }
        for _ in 0..<12 {
            for count in 2...4 {
                let f = GridLayout.frames(count: count, in: screen, gap: 6, splits: s)
                #expect(f.reduce(CGRect.null) { $0.union($1) } == screen.insetBy(dx: 6, dy: 6), "\(s) count \(count)")
            }
            s.nudge(.right)
            s.nudge(.down)
        }
    }

    @Test func singleIgnoresSplits() {
        #expect(GridLayout.frames(count: 1, in: screen, gap: 0, splits: Splits(x: 0.2, y: 0.8)) == [screen])
    }
}
