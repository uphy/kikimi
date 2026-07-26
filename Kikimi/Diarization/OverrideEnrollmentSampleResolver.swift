import Foundation

// MARK: - OverrideEnrollmentSampleResolver

/// Pure function mapping one enrollment identity's "この発言だけ" (`SegmentSpeakerOverride`) segments onto
/// per-recording-segment sample ranges into that segment's own `system_NNN.wav`
/// (`docs/design/20-voiceprint-misassignment-mitigation.md` section 5.3). Mirrors
/// `VoiceprintEnrollmentSampleResolver`'s role (turn -> WAV-sample-range mapping) but starts from
/// per-segment overrides instead of a single slot's `diarization.jsonl` turns directly -- an override
/// only ever names *one transcript segment*, whose speaker attribution (`SegmentAttribution`) must
/// first be resolved to know *which* slot's turns are actually this identity's voice within that
/// segment's time range, and simultaneous-speech turns from any other slot must be carved back out
/// (design section 5.3's "同時発話（クロストーク）汚染防止"). No I/O -- the caller
/// (`MeetingWorkspaceViewModel+OverrideEnrollment.swift`'s Ended-time stage 1) owns actually reading
/// `audio/system_NNN.wav`.
enum OverrideEnrollmentSampleResolver {
    /// Resolves one enrollment identity's override segments (design section 5.4's "identity の定義": all
    /// `SegmentSpeakerOverride`s that resolved to the same person, or the same not-yet-registered new
    /// name, this session) into the sample slices to feed into extraction -- capped in aggregate at
    /// `maxSampleCount` and taken in chronological (`startMs` ascending, then `id` for a same-`startMs`
    /// tie) order, exactly like `VoiceprintEnrollmentSampleResolver.resolveSampleSlices(...)`.
    ///
    /// Per-segment adoption rule (design section 5.3, "保守的に、純度の低いサンプルは捨てる"):
    /// 1. `SegmentAttribution.attribute(startMs:endMs:turns:)`'s result for the segment must be
    ///    `.single(slot)`. A `.mixed` segment (the override may be naming the *secondary* speaker, whose
    ///    voice cannot be isolated from the primary's in the same audio -- design section 5.3/6.1) and an
    ///    `.unattributed` segment (no turn at all to locate the voice within, e.g. a "Speaker ?" row) are
    ///    both excluded wholesale, silently -- `resolveSampleSlices` is a pure function with no logger of
    ///    its own (matching `VoiceprintEnrollmentSampleResolver`'s own precedent); the caller is free to
    ///    log the aggregate outcome (nil vs. resolved) but has no per-segment detail to log regardless.
    /// 2. The adopted audio is "セグメント範囲 ∩ primary slot の turns" -- the segment's own raw
    ///    `[startMs, endMs)` (not `SegmentAttribution`'s internally-trimmed classification range;
    ///    classification and audio-selection ranges are deliberately different per design section 5.3)
    ///    intersected with every turn belonging to that `.single` slot.
    /// 3. Any sub-range of that intersection which a turn from a *different* slot also covers
    ///    (simultaneous speech) is carved back out before this segment's intervals are added to the
    ///    aggregate -- design section 5.3's explicit crosstalk-contamination guard, distinct from (and
    ///    stricter than) `SegmentAttribution`'s own `hasOverlapMarker` (which only flags overlap, never
    ///    excludes audio).
    ///
    /// Cumulative aggregation and the `minEnrollSpeechMs` gate (design section 5.3's "同一 identity の
    /// 複数 override は音声合算で累計判定する"): every segment's post-exclusion intervals -- across every
    /// segment passed in `segments`, not just one -- are pooled into one chronological list before the
    /// `minEnrollSpeechMs`/`maxSampleCount` handling below runs, so a person corrected across three short
    /// override segments is judged (and capped) as a single combined sample, not three independent ones.
    ///
    /// - Parameters:
    ///   - segments: Every transcript segment this identity has a `SegmentSpeakerOverride` on this
    ///     session (already filtered down to one identity by the caller -- this function has no opinion
    ///     on identity resolution, design section 5.4). Order does not matter; sorted here.
    ///   - turns: The session's full `diarization.jsonl` (any slot, any order) -- used both to classify
    ///     each segment (`SegmentAttribution`) and to look up the winning slot's own turns.
    ///   - recordings: `SessionMeta.recordings` (any order; sorted by `VoiceprintEnrollmentSampleResolver
    ///     .sliceIntoRecordingSegments(...)`, which this delegates to for the final WAV-range conversion).
    ///   - minEnrollSpeechMs: `config.yaml`'s `diarization.min_enroll_speech_ms` (design section 5.3:
    ///     "累計発話が min_enroll_speech_ms 未満なら nil"). Measured against the *full* pooled duration,
    ///     before the `maxSampleCount` cap is applied -- same "gate before cap" contract as
    ///     `VoiceprintEnrollmentSampleResolver`.
    ///   - maxSampleCount: `VoiceprintExtractor.maxSampleCount` by default (the same fixed 10s window);
    ///     overridable so tests can exercise the cutoff without needing 160,000-sample fixtures.
    /// - Returns: `nil` when there is nothing to extract from at all -- no `segments`, no `recordings`,
    ///   every segment excluded by the `.single`-only adoption rule, or the pooled cumulative speech is
    ///   below `minEnrollSpeechMs`. All are silent "don't bother" outcomes for the caller, never an error
    ///   (design section 5.3/8's "累計発話が min_enroll_speech_ms 未満なら nil（info ログして学習スキップ）" --
    ///   the info-logging itself is the caller's job, this function only reports the fact via `nil`).
    static func resolveSampleSlices(
        segments: [AttributableSegment],
        turns: [DiarizationTurn],
        recordings: [RecordingSegment],
        minEnrollSpeechMs: Int,
        maxSampleCount: Int = VoiceprintExtractor.maxSampleCount
    ) -> [EnrollmentSampleSlice]? {
        guard !segments.isEmpty, !recordings.isEmpty, maxSampleCount > 0 else {
            return nil
        }

        let sortedSegments = segments.sorted { lhs, rhs in
            lhs.startMs != rhs.startMs ? lhs.startMs < rhs.startMs : lhs.id < rhs.id
        }

        var pooledIntervals: [(startMs: Int, endMs: Int)] = []
        for segment in sortedSegments {
            guard let slot = SegmentAttribution.singleDominantSlot(
                startMs: segment.startMs, endMs: segment.endMs, turns: turns
            ) else {
                continue // `.mixed`/`.unattributed`: excluded (design section 5.3).
            }

            let primaryTurns = turns.filter { $0.slot == slot && $0.endMs > $0.startMs }
            let otherTurns = turns.filter { $0.slot != slot && $0.endMs > $0.startMs }

            for turn in primaryTurns {
                let overlapStart = max(segment.startMs, turn.startMs)
                let overlapEnd = min(segment.endMs, turn.endMs)
                guard overlapEnd > overlapStart else { continue }

                let crosstalk = otherTurns.compactMap { other -> (Int, Int)? in
                    let start = max(other.startMs, overlapStart)
                    let end = min(other.endMs, overlapEnd)
                    return end > start ? (start, end) : nil
                }
                pooledIntervals.append(contentsOf: subtract(crosstalk, from: (overlapStart, overlapEnd)))
            }
        }

        guard !pooledIntervals.isEmpty else {
            return nil
        }

        let sortedIntervals = pooledIntervals.sorted { $0.startMs < $1.startMs }
        let cumulativeSpeechMs = sortedIntervals.reduce(0) { $0 + ($1.endMs - $1.startMs) }
        guard cumulativeSpeechMs >= minEnrollSpeechMs else {
            return nil
        }

        let slices = VoiceprintEnrollmentSampleResolver.sliceIntoRecordingSegments(
            intervals: sortedIntervals,
            recordings: recordings,
            maxSampleCount: maxSampleCount
        )
        guard !slices.isEmpty else {
            return nil
        }
        return slices
    }

    /// Removes every `others` sub-range from `base`, returning the (possibly empty, possibly
    /// multi-piece) remainder -- the simultaneous-speech exclusion step (design section 5.3). `others`
    /// need not be sorted or non-overlapping; each is subtracted in turn against whatever remains of
    /// `base` so far.
    private static func subtract(
        _ others: [(Int, Int)],
        from base: (start: Int, end: Int)
    ) -> [(startMs: Int, endMs: Int)] {
        var remaining = [base]
        for other in others {
            guard other.1 > other.0 else { continue }
            var next: [(start: Int, end: Int)] = []
            for piece in remaining {
                guard other.0 < piece.end, other.1 > piece.start else {
                    // No overlap with this piece at all.
                    next.append(piece)
                    continue
                }
                if other.0 > piece.start {
                    next.append((piece.start, other.0))
                }
                if other.1 < piece.end {
                    next.append((other.1, piece.end))
                }
            }
            remaining = next
        }
        return remaining
            .filter { $0.end > $0.start }
            .map { (startMs: $0.start, endMs: $0.end) }
    }
}
