import Testing
@testable import Macbar

@Suite struct ModifierTaps {
    private let trigger: Modifiers = [.control, .option]

    /// Plays modifier changes `(held, time)` with the last key press or click at `lastInput`;
    /// true if the last change completes a tap.
    private func play(_ changes: [(Modifiers, Double)], lastInput: Double = -100) -> Bool {
        var tap = ModifierTap()
        var tapped = false
        for (held, time) in changes {
            tapped = tap.changed(to: held, trigger: trigger, at: time, lastInput: lastInput)
        }
        return tapped
    }

    @Test func pressedTogetherAndLetGoIsATap() {
        let tapped = play([([.control, .option], 0), ([], 0.2)])
        #expect(tapped)
    }

    @Test func pressedAndLetGoOneAtATimeIsATap() {
        let tapped = play([(.control, 0), ([.control, .option], 0.05), (.option, 0.2), ([], 0.25)])
        #expect(tapped)
    }

    @Test func holdingLongerThanTheLimitIsNoTap() {
        let tapped = play([([.control, .option], 0), ([], ModifierTap.limit + 0.01)])
        #expect(!tapped)
    }

    @Test func letGoAtTheLimitIsStillATap() {
        let tapped = play([([.control, .option], 0), ([], ModifierTap.limit)])
        #expect(tapped)
    }

    @Test func onlyPartOfTheTriggerIsNoTap() {
        let tapped = play([(.control, 0), ([], 0.1)])
        #expect(!tapped)
    }

    @Test func anExtraModifierIsNoTap() {
        let tapped = play([([.control, .option], 0), ([.control, .option, .command], 0.1), ([], 0.2)])
        #expect(!tapped)
    }

    @Test func anExtraModifierLetGoFirstIsStillNoTap() {
        let tapped = play([([.control, .option, .shift], 0), ([.control, .option], 0.1), ([], 0.2)])
        #expect(!tapped)
    }

    @Test func aKeyOrClickDuringTheHoldIsNoTap() {
        let tapped = play([([.control, .option], 0), ([], 0.2)], lastInput: 0.1)
        #expect(!tapped)
    }

    @Test func aKeyOrClickBeforeTheHoldDoesNotCount() {
        let tapped = play([([.control, .option], 1), ([], 1.2)], lastInput: 0.9)
        #expect(tapped)
    }

    @Test func onlyTheReleaseCompletesATap() {
        var tap = ModifierTap()
        let down = tap.changed(to: [.control, .option], trigger: trigger, at: 0, lastInput: -100)
        #expect(!down)
    }

    @Test func eachHoldIsJudgedOnItsOwn() {
        var tap = ModifierTap()
        tap.changed(to: [.control, .option, .command], trigger: trigger, at: 0, lastInput: -100)
        tap.changed(to: [], trigger: trigger, at: 0.1, lastInput: -100)
        tap.changed(to: [.control, .option], trigger: trigger, at: 1, lastInput: -100)
        let second = tap.changed(to: [], trigger: trigger, at: 1.1, lastInput: -100)
        #expect(second)
    }

    @Test func aReleaseWithoutAPressIsNoTap() {
        let tapped = play([([], 0)])
        #expect(!tapped)
    }

    @Test func otherTriggersWork() {
        var tap = ModifierTap()
        tap.changed(to: .command, trigger: .command, at: 0, lastInput: -100)
        let up = tap.changed(to: [], trigger: .command, at: 0.1, lastInput: -100)
        #expect(up)
    }
}
