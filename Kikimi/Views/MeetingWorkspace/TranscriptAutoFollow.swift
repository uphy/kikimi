import Foundation

// MARK: - TranscriptAutoFollow

/// The two decisions behind the Transcript pane's auto-follow scrolling (kikimi.md 10 章
/// "自動追従スクロール（上スクロールで一時停止）"), factored out of `TranscriptTabView` so they are
/// unit-testable without instantiating a SwiftUI view -- the same pattern `CopyFeedbackFlash`
/// (`MeetingTabView.swift`) uses.
enum TranscriptAutoFollow {
    /// `withAnimation` duration for an auto-scroll.
    static let scrollAnimationDuration: Double = 0.2

    /// How long after issuing an auto-scroll the bottom anchor's `onDisappear` stays suppressed.
    /// Comfortably longer than `scrollAnimationDuration` so the relayout the scroll itself triggers
    /// is fully settled before the anchor is trusted again as a "user scrolled away" signal.
    static let autoScrollSettleDuration: Double = 0.5

    /// How long after a seg-id jump (`docs/design/05-watcher-runner.md` §10.4) the same
    /// `proxy.scrollTo(_:)` is re-issued once. `LazyVStack` has only realized the rows around the
    /// current viewport, and a scroll toward a row outside that window lands short -- §10.4's own
    /// caveat ("未実体化行への `scrollTo` は不発になり得る"). Re-issuing after the first pass has
    /// realized the destination corrects that; on an already-centered row it is a visual no-op.
    /// Longer than `scrollAnimationDuration` so the correction reads the settled position, not a
    /// mid-animation one.
    static let jumpCorrectionDelay: Double = 0.3

    /// How long a jump's arrival flash (the row's filled background) stays at full strength before
    /// fading. Long enough to survive the jump's own scroll animation plus `jumpCorrectionDelay`, so
    /// the reader sees it *after* the viewport has settled, and short enough not to linger as a
    /// pseudo-selection -- the leading accent bar is what persists (`MeetingWorkspaceViewModel
    /// .jumpHighlightedSegmentId`).
    static let jumpFlashHoldDuration: Double = 1.8

    /// The arrival flash's fade-out. Only the fade is animated: the flash appears instantly (the whole
    /// point is to catch the eye at the moment the scroll lands), so `TranscriptTabView` turns it on
    /// outside `withAnimation` and off inside it.
    static let jumpFlashFadeDuration: Double = 0.7

    /// What the Transcript pane should do on its very first layout pass.
    enum InitialScroll: Equatable {
        /// Honour a jump request that was already pending when the pane was created.
        case jump(segId: String)
        /// The normal case: show the newest rows (`TranscriptTabView.onAppear`'s backfill follow).
        case followBottom
    }

    /// Whether the pane's first layout should honour a pending `scrollTarget` instead of following
    /// the bottom.
    ///
    /// A seg-id link only exists on the Watchers/Chat tab, so clicking one always switches the 会議
    /// tab in (and may widen a サマリのみ pane back to `.both`) -- and SwiftUI re-creates those
    /// subtrees from scratch (`docs/design/39-webview-markdown.md` MD2). The pane's *first*
    /// `scrollTarget` value is therefore already the requested id, and `.onChange(of: scrollTarget)`
    /// -- which §10.4 originally specified as the only entry point -- never fires for it. Every jump
    /// then fell through to `onAppear`'s follow-to-bottom, which is exactly the reported symptom:
    /// "クリックしても対象の segment に飛べず、常に書き起こしの末尾に移動する".
    static func initialScroll(scrollTarget: String?) -> InitialScroll {
        guard let scrollTarget, !scrollTarget.isEmpty else { return .followBottom }
        return .jump(segId: scrollTarget)
    }

    /// Whether a content change should scroll to the bottom. The pin flag is the only input: while
    /// pinned, every change follows (see `TranscriptTabView.scrollToBottomIfPinned` for why an
    /// "is this an append?" test is deliberately absent).
    static func shouldFollow(isPinnedToBottom: Bool) -> Bool {
        isPinnedToBottom
    }

    /// Whether the bottom anchor leaving the realized region means the *user* scrolled away.
    ///
    /// `LazyVStack` unrealizes views that fall outside (or near) the visible region, so the anchor's
    /// `onDisappear` also fires as a side effect of an auto-scroll's own relayout. Acting on that
    /// firing is self-defeating: unpinning stops all further auto-scrolls, so the anchor never comes
    /// back into view to re-pin via `onAppear`, and auto-follow is off for the rest of the meeting
    /// with no way back except scrolling by hand. Firings during an in-flight auto-scroll are
    /// therefore ignored.
    static func shouldUnpin(isAutoScrolling: Bool) -> Bool {
        !isAutoScrolling
    }
}
