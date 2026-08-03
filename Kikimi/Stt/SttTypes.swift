import Foundation

// MARK: - SttEngineConfig

/// Tunable parameters for `SttEngine`'s streaming pipeline. See `docs/design/11-streaming-stt.md`
/// section 3.3 (segment confirmation), section 3.9 (config.yaml mapping).
///
/// Replaces the previous VAD/decode-batch tuning (`speechStartThreshold` etc., ported from
/// Chirami's `SherpaOnnxEngine`); streaming has no VAD concept of its own (section 3 intro).
struct SttEngineConfig: Sendable, Equatable {
    /// FluidAudio language conditioning code (e.g. `"ja-JP"`), or `"auto"` for language detection.
    /// Forwarded to `StreamingNemotronMultilingualAsrManager.setLanguage(_:)` (section 2.4/3.9).
    var language: String = "ja-JP"

    /// Streaming chunk tier in milliseconds. FluidAudio only accepts 560/1120/2240/4480; **2240 is
    /// the recommended default for ja/zh multilingual** (spike `chunkTierDocs`: at 560ms the
    /// full-vocab joint-matmul overhead collapses RTFx from ~84-90x to ~21-23x). Section 3.9.
    var chunkMs: Int = 2_240

    /// Seconds of no new text growth after which a non-empty pending segment is force-confirmed
    /// (section 3.3 route 2 — recovers utterances that never receive trailing punctuation).
    var segmentIdleTimeout: TimeInterval = 2.0

    /// Character count above which a pending segment is force-confirmed regardless of punctuation
    /// (section 3.3 route 3, a runaway guard).
    var maxSegmentCharacters: Int = 120

    /// Sentence-ending characters that trigger segment confirmation (section 3.3 route 1). Nemotron
    /// auto-punctuates, so this is the primary confirmation path in practice.
    static let sentenceEndingCharacters: Set<Character> = ["。", "？", "！", "?", "!"]

    /// Soft boundary characters used to back off route 3's runaway guard (`docs/design/03-refinement-batch.md`
    /// section 15.1): commas, the katakana middle dot, closing brackets that typically follow a clause,
    /// and whitespace. None of these are sentence-ending on their own, but they mark plausible places to
    /// cut a pending segment that has exceeded `maxSegmentCharacters` without slicing a word in half.
    static let softBoundaryCharacters: Set<Character> = ["、", "，", "・", "」", "』", "）", "】", " ", "　"]

    /// FluidAudio's valid `chunkMs` tiers (section 3.9's `stt.chunk_ms`). Values outside this set
    /// should fall back to the default with a `.warning` log at the config-loading layer.
    static let validChunkMsTiers: Set<Int> = [560, 1_120, 2_240, 4_480]

    /// Batch re-decode of each confirmed window (`docs/design/33-meeting-two-pass-decode.md` MT2-MT13).
    /// Default `true` (MT10): the word-drop this feature fixes is unnoticeable to the user in the
    /// moment, so opt-in would leave it silently unfixed for most sessions. `false` restores the
    /// pre-design-33 streaming-only confirmation behavior byte for byte (MT9). Snapshotted at
    /// recording start like every other field here; not a runtime toggle (MT10).
    var twoPassDecode: Bool = true

    /// Which model performs that batch re-decode (`docs/design/45-qwen3-batch-decode.md` Q4):
    /// `"qwen3-1.7b"` / `"qwen3-0.6b"` / `"parakeet-ja"`. Carried here rather than read from
    /// `AppConfig` at decode time for the same reason as every other field on this struct -- it is
    /// snapshotted at recording start, so switching models mid-recording is not possible and the
    /// pipeline cannot observe a torn config (design 33 MT10).
    ///
    /// Validation happened at config decode (`SttConfig.init(from:)`); an unrecognized value
    /// reaching here still resolves to a working decoder via
    /// `TranscriptPipeline.resolveBatchModel`.
    var batchModel: String = SttConfig.default.batchModel
}

// MARK: - SttEngineState

/// Lifecycle state of an `SttEngine` instance. See `docs/design/11-streaming-stt.md` section 3.2/3.10.
enum SttEngineState: Equatable, Sendable {
    case idle
    /// `prepare()` is downloading/loading the streaming model.
    case preparing
    /// The backend has been created; `feed()` is accepted.
    case ready
    case stopped
}

// MARK: - SttEngineError

/// Failure modes surfaced by `SttEngine`, either by throwing from `prepare()` or via the
/// `failures` stream. See `docs/design/11-streaming-stt.md` section 3.10 for the full table.
enum SttEngineError: LocalizedError, Equatable, Sendable {
    /// `prepare()`'s model download/preload step failed (section 3.10 #1: network unreachable, etc.).
    case modelPreparationFailed(String)
    /// `prepare()`'s per-stream backend construction (`loadFromShared`/`setLanguage`) failed after
    /// the shared model bundle was itself preloaded successfully (section 3.10 #2).
    case recognizerCreationFailed(String)
    /// A fed buffer's format does not match the expected Float32/16kHz/mono contract (section 3.10 #5).
    case unsupportedAudioFormat
    /// A chunk transcription call (`SttStreamingBackend.processChunk`/`finish`) failed
    /// (section 3.10 #3). The offending chunk is skipped; the engine keeps running.
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelPreparationFailed(let message):
            return "Failed to prepare the STT model: \(message)"
        case .recognizerCreationFailed(let message):
            return "Failed to create the STT recognizer: \(message)"
        case .unsupportedAudioFormat:
            return "The audio buffer format is not supported (expected Float32/16kHz/mono)."
        case .transcriptionFailed(let message):
            return "STT transcription failed: \(message)"
        }
    }
}

// MARK: - SttFinalizedSegment

/// A confirmed transcript segment ready to be appended via
/// `SessionHandle.appendTranscriptSegment(source:startMs:endMs:text:confidence:)`.
/// See `docs/design/11-streaming-stt.md` section 3.2/3.4/3.5.
struct SttFinalizedSegment: Sendable, Equatable {
    /// Milliseconds since `AudioCapture.start()`, resolved at chunk granularity (section 3.4).
    var startMs: Int
    var endMs: Int
    var text: String
    /// STT confidence in the `0.0...1.0` range. Always `1.0`: streaming RNN-T per-token confidence
    /// is not exposed by the SDK (section 3.5, spike `timestamps`: `confidence` is hardcoded to
    /// `1.0` for every token).
    var confidence: Double
}

// MARK: - SttConfirmedWindow

/// One confirmation event's output: the streaming-confirmed pieces (>= 1, in order) plus the tiled
/// sample window they came from (`docs/design/33-meeting-two-pass-decode.md` MT2/MT3, section 3.2).
/// Replaces the previous per-piece `finalizedSegments: AsyncStream<SttFinalizedSegment>` -- every
/// piece confirmed within one `processChunkResult` call is now grouped with the audio window it was
/// confirmed from, so `TranscriptPipeline` can re-decode that window as a single unit (MT5) instead
/// of per piece.
///
/// The last piece may be the pending remainder consumed at the cut (MT13's residual consumption,
/// two-pass ON only), so `pieces`' concatenated text always covers exactly the window's audio --
/// there is never a gap between what streaming confirmed and what the window's samples contain.
struct SttConfirmedWindow: Sendable, Equatable {
    /// Confirmed pieces, in confirmation order. Never empty -- `SttEngine` never yields a window for
    /// an event that confirmed nothing (the audio simply stays retained for the next window).
    var pieces: [SttFinalizedSegment]
    /// The window's raw samples, ready for `BatchAsrDecoder.transcribe(samples:)`. Empty when
    /// `SttEngineConfig.twoPassDecode` is `false` (retention is never populated in that mode).
    var samples: [Float]
    /// Window bounds at chunk granularity (seconds since `AudioCapture.start()`, before
    /// `TranscriptPipeline.startMsOffset`). Used for the character-count-proportional re-split
    /// (`SttWindowRedecode`, section 3.4).
    var startElapsed: TimeInterval
    var endElapsed: TimeInterval
    /// `true` when the retention cap (MT6 (b)) dropped leading chunks since the previous cut -- the
    /// consumer must fall back to `pieces` instead of re-decoding a beheaded window (MT4). Always
    /// `false` when `twoPassDecode` is `false`.
    var truncated: Bool
}

// MARK: - SttModelDownloadStage / SttModelDownloadProgress

enum SttModelDownloadStage: String, Sendable, Equatable {
    case downloading
    case installing
}

/// Progress notification surfaced during `SttEngine.prepare(downloadProgress:)` (section 3.7).
/// Simplified relative to the previous sherpa-onnx-era type (no `receivedBytes`/`totalBytes`):
/// FluidAudio's `DownloadUtils.DownloadProgress` reports file-count-based, not byte-based, progress
/// (`.listing` / `.downloading(completedFiles:totalFiles:)` / `.compiling(modelName:)`), so this
/// type only carries what every phase can actually populate.
struct SttModelDownloadProgress: Sendable, Equatable {
    var stage: SttModelDownloadStage
    var fractionCompleted: Double
}

// MARK: - SttVolatileUpdate

/// One `SttEngine`'s volatile-transcript event (section 3.6). Carries both halves of what a single
/// `processChunkResult` call did to that engine's pending text, because the UI needs both to show a
/// continuous line:
///
/// - `text` — what is still pending after this event.
/// - `confirming` — what this event moved *out* of pending into `confirmedWindows`.
///
/// Splitting them exists to close the display gap the two-pass re-decode opens
/// (`docs/design/33-meeting-two-pass-decode.md` MT5): confirmation clears the pending text
/// immediately, but the confirmed row only reaches the UI after `TranscriptPipeline` has re-decoded
/// the window (RTF 0.046, i.e. ~1.15s for a 25s window per `docs/design/45-qwen3-batch-decode.md`)
/// and appended it to `transcript.jsonl`. With only `text` to go on, the UI had no choice but to
/// erase the line for that whole interval and then re-draw it — the flicker this field removes.
struct SttVolatileUpdate: Sendable, Equatable {
    /// The pending (not-yet-confirmed) segment's current full content. Empty means nothing pending.
    var text: String = ""
    /// This event's confirmed pieces, concatenated in confirmation order. Empty when the event
    /// confirmed nothing (the common case: text merely grew). Whitespace-only pieces that
    /// `confirmSegment` dropped are not represented here — they never become rows either.
    var confirming: String = ""
}

// MARK: - SttVolatileTranscript

/// One source's in-progress (unconfirmed) transcript text, replacing the previous
/// `previewCleared: AsyncStream<Void>` "clear signal" (which never carried text — the old batch
/// pipeline had no true partial/live preview). Streaming has real incremental text, so this now
/// carries it directly (section 3.2/3.6): each value is the *current full content* of the pending
/// (not-yet-confirmed) segment for `source`, replacing whatever was shown before. An empty `text`
/// means "nothing pending" — but *not* "erase the line": see `confirming`.
struct SttVolatileTranscript: Sendable, Equatable {
    var source: AudioSourceKind
    var text: String
    /// `SttVolatileUpdate.confirming` for this source — text that just left `text` and is now in
    /// flight toward `liveSegments`. The UI appends it to a per-source "confirming" buffer and
    /// keeps rendering it until that source's next `liveSegments` value arrives, so the line stays
    /// on screen across the two-pass re-decode instead of blinking out. See `SttVolatileUpdate`.
    var confirming: String = ""
}
