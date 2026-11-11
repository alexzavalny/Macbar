import Testing
@testable import Macbar

@Suite struct ComboSessions {
    private let none: () -> Int = { 0 }

    @Test func startsEmpty() {
        #expect(ComboSession().keys.isEmpty)
    }

    @Test func keepsPressOrder() {
        var s = ComboSession()
        let first = s.press(.m, windows: none)
        let second = s.press(.a, windows: none)
        #expect(first && second)
        #expect(s.keys == [.m, .a])
    }

    @Test func autoRepeatOfTheSameKeyCountsOnce() {
        var s = ComboSession()
        s.press(.a, windows: { 5 })
        let repeats = (0..<10).map { _ in s.press(.a, windows: { 5 }) }
        #expect(repeats.allSatisfy { !$0 })
        #expect(s.keys == [.a])
    }

    @Test func aReleasedKeyPressedAgainAddsAnotherWindow() {
        var s = ComboSession()
        s.press(.a, windows: { 2 })
        s.release(.a)
        let again = s.press(.a, windows: { 2 })
        #expect(again)
        #expect(s.keys == [.a, .a])
    }

    @Test func aRepeatNeedsAWindowLeft() {
        var s = ComboSession()
        s.press(.a, windows: { 1 })
        s.release(.a)
        let oneWindow = s.press(.a, windows: { 1 })
        s.release(.a)
        let twoWindows = s.press(.a, windows: { 2 })
        s.release(.a)
        let thirdOfTwo = s.press(.a, windows: { 2 })
        #expect(!oneWindow && twoWindows && !thirdOfTwo)
        #expect(s.keys == [.a, .a])
    }

    @Test func windowsAreAskedOnlyForARepeat() {
        var s = ComboSession()
        var asked = 0
        s.press(.a, windows: { asked += 1; return 0 })
        #expect(asked == 0)
        #expect(s.keys == [.a])
    }

    @Test func capsAtFour() {
        var s = ComboSession()
        for key in [TriggerKey.a, .b, .c, .d] { s.press(key, windows: none) }
        let fifth = s.press(.e, windows: none)
        #expect(!fifth)
        #expect(s.keys == [.a, .b, .c, .d])
    }

    @Test func addIsForReplaysAndIgnoresHeldKeys() {
        var s = ComboSession()
        s.add(.a, windows: { 2 })
        s.add(.a, windows: { 2 })
        let third = s.add(.a, windows: { 2 })
        #expect(s.keys == [.a, .a])
        #expect(!third)
    }

    @Test func removeTakesOneSlotOut() {
        var s = ComboSession()
        s.press(.a, windows: none)
        s.press(.m, windows: none)
        s.remove(at: 0)
        #expect(s.keys == [.m])
        s.release(.a)
        let back = s.press(.a, windows: none)
        #expect(back)
        #expect(s.keys == [.m, .a])
    }
}
