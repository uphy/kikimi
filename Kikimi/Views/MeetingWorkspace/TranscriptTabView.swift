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

    /// "上スクロールで一時停止" (kikimi.md 10 章): `true` while the view should keep following newly
    /// inserted rows; becomes `false` the moment the user scrolls away from the bottom, and returns
    /// to `true` once they scroll back down. Starts `true` so a freshly opened tab follows along.
    @State private var isPinnedToBottom = true

    /// Zero-height marker appended after the last row. Its `onAppear`/`onDisappear` firing is used
    /// as a proxy for "is the bottom of the list currently visible", since `LazyVStack` only
    /// realizes views inside (or near) the scroll view's visible region. This avoids depending on
    /// `onScrollGeometryChange`, which requires macOS 15 (this target is macOS 14, `Package.swift`).
    private static let bottomAnchorID = "TranscriptTabView.bottomAnchor"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if rows.isEmpty && micVolatileText.isEmpty && systemVolatileText.isEmpty {
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
                                onTogglePlayback: { onTogglePlayback(row) }
                            )
                            .id(row.id)
                        }
                        volatileRows
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                        .onAppear { isPinnedToBottom = true }
                        .onDisappear { isPinnedToBottom = false }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                // Backfilled rows (`sessionHandle.readTranscriptSegments()`, section 6.3 "初期表示")
                // arrive as the view's very first `rows` value, before any `onChange` fires, so the
                // initial follow-to-bottom has to happen here rather than in `onChange`.
                scrollToBottom(proxy: proxy, animated: false)
            }
            .onChange(of: rows) { oldRows, newRows in
                handleRowsChange(oldRows: oldRows, newRows: newRows, proxy: proxy)
            }
            .onChange(of: micVolatileText) { _, _ in
                scrollToBottomIfPinned(proxy: proxy)
            }
            .onChange(of: systemVolatileText) { _, _ in
                scrollToBottomIfPinned(proxy: proxy)
            }
            .onChange(of: scrollTarget) { _, newTarget in
                handleScrollTargetChange(newTarget, proxy: proxy)
            }
        }
    }

    /// Handles a `scrollTarget` change (§10.4): scrolls to `segId` if it (after resolving a possible
    /// `.mergedInto` covered id to its leader, §15.2.6) names a currently-rendered row (excluding
    /// refinement-dropped rows, which are filtered out of `body`'s `ForEach` entirely and so can
    /// never be a valid `proxy.scrollTo(_:)` target), then always calls `onScrollTargetConsumed()` so
    /// the caller's pending-request state doesn't get stuck non-`nil` forever -- both on a successful
    /// jump and on a silently-ignored unresolvable id.
    private func handleScrollTargetChange(_ segId: String?, proxy: ScrollViewProxy) {
        guard let segId else { return }
        defer { onScrollTargetConsumed() }
        let resolvedId = resolvedScrollTargetId(segId)
        guard rows.contains(where: { $0.id == resolvedId && !$0.state.isDroppedByRefinement && !$0.state.isMergedAway }) else {
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(resolvedId, anchor: .center)
        }
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
    @ViewBuilder
    private var volatileRows: some View {
        if !micVolatileText.isEmpty {
            TranscriptVolatileRowContentView(source: .mic, text: micVolatileText)
                .id("TranscriptTabView.volatile.mic")
        }
        if !systemVolatileText.isEmpty {
            TranscriptVolatileRowContentView(source: .system, text: systemVolatileText)
                .id("TranscriptTabView.volatile.system")
        }
    }

    /// Auto-scrolls only when both hold:
    /// 1. `isPinnedToBottom` — the user hasn't scrolled away.
    /// 2. The newest change landed at the tail of `newRows` — i.e. `TranscriptRowList.inserted`'s
    ///    insertion position matched `rows.last?.id` at insertion time. A mid-list insertion (an
    ///    out-of-order segment from the other audio stream arriving late, section 6.3 "実装上の注意")
    ///    leaves the previous tail row's `id` unchanged as the new list's last element too, so
    ///    comparing `oldRows.last?.id` against `newRows.last?.id` distinguishes the two cases without
    ///    needing to re-derive the insertion index here.
    private func handleRowsChange(
        oldRows: [TranscriptRowViewModel],
        newRows: [TranscriptRowViewModel],
        proxy: ScrollViewProxy
    ) {
        guard isPinnedToBottom, newRows.last != nil else { return }
        guard oldRows.last?.id != newRows.last?.id else { return }
        scrollToBottom(proxy: proxy, animated: true)
    }

    /// Scrolls to the bottom anchor only if the user hasn't scrolled away -- used by the volatile-text
    /// `onChange` handlers, which (unlike `handleRowsChange`) have no "did this land at the tail"
    /// question to ask: `micVolatileText`/`systemVolatileText` are always rendered after every
    /// confirmed row, so any change to either is always a tail-of-list change.
    private func scrollToBottomIfPinned(proxy: ScrollViewProxy) {
        guard isPinnedToBottom else { return }
        scrollToBottom(proxy: proxy, animated: true)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard !rows.isEmpty || !micVolatileText.isEmpty || !systemVolatileText.isEmpty else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }
}

// MARK: - TranscriptRowContentView

/// One row of the transcript, rendered as a 2-line layout (`docs/design/17-session-window-redesign.md`
/// section 5.3.1): a header line (timestamp / speaker icon / speaker label / play button) followed by
/// a full-width text line. See also `docs/design/06-ui-panels.md` section 6.3 and
/// `docs/design/13-speaker-diarization.md` section 6.1 (the speaker-label column and its rename
/// popover).
private struct TranscriptRowContentView: View {
    let row: TranscriptRowViewModel
    /// `TranscriptTabView.speakerLabels[row.id]`; `nil` renders like `ResolvedSpeakerLabel
    /// .systemFallback` (design section 6.1: "diarization が無効・未稼働範囲のセグメントは従来どおり
    /// 「system」表示").
    let resolvedLabel: ResolvedSpeakerLabel?
    let selfName: String
    let knownSpeakers: [VoiceprintSpeaker]
    let renameTargets: (TranscriptRowViewModel) -> [RenameableSlot]
    let onRenameSlot: (_ slot: String, _ submission: SpeakerRenameSubmission?) async -> Void
    let onOverrideSegment: (_ segmentId: String, _ submission: SpeakerRenameSubmission?) async -> Void
    /// `true` when this row's audio is the one currently playing (`docs/design/15-segment-playback.md`
    /// section 6).
    let isPlaying: Bool
    /// Play/stop toggle for this row's audio. Mirrors `MeetingWorkspaceViewModel
    /// .toggleSegmentPlayback(_:)`.
    let onTogglePlayback: () -> Void

    /// Drives the playback button's visibility (`docs/design/15-segment-playback.md` section 6:
    /// visible on hover or while playing; always reserves its layout width so rows don't shift).
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            headerRow
            Text(displayText)
                .font(.body)
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        // onHover is hit-test-shape based, so cover the whole 2-line row rect -- otherwise hover drops
        // out over inter-column spacing and the opacity-0 button itself, making the button vanish
        // right as the pointer reaches it.
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    /// The header line: timestamp + speaker icon + speaker label (natural width, design section 5.3.1
    /// drops the old fixed 100pt column) + play button pinned to the trailing edge via `Spacer()`.
    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.formattedTimestamp(startMs: row.startMs))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            Image(systemName: speakerSymbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityLabel(speakerAccessibilityLabel)

            SpeakerLabelColumnView(
                row: row,
                resolvedLabel: resolvedLabel,
                selfName: selfName,
                knownSpeakers: knownSpeakers,
                renameTargets: renameTargets,
                onRenameSlot: onRenameSlot,
                onOverrideSegment: onOverrideSegment
            )

            Spacer()

            playbackButton
        }
    }

    /// This row's audio playback toggle (`docs/design/15-segment-playback.md` section 6). Kept at a
    /// fixed width and always laid out (just invisible when idle/unhovered) so its appearance never
    /// shifts neighboring rows.
    private var playbackButton: some View {
        Button(action: onTogglePlayback) {
            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                .font(.body)
                .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .frame(width: 20)
        .opacity(isPlaying || isHovered ? 1 : 0)
        .help(isPlaying ? "再生を停止" : "この発言の音声を再生")
        .accessibilityLabel(isPlaying ? "再生を停止" : "この発言の音声を再生")
    }

    private var speakerSymbolName: String { row.speaker.sfSymbolName }

    private var speakerAccessibilityLabel: String { row.speaker.accessibilityLabel }

    /// The text to render for the current `TranscriptRowState`. Phase 1 only ever reaches `.raw`
    /// (`03-refinement-batch.md` doesn't exist yet), but the switch stays exhaustive so Phase 2's
    /// `.refining`/`.refined`/`.refinedFailed` wiring doesn't have to touch this view's layout.
    private var displayText: String {
        switch row.state {
        case .raw:
            return row.rawText
        case .refining:
            return "🔄 " + row.rawText
        case .refined(let refinedText):
            return refinedText
        case .refinedFailed:
            // Falls back to raw_text (kikimi.md 8.5 章: 整形失敗のセグメントは raw_text にフォールバック).
            return row.rawText
        case .mergedInto:
            // §15.2.6: unreachable in practice -- `TranscriptTabView.body`'s `ForEach` filters
            // `.mergedInto` rows out before a `TranscriptRowContentView` is ever built for one. Kept
            // only so this switch stays exhaustive.
            return row.rawText
        }
    }

    /// `.raw`/`.refining` render in light gray per kikimi.md 10 章 ("生書き起こしは薄いグレー、
    /// 整形完了で通常色"): `.refining` is still queued/pending, not yet refined, so it stays gray
    /// like `.raw` rather than jumping to normal color early. Only `.refined`/`.refinedFailed`
    /// (refinement actually attempted to completion, success or failure) render in normal color.
    private var textColor: Color {
        switch row.state {
        case .raw, .refining, .mergedInto:
            return .secondary
        case .refined, .refinedFailed:
            return .primary
        }
    }

    private static func formattedTimestamp(startMs: Int) -> String {
        // `startMs` is "milliseconds elapsed since session start" (kikimi.md 5 章), not a wall-clock
        // offset, so it's formatted directly rather than added to `meta.startedAt`
        // (`docs/design/06-ui-panels.md` section 6.3 "座標系の注意").
        let totalSeconds = max(0, startMs) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

// MARK: - SpeakerLabelColumnView

/// The speaker-label column of one confirmed row (`docs/design/13-speaker-diarization.md` section
/// 6.1). `mic` rows render `selfName` as plain, non-interactive text (design section 4.5: mic is
/// never diarized, so there is no slot to rename through). `system` rows render the staged label
/// ("(認識中…)" → "Speaker N" → 実名, plus the "A + B" mixed form and a trailing "⚠" overlap marker)
/// and, whenever `resolveSlot(row)` can name a slot to act on, become a button that opens the rename
/// popover.
private struct SpeakerLabelColumnView: View {
    let row: TranscriptRowViewModel
    let resolvedLabel: ResolvedSpeakerLabel?
    let selfName: String
    let knownSpeakers: [VoiceprintSpeaker]
    let renameTargets: (TranscriptRowViewModel) -> [RenameableSlot]
    let onRenameSlot: (_ slot: String, _ submission: SpeakerRenameSubmission?) async -> Void
    let onOverrideSegment: (_ segmentId: String, _ submission: SpeakerRenameSubmission?) async -> Void

    @State private var isPopoverPresented = false

    var body: some View {
        switch row.speaker {
        case .mic:
            // Design section 4.5: mic's label is a fixed config value, not a `speakerLabels` lookup --
            // there is no slot behind it to attribute or rename.
            Text(selfName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .system:
            systemLabel
        }
    }

    @ViewBuilder
    private var systemLabel: some View {
        // Always a button, slot or not (design section 6.1): "この発言だけ" (the per-segment override)
        // is available on every system row, including slotless "Speaker ?"/"(認識中…)" ones. The
        // slot-wide fields come one-per-attributed-slot -- two for an "A + B" mixed row, so both
        // speakers can be renamed from the same popover.
        let resolved = resolvedLabel ?? .systemFallback
        let targets = renameTargets(row)
        Button {
            isPopoverPresented = true
        } label: {
            Text(Self.labelText(for: resolved))
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(targets.isEmpty && !resolved.isSegmentOverride ? .tertiary : .secondary)
        .lineLimit(1)
        .help("クリックして話者名を変更")
        .popover(isPresented: $isPopoverPresented) {
            RenameSpeakerPopoverView(
                slots: targets,
                knownSpeakers: knownSpeakers,
                isSegmentOverride: resolved.isSegmentOverride,
                initialSegmentName: Self.overrideName(for: resolved),
                // Design section 6.3: hint only when the row's primary (first-attributed) slot is
                // still an unconfirmed `.auto` match -- a `.user` slot (explicit rename) or no slot at
                // all has nothing to hint at applying "すべての発言に適用" over.
                showsAutoHint: targets.first?.assignedBy == .auto,
                onSubmitSlot: { slot, submission in
                    isPopoverPresented = false
                    Task { await onRenameSlot(slot, submission) }
                },
                onSubmitSegment: { submission in
                    isPopoverPresented = false
                    Task { await onOverrideSegment(row.id, submission) }
                }
            )
        }
    }

    /// Design section 6.1's staged text, in the same order the design lists it: "(認識中…) → Speaker N
    /// → 実名", plus "Speaker ?" (section 5.3 rule 1's post-grace-period fallback), "A + B" mixed
    /// (section 5.3 rule 2), and a trailing "⚠" whenever `hasOverlapMarker` (section 5.3, "上記と直交
    /// する付加マーカー").
    private static func labelText(for resolved: ResolvedSpeakerLabel) -> String {
        var text: String
        switch resolved.label {
        case .systemFallback:
            text = "system"
        case .recognizing:
            text = "(認識中…)"
        case .unknown:
            text = "Speaker ?"
        case .anonymous(let slotNumber):
            text = "Speaker \(slotNumber)"
        case .named(let name):
            text = name
        case .mixed(let primary, let secondary):
            text = "\(primary) + \(secondary)"
        }
        if resolved.hasOverlapMarker {
            text += " ⚠"
        }
        return text
    }

    /// The "この発言だけ" field's initial draft: the active override's name when one is applied
    /// (so editing starts from the current value), otherwise empty.
    private static func overrideName(for resolved: ResolvedSpeakerLabel) -> String {
        guard resolved.isSegmentOverride, case .named(let name) = resolved.label else {
            return ""
        }
        return name
    }
}

// MARK: - TranscriptVolatileRowContentView

/// One in-progress (unconfirmed) source's trailing line (`docs/design/11-streaming-stt.md` section
/// 3.6), rendered in the same 2-line layout as `TranscriptRowContentView`
/// (`docs/design/17-session-window-redesign.md` section 5.3.1): a header line with the speaker icon
/// only (no timestamp -- this text has no confirmed `startMs`/`endMs` yet, it may still grow, shrink,
/// or be replaced entirely before ever becoming a real row) followed by a full-width dim/italic text
/// line.
private struct TranscriptVolatileRowContentView: View {
    let source: AudioSourceKind
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: source.sfSymbolName)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(source.accessibilityLabel)

            Text(text)
                .font(.body.italic())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.accessibilityLabel)、書き起こし中: \(text)")
    }
}

// MARK: - AudioSourceKind display helpers

/// Shared between `TranscriptRowContentView` (confirmed rows) and `TranscriptVolatileRowContentView`
/// (in-progress rows) so both render the same icon/label per source.
private extension AudioSourceKind {
    var sfSymbolName: String {
        switch self {
        case .mic:
            return "mic.fill"
        case .system:
            return "speaker.wave.2.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .mic:
            return "マイク"
        case .system:
            return "システム音声"
        }
    }
}
