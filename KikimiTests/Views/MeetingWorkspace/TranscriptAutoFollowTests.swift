import Testing

@testable import Kikimi

/// Covers the auto-follow decisions the Transcript pane's scrolling depends on
/// (`Kikimi/Views/MeetingWorkspace/TranscriptAutoFollow.swift`, kikimi.md 10 章
/// "自動追従スクロール（上スクロールで一時停止）").
@Suite("TranscriptAutoFollow")
struct TranscriptAutoFollowTests {
    @Test("while pinned to the bottom, every content change follows -- appends and in-place edits alike")
    func followsWhilePinned() {
        #expect(TranscriptAutoFollow.shouldFollow(isPinnedToBottom: true))
    }

    @Test("once the user has scrolled away, no content change scrolls the viewport back")
    func doesNotFollowWhileUnpinned() {
        #expect(!TranscriptAutoFollow.shouldFollow(isPinnedToBottom: false))
    }

    @Test("the bottom anchor disappearing while the user is idle unpins auto-follow")
    func unpinsOnUserScrollAway() {
        #expect(TranscriptAutoFollow.shouldUnpin(isAutoScrolling: false))
    }

    @Test("the bottom anchor disappearing because an auto-scroll is relaying out does not unpin")
    func doesNotUnpinDuringAutoScroll() {
        // The regression this guards: unpinning here stops all further auto-scrolls, so the anchor
        // never reappears to re-pin via `onAppear` and the pane stops following for the rest of the
        // meeting.
        #expect(!TranscriptAutoFollow.shouldUnpin(isAutoScrolling: true))
    }

    @Test("the anchor stays suppressed for longer than an auto-scroll's own animation")
    func settleOutlastsAnimation() {
        #expect(TranscriptAutoFollow.autoScrollSettleDuration > TranscriptAutoFollow.scrollAnimationDuration)
    }
}
