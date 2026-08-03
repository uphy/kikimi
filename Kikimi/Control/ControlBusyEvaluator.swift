import Foundation

// MARK: - ControlBusyEvaluator

/// Decides whether Kikimi can be quit and replaced right now (`docs/design/46-control-socket.md`
/// §4). Pure and dependency-free on purpose: the live state lives in three different `@MainActor`
/// singletons, and this is the part worth unit-testing.
enum ControlBusyEvaluator {
    /// `nil` when a restart is safe. Conditions are evaluated in the design doc's order so the
    /// reported reason is the most specific one -- a live recording outranks an open paused window.
    ///
    /// - Parameters:
    ///   - recordingSessionId: `WindowManager.recordingSessionId`. Non-`nil` means audio is being
    ///     captured right now (kikimi.md 10 章: at most one session records at a time).
    ///   - dictationState: `DictationController.state`. Everything except `.idle`/`.disabled` means
    ///     an utterance is mid-flight; `.disabled` is the feature being off, not work in progress.
    ///   - openPausedSessionIds: sessions whose workspace window is open and whose state is
    ///     `.paused` -- the meeting is still on, the user just stopped recording for a moment
    ///     (kikimi.md 4 章). A paused session with no window is a leftover and does not block.
    static func busyReason(
        recordingSessionId: String?,
        dictationState: DictationState,
        openPausedSessionIds: [String]
    ) -> String? {
        if let recordingSessionId {
            return "session \(recordingSessionId) is recording"
        }

        switch dictationState {
        case .idle, .disabled:
            break
        case .capturing, .transcribing, .refining, .inserting:
            return "dictation is \(dictationState.controlReasonVerb)"
        }

        // The smallest id, so the reported one is deterministic when more than one paused window is
        // open; which one is named does not matter, but a stable answer keeps logs comparable.
        if let pausedSessionId = openPausedSessionIds.min() {
            return "session \(pausedSessionId) is paused and open"
        }

        return nil
    }
}

// MARK: - DictationState + control reason

extension DictationState {
    /// How this state is named in a control-socket refusal ("dictation is <verb>"). Kept next to
    /// the evaluator rather than on the state machine itself: it is wire vocabulary, not UI text.
    var controlReasonVerb: String {
        switch self {
        case .disabled: return "disabled"
        case .idle: return "idle"
        case .capturing: return "capturing"
        case .transcribing: return "transcribing"
        case .refining: return "refining"
        case .inserting: return "inserting"
        }
    }
}
