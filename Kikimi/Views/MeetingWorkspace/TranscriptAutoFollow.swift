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
