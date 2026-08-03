import SwiftUI

// MARK: - RenameSpeakerPopoverView

/// Design section 6.1's rename popover: free-text input plus, per slot, a known-speaker picker sourced
/// from the global voiceprint DB (design section 4.4/6.1, "R2"). One "すべての発言に適用" field group per
/// attributed slot -- an "A + B" mixed row gets two, so both speakers can be renamed from the same
/// popover -- plus the per-segment "この発言だけ" override (design section 4.3's `segment_overrides`)
/// that names exactly this row, slot or no slot.
///
/// Split out of `TranscriptTabView.swift` (which owns `SpeakerLabelColumnView`, the sole call site,
/// via its `.popover(isPresented:)`) to keep that file under the project's `file_length` lint limit --
/// same rationale as `AudioInputPopover.swift` living in its own file rather than inside whatever view
/// presents it. Not `private`, unlike `SlotRenameFieldView`/`SegmentOverrideFieldView` below (which are
/// only ever used from within this file): `SpeakerLabelColumnView` constructs this type directly.
struct RenameSpeakerPopoverView: View {
    let slots: [RenameableSlot]
    let knownSpeakers: [VoiceprintSpeaker]
    let isSegmentOverride: Bool
    let initialSegmentName: String
    /// Whether to show the "この発言だけ" section's auto-mismatch hint caption
    /// (`docs/design/20-voiceprint-misassignment-mitigation.md` section 6.3): the caller
    /// (`SpeakerLabelColumnView`) computes this from the row's primary (first) `RenameableSlot
    /// .assignedBy`, so this view stays a plain renderer of a `Bool` rather than reaching back into
    /// `slots` itself to decide.
    let showsAutoHint: Bool
    let onSubmitSlot: (_ slot: String, _ submission: SpeakerRenameSubmission?) -> Void
    let onSubmitSegment: (_ submission: SpeakerRenameSubmission?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !slots.isEmpty {
                Text("話者名（すべての発言に適用）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(slots) { target in
                    SlotRenameFieldView(
                        target: target,
                        knownSpeakers: knownSpeakers,
                        showsTitle: slots.count > 1,
                        onSubmitSlot: onSubmitSlot
                    )
                }
                Divider()
            }
            SegmentOverrideFieldView(
                isSegmentOverride: isSegmentOverride,
                initialName: initialSegmentName,
                knownSpeakers: knownSpeakers,
                primarySlotEmbedding: slots.first?.embedding,
                showsAutoHint: showsAutoHint,
                onSubmit: onSubmitSegment
            )
        }
        .padding(12)
        .frame(width: 300)
    }
}

// MARK: - SlotRenameFieldView

/// One slot-wide rename line: the slot's current on-screen label (shown only when the popover has
/// more than one, i.e. a mixed row, so the fields can be told apart), a known-speaker picker (design
/// section 4.4 bullet 2, "既存話者を選択"), a free-text draft field (bullet 1, "新しい名前を入力"), and
/// apply/clear.
///
/// The draft field is a `SpeakerNameSuggestField`
/// (`docs/design/48-speaker-rename-autocomplete.md`), so typing a few characters narrows the known
/// speakers inline and ↑↓/Enter picks one -- the picker `Menu` below stays for the unfiltered,
/// voice-similarity-ordered full list (design 48 section 2.3).
private struct SlotRenameFieldView: View {
    let target: RenameableSlot
    let knownSpeakers: [VoiceprintSpeaker]
    let showsTitle: Bool
    let onSubmitSlot: (_ slot: String, _ submission: SpeakerRenameSubmission?) -> Void

    @State private var draft: String

    init(
        target: RenameableSlot,
        knownSpeakers: [VoiceprintSpeaker],
        showsTitle: Bool,
        onSubmitSlot: @escaping (_ slot: String, _ submission: SpeakerRenameSubmission?) -> Void
    ) {
        self.target = target
        self.knownSpeakers = knownSpeakers
        self.showsTitle = showsTitle
        self.onSubmitSlot = onSubmitSlot
        _draft = State(initialValue: target.currentName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SpeakerNameSuggestField(
                draft: $draft,
                placeholder: "名前を入力",
                title: showsTitle ? target.title : nil,
                knownSpeakers: knownSpeakers,
                slotEmbedding: target.embedding,
                identifierPrefix: "rename-slot-\(target.slot)",
                onSubmit: { submission in onSubmitSlot(target.slot, submission) },
                trailing: {
                    Button("適用", action: applyNewName)
                        .disabled(trimmedDraft == nil)
                    Button("解除") {
                        onSubmitSlot(target.slot, nil)
                    }
                    .disabled(target.currentName == nil)
                }
            )
            if !knownSpeakers.isEmpty {
                knownSpeakerPicker
            }
        }
    }

    /// Design section 4.4 bullet 2 / section 6.1's known-speaker picker: assigning one of these never
    /// touches any embedding (`SpeakerRenameDecision.assignExisting`), unlike the free-text field above
    /// which may register a brand-new global speaker (bullet 1).
    private var knownSpeakerPicker: some View {
        KnownSpeakerPickerView(speakers: knownSpeakers, slotEmbedding: target.embedding) { speaker in
            onSubmitSlot(target.slot, .existingSpeaker(globalSpeakerId: speaker.id, name: speaker.name))
        }
    }

    private var trimmedDraft: String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func applyNewName() {
        guard let trimmedDraft else { return }
        onSubmitSlot(target.slot, .newName(trimmedDraft))
    }
}

// MARK: - SegmentOverrideFieldView

/// The per-segment "この発言だけ" line (design section 6.1 / 4.3's `segment_overrides`). "解除" only
/// enables while an override is actually applied -- clearing a slot's name lives on that slot's own
/// line above, so the two clear scopes can't be confused.
///
/// Carries the same known-speaker picker as `SlotRenameFieldView`
/// (`docs/design/20-voiceprint-misassignment-mitigation.md` section 5.2): picking a speaker submits
/// `.existingSpeaker` directly (bypassing normalization, same as the slot-wide picker), while the
/// free-text field always submits `.newName` and lets the ViewModel normalize it
/// (`MeetingWorkspaceViewModel.overrideSegmentSpeaker(segmentId:submission:)`). Its inline suggestion
/// list (`SpeakerNameSuggestField`, `docs/design/48-speaker-rename-autocomplete.md`) spans both: a
/// suggested speaker submits `.existingSpeaker`, the trailing "新しい名前で登録" row submits `.newName`.
private struct SegmentOverrideFieldView: View {
    let isSegmentOverride: Bool
    let knownSpeakers: [VoiceprintSpeaker]
    /// This row's primary slot's captured voiceprint, if any -- there is no embedding of the segment
    /// itself, so the picker orders by the primary slot's voice instead (design section 5.2, "セグメント
    /// 単独の embedding は持っていないため、当該行の primary slot の embedding（あれば）で並べ").
    let primarySlotEmbedding: [Float]?
    /// Design section 6.3's auto-mismatch hint caption, shown only when the primary slot's current
    /// assignment is `.auto`.
    let showsAutoHint: Bool
    let onSubmit: (_ submission: SpeakerRenameSubmission?) -> Void

    @State private var draft: String

    init(
        isSegmentOverride: Bool,
        initialName: String,
        knownSpeakers: [VoiceprintSpeaker],
        primarySlotEmbedding: [Float]?,
        showsAutoHint: Bool,
        onSubmit: @escaping (_ submission: SpeakerRenameSubmission?) -> Void
    ) {
        self.isSegmentOverride = isSegmentOverride
        self.knownSpeakers = knownSpeakers
        self.primarySlotEmbedding = primarySlotEmbedding
        self.showsAutoHint = showsAutoHint
        self.onSubmit = onSubmit
        _draft = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("この発言だけ")
                .font(.caption)
                .foregroundStyle(.secondary)
            SpeakerNameSuggestField(
                draft: $draft,
                placeholder: "名前を入力",
                title: nil,
                knownSpeakers: knownSpeakers,
                slotEmbedding: primarySlotEmbedding,
                identifierPrefix: "rename-segment",
                onSubmit: { submission in onSubmit(submission) },
                trailing: {
                    Button("適用", action: apply)
                        .disabled(trimmedDraft == nil)
                    Button("解除") {
                        onSubmit(nil)
                    }
                    .disabled(!isSegmentOverride)
                }
            )
            if !knownSpeakers.isEmpty {
                knownSpeakerPicker
            }
            if showsAutoHint {
                Text("自動判定が間違っている場合は、上の「すべての発言に適用」を使うと以後の会議でも正しく認識されます")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// `knownSpeakers` ordered by voice similarity to the row's primary slot (`KnownSpeakerPickerView`,
    /// design section 5.2) -- falls back to descending `updatedAt` when `primarySlotEmbedding` is
    /// `nil`/empty, same as `SlotRenameFieldView`.
    private var knownSpeakerPicker: some View {
        KnownSpeakerPickerView(speakers: knownSpeakers, slotEmbedding: primarySlotEmbedding) { speaker in
            onSubmit(.existingSpeaker(globalSpeakerId: speaker.id, name: speaker.name))
        }
    }

    private var trimmedDraft: String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func apply() {
        guard let trimmedDraft else { return }
        onSubmit(.newName(trimmedDraft))
    }
}

// MARK: - KnownSpeakerPickerView

/// The known-speaker picker menu shared by `SlotRenameFieldView` and `SegmentOverrideFieldView` (design
/// section 4.4 bullet 2 / section 5.2/6.1): both render the exact same "既存の話者から選択…" `Menu`, ordered
/// by voice similarity to a slot embedding (`KnownSpeakerSort.sorted(speakers:slotEmbedding:)`) that
/// falls back to descending `updatedAt` when no embedding is available, differing only in which
/// embedding they sort by and what picking a speaker submits.
private struct KnownSpeakerPickerView: View {
    let speakers: [VoiceprintSpeaker]
    /// The relevant slot's captured voiceprint, if any -- `SegmentOverrideFieldView` has no embedding
    /// of the segment itself, so it passes its row's primary slot's embedding instead (design section
    /// 5.2).
    let slotEmbedding: [Float]?
    let onPick: (VoiceprintSpeaker) -> Void

    private var sortedSpeakers: [VoiceprintSpeaker] {
        KnownSpeakerSort.sorted(speakers: speakers, slotEmbedding: slotEmbedding)
    }

    var body: some View {
        Menu {
            ForEach(sortedSpeakers) { speaker in
                Button(speaker.name) {
                    onPick(speaker)
                }
            }
        } label: {
            Text("既存の話者から選択…")
                .font(.caption2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
