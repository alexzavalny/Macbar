import CoreGraphics
import Testing
@testable import Macbar

// AX coordinates: a 1000×600 visible area under a 25 pt menu bar.
private let screen = CGRect(x: 0, y: 25, width: 1000, height: 600)

@Suite struct Grid {
    @Test func oneFillsTheScreen() {
        #expect(GridLayout.frames(count: 1, in: screen, gap: 0) == [screen])
    }

    @Test func twoAreHalves() {
        #expect(GridLayout.frames(count: 2, in: screen, gap: 0) == [
            CGRect(x: 0, y: 25, width: 500, height: 600),
            CGRect(x: 500, y: 25, width: 500, height: 600),
        ])
    }

    @Test func threeIsBigLeftAndStackedRight() {
        #expect(GridLayout.frames(count: 3, in: screen, gap: 0) == [
            CGRect(x: 0, y: 25, width: 500, height: 600),
            CGRect(x: 500, y: 25, width: 500, height: 300),
            CGRect(x: 500, y: 325, width: 500, height: 300),
        ])
    }

    @Test func fourIsAGridInPressOrder() {
        #expect(GridLayout.frames(count: 4, in: screen, gap: 0) == [
            CGRect(x: 0, y: 25, width: 500, height: 300),
            CGRect(x: 500, y: 25, width: 500, height: 300),
            CGRect(x: 0, y: 325, width: 500, height: 300),
            CGRect(x: 500, y: 325, width: 500, height: 300),
        ])
    }

    // gap 10 → inner (10, 35, 980, 580); halves (980 − 10) / 2 = 485; rows (580 − 10) / 2 = 285.
    @Test func gapInsetsEdgesAndSeparatesSlots() {
        #expect(GridLayout.frames(count: 1, in: screen, gap: 10) == [CGRect(x: 10, y: 35, width: 980, height: 580)])
        #expect(GridLayout.frames(count: 4, in: screen, gap: 10) == [
            CGRect(x: 10, y: 35, width: 485, height: 285),
            CGRect(x: 505, y: 35, width: 485, height: 285),
            CGRect(x: 10, y: 330, width: 485, height: 285),
            CGRect(x: 505, y: 330, width: 485, height: 285),
        ])
    }

    @Test func oddSizesFillExactlyWithoutOverlap() {
        let odd = CGRect(x: 0, y: 38, width: 1511, height: 943) // notch menu bar, Dock on the side
        for count in 2...4 {
            for gap in [0.0, 7.0] {
                let f = GridLayout.frames(count: count, in: odd, gap: gap)
                #expect(f.count == count)
                #expect(f.reduce(CGRect.null) { $0.union($1) } == odd.insetBy(dx: gap, dy: gap), "count \(count) gap \(gap)")
                for i in f.indices {
                    for j in f.indices where i < j {
                        let o = f[i].intersection(f[j])
                        #expect(o.isNull || o.width * o.height == 0, "slots \(i) and \(j) overlap")
                    }
                }
            }
        }
    }

    @Test func fractionalScreenGivesWholePoints() {
        let frac = CGRect(x: 0.5, y: 37.5, width: 1511.5, height: 900.25)
        for count in 1...4 {
            for r in GridLayout.frames(count: count, in: frac, gap: 3) {
                #expect(r == r.integral, "\(r)")
            }
        }
    }

    @Test func outOfRangeCountsAreEmpty() {
        #expect(GridLayout.frames(count: 0, in: screen, gap: 0).isEmpty)
        #expect(GridLayout.frames(count: 5, in: screen, gap: 0).isEmpty)
    }
}
