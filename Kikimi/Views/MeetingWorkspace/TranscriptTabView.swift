import SwiftUI

// MARK: - RenameableSlot

/// One slot a row's rename popover can act on (`docs/design/13-speaker-diarization.md` section 6.1):
/// `title` is the slot's current on-screen display ("田中さん"/"Speaker 3") so the user can tell the
/// fields of an "A + B" mixed row apart, `currentName` its assigned display name if any (drives the
/// field's prefill and whether "解除" is enabled). `embedding` is this slot's own captured
/// `SlotAssignment.embedding` (design section 4.3, `nil` until voiceprint extraction succeeds) --
/// `RenameSpeakerPopoverView`'s known-speaker picker feeds it to `KnownSpeakerSort.sorted(speakers:
/// slotEmbedding:)` so the picker for *this* slot is ordered by voice similarity to *this* slot, not
/// some other slot's in the same "A + B" mixed row. `assignedBy` is this slot's own
/// `SlotAssignment.assignedBy` (design section 4.3) -- `SpeakerLabelColumnView` uses the first (primary)
/// slot's value to decide whether the popover's "この発言だけ" section shows the auto-mismatch hint
/// (`docs/design/20-voiceprint-misassignment-mitigation.md` section 6.3).
struct RenameableSlot: Equatable, Identifiable {
    let slot: String
    let title: String
    let currentName: String?
    let embedding: [Float]?
    let assignedBy: SlotAssignmentSource?
    var id: String { slot }
}

// MARK: - TranscriptTabView

/// Session Window "Transcript" tab (`docs/design/06-ui-panels.md` section 6.3, kikimi.md 10 章
/// "セグメントリスト（時系列）"). Renders `rows` as a time-ordered list of
/// `HH:MM:SS` / speaker icon / speaker label / text rows, and implements the tab's auto-follow
/// scrolling. The speaker-label column (`speakerLabels`/`selfName`/`resolveSlot`/`onRenameSlot`) is
/// `docs/design/13-speaker-diarization.md` section 6.1's staged display and rename popover.
///
/// `rows` is expected to already be maintained in `start_ms` order by the caller via
/// `TranscriptRowList.inserted(_:into:)` — this view does not re-sort. It is a value-type,
/// side-effect-free-on-input view: the only state it owns locally is the auto-follow flag
/// (`isPinnedToBottom`), which section 6.3 explicitly calls out as "UI 側の状態変数" rather than
/// something `MeetingWorkspaceViewModel` needs to track.
struct TranscriptTabView: View {
    var rows: [TranscriptRowViewModel]

    /// In-progress (unconfirmed) transcript text for each source (`docs/design/11-streaming-stt.md`
    /// section 3.6). An empty string means "nothing pending for this source right now" and renders no
    /// row at all -- so this view shows at most 2 extra lines (mic / system), and often 0 or 1.
    var micVolatileText: String = ""
    var systemVolatileText: String = ""

    /// Streaming-confirmed text whose row has not arrived yet, per source
    /// (`MeetingWorkspaceViewModel.micConfirmingText`/`systemConfirmingText`). Rendered as the head
    /// of the same trailing line as the volatile text above, which is what keeps that line on screen
    /// across the two-pass re-decode instead of blinking out between confirmation and row arrival.
    var micConfirmingText: String = ""
    var systemConfirmingText: String = ""

    /// Per-row speaker label (`docs/design/13-speaker-diarization.md` section 6.1), keyed by
    /// `TranscriptRowViewModel.id` -- `MeetingWorkspaceViewModel.speakerLabels` verbatim. Only ever
    /// populated for `system` rows (`mic` uses `selfName` below regardless of this dictionary, design
    /// section 4.5); a missing entry for a `system` row renders the pre-diarization "system" label
    /// (`ResolvedSpeakerLabel.systemFallback`, the same fallback the dictionary itself uses while
    /// `diarization.enabled == false`).
    var speakerLabels: [String: ResolvedSpeakerLabel] = [:]

    /// Every currently-registered global speaker (`docs/design/13-speaker-diarization.md` section
    /// 4.4/6.1's rename popover picker, "R2"), verbatim from `MeetingWorkspaceViewModel
    /// .knownVoiceprintSpeakers`. Empty renders the popover with only the free-text field (no picker
    /// section) -- not distinguishable from "diarization disabled"/"no speakers registered yet" here,
    /// both render the same way.
    var knownSpeakers: [VoiceprintSpeaker] = []

    /// `AppConfig.shared.data.diarization.selfName` (design section 4.5): the label every `mic` row
    /// renders, independent of `speakerLabels`/`diarization.enabled` -- mic is never diarized, so this
    /// is a plain config value, not a derived one.
    var selfName: String = "自分"

    /// Resolves every `speaker_assignments.json` slot (design section 4.3) a `system` row's rename
    /// popover should offer a slot-wide field for: one for a `.single`/`.anonymous`/`.named` row, two
    /// for an "A + B" `.mixed` row (both speakers renameable from the same popover), empty for
    /// `.systemFallback`/`.recognizing`/`.unknown` (no slot to act on -- only "この発言だけ" applies).
    /// `mic` rows are never passed here (`SpeakerLabelColumnView` only calls this for `.system`).
    var renameTargets: (TranscriptRowViewModel) -> [RenameableSlot] = { _ in [] }

    /// Persists a rename (design section 6.1's popover): `submission: nil` clears the assignment back
    /// to anonymous ("解除"; the caller is responsible for mapping an empty draft string to `nil`
    /// before invoking this). A non-`nil` submission distinguishes "new name typed" from "existing
    /// speaker picked" (design section 4.4) so the enrollment decision can be made correctly. Mirrors
    /// `MeetingWorkspaceViewModel.applyRename(slot:submission:)` exactly so `MeetingWorkspaceView` can
    /// pass that method directly.
    var onRenameSlot: (_ slot: String, _ submission: SpeakerRenameSubmission?) async -> Void = { _, _ in }

    /// Persists a single-row override ("この発言だけ変更", design section 6.1): names exactly one
    /// segment without touching its slot's assignment, and works even for rows with no slot at all
    /// ("Speaker ?"/"(認識中…)"). `submission: nil` removes the override, restoring the slot-derived
    /// label; a non-`nil` submission distinguishes "existing speaker picked" from "new name typed" the
    /// same way `onRenameSlot` does (`docs/design/20-voiceprint-misassignment-mitigation.md` section
    /// 5.2). Mirrors `MeetingWorkspaceViewModel.overrideSegmentSpeaker(segmentId:submission:)`.
    var onOverrideSegment: (_ segmentId: String, _ submission: SpeakerRenameSubmission?) async -> Void = { _, _ in }

    /// `MeetingWorkspaceViewModel.playingSegmentId` verbatim (`docs/design/15-segment-playback.md`
    /// section 6): the `TranscriptRowViewModel.id` currently playing back, `nil` when idle. Drives
    /// which row's button renders as "stop" instead of "play".
    var playingRowId: String?

    /// Play/stop toggle for one row's audio (`docs/design/15-segment-playback.md`). Mirrors
    /// `MeetingWorkspaceViewModel.toggleSegmentPlayback(_:)` exactly so `MeetingWorkspaceView` can
    /// pass that method directly.
    var onTogglePlayback: (TranscriptRowViewModel) -> Void = { _ in }

    /// Copies one row's Markdown line (`docs/design/37-transcript-markdown-copy.md` §3.3/§4.4).
    /// Mirrors `MeetingWorkspaceViewModel.copyRowMarkdown(rowId:)` exactly so `MeetingWorkspaceView`
    /// can pass that method directly, the same convention as `onTogglePlayback`. This view has no
    /// compile-time dependency on the view model (top of file), so it only forwards the tap upward
    /// rather than rendering Markdown or touching the pasteboard itself.
    var onCopyRow: (TranscriptRowViewModel) -> Void = { _ in }

    /// `MeetingWorkspaceViewModel.copyFeedbackRowId` verbatim (`docs/design/37-transcript-markdown-copy.md`
    /// §3.3/§6/TC11(f)): the id of the row whose copy most recently *succeeded*, `nil` after a toolbar
    /// copy or on startup. Driving the row's checkmark from this (rather than firing it unconditionally
    /// on tap) is what makes a failed pasteboard write correctly show no feedback -- mirrors
    /// `MeetingTabView.copyFeedbackToken`'s exact pattern for the toolbar button. A plain `String?`
    /// value parameter, so this keeps the same "no compile-time ViewModel dependency" contract as
    /// `playingRowId` above, not a new one.
    var copyFeedbackRowId: String?

    /// A pending "scroll to this segment" request (`docs/design/05-watcher-runner.md` §10.4), verbatim
    /// from `MeetingWorkspaceViewModel.pendingTranscriptScrollTarget` -- set by a Watchers-tab seg-id
    /// link click. `MeetingWorkspaceView` passes this as a plain parameter (not a `Binding`) since this
    /// view has no compile-time dependency on the view model: it only needs to *consume* the request
    /// once handled, via `onScrollTargetConsumed` below.
    var scrollTarget: String?

    /// Invoked immediately after handling (or giving up on) a non-`nil` `scrollTarget`, so the caller
    /// can clear `pendingTranscriptScrollTarget` back to `nil` -- otherwise the same id would never be
    /// jump-able to a second time (SwiftUI's `.onChange` only fires on an actual value change).
    var onScrollTargetConsumed: () -> Void = {}

    /// The segment the most recent seg-id jump targeted (§10.4), verbatim from
    /// `MeetingWorkspaceViewModel.jumpHighlightedSegmentId`. That row renders a leading accent bar for
    /// as long as this stays set, answering "which row was the cited one?" long after the arrival flash
    /// has faded. A `.mergedInto` covered id is resolved to its leader before matching, so the marker
    /// lands on the row that actually renders the text.
    var highlightedSegmentId: String?

    /// "上スクロールで一時停止" (kikimi.md 10 章): `true` while the view should keep following newly
    /// inserted rows; becomes `false` the moment the user scrolls away from the bottom, and returns
    /// to `true` once they scroll back down. Starts `true` so a freshly opened tab follows along.
    @State private var isPinnedToBottom = true

    /// `true` from the moment an auto-scroll is issued until shortly after its animation would have
    /// finished. Guards the bottom anchor's `onDisappear` (see `TranscriptAutoFollow.shouldUnpin`):
    /// appending a row re-lays out the stack and can briefly pull the anchor out of `LazyVStack`'s
    /// realized region *because of* the very scroll that is chasing it, which used to unpin
    /// auto-follow permanently -- once unpinned, nothing scrolls, so the anchor never reappears to
    /// re-pin it, and the tab silently stopped following mid-meeting.
    @State private var isAutoScrolling = false

    /// The row currently showing a jump's arrival flash (the filled background), or `nil` between
    /// jumps. View-local rather than view-model state, unlike `highlightedSegmentId`: it belongs to one
    /// arrival, so losing it when SwiftUI re-creates this subtree is correct -- returning to the 会議 tab
    /// should not replay a flash for a jump that happened minutes ago.
    @State private var flashingRowId: String?

    /// `docs/design/05-watcher-runner.md` §10.4: with "動きを減らす" on, a jump cuts to its destination
    /// instead of animating the scroll. Scoped to the scroll on purpose -- the arrival flash's fade is a
    /// cross-fade, which that setting asks for rather than asks you to drop (see
    /// `TranscriptRowContentView.jumpFlashAnimation`).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where a seg-id jump parks the target row: a third of the way down rather than dead centre. A
    /// long row (one grown by refinement, or a merged unit covering several segments) is tall enough
    /// that centring its *middle* pushes the header line -- the timestamp and speaker name, which is
    /// exactly what a reader arriving from a Watcher citation looks at first -- off the top edge.
    private static let jumpAnchor = UnitPoint(x: 0.5, y: 0.33)

    /// Zero-height marker appended after the last row. Its `onAppear`/`onDisappear` firing is used
    /// as a proxy for "is the bottom of the list currently visible", since `LazyVStack` only
    /// realizes views inside (or near) the scroll view's visible region. This avoids depending on
    /// `onScrollGeometryChange`, which requires macOS 15 (this target is macOS 14, `Package.swift`).
    private static let bottomAnchorID = "TranscriptTabView.bottomAnchor"

    var body: some View {
        // Resolved once per body evaluation, never inside `ForEach`: `resolvedScrollTargetId(_:)` scans
        // `rows`, so doing it per row would make every render O(rows²) on a list that reaches four
        // digits in a long meeting -- the same shape as the diarization recomputation that used to pin
        // the CPU (see `MeetingWorkspaceView.transcriptTabView`'s note).
        let markedRowId = highlightedSegmentId.map(resolvedScrollTargetId)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if rows.isEmpty && !hasTrailingLine {
                        emptyPlaceholder
                    } else {
                        // Rows refinement dropped as meaningless (refined_text == "") are hidden
                        // entirely instead of rendering as blank lines (kikimi.md 7 章の整形ルール).
                        // Rows folded into an earlier leader row by the merge gate (§15.2.6) are
                        // likewise skipped -- their content is already shown on the leader row.
                        ForEach(rows.filter { !$0.state.isDroppedByRefinement && !$0.state.isMergedAway }) { row in
                            TranscriptRowContentView(
                                row: row,
                                resolvedLabel: speakerLabels[row.id],
                                selfName: selfName,
                                knownSpeakers: knownSpeakers,
                                renameTargets: renameTargets,
                                onRenameSlot: onRenameSlot,
                                onOverrideSegment: onOverrideSegment,
                                isPlaying: playingRowId == row.id,
                                onTogglePlayback: { onTogglePlayback(row) },
                                onCopyRow: onCopyRow,
                                copyFeedbackRowId: copyFeedbackRowId,
                                isJumpTarget: markedRowId == row.id,
                                isJumpFlashing: flashingRowId == row.id
                            )
                            .id(row.id)
                        }
                        volatileRows
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                        .onAppear { isPinnedToBottom = true }
                        .onDisappear {
                            guard TranscriptAutoFollow.shouldUnpin(isAutoScrolling: isAutoScrolling) else { return }
                            isPinnedToBottom = false
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                // Backfilled rows (`sessionHandle.readTranscriptSegments()`, section 6.3 "初期表示")
                // arrive as the view's very first `rows` value, before any `onChange` fires, so the
                // initial follow-to-bottom has to happen here rather than in `onChange`.
                //
                // A jump request that was already pending at creation time takes precedence over it
                // -- see `TranscriptAutoFollow.initialScroll(scrollTarget:)` for why that is the
                // *normal* path for a seg-id link, not an edge case.
                switch TranscriptAutoFollow.initialScroll(scrollTarget: scrollTarget) {
                case .jump(let segId):
                    // Falls back to the normal follow-to-bottom when the request can't be honoured
                    // (`MeetingWorkspaceViewModel.jumpToTranscriptSegment(_:)` only checks that the id
                    // is *in* `transcriptRows`, so a refinement-dropped row still reaches here) --
                    // otherwise the pane would open at the very top of the meeting.
                    if !jumpToScrollTarget(segId, proxy: proxy, animated: false) {
                        scrollToBottom(proxy: proxy, animated: false)
                    }
                case .followBottom:
                    scrollToBottom(proxy: proxy, animated: false)
                }
            }
            .onChange(of: rows) { _, _ in
                scrollToBottomIfPinned(proxy: proxy)
            }
            .onChange(of: micVolatileText) { _, _ in
                scrollToBottomIfPinned(proxy: proxy)
            }
            .onChange(of: systemVolatileText) { _, _ in
                scrollToBottomIfPinned(proxy: proxy)
            }
            .onChange(of: micConfirmingText) { _, _ in
                scrollToBottomIfPinned(proxy: proxy)
            }
            .onChange(of: systemConfirmingText) { _, _ in
                scrollToBottomIfPinned(proxy: proxy)
            }
            .onChange(of: scrollTarget) { _, newTarget in
                handleScrollTargetChange(newTarget, proxy: proxy)
            }
            // Re-armed by every arrival (`flashingRowId` changes), so a second jump restarts the hold
            // instead of inheriting the previous one's remaining time.
            .task(id: flashingRowId) {
                guard flashingRowId != nil else { return }
                try? await Task.sleep(for: .seconds(TranscriptAutoFollow.jumpFlashHoldDuration))
                guard !Task.isCancelled else { return }
                // A plain write: the fade is declared by the row itself
                // (`TranscriptRowContentView.jumpFlashAnimation`), not by a transaction here -- see that
                // property for why wrapping this in `withAnimation` did not animate anything.
                flashingRowId = nil
            }
        }
    }

    /// Handles a `scrollTarget` change (§10.4) for an already-visible pane. The pane being re-created
    /// *with* the request already set is the other (and more common) entry point -- see `onAppear`.
    private func handleScrollTargetChange(_ segId: String?, proxy: ScrollViewProxy) {
        guard let segId else { return }
        jumpToScrollTarget(segId, proxy: proxy, animated: true)
    }

    /// Scrolls to `segId` if it (after resolving a possible `.mergedInto` covered id to its leader,
    /// §15.2.6) names a currently-rendered row (excluding refinement-dropped rows, which are filtered
    /// out of `body`'s `ForEach` entirely and so can never be a valid `proxy.scrollTo(_:)` target),
    /// then always consumes the request so the caller's pending state doesn't get stuck non-`nil`
    /// forever -- both on a successful jump and on a silently-ignored unresolvable id. Returns whether
    /// a scroll was actually issued, so the `onAppear` caller can fall back to following the bottom.
    @discardableResult
    private func jumpToScrollTarget(_ segId: String, proxy: ScrollViewProxy, animated: Bool) -> Bool {
        defer { consumeScrollTarget() }
        let resolvedId = resolvedScrollTargetId(segId)
        guard rows.contains(where: { $0.id == resolvedId && !$0.state.isDroppedByRefinement && !$0.state.isMergedAway }) else {
            return false
        }
        // Auto-follow is released explicitly rather than relying on the bottom anchor's `onDisappear`
        // (§10.4's "暗黙に解除される（既存機構）"): that firing is suppressed for
        // `autoScrollSettleDuration` after `onAppear`'s own scroll, and it never happens at all when
        // the destination is close enough to the bottom for the anchor to stay realized. In both
        // cases the pane stayed pinned, so the very next volatile line (which arrives within a second
        // while recording) yanked the viewport straight back to the end.
        isPinnedToBottom = false
        // Lit as a cut, not a fade-in: the flash exists to be noticed at the moment the viewport
        // settles. `.task(id:)` above owns the fade-out.
        flashingRowId = resolvedId
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: TranscriptAutoFollow.scrollAnimationDuration)) {
                proxy.scrollTo(resolvedId, anchor: Self.jumpAnchor)
            }
        } else {
            proxy.scrollTo(resolvedId, anchor: Self.jumpAnchor)
        }
        // See `TranscriptAutoFollow.jumpCorrectionDelay`: one re-issue after the first pass has
        // realized the destination row, so a long jump through an unrealized `LazyVStack` region
        // doesn't land short.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(TranscriptAutoFollow.jumpCorrectionDelay))
            proxy.scrollTo(resolvedId, anchor: Self.jumpAnchor)
        }
        announceJumpArrival(rowId: resolvedId)
        return true
    }

    /// Tells VoiceOver where the jump landed -- the flash and the accent bar are both purely visual, and
    /// a scroll that moves the viewport without moving focus is otherwise silent. Deliberately an
    /// announcement rather than an `.isSelected` trait on the row: nothing has been selected, the view
    /// has moved.
    private func announceJumpArrival(rowId: String) {
        guard let row = rows.first(where: { $0.id == rowId }) else { return }
        let timestamp = TranscriptRowContentView.formattedTimestamp(startMs: row.startMs)
        AccessibilityNotification.Announcement("\(timestamp) の発言に移動しました").post()
    }

    /// Clears the pending request on the next runloop turn rather than inline: `jumpToScrollTarget`
    /// also runs from `onAppear`, i.e. inside SwiftUI's own update pass, and writing the observed
    /// view model's `@Published` there is what triggers the "Publishing changes from within view
    /// updates is not allowed" runtime warning.
    private func consumeScrollTarget() {
        Task { @MainActor in onScrollTargetConsumed() }
    }

    /// §15.2.6: a `.mergedInto(leaderId:)` row is never rendered itself, so a jump landing on one of
    /// its covered ids must resolve to the leader row that actually renders the merged text. Any
    /// other id (including one not present in `rows` at all) passes through unchanged.
    private func resolvedScrollTargetId(_ segId: String) -> String {
        guard let row = rows.first(where: { $0.id == segId }), case .mergedInto(let leaderId) = row.state else {
            return segId
        }
        return leaderId
    }

    private var emptyPlaceholder: some View {
        Text("まだ書き起こしがありません")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    /// The trailing "in-progress" lines (`docs/design/11-streaming-stt.md` section 3.6): at most one
    /// per source, dim + italic, distinct from the "生=薄グレー/整形済=通常色" palette used for
    /// confirmed rows (kikimi.md 10 章) so it reads unambiguously as "not yet a real row".
    /// `true` while either source has something to show below the confirmed rows -- pending text,
    /// text awaiting its row, or both. Drives the empty placeholder and the auto-follow guard, which
    /// both need "is anything at all on screen" rather than "is any row on screen".
    private var hasTrailingLine: Bool {
        !micVolatileText.isEmpty || !systemVolatileText.isEmpty
            || !micConfirmingText.isEmpty || !systemConfirmingText.isEmpty
    }

    @ViewBuilder
    private var volatileRows: some View {
        if !micConfirmingText.isEmpty || !micVolatileText.isEmpty {
            TranscriptVolatileRowContentView(
                source: .mic,
                confirmingText: micConfirmingText,
                text: micVolatileText
            )
            .id("TranscriptTabView.volatile.mic")
        }
        if !systemConfirmingText.isEmpty || !systemVolatileText.isEmpty {
            TranscriptVolatileRowContentView(
                source: .system,
                confirmingText: systemConfirmingText,
                text: systemVolatileText
            )
            .id("TranscriptTabView.volatile.system")
        }
    }

    /// Follows the bottom whenever the user hasn't scrolled away, for *any* change to `rows` --
    /// deliberately not just an append.
    ///
    /// This used to additionally require `oldRows.last?.id != newRows.last?.id` ("the change landed
    /// at the tail") so that a mid-list insertion — an out-of-order segment from the other audio
    /// stream arriving late (`docs/design/06-ui-panels.md` section 6.3 "実装上の注意") — wouldn't yank
    /// the viewport. But that guard also swallowed every *in-place* row mutation, and those are the
    /// common case while recording: refinement rewrites `.raw` → `.refined` text (usually longer, and
    /// often wrapping onto more lines) and the merge gate folds a row away entirely, both of which
    /// change the stack's height below the viewport without changing the tail row's id. The visible
    /// bottom then drifted further off-screen with every batch. While pinned to the bottom, following
    /// is the right answer for a mid-list insertion too: the user is at the end of the list, so the
    /// end of the list is what should stay on screen.
    private func scrollToBottomIfPinned(proxy: ScrollViewProxy) {
        guard TranscriptAutoFollow.shouldFollow(isPinnedToBottom: isPinnedToBottom) else { return }
        scrollToBottom(proxy: proxy, animated: true)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard !rows.isEmpty || hasTrailingLine else { return }
        // Held across the scroll so the anchor's own `onDisappear` can't mistake this scroll's
        // relayout for the user scrolling away (see `isAutoScrolling`).
        isAutoScrolling = true
        if animated {
            withAnimation(.easeOut(duration: TranscriptAutoFollow.scrollAnimationDuration)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(TranscriptAutoFollow.autoScrollSettleDuration))
            isAutoScrolling = false
        }
    }
}
