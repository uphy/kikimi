// MARK: - WindowCloseDecision

/// Pure decision table for `windowShouldClose` (`docs/design/06-ui-panels.md` section 6.1.1,
/// `docs/design/18-recording-window-stow-and-compact.md` §2 R2/R7), factored out of
/// `MeetingWorkspaceWindowController` so the branching logic is unit-testable without driving real
/// `NSWindow` machinery (`docs/design/06-ui-panels.md` section 12 favors testing pure functions over
/// actor/AppKit-entangled code wherever the logic allows it — see e.g. `TranscriptRowList`,
/// `Kikimi/ViewModels/TranscriptRowList.swift`).
///
/// Supersedes the old 4-value `WindowCloseDecision`/`RecordingCloseChoice` confirmation-dialog state
/// machine (18章 R7): closing a Recording/Paused window no longer asks anything -- it silently stows
/// instead (§3.2). There is no dialog to be "already showing", so this table has no state to consume
/// or thread through repeated calls the way the old `isConfirmingClose`/`closeApprovedAfterStop`
/// two-flag pattern did; `evaluate` is a plain function of the current `RecordingButtonState`, called
/// fresh on every `windowShouldClose` invocation.
enum WindowCloseDecision: Equatable {
    /// Draft / Ended (`isStowable == false`, `blocksClose == false`): let the close proceed as a real,
    /// destructive-to-the-window close (the session folder itself is never touched here).
    case allowClose
    /// `.recording` / `.paused` / `.pausedDisabledOtherRecording` (`isStowable == true`): deny the
    /// close and stow the window instead (§3.2/R1) -- reachable again from the menu bar or Session
    /// List, recording untouched. Takes priority over `blocksClose` (both are `true` for these states)
    /// since stowing is the more specific, correct response.
    case stowInsteadOfClose
    /// `.starting` / `.pausing` / `.resuming` / `.ending` (`isStowable == false`, `blocksClose ==
    /// true`): do nothing. These transitions resolve in a few seconds on their own; stowing mid-
    /// transition would risk building a hidden window around a state that's about to roll back (18章
    /// R2: "`.starting` 中にしまう → 開始失敗ロールバック → hidden な Draft" must be structurally
    /// impossible).
    case denyTransient

    /// - Parameters:
    ///   - isStowable: `RecordingButtonState.showsStowControls` -- `true` only for `.recording`/
    ///     `.paused`/`.pausedDisabledOtherRecording`.
    ///   - blocksClose: `RecordingButtonState.blocksWindowClose` -- `true` for every in-flight/
    ///     active-recording-or-paused state, a superset of `isStowable`.
    static func evaluate(isStowable: Bool, blocksClose: Bool) -> WindowCloseDecision {
        if isStowable { return .stowInsteadOfClose }
        if blocksClose { return .denyTransient }
        return .allowClose
    }
}

// MARK: - MeetingEndReshowDecision

/// Pure decision table for R6's "reveal the window when the meeting ends"
/// (`docs/design/18-recording-window-stow-and-compact.md` §2/§5.1), factored out of the
/// `viewModel.onMeetingEnded` closure wired in `MeetingWorkspaceWindowController.init` so the
/// judgment is unit-testable without driving `WindowManager.shared` (a hard-wired singleton with no
/// test seam, same rationale `WindowCloseDecision`'s doc comment above gives for its own extraction).
enum MeetingEndReshowDecision: Equatable {
    /// `true` only when the window is still in compact-pill form at the moment `endMeeting()` reached
    /// this point -- that window is already on screen, so expanding it back to normal size changes no
    /// visibility and steals no focus.
    ///
    /// A normally-displayed, non-compact window is left alone (`false`): it was already visible with
    /// its full chrome, so there is nothing to reveal -- `endMeeting()` (from the header's `⏹`, or
    /// the menu bar's confirmed "会議を終了…", §3.3) runs exactly the same either way, this decision
    /// just answers whether a visibility/mode change needs to happen alongside it.
    ///
    /// A **stowed** window is also left alone, deliberately -- hence `isStowed` being an input this
    /// function reads but never ORs in. R6 originally reshowed it too ("しまったまま終了してもサマリが
    /// 見える"), but the reveal lands whenever the confirmation processing happens to finish, which is
    /// tens of seconds after the user pressed 会議終了 and moved on to something else; the Session
    /// Window is a `.floating`-level `canBecomeKey` panel, so it jumps in front of every other app and
    /// takes keyboard focus at an arbitrary moment. A window the user explicitly put away stays away:
    /// the summary is still there whenever they reopen it from the menu bar or the Session List.
    static func shouldReshow(isStowed: Bool, isCompact: Bool) -> Bool {
        guard !isStowed else { return false }
        return isCompact
    }
}
