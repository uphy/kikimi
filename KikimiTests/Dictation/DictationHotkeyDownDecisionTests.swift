import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `DictationHotkeyDownDecision.decide` -- the pure core of
/// `DictationController.handleHotkeyDown()`'s re-entrancy guard (`docs/design/25-dictation-mode.md`
/// §4/§11). No recording-session input: R4 dropped the meeting-recording exclusivity gate after D1
/// shipped, so a hotkey press is no longer refused while a meeting is recording.
@Suite("DictationHotkeyDownDecision")
struct DictationHotkeyDownDecisionTests {
    @Test("idle, warmed up -> start")
    func idleReadyStarts() {
        let decision = DictationHotkeyDownDecision.decide(state: .idle, isTranscriberReady: true)
        #expect(decision == .start)
    }

    @Test(
        "any non-idle state ignores the press, regardless of warm status",
        arguments: [DictationState.disabled, .capturing, .transcribing, .refining, .inserting]
    )
    func nonIdleStateIgnores(state: DictationState) {
        let decision = DictationHotkeyDownDecision.decide(state: state, isTranscriberReady: true)
        #expect(decision == .ignore)
    }

    @Test("not yet warmed up refuses, even while idle")
    func notWarmedUpRefuses() {
        let decision = DictationHotkeyDownDecision.decide(state: .idle, isTranscriberReady: false)
        #expect(decision == .refuseNotWarmedUp)
    }
}
