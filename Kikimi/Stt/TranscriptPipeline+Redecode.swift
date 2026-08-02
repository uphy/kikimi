import Foundation
import OSLog

// MARK: - TranscriptPipeline + two-pass window re-decode (design 33 MT4/MT5/section 3.3)

/// Split out of `TranscriptPipeline.swift` to keep that file under the project's `file_length` lint
/// limit (mirrors `SttEngine`/`SttEngine+PureHelpers.swift`'s split). Holds the acquire/release
/// plumbing for the shared `BatchAsrDecoder` (MT7/MT8) plus the per-window redecode-or-fallback
/// decision (MT4), whose pure selection half is kept `static` for direct unit testing (section 3.12's
/// convention, same as `SttEngine+PureHelpers.swift`).
extension TranscriptPipeline {
    /// `defaultBatchDecoderAcquire` is `static`, so it cannot reach the instance `logger`.
    private static let redecodeLogger = Logger(
        subsystem: "io.github.uphy.Kikimi", category: "TranscriptPipeline.Redecode")

    /// One acquired two-pass batch decoder plus its release callback
    /// (`docs/design/33-meeting-two-pass-decode.md` MT7/MT8). Production wraps a real
    /// `BatchAsrDecoderLease`; tests construct one directly from a fake `SttBatchDecoding` and a
    /// release closure they can assert call counts on, without ever touching
    /// `BatchAsrDecoderPool`/FluidAudio.
    struct AcquiredBatchDecoder: Sendable {
        var decoder: any SttBatchDecoding
        var release: @Sendable () -> Void
    }

    /// Resolves the two-pass decoder for `language`/`batchModel` and acquires it from the matching
    /// shared pool (MT1/MT7, extended by `docs/design/45-qwen3-batch-decode.md` Q2/Q4).
    /// The default `batchDecoderAcquire` passed to `init`.
    ///
    /// This is the **only** place design 45 changes: everything downstream -- window tiling,
    /// re-split, the batch-vs-streaming choice, `stt_source` -- sees an opaque `SttBatchDecoding`
    /// and cannot tell which engine produced the text.
    static func defaultBatchDecoderAcquire(
        language: String,
        batchModel: String
    ) async throws -> AcquiredBatchDecoder {
        #if canImport(Qwen3ASR)
        if let variant = Qwen3Variant(rawValue: batchModel) {
            let lease = try await Qwen3BatchDecoderPool.shared.acquire(
                variant: variant, language: language)
            return AcquiredBatchDecoder(decoder: lease.decoder, release: lease.release)
        }
        #else
        // The SwiftPM build has no MLX (design 45 §4), so a `qwen3-*` setting cannot be honoured
        // here. Falling back to Parakeet keeps `swift test` and any non-Xcode build working with
        // the pre-design-45 behaviour rather than failing the acquire and silently disabling the
        // second pass for the whole session.
        if Qwen3Variant(rawValue: batchModel) != nil {
            Self.redecodeLogger.warning(
                """
                stt.batch_model=\(batchModel, privacy: .public) needs the Xcode/Metal build; \
                using \(SttConfig.parakeetBatchModel, privacy: .public) instead
                """
            )
        }
        #endif
        let version = BatchAsrDecoder.resolveModelVersion(language: language)
        let lease = try await BatchAsrDecoderPool.shared.acquire(version: version)
        return AcquiredBatchDecoder(decoder: lease.decoder, release: lease.release)
    }

    /// The body of `startBatchDecoderAcquire` (MT8), lifted here so `TranscriptPipeline.swift` stays
    /// under the `file_length` limit -- and because this file already owns the acquire/release
    /// plumbing. Writes the lease into `storage` on success; both failure paths leave it `nil`, which
    /// `redecodeOrFallback`'s `decoder == nil` guard reads as "fall back to streaming text".
    static func makeBatchDecoderAcquireTask(
        acquire: @escaping @Sendable (String, String) async throws -> AcquiredBatchDecoder,
        language: String,
        batchModel: String,
        storage: OSAllocatedUnfairLock<AcquiredBatchDecoder?>,
        logger: Logger
    ) -> Task<AcquiredBatchDecoder, Error> {
        Task {
            do {
                let acquired = try await acquire(language, batchModel)
                storage.withLock { $0 = acquired }
                return acquired
            } catch is CancellationError {
                // Expected when the recording stops before the model finished loading (MT8) -- not a
                // failure worth an `.error` log, just this recording's session falling back to
                // streaming text for whatever windows were still pending.
                logger.debug("two-pass batch decoder acquire cancelled before completing; falling back to streaming text for this recording")
                throw CancellationError()
            } catch {
                logger.error(
                    "two-pass batch decoder acquire failed; falling back to streaming text for this recording: \(String(describing: error), privacy: .public)"
                )
                throw error
            }
        }
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
