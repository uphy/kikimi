import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `OverrideEnrollmentSampleResolver.resolveSampleSlices(segments:turns:recordings:
/// minEnrollSpeechMs:maxSampleCount:)` (`Kikimi/Diarization/OverrideEnrollmentSampleResolver.swift`),
/// the pure "この発言だけ" override -> WAV-sample-range mapping backing Ended-time enrollment
/// (`docs/design/20-voiceprint-misassignment-mitigation.md` section 5.3).
@Suite("OverrideEnrollmentSampleResolver")
struct OverrideEnrollmentSampleResolverTests {
    private func recording(index: Int, startMsOffset: Int) -> RecordingSegment {
        RecordingSegment(index: index, startedAt: Date(), endedAt: nil, startMsOffset: startMsOffset)
    }

    @Test("a `.single`-classified segment adopts its raw range intersected with the primary slot's own turns")
    func adoptsSingleSegmentAudio() {
        let segments = [AttributableSegment(id: "seg_00001", startMs: 0, endMs: 10_000)]
        let turns = [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 10_000)]
        let recordings = [recording(index: 0, startMsOffset: 0)]

        let slices = OverrideEnrollmentSampleResolver.resolveSampleSlices(
            segments: segments, turns: turns, recordings: recordings, minEnrollSpeechMs: 1_000
        )

        // 10_000ms -> 160_000 samples @16kHz.
        #expect(slices == [EnrollmentSampleSlice(recordingIndex: 0, sampleRange: 0..<160_000)])
    }

    @Test("a `.mixed`-classified segment (secondary slot >= 30% of the trimmed-range denominator) is excluded wholesale")
    func excludesMixedSegment() {
        let segments = [AttributableSegment(id: "seg_00001", startMs: 0, endMs: 10_000)]
        let turns = [
            DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 10_000),
            // Trimmed range is [1500, 8500); spk_2 covers [4000, 8500) of it (4500ms of 7000ms union
            // == ~64%), well past the 30% mixed threshold.
            DiarizationTurn(slot: "spk_2", startMs: 4_000, endMs: 10_000)
        ]
        let recordings = [recording(index: 0, startMsOffset: 0)]

        let slices = OverrideEnrollmentSampleResolver.resolveSampleSlices(
            segments: segments, turns: turns, recordings: recordings, minEnrollSpeechMs: 1_000
        )

        #expect(slices == nil)
    }

    @Test("an `.unattributed`-classified segment (no turn overlaps it at all) is excluded wholesale")
    func excludesUnattributedSegment() {
        let segments = [AttributableSegment(id: "seg_00001", startMs: 20_000, endMs: 30_000)]
        let turns = [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 10_000)]
        let recordings = [recording(index: 0, startMsOffset: 0)]

        let slices = OverrideEnrollmentSampleResolver.resolveSampleSlices(
            segments: segments, turns: turns, recordings: recordings, minEnrollSpeechMs: 1_000
        )

        #expect(slices == nil)
    }

    @Test("simultaneous-speech sub-ranges (a different slot's turn) are carved out of the adopted audio")
    func excludesSimultaneousSpeechSubRange() {
        // Segment [0, 20_000) is still `.single(spk_1)` overall (spk_2's 1000ms sliver is far below
        // the 30% mixed threshold against the 14_000ms trimmed-range denominator), but the 1000ms
        // where spk_2 also speaks must still be carved out of the adopted audio.
        let segments = [AttributableSegment(id: "seg_00001", startMs: 0, endMs: 20_000)]
        let turns = [
            DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 20_000),
            DiarizationTurn(slot: "spk_2", startMs: 5_000, endMs: 6_000)
        ]
        let recordings = [recording(index: 0, startMsOffset: 0)]

        let slices = OverrideEnrollmentSampleResolver.resolveSampleSlices(
            segments: segments, turns: turns, recordings: recordings, minEnrollSpeechMs: 1_000, maxSampleCount: 1_000_000
        )

        // [0, 5_000)ms -> [0, 80_000) samples, [6_000, 20_000)ms -> [96_000, 320_000) samples.
        #expect(slices == [
            EnrollmentSampleSlice(recordingIndex: 0, sampleRange: 0..<80_000),
            EnrollmentSampleSlice(recordingIndex: 0, sampleRange: 96_000..<320_000)
        ])
    }

    @Test("multiple override segments are aggregated cumulatively, and the minEnrollSpeechMs gate applies to the pooled total")
    func aggregatesAcrossSegmentsAndHonorsMinEnrollSpeechMsGate() {
        let segments = [
            AttributableSegment(id: "seg_00001", startMs: 0, endMs: 2_000),
            AttributableSegment(id: "seg_00002", startMs: 10_000, endMs: 12_000)
        ]
        let turns = [
            DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 2_000),
            DiarizationTurn(slot: "spk_1", startMs: 10_000, endMs: 12_000)
        ]
        let recordings = [recording(index: 0, startMsOffset: 0)]

        // Pooled total is 4_000ms: below a 5_000ms gate...
        #expect(OverrideEnrollmentSampleResolver.resolveSampleSlices(
            segments: segments, turns: turns, recordings: recordings, minEnrollSpeechMs: 5_000
        ) == nil)

        // ...but clears a 3_000ms gate, aggregating both segments' audio.
        let slices = OverrideEnrollmentSampleResolver.resolveSampleSlices(
            segments: segments, turns: turns, recordings: recordings, minEnrollSpeechMs: 3_000
        )
        #expect(slices == [
            EnrollmentSampleSlice(recordingIndex: 0, sampleRange: 0..<32_000),
            EnrollmentSampleSlice(recordingIndex: 0, sampleRange: 160_000..<192_000)
        ])
    }

    @Test("selection stops once the aggregate maxSampleCount cap is reached, taken in chronological order across segments")
    func stopsAtMaxSampleCountAcrossSegments() {
        let segments = [
            AttributableSegment(id: "seg_00001", startMs: 0, endMs: 3_000),
            AttributableSegment(id: "seg_00002", startMs: 10_000, endMs: 13_000)
        ]
        let turns = [
            DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 3_000),
            DiarizationTurn(slot: "spk_1", startMs: 10_000, endMs: 13_000)
        ]
        let recordings = [recording(index: 0, startMsOffset: 0)]

        // Cap at 64_000 samples (4s): the first segment's full 48_000 samples (3s) plus 16_000 (1s)
        // of the second, taken chronologically.
        let slices = OverrideEnrollmentSampleResolver.resolveSampleSlices(
            segments: segments, turns: turns, recordings: recordings, minEnrollSpeechMs: 1_000, maxSampleCount: 64_000
        )
        #expect(slices == [
            EnrollmentSampleSlice(recordingIndex: 0, sampleRange: 0..<48_000),
            EnrollmentSampleSlice(recordingIndex: 0, sampleRange: 160_000..<176_000)
        ])
    }

    @Test("a segment's adopted audio spanning a recording-segment boundary is split into one slice per segment")
    func splitsAcrossRecordingSegmentBoundary() {
        let segments = [AttributableSegment(id: "seg_00001", startMs: 8_000, endMs: 12_000)]
        let turns = [DiarizationTurn(slot: "spk_1", startMs: 8_000, endMs: 12_000)]
        let recordings = [
            recording(index: 0, startMsOffset: 0),
            recording(index: 1, startMsOffset: 10_000)
        ]

        let slices = OverrideEnrollmentSampleResolver.resolveSampleSlices(
            segments: segments, turns: turns, recordings: recordings, minEnrollSpeechMs: 1_000, maxSampleCount: 1_000_000
        )

        #expect(slices == [
            EnrollmentSampleSlice(recordingIndex: 0, sampleRange: 128_000..<160_000),
            EnrollmentSampleSlice(recordingIndex: 1, sampleRange: 0..<32_000)
        ])
    }

    @Test("no segments, no recordings, or every segment excluded all return nil")
    func returnsNilForEmptyInputsOrFullExclusion() {
        let recordings = [recording(index: 0, startMsOffset: 0)]

        #expect(OverrideEnrollmentSampleResolver.resolveSampleSlices(
            segments: [], turns: [], recordings: recordings, minEnrollSpeechMs: 1_000
        ) == nil)

        #expect(OverrideEnrollmentSampleResolver.resolveSampleSlices(
            segments: [AttributableSegment(id: "seg_00001", startMs: 0, endMs: 10_000)],
            turns: [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 10_000)],
            recordings: [],
            minEnrollSpeechMs: 1_000
        ) == nil)
    }
}
