import Foundation

// MARK: - RealtimeDiarizationCoordinator + Anchor (docs/design/13-speaker-diarization.md section 5.1,
// "実装時の追記 2026-08-01（タイムスタンプのアンカー補正）")

/// Split into its own file (alongside `+Voiceprint.swift`/`+Rematch.swift`/`+SlotNumbering.swift`) to
/// keep `RealtimeDiarizationCoordinator.swift` under the project's `file_length` lint limit. Owns the
/// single job of reconciling the diarizer's two clocks:
///
/// - the **backend frame cursor** (`DiarizerSegment.startTime`/`.endTime`), which counts from the first
///   sample ever fed to the current generation, and
/// - the **capture clock** (`elapsedAtBufferStart`), which counts from `AudioCapture.start()` and is
///   what every `TranscriptSegment.startMs` is derived from (`SttEngine`).
///
/// These differ by however long the system-audio tap took to produce its first buffer — CoreAudio
/// aggregate-device setup, typically a few hundred ms, occasionally more. Left uncorrected, every turn
/// is reported that much *too early*, and `SegmentAttribution` mis-attributes segments whose text sits
/// near a turn boundary (the exact symptom this correction was written for).
///
/// Only needs `RealtimeDiarizationCoordinator`'s already-`internal` surface (`elapsedAnchorMs`/
/// `samplesFedThisGeneration`/`baseOffsetMs`/`logger`), not any `private` member of the primary actor
/// declaration.
extension RealtimeDiarizationCoordinator {
    /// This generation's frame-cursor → capture-clock offset in ms, or `0` while it is still
    /// unestablished (no buffer fed yet this generation). `0` is the correct neutral value: with no
    /// buffer fed there is no turn to shift either, so nothing can observe the difference between
    /// "no anchor" and "zero anchor".
    var anchorMs: Int {
        elapsedAnchorMs ?? 0
    }

    /// Converts a `DiarizerSegment` time (seconds on the current generation's frame cursor) into a
    /// timestamp on the session's cumulative "recording active time" timeline (kikimi.md 6 章) — i.e.
    /// this generation's base offset, plus the capture-clock anchor, plus the frame-cursor time itself.
    ///
    /// The anchor is applied **here and in `closeCurrentActiveRange()` only**. It deliberately does not
    /// apply to voiceprint slicing (`+Voiceprint.swift`), which indexes `generationSampleBuffer` — that
    /// buffer is filled by the same `feed` calls the backend consumes, so it lives in the frame
    /// cursor's own index space and must be addressed with unshifted times. Shifting there too would
    /// slice each turn's audio from the wrong place by exactly the tap's startup lag.
    func turnMs(fromGenerationTime seconds: Float) -> Int {
        baseOffsetMs + anchorMs + Int((seconds * 1_000).rounded())
    }

    /// Establishes (first buffer of the generation) or re-establishes (after a detected audio gap) the
    /// capture-clock anchor. Called from `feed(samples:elapsedAtBufferStart:)` *before*
    /// `samplesFedThisGeneration` grows, so `elapsedAtBufferStart` — which marks this buffer's first
    /// sample — is compared against the fed-sample count that same sample continues from.
    ///
    /// - **First call**: `anchor = elapsedMs − fedMs`. `fedMs` is normally `0` (this is the generation's
    ///   first buffer), making the anchor simply "how late the tap started"; subtracting `fedMs` anyway
    ///   keeps the formula correct if the very first buffers were somehow fed before an anchor existed.
    /// - **Later calls**: `drift = elapsedMs − (anchor + fedMs)`. Positive drift means the capture clock
    ///   advanced further than the audio actually handed to the backend — i.e. buffers went missing
    ///   (tap stall/dropout), so from here on every turn would be reported `drift` ms too early. Once it
    ///   exceeds `anchorDriftToleranceMs` the anchor absorbs the whole gap.
    ///
    /// Negative drift is **never** corrected. It would mean more audio reached the backend than wall
    /// time allows, which only happens transiently through rounding/buffer-boundary jitter; treating it
    /// as real would let the anchor walk backwards and undo a legitimate gap correction. Small positive
    /// jitter is likewise ignored below the tolerance — an anchor that twitches every buffer would make
    /// turn timestamps non-monotonic against each other, which is worse than being a few tens of ms off.
    func updateElapsedAnchor(elapsedAtBufferStart: TimeInterval) {
        let elapsedMs = Int((elapsedAtBufferStart * 1_000).rounded())
        let fedMs = Int((Double(samplesFedThisGeneration) / Double(Self.sampleRateHz) * 1_000).rounded())

        guard let anchor = elapsedAnchorMs else {
            let established = elapsedMs - fedMs
            elapsedAnchorMs = established
            logger.debug(
                "diarization capture-clock anchor established at \(established)ms (elapsed=\(elapsedMs)ms fed=\(fedMs)ms)"
            )
            return
        }

        let drift = elapsedMs - (anchor + fedMs)
        guard drift > Self.anchorDriftToleranceMs else {
            return
        }
        elapsedAnchorMs = anchor + drift
        logger.warning(
            """
            diarization detected a \(drift)ms system-audio gap (elapsed=\(elapsedMs)ms fed=\(fedMs)ms); \
            re-anchoring turn timestamps from \(anchor)ms to \(anchor + drift)ms
            """
        )
    }
}
