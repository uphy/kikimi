import SwiftUI

// MARK: - SpeakerNameSuggestField

/// The rename popover's free-text name field plus its inline suggestion list
/// (`docs/design/48-speaker-rename-autocomplete.md`). Shared by both fields of
/// `RenameSpeakerPopoverView` -- the slot-wide "すべての発言に適用" line and the per-segment "この発言だけ"
/// line -- which differ only in what a pick submits and which slot's voiceprint orders the candidates.
///
/// The list is a plain inline `VStack` that appears and disappears with the draft text, not a nested
/// floating panel, exactly like the participant-hints suggest box
/// (`docs/design/22-participant-hints.md` section 5): this view already lives *inside* a `.popover`, and
/// stacking a second floating layer on top of one is both fragile to dismiss and undetectable to
/// `kikimi-verify`.
///
/// `title` and `trailing` carry the caller's own leading label and "適用"/"解除" buttons so they stay on
/// the same row as the field (the pre-existing layout) while this view owns everything below it. Both
/// belong to the field's *row*, not to the field: if the caller placed them in its own `HStack` around
/// this view instead, the suggestion list -- which is part of this view's vertical stack -- would push
/// them out of line as soon as it appeared.
struct SpeakerNameSuggestField<Trailing: View>: View {
    @Binding var draft: String
    let placeholder: String
    /// The slot's current on-screen label, shown to the left of the field. Only non-`nil` when the
    /// popover renders more than one slot field (an "A + B" mixed row), so the two can be told apart.
    let title: String?
    let knownSpeakers: [VoiceprintSpeaker]
    /// The relevant slot's captured voiceprint, forwarded to `SpeakerSuggestList` for within-group
    /// ordering (`docs/design/20-voiceprint-misassignment-mitigation.md` section 5.2). `nil` for a slot
    /// that hasn't captured one yet, and for the segment-override field the row's *primary* slot's
    /// embedding (a segment has none of its own).
    let slotEmbedding: [Float]?
    /// Prefix for the suggestion rows' `accessibilityIdentifier`s, so `kikimi-verify` can tell the
    /// slot-wide field's list apart from the segment-override one on the same popover.
    let identifierPrefix: String
    let onSubmit: (SpeakerRenameSubmission) -> Void
    @ViewBuilder let trailing: () -> Trailing

    /// Which rendered row the keyboard has selected, or `nil` for the free-text state where Enter
    /// submits the typed draft as-is (design section 2.2).
    @State private var selectedIndex: Int?
    /// Set by Escape, cleared by the next edit (design section 2.2): lets the user dismiss the list
    /// without also losing what they typed, and without Escape falling through to close the popover.
    @State private var isListDismissed = false

    private var trimmedDraft: String { SpeakerName.trimmed(draft) }

    private var suggestions: (rows: [SpeakerSuggestion], truncatedSpeakerCount: Int) {
        SpeakerSuggestList.suggestions(
            query: draft, knownSpeakers: knownSpeakers, slotEmbedding: slotEmbedding
        )
    }

    private var visibleRows: [SpeakerSuggestion] {
        isListDismissed ? [] : suggestions.rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let title {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                        .lineLimit(1)
                        .help(title)
                }
                textField
                trailing()
            }
            if !visibleRows.isEmpty {
                suggestionList
            }
        }
    }

    private var textField: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("\(identifierPrefix)-field")
            .onSubmit(submitSelectionOrDraft)
            // Arrow keys reach this field because `.onKeyPress` is delivered to the focused view before
            // AppKit's own text-navigation handling, and a single-line `TextField` has no vertical
            // navigation to lose to it either way.
            .onKeyPress(.downArrow) { moveSelection(by: 1) }
            .onKeyPress(.upArrow) { moveSelection(by: -1) }
            .onKeyPress(.escape) { dismissList() }
            .onChange(of: draft) { _, _ in
                // The rows themselves changed, so a held-over index would point at a different speaker
                // than the one still highlighted a keystroke ago (design section 2.2).
                selectedIndex = nil
                isListDismissed = false
            }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                suggestionRow(row, isSelected: index == selectedIndex)
            }
            if suggestions.truncatedSpeakerCount > 0 {
                // Design section 2.1: the cap is stated rather than silently applied, together with
                // where the rest of the speakers are still reachable.
                Text("他 \(suggestions.truncatedSpeakerCount) 件は「既存の話者から選択…」から")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    private func suggestionRow(_ row: SpeakerSuggestion, isSelected: Bool) -> some View {
        Button {
            submit(row)
        } label: {
            Text(label(for: row))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(identifierPrefix)-suggest-\(identifierSuffix(for: row))")
    }

    private func label(for row: SpeakerSuggestion) -> String {
        switch row {
        case let .existing(speaker):
            return speaker.name
        case let .registerNew(name):
            return "「\(name)」を新しい名前で登録"
        }
    }

    private func identifierSuffix(for row: SpeakerSuggestion) -> String {
        switch row {
        case let .existing(speaker):
            return speaker.name
        case .registerNew:
            return "new"
        }
    }

    private func moveSelection(by delta: Int) -> KeyPress.Result {
        let rows = visibleRows
        guard !rows.isEmpty else { return .ignored }
        selectedIndex = SpeakerSuggestList.movedSelection(
            current: selectedIndex, delta: delta, count: rows.count
        )
        return .handled
    }

    /// Escape closes the suggestion list first and the enclosing `.popover` only on a second press:
    /// returning `.ignored` when no list is open is what lets macOS's own popover dismissal take over
    /// (design section 2.2).
    private func dismissList() -> KeyPress.Result {
        guard !visibleRows.isEmpty else { return .ignored }
        isListDismissed = true
        selectedIndex = nil
        return .handled
    }

    private func submitSelectionOrDraft() {
        let rows = visibleRows
        if let selectedIndex, rows.indices.contains(selectedIndex) {
            submit(rows[selectedIndex])
            return
        }
        guard !trimmedDraft.isEmpty else { return }
        onSubmit(.newName(trimmedDraft))
    }

    private func submit(_ row: SpeakerSuggestion) {
        switch row {
        case let .existing(speaker):
            onSubmit(.existingSpeaker(globalSpeakerId: speaker.id, name: speaker.name))
        case let .registerNew(name):
            onSubmit(.newName(name))
        }
    }
}
