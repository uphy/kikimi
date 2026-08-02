import Foundation
import os

#if canImport(Qwen3ASR)
import Qwen3ASR
#endif

// MARK: - Qwen3Variant

/// Which Qwen3-ASR bundle the second-pass decoder runs
/// (`docs/design/45-qwen3-batch-decode.md` Q1).
///
/// Declared unconditionally -- outside the `canImport` guard -- so `SttConfig` and the model
/// resolution in `TranscriptPipeline` parse and round-trip the same values on both build paths.
/// Only the decoder that *uses* a variant is conditional.
enum Qwen3Variant: String, Codable, Equatable, Sendable, CaseIterable {
    /// Default. 1.7B at 8-bit: the smaller/coarser bundles measurably lose proper nouns and
    /// technical terms on real meeting audio (0.6B/4bit turned `東さん` into `日向さん`, dropped
    /// `AWS` outright, and leaked Hangul into Japanese output) while saving ~0.7s per 25s window,
    /// which is not a trade the meeting pipeline needs -- design 45 §1.
    case large = "qwen3-1.7b"
    /// Half the latency and ~1.2GB less resident memory, at the accuracy cost above. Kept because
    /// on a memory-constrained machine that trade may be the right one.
    case small = "qwen3-0.6b"

    var modelId: String {
        switch self {
        case .large: return "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
        case .small: return "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        }
    }
}

#if canImport(Qwen3ASR)

// MARK: - Qwen3BatchDecoder

/// One warm Qwen3-ASR (MLX) batch decoder, shaped exactly like `BatchAsrDecoder` so it can be
/// swapped in behind `SttBatchDecoding` without touching anything upstream of it
/// (`docs/design/45-qwen3-batch-decode.md` Q2). All `transcribe` calls are serialized by actor
/// isolation, which doubles as the GPU arbitration between the meeting's two sources.
///
/// **Requires the Xcode build.** `swift build` does not compile Metal shaders, so mlx-swift ships
/// without its `default.metallib` and the first MLX call traps at runtime with no build-time
/// warning. See design 45 §4 and `.mise/tasks/build/swift`.
actor Qwen3BatchDecoder: SttBatchDecoding {
    /// Qwen3-ASR's audio encoder takes a fixed 30s mel input. Longer audio is split rather than
    /// handed over whole: the CoreML packaging rejects it outright, and the MLX one has no
    /// defined behaviour past the trained window.
    static let maxWindowSamples = 30 * 16_000

    /// Cut search window for `splitForSingleWindowDecode`, scaled from `BatchAsrDecoder`'s 15s
    /// defaults (`[10s, 14.5s]`) to this decoder's 30s ceiling. The same invariant holds: a split
    /// only happens while the remainder exceeds 30s, so cutting at up to 29s in always leaves
    /// more than 1s behind, well clear of any minimum-length floor.
    private static let searchStartSeconds = 20.0
    private static let searchEndSeconds = 29.0

    private let model: Qwen3ASRModel
    private let language: String?

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "Qwen3BatchDecoder")

    init(model: Qwen3ASRModel, language: String?) {
        self.model = model
        self.language = language
    }

    /// Downloads (first launch only, ~2GB for `.large`, into `~/Library/Caches/qwen3-speech/`) and
    /// loads the model. This is `Qwen3BatchDecoderPool`'s default `load`; pool tests inject a fake
    /// instead so they never touch the network.
    ///
    /// **No `progressHandler` is passed, deliberately.** `fromPretrained`'s progress callback is
    /// invoked off the main actor. A closure written at a call site that is `@MainActor`-isolated
    /// inherits that isolation, and the resulting `swift_task_checkIsolated` →
    /// `dispatch_assert_queue` failure kills the process with a bare SIGTRAP -- no message, no
    /// stack pointing at the closure. If progress reporting is ever wanted here, pass an
    /// explicitly `nonisolated` function, not an inline closure (design 45 §3.1).
    static func make(variant: Qwen3Variant, language: String?) async throws -> Qwen3BatchDecoder {
        let model = try await Qwen3ASRModel.fromPretrained(modelId: variant.modelId)
        return Qwen3BatchDecoder(model: model, language: language)
    }

    /// Decodes one window, splitting at low-energy points when it exceeds the model's 30s input.
    ///
    /// The split/join machinery is `BatchAsrDecoder`'s, reused rather than reimplemented: the
    /// silence-seeking cut and the CJK-aware join are model-independent, and having one
    /// implementation means a fix to either applies to both decoders.
    func transcribe(samples: [Float]) async throws -> String {
        let ranges = BatchAsrDecoder.splitForSingleWindowDecode(
            samples: samples,
            maxWindowSamples: Self.maxWindowSamples,
            searchStartSeconds: Self.searchStartSeconds,
            searchEndSeconds: Self.searchEndSeconds
        )
        guard ranges.count > 1 else {
            return transcribeSingleWindow(samples)
        }
        var pieceTexts: [String] = []
        pieceTexts.reserveCapacity(ranges.count)
        for range in ranges {
            let trimmed = transcribeSingleWindow(Array(samples[range]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            pieceTexts.append(trimmed)
        }
        return BatchAsrDecoder.joinPieceTexts(pieceTexts)
    }

    /// `Qwen3ASRModel.transcribe` is synchronous and non-throwing; actor isolation is what keeps
    /// concurrent callers from entering it at once.
    private func transcribeSingleWindow(_ samples: [Float]) -> String {
        model.transcribe(audio: samples, sampleRate: 16_000, language: language)
    }
}

// MARK: - Qwen3BatchDecoderLease

/// Release-bearing handle returned by `Qwen3BatchDecoderPool.acquire`, with the same idempotent
/// `release()` contract as `BatchAsrDecoderLease` (design 33 MT7/MT8): callers only obtain one by
/// acquiring successfully, and calling it more than once is a no-op, so an unbalanced release is
/// impossible by construction.
final class Qwen3BatchDecoderLease: Sendable {
    let decoder: Qwen3BatchDecoder

    private let hasReleased = OSAllocatedUnfairLock(initialState: false)
    private let onRelease: @Sendable () -> Void

    init(decoder: Qwen3BatchDecoder, onRelease: @escaping @Sendable () -> Void) {
        self.decoder = decoder
        self.onRelease = onRelease
    }

    func release() {
        let shouldRelease = hasReleased.withLock { alreadyReleased -> Bool in
            guard !alreadyReleased else { return false }
            alreadyReleased = true
            return true
        }
        guard shouldRelease else { return }
        onRelease()
    }
}

// MARK: - Qwen3BatchDecoderPool

/// Process-wide refcounted registry of warm `Qwen3BatchDecoder`s, one per (variant, language)
/// pair. Mirrors `BatchAsrDecoderPool`'s semantics exactly -- single-flight load on the first
/// holder, refcount returned on failure *or* cancellation, freed at refcount 0 -- because the
/// callers (`TranscriptPipeline.prepare` / `stopAndDrain`) treat the two interchangeably.
///
/// A dictionary keyed on the variant is enough here (unlike `BatchAsrDecoderPool`'s array, which
/// exists only because FluidAudio's `AsrModelVersion` is not `Hashable`), but the language is part
/// of the key: it is baked into the decoder at construction and two sessions on different languages
/// must not share one.
actor Qwen3BatchDecoderPool {
    static let shared = Qwen3BatchDecoderPool()

    private struct Key: Hashable {
        let variant: Qwen3Variant
        let language: String?
    }

    private struct Entry {
        var decoder: Qwen3BatchDecoder?
        var loadTask: Task<Qwen3BatchDecoder, Error>?
        var refcount = 0
    }

    private let load: @Sendable (Qwen3Variant, String?) async throws -> Qwen3BatchDecoder
    private var entries: [Key: Entry] = [:]

    init(
        load: @escaping @Sendable (Qwen3Variant, String?) async throws -> Qwen3BatchDecoder =
            Qwen3BatchDecoder.make(variant:language:)
    ) {
        self.load = load
    }

    func acquire(variant: Qwen3Variant, language: String?) async throws -> Qwen3BatchDecoderLease {
        let key = Key(variant: variant, language: language)
        entries[key, default: Entry()].refcount += 1

        if let cached = entries[key]?.decoder {
            return makeLease(key: key, decoder: cached)
        }

        let task: Task<Qwen3BatchDecoder, Error>
        if let inFlight = entries[key]?.loadTask {
            task = inFlight
        } else {
            let load = self.load
            let newTask = Task { try await load(variant, language) }
            entries[key]?.loadTask = newTask
            task = newTask
        }

        do {
            let decoder = try await task.value
            if entries[key] != nil {
                entries[key]?.decoder = decoder
                entries[key]?.loadTask = nil
            }
            // Cancellation while suspended on a possibly-shared load: the load itself continues for
            // other holders, but this acquire must not hand out a lease and must give its refcount
            // back (design 33 MT8).
            if Task.isCancelled {
                decrementRefcount(key: key)
                throw CancellationError()
            }
            return makeLease(key: key, decoder: decoder)
        } catch {
            // Clear the settled (failed) task before decrementing so a later acquire starts a fresh
            // load instead of joining this dead one and rethrowing the same stale error.
            entries[key]?.loadTask = nil
            decrementRefcount(key: key)
            throw error
        }
    }

    /// Test-only peek at a key's live refcount. `release()` reaches this actor through a
    /// fire-and-forget `Task`, so tests poll this to observe the hop having landed.
    func refcountForTesting(variant: Qwen3Variant, language: String?) -> Int {
        entries[Key(variant: variant, language: language)]?.refcount ?? 0
    }

    private func decrementRefcount(key: Key) {
        guard var entry = entries[key] else { return }
        entry.refcount -= 1
        if entry.refcount <= 0 {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = entry
        }
    }

    private func makeLease(key: Key, decoder: Qwen3BatchDecoder) -> Qwen3BatchDecoderLease {
        Qwen3BatchDecoderLease(decoder: decoder) { [weak self] in
            guard let self else { return }
            Task { await self.decrementRefcount(key: key) }
        }
    }
}

#endif
