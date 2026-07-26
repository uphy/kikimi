import FluidAudio
import Foundation
import OSLog

// MARK: - VoiceprintEmbeddingExtracting

/// Abstraction over one-shot WeSpeaker voiceprint embedding extraction
/// (`docs/design/13-speaker-diarization.md` section 5, "声紋照合（イベント駆動）"). Mirrors
/// `DiarizationBackend`'s test-seam role (`DiarizationBackend.swift`): `RealtimeDiarizationCoordinator`
/// only ever talks to this protocol, never to FluidAudio's `DiarizerManager` directly, so a future
/// model/vendor swap only touches this file plus `VoiceprintExtractor`'s replacement, and unit tests
/// inject a fake that returns deterministic embeddings without a real WeSpeaker CoreML model (no
/// network access, no wall-clock model-load delay).
protocol VoiceprintEmbeddingExtracting: Sendable {
    /// Extracts one WeSpeaker embedding from up to `VoiceprintExtractor.maxSampleCount` (10s @ 16kHz)
    /// of 16 kHz mono speech samples. The caller (`RealtimeDiarizationCoordinator`) is responsible for
    /// capping the slice at that length before calling this: per the spike facts,
    /// `DiarizerManager.extractSpeakerEmbedding` silently truncates anything longer with no error, so
    /// capping earlier avoids retaining/copying samples that would be dropped anyway.
    ///
    /// - Returns: A 256-dimensional, L2-normalized embedding (design section 2.2's comparisons assume
    ///   unit vectors; see `VoiceprintExtractor.extractEmbedding(from:)`'s doc comment for why this
    ///   conformance normalizes explicitly rather than trusting the underlying API to have already done
    ///   so).
    func extractEmbedding(from samples: [Float]) async throws -> [Float]
}

// MARK: - VoiceprintExtractor

/// Production `VoiceprintEmbeddingExtracting` backed by FluidAudio's
/// `DiarizerManager.extractSpeakerEmbedding(from:)` (spike facts: the exact one-shot API the design
/// wants, needing no extra plumbing). An `actor` — not a `struct` wrapping a reference, unlike
/// `FluidAudioStreamingBackend` — because `DiarizerManager` is a plain, non-Sendable `final class` with
/// no isolation of its own (same rationale as `LSEENDDiarizationBackend` wrapping `LSEENDDiarizer`,
/// `DiarizationBackend.swift`): this type supplies that isolation itself rather than reaching for
/// `@unchecked Sendable`.
///
/// This is a **second, independent** CoreML model pair from the one `LSEENDDiarizationBackend` loads
/// (spike facts: `pyannote_segmentation.mlmodelc` + `wespeaker_v2.mlmodelc` from the
/// `FluidInference/speaker-diarization-coreml` repo, vs. LS-EEND's own `ls_eend_*.mlmodelc` from a
/// different repo) — there is no way to reuse or repurpose the realtime LS-EEND diarizer for
/// voiceprints (it has no embedding/clustering step at all).
actor VoiceprintExtractor: VoiceprintEmbeddingExtracting {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "VoiceprintExtractor")

    /// `DiarizerManager.extractSpeakerEmbedding`'s fixed internal window (spike facts: internal
    /// `waveformShape = [3, 160_000]`, exactly 10.0s @ 16kHz). Exposed so
    /// `RealtimeDiarizationCoordinator` can cap its accumulated per-slot buffer at exactly this length
    /// before calling `extractEmbedding(from:)` — anything longer is silently truncated by the
    /// underlying API with no error (spike facts), so capping earlier avoids wasting memory on samples
    /// that would be dropped anyway.
    static let maxSampleCount = 160_000

    /// Lazily loaded the first time `extractEmbedding(from:)` is actually called, never at `init`
    /// (design section 9: "イベント駆動（会議序盤に数回）。ほぼゼロ" — a session that never accumulates
    /// `min_enroll_speech_ms` of speech for any slot, e.g. a very short meeting, never downloads/loads
    /// this second CoreML model pair at all). `initializationTask` de-duplicates concurrent callers
    /// (two slots crossing the enrollment threshold close together) into a single in-flight
    /// download/load rather than racing two.
    private var manager: DiarizerManager?
    private var initializationTask: Task<DiarizerManager, Error>?

    /// - Parameter modelDirectory: `nil` uses FluidAudio's own default cache directory
    ///   (`~/Library/Application Support/FluidAudio/Models/speaker-diarization-coreml/`, kikimi.md 4
    ///   章). Overridable only so a test could in principle point at a pre-fetched local model; no
    ///   current test exercises real extraction (that would need network access on first run), so this
    ///   exists purely for future use, mirroring `LSEENDDiarizationBackend`'s constructor shape.
    private let modelDirectory: URL?

    init(modelDirectory: URL? = nil) {
        self.modelDirectory = modelDirectory
    }

    /// - Throws: On model download/load failure or `DiarizerManager.extractSpeakerEmbedding`'s own
    ///   errors (design section 8, "WeSpeaker 抽出/照合の失敗"). The caller
    ///   (`RealtimeDiarizationCoordinator`) treats every failure here as best-effort: the slot stays
    ///   anonymous, `embedding` stays `null`, and neither recording nor STT is affected.
    func extractEmbedding(from samples: [Float]) async throws -> [Float] {
        let manager = try await loadedManager()
        let raw = try manager.extractSpeakerEmbedding(from: samples)
        return Self.l2Normalize(raw)
    }

    private func loadedManager() async throws -> DiarizerManager {
        if let manager {
            return manager
        }
        if let initializationTask {
            return try await initializationTask.value
        }
        let directory = modelDirectory
        let task = Task<DiarizerManager, Error> {
            let models = try await DiarizerModels.downloadIfNeeded(to: directory)
            let manager = DiarizerManager(config: .default)
            manager.initialize(models: models)
            return manager
        }
        initializationTask = task
        do {
            let loaded = try await task.value
            manager = loaded
            initializationTask = nil
            return loaded
        } catch {
            initializationTask = nil
            throw error
        }
    }

    /// Normalizes explicitly rather than trusting `DiarizerManager.extractSpeakerEmbedding`'s own doc
    /// comment (which claims an already-"L2-normalized" result): per the spike facts, that
    /// normalization is only confirmed to happen once a raw embedding is boxed into a `Speaker`
    /// (`SpeakerTypes.swift`'s `VDSPOperations.l2Normalize` calls), not necessarily on the raw `[Float]`
    /// `extractSpeakerEmbedding` itself returns — `EmbeddingExtractor.getEmbeddings` performs no
    /// normalization of its own. Normalizing again here is idempotent for an already-unit vector and
    /// guarantees every embedding this actor hands back is safe to compare/persist directly (design
    /// section 2.2, `VoiceprintStore.cosineDistance`) regardless of that ambiguity.
    private static func l2Normalize(_ vector: [Float]) -> [Float] {
        var sumOfSquares: Float = 0
        for value in vector {
            sumOfSquares += value * value
        }
        let norm = sumOfSquares.squareRoot()
        guard norm > 0 else {
            Self.logger.warning("l2Normalize received a zero-norm embedding; returning it unmodified.")
            return vector
        }
        return vector.map { $0 / norm }
    }
}
