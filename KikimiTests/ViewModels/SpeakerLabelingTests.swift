import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `SpeakerLabelResolver` (`Kikimi/ViewModels/SpeakerLabeling.swift`,
/// `docs/design/13-speaker-diarization.md` sections 5.3/6.1). All test segments use
/// `startMs: 0, endMs: 1000` unless noted -- see `SegmentAttributionTests.swift`'s own doc comment
/// for the trimmed-range arithmetic (`[150, 850]`) this inherits from `SegmentAttribution`.
@Suite("SpeakerLabelResolver.isWithinActiveRange")
struct SpeakerLabelResolverIsWithinActiveRangeTests {
    @Test("a segment fully inside a closed active range is within range")
    func fullyInsideClosedRange() {
        #expect(SpeakerLabelResolver.isWithinActiveRange(
            startMs: 100, endMs: 200,
            activeRanges: [DiarizationActiveRange(startMs: 0, endMs: 1_000)]
        ))
    }

    @Test("a segment entirely before an active range's start is not within range")
    func entirelyBeforeRange() {
        #expect(!SpeakerLabelResolver.isWithinActiveRange(
            startMs: 0, endMs: 50,
            activeRanges: [DiarizationActiveRange(startMs: 100, endMs: 200)]
        ))
    }

    @Test("a segment entirely after a closed active range's end is not within range")
    func entirelyAfterClosedRange() {
        #expect(!SpeakerLabelResolver.isWithinActiveRange(
            startMs: 300, endMs: 400,
            activeRanges: [DiarizationActiveRange(startMs: 100, endMs: 200)]
        ))
    }

    @Test("an open-ended active range (endMs == nil, still-recording segment) extends to Int.max")
    func openEndedRangeExtendsToInfinity() {
        #expect(SpeakerLabelResolver.isWithinActiveRange(
            startMs: 1_000_000, endMs: 1_000_100,
            activeRanges: [DiarizationActiveRange(startMs: 0, endMs: nil)]
        ))
    }

    @Test("no active ranges at all is never within range")
    func emptyRangesNeverMatch() {
        #expect(!SpeakerLabelResolver.isWithinActiveRange(startMs: 0, endMs: 100, activeRanges: []))
    }

    @Test("a segment overlapping the second of several ranges is within range")
    func overlapsSecondOfSeveralRanges() {
        #expect(SpeakerLabelResolver.isWithinActiveRange(
            startMs: 250, endMs: 260,
            activeRanges: [
                DiarizationActiveRange(startMs: 0, endMs: 100),
                DiarizationActiveRange(startMs: 200, endMs: 300)
            ]
        ))
    }
}

@Suite("SpeakerLabelResolver.resolve")
struct SpeakerLabelResolverResolveTests {
    private let fullRange = [DiarizationActiveRange(startMs: 0, endMs: nil)]
    private let epoch = Date(timeIntervalSince1970: 0)

    @Test("outside every active range resolves to .systemFallback regardless of turns/assignments")
    func outsideActiveRangeIsSystemFallback() {
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1_000)],
            activeRanges: [DiarizationActiveRange(startMs: 2_000, endMs: 3_000)],
            assignments: SpeakerAssignments(assignments: ["spk_1": SlotAssignment(displayName: "田中さん")]),
            confirmedAt: epoch,
            now: epoch
        )
        #expect(result == .systemFallback)
    }

    @Test("no active ranges at all resolves to .systemFallback (design section 5.3's precondition)")
    func noActiveRangesIsSystemFallback() {
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [],
            activeRanges: [],
            assignments: SpeakerAssignments(),
            confirmedAt: epoch,
            now: epoch
        )
        #expect(result == .systemFallback)
    }

    @Test("a per-segment override wins over the slot-derived label (design section 6.1 \"この発言だけ\")")
    func segmentOverrideWinsOverSlotLabel() {
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1_000)],
            activeRanges: fullRange,
            assignments: SpeakerAssignments(assignments: ["spk_1": SlotAssignment(displayName: "田中さん")]),
            override: SegmentSpeakerOverride(displayName: "佐藤さん"),
            confirmedAt: epoch,
            now: epoch
        )
        #expect(result.label == .named("佐藤さん"))
        #expect(result.isSegmentOverride)
    }

    @Test("a per-segment override applies even outside every active range (explicit user knowledge beats the precondition)")
    func segmentOverrideAppliesOutsideActiveRange() {
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [],
            activeRanges: [],
            assignments: SpeakerAssignments(),
            override: SegmentSpeakerOverride(displayName: "佐藤さん"),
            confirmedAt: epoch,
            now: epoch
        )
        #expect(result.label == .named("佐藤さん"))
        #expect(result.isSegmentOverride)
        #expect(!result.hasOverlapMarker)
    }

    @Test("a per-segment override names an otherwise-unattributed (\"Speaker ?\") row")
    func segmentOverrideNamesUnattributedRow() {
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [],
            activeRanges: fullRange,
            assignments: SpeakerAssignments(),
            override: SegmentSpeakerOverride(displayName: "佐藤さん"),
            confirmedAt: epoch,
            now: epoch.addingTimeInterval(10)
        )
        #expect(result.label == .named("佐藤さん"))
    }

    @Test("the overlap marker stays orthogonal to a per-segment override (design section 5.3)")
    func segmentOverrideKeepsOverlapMarker() {
        // Two slots simultaneously active across the whole trimmed range -> marker on.
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [
                DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1_000),
                DiarizationTurn(slot: "spk_2", startMs: 0, endMs: 1_000),
            ],
            activeRanges: fullRange,
            assignments: SpeakerAssignments(),
            override: SegmentSpeakerOverride(displayName: "佐藤さん"),
            confirmedAt: epoch,
            now: epoch
        )
        #expect(result.label == .named("佐藤さん"))
        #expect(result.hasOverlapMarker)
    }

    @Test("unattributed within the grace period is .recognizing")
    func unattributedWithinGraceIsRecognizing() {
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [],
            activeRanges: fullRange,
            assignments: SpeakerAssignments(),
            confirmedAt: epoch,
            now: epoch.addingTimeInterval(1.0),
            unattributedGraceMs: 3_000
        )
        #expect(result.label == .recognizing)
        #expect(!result.hasOverlapMarker)
    }

    @Test("unattributed exactly at the grace boundary has already elapsed (>=, not strict less-than) and is .unknown")
    func unattributedAtGraceBoundaryIsUnknown() {
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [],
            activeRanges: fullRange,
            assignments: SpeakerAssignments(),
            confirmedAt: epoch,
            now: epoch.addingTimeInterval(3.0),
            unattributedGraceMs: 3_000
        )
        #expect(result.label == .unknown)
    }

    @Test("unattributed past the grace period is .unknown (\"Speaker ?\")")
    func unattributedPastGraceIsUnknown() {
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [],
            activeRanges: fullRange,
            assignments: SpeakerAssignments(),
            confirmedAt: epoch,
            now: epoch.addingTimeInterval(3.001),
            unattributedGraceMs: 3_000
        )
        #expect(result.label == .unknown)
    }

    @Test("a single dominant slot with no displayName resolves to .anonymous with its slot number")
    func singleDominantSlotNoNameIsAnonymous() {
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [DiarizationTurn(slot: "spk_2", startMs: 0, endMs: 1_000)],
            activeRanges: fullRange,
            assignments: SpeakerAssignments(),
            confirmedAt: epoch,
            now: epoch
        )
        #expect(result.label == .anonymous(slotNumber: 2))
        #expect(!result.hasOverlapMarker)
    }

    @Test("a single dominant slot with a displayName resolves to .named")
    func singleDominantSlotWithNameIsNamed() {
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1_000)],
            activeRanges: fullRange,
            assignments: SpeakerAssignments(assignments: ["spk_1": SlotAssignment(displayName: "田中さん")]),
            confirmedAt: epoch,
            now: epoch
        )
        #expect(result.label == .named("田中さん"))
    }

    @Test("an empty displayName is treated as absent (falls back to .anonymous)")
    func emptyDisplayNameFallsBackToAnonymous() {
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1_000)],
            activeRanges: fullRange,
            assignments: SpeakerAssignments(assignments: ["spk_1": SlotAssignment(displayName: "")]),
            confirmedAt: epoch,
            now: epoch
        )
        #expect(result.label == .anonymous(slotNumber: 1))
    }

    @Test("a mixed segment resolves both sides through assignments -- named primary, anonymous secondary")
    func mixedSegmentResolvesBothSlots() {
        // spk_1 occupies [150, 850] (700ms, the full trimmed range); spk_2 occupies [150, 550]
        // (400ms) -- 400/700 ≈ 57%, comfortably over the 30% mixed threshold.
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [
                DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1_000),
                DiarizationTurn(slot: "spk_2", startMs: 0, endMs: 550)
            ],
            activeRanges: fullRange,
            assignments: SpeakerAssignments(assignments: ["spk_1": SlotAssignment(displayName: "田中さん")]),
            confirmedAt: epoch,
            now: epoch
        )
        #expect(result.label == .mixed(primary: "田中さん", secondary: "Speaker 2"))
    }

    @Test("hasOverlapMarker is orthogonal to .single -- true alongside a single dominant slot")
    func overlapMarkerOrthogonalToSingleLabel() {
        // spk_1 covers the entire trimmed range (700ms), so `union == rangeLength == 700` no matter
        // what else overlaps it -- the two lower-occupancy slots (spk_2: 200ms, spk_3: 50ms) each
        // overlap spk_1 in *disjoint* windows, so their combined 250ms of simultaneous-speech time
        // crosses the 30% overlap-marker threshold (250/700 ≈ 36%) while spk_2 alone (the rank-2
        // "secondary" occupancy) stays under the 30% *mixed* threshold (200/700 ≈ 29%) -- decoupling
        // the two thresholds requires this three-slot construction (see `SegmentAttribution
        // Tests.swift` for the single-pair case, where they cannot be decoupled).
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [
                DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1_000),
                DiarizationTurn(slot: "spk_2", startMs: 150, endMs: 350),
                DiarizationTurn(slot: "spk_3", startMs: 400, endMs: 450)
            ],
            activeRanges: fullRange,
            assignments: SpeakerAssignments(assignments: ["spk_1": SlotAssignment(displayName: "田中さん")]),
            confirmedAt: epoch,
            now: epoch
        )
        #expect(result.label == .named("田中さん"), "SpeakerLabelResolver maps SegmentAttribution's .single(slot:) to .named/.anonymous, never exposing the raw slot id")
        #expect(result.hasOverlapMarker)
    }

    // MARK: - speakerNames override (docs/design/23-speaker-settings-rename.md §2.2)

    @Test("speakerNames overrides a slot's snapshot displayName when globalSpeakerId matches")
    func speakerNamesOverridesSlotSnapshot() {
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1_000)],
            activeRanges: fullRange,
            assignments: SpeakerAssignments(assignments: [
                "spk_1": SlotAssignment(globalSpeakerId: "vp_1", displayName: "田中さん")
            ]),
            confirmedAt: epoch,
            now: epoch,
            speakerNames: ["vp_1": "田中さん（改名後）"]
        )
        #expect(result.label == .named("田中さん（改名後）"))
    }

    @Test("speakerNames falls back to the snapshot displayName when globalSpeakerId is not found (e.g. speaker deleted from Settings)")
    func speakerNamesFallsBackWhenIdNotFound() {
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1_000)],
            activeRanges: fullRange,
            assignments: SpeakerAssignments(assignments: [
                "spk_1": SlotAssignment(globalSpeakerId: "vp_1", displayName: "田中さん")
            ]),
            confirmedAt: epoch,
            now: epoch,
            speakerNames: ["vp_2": "別の人"]
        )
        #expect(result.label == .named("田中さん"))
    }

    @Test("speakerNames is ignored for a slot with no globalSpeakerId (local-only rename)")
    func speakerNamesIgnoredWithoutGlobalSpeakerId() {
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1_000)],
            activeRanges: fullRange,
            assignments: SpeakerAssignments(assignments: [
                "spk_1": SlotAssignment(displayName: "田中さん")
            ]),
            confirmedAt: epoch,
            now: epoch,
            speakerNames: ["vp_1": "無関係の人"]
        )
        #expect(result.label == .named("田中さん"))
    }

    @Test("speakerNames overrides a segment override's snapshot displayName when globalSpeakerId matches")
    func speakerNamesOverridesSegmentOverrideSnapshot() {
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [],
            activeRanges: fullRange,
            assignments: SpeakerAssignments(),
            override: SegmentSpeakerOverride(displayName: "佐藤さん", globalSpeakerId: "vp_9"),
            confirmedAt: epoch,
            now: epoch,
            speakerNames: ["vp_9": "佐藤さん（改名後）"]
        )
        #expect(result.label == .named("佐藤さん（改名後）"))
        #expect(result.isSegmentOverride)
    }

    @Test("confirmedAt/now are not consulted once the segment is attributed (only the unattributed branch reads them)")
    func attributedSegmentIgnoresConfirmedAtNow() {
        let result = SpeakerLabelResolver.resolve(
            startMs: 0, endMs: 1_000,
            turns: [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1_000)],
            activeRanges: fullRange,
            assignments: SpeakerAssignments(),
            confirmedAt: epoch,
            now: epoch.addingTimeInterval(999_999)
        )
        #expect(result.label == .anonymous(slotNumber: 1))
    }
}

@Suite("SpeakerLabelResolver.displayString/resolvedLabel")
struct SpeakerLabelResolverDisplayStringTests {
    @Test("resolvedLabel(forSlot:assignments:) returns .anonymous(slotNumber: 0) for a malformed slot id")
    func malformedSlotIdDefaultsToZero() {
        #expect(SpeakerLabelResolver.resolvedLabel(forSlot: "not-a-slot", assignments: SpeakerAssignments()) == .anonymous(slotNumber: 0))
    }

    @Test("displayString(forSlot:assignments:) renders .anonymous as \"Speaker N\"")
    func displayStringRendersAnonymous() {
        #expect(SpeakerLabelResolver.displayString(forSlot: "spk_3", assignments: SpeakerAssignments()) == "Speaker 3")
    }

    @Test("displayString(forSlot:assignments:) renders .named as the display name verbatim")
    func displayStringRendersNamed() {
        let assignments = SpeakerAssignments(assignments: ["spk_1": SlotAssignment(displayName: "佐藤さん")])
        #expect(SpeakerLabelResolver.displayString(forSlot: "spk_1", assignments: assignments) == "佐藤さん")
    }

    @Test("resolvedLabel(forSlot:assignments:speakerNames:) prefers the current registered name over the snapshot displayName")
    func resolvedLabelPrefersSpeakerNamesOverride() {
        let assignments = SpeakerAssignments(assignments: [
            "spk_1": SlotAssignment(globalSpeakerId: "vp_1", displayName: "佐藤さん")
        ])
        #expect(
            SpeakerLabelResolver.resolvedLabel(forSlot: "spk_1", assignments: assignments, speakerNames: ["vp_1": "佐藤さん（改名後）"])
                == .named("佐藤さん（改名後）")
        )
    }

    @Test("displayString(forSlot:assignments:speakerNames:) renders the speakerNames override for a .mixed slot's secondary label")
    func displayStringRendersSpeakerNamesOverride() {
        let assignments = SpeakerAssignments(assignments: [
            "spk_1": SlotAssignment(globalSpeakerId: "vp_1", displayName: "佐藤さん")
        ])
        #expect(
            SpeakerLabelResolver.displayString(forSlot: "spk_1", assignments: assignments, speakerNames: ["vp_1": "佐藤さん（改名後）"])
                == "佐藤さん（改名後）"
        )
    }
}
