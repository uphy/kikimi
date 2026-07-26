import Foundation

// MARK: - TranscriptRowViewModel

/// One row of the Transcript tab's time-ordered segment list. See
/// `docs/design/06-ui-panels.md` section 6.3 and kikimi.md 10 章 ("セグメントリスト（時系列）").
///
/// `speaker` reuses `AudioSourceKind` (`Kikimi/AudioCapture/AudioCaptureTypes.swift`), the same
/// physical-source attribution used by `TranscriptSegment` (`Kikimi/SessionStore/SessionModels.swift`).
struct TranscriptRowViewModel: Identifiable, Equatable {
    /// `TranscriptSegment.id` ("seg_" + 5-digit zero-padded sequence number). Assigned in
    /// insertion order, which does **not** match time order — see `startMs`.
    var id: String
    /// Milliseconds elapsed since session start. This, not `id`, is the field to sort/display by
    /// (kikimi.md 6 章: "`id` は投入順に採番されるので、時系列とはズレる可能性がある（時系列参照は
    /// 必ず `start_ms` を使う）").
    var startMs: Int
    /// Milliseconds elapsed since session start.
    var endMs: Int
    var speaker: AudioSourceKind
    /// Raw sherpa-onnx output (no trailing newline).
    var rawText: String
    var state: TranscriptRowState
}

// MARK: - TranscriptRowState

/// Rendering state of a `TranscriptRowViewModel`. See `docs/design/06-ui-panels.md` section 6.3.
///
/// Phase 1 only ever reaches `.raw` — refinement (`03-refinement-batch.md`) does not exist yet, so
/// `.refining`/`.refined`/`.refinedFailed` are forward-looking extension points wired in Phase 2.
enum TranscriptRowState: Equatable {
    /// Raw transcription, not yet refined. Rendered in light gray (kikimi.md 10 章).
    case raw
    /// Phase 2+: queued for refinement. Rendered with a "🔄" marker.
    case refining
    /// Phase 2+: refinement succeeded. Associated value is the refined text; rendered in normal color.
    /// An empty string means the LLM judged the segment meaningless (filler-only) and dropped it
    /// (kikimi.md 7 章の整形ルール) -- see `isDroppedByRefinement`.
    case refined(String)
    /// Phase 2+: refinement failed. Associated value is the error message; UI falls back to
    /// displaying `rawText` (kikimi.md 8.5 章: 整形失敗は raw_text にフォールバック).
    case refinedFailed(String)
    /// `docs/design/03-refinement-batch.md` §15.2.6: this row's raw segment was folded into an
    /// earlier row's merged derived unit by `RefinementMerge`'s deterministic merge gate.
    /// `leaderId` names the row (`TranscriptRowViewModel.id`) that actually renders the merged
    /// text -- this row itself is never independently rendered (`TranscriptTabView` skips it, the
    /// same shape as `isDroppedByRefinement`'s hidden rows, but for a different reason: absorbed
    /// into a leader row rather than intentionally deleted).
    case mergedInto(leaderId: String)

    /// `true` when refinement intentionally dropped this segment as meaningless
    /// (`refined_text: ""`). Such rows are hidden from the Transcript tab rather than rendered as
    /// blank lines. Distinct from `.refinedFailed` (which falls back to `rawText`) and from
    /// `.mergedInto` (which has a leader row elsewhere showing its content).
    var isDroppedByRefinement: Bool {
        if case .refined(let text) = self { return text.isEmpty }
        return false
    }

    /// `true` for `.mergedInto` -- never independently rendered (§15.2.6). Distinct from
    /// `isDroppedByRefinement`: a merged-away row's content lives on its leader row, while a
    /// dropped row's content is gone entirely.
    var isMergedAway: Bool {
        if case .mergedInto = self { return true }
        return false
    }
}

// MARK: - TranscriptRowList

/// Pure, side-effect-free helpers for maintaining the Transcript tab's time-ordered row list. See
/// `docs/design/06-ui-panels.md` section 6.3 and section 12 (these are unit-tested as layer 1
/// per docs/development-process.md 2.9). Independent of any networking/actor/UI concern by design, so it can be
/// exercised directly from `KikimiTests` without spinning up `TranscriptPipeline` or `SessionHandle`.
enum TranscriptRowList {
    /// Inserts `row` into `rows` at the position that keeps the list sorted by `startMs` ascending,
    /// breaking ties by `id` ascending (kikimi.md 6 章: mic/system の2ストリームを時系列マージした
    /// もの。`id` は投入順で時系列と食い違うため並び順の根拠には使わない、が同値タイの安定化には使う).
    ///
    /// This performs a stable insertion: `row` is placed immediately before the first existing
    /// element that sorts strictly after it, so rows that are equal under the sort key retain their
    /// relative arrival order except where `row` itself introduces a new tie-break position.
    static func inserted(_ row: TranscriptRowViewModel, into rows: [TranscriptRowViewModel]) -> [TranscriptRowViewModel] {
        let insertionIndex = rows.firstIndex { existing in
            isOrderedBefore(row, existing)
        } ?? rows.count

        var result = rows
        result.insert(row, at: insertionIndex)
        return result
    }

    /// `true` when `lhs` sorts strictly before `rhs` under the `startMs` asc / `id` asc ordering.
    private static func isOrderedBefore(_ lhs: TranscriptRowViewModel, _ rhs: TranscriptRowViewModel) -> Bool {
        if lhs.startMs != rhs.startMs {
            return lhs.startMs < rhs.startMs
        }
        return lhs.id < rhs.id
    }
}
