import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `SegmentPlaybackResolver.resolve(startMs:endMs:recordings:)`
/// (`Kikimi/Playback/SegmentPlaybackResolver.swift`), the pure cumulative-timeline -> WAV-local-
/// offset mapping backing Transcript-row playback (`docs/design/15-segment-playback.md` section 3).
@Suite("SegmentPlaybackResolver")
struct SegmentPlaybackResolverTests {
    private func recording(index: Int, startMsOffset: Int) -> RecordingSegment {
        RecordingSegment(index: index, startedAt: Date(), endedAt: nil, startMsOffset: startMsOffset)
    }

    @Test("a segment inside a single recording segment (startMsOffset=0) resolves unchanged")
    func singleRecordingSegment() {
        let recordings = [recording(index: 0, startMsOffset: 0)]

        let slice = SegmentPlaybackResolver.resolve(startMs: 1_000, endMs: 3_500, recordings: recordings)

        #expect(slice == SegmentPlaybackSlice(recordingIndex: 0, localStartMs: 1_000, durationMs: 2_500))
    }

    @Test("a segment inside the second recording segment has startMsOffset subtracted")
    func secondRecordingSegment() {
        let recordings = [
            recording(index: 0, startMsOffset: 0),
            recording(index: 1, startMsOffset: 10_000)
        ]

        let slice = SegmentPlaybackResolver.resolve(startMs: 12_000, endMs: 13_200, recordings: recordings)

        #expect(slice == SegmentPlaybackSlice(recordingIndex: 1, localStartMs: 2_000, durationMs: 1_200))
    }

    @Test("a segment crossing a recording-segment boundary is clamped to that segment's end")
    func clampedAtSegmentBoundary() {
        let recordings = [
            recording(index: 0, startMsOffset: 0),
            recording(index: 1, startMsOffset: 10_000)
        ]

        // Starts at 9_000ms (inside segment 0) but nominally ends at 11_000ms, past the segment
        // 0/1 boundary at 10_000ms -- must clamp durationMs to the boundary, not the raw endMs.
        let slice = SegmentPlaybackResolver.resolve(startMs: 9_000, endMs: 11_000, recordings: recordings)

        #expect(slice == SegmentPlaybackSlice(recordingIndex: 0, localStartMs: 9_000, durationMs: 1_000))
    }

    @Test("the last known recording segment is unbounded: durationMs is never clamped")
    func lastSegmentUnbounded() {
        let recordings = [
            recording(index: 0, startMsOffset: 0),
            recording(index: 1, startMsOffset: 10_000)
        ]

        // Still-open (in-progress) segment 1: no next segment to clamp against, so a segment far
        // past what durationMs would otherwise suggest must resolve without truncation.
        let slice = SegmentPlaybackResolver.resolve(startMs: 50_000, endMs: 55_000, recordings: recordings)

        #expect(slice == SegmentPlaybackSlice(recordingIndex: 1, localStartMs: 40_000, durationMs: 5_000))
    }

    @Test("empty recordings resolves to nil")
    func emptyRecordings() {
        #expect(SegmentPlaybackResolver.resolve(startMs: 0, endMs: 1_000, recordings: []) == nil)
    }

    @Test("endMs <= startMs resolves to nil")
    func nonPositiveDuration() {
        let recordings = [recording(index: 0, startMsOffset: 0)]

        #expect(SegmentPlaybackResolver.resolve(startMs: 1_000, endMs: 1_000, recordings: recordings) == nil)
        #expect(SegmentPlaybackResolver.resolve(startMs: 1_000, endMs: 500, recordings: recordings) == nil)
    }

    @Test("startMs before every known segment's startMsOffset resolves to nil")
    func startBeforeEveryKnownSegment() {
        let recordings = [recording(index: 0, startMsOffset: 5_000)]

        #expect(SegmentPlaybackResolver.resolve(startMs: 1_000, endMs: 2_000, recordings: recordings) == nil)
    }

    @Test("recordings out of index order still resolve correctly (sorted internally)")
    func outOfOrderRecordings() {
        let recordings = [
            recording(index: 1, startMsOffset: 10_000),
            recording(index: 0, startMsOffset: 0)
        ]

        let slice = SegmentPlaybackResolver.resolve(startMs: 500, endMs: 1_500, recordings: recordings)

        #expect(slice == SegmentPlaybackSlice(recordingIndex: 0, localStartMs: 500, durationMs: 1_000))
    }
}
