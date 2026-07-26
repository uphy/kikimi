import FluidAudio
import Foundation

// MARK: - SttStreamingBackend

/// Abstraction over the streaming ASR SDK call (`docs/design/11-streaming-stt.md` section 2.3/3.1's
/// isolation goal: "`SttEngine` の背後にエンジンを完全隔離し、`feed()` → `SttFinalizedSegment` の契約だけを固定
/// する"). `SttEngine` only ever talks to this protocol, never to FluidAudio types directly, so a
/// future engine swap (transcribe.cpp, a future sherpa-onnx streaming release, ...) only touches
/// this file plus `FluidAudioStreamingBackend`'s replacement.
///
/// Also the layer-1 test seam (section 3.12): a fake conforming to this protocol drives `SttEngine`'s
/// state machine deterministically without a real model or network access.
protocol SttStreamingBackend: Sendable {
    /// Number of Float32 samples `processChunk(_:)` expects per call. Backed by
    /// `NemotronMultilingualStreamingConfig.chunkSamples`, only known once the model's `metadata.json`
    /// has actually been loaded (hence a property on the *instance*, not `SttEngineConfig.chunkMs`
    /// converted a priori).
    var chunkSampleCount: Int { get }

    /// Feeds one full chunk (`chunkSampleCount` samples; the final chunk of a session may be
    /// zero-padded by the caller, section 3.2) and returns the transcript accumulated so far since
    /// the last `reset()` — **cumulative**, not a delta (spike `incrementalTextMode: "cumulative"`).
    func processChunk(_ samples: [Float]) async throws -> String

    /// Flushes any buffered remainder and returns the final cumulative text, then clears the
    /// backend's accumulated-token state (spike `apiSketch`: `finish()` "clears internal
    /// accumulators"). Does not reset encoder/decoder cache — see `reset()`.
    func finish() async throws -> String

    /// Full state reset (encoder cache, decoder LSTM state, mel cache). Preserves the configured
    /// language/prompt id (spike `resetPolicy`). Callers must only invoke this at true session
    /// boundaries (`SttEngine.stop()`), never per-confirmed-segment — cache-aware streaming's
    /// accuracy depends on carrying context across chunk boundaries (spike `resetPolicy`).
    func reset() async
}

// MARK: - FluidAudioStreamingBackend

/// Production `SttStreamingBackend` backed by FluidAudio's
/// `StreamingNemotronMultilingualAsrManager` (section 2.2/2.3: NVIDIA Nemotron 3.5 ASR Streaming
/// Multilingual 0.6B, CoreML/ANE). `StreamingNemotronMultilingualAsrManager` is itself a Swift
/// `actor`, so wrapping a reference to it in this `Sendable` `struct` is safe — every call below
/// simply hops onto that actor's own executor.
struct FluidAudioStreamingBackend: SttStreamingBackend {
    let chunkSampleCount: Int
    private let manager: StreamingNemotronMultilingualAsrManager

    init(manager: StreamingNemotronMultilingualAsrManager, chunkSampleCount: Int) {
        self.manager = manager
        self.chunkSampleCount = chunkSampleCount
    }

    /// `manager.process(samples:)` always returns `""` — the actual (cumulative) text comes from
    /// `getPartialTranscript()` (spike `apiSketch`). Combining both calls here keeps that FluidAudio
    /// quirk out of `SttEngine`.
    func processChunk(_ samples: [Float]) async throws -> String {
        _ = try await manager.process(samples: samples)
        return await manager.getPartialTranscript()
    }

    func finish() async throws -> String {
        try await manager.finish()
    }

    func reset() async {
        await manager.reset()
    }
}

// MARK: - SttSharedModelCoordinator

/// Single-flight coordinator for FluidAudio's expensive (~1.5GB CoreML) shared model preload
/// (`docs/design/11-streaming-stt.md` section 3.7's open question, resolved by the spike's
/// `multiInstance` finding: mic/system must share one `SharedNemotronMultilingualModels` bundle via
/// `loadFromShared(_:)` rather than each independently calling `downloadAndPreloadShared`/
/// `loadModels`, which would double CoreML model memory and compile/load time).
///
/// `TranscriptPipeline` constructs one `SttEngine` per source (section 3.1), and both commonly
/// request the same `(language, chunkMs)` shared bundle concurrently via `async let` — this actor
/// ensures only the first caller actually performs the download/preload; the second joins the same
/// in-flight `Task` (mirroring `SttModelStore`'s previous `DownloadCoordinator` pattern for the same
/// reason, one layer up the stack now that FluidAudio owns the download itself).
actor SttSharedModelCoordinator {
    static let shared = SttSharedModelCoordinator()

    private var inFlight: [String: Task<SharedNemotronMultilingualModels, Error>] = [:]

    /// Returns the shared model bundle for `config.language`/`config.chunkMs`, downloading/preloading
    /// it at most once per process per distinct `(language, chunkMs)` pair. Concurrent callers with
    /// the same pair all receive `downloadProgress` callbacks from the single underlying download
    /// (each source's own banner shows the same progress, which matches section 3.7's intent — there
    /// is genuinely only one download in flight).
    func sharedModel(
        config: SttEngineConfig,
        downloadProgress: (@Sendable (SttModelDownloadProgress) -> Void)?
    ) async throws -> SharedNemotronMultilingualModels {
        let key = "\(config.language)|\(config.chunkMs)"
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task {
            try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
                languageCode: config.language,
                chunkMs: config.chunkMs,
                progressHandler: { progress in
                    downloadProgress?(Self.convert(progress))
                }
            )
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Maps FluidAudio's file-count-based download phases onto `SttModelDownloadProgress`'s
    /// simplified two-stage model (section 3.7: ".downloading 開始と .installing 完了の 2 点通知").
    /// `.listing`/`.downloading` are both surfaced as `.downloading`; `.compiling` (CoreML model
    /// compilation, which only happens after all files are on disk) is surfaced as `.installing`.
    private static func convert(_ progress: DownloadUtils.DownloadProgress) -> SttModelDownloadProgress {
        let stage: SttModelDownloadStage
        switch progress.phase {
        case .listing, .downloading:
            stage = .downloading
        case .compiling:
            stage = .installing
        }
        return SttModelDownloadProgress(stage: stage, fractionCompleted: progress.fractionCompleted)
    }
}

// MARK: - FluidAudioSttBackendFactory

/// Default production `SttEngine.BackendFactory` (`SttEngine.swift`): resolves the process-wide
/// shared model bundle via `SttSharedModelCoordinator`, then builds one per-stream
/// `StreamingNemotronMultilingualAsrManager` from it (cheap: only per-stream cache/LSTM state is
/// allocated, section 3.7/spike `multiInstance`).
enum FluidAudioSttBackendFactory {
    static func makeBackend(
        config: SttEngineConfig,
        downloadProgress: (@Sendable (SttModelDownloadProgress) -> Void)?
    ) async throws -> SttStreamingBackend {
        let shared: SharedNemotronMultilingualModels
        do {
            shared = try await SttSharedModelCoordinator.shared.sharedModel(
                config: config,
                downloadProgress: downloadProgress
            )
        } catch {
            throw SttEngineError.modelPreparationFailed(error.localizedDescription)
        }

        do {
            let manager = StreamingNemotronMultilingualAsrManager()
            try await manager.loadFromShared(shared)
            await manager.setLanguage(config.language)
            return FluidAudioStreamingBackend(manager: manager, chunkSampleCount: shared.config.chunkSamples)
        } catch {
            throw SttEngineError.recognizerCreationFailed(error.localizedDescription)
        }
    }
}
