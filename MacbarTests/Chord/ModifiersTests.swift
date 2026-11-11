import Carbon.HIToolbox
import Testing
@testable import Macbar

@Suite struct ModifierFlags {
    @Test func defaultIsControlOption() {
        #expect(Modifiers.default == [.control, .option])
    }

    @Test func carbonFlagsMatchCarbon() {
        #expect(Modifiers.control.carbonFlags == UInt32(controlKey))
        #expect(Modifiers.option.carbonFlags == UInt32(optionKey))
        #expect(Modifiers.shift.carbonFlags == UInt32(shiftKey))
        #expect(Modifiers.command.carbonFlags == UInt32(cmdKey))
        #expect(Modifiers.default.carbonFlags == UInt32(controlKey | optionKey))
    }

    @Test func validNeedsControlOptionOrCommand() {
        #expect(Modifiers.control.isValid)
        #expect(Modifiers.option.isValid)
        #expect(Modifiers.command.isValid)
        #expect(Modifiers([.shift, .command]).isValid)
        #expect(!Modifiers.shift.isValid)
        #expect(!Modifiers([]).isValid)
    }

    @Test func settingRefusesInvalidResult() {
        #expect(Modifiers.default.setting(.shift, true) == [.control, .option, .shift])
        #expect(Modifiers.default.setting(.option, false) == [.control])
        #expect(Modifiers.control.setting(.control, false) == nil)
        #expect(Modifiers([.control, .shift]).setting(.control, false) == nil)
    }

    @Test func symbolsInMacOrder() {
        #expect(Modifiers([.command, .shift, .option, .control]).symbols == "⌃⌥⇧⌘")
        #expect(Modifiers.default.symbols == "⌃⌥")
        #expect(Modifiers.ordered.map(\.symbol).joined() == "⌃⌥⇧⌘")
    }
}
