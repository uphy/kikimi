import Foundation

// MARK: - AttributableSegment

/// A lightweight time-range reference to one transcript segment (`TranscriptRowViewModel.id`/`startMs`/
/// `endMs`), used wherever a pure diarization function needs to classify a segment's speaker
/// attribution (`SegmentAttribution.attribute(startMs:endMs:turns:)`) without depending on the full
/// view-model row type (or its `speaker`/`rawText`/`state` fields, irrelevant here). Shared by
/// `OverrideEnrollmentSampleResolver` and `DisputedSlotDetector`
/// (`docs/design/20-voiceprint-misassignment-mitigation.md` sections 5.3/6.1), both of which only ever
/// need a segment's id/time-range to look up its `.single`/`.mixed`/`.unattributed` classification.
struct AttributableSegment: Sendable, Equatable {
    let id: String
    let startMs: Int
    let endMs: Int
}

// MARK: - SlotOccupancy

/// One slot's total overlap (in milliseconds) with a `TranscriptSegment`'s trimmed central range.
/// See `docs/design/13-speaker-diarization.md` section 5.2. Never persisted -- this is a
/// display-time derived value, recomputed whenever new `DiarizationTurn`s arrive.
struct SlotOccupancy: Sendable, Equatable {
    let slot: String
    let overlapMs: Int
}

// MARK: - SegmentSpeakerLabel

/// The speaker label a `TranscriptSegment` should render as, derived from `SlotOccupancy` (design
/// section 5.3). This is a display-time derivation, not a persisted value: renaming a slot or a new
/// `DiarizationTurn` arriving both trigger recomputation, never a rewrite of stored data.
enum SegmentSpeakerLabel: Equatable {
    /// No `DiarizationTurn` overlaps the segment's trimmed central range at all (design section 5.3
    /// rule 1). Callers apply `AttributionTuning.unattributedGraceMs` on top of this to decide
    /// between "(認識中…)" and "Speaker ?" -- this pure layer only reports the underlying fact.
    case unattributed
    /// One slot dominates the segment (design section 5.3 rule 3).
    case single(slot: String)
    /// The second-most-occupying slot clears `AttributionTuning.secondSpeakerMixedThreshold` (design
    /// section 5.3 rule 2). `primary` is the top-occupying slot, `secondary` the runner-up.
    case mixed(primary: String, secondary: String)
}

// MARK: - SegmentAttributionResult

/// Everything `SegmentAttribution.attribute(...)` derives for one `TranscriptSegment`.
struct SegmentAttributionResult: Equatable {
    let label: SegmentSpeakerLabel
    /// Simultaneous-speech marker (design section 5.3): orthogonal to `label` -- it can be `true`
    /// alongside `.single`, `.mixed`, or (in principle) `.unattributed`.
    let hasOverlapMarker: Bool
    /// The full per-slot occupancy breakdown `label` was derived from, exposed for UI/debugging
    /// (e.g. tooltips showing the raw split) without recomputing it.
    let occupancies: [SlotOccupancy]
}

// MARK: - AttributionTuning

/// Tuning constants for segment-to-speaker attribution (design section 5.3). Deliberately not
/// exposed in `config.yaml` -- "実戦で調整してから公開を判断" (design section 5.3).
enum AttributionTuning {
    /// Fraction of the segment's duration trimmed off *each* end before computing occupancy, to
    /// exclude the chunk-granularity padding streaming ASR segment boundaries carry (design
    /// section 5.2).
    static let edgeTrimRatio: Double = 0.15
    /// Minimum occupancy ratio (of the union-of-any-turn-overlap denominator) the second-place slot
    /// must reach for a segment to render as `.mixed` rather than `.single` (design section 5.3
    /// rule 2).
    static let secondSpeakerMixedThreshold: Double = 0.3
    /// Minimum fraction of the trimmed central range that must be covered by two-or-more distinct
    /// slots' turns simultaneously for `hasOverlapMarker` to be `true` (design section 5.3).
    static let overlapMarkerThreshold: Double = 0.3
    /// Grace period (ms) after a segment is confirmed before an unattributed segment's display
    /// falls back from "(認識中…)" to "Speaker ?" (design section 5.3 rule 1). Not consumed by this
    /// file's pure functions -- they have no notion of wall-clock "now" -- but declared alongside
    /// the other tuning constants per the design's "定数化" instruction, for the UI layer to use.
    static let unattributedGraceMs: Int = 3000
    /// Minimum union-of-any-turn-overlap (ms) a segment needs before any slot may be named as its
    /// speaker (design section 5.3's coverage gate, 2026-08-01). Below this *and* below
    /// `shortSegmentCoverageRatio`, the segment falls through to `.unattributed` instead: a couple of
    /// hundred milliseconds of turn is exactly the phantom LS-EEND emitted before the timeline's
    /// `min_duration_on_ms` gate existed (`DiarizationConfig`), and attributing a multi-second segment
    /// from it names the wrong person with full confidence.
    static let minAttributionUnionMs: Int = 300
    /// The escape hatch that keeps genuine short segments (相槌 like 「はい」) attributable: a segment
    /// whose trimmed range is *itself* well covered by turns is attributed no matter how short it is.
    /// Only a segment failing **both** this ratio and `minAttributionUnionMs` is dropped to
    /// `.unattributed` -- the gate targets "long segment, sliver of turn", not "short segment".
    static let shortSegmentCoverageRatio: Double = 0.5
}

// MARK: - SegmentAttribution

/// Pure functions mapping a `TranscriptSegment`'s time range and the session's `DiarizationTurn`s to
/// a speaker attribution (design section 5.2/5.3). No I/O, no dependency on `SessionHandle` or the
/// diarization coordinator -- callers own reading `diarization.jsonl` and re-invoking these whenever
/// new turns are appended. `turns` may be unsorted and may contain overlapping turns from different
/// slots (simultaneous speech); both are handled here rather than assumed away by callers.
enum SegmentAttribution {
    /// Per-slot occupancy (in ms) of `turns` within the segment's trimmed central range
    /// (`[startMs, endMs]` with `AttributionTuning.edgeTrimRatio` trimmed off each end -- design
    /// section 5.2's substitute for token-level timestamps). Turns entirely outside the trimmed
    /// range, or only touching its boundary (`overlap == 0`), are excluded. Returned sorted by
    /// descending `overlapMs` (ties broken by `slot` for determinism); empty when nothing overlaps.
    static func computeOccupancies(startMs: Int, endMs: Int, turns: [DiarizationTurn]) -> [SlotOccupancy] {
        let trimmed = trimmedRange(startMs: startMs, endMs: endMs)
        let intervals = clippedIntervals(trimmedRange: trimmed, turns: turns)
        return occupancies(from: intervals)
    }

    /// Shared by `computeOccupancies(startMs:endMs:turns:)` and `attribute(startMs:endMs:turns:)` --
    /// both need the exact same per-slot sum, but `attribute` already has `clippedIntervals` computed
    /// once for its other derivations and must not re-scan the (potentially large, ever-growing --
    /// see `attribute`'s doc comment) `turns` array a second time just for this.
    private static func occupancies(from intervals: [(slot: String, start: Int, end: Int)]) -> [SlotOccupancy] {
        var overlapBySlot: [String: Int] = [:]
        for interval in intervals {
            overlapBySlot[interval.slot, default: 0] += interval.end - interval.start
        }

        return overlapBySlot
            .map { SlotOccupancy(slot: $0.key, overlapMs: $0.value) }
            .sorted { lhs, rhs in
                lhs.overlapMs != rhs.overlapMs ? lhs.overlapMs > rhs.overlapMs : lhs.slot < rhs.slot
            }
    }

    /// Derives the full attribution for one segment (design section 5.3): the display label (rules
    /// 1-3, evaluated in order and mutually exclusive) plus the orthogonal `hasOverlapMarker`.
    ///
    /// Perf note (CPU-freeze fix, see `MeetingWorkspaceViewModel+Diarization.swift`'s
    /// `recomputeSpeakerLabels()`): `turns` accumulates unboundedly for the whole recording and this
    /// is called once per row on every new turn / grace-period tick, so this function computes
    /// `clippedIntervals` (the only pass that actually scans the full `turns` array) exactly **once**
    /// and reuses it for every derivation below, instead of the three independent full scans the
    /// previous implementation did (one each for occupancies/union/overlap-marker).
    static func attribute(startMs: Int, endMs: Int, turns: [DiarizationTurn]) -> SegmentAttributionResult {
        let trimmed = trimmedRange(startMs: startMs, endMs: endMs)
        let intervals = clippedIntervals(trimmedRange: trimmed, turns: turns)
        let occupancies = occupancies(from: intervals)
        let hasOverlapMarker = computeHasOverlapMarker(rangeLength: trimmed.end - trimmed.start, intervals: intervals)

        // Denominator: total time within the trimmed range covered by *any* turn (a union, not a
        // sum -- summing would double-count time where multiple slots' turns overlap each other,
        // design section 5.2 "占有率の分母は「いずれかの turn と重複した時間の合計」").
        let denominatorMs = unionOverlapMs(intervals: intervals)

        guard denominatorMs > 0, let primary = occupancies.first else {
            // Rule 1: nothing overlaps at all.
            return SegmentAttributionResult(label: .unattributed, hasOverlapMarker: hasOverlapMarker, occupancies: occupancies)
        }

        // Rule 1b (coverage gate, design section 5.3's 2026-08-01 addition): the union is real but too
        // thin to name anyone from. `denominatorMs` being the *union* means it is also the total amount
        // of evidence this segment has; a 200ms sliver against a multi-second segment says "the diarizer
        // saw a blip somewhere in here", not "this person spoke this sentence". Both conditions must
        // fail: a short segment (相槌) whose trimmed range is mostly covered still attributes normally,
        // which is why this is an AND, not just an absolute floor. `occupancies`/`hasOverlapMarker` are
        // still reported -- callers use them as raw display/debug data regardless of the label.
        guard !isCoverageTooThin(denominatorMs: denominatorMs, trimmedLengthMs: trimmed.end - trimmed.start) else {
            return SegmentAttributionResult(label: .unattributed, hasOverlapMarker: hasOverlapMarker, occupancies: occupancies)
        }

        if occupancies.count >= 2 {
            let secondary = occupancies[1]
            let secondaryRatio = Double(secondary.overlapMs) / Double(denominatorMs)
            if secondaryRatio >= AttributionTuning.secondSpeakerMixedThreshold {
                // Rule 2: runner-up slot is substantial enough to call this mixed.
                return SegmentAttributionResult(
                    label: .mixed(primary: primary.slot, secondary: secondary.slot),
                    hasOverlapMarker: hasOverlapMarker,
                    occupancies: occupancies
                )
            }
        }

        // Rule 3: fall through to whichever slot occupies the most.
        return SegmentAttributionResult(label: .single(slot: primary.slot), hasOverlapMarker: hasOverlapMarker, occupancies: occupancies)
    }

    /// Returns the dominant slot's id when `attribute(startMs:endMs:turns:)` resolves to `.single`,
    /// `nil` for `.mixed`/`.unattributed`. Shared by `DisputedSlotDetector` and
    /// `OverrideEnrollmentSampleResolver` (`docs/design/20-voiceprint-misassignment-mitigation.md`
    /// section 6.1: "5.3 節の M2 サンプル採用規則と同じ基準" -- both call sites must apply exactly the same
    /// `.single`-only adoption rule, so this is the one place that rule lives).
    static func singleDominantSlot(startMs: Int, endMs: Int, turns: [DiarizationTurn]) -> String? {
        guard case .single(let slot) = attribute(startMs: startMs, endMs: endMs, turns: turns).label else {
            return nil
        }
        return slot
    }

    // MARK: Private helpers

    /// `true` when the turn coverage backing a segment is too thin to name a speaker from: the union
    /// is under `AttributionTuning.minAttributionUnionMs` **and** covers under
    /// `AttributionTuning.shortSegmentCoverageRatio` of the trimmed range. A `trimmedLengthMs <= 0`
    /// range (a zero-or-negative-length segment) can only be reached with `denominatorMs == 0`, which
    /// `attribute(...)` already returned `.unattributed` for, so it is treated as "not thin" here rather
    /// than dividing by zero.
    private static func isCoverageTooThin(denominatorMs: Int, trimmedLengthMs: Int) -> Bool {
        guard denominatorMs < AttributionTuning.minAttributionUnionMs, trimmedLengthMs > 0 else {
            return false
        }
        let coverageRatio = Double(denominatorMs) / Double(trimmedLengthMs)
        return coverageRatio < AttributionTuning.shortSegmentCoverageRatio
    }

    /// The segment's central range after trimming `AttributionTuning.edgeTrimRatio` off each end.
    /// For any `endMs > startMs`, `2 * edgeTrimRatio < 1` guarantees `end > start` (never inverted).
    private static func trimmedRange(startMs: Int, endMs: Int) -> (start: Int, end: Int) {
        let length = endMs - startMs
        guard length > 0 else {
            return (startMs, endMs)
        }
        let trim = Int((Double(length) * AttributionTuning.edgeTrimRatio).rounded())
        return (startMs + trim, endMs - trim)
    }

    /// Overlap (ms) between two closed-open-ish integer ranges, clamped to `0` (touching at a shared
    /// boundary, e.g. `aEnd == bStart`, yields `0`, not a negative or off-by-one value).
    private static func overlapMs(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int) -> Int {
        max(0, min(aEnd, bEnd) - max(aStart, bStart))
    }

    /// Every turn clipped to `trimmedRange`, dropping turns that don't overlap it at all.
    private static func clippedIntervals(
        trimmedRange: (start: Int, end: Int),
        turns: [DiarizationTurn]
    ) -> [(slot: String, start: Int, end: Int)] {
        turns.compactMap { turn in
            let start = max(trimmedRange.start, turn.startMs)
            let end = min(trimmedRange.end, turn.endMs)
            guard end > start else {
                return nil
            }
            return (turn.slot, start, end)
        }
    }

    /// Total duration covered by the union of `intervals` (already `clippedIntervals(...)`'s output),
    /// ignoring which slot each interval belongs to (i.e. overlapping turns from different slots are
    /// not double-counted). Takes the pre-clipped intervals rather than `turns` directly -- see
    /// `attribute(startMs:endMs:turns:)`'s perf note.
    private static func unionOverlapMs(intervals: [(slot: String, start: Int, end: Int)]) -> Int {
        guard !intervals.isEmpty else {
            return 0
        }
        let sorted = intervals.sorted { $0.start < $1.start }
        var total = 0
        var currentStart = sorted[0].start
        var currentEnd = sorted[0].end
        for interval in sorted.dropFirst() {
            if interval.start > currentEnd {
                total += currentEnd - currentStart
                currentStart = interval.start
                currentEnd = interval.end
            } else {
                currentEnd = max(currentEnd, interval.end)
            }
        }
        total += currentEnd - currentStart
        return total
    }

    /// One coordinate-sweep event: a slot's turn starting or ending at `position` (half-open
    /// `[start, end)`, matching `overlapMs`'s "touching boundaries never count as overlap"
    /// convention -- see `OverlapSweepEventKind`'s ordering below). File-scope (not nested inside
    /// `SegmentAttribution`) solely to keep `OverlapSweepEventKind` from nesting two levels deep,
    /// which SwiftLint's `nesting` rule flags.
    private struct OverlapSweepEvent {
        let position: Int
        let kind: OverlapSweepEventKind
        let slot: String
    }

    /// `.end` sorts before `.start` at the same `position` so a turn ending exactly where another
    /// begins is never briefly counted as both active at once (the half-open boundary convention
    /// every other helper in this file already assumes).
    private enum OverlapSweepEventKind: Int {
        case end = 0
        case start = 1
    }

    /// `true` once the fraction of the trimmed range covered by two-or-more *distinct* slots' turns
    /// simultaneously reaches `AttributionTuning.overlapMarkerThreshold`.
    ///
    /// A single coordinate-compression sweep over `intervals`' start/end events, `O(M log M)` for
    /// `M = intervals.count`: previously this re-filtered the *entire* `intervals` list once per
    /// breakpoint (`O(M^2)`), which -- combined with `turns` accumulating unboundedly for the whole
    /// recording and this whole function being re-invoked every second by the diarization label
    /// ticker (`MeetingWorkspaceViewModel+Diarization.swift`'s `startDiarizationLabelTicker()`) -- was
    /// the dominant driver of a real CPU-pinning/UI-freeze bug in long meetings. Per-slot *turn
    /// counts* (not just an active/inactive flag) are tracked so several overlapping turns from the
    /// *same* slot never toggle `distinctActiveSlots` more than once.
    private static func computeHasOverlapMarker(rangeLength: Int, intervals: [(slot: String, start: Int, end: Int)]) -> Bool {
        guard rangeLength > 0, intervals.count >= 2 else {
            return false
        }

        var events: [OverlapSweepEvent] = []
        events.reserveCapacity(intervals.count * 2)
        for interval in intervals {
            events.append(OverlapSweepEvent(position: interval.start, kind: .start, slot: interval.slot))
            events.append(OverlapSweepEvent(position: interval.end, kind: .end, slot: interval.slot))
        }
        events.sort { lhs, rhs in
            lhs.position != rhs.position ? lhs.position < rhs.position : lhs.kind.rawValue < rhs.kind.rawValue
        }

        var activeTurnCountBySlot: [String: Int] = [:]
        var distinctActiveSlots = 0
        var multiSlotMs = 0
        var previousPosition = events[0].position
        var index = 0
        while index < events.count {
            let position = events[index].position
            if distinctActiveSlots >= 2, position > previousPosition {
                multiSlotMs += position - previousPosition
            }
            while index < events.count, events[index].position == position {
                let event = events[index]
                switch event.kind {
                case .start:
                    let updatedCount = (activeTurnCountBySlot[event.slot] ?? 0) + 1
                    activeTurnCountBySlot[event.slot] = updatedCount
                    if updatedCount == 1 {
                        distinctActiveSlots += 1
                    }
                case .end:
                    let updatedCount = (activeTurnCountBySlot[event.slot] ?? 0) - 1
                    activeTurnCountBySlot[event.slot] = updatedCount
                    if updatedCount == 0 {
                        distinctActiveSlots -= 1
                    }
                }
                index += 1
            }
            previousPosition = position
        }

        return Double(multiSlotMs) / Double(rangeLength) >= AttributionTuning.overlapMarkerThreshold
    }
}
