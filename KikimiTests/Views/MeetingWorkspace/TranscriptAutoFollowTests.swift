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

    // MARK: - Initial scroll (`docs/design/05-watcher-runner.md` §10.4)

    @Test("a pane created with no pending jump follows the bottom, as before")
    func initialScrollFollowsBottomWithoutTarget() {
        #expect(TranscriptAutoFollow.initialScroll(scrollTarget: nil) == .followBottom)
    }

    @Test("a pane created with a pending jump honours it instead of following the bottom")
    func initialScrollHonoursPendingTarget() {
        // The regression this guards: a seg-id link click switches the 会議 tab in, SwiftUI re-creates
        // the pane, and `onChange(of: scrollTarget)` never fires for a value that was already set at
        // creation -- so every jump used to land on the follow-to-bottom instead of the segment.
        #expect(TranscriptAutoFollow.initialScroll(scrollTarget: "seg_00042") == .jump(segId: "seg_00042"))
    }

    @Test("an empty target is not a jump request")
    func initialScrollIgnoresEmptyTarget() {
        #expect(TranscriptAutoFollow.initialScroll(scrollTarget: "") == .followBottom)
    }

    @Test("the jump correction outlasts the jump's own animation")
    func jumpCorrectionOutlastsAnimation() {
        #expect(TranscriptAutoFollow.jumpCorrectionDelay > TranscriptAutoFollow.scrollAnimationDuration)
    }

    @Test("the arrival flash is still at full strength once the scroll and its correction have settled")
    func flashOutlastsScrollSettling() {
        // Otherwise the flash would be fading (or gone) at the moment the viewport finally stops
        // moving, i.e. exactly when the reader starts looking -- which is the whole point of it.
        #expect(
            TranscriptAutoFollow.jumpFlashHoldDuration
                > TranscriptAutoFollow.scrollAnimationDuration + TranscriptAutoFollow.jumpCorrectionDelay
        )
    }

    @Test("the flash fades rather than cutting out, but does not linger as a pseudo-selection")
    func flashFadeIsShorterThanItsHold() {
        #expect(TranscriptAutoFollow.jumpFlashFadeDuration > 0)
        #expect(TranscriptAutoFollow.jumpFlashFadeDuration < TranscriptAutoFollow.jumpFlashHoldDuration)
    }
}
