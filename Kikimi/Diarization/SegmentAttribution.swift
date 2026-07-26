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
        guard trimmed.end > trimmed.start else {
            return []
        }

        var overlapBySlot: [String: Int] = [:]
        for turn in turns {
            let overlap = overlapMs(trimmed.start, trimmed.end, turn.startMs, turn.endMs)
            guard overlap > 0 else {
                continue
            }
            overlapBySlot[turn.slot, default: 0] += overlap
        }

        return overlapBySlot
            .map { SlotOccupancy(slot: $0.key, overlapMs: $0.value) }
            .sorted { lhs, rhs in
                lhs.overlapMs != rhs.overlapMs ? lhs.overlapMs > rhs.overlapMs : lhs.slot < rhs.slot
            }
    }

    /// Derives the full attribution for one segment (design section 5.3): the display label (rules
    /// 1-3, evaluated in order and mutually exclusive) plus the orthogonal `hasOverlapMarker`.
    static func attribute(startMs: Int, endMs: Int, turns: [DiarizationTurn]) -> SegmentAttributionResult {
        let trimmed = trimmedRange(startMs: startMs, endMs: endMs)
        let occupancies = computeOccupancies(startMs: startMs, endMs: endMs, turns: turns)
        let hasOverlapMarker = computeHasOverlapMarker(trimmedRange: trimmed, turns: turns)

        // Denominator: total time within the trimmed range covered by *any* turn (a union, not a
        // sum -- summing would double-count time where multiple slots' turns overlap each other,
        // design section 5.2 "占有率の分母は「いずれかの turn と重複した時間の合計」").
        let denominatorMs = unionOverlapMs(trimmedRange: trimmed, turns: turns)

        guard denominatorMs > 0, let primary = occupancies.first else {
            // Rule 1: nothing overlaps at all.
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

    /// Total duration covered by the union of `clippedIntervals(...)`, ignoring which slot each
    /// interval belongs to (i.e. overlapping turns from different slots are not double-counted).
    private static func unionOverlapMs(trimmedRange: (start: Int, end: Int), turns: [DiarizationTurn]) -> Int {
        let intervals = clippedIntervals(trimmedRange: trimmedRange, turns: turns).map { ($0.start, $0.end) }
        guard !intervals.isEmpty else {
            return 0
        }
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var total = 0
        var currentStart = sorted[0].0
        var currentEnd = sorted[0].1
        for interval in sorted.dropFirst() {
            if interval.0 > currentEnd {
                total += currentEnd - currentStart
                currentStart = interval.0
                currentEnd = interval.1
            } else {
                currentEnd = max(currentEnd, interval.1)
            }
        }
        total += currentEnd - currentStart
        return total
    }

    /// `true` once the fraction of the trimmed range covered by two-or-more *distinct* slots'
    /// turns simultaneously reaches `AttributionTuning.overlapMarkerThreshold`. Uses a breakpoint
    /// sweep (turn count per segment is tiny, so this stays simple rather than a proper interval
    /// tree) so that a same-slot turn touching itself never counts as an overlap.
    private static func computeHasOverlapMarker(trimmedRange: (start: Int, end: Int), turns: [DiarizationTurn]) -> Bool {
        let rangeLength = trimmedRange.end - trimmedRange.start
        guard rangeLength > 0 else {
            return false
        }
        let intervals = clippedIntervals(trimmedRange: trimmedRange, turns: turns)
        guard intervals.count >= 2 else {
            return false
        }

        var boundaries = Set<Int>()
        for interval in intervals {
            boundaries.insert(interval.start)
            boundaries.insert(interval.end)
        }
        let sortedBoundaries = boundaries.sorted()
        guard sortedBoundaries.count >= 2 else {
            return false
        }

        var multiSlotMs = 0
        for index in 0..<(sortedBoundaries.count - 1) {
            let segmentStart = sortedBoundaries[index]
            let segmentEnd = sortedBoundaries[index + 1]
            guard segmentEnd > segmentStart else {
                continue
            }
            let midpoint = segmentStart + (segmentEnd - segmentStart) / 2
            let activeSlots = Set(
                intervals
                    .filter { $0.start <= midpoint && midpoint < $0.end }
                    .map(\.slot)
            )
            if activeSlots.count >= 2 {
                multiSlotMs += segmentEnd - segmentStart
            }
        }

        return Double(multiSlotMs) / Double(rangeLength) >= AttributionTuning.overlapMarkerThreshold
    }
}
