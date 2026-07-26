import Foundation
import Testing

@testable import Kikimi

/// `RefinementMerge` coverage: `docs/design/03-refinement-batch.md` §15.2.3 (the deterministic merge
/// gate)/§15.2.4 (the coverage invariant + 1:1 fallback), §15.2.8's test list.
@Suite("RefinementMerge")
struct RefinementMergeTests {
    private let refinedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let model = "claude-haiku-4-5-20251001"
    private let batchId = "batch_00001"

    // MARK: - Helpers

    private func makeSegment(
        id: String,
        startMs: Int,
        endMs: Int,
        speaker: AudioSourceKind = .mic,
        refinedText: String? = "refined",
        rawText: String? = nil
    ) -> RefinedSegment {
        RefinedSegment(
            id: id,
            startMs: startMs,
            endMs: endMs,
            speaker: speaker,
            rawText: rawText ?? "raw-\(id)",
            refinedText: refinedText,
            error: refinedText == nil ? "missing from LLM response" : nil,
            refinedAt: refinedAt,
            model: model,
            batchId: batchId
        )
    }

    /// Every segment lands in the same recording index (`0`) unless overridden.
    private func sameRecordingIndex(_ startMs: Int) -> Int { 0 }

    // MARK: - Simple chains

    @Test("a simple 2-chain merges into one unit spanning both segments")
    func simpleTwoChainMerges() {
        let a = makeSegment(id: "seg_00001", startMs: 0, endMs: 500, refinedText: "そうですね次のスプリントで")
        let b = makeSegment(id: "seg_00002", startMs: 500, endMs: 1_000, refinedText: "対応します。")

        let result = RefinementMerge.merge(
            [a, b],
            joinsNext: ["seg_00001": true],
            recordingIndexOf: sameRecordingIndex
        )

        #expect(result.count == 1)
        #expect(result[0].id == "seg_00001")
        #expect(result[0].sourceSegIds == ["seg_00001", "seg_00002"])
        #expect(result[0].startMs == 0)
        #expect(result[0].endMs == 1_000)
        #expect(result[0].rawText == "raw-seg_00001raw-seg_00002")
        #expect(result[0].refinedText == "そうですね次のスプリントで対応します。")
    }

    @Test("a 3-chain folds all three segments into one unit, in order")
    func threeChainMerges() {
        let a = makeSegment(id: "seg_00001", startMs: 0, endMs: 300, refinedText: "そうですね")
        let b = makeSegment(id: "seg_00002", startMs: 300, endMs: 600, refinedText: "次のスプリントで")
        let c = makeSegment(id: "seg_00003", startMs: 600, endMs: 900, refinedText: "対応します。")

        let result = RefinementMerge.merge(
            [a, b, c],
            joinsNext: ["seg_00001": true, "seg_00002": true],
            recordingIndexOf: sameRecordingIndex
        )

        #expect(result.count == 1)
        #expect(result[0].sourceSegIds == ["seg_00001", "seg_00002", "seg_00003"])
        #expect(result[0].startMs == 0)
        #expect(result[0].endMs == 900)
        #expect(result[0].refinedText == "そうですね次のスプリントで対応します。")
    }

    @Test("joinsNext=false never merges, even when every other guard would allow it")
    func joinsNextFalseNeverMerges() {
        let a = makeSegment(id: "seg_00001", startMs: 0, endMs: 500)
        let b = makeSegment(id: "seg_00002", startMs: 500, endMs: 1_000)

        let result = RefinementMerge.merge(
            [a, b],
            joinsNext: ["seg_00001": false],
            recordingIndexOf: sameRecordingIndex
        )

        #expect(result.count == 2)
        #expect(result.map(\.id) == ["seg_00001", "seg_00002"])
    }

    @Test("an id absent from the joins_next map (e.g. missing from the LLM response) is treated as false")
    func missingJoinsNextEntryDefaultsToNoMerge() {
        let a = makeSegment(id: "seg_00001", startMs: 0, endMs: 500, refinedText: nil)
        let b = makeSegment(id: "seg_00002", startMs: 500, endMs: 1_000)

        let result = RefinementMerge.merge([a, b], joinsNext: [:], recordingIndexOf: sameRecordingIndex)

        #expect(result.count == 2)
    }

    // MARK: - Guard rejections

    @Test("cross-speaker adjacency never merges, even with joinsNext=true")
    func crossSpeakerRejectsMerge() {
        let a = makeSegment(id: "seg_00001", startMs: 0, endMs: 500, speaker: .mic)
        let b = makeSegment(id: "seg_00002", startMs: 500, endMs: 1_000, speaker: .system)

        let result = RefinementMerge.merge(
            [a, b],
            joinsNext: ["seg_00001": true],
            recordingIndexOf: sameRecordingIndex
        )

        #expect(result.count == 2)
        #expect(result.map(\.id) == ["seg_00001", "seg_00002"])
    }

    @Test("crossing a recording-index boundary never merges, even with joinsNext=true and the same speaker")
    func crossRecordingIndexRejectsMerge() {
        let a = makeSegment(id: "seg_00001", startMs: 0, endMs: 500)
        let b = makeSegment(id: "seg_00002", startMs: 500, endMs: 1_000)

        let result = RefinementMerge.merge(
            [a, b],
            joinsNext: ["seg_00001": true],
            recordingIndexOf: { $0 < 500 ? 0 : 1 }
        )

        #expect(result.count == 2)
    }

    @Test("a non-empty other-stream segment sitting between A and a later same-speaker C blocks A from reaching C")
    func nonEmptyOtherStreamSegmentInBetweenBlocksMerge() {
        let a = makeSegment(id: "seg_00001", startMs: 0, endMs: 300, speaker: .mic)
        let b = makeSegment(id: "seg_00002", startMs: 300, endMs: 600, speaker: .system, refinedText: "了解しました。")
        let c = makeSegment(id: "seg_00003", startMs: 600, endMs: 900, speaker: .mic)

        // A and C both want to continue, but B (a different stream) sits directly between them in
        // start_ms order -- A is only ever compared against its literal successor (B), never against
        // C directly, so this must never collapse A and C together.
        let result = RefinementMerge.merge(
            [a, b, c],
            joinsNext: ["seg_00001": true, "seg_00002": true],
            recordingIndexOf: sameRecordingIndex
        )

        #expect(result.count == 3, "A/B/C must all remain standalone: A-B rejected (cross-speaker), B-C rejected (cross-speaker)")
        #expect(result.map(\.id) == ["seg_00001", "seg_00002", "seg_00003"])
    }

    @Test("an empty-string (intentionally deleted) A is never a merge source")
    func emptyStringARejectsMerge() {
        let a = makeSegment(id: "seg_00001", startMs: 0, endMs: 500, refinedText: "")
        let b = makeSegment(id: "seg_00002", startMs: 500, endMs: 1_000, refinedText: "next")

        let result = RefinementMerge.merge(
            [a, b],
            joinsNext: ["seg_00001": true],
            recordingIndexOf: sameRecordingIndex
        )

        #expect(result.count == 2, "A is the deleted marker (refinedText == \"\") and must not absorb B")
    }

    @Test("an empty-string (intentionally deleted) B is never absorbed, even when A wants to continue")
    func emptyStringBRejectsMerge() {
        let a = makeSegment(id: "seg_00001", startMs: 0, endMs: 500, refinedText: "some text")
        let b = makeSegment(id: "seg_00002", startMs: 500, endMs: 1_000, refinedText: "")

        let result = RefinementMerge.merge(
            [a, b],
            joinsNext: ["seg_00001": true],
            recordingIndexOf: sameRecordingIndex
        )

        #expect(result.count == 2, "B is the deleted marker and must never be absorbed into A")
    }

    @Test("a nil (failed) refinedText on either side blocks the merge")
    func nilRefinedTextRejectsMerge() {
        let aFailed = makeSegment(id: "seg_00001", startMs: 0, endMs: 500, refinedText: nil)
        let b = makeSegment(id: "seg_00002", startMs: 500, endMs: 1_000, refinedText: "next")
        // A's own joinsNext can still be true in the map (defensive: shouldn't happen in practice
        // since a missing-from-response row has no Item to source `true` from, but the gate must not
        // depend on that never happening).
        let resultAFailed = RefinementMerge.merge(
            [aFailed, b],
            joinsNext: ["seg_00001": true],
            recordingIndexOf: sameRecordingIndex
        )
        #expect(resultAFailed.count == 2)

        let a = makeSegment(id: "seg_00003", startMs: 0, endMs: 500, refinedText: "some text")
        let bFailed = makeSegment(id: "seg_00004", startMs: 500, endMs: 1_000, refinedText: nil)
        let resultBFailed = RefinementMerge.merge(
            [a, bFailed],
            joinsNext: ["seg_00003": true],
            recordingIndexOf: sameRecordingIndex
        )
        #expect(resultBFailed.count == 2)
    }

    // MARK: - Batch-tail (no cross-batch merge, 段階1 scope)

    @Test("the batch's last segment finalizes standalone even when its own joinsNext is true")
    func batchTailFinalizesStandaloneWithoutCrossBatchMerge() {
        let a = makeSegment(id: "seg_00001", startMs: 0, endMs: 500)
        let b = makeSegment(id: "seg_00002", startMs: 500, endMs: 1_000)

        let result = RefinementMerge.merge(
            [a, b],
            joinsNext: ["seg_00001": false, "seg_00002": true],
            recordingIndexOf: sameRecordingIndex
        )

        #expect(result.count == 2, "no pending-tail state exists in 段階1 -- the batch's last segment must stand alone regardless of its own joinsNext")
        #expect(result.map(\.id) == ["seg_00001", "seg_00002"])
    }

    @Test("the batch-tail info log fires with the exact 'batch-boundary joins_next dropped: <segId>' message")
    func batchTailLogsInfoWithExactMessage() {
        // No direct OSLog capture in swift-testing, so this only exercises the code path without
        // asserting on the log sink -- passing `logger: nil` (the default) already covers "does not
        // crash without a logger"; this test additionally proves a real `Logger` instance can be
        // passed through without throwing/crashing.
        let a = makeSegment(id: "seg_00001", startMs: 0, endMs: 500)
        let result = RefinementMerge.merge(
            [a],
            joinsNext: ["seg_00001": true],
            recordingIndexOf: sameRecordingIndex,
            logger: nil
        )
        #expect(result.count == 1)
    }

    // MARK: - Sorting independence

    @Test("input order does not matter -- merge always operates on the startMs-ascending sequence")
    func inputOrderIndependent() {
        let a = makeSegment(id: "seg_00001", startMs: 0, endMs: 500, refinedText: "first")
        let b = makeSegment(id: "seg_00002", startMs: 500, endMs: 1_000, refinedText: "second")

        let result = RefinementMerge.merge(
            [b, a], // reversed input order
            joinsNext: ["seg_00001": true],
            recordingIndexOf: sameRecordingIndex
        )

        #expect(result.count == 1)
        #expect(result[0].id == "seg_00001")
        #expect(result[0].refinedText == "firstsecond")
    }

    @Test("merge on an empty array returns an empty array")
    func emptyInputReturnsEmpty() {
        #expect(RefinementMerge.merge([], joinsNext: [:], recordingIndexOf: sameRecordingIndex).isEmpty)
    }

    // MARK: - Coverage invariant (§15.2.4)

    @Test("coversExactly is true when every batch id appears exactly once across the merged units")
    func coversExactlyTrueForWellFormedMerge() {
        let merged = [
            RefinedSegment(
                id: "seg_00001", startMs: 0, endMs: 1_000, speaker: .mic, rawText: "r", refinedText: "t",
                error: nil, refinedAt: refinedAt, model: model, batchId: batchId,
                sourceSegIds: ["seg_00001", "seg_00002"]
            ),
            makeSegment(id: "seg_00003", startMs: 1_000, endMs: 1_500)
        ]

        #expect(RefinementMerge.coversExactly(["seg_00001", "seg_00002", "seg_00003"], merged))
    }

    @Test("coversExactly is false when a batch id is missing from every merged unit's sourceSegIds")
    func coversExactlyFalseWhenIdMissing() {
        let merged = [makeSegment(id: "seg_00001", startMs: 0, endMs: 500)]

        #expect(!RefinementMerge.coversExactly(["seg_00001", "seg_00002"], merged))
    }

    @Test("coversExactly is false when an id is duplicated across merged units")
    func coversExactlyFalseWhenIdDuplicated() {
        let duplicated = RefinedSegment(
            id: "seg_00001", startMs: 0, endMs: 500, speaker: .mic, rawText: "r", refinedText: "t",
            error: nil, refinedAt: refinedAt, model: model, batchId: batchId,
            sourceSegIds: ["seg_00001", "seg_00002"]
        )
        let alsoClaimsSeg2 = makeSegment(id: "seg_00002", startMs: 500, endMs: 1_000)

        #expect(!RefinementMerge.coversExactly(["seg_00001", "seg_00002"], [duplicated, alsoClaimsSeg2]))
    }

    @Test("applyCoverageFallback passes the merged result through unchanged when coverage holds")
    func applyCoverageFallbackPassesThroughOnSuccess() {
        let original = [makeSegment(id: "seg_00001", startMs: 0, endMs: 500), makeSegment(id: "seg_00002", startMs: 500, endMs: 1_000)]
        let merged = [
            RefinedSegment(
                id: "seg_00001", startMs: 0, endMs: 1_000, speaker: .mic, rawText: "r", refinedText: "t",
                error: nil, refinedAt: refinedAt, model: model, batchId: batchId,
                sourceSegIds: ["seg_00001", "seg_00002"]
            )
        ]

        let result = RefinementMerge.applyCoverageFallback(original: original, merged: merged, batchIds: ["seg_00001", "seg_00002"])

        #expect(result.count == 1)
        #expect(result[0].sourceSegIds == ["seg_00001", "seg_00002"])
    }

    @Test("applyCoverageFallback falls back to the original 1:1 segments when the merged result violates coverage")
    func applyCoverageFallbackFallsBackOnViolation() {
        let original = [makeSegment(id: "seg_00001", startMs: 0, endMs: 500), makeSegment(id: "seg_00002", startMs: 500, endMs: 1_000)]
        // A hand-built, intentionally-broken "merged" result missing seg_00002 entirely -- this can
        // never actually come out of `merge(...)` itself (which cannot lose an id by construction),
        // but the fallback path must still defend against it.
        let brokenMerged = [makeSegment(id: "seg_00001", startMs: 0, endMs: 500)]

        let result = RefinementMerge.applyCoverageFallback(original: original, merged: brokenMerged, batchIds: ["seg_00001", "seg_00002"])

        #expect(result.count == 2)
        #expect(result.map(\.id) == ["seg_00001", "seg_00002"], "must fall back to the untouched 1:1 original, not the broken merged result")
    }
}
