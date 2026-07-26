import Foundation

// MARK: - SegmentPlaybackSlice

/// One playable slice of a recording segment's own WAV file, resolved from a transcript segment's
/// cumulative-timeline position (`docs/design/15-segment-playback.md` section 3). `localStartMs`/
/// `durationMs` are relative to the start of `mic_NNN.wav`/`system_NNN.wav` for `recordingIndex`
/// (kikimi.md 4 章 directory layout), not the session's cumulative "recording active time"
/// timeline that `TranscriptRowViewModel.startMs`/`endMs` use.
struct SegmentPlaybackSlice: Equatable, Sendable {
    let recordingIndex: Int
    let localStartMs: Int
    let durationMs: Int
}

// MARK: - SegmentPlaybackResolver

/// Pure function mapping one transcript segment's cumulative-timeline `startMs`/`endMs` (kikimi.md
/// 5/6 章) onto the recording segment (`RecordingSegment`, `meta.recordings`) that produced it and
/// that segment's own local sample position -- the same timeline-to-WAV-position rules
/// `VoiceprintEnrollmentSampleResolver` (`Kikimi/Diarization/VoiceprintEnrollmentSampleResolver.swift`)
/// already established for voiceprint fallback extraction, reused here for playback instead of
/// voiceprint sampling. No I/O -- the caller (`MeetingWorkspaceViewModel+SegmentPlayback.swift`)
/// owns turning the result into a file URL and actually playing it.
enum SegmentPlaybackResolver {
    /// Resolves `startMs`..<`endMs` (a `TranscriptRowViewModel`'s cumulative-timeline span) into the
    /// single recording segment it starts in and that segment's local millisecond offsets.
    ///
    /// `recordings` is sorted by `startMsOffset` here (any input order is accepted, matching
    /// `VoiceprintEnrollmentSampleResolver.resolveSampleSlices`'s tolerance for out-of-order input).
    /// The segment containing `startMs` is the last one whose `startMsOffset <= startMs`. That
    /// segment's upper bound is the *next* segment's `startMsOffset`, or -- for the last known
    /// segment -- deliberately unbounded (`Int.max`, not derived from `SessionMeta.durationMs`):
    /// `durationMs` only advances once a segment *closes* (kikimi.md 5 章), so a segment still being
    /// actively recorded has no reliable upper bound to clamp against yet, and clamping to a stale
    /// `durationMs` would wrongly truncate playback of a segment recorded moments ago. `endMs` is
    /// clamped to whatever upper bound applies; a segment cannot straddle a recording-segment
    /// boundary and still be played back as a single WAV region, so the clamped-away remainder
    /// (if any) is simply dropped rather than split across two files.
    ///
    /// - Returns: `nil` when there is nothing playable: `endMs <= startMs`, no `recordings` at all,
    ///   or `startMs` falls before every known segment's `startMsOffset` (should not normally happen
    ///   for a segment that was actually recorded, but defensively returns `nil` rather than
    ///   guessing which segment to use).
    static func resolve(startMs: Int, endMs: Int, recordings: [RecordingSegment]) -> SegmentPlaybackSlice? {
        guard endMs > startMs, !recordings.isEmpty else { return nil }

        let sorted = recordings.sorted { $0.startMsOffset < $1.startMsOffset }
        guard let index = sorted.lastIndex(where: { $0.startMsOffset <= startMs }) else { return nil }

        let segment = sorted[index]
        let segmentEndMs = index + 1 < sorted.count ? sorted[index + 1].startMsOffset : Int.max
        let clampedEndMs = min(endMs, segmentEndMs)
        guard clampedEndMs > startMs else { return nil }

        return SegmentPlaybackSlice(
            recordingIndex: segment.index,
            localStartMs: startMs - segment.startMsOffset,
            durationMs: clampedEndMs - startMs
        )
    }
}
