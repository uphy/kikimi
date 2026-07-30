import SwiftUI

// MARK: - TranscriptRowContentView

/// One row of the transcript, rendered as a 2-line layout (`docs/design/17-session-window-redesign.md`
/// section 5.3.1): a header line (timestamp / speaker icon / speaker label / play button) followed by
/// a full-width text line. See also `docs/design/06-ui-panels.md` section 6.3 and
/// `docs/design/13-speaker-diarization.md` section 6.1 (the speaker-label column and its rename
/// popover).
///
/// Split out of `TranscriptTabView.swift` (`file_length` lint) for the same reason
/// `TranscriptVolatileRowContentView.swift` was, and internal rather than `private` only because of
/// that split: `TranscriptTabView` is still the sole caller.
struct TranscriptRowContentView: View {
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
    /// Copies this row's Markdown line (`docs/design/37-transcript-markdown-copy.md` §3.3/§4.4).
    /// Mirrors `MeetingWorkspaceViewModel.copyRowMarkdown(rowId:)`.
    let onCopyRow: (TranscriptRowViewModel) -> Void
    /// `TranscriptTabView.copyFeedbackRowId` verbatim -- `== row.id` only once the copy of *this* row
    /// has actually succeeded (§6/TC11(f)).
    let copyFeedbackRowId: String?

    /// `true` while this row is the one the most recent seg-id jump targeted
    /// (`docs/design/05-watcher-runner.md` §10.4). Renders a persistent 3pt leading accent bar. Kept
    /// separate from `isJumpFlashing` because the two have different lifetimes: the bar lasts until the
    /// next jump, the flash for `TranscriptAutoFollow.jumpFlashHoldDuration`.
    var isJumpTarget: Bool = false

    /// `true` for the couple of seconds right after a jump lands on this row (§10.4): fills the row's
    /// background. The row itself owns no timer -- `TranscriptTabView` flips this and animates the
    /// fade-out, so the flash is a cut on and a fade off.
    var isJumpFlashing: Bool = false

    /// Drives the playback button's visibility (`docs/design/15-segment-playback.md` section 6:
    /// visible on hover or while playing; always reserves its layout width so rows don't shift).
    @State private var isHovered = false

    /// `true` while `copyFeedbackRowId == row.id` (`docs/design/37-transcript-markdown-copy.md`
    /// TC11): swaps `copyButton`'s icon to `checkmark` as copy-success feedback, then reverts after
    /// 1.5s. Driven by `copyFeedbackRowId` (set by the ViewModel only after a *successful* pasteboard
    /// write, `.task(id:)` below) rather than firing unconditionally on tap, so a failed write
    /// correctly shows no feedback (§6) -- mirrors `MeetingTabView.showsCopyFeedback`'s exact pattern
    /// for the toolbar button.
    @State private var showsCopyFeedback = false

    /// The arrival flash's background strength (§10.4). Around macOS's own list-selection alpha: enough
    /// to read as a filled row at a glance, not enough to fight the body text's contrast.
    private static let jumpFlashOpacity: Double = 0.18

    /// Cut on, fade off (§10.4). Resolved from the *new* value of `isJumpFlashing`, which is what makes
    /// the asymmetry expressible in a single `.animation(_:value:)`: turning on supplies no animation,
    /// turning off supplies the fade.
    ///
    /// Deliberately *not* gated on `accessibilityReduceMotion`, unlike the jump's scroll animation: a
    /// cross-fade is what Apple's own guidance prescribes as the **substitute** for motion when that
    /// setting is on, not something the setting asks you to remove. Gating it here is what made the
    /// flash cut out on a machine with "視差効果を減らす" enabled.
    private var jumpFlashAnimation: Animation? {
        guard !isJumpFlashing else { return nil }
        return .easeOut(duration: TranscriptAutoFollow.jumpFlashFadeDuration)
    }

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
        .padding(.leading, 6)
        // §10.4's jump marker. The row background is the one visual channel nothing else uses (playback
        // is an icon tint, copy feedback an icon swap, the speaker label its own color, raw/refined the
        // body text color), so it carries this without any of them becoming ambiguous. The bar is a
        // shape cue, not a second color cue: it reads without relying on hue discrimination.
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor)
                // `.opacity(_:)` rather than folding the alpha into the `fill` color, and a local
                // `.animation(_:value:)` rather than the caller's `withAnimation`: a `ShapeStyle`
                // passed to `fill(_:)` is not animatable data, so a color-to-color change cuts
                // instantly no matter what transaction wraps it. Opacity is.
                .opacity(isJumpFlashing ? Self.jumpFlashOpacity : 0)
                .animation(jumpFlashAnimation, value: isJumpFlashing)
        }
        .overlay(alignment: .leading) {
            if isJumpTarget {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3)
            }
        }
        // onHover is hit-test-shape based, so cover the whole 2-line row rect -- otherwise hover drops
        // out over inter-column spacing and the opacity-0 button itself, making the button vanish
        // right as the pointer reaches it.
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .task(id: copyFeedbackRowId) {
            guard copyFeedbackRowId == row.id else {
                showsCopyFeedback = false
                return
            }
            showsCopyFeedback = true
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            showsCopyFeedback = false
        }
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

            copyButton
            playbackButton
        }
    }

    /// This row's Markdown-line copy button (`docs/design/37-transcript-markdown-copy.md` §3.3),
    /// placed to the left of `playbackButton` and following the exact same visibility/sizing
    /// convention: fixed width and always laid out (just invisible when idle/unhovered/no feedback
    /// pending) so its appearance never shifts neighboring rows.
    private var copyButton: some View {
        Button {
            onCopyRow(row)
        } label: {
            Image(systemName: showsCopyFeedback ? "checkmark" : "doc.on.doc")
                .font(.body)
                .foregroundStyle(showsCopyFeedback ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .frame(width: 20)
        .opacity(isHovered || showsCopyFeedback ? 1 : 0)
        .help("この発言をコピー")
        .accessibilityLabel("この発言をコピー")
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

    /// Internal rather than `private` so `TranscriptTabView` can speak the same "HH:MM:SS" a row shows
    /// in its jump-arrival VoiceOver announcement (§10.4).
    static func formattedTimestamp(startMs: Int) -> String {
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
