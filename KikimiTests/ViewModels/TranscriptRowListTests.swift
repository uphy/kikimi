import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `TranscriptRowList.inserted(_:into:)`
/// (`Kikimi/ViewModels/TranscriptRowList.swift`, `docs/design/06-ui-panels.md` section 6.3/12).
///
/// Covers not just tail insertion (the common case while a single stream is producing segments in
/// order) but also the mid-list insertion cases the design doc calls out explicitly: mic/system are
/// independent streams, so a segment with an earlier `startMs` can be appended to `transcript.jsonl`
/// (and thus arrive here) *after* a segment with a later `startMs` already in the list.
@Suite("TranscriptRowList")
struct TranscriptRowListTests {
    private func row(_ id: String, _ startMs: Int, endMs: Int? = nil, speaker: AudioSourceKind = .mic) -> TranscriptRowViewModel {
        TranscriptRowViewModel(
            id: id,
            startMs: startMs,
            endMs: endMs ?? startMs + 1_000,
            speaker: speaker,
            rawText: id,
            state: .raw
        )
    }

    // MARK: - Empty list

    @Test("inserting into an empty list produces a single-element list")
    func insertIntoEmptyList() {
        let result = TranscriptRowList.inserted(row("seg_00001", 1_000), into: [])
        #expect(result == [row("seg_00001", 1_000)])
    }

    // MARK: - Tail insertion (the common case)

    @Test("a segment with a later startMs than everything else is appended at the tail")
    func insertAtTail() {
        let existing = [row("seg_00001", 1_000), row("seg_00002", 2_000)]
        let result = TranscriptRowList.inserted(row("seg_00003", 3_000), into: existing)
        #expect(result.map(\.id) == ["seg_00001", "seg_00002", "seg_00003"])
    }

    // MARK: - Head insertion

    @Test("a segment with an earlier startMs than everything else is inserted at the head")
    func insertAtHead() {
        let existing = [row("seg_00002", 2_000), row("seg_00003", 3_000)]
        let result = TranscriptRowList.inserted(row("seg_00001", 500), into: existing)
        #expect(result.map(\.id) == ["seg_00001", "seg_00002", "seg_00003"])
    }

    // MARK: - Middle insertion

    @Test("a segment that arrives late from a slower stream is inserted in the middle by startMs")
    func insertInMiddle() {
        // Simulates: system stream confirms seg_00001 (0ms) then seg_00003 (4000ms) quickly, while
        // mic is mid-decode of a long utterance; seg_00002 (2000ms) arrives afterwards but sorts
        // between the two already-present rows.
        let existing = [row("seg_00001", 0, speaker: .system), row("seg_00003", 4_000, speaker: .system)]
        let result = TranscriptRowList.inserted(row("seg_00002", 2_000, speaker: .mic), into: existing)
        #expect(result.map(\.id) == ["seg_00001", "seg_00002", "seg_00003"])
    }

    @Test("multiple out-of-order insertions converge to full startMs ascending order")
    func multipleOutOfOrderInsertionsConverge() {
        // Arrival order (by id) deliberately scrambled relative to startMs, mirroring kikimi.md
        // 6 章's "id は投入順に採番されるので、時系列とはズレる可能性がある" note.
        let arrivals = [
            row("seg_00003", 3_000),
            row("seg_00001", 1_000),
            row("seg_00005", 5_000),
            row("seg_00002", 2_000),
            row("seg_00004", 4_000)
        ]

        var rows: [TranscriptRowViewModel] = []
        for arrival in arrivals {
            rows = TranscriptRowList.inserted(arrival, into: rows)
        }

        #expect(rows.map(\.id) == ["seg_00001", "seg_00002", "seg_00003", "seg_00004", "seg_00005"])
        #expect(rows.map(\.startMs) == [1_000, 2_000, 3_000, 4_000, 5_000])
    }

    // MARK: - Tie-breaking on startMs

    @Test("segments with equal startMs are ordered by id ascending")
    func tieBreaksByIdAscending() {
        let existing = [row("seg_00001", 1_000)]
        let result = TranscriptRowList.inserted(row("seg_00000", 1_000), into: existing)
        #expect(result.map(\.id) == ["seg_00000", "seg_00001"])
    }

    @Test("inserting a row whose id sorts after an equal-startMs existing row keeps it after")
    func tieBreakInsertsAfterWhenIdIsGreater() {
        let existing = [row("seg_00001", 1_000)]
        let result = TranscriptRowList.inserted(row("seg_00002", 1_000), into: existing)
        #expect(result.map(\.id) == ["seg_00001", "seg_00002"])
    }

    @Test("inserting into a run of equal startMs rows lands at the correct id-sorted position")
    func tieBreakInsertsIntoMiddleOfEqualStartMsRun() {
        let existing = [row("seg_00001", 1_000), row("seg_00003", 1_000), row("seg_00005", 1_000)]
        let result = TranscriptRowList.inserted(row("seg_00002", 1_000), into: existing)
        #expect(result.map(\.id) == ["seg_00001", "seg_00002", "seg_00003", "seg_00005"])
    }

    // MARK: - Field preservation

    @Test("inserted row's fields (endMs, speaker, rawText, state) are carried through unchanged")
    func insertedRowFieldsArePreserved() {
        let candidate = TranscriptRowViewModel(
            id: "seg_00001",
            startMs: 100,
            endMs: 900,
            speaker: .system,
            rawText: "こんにちは",
            state: .raw
        )

        let result = TranscriptRowList.inserted(candidate, into: [])
        #expect(result == [candidate])
    }
}
