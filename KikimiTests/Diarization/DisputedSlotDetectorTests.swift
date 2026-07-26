import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `DisputedSlotDetector.disputedSlots(assignments:transcriptSegments:turns:)`
/// (`Kikimi/Diarization/DisputedSlotDetector.swift`), design section 20 §6.1's "M3" circuit breaker.
@Suite("DisputedSlotDetector")
struct DisputedSlotDetectorTests {
    private let segment = AttributableSegment(id: "seg_00001", startMs: 0, endMs: 10_000)
    private let turns = [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 10_000)]

    @Test("an .auto slot's `.single`-classified segment overridden with a different name is disputed")
    func autoSlotWithDifferentNameIsDisputed() {
        let assignments = SpeakerAssignments(
            assignments: ["spk_1": SlotAssignment(displayName: "田中さん", assignedBy: .auto)],
            segmentOverrides: ["seg_00001": SegmentSpeakerOverride(displayName: "佐藤さん")]
        )

        let disputed = DisputedSlotDetector.disputedSlots(assignments: assignments, transcriptSegments: [segment], turns: turns)

        #expect(disputed == ["spk_1"])
    }

    @Test("an .auto slot overridden with the same (trimmed) name is not disputed")
    func autoSlotWithSameNameIsNotDisputed() {
        let assignments = SpeakerAssignments(
            assignments: ["spk_1": SlotAssignment(displayName: "田中さん", assignedBy: .auto)],
            segmentOverrides: ["seg_00001": SegmentSpeakerOverride(displayName: " 田中さん ")]
        )

        let disputed = DisputedSlotDetector.disputedSlots(assignments: assignments, transcriptSegments: [segment], turns: turns)

        #expect(disputed.isEmpty)
    }

    @Test("a .user slot is never disputed, even when overridden with a different name")
    func userSlotIsNeverDisputed() {
        let assignments = SpeakerAssignments(
            assignments: ["spk_1": SlotAssignment(displayName: "田中さん", assignedBy: .user)],
            segmentOverrides: ["seg_00001": SegmentSpeakerOverride(displayName: "佐藤さん")]
        )

        let disputed = DisputedSlotDetector.disputedSlots(assignments: assignments, transcriptSegments: [segment], turns: turns)

        #expect(disputed.isEmpty)
    }

    @Test("a `.mixed`-classified segment's primary slot is never disputed, even overridden with a different name")
    func mixedSegmentIsNotDisputed() {
        let mixedSegment = AttributableSegment(id: "seg_00002", startMs: 0, endMs: 10_000)
        let mixedTurns = [
            DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 10_000),
            DiarizationTurn(slot: "spk_2", startMs: 4_000, endMs: 10_000)
        ]
        let assignments = SpeakerAssignments(
            assignments: ["spk_1": SlotAssignment(displayName: "田中さん", assignedBy: .auto)],
            segmentOverrides: ["seg_00002": SegmentSpeakerOverride(displayName: "佐藤さん")]
        )

        let disputed = DisputedSlotDetector.disputedSlots(assignments: assignments, transcriptSegments: [mixedSegment], turns: mixedTurns)

        #expect(disputed.isEmpty)
    }

    @Test("an `.unattributed`-classified segment (no matching turn) is not disputed")
    func unattributedSegmentIsNotDisputed() {
        let unattributedSegment = AttributableSegment(id: "seg_00003", startMs: 20_000, endMs: 30_000)
        let assignments = SpeakerAssignments(
            assignments: ["spk_1": SlotAssignment(displayName: "田中さん", assignedBy: .auto)],
            segmentOverrides: ["seg_00003": SegmentSpeakerOverride(displayName: "佐藤さん")]
        )

        let disputed = DisputedSlotDetector.disputedSlots(assignments: assignments, transcriptSegments: [unattributedSegment], turns: turns)

        #expect(disputed.isEmpty)
    }

    @Test("no overrides, or an override whose segment is unknown, yields no disputes")
    func noOverridesOrUnknownSegmentYieldsNoDisputes() {
        let noOverrides = SpeakerAssignments(assignments: ["spk_1": SlotAssignment(displayName: "田中さん", assignedBy: .auto)])
        #expect(DisputedSlotDetector.disputedSlots(assignments: noOverrides, transcriptSegments: [segment], turns: turns).isEmpty)

        let unknownSegmentOverride = SpeakerAssignments(
            assignments: ["spk_1": SlotAssignment(displayName: "田中さん", assignedBy: .auto)],
            segmentOverrides: ["seg_missing": SegmentSpeakerOverride(displayName: "佐藤さん")]
        )
        #expect(DisputedSlotDetector.disputedSlots(assignments: unknownSegmentOverride, transcriptSegments: [segment], turns: turns).isEmpty)
    }
}
