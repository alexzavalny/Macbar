import Carbon.HIToolbox
import Testing
@testable import Macbar

@Suite struct SizeKeys {
    @Test func coversTwoToFive() {
        #expect(SizeKey.allCases.map(\.rawValue) == [2, 3, 4, 5])
    }

    @Test func keyCodesMatchCarbon() {
        #expect(SizeKey.two.keyCode == UInt32(kVK_ANSI_2))
        #expect(SizeKey.three.keyCode == UInt32(kVK_ANSI_3))
        #expect(SizeKey.four.keyCode == UInt32(kVK_ANSI_4))
        #expect(SizeKey.five.keyCode == UInt32(kVK_ANSI_5))
    }

    @Test func takenOnlyWhileADividerExists() {
        #expect(SizeKey.available(for: 0).isEmpty)
        #expect(SizeKey.available(for: 1).isEmpty)
        #expect(SizeKey.available(for: 2) == SizeKey.allCases)
        #expect(SizeKey.available(for: 4) == SizeKey.allCases)
    }
}

@Suite struct SizePressing {
    @Test func firstDigitGivesTheRightWindowOneNth() {
        var presses = SizePresses()
        #expect(presses.press(.three, count: 2, splits: Splits()) == Splits(x: 2.0 / 3, y: 0.5))
    }

    @Test func secondDigitGivesTheBottomWindowOneNth() {
        var presses = SizePresses()
        let wide = presses.press(.three, count: 3, splits: Splits())!
        #expect(presses.press(.four, count: 3, splits: wide) == Splits(x: 2.0 / 3, y: 0.75))
    }

    @Test func alternatesWidthAndHeight() {
        var presses = SizePresses()
        var s = Splits()
        for key in [SizeKey.two, .five, .four, .three] {
            s = presses.press(key, count: 4, splits: s)!
        }
        #expect(s == Splits(x: 0.75, y: 2.0 / 3))
        s = presses.press(.five, count: 4, splits: s)!
        #expect(s == Splits(x: 0.8, y: 2.0 / 3))
    }

    @Test func twoWindowsOnlyHaveWidth() {
        var presses = SizePresses()
        var s = presses.press(.three, count: 2, splits: Splits())!
        s = presses.press(.five, count: 2, splits: s)!
        #expect(s == Splits(x: 0.8, y: 0.5))
    }

    @Test func singleWindowHasNoDivider() {
        var presses = SizePresses()
        #expect(presses.press(.three, count: 1, splits: Splits()) == nil)
        #expect(presses.press(.three, count: 0, splits: Splits()) == nil)
        #expect(presses.press(.three, count: 3, splits: Splits()) == Splits(x: 2.0 / 3, y: 0.5))
    }

    @Test func resetStartsAtWidthAgain() {
        var presses = SizePresses()
        let wide = presses.press(.three, count: 3, splits: Splits())!
        presses.reset()
        #expect(presses.press(.four, count: 3, splits: wide) == Splits(x: 0.75, y: 0.5))
    }
}
