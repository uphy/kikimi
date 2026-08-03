import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `SpeakerSuggestList` (`Kikimi/ViewModels/SpeakerSuggestList.swift`,
/// `docs/design/48-speaker-rename-autocomplete.md`). Pure/deterministic (no I/O), so filtering,
/// ordering, the display cap and the arrow-key boundaries are all exercised directly here without a
/// `VoiceprintStore`/UI round-trip -- same rationale as `KnownSpeakerSortTests`.
@Suite("SpeakerSuggestList")
struct SpeakerSuggestListTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func speaker(
        id: String,
        name: String,
        embedding: [Float] = [],
        updatedAt: Date = baseDate
    ) -> VoiceprintSpeaker {
        VoiceprintSpeaker(
            id: id,
            name: name,
            embedding: embedding,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    private static func names(_ rows: [SpeakerSuggestion]) -> [String] {
        rows.compactMap { row in
            if case let .existing(speaker) = row { return speaker.name }
            return nil
        }
    }

    // MARK: - Filtering

    @Test("an empty draft yields no rows at all (the list only exists while typing)")
    func emptyQueryYieldsNoRows() {
        let result = SpeakerSuggestList.suggestions(
            query: "", knownSpeakers: [Self.speaker(id: "a", name: "山田 太郎")]
        )

        #expect(result.rows.isEmpty)
        #expect(result.truncatedSpeakerCount == 0)
    }

    @Test("a whitespace-only draft is treated the same as an empty one")
    func whitespaceOnlyQueryYieldsNoRows() {
        let result = SpeakerSuggestList.suggestions(
            query: "   \n ", knownSpeakers: [Self.speaker(id: "a", name: "山田 太郎")]
        )

        #expect(result.rows.isEmpty)
    }

    @Test("matches are substring, case-insensitive")
    func matchesSubstringCaseInsensitively() {
        let speakers = [
            Self.speaker(id: "a", name: "Alice Smith"),
            Self.speaker(id: "b", name: "Bob Jones"),
        ]

        let result = SpeakerSuggestList.suggestions(query: "SMITH", knownSpeakers: speakers)

        #expect(Self.names(result.rows) == ["Alice Smith"])
    }

    @Test("the draft is trimmed before matching, like every other name comparison")
    func trimsQueryBeforeMatching() {
        let speakers = [Self.speaker(id: "a", name: "山田 太郎")]

        let result = SpeakerSuggestList.suggestions(query: "  山田 \n", knownSpeakers: speakers)

        #expect(Self.names(result.rows) == ["山田 太郎"])
    }

    // MARK: - Ordering

    @Test("prefix matches come before speakers that merely contain the query")
    func prefixMatchesComeFirst() {
        let speakers = [
            Self.speaker(id: "contains", name: "小山田 次郎"),
            Self.speaker(id: "prefix", name: "山田 太郎"),
        ]

        let result = SpeakerSuggestList.suggestions(query: "山田", knownSpeakers: speakers)

        #expect(Self.names(result.rows) == ["山田 太郎", "小山田 次郎"])
    }

    @Test("within a group, ordering is KnownSpeakerSort's: closest voice to the slot first")
    func withinGroupOrdersByVoiceSimilarity() {
        // Both are prefix matches, so only the embedding distance to `slotEmbedding` separates them.
        let far = Self.speaker(id: "far", name: "山田 次郎", embedding: [-1, 0])
        let close = Self.speaker(id: "close", name: "山田 太郎", embedding: [1, 0])

        let result = SpeakerSuggestList.suggestions(
            query: "山田", knownSpeakers: [far, close], slotEmbedding: [1, 0]
        )

        #expect(Self.names(result.rows) == ["山田 太郎", "山田 次郎"])
    }

    @Test("with no slot embedding, within-group ordering falls back to descending updatedAt")
    func withinGroupFallsBackToRecency() {
        let older = Self.speaker(id: "older", name: "山田 次郎", updatedAt: Self.baseDate)
        let newer = Self.speaker(
            id: "newer", name: "山田 太郎", updatedAt: Self.baseDate.addingTimeInterval(60)
        )

        let result = SpeakerSuggestList.suggestions(
            query: "山田", knownSpeakers: [older, newer], slotEmbedding: nil
        )

        #expect(Self.names(result.rows) == ["山田 太郎", "山田 次郎"])
    }

    @Test("a closer voice never outranks a prefix match (text beats voice across groups)")
    func prefixGroupOutranksCloserVoice() {
        let closeButContainsOnly = Self.speaker(id: "close", name: "小山田 次郎", embedding: [1, 0])
        let farButPrefix = Self.speaker(id: "far", name: "山田 太郎", embedding: [-1, 0])

        let result = SpeakerSuggestList.suggestions(
            query: "山田", knownSpeakers: [closeButContainsOnly, farButPrefix], slotEmbedding: [1, 0]
        )

        #expect(Self.names(result.rows) == ["山田 太郎", "小山田 次郎"])
    }

    // MARK: - Display cap

    @Test("the speaker rows are capped and the dropped count is reported, not silently swallowed")
    func capsRowsAndReportsTruncatedCount() {
        let speakers = (0..<8).map { index in
            Self.speaker(
                id: "s\(index)",
                name: "山田 \(index)",
                updatedAt: Self.baseDate.addingTimeInterval(TimeInterval(-index))
            )
        }

        let result = SpeakerSuggestList.suggestions(query: "山田", knownSpeakers: speakers, limit: 5)

        #expect(Self.names(result.rows).count == 5)
        #expect(result.truncatedSpeakerCount == 3)
        // Most recently updated first (no slot embedding), so the cap drops the least recent ones.
        #expect(Self.names(result.rows) == ["山田 0", "山田 1", "山田 2", "山田 3", "山田 4"])
    }

    @Test("nothing is reported as truncated when every match fits")
    func reportsNoTruncationWhenEverythingFits() {
        let speakers = [Self.speaker(id: "a", name: "山田 太郎")]

        let result = SpeakerSuggestList.suggestions(query: "山田", knownSpeakers: speakers, limit: 5)

        #expect(result.truncatedSpeakerCount == 0)
    }

    // MARK: - "Register a new name" row

    @Test("the register-new row is appended after the speaker rows when nothing matches exactly")
    func appendsRegisterNewRow() {
        let speakers = [Self.speaker(id: "a", name: "山田 太郎")]

        let result = SpeakerSuggestList.suggestions(query: "山田", knownSpeakers: speakers)

        #expect(result.rows.count == 2)
        #expect(result.rows.last == .registerNew("山田"))
    }

    @Test("no register-new row once the draft trim-exactly matches a known speaker")
    func hidesRegisterNewRowOnExactMatch() {
        let speakers = [Self.speaker(id: "a", name: "山田 太郎")]

        let result = SpeakerSuggestList.suggestions(query: "  山田 太郎 ", knownSpeakers: speakers)

        #expect(result.rows == [.existing(speakers[0])])
    }

    @Test("an exact match hides the row even when the matched speaker is off the capped list")
    func exactMatchHidesRegisterNewRowRegardlessOfCap() {
        // "山田 0" trim-exactly matches, but with limit 1 only the most recent speaker is rendered.
        let speakers = (0..<3).map { index in
            Self.speaker(
                id: "s\(index)",
                name: "山田 \(index)",
                updatedAt: Self.baseDate.addingTimeInterval(TimeInterval(index))
            )
        }

        let result = SpeakerSuggestList.suggestions(query: "山田 0", knownSpeakers: speakers, limit: 1)

        #expect(!result.rows.contains(.registerNew("山田 0")))
    }

    @Test("showsRegisterNewRow is false for an empty draft and for an exact match only")
    func showsRegisterNewRowRules() {
        let speakers = [Self.speaker(id: "a", name: "山田 太郎")]

        #expect(!SpeakerSuggestList.showsRegisterNewRow(query: "  ", knownSpeakers: speakers))
        #expect(!SpeakerSuggestList.showsRegisterNewRow(query: "山田 太郎", knownSpeakers: speakers))
        #expect(SpeakerSuggestList.showsRegisterNewRow(query: "山田", knownSpeakers: speakers))
        #expect(SpeakerSuggestList.showsRegisterNewRow(query: "佐藤", knownSpeakers: speakers))
    }

    // MARK: - Keyboard selection

    @Test("down from the free-text state selects the first row")
    func downFromNoSelectionSelectsFirstRow() {
        #expect(SpeakerSuggestList.movedSelection(current: nil, delta: 1, count: 3) == 0)
    }

    @Test("up from the free-text state stays there (no wrap to the bottom)")
    func upFromNoSelectionStaysUnselected() {
        #expect(SpeakerSuggestList.movedSelection(current: nil, delta: -1, count: 3) == nil)
    }

    @Test("down stops at the last row instead of wrapping")
    func downStopsAtLastRow() {
        #expect(SpeakerSuggestList.movedSelection(current: 1, delta: 1, count: 3) == 2)
        #expect(SpeakerSuggestList.movedSelection(current: 2, delta: 1, count: 3) == 2)
    }

    @Test("up off the first row returns to the free-text state")
    func upOffFirstRowReturnsToFreeText() {
        #expect(SpeakerSuggestList.movedSelection(current: 1, delta: -1, count: 3) == 0)
        #expect(SpeakerSuggestList.movedSelection(current: 0, delta: -1, count: 3) == nil)
    }

    @Test("with no rows there is nothing to select in either direction")
    func emptyRowsNeverSelect() {
        #expect(SpeakerSuggestList.movedSelection(current: nil, delta: 1, count: 0) == nil)
        #expect(SpeakerSuggestList.movedSelection(current: 0, delta: 1, count: 0) == nil)
        #expect(SpeakerSuggestList.movedSelection(current: 0, delta: -1, count: 0) == nil)
    }

    @Test("a stale selection past the end is clamped to the last row")
    func staleSelectionIsClamped() {
        #expect(SpeakerSuggestList.movedSelection(current: 9, delta: 1, count: 3) == 2)
    }
}
