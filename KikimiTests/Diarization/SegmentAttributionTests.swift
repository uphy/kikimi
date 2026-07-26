import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `SegmentAttribution` (`Kikimi/Diarization/SegmentAttribution.swift`,
/// `docs/design/13-speaker-diarization.md` sections 5.2/5.3). All test segments use
/// `startMs: 0, endMs: 1000` unless noted, so `AttributionTuning.edgeTrimRatio` (0.15) trims
/// `150ms` off each end, giving a trimmed central range of `[150, 850]` (length `700`) -- the
/// arithmetic every test below is worked out against that range unless stated otherwise.
@Suite("SegmentAttribution.computeOccupancies")
struct SegmentAttributionComputeOccupanciesTests {
    @Test("a single turn spanning the whole segment yields one slot at the trimmed range's full length")
    func singleSpeakerFullCoverage() {
        let occupancies = SegmentAttribution.computeOccupancies(
            startMs: 0,
            endMs: 1000,
            turns: [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1000)]
        )

        #expect(occupancies == [SlotOccupancy(slot: "spk_1", overlapMs: 700)])
    }

    @Test("a turn touching the trimmed range's boundary exactly (endMs == turn.startMs) contributes zero overlap")
    func boundaryTouchingTurnIsExcluded() {
        // spk_1 covers the whole trimmed range as a baseline; spk_3 starts exactly where the
        // trimmed range ends (850) and must not be counted at all.
        let occupancies = SegmentAttribution.computeOccupancies(
            startMs: 0,
            endMs: 1000,
            turns: [
                DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1000),
                DiarizationTurn(slot: "spk_3", startMs: 850, endMs: 1000)
            ]
        )

        #expect(occupancies == [SlotOccupancy(slot: "spk_1", overlapMs: 700)])
    }

    @Test("a turn touching the trimmed range's left boundary exactly (turn.endMs == trimmedStart) contributes zero overlap")
    func leftBoundaryTouchingTurnIsExcluded() {
        let occupancies = SegmentAttribution.computeOccupancies(
            startMs: 0,
            endMs: 1000,
            turns: [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 150)]
        )

        #expect(occupancies.isEmpty)
    }

    @Test("a turn entirely outside the segment's trimmed range is excluded")
    func turnOutsideRangeIsExcluded() {
        let occupancies = SegmentAttribution.computeOccupancies(
            startMs: 500,
            endMs: 1500,
            turns: [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 100)]
        )

        #expect(occupancies.isEmpty)
    }

    @Test("a short segment's edge trim excludes most of an edge-only turn, leaving the central turn dominant")
    func shortSegmentEdgeTrimEffect() {
        // Segment [1000, 1400] (length 400) -> trim = round(400 * 0.15) = 60 -> trimmed [1060, 1340].
        // spk_1 only reaches 90ms into the raw segment (1000-1090), of which just 30ms survives
        // trimming (1060-1090); without trimming it would have counted the full 90ms.
        let occupancies = SegmentAttribution.computeOccupancies(
            startMs: 1000,
            endMs: 1400,
            turns: [
                DiarizationTurn(slot: "spk_1", startMs: 1000, endMs: 1090),
                DiarizationTurn(slot: "spk_2", startMs: 1150, endMs: 1340)
            ]
        )

        #expect(occupancies == [
            SlotOccupancy(slot: "spk_2", overlapMs: 190),
            SlotOccupancy(slot: "spk_1", overlapMs: 30)
        ])
    }

    @Test("ties in overlapMs are broken by ascending slot name for deterministic ordering")
    func tiesBrokenBySlotName() {
        let occupancies = SegmentAttribution.computeOccupancies(
            startMs: 0,
            endMs: 1000,
            turns: [
                DiarizationTurn(slot: "spk_5", startMs: 450, endMs: 650),
                DiarizationTurn(slot: "spk_2", startMs: 300, endMs: 500),
                DiarizationTurn(slot: "spk_4", startMs: 400, endMs: 600),
                DiarizationTurn(slot: "spk_3", startMs: 350, endMs: 550)
            ]
        )

        #expect(occupancies == [
            SlotOccupancy(slot: "spk_2", overlapMs: 200),
            SlotOccupancy(slot: "spk_3", overlapMs: 200),
            SlotOccupancy(slot: "spk_4", overlapMs: 200),
            SlotOccupancy(slot: "spk_5", overlapMs: 200)
        ])
    }

    @Test("turn order does not affect the result (turns are not assumed pre-sorted)")
    func unsortedTurnsGiveTheSameResult() {
        let sortedOrder = [
            DiarizationTurn(slot: "spk_1", startMs: 150, endMs: 780),
            DiarizationTurn(slot: "spk_2", startMs: 570, endMs: 850)
        ]
        let reversedOrder = Array(sortedOrder.reversed())

        let fromSorted = SegmentAttribution.computeOccupancies(startMs: 0, endMs: 1000, turns: sortedOrder)
        let fromReversed = SegmentAttribution.computeOccupancies(startMs: 0, endMs: 1000, turns: reversedOrder)

        #expect(fromSorted == fromReversed)
        #expect(fromSorted == [
            SlotOccupancy(slot: "spk_1", overlapMs: 630),
            SlotOccupancy(slot: "spk_2", overlapMs: 280)
        ])
    }
}

@Suite("SegmentAttribution.attribute")
struct SegmentAttributionAttributeTests {
    @Test("no turns overlap the segment at all -> unattributed, no overlap marker")
    func noOverlapIsUnattributed() {
        let result = SegmentAttribution.attribute(startMs: 0, endMs: 1000, turns: [])

        #expect(result == SegmentAttributionResult(label: .unattributed, hasOverlapMarker: false, occupancies: []))
    }

    @Test("turns exist but only touch the trimmed range's boundary -> still unattributed")
    func boundaryOnlyTurnsAreUnattributed() {
        let result = SegmentAttribution.attribute(
            startMs: 0,
            endMs: 1000,
            turns: [DiarizationTurn(slot: "spk_1", startMs: 850, endMs: 1000)]
        )

        #expect(result.label == .unattributed)
        #expect(result.occupancies.isEmpty)
    }

    @Test("a single dominant slot with no runner-up -> single, no overlap marker")
    func singleSpeaker() {
        let result = SegmentAttribution.attribute(
            startMs: 0,
            endMs: 1000,
            turns: [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1000)]
        )

        #expect(result == SegmentAttributionResult(
            label: .single(slot: "spk_1"),
            hasOverlapMarker: false,
            occupancies: [SlotOccupancy(slot: "spk_1", overlapMs: 700)]
        ))
    }

    @Test("second slot exactly at the 30% mixed threshold -> mixed (inclusive boundary)")
    func secondSpeakerAtMixedThresholdIsMixed() {
        // spk_1 covers the whole trimmed range (700ms, denominator 700). spk_2 is nested inside it
        // for exactly 210ms == 30% of 700.
        let result = SegmentAttribution.attribute(
            startMs: 0,
            endMs: 1000,
            turns: [
                DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1000),
                DiarizationTurn(slot: "spk_2", startMs: 150, endMs: 360)
            ]
        )

        #expect(result.label == .mixed(primary: "spk_1", secondary: "spk_2"))
    }

    @Test("second slot just below the 30% mixed threshold -> single")
    func secondSpeakerJustBelowMixedThresholdIsSingle() {
        // Same setup as the boundary test, but spk_2 is 1ms short of 210ms (209/700 ~= 29.86%).
        let result = SegmentAttribution.attribute(
            startMs: 0,
            endMs: 1000,
            turns: [
                DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1000),
                DiarizationTurn(slot: "spk_2", startMs: 150, endMs: 359)
            ]
        )

        #expect(result.label == .single(slot: "spk_1"))
    }

    @Test("overlapping turns can push the occupancy sum over 100% and still resolve to mixed")
    func overlappingTurnsExceedOneHundredPercentTotal() {
        // spk_1 [150,780] (630ms, 90% of the 700ms union) and spk_2 [570,850] (280ms, 40% of the
        // union) overlap each other for [570,780]; the union is the full trimmed range (700ms), so
        // percentages sum to 130% while each individually is computed against that same union.
        let result = SegmentAttribution.attribute(
            startMs: 0,
            endMs: 1000,
            turns: [
                DiarizationTurn(slot: "spk_1", startMs: 150, endMs: 780),
                DiarizationTurn(slot: "spk_2", startMs: 570, endMs: 850)
            ]
        )

        #expect(result.label == .mixed(primary: "spk_1", secondary: "spk_2"))
        #expect(result.occupancies == [
            SlotOccupancy(slot: "spk_1", overlapMs: 630),
            SlotOccupancy(slot: "spk_2", overlapMs: 280)
        ])
        // The two turns overlap for [570, 780] = 210ms, exactly 30% of the 700ms trimmed range.
        #expect(result.hasOverlapMarker)
    }

    @Test("adjacent (non-overlapping) turns split 50/50 resolve to mixed with no overlap marker")
    func adjacentTurnsAreMixedWithoutOverlapMarker() {
        // spk_1 [150,500] and spk_2 [500,850] never actually overlap in time (they only touch at
        // 500), but together they fully cover the union (700ms) with an even split -- demonstrating
        // hasOverlapMarker is independent of the mixed/single label.
        let result = SegmentAttribution.attribute(
            startMs: 0,
            endMs: 1000,
            turns: [
                DiarizationTurn(slot: "spk_1", startMs: 150, endMs: 500),
                DiarizationTurn(slot: "spk_2", startMs: 500, endMs: 850)
            ]
        )

        #expect(result.label == .mixed(primary: "spk_1", secondary: "spk_2"))
        #expect(!result.hasOverlapMarker)
    }

    @Test("a dominant primary with several small crosstalking secondaries stays single, but sets the overlap marker")
    func dominantPrimaryWithCrosstalkingSecondariesIsSingleWithOverlapMarker() {
        // spk_1 covers the whole trimmed range (700ms, 100%). Four secondary slots each occupy
        // 200ms (28.57% individually, all below the 30% mixed threshold) but chain-overlap each
        // other across [350, 600], which totals 250ms (35.7% of 700ms) of two-or-more-slots-active
        // time -- enough to set hasOverlapMarker despite no single secondary reaching mixed.
        let result = SegmentAttribution.attribute(
            startMs: 0,
            endMs: 1000,
            turns: [
                DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1000),
                DiarizationTurn(slot: "spk_2", startMs: 300, endMs: 500),
                DiarizationTurn(slot: "spk_3", startMs: 350, endMs: 550),
                DiarizationTurn(slot: "spk_4", startMs: 400, endMs: 600),
                DiarizationTurn(slot: "spk_5", startMs: 450, endMs: 650)
            ]
        )

        #expect(result.label == .single(slot: "spk_1"))
        #expect(result.hasOverlapMarker)
    }

    @Test("a short segment's edge trim changes which slot dominates versus using the raw range")
    func shortSegmentEdgeTrimAffectsAttribution() {
        // See SegmentAttributionComputeOccupanciesTests.shortSegmentEdgeTrimEffect: trimming leaves
        // spk_1 with only 30ms (of a possible 90ms raw), so spk_2 dominates.
        let result = SegmentAttribution.attribute(
            startMs: 1000,
            endMs: 1400,
            turns: [
                DiarizationTurn(slot: "spk_1", startMs: 1000, endMs: 1090),
                DiarizationTurn(slot: "spk_2", startMs: 1150, endMs: 1340)
            ]
        )

        #expect(result.label == .single(slot: "spk_2"))
    }

    @Test("turn order does not affect the derived attribution")
    func unsortedTurnsGiveTheSameAttribution() {
        let turnsInOrder = [
            DiarizationTurn(slot: "spk_1", startMs: 150, endMs: 780),
            DiarizationTurn(slot: "spk_2", startMs: 570, endMs: 850)
        ]

        let fromInOrder = SegmentAttribution.attribute(startMs: 0, endMs: 1000, turns: turnsInOrder)
        let fromReversed = SegmentAttribution.attribute(startMs: 0, endMs: 1000, turns: Array(turnsInOrder.reversed()))

        #expect(fromInOrder == fromReversed)
    }
}
