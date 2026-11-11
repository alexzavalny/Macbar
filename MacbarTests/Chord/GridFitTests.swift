import CoreGraphics
import Testing
@testable import Macbar

private let screen = CGRect(x: 0, y: 25, width: 1000, height: 800)
private let even = Splits()

private func fit(_ actual: [CGRect?], _ count: Int, gap: Double = 0, from splits: Splits = even) -> Splits {
    GridLayout.splits(fitting: actual, count: count, in: screen, gap: gap, from: splits)
}

@Suite struct GridFits {
    @Test func aWiderLeftWindowPushesTheDividerRight() {
        #expect(fit([CGRect(x: 0, y: 25, width: 600, height: 800), nil], 2) == Splits(x: 0.6, y: 0.5))
    }

    /// Chord puts each window at its slot's corner; one that insists on a bigger size runs past
    /// the slot's far edge.
    @Test func aWiderRightWindowPushesTheDividerLeft() {
        #expect(fit([nil, CGRect(x: 500, y: 25, width: 700, height: 800)], 2) == Splits(x: 0.3, y: 0.5))
    }

    @Test func aNarrowerWindowGivesTheRestAway() {
        #expect(fit([CGRect(x: 0, y: 25, width: 450, height: 800), nil], 2) == Splits(x: 0.45, y: 0.5))
    }

    @Test func windowsThatFitChangeNothing() {
        let slots = GridLayout.frames(count: 2, in: screen, gap: 0)
        #expect(fit(slots, 2) == even)
        #expect(fit([CGRect(x: 0, y: 25, width: 501.5, height: 800), nil], 2) == even)
    }

    @Test func stackedWindowsSetTheirHeights() {
        #expect(fit([nil, nil, CGRect(x: 500, y: 425, width: 500, height: 600)], 3) == Splits(x: 0.5, y: 0.25))
        #expect(fit([nil, CGRect(x: 500, y: 25, width: 500, height: 600), nil], 3) == Splits(x: 0.5, y: 0.75))
    }

    @Test func theFullHeightWindowOfThreeNeverSetsTheHeight() {
        #expect(fit([CGRect(x: 0, y: 25, width: 500, height: 500), nil, nil], 3) == even)
    }

    @Test func fourWindowsShareBothDividers() {
        #expect(fit([nil, nil, nil, CGRect(x: 500, y: 425, width: 300, height: 600)], 4) == Splits(x: 0.7, y: 0.25))
    }

    @Test func aLaterWindowWins() {
        let left = CGRect(x: 0, y: 25, width: 600, height: 800)
        let right = CGRect(x: 500, y: 25, width: 600, height: 800)
        #expect(fit([left, right], 2) == Splits(x: 0.4, y: 0.5))
    }

    @Test func clampedToTheFitRange() {
        #expect(fit([CGRect(x: 0, y: 25, width: 990, height: 800), nil], 2) == Splits(x: 0.95, y: 0.5))
    }

    @Test func gapIsLeftOutOfTheShare() {
        #expect(fit([CGRect(x: 10, y: 35, width: 582, height: 780), nil], 2, gap: 10) == Splits(x: 0.6, y: 0.5))
    }

    @Test func oneWindowHasNoDivider() {
        #expect(fit([CGRect(x: 0, y: 25, width: 600, height: 800)], 1) == even)
        #expect(fit([nil, nil], 2) == even)
    }

    /// A window that never took its place (native fullscreen, a late or refused move) says
    /// nothing about the size it wants.
    @Test func aWindowAwayFromItsSlotIsIgnored() {
        #expect(fit([CGRect(x: 0, y: 0, width: 1000, height: 825), nil], 2) == even)
        #expect(fit([nil, CGRect(x: 520, y: 25, width: 300, height: 800)], 2) == even)
    }
}

@Suite struct GridMatches {
    private let slot = CGRect(x: 500, y: 25, width: 500, height: 800)

    @Test func findsTheWindowSittingInTheSlot() {
        let frames: [CGRect?] = [CGRect(x: 0, y: 25, width: 500, height: 800), nil, CGRect(x: 501, y: 26, width: 498, height: 801)]
        #expect(GridLayout.match(slot, in: frames) == 2)
    }

    @Test func anEdgeMoreThanTwoPointsOffIsNoMatch() {
        #expect(GridLayout.match(slot, in: [CGRect(x: 500, y: 25, width: 497, height: 800)]) == nil)
        #expect(GridLayout.match(slot, in: []) == nil)
    }
}
