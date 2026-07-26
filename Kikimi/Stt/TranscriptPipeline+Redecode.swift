import Foundation
import OSLog
import os

// MARK: - TranscriptPipeline + two-pass window re-decode (design 33 MT4/MT5/section 3.3)

/// Split out of `TranscriptPipeline.swift` to keep that file under the project's `file_length` lint
/// limit (mirrors `SttEngine`/`SttEngine+PureHelpers.swift`'s split). Holds the acquire/release
/// plumbing for the shared `BatchAsrDecoder` (MT7/MT8) plus the per-window redecode-or-fallback
/// decision (MT4), whose pure selection half is kept `static` for direct unit testing (section 3.12's
/// convention, same as `SttEngine+PureHelpers.swift`).
extension TranscriptPipeline {
    /// One acquired two-pass batch decoder plus its release callback
    /// (`docs/design/33-meeting-two-pass-decode.md` MT7/MT8). Production wraps a real
    /// `BatchAsrDecoderLease`; tests construct one directly from a fake `SttBatchDecoding` and a
    /// release closure they can assert call counts on, without ever touching
    /// `BatchAsrDecoderPool`/FluidAudio.
    struct AcquiredBatchDecoder: Sendable {
        var decoder: any SttBatchDecoding
        var release: @Sendable () -> Void
    }

    /// Resolves the two-pass decoder for `language` and acquires it from the shared pool (MT1/MT7).
    /// The default `batchDecoderAcquire` passed to `init`.
    static func defaultBatchDecoderAcquire(language: String) async throws -> AcquiredBatchDecoder {
        let version = BatchAsrDecoder.resolveModelVersion(language: language)
        let lease = try await BatchAsrDecoderPool.shared.acquire(version: version)
        return AcquiredBatchDecoder(decoder: lease.decoder, release: lease.release)
    }

    /// The result of one window's redecode-or-fallback decision (MT4): the segments to append, and
    /// the `stt_source` to tag them with (`"batch"` only on a successful re-decode, `nil` for every
    /// fallback path and for `two_pass_decode` OFF, MT9).
    struct RedecodeOutcome: Sendable, Equatable {
        var segments: [SttFinalizedSegment]
        var sttSource: String?
    }

    /// Pure pre-check for MT4's non-async fallback guards: no decoder acquired yet (still loading, or
    /// acquire failed) / the window's audio is under FluidAudio's hard minimum
    /// (`DictationBatchTranscribing`'s `0.3s`, design 31 §3.3) / the window was beheaded by the
    /// retention cap (MT6 (b)). Any of these means re-decoding would only make things worse or simply
    /// cannot run, so the caller must never call `transcribe` at all.
    static func isEligibleForBatchRedecode(window: SttConfirmedWindow, hasDecoder: Bool) -> Bool {
        hasDecoder
            && window.samples.count >= DictationBatchTranscriber.minimumSampleCount
            && !window.truncated
    }

    /// Forwarding-`Task` entry point (section 3.3): dispatches to `redecodeOrFallback` when two-pass
    /// is on, or passes `window.pieces` straight through untouched when it is off. OFF is *not* a
    /// fallback/degradation (it's the config's steady state), so it deliberately skips
    /// `redecodeOrFallback`'s per-segment debug logging entirely -- keeps the diagnostic log's
    /// signal-to-noise ratio meaningful for sessions that actually have two-pass enabled (MT9).
    static func redecodeWindowIfEnabled(
        _ window: SttConfirmedWindow,
        twoPassDecode: Bool,
        batchDecoderStorage: OSAllocatedUnfairLock<AcquiredBatchDecoder?>,
        maxSegmentCharacters: Int,
        logger: Logger
    ) async -> RedecodeOutcome {
        guard twoPassDecode else {
            return RedecodeOutcome(segments: window.pieces, sttSource: nil)
        }
        let decoder = batchDecoderStorage.withLock { $0 }?.decoder
        return await redecodeOrFallback(
            window: window,
            decoder: decoder,
            maxSegmentCharacters: maxSegmentCharacters,
            logger: logger
        )
    }

    /// MT4's full redecode-or-fallback decision for one confirmed window, run inline in a per-source
    /// forwarding `Task` (MT5) so mic/system re-decodes serialize through the same `decoder` actor.
    /// Every fallback path (guards ①, a `transcribe` throw ②, or an all-whitespace batch result ③) is
    /// logged at `.debug`/`.error` and returns `window.pieces` untouched with `sttSource: nil` --
    /// "録音は絶対に止めない" means a re-decode failure must never lose or block the streaming text
    /// that already confirmed successfully (kikimi.md 8.5 章).
    static func redecodeOrFallback(
        window: SttConfirmedWindow,
        decoder: (any SttBatchDecoding)?,
        maxSegmentCharacters: Int,
        logger: Logger
    ) async -> RedecodeOutcome {
        guard let decoder, isEligibleForBatchRedecode(window: window, hasDecoder: true) else {
            logger.debug(
                "two-pass redecode skipped (no decoder / window too short / truncated); falling back to \(window.pieces.count, privacy: .public) streaming piece(s)"
            )
            return RedecodeOutcome(segments: window.pieces, sttSource: nil)
        }

        let batchText: String
        do {
            batchText = try await decoder.transcribe(samples: window.samples)
        } catch {
            logger.error(
                "two-pass redecode failed; falling back to streaming piece(s): \(String(describing: error), privacy: .public)"
            )
            return RedecodeOutcome(segments: window.pieces, sttSource: nil)
        }

        guard !batchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.debug("two-pass redecode produced an empty result; falling back to streaming piece(s)")
            return RedecodeOutcome(segments: window.pieces, sttSource: nil)
        }

        let speechStartMs = window.pieces.first?.startMs ?? Int((window.startElapsed * 1_000).rounded())
        let resplit = SttWindowRedecode.resplit(
            batchText: batchText,
            windowStartMs: Int((window.startElapsed * 1_000).rounded()),
            windowEndMs: Int((window.endElapsed * 1_000).rounded()),
            speechStartMs: speechStartMs,
            maxSegmentCharacters: maxSegmentCharacters
        )
        logger.debug(
            "two-pass redecode: streaming=\(window.pieces.map(\.text), privacy: .public) batch=\(batchText, privacy: .public)"
        )
        return RedecodeOutcome(segments: resplit, sttSource: "batch")
    }
}
