import Foundation

// MARK: - SttDecodeWorker

/// `SttEngine`'s inference-only companion actor (`docs/design/11-streaming-stt.md` section 3.2, last
/// paragraph: "CoreML 推論...は SttEngine actor 本体とは別 actor に隔離し、推論中も feed() の受付...を塞がない").
/// Runs on its own actor executor: `SttStreamingBackend.processChunk(_:)`/`finish()` are async CoreML/ANE
/// calls, and isolating them here means `SttEngine.feed()` (its own actor's chunk-accumulation bookkeeping)
/// never blocks behind one — `SttEngine` only enqueues chunks and dispatches a background `Task` to this
/// actor (`SttEngine.swift`'s decode-queue), never `await`s a chunk decode inline within `feed()` itself.
///
/// Split into its own file (alongside `SttEngine+PureHelpers.swift`) to keep `SttEngine.swift` under the
/// project's `file_length` lint limit. `SttEngine` is this type's only caller, so — as before — this is
/// declared at the default `internal` access level rather than file-scoped `private`.
actor SttDecodeWorker {
    private let backend: SttStreamingBackend

    init(backend: SttStreamingBackend) {
        self.backend = backend
    }

    /// `chunkSampleCount` is a `let` on the underlying backend (fixed once the model's `metadata.json`
    /// is loaded), so it is safe to read without hopping onto this actor's executor first.
    nonisolated var chunkSampleCount: Int {
        backend.chunkSampleCount
    }

    func processChunk(_ samples: [Float]) async throws -> String {
        try await backend.processChunk(samples)
    }

    func finish() async throws -> String {
        try await backend.finish()
    }

    func reset() async {
        await backend.reset()
    }
}
