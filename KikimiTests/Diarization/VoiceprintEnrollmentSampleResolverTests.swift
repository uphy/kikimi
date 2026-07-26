import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `VoiceprintEnrollmentSampleResolver.resolveSampleSlices(turns:slot:recordings:
/// minEnrollSpeechMs:maxSampleCount:)` (`Kikimi/Diarization/VoiceprintEnrollmentSampleResolver.swift`),
/// the pure turn -> WAV-sample-range mapping backing the on-demand voiceprint fallback
/// (`docs/design/13-speaker-diarization.md` section 4.4, "実装時の追記 2026-07-03").
@Suite("VoiceprintEnrollmentSampleResolver")
struct VoiceprintEnrollmentSampleResolverTests {
    private func recording(index: Int, startMsOffset: Int) -> RecordingSegment {
        RecordingSegment(index: index, startedAt: Date(), endedAt: nil, startMsOffset: startMsOffset)
    }

    @Test("a single turn fully inside one recording segment resolves to one slice, correctly converted to samples")
    func singleSegmentSingleTurn() {
        let turns = [DiarizationTurn(slot: "spk_1", startMs: 1_000, endMs: 6_000)]
        let recordings = [recording(index: 0, startMsOffset: 0)]

        let slices = VoiceprintEnrollmentSampleResolver.resolveSampleSlices(
            turns: turns, slot: "spk_1", recordings: recordings, minEnrollSpeechMs: 5_000
        )

        // 1000ms -> 16_000 samples, 6000ms -> 96_000 samples (16kHz).
        #expect(slices == [EnrollmentSampleSlice(recordingIndex: 0, sampleRange: 16_000..<96_000)])
    }

    @Test("a turn spanning a recording-segment boundary is split into one slice per segment")
    func turnSpanningSegmentBoundary() {
        // Segment 0 covers [0, 10_000)ms, segment 1 starts at 10_000ms. A turn straddling the
        // boundary must produce two slices, each expressed in its own segment's local sample offset.
        let turns = [DiarizationTurn(slot: "spk_1", startMs: 8_000, endMs: 12_000)]
        let recordings = [
            recording(index: 0, startMsOffset: 0),
            recording(index: 1, startMsOffset: 10_000)
        ]

        let slices = VoiceprintEnrollmentSampleResolver.resolveSampleSlices(
            turns: turns, slot: "spk_1", recordings: recordings, minEnrollSpeechMs: 4_000
        )

        // Segment 0's local portion: [8000, 10000)ms -> [128_000, 160_000) samples.
        // Segment 1's local portion: [10000, 12000)ms -> local [0, 2000)ms -> [0, 32_000) samples.
        #expect(slices == [
            EnrollmentSampleSlice(recordingIndex: 0, sampleRange: 128_000..<160_000),
            EnrollmentSampleSlice(recordingIndex: 1, sampleRange: 0..<32_000)
        ])
    }

    @Test("a turn extending past every known recording segment's boundary is fully attributed to the last (still-open) segment, not clamped to a stale duration")
    func turnPastLastKnownSegmentBoundary() {
        // A single, still-recording segment: durationMs has not advanced yet (it only updates when a
        // segment closes, kikimi.md 5 章), so the resolver must not use it as an upper bound -- the
        // whole turn belongs to the one open segment regardless.
        let turns = [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 20_000)]
        let recordings = [recording(index: 0, startMsOffset: 0)]

        let slices = VoiceprintEnrollmentSampleResolver.resolveSampleSlices(
            turns: turns, slot: "spk_1", recordings: recordings, minEnrollSpeechMs: 5_000, maxSampleCount: 1_000_000
        )

        #expect(slices == [EnrollmentSampleSlice(recordingIndex: 0, sampleRange: 0..<320_000)])
    }

    @Test("selection stops once the aggregate 10-second (maxSampleCount) cap is reached, taken in chronological order")
    func stopsAtMaxSampleCountInChronologicalOrder() {
        let turns = [
            DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 3_000),
            DiarizationTurn(slot: "spk_1", startMs: 4_000, endMs: 7_000),
            DiarizationTurn(slot: "spk_1", startMs: 8_000, endMs: 11_000)
        ]
        let recordings = [recording(index: 0, startMsOffset: 0)]

        // Cap at 80_000 samples (5s): the first two turns (3s + 3s = 6s = 96_000 samples) already
        // exceed it, so the second turn must be truncated and the third dropped entirely.
        let slices = VoiceprintEnrollmentSampleResolver.resolveSampleSlices(
            turns: turns, slot: "spk_1", recordings: recordings, minEnrollSpeechMs: 1_000, maxSampleCount: 80_000
        )

        let totalSamples = slices?.reduce(0) { $0 + $1.sampleRange.count } ?? 0
        #expect(totalSamples == 80_000)
        // First turn contributes its full 48_000 samples (3s), second turn is truncated to the
        // remaining 32_000.
        #expect(slices == [
            EnrollmentSampleSlice(recordingIndex: 0, sampleRange: 0..<48_000),
            EnrollmentSampleSlice(recordingIndex: 0, sampleRange: 64_000..<96_000)
        ])
    }

    @Test("cumulative speech below minEnrollSpeechMs (measured before the maxSampleCount cap) returns nil")
    func belowMinEnrollSpeechMsReturnsNil() {
        let turns = [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 3_000)]
        let recordings = [recording(index: 0, startMsOffset: 0)]

        let slices = VoiceprintEnrollmentSampleResolver.resolveSampleSlices(
            turns: turns, slot: "spk_1", recordings: recordings, minEnrollSpeechMs: 5_000
        )

        #expect(slices == nil)
    }

    @Test("no turns for the requested slot returns nil")
    func noTurnsForSlotReturnsNil() {
        let turns = [DiarizationTurn(slot: "spk_2", startMs: 0, endMs: 10_000)]
        let recordings = [recording(index: 0, startMsOffset: 0)]

        let slices = VoiceprintEnrollmentSampleResolver.resolveSampleSlices(
            turns: turns, slot: "spk_1", recordings: recordings, minEnrollSpeechMs: 1_000
        )

        #expect(slices == nil)
    }

    @Test("no recording segments returns nil even with turns present")
    func noRecordingsReturnsNil() {
        let turns = [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 10_000)]

        let slices = VoiceprintEnrollmentSampleResolver.resolveSampleSlices(
            turns: turns, slot: "spk_1", recordings: [], minEnrollSpeechMs: 1_000
        )

        #expect(slices == nil)
    }

    @Test("turns are considered regardless of diarization.jsonl's append order (unsorted input)")
    func handlesUnsortedTurns() {
        let turns = [
            DiarizationTurn(slot: "spk_1", startMs: 8_000, endMs: 11_000),
            DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 3_000)
        ]
        let recordings = [recording(index: 0, startMsOffset: 0)]

        let slices = VoiceprintEnrollmentSampleResolver.resolveSampleSlices(
            turns: turns, slot: "spk_1", recordings: recordings, minEnrollSpeechMs: 1_000, maxSampleCount: 48_000
        )

        // Chronological order means the earlier turn (0-3s) is the one selected under the cap, not
        // the later one that happens to appear first in the unsorted input.
        #expect(slices == [EnrollmentSampleSlice(recordingIndex: 0, sampleRange: 0..<48_000)])
    }
}
