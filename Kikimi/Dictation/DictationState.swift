import Foundation

// MARK: - DictationState

/// `docs/design/25-dictation-mode.md` §4's state machine. `.aborted` from the design doc's diagram
/// is a same-tick outcome of `.inserting` (`DictationInsertOutcome.abortedAndStashed`) rather than
/// an observable intermediate state, so it has no case here.
///
/// Split out of `DictationController.swift` (together with `DictationHotkeyDownDecision` below)
/// once the two-pass decode wiring (`docs/design/31-dictation-two-pass-decode.md`) pushed that file
/// past SwiftLint's 600-line file-length limit -- the same reason `DictationSettingsTab` left
/// `SettingsView.swift`.
enum DictationState: Equatable, Sendable {
    case disabled
    case idle
    case capturing
    case transcribing
    /// D2 only: `dictation.refine == true` and the single-shot `DictationRefiner` call is in
    /// flight. Skipped entirely when `refine == false` (D1's fast path).
    case refining
    case inserting
}

// MARK: - DictationHotkeyDownDecision

/// Pure decision for `DictationController.handleHotkeyDown()` (`docs/design/25-dictation-mode.md`
/// §4/§11). Takes every input the real handler reads and returns what to do, so the re-entrancy
/// guard is unit-testable without a real `AppConfig`/warm `DictationTranscriber`.
///
/// No longer takes a recording-session id (R4 dropped the meeting-recording exclusivity gate after
/// D1 shipped -- dictation now shares the mic with an in-progress meeting recording rather than
/// refusing to start).
enum DictationHotkeyDownDecision: Equatable, Sendable {
    /// Begin capturing a new utterance.
    case start
    /// Not idle (already capturing/transcribing/inserting, or the feature is disabled). Ignored
    /// silently -- this is either a stray re-entrant key-down or the feature being off.
    case ignore
    /// The STT backend hasn't finished warming yet. Ignored silently (logged, no notification --
    /// see `handleHotkeyDown()`'s doc comment on why user-facing notifications were dropped).
    case refuseNotWarmedUp

    static func decide(state: DictationState, isTranscriberReady: Bool) -> Self {
        guard state == .idle else {
            return .ignore
        }
        guard isTranscriberReady else {
            return .refuseNotWarmedUp
        }
        return .start
    }
}
