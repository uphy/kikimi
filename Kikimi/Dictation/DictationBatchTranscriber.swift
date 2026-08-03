import FluidAudio
import Foundation

// MARK: - DictationBatchTranscribing

/// `DictationController`'s seam for the key-up batch re-decode
/// (`docs/design/31-dictation-two-pass-decode.md` §3.1) -- same DI convention as
/// `DictationHistoryStoring` (design 29 §5.1): tests inject a fake that never touches FluidAudio.
protocol DictationBatchTranscribing: Sendable {
    func transcribe(samples: [Float]) async throws -> String
}

// MARK: - DictationBatchTranscriber

/// Thin `DictationBatchTranscribing` adapter over a `BatchAsrDecoderLease`
/// (`docs/design/33-meeting-two-pass-decode.md` §3.1). The warm `AsrManager` + per-utterance
/// `transcribe` this type used to own directly now lives in the process-wide `BatchAsrDecoderPool`
/// (MT7), shared with the meeting pipeline; this adapter just holds the lease acquired for
/// dictation's resolved language and forwards `transcribe` to it.
///
/// Kept warm for as long as `dictation.enabled && dictation.two_pass_decode` holds
/// (`docs/design/31-dictation-two-pass-decode.md` TP5/TP9), same as before design 33 -- only now
/// "kept warm" means "holds a pool lease" rather than "owns the model directly". Releasing that
/// lease (`releaseModel()`, called by `DictationController`'s disable/toggle-off transitions) drops
/// the pool's refcount for dictation's share; the decoder itself is only actually freed once every
/// other holder (e.g. a concurrently recording meeting on the same `AsrModelVersion`) has released
/// too (MT7).
struct DictationBatchTranscriber: DictationBatchTranscribing {
    /// FluidAudio's `AsrManager.transcribe` hard-rejects anything shorter than
    /// `ASRConstants.minimumAudioDurationSeconds` (0.3s) with `ASRError.invalidAudioData`.
    /// `DictationController` gates on this *before* calling `transcribe` so everyday short
    /// presses degrade to the streaming text with a debug log instead of an error log per press
    /// (design 31 §3.3's minimum-sample guard).
    static let minimumSampleCount = Int(
        ASRConstants.minimumAudioDurationSeconds * Double(ASRConstants.sampleRate)
    )

    /// The leased decoder and its release, rather than a `BatchAsrDecoderLease` directly: since
    /// `docs/design/45-qwen3-batch-decode.md` §6.1 dictation can run Qwen3 too, and the two pools
    /// hand back different lease types. Same shape as
    /// `TranscriptPipeline.AcquiredBatchDecoder` for the same reason.
    private let decoder: any SttBatchDecoding
    private let release: @Sendable () -> Void

    /// Resolves `batchModel` (+ the *resolved* dictation language -- `resolveSttEngineConfig`'s
    /// output, never the raw `dictation.language`) to a decoder and acquires it from the matching
    /// shared pool. Mirrors `TranscriptPipeline.defaultBatchDecoderAcquire`, so the meeting and
    /// dictation share one warm instance whenever they point at the same model (design 33 MT7).
    static func make(language: String, batchModel: String) async throws -> DictationBatchTranscriber {
        #if canImport(Qwen3ASR)
        if let variant = Qwen3Variant(rawValue: batchModel) {
            let lease = try await Qwen3BatchDecoderPool.shared.acquire(
                variant: variant, language: language)
            return DictationBatchTranscriber(decoder: lease.decoder, release: lease.release)
        }
        #endif
        let version = BatchAsrDecoder.resolveModelVersion(language: language)
        let lease = try await BatchAsrDecoderPool.shared.acquire(version: version)
        return DictationBatchTranscriber(decoder: lease.decoder, release: lease.release)
    }

    /// Decodes one utterance by delegating to the leased decoder.
    func transcribe(samples: [Float]) async throws -> String {
        try await decoder.transcribe(samples: samples)
    }

    /// Releases the pool lease this instance holds (design 33 MT7). Called by
    /// `DictationController` at every `batchTranscriber = nil` transition instead of relying on
    /// `deinit`, so the release happens deterministically at the same instant the old code freed
    /// the model directly. Idempotent via `BatchAsrDecoderLease.release()`.
    func releaseModel() {
        release()
    }
}
