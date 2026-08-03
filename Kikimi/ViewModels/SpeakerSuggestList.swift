import Foundation

// MARK: - SpeakerSuggestion

/// One row of the rename popover's inline suggestion list
/// (`docs/design/48-speaker-rename-autocomplete.md` section 2.1). The "register a new name" row is part
/// of the same list rather than a sibling control below it, so `selectedIndex` in
/// `SpeakerNameSuggestField` means exactly "index into the rendered rows" and arrow-key movement can
/// stay a single `movedSelection(current:delta:count:)` call over one array (section 2.2).
enum SpeakerSuggestion: Equatable, Identifiable {
    /// An already-registered global speaker: picking it submits `.existingSpeaker`, which never touches
    /// any embedding (design 13 section 4.4 bullet 2, same as the known-speaker picker `Menu`).
    case existing(VoiceprintSpeaker)
    /// The trailing "「X」を新しい名前で登録" row: picking it submits `.newName(String)`, i.e. the exact same
    /// path as typing the name and pressing Enter, so `NormalizedRenameTarget`'s normalization still
    /// runs on it in the view model.
    case registerNew(String)

    var id: String {
        switch self {
        case let .existing(speaker):
            return "existing:\(speaker.id)"
        case let .registerNew(name):
            return "new:\(name)"
        }
    }
}

// MARK: - SpeakerSuggestList

/// Pure candidate list for the rename popover's free-text fields
/// (`docs/design/48-speaker-rename-autocomplete.md`): filters the already-fetched known speakers by
/// what the user has typed so far, orders them, caps the list, and answers where the keyboard selection
/// moves next.
///
/// No I/O -- the caller (`SpeakerNameSuggestField`) supplies both the speaker list
/// (`MeetingWorkspaceViewModel.knownVoiceprintSpeakers`) and, when it has one, the target slot's
/// captured voiceprint. Sits next to `KnownSpeakerSort`/`NormalizedRenameTarget` for the same reason
/// those do: it is a view *decision* helper, not a store concern, and keeping it out of the SwiftUI
/// view is what makes the ordering and the arrow-key boundaries unit-testable.
enum SpeakerSuggestList {
    /// Design section 2.1's cap. The popover is a fixed 300pt-wide `.popover`, so an uncapped list
    /// grows downwards over the transcript it is anchored to. Anything beyond this stays reachable
    /// through the "既存の話者から選択…" `Menu`, which is never filtered or capped (section 2.3).
    static let displayLimit = 5

    /// The rows to render for `query`, in display order, already capped at `limit`.
    ///
    /// - Parameters:
    ///   - query: The raw draft text. Always compared trimmed (`SpeakerName.trimmed`), matching how
    ///     every other name comparison in the rename flow works (design 20 section 4). An empty or
    ///     whitespace-only draft yields no rows at all -- the list only exists while the user is typing.
    ///   - knownSpeakers: The full known-speaker list, verbatim from
    ///     `MeetingWorkspaceViewModel.knownVoiceprintSpeakers`.
    ///   - slotEmbedding: The target slot's captured voiceprint if any, forwarded to
    ///     `KnownSpeakerSort.sorted(speakers:slotEmbedding:)` for the within-group ordering (design 20
    ///     section 5.2). `nil`/empty falls back to descending `updatedAt` there.
    ///   - limit: Overridable only for tests; production always uses `displayLimit`.
    /// - Returns: `rows` in display order plus `truncatedSpeakerCount`, the number of matching speakers
    ///   the cap dropped -- the caller shows that count rather than letting the list silently end.
    static func suggestions(
        query: String,
        knownSpeakers: [VoiceprintSpeaker],
        slotEmbedding: [Float]? = nil,
        limit: Int = displayLimit
    ) -> (rows: [SpeakerSuggestion], truncatedSpeakerCount: Int) {
        let trimmed = SpeakerName.trimmed(query)
        guard !trimmed.isEmpty else { return (rows: [], truncatedSpeakerCount: 0) }

        let matched = orderedMatches(query: trimmed, knownSpeakers: knownSpeakers, slotEmbedding: slotEmbedding)
        let shown = Array(matched.prefix(max(0, limit)))
        var rows = shown.map(SpeakerSuggestion.existing)
        if showsRegisterNewRow(query: trimmed, knownSpeakers: knownSpeakers) {
            rows.append(.registerNew(trimmed))
        }
        return (rows: rows, truncatedSpeakerCount: matched.count - shown.count)
    }

    /// Design section 2.1: the "新しい名前で登録" row appears only when *no* known speaker trimmed-exact-
    /// matches the draft -- the same rule the participant-hints suggest box uses
    /// (`docs/design/22-participant-hints.md` section 4.3). Matching an existing speaker exactly means
    /// the user has already typed that speaker's registered name, and `NormalizedRenameTarget.resolve`
    /// would resolve a `.newName` submission to that speaker anyway, so offering to "register" it would
    /// promise something the submission path does not do.
    static func showsRegisterNewRow(query: String, knownSpeakers: [VoiceprintSpeaker]) -> Bool {
        let trimmed = SpeakerName.trimmed(query)
        guard !trimmed.isEmpty else { return false }
        return !knownSpeakers.contains { SpeakerName.isSame($0.name, trimmed) }
    }

    /// Where the keyboard selection lands after moving by `delta` rows (design section 2.2).
    ///
    /// `nil` means "nothing selected", i.e. the free-text state where Enter submits whatever is typed.
    /// Movement deliberately does **not** wrap: ↓ stops at the last row instead of jumping back to the
    /// top, and ↑ off the first row returns to `nil` rather than to the bottom, so the only way to reach
    /// the free-text state is the direction the user came from.
    ///
    /// - Parameter count: The number of rendered rows (`suggestions(...).rows.count`). Zero always
    ///   yields `nil` -- there is nothing to select.
    static func movedSelection(current: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else {
            return delta > 0 ? 0 : nil
        }
        let next = current + delta
        guard next >= 0 else { return nil }
        return min(next, count - 1)
    }

    /// Design section 2.1's two-group ordering: speakers whose name *starts with* the query come before
    /// speakers that merely contain it, and each group is ordered by `KnownSpeakerSort` (voice
    /// similarity to this slot, falling back to recency). "Closest to what I typed" wins over "closest
    /// to this voice", but the latter still decides the order among otherwise equally good text matches.
    private static func orderedMatches(
        query: String,
        knownSpeakers: [VoiceprintSpeaker],
        slotEmbedding: [Float]?
    ) -> [VoiceprintSpeaker] {
        let matching = knownSpeakers.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let sorted = KnownSpeakerSort.sorted(speakers: matching, slotEmbedding: slotEmbedding)
        let prefixMatches = sorted.filter { hasCaseInsensitivePrefix($0.name, query) }
        let containsOnly = sorted.filter { !hasCaseInsensitivePrefix($0.name, query) }
        return prefixMatches + containsOnly
    }

    /// Prefix counterpart of `localizedCaseInsensitiveContains` (which has no `hasPrefix` sibling in
    /// Foundation): `.anchored` without `.backwards` restricts the search to the very start of `name`.
    /// `name` is trimmed first so a stored name with stray leading whitespace still prefix-matches, the
    /// same tolerance `SpeakerName.isSame` gives exact comparisons.
    private static func hasCaseInsensitivePrefix(_ name: String, _ query: String) -> Bool {
        SpeakerName.trimmed(name).range(
            of: query, options: [.caseInsensitive, .anchored], range: nil, locale: .current
        ) != nil
    }
}
