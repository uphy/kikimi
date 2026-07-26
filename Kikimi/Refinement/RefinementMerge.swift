import Foundation
import OSLog

// MARK: - RefinementMerge

/// 段階1 の決定論的 merge ゲート（`docs/design/03-refinement-batch.md` §15.2.3/§15.2.4）: LLM は
/// `joins_next: Bool` のヒントだけを返し、実際に隣接セグメントを1つの派生単位へ畳み込むかどうかは
/// すべて Kikimi 側がここで判断する。`RefinementQueue+BatchProcessing.swift` が
/// `RefinementValidator.validate(...)` の直後・`appendRefinedSegment` の直前に一度だけ呼ぶ。
///
/// Pure: no file I/O, no `Date()`. Split (not `RefinementValidator`'s own scope) because merge is a
/// distinct pipeline stage per §15.2.3's "検証後 / 追記前" framing, and because unit tests want to
/// exercise the gate/coverage-fallback logic independently of `RefinementValidator`'s own id-matching
/// rules.
enum RefinementMerge {
    /// Walks `segments` in `startMs` ascending order (ties broken by `id`, matching every other
    /// chronological sort in this codebase -- e.g. `TranscriptRowList.inserted`) and folds an
    /// adjacent pair `(current, next)` into `current` whenever every §15.2.3 guard holds. Folding
    /// repeats for chains of 3+ (the newly-folded `current` is immediately re-evaluated against the
    /// following segment).
    ///
    /// Sorting first (rather than trusting caller order) is what makes "A の直後が B" -- the §15.2.3
    /// guard that no other segment, same-stream or not, sits between the two being considered --
    /// structural: two elements are only ever compared here if they are literally adjacent in the
    /// full, both-streams-merged, `startMs`-ordered sequence.
    ///
    /// - Parameters:
    ///   - segments: One batch's already-validated, still-1:1 `RefinedSegment`s (`RefinementValidator`
    ///     always produces exactly one per input `TranscriptSegment`, success or failure alike --
    ///     §5.1). Untouched (returned as a single-element result each) if merge never applies.
    ///   - joinsNext: `response.segments`' `id -> joinsNext` map (§15.2.2), keyed by each *original*
    ///     raw `seg_id` -- looked up by a chain's own tail id (`sourceSegIds.last`), never by a
    ///     possibly-already-merged unit's leading `id`, so a 3+ chain's continuation decision always
    ///     reflects the segment actually adjacent to the next candidate. An id absent from this map
    ///     (e.g. `RefinementValidator`'s "missing from LLM response" row, which never got a
    ///     `RefinementResponse.Item` at all) is treated as `false`.
    ///   - recordingIndexOf: Resolves a cumulative-timeline `startMs` to its owning recording segment
    ///     index (`SessionMeta.recordingIndex(atStartMs:)`), injected so this stays a pure function
    ///     independent of `SessionHandle`/actor isolation.
    ///   - logger: Optional; when a batch's chronologically-last segment still wants to continue
    ///     (`joinsNext == true`) past the batch boundary, §15.2.3 requires logging that fact (segment
    ///     re-cutting 段階2's pending-tail decision material) even though 段階1 never merges across
    ///     batches.
    static func merge(
        _ segments: [RefinedSegment],
        joinsNext: [String: Bool],
        recordingIndexOf: (Int) -> Int,
        logger: Logger? = nil
    ) -> [RefinedSegment] {
        guard !segments.isEmpty else { return [] }

        let sorted = segments.sorted { lhs, rhs in
            lhs.startMs != rhs.startMs ? lhs.startMs < rhs.startMs : lhs.id < rhs.id
        }

        var result: [RefinedSegment] = []
        result.reserveCapacity(sorted.count)
        var current = sorted[0]
        for next in sorted.dropFirst() {
            if canMerge(current, next, joinsNext: joinsNext, recordingIndexOf: recordingIndexOf) {
                current = merged(current, next)
            } else {
                result.append(current)
                current = next
            }
        }

        let tailId = current.sourceSegIds.last ?? current.id
        if joinsNext[tailId] == true {
            logger?.info("batch-boundary joins_next dropped: \(tailId, privacy: .public)")
        }
        result.append(current)
        return result
    }

    /// §15.2.3's full guard table for folding `next` into `current`:
    /// - `current`'s own tail segment's `joinsNext` hint must be `true`.
    /// - Same `speaker` (mic/system never merge across streams).
    /// - Same recording index (a paused/resumed session's STT is flushed + fresh-started per segment,
    ///   kikimi.md 6 章 -- merging across that boundary would also break single-WAV playback).
    /// - Neither side is the empty-string "intentionally deleted" marker (§5.1) -- `current` must not
    ///   already be one (nothing meaningful to extend), and `next` must not be one either (nothing
    ///   meaningful to absorb). Also rejects a `nil` (failed) `refinedText` on either side: there is
    ///   no text to concatenate, and a failed segment never legitimately carries `joinsNext == true`
    ///   in practice (`RefinementValidator`'s "missing from response" row has no
    ///   `RefinementResponse.Item` to source a `true` hint from at all).
    private static func canMerge(
        _ current: RefinedSegment,
        _ next: RefinedSegment,
        joinsNext: [String: Bool],
        recordingIndexOf: (Int) -> Int
    ) -> Bool {
        guard let tailId = current.sourceSegIds.last, joinsNext[tailId] == true else { return false }
        guard current.speaker == next.speaker else { return false }
        guard recordingIndexOf(current.startMs) == recordingIndexOf(next.startMs) else { return false }
        guard let currentText = current.refinedText, !currentText.isEmpty else { return false }
        guard let nextText = next.refinedText, !nextText.isEmpty else { return false }
        return true
    }

    /// Folds `next` into `current` (§15.2.3): `sourceSegIds` concatenates (`current`'s come first,
    /// chronologically earlier per the caller's sort), `endMs` advances to `next`'s, and `rawText`/
    /// `refinedText` concatenate verbatim with no separator ("「」なしで連結"). `startMs`/`id`/
    /// `speaker`/`refinedAt`/`model`/`batchId` all stay `current`'s (the leading segment's) own
    /// values.
    private static func merged(_ current: RefinedSegment, _ next: RefinedSegment) -> RefinedSegment {
        var result = current
        result.sourceSegIds = current.sourceSegIds + next.sourceSegIds
        result.endMs = next.endMs
        result.rawText = current.rawText + next.rawText
        result.refinedText = (current.refinedText ?? "") + (next.refinedText ?? "")
        return result
    }

    // MARK: - §15.2.4 coverage invariant

    /// `true` iff every id in `batchIds` appears in exactly one element of `merged`'s `sourceSegIds`
    /// (no id lost, none duplicated). Pure and independent of `merge(...)` itself, so a hand-built
    /// fixture can exercise both the pass and violation cases without needing to reproduce an
    /// (in-practice-impossible, since `merge(...)` cannot itself lose or duplicate an id) violation
    /// through the real gate.
    static func coversExactly(_ batchIds: [String], _ merged: [RefinedSegment]) -> Bool {
        let covered = merged.flatMap(\.sourceSegIds)
        return covered.count == batchIds.count && Set(covered) == Set(batchIds)
    }

    /// §15.2.4's fallback: returns `merged` unchanged when it covers `batchIds` exactly, otherwise
    /// logs a warning and returns `original` (the still-1:1 segments merge was never applied to) so
    /// this batch degrades to the safe, pre-段階1 behavior instead of ever risking a lost/duplicated
    /// `seg_id` in `refined.jsonl`.
    static func applyCoverageFallback(
        original: [RefinedSegment],
        merged: [RefinedSegment],
        batchIds: [String],
        logger: Logger? = nil
    ) -> [RefinedSegment] {
        guard coversExactly(batchIds, merged) else {
            logger?.warning(
                "Refinement merge coverage check failed for this batch (lost or duplicated a seg_id); falling back to unmerged 1:1 segments."
            )
            return original
        }
        return merged
    }
}
