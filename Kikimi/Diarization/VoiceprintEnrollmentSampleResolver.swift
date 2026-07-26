import Foundation

// MARK: - EnrollmentSampleSlice

/// One contiguous slice of a recording segment's own `system_NNN.wav` file to feed into on-demand
/// voiceprint extraction (`docs/design/13-speaker-diarization.md` section 4.4, "実装時の追記
/// 2026-07-03": the R2 fallback for a slot whose live capture never captured an `embedding`).
///
/// `sampleRange` is expressed in that recording segment's *own* local sample position (0-based, at
/// `VoiceprintEnrollmentSampleResolver.sampleRateHz`) -- i.e. an offset directly into
/// `system_NNN.wav`, not into the session's cumulative "recording active time" timeline. It may
/// extend past that file's actual frame count (e.g. a turn recorded right before a mid-write crash
/// truncated the WAV); the reader (`SessionAudioSampleReading`), not this type, is responsible for
/// clamping to the file's real length.
struct EnrollmentSampleSlice: Sendable, Equatable {
    /// Matches `RecordingSegment.index` / the `NNN` in `system_NNN.wav`.
    let recordingIndex: Int
    let sampleRange: Range<Int>
}

// MARK: - VoiceprintEnrollmentSampleResolver

/// Pure function mapping one slot's `DiarizationTurn`s (design section 4.2, cumulative "recording
/// active time" timeline) onto per-recording-segment sample ranges into that segment's own
/// `system_NNN.wav` (kikimi.md 4/5 章). No I/O -- the caller (`VoiceprintWavFallbackExtractor`) owns
/// actually reading those files.
enum VoiceprintEnrollmentSampleResolver {
    /// Kikimi's audio pipeline is fixed at 16 kHz mono end to end (kikimi.md 12 章 `audio.sample_rate`),
    /// matching `RealtimeDiarizationCoordinator.sampleRateHz` -- not read from that type directly since
    /// this file has no reason to depend on the coordinator itself, only on the same fixed constant.
    static let sampleRateHz = 16_000

    /// Resolves `slot`'s turns into the sample slices to feed into extraction, capped in aggregate at
    /// `maxSampleCount` (design section 4.4's "先頭 10 秒固定" -- `VoiceprintExtractor.maxSampleCount`
    /// by default) and taken in chronological (`startMs` ascending) order ("時系列順で十分" -- the
    /// design explicitly does not ask for a more elaborate selection strategy).
    ///
    /// A turn that spans a recording-segment boundary (kikimi.md 4 章's `recordings[]`: a session can
    /// span several `mic_NNN.wav`/`system_NNN.wav` pairs, one per Recording segment) is split into one
    /// slice per segment it overlaps ("turn が区間境界をまたぐ場合は区間ごとに分割"). The *last* known
    /// recording segment's upper bound is deliberately left unbounded (`Int.max`, not derived from
    /// `SessionMeta.durationMs`): `durationMs` only advances when a segment *closes` (kikimi.md 5 章),
    /// so a turn recorded during the still-open segment of an in-progress Recording (renames are
    /// allowed at any time, design section 6.1) would otherwise be wrongly clamped to a stale, smaller
    /// `durationMs` and silently dropped. Clamping a slice's sample range to the WAV file's *actual*
    /// on-disk length (crash truncation, or a since-closed segment shorter than its turns imply) is the
    /// reader's job (`SessionAudioSampleReading`), not this pure function's -- it has no access to the
    /// filesystem to know that length.
    ///
    /// - Parameters:
    ///   - turns: The session's full `diarization.jsonl` (any slot, any order) -- filtered down to
    ///     `slot` and sorted here.
    ///   - recordings: `SessionMeta.recordings` (any order; sorted here by `index`).
    ///   - minEnrollSpeechMs: `config.yaml`'s `diarization.min_enroll_speech_ms` (design section 4.4's
    ///     fallback-specific gate: "累計発話が...未満なら fallback 抽出はしない"). Measured against the
    ///     slot's *full* cumulative turn duration, before the `maxSampleCount` cap is applied -- a slot
    ///     with 6s of turns spread across a 10s-capped extraction still clears a 5s gate even though
    ///     only some of that 6s ends up selected below.
    ///   - maxSampleCount: `VoiceprintExtractor.maxSampleCount` by default (design section 4.4's fixed
    ///     10s window); overridable so tests can exercise the cutoff without needing 160,000-sample
    ///     fixtures.
    /// - Returns: `nil` when there is nothing to extract from at all (no turns for `slot`, no
    ///   `recordings`, or the slot's cumulative speech is below `minEnrollSpeechMs`) -- all three are
    ///   silent "don't bother" outcomes for the caller, never an error.
    static func resolveSampleSlices(
        turns: [DiarizationTurn],
        slot: String,
        recordings: [RecordingSegment],
        minEnrollSpeechMs: Int,
        maxSampleCount: Int = VoiceprintExtractor.maxSampleCount
    ) -> [EnrollmentSampleSlice]? {
        let slotTurns = turns
            .filter { $0.slot == slot && $0.endMs > $0.startMs }
            .sorted { $0.startMs < $1.startMs }
        guard !slotTurns.isEmpty, !recordings.isEmpty, maxSampleCount > 0 else {
            return nil
        }

        let cumulativeSpeechMs = slotTurns.reduce(0) { $0 + ($1.endMs - $1.startMs) }
        guard cumulativeSpeechMs >= minEnrollSpeechMs else {
            return nil
        }

        let slices = sliceIntoRecordingSegments(
            intervals: slotTurns.map { (startMs: $0.startMs, endMs: $0.endMs) },
            recordings: recordings,
            maxSampleCount: maxSampleCount
        )
        guard !slices.isEmpty else {
            return nil
        }
        return slices
    }

    /// Converts a chronologically-sorted (`startMs` ascending) list of cumulative-timeline ms
    /// intervals into per-recording-segment sample slices, splitting across recording-segment
    /// boundaries (same rule as `resolveSampleSlices(...)` above) and stopping once `maxSampleCount`
    /// total samples have been selected. Shared with `OverrideEnrollmentSampleResolver`
    /// (`docs/design/20-voiceprint-misassignment-mitigation.md` section 5.3: "区間 →
    /// system_NNN.wav 内サンプル範囲への変換・録音区間跨ぎの分割・時系列順の maxSampleCount 打ち切りは
    /// VoiceprintEnrollmentSampleResolver と同じ規則（変換ヘルパは共有してよい）") -- that resolver has
    /// already reduced its own "セグメント範囲 ∩ primary slot の turns" (minus simultaneous-speech overlap)
    /// down to plain ms intervals before calling this, so this helper only ever deals in intervals, never
    /// slot identity.
    ///
    /// - Parameter intervals: Must already be sorted by `startMs` ascending -- this method does not sort
    ///   (both current callers already produce/require sorted input for their own "時系列順" contracts).
    static func sliceIntoRecordingSegments(
        intervals: [(startMs: Int, endMs: Int)],
        recordings: [RecordingSegment],
        maxSampleCount: Int
    ) -> [EnrollmentSampleSlice] {
        let sortedRecordings = recordings.sorted { $0.index < $1.index }

        var slices: [EnrollmentSampleSlice] = []
        var remainingSamples = maxSampleCount

        intervalLoop: for interval in intervals {
            for (offset, recording) in sortedRecordings.enumerated() {
                guard remainingSamples > 0 else { break intervalLoop }

                let segmentStartMs = recording.startMsOffset
                let segmentEndMs = offset + 1 < sortedRecordings.count
                    ? sortedRecordings[offset + 1].startMsOffset
                    : Int.max

                let overlapStartMs = max(interval.startMs, segmentStartMs)
                let overlapEndMs = min(interval.endMs, segmentEndMs)
                guard overlapEndMs > overlapStartMs else {
                    continue
                }

                let localStartSample = millisecondsToSamples(overlapStartMs - segmentStartMs)
                let localEndSample = millisecondsToSamples(overlapEndMs - segmentStartMs)
                let availableSamples = localEndSample - localStartSample
                guard availableSamples > 0 else {
                    continue
                }

                let cappedCount = min(availableSamples, remainingSamples)
                slices.append(
                    EnrollmentSampleSlice(
                        recordingIndex: recording.index,
                        sampleRange: localStartSample..<(localStartSample + cappedCount)
                    )
                )
                remainingSamples -= cappedCount
            }
        }
        return slices
    }

    private static func millisecondsToSamples(_ ms: Int) -> Int {
        Int((Double(ms) / 1_000.0 * Double(sampleRateHz)).rounded())
    }
}
