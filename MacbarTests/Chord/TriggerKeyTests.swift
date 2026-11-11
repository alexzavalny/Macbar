import Carbon.HIToolbox
import Testing
@testable import Macbar

@Suite struct TriggerKeys {
    @Test func coversLettersOnly() {
        #expect(TriggerKey.allCases.count == 26)
        #expect(TriggerKey.allCases.map(\.rawValue).joined() == "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        #expect(TriggerKey(rawValue: "3") == nil)
    }

    @Test func keyCodesMatchCarbon() {
        let expected: [TriggerKey: Int] = [
            .a: kVK_ANSI_A, .b: kVK_ANSI_B, .c: kVK_ANSI_C, .d: kVK_ANSI_D, .e: kVK_ANSI_E,
            .f: kVK_ANSI_F, .g: kVK_ANSI_G, .h: kVK_ANSI_H, .i: kVK_ANSI_I, .j: kVK_ANSI_J,
            .k: kVK_ANSI_K, .l: kVK_ANSI_L, .m: kVK_ANSI_M, .n: kVK_ANSI_N, .o: kVK_ANSI_O,
            .p: kVK_ANSI_P, .q: kVK_ANSI_Q, .r: kVK_ANSI_R, .s: kVK_ANSI_S, .t: kVK_ANSI_T,
            .u: kVK_ANSI_U, .v: kVK_ANSI_V, .w: kVK_ANSI_W, .x: kVK_ANSI_X, .y: kVK_ANSI_Y,
            .z: kVK_ANSI_Z,
        ]
        #expect(expected.count == 26)
        for (key, code) in expected {
            #expect(key.keyCode == UInt32(code), "key \(key.rawValue)")
        }
    }

    @Test func sortsAlphabetically() {
        #expect(TriggerKey.a < TriggerKey.z)
        #expect([TriggerKey.z, .m, .a].sorted() == [.a, .m, .z])
    }
}
