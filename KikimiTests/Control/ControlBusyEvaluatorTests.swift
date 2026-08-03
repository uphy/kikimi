import Foundation
import Testing

@testable import Kikimi

@Suite("ControlBusyEvaluator")
struct ControlBusyEvaluatorTests {
    @Test("idle when nothing is recording, dictating, or paused on screen")
    func idle() {
        let reason = ControlBusyEvaluator.busyReason(
            recordingSessionId: nil,
            dictationState: .idle,
            openPausedSessionIds: []
        )

        #expect(reason == nil)
    }

    @Test("a live recording is busy")
    func recordingIsBusy() {
        let reason = ControlBusyEvaluator.busyReason(
            recordingSessionId: "2026-08-03T05-59-26_9427133b",
            dictationState: .idle,
            openPausedSessionIds: []
        )

        #expect(reason == "session 2026-08-03T05-59-26_9427133b is recording")
    }

    /// Every state between hotkey-down and insertion counts: the utterance is lost either way.
    @Test("every in-flight dictation state is busy", arguments: [
        DictationState.capturing,
        .transcribing,
        .refining,
        .inserting,
    ])
    func dictationInFlightIsBusy(state: DictationState) {
        let reason = ControlBusyEvaluator.busyReason(
            recordingSessionId: nil,
            dictationState: state,
            openPausedSessionIds: []
        )

        #expect(reason == "dictation is \(state.controlReasonVerb)")
    }

    /// `.disabled` is the feature being off, not work in progress -- restarting then loses nothing.
    @Test("idle and disabled dictation both allow a restart", arguments: [
        DictationState.idle,
        .disabled,
    ])
    func dictationAtRestIsFree(state: DictationState) {
        let reason = ControlBusyEvaluator.busyReason(
            recordingSessionId: nil,
            dictationState: state,
            openPausedSessionIds: []
        )

        #expect(reason == nil)
    }

    @Test("an open paused window is busy: the meeting is stopped, not over")
    func openPausedWindowIsBusy() {
        let reason = ControlBusyEvaluator.busyReason(
            recordingSessionId: nil,
            dictationState: .idle,
            openPausedSessionIds: ["2026-08-03T01-00-01_54ceda2b"]
        )

        #expect(reason == "session 2026-08-03T01-00-01_54ceda2b is paused and open")
    }

    @Test("the reported paused session is deterministic when several windows are open")
    func pausedReasonIsStable() {
        let reason = ControlBusyEvaluator.busyReason(
            recordingSessionId: nil,
            dictationState: .idle,
            openPausedSessionIds: ["2026-08-03T09-00-00_zzz", "2026-08-03T01-00-00_aaa"]
        )

        #expect(reason == "session 2026-08-03T01-00-00_aaa is paused and open")
    }

    /// Design 46 §4's order: the most specific reason wins, so a user reading the refusal sees the
    /// recording rather than an incidental paused window.
    @Test("recording outranks dictation, which outranks a paused window")
    func reasonPriority() {
        let allBusy = ControlBusyEvaluator.busyReason(
            recordingSessionId: "rec-1",
            dictationState: .capturing,
            openPausedSessionIds: ["paused-1"]
        )
        let dictationAndPaused = ControlBusyEvaluator.busyReason(
            recordingSessionId: nil,
            dictationState: .capturing,
            openPausedSessionIds: ["paused-1"]
        )

        #expect(allBusy == "session rec-1 is recording")
        #expect(dictationAndPaused == "dictation is capturing")
    }
}
