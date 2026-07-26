import Foundation

// MARK: - DictationTranscriber

/// One warm `SttStreamingBackend`, reused across every dictation utterance
/// (`docs/design/25-dictation-mode.md` R3). Unlike `SttEngine` (which is a one-shot-per-session
/// pipeline with its own segment-confirmation state machine), this type has no notion of
/// segments at all -- one utterance (one hotkey press-and-hold) is always exactly one chunk-fed
/// `reset()`/`feed`/`finish()` cycle, and the full `finish()` text is the result.
///
/// Constructed once (via `make(config:)`) when the dictation feature is enabled and kept alive for
/// as long as it stays enabled (`DictationController` owns the instance) -- `reset()` between
/// utterances is cheap (encoder/decoder cache clear only); tearing down and rebuilding the backend
/// per utterance would repay FluidAudio's ANE load cost every single press.
actor DictationTranscriber {
    private let backend: SttStreamingBackend
    private var pendingSamples: [Float] = []

    /// Injectable for tests (`docs/design/25-dictation-mode.md` §11's "`SttStreamingBackend` を
    /// フェイク注入" layer-1 case) -- a fake never touches FluidAudio or the network.
    init(backend: SttStreamingBackend) {
        self.backend = backend
    }

    /// Builds a warm backend via `FluidAudioSttBackendFactory.makeBackend`, which transparently
    /// shares the expensive CoreML model bundle with any concurrently-running meeting
    /// `SttEngine`s through `SttSharedModelCoordinator` when `config.language`/`config.chunkMs`
    /// match (R3).
    static func make(config: SttEngineConfig) async throws -> DictationTranscriber {
        let backend = try await FluidAudioSttBackendFactory.makeBackend(config: config, downloadProgress: nil)
        return DictationTranscriber(backend: backend)
    }

    /// Call on hotkey key-down, before the first `feed(samples:)` of a new utterance. Clears the
    /// backend's encoder/decoder cache (so a previous utterance's audio context never bleeds into
    /// this one) and any leftover sub-chunk sample remainder.
    func beginUtterance() async {
        pendingSamples.removeAll(keepingCapacity: true)
        await backend.reset()
    }

    /// Call repeatedly while the hotkey is held. Accumulates `samples` and feeds the backend at
    /// exactly `chunkSampleCount` granularity, mirroring `SttEngine`'s own chunk accumulation
    /// (`SttEngine+PureHelpers.swift`) but without that type's segment-confirmation bookkeeping --
    /// dictation only cares about the final `finishUtterance()` text.
    ///
    /// Returns the backend's cumulative transcript (`SttStreamingBackend.processChunk`'s "cumulative,
    /// not delta" contract) from the *last* `processChunk` call this invocation made, or `nil` if
    /// fewer than one full chunk has accumulated yet (nothing new to report). `DictationController`
    /// forwards this straight to the live-preview HUD (`docs/design/25-dictation-mode.md`'s "ライブ
    /// プレビューHUD" section) -- dictation still has no notion of segments, so this is simply
    /// "whatever the backend has transcribed so far", unfiltered and unsplit.
    @discardableResult
    func feed(samples: [Float]) async throws -> String? {
        guard !samples.isEmpty else { return nil }
        pendingSamples.append(contentsOf: samples)
        var latestText: String?
        while pendingSamples.count >= backend.chunkSampleCount {
            let chunk = Array(pendingSamples.prefix(backend.chunkSampleCount))
            pendingSamples.removeFirst(backend.chunkSampleCount)
            latestText = try await backend.processChunk(chunk)
        }
        return latestText
    }

    /// Call on hotkey key-up. Zero-pads and flushes whatever sub-chunk remainder is still
    /// buffered, then calls `SttStreamingBackend.finish()` for the utterance's full cumulative
    /// text. The backend's accumulated-token state is cleared by `finish()` itself; the next
    /// utterance still needs its own `beginUtterance()` for the encoder/decoder cache reset.
    func finishUtterance() async throws -> String {
        defer { pendingSamples.removeAll(keepingCapacity: true) }
        if !pendingSamples.isEmpty {
            var chunk = pendingSamples
            if chunk.count < backend.chunkSampleCount {
                chunk.append(contentsOf: repeatElement(Float(0), count: backend.chunkSampleCount - chunk.count))
            }
            _ = try await backend.processChunk(chunk)
        }
        return try await backend.finish()
    }
}
