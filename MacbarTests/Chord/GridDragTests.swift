import CoreGraphics
import Testing
@testable import Macbar

private let screen = CGRect(x: 0, y: 25, width: 1000, height: 800)
private let even = Splits()

private func drag(_ slot: Int, of count: Int, to frame: CGRect, gap: Double = 0, from splits: Splits = even) -> Splits {
    GridLayout.splits(dragging: slot, to: frame, count: count, in: screen, gap: gap, from: splits)
}

@Suite struct GridDrags {
    @Test func leftWindowsRightEdgeMovesTheVerticalDivider() {
        #expect(drag(0, of: 2, to: CGRect(x: 0, y: 25, width: 600, height: 800)) == Splits(x: 0.6, y: 0.5))
    }

    @Test func rightWindowsLeftEdgeMovesTheVerticalDivider() {
        #expect(drag(1, of: 2, to: CGRect(x: 300, y: 25, width: 700, height: 800)) == Splits(x: 0.3, y: 0.5))
    }

    @Test func gapIsLeftOutOfTheShare() {
        // Inset area 980 wide, 970 to share: 582 is 60 %.
        let s = drag(0, of: 2, to: CGRect(x: 10, y: 35, width: 582, height: 780), gap: 10)
        #expect(s == Splits(x: 0.6, y: 0.5))
        #expect(GridLayout.frames(count: 2, in: screen, gap: 10, splits: s)[0].width == 582)
    }

    @Test func stackedWindowsInnerEdgesMoveTheHorizontalDivider() {
        // Right column of three: top 25…425, bottom 425…825.
        #expect(drag(2, of: 3, to: CGRect(x: 500, y: 225, width: 500, height: 600)) == Splits(x: 0.5, y: 0.25))
        #expect(drag(1, of: 3, to: CGRect(x: 500, y: 25, width: 500, height: 600)) == Splits(x: 0.5, y: 0.75))
    }

    @Test func fourWindowsShareBothDividers() {
        #expect(drag(2, of: 4, to: CGRect(x: 0, y: 225, width: 500, height: 600)) == Splits(x: 0.5, y: 0.25))
        #expect(drag(0, of: 4, to: CGRect(x: 0, y: 25, width: 700, height: 400)) == Splits(x: 0.7, y: 0.5))
    }

    @Test func cornerDragMovesBoth() {
        #expect(drag(3, of: 4, to: CGRect(x: 300, y: 225, width: 700, height: 600)) == Splits(x: 0.3, y: 0.25))
    }

    @Test func outerEdgesChangeNothing() {
        // Left window's left edge, right window's right edge, the full-height window's bottom.
        #expect(drag(0, of: 2, to: CGRect(x: 100, y: 25, width: 400, height: 800)) == even)
        #expect(drag(1, of: 2, to: CGRect(x: 500, y: 25, width: 300, height: 800)) == even)
        #expect(drag(0, of: 3, to: CGRect(x: 0, y: 25, width: 500, height: 500)) == even)
        #expect(drag(1, of: 3, to: CGRect(x: 500, y: 125, width: 500, height: 300)) == even)
    }

    @Test func movingAWindowChangesNothing() {
        #expect(drag(0, of: 2, to: CGRect(x: 120, y: 85, width: 500, height: 800)) == even)
        #expect(drag(3, of: 4, to: CGRect(x: 400, y: 325, width: 500, height: 400)) == even)
    }

    @Test func jitterUnderTwoPointsChangesNothing() {
        #expect(drag(0, of: 2, to: CGRect(x: 0, y: 25, width: 501.5, height: 800)) == even)
    }

    @Test func measuredFromTheSplitsTheDragStartedWith() {
        let start = Splits(x: 0.3, y: 0.5)
        #expect(drag(0, of: 2, to: CGRect(x: 0, y: 25, width: 400, height: 800), from: start) == Splits(x: 0.4, y: 0.5))
    }

    @Test func clampedToTheArrowLimits() {
        #expect(drag(0, of: 2, to: CGRect(x: 0, y: 25, width: 950, height: 800)) == Splits(x: 0.8, y: 0.5))
        #expect(drag(1, of: 2, to: CGRect(x: 50, y: 25, width: 950, height: 800)) == Splits(x: 0.2, y: 0.5))
    }

    @Test func nothingToShareWithoutASecondWindow() {
        #expect(drag(0, of: 1, to: CGRect(x: 0, y: 25, width: 600, height: 800)) == even)
        #expect(drag(5, of: 2, to: CGRect(x: 0, y: 25, width: 600, height: 800)) == even)
    }
}
