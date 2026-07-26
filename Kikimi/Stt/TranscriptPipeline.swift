import AVFoundation
import Foundation
import OSLog
import os

// MARK: - TranscriptPipeline

/// Glue component wiring `AudioCapture`'s two independent audio streams (`docs/design/01-audio-capture.md`)
/// through the two independent `SttEngine` instances (`docs/design/11-streaming-stt.md` section 3.1, "2
/// ストリーム独立処理") and into `SessionHandle.appendTranscriptSegment(source:startMs:endMs:text:confidence:)`
/// (`docs/design/07-session-store.md` section 5.2). Does not appear in kikimi.md's 13章 component table, but
/// is required at the same granularity as `AudioCapture`/`SessionHandle` to connect them.
///
/// ## Call-order contract (section 9.2 of the previous batch-era design; unchanged by the streaming rewrite)
///
/// Honoring this order is the caller's responsibility (the Session Window ViewModel,
/// `docs/design/06-ui-panels.md`), **not** something `TranscriptPipeline` enforces itself:
///
/// ```
/// ① SessionStore.beginRecording(_:)         (07-session-store.md 9章: exclusivity, meta.json update)
/// ② TranscriptPipeline.prepare(...)          (this file: model download/prepare if not yet installed)
/// ③ AudioCapture(sessionDirectory:).start()  (01-audio-capture.md 5章: starts WAV writing)
/// ④ audioCapture.delegate = transcriptPipeline (may happen any time before ③)
///
/// ... recording in progress ...
///
/// ⑤ AudioCapture.stop()                      (01-audio-capture.md)
/// ⑥ TranscriptPipeline.stopAndDrain()        (this file: waits until the last segment has been
///                                              appended via appendTranscriptSegment)
/// ⑦ SessionStore.endRecording(_:)            (07-session-store.md 9章: commits state=ended)
/// ```
///
/// Placing ⑥ before ⑦ matters: if `SessionStore.endRecording(_:)` commits `meta.json.state = "ended"`
/// before `stopAndDrain()` has finished flushing buffered audio through both `SttEngine`s, a
/// `transcript.jsonl` line can still be appended after `state` reads `ended`, momentarily breaking the
/// `segmentCount` vs. actual line count invariant that `07-session-store.md`'s layer-1 tests assert on.
/// This contract is not yet reflected in `07-session-store.md` section 15's boundary table (design doc
/// section 9.2 open item).
final class TranscriptPipeline: AudioCaptureDelegate {
    /// Carries one converted buffer's samples, plus the elapsed-time anchor `SttEngine.feed` needs
    /// (section 3.4), from `didCapture` to the dedicated per-source feed `Task` (section 3.3).
    ///
    /// Samples are extracted from the `AVAudioPCMBuffer` synchronously inside `didCapture` (on
    /// `AudioCapture`'s `eventQueue`) instead of carrying the buffer object itself: the same buffer
    /// instance is concurrently read by the WAV writer (audio/writer thread) and the level meter
    /// (`eventQueue`), and `AVAudioPCMBuffer` is not thread-safe. Reading `floatChannelData` from
    /// the feed `Task` while another thread was first-touching its lazily built channel-pointer
    /// array crashed with a NULL channel pointer (SIGSEGV, memmove from 0x0, 2026-07-02). `[Float]`
    /// has value semantics, so nothing shared crosses the thread boundary anymore.
    private struct PendingBuffer: Sendable {
        var samples: [Float]
        var elapsedAtBufferStart: TimeInterval
    }

    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "TranscriptPipeline")

    private let sessionHandle: SessionHandle
    private let micEngine: SttEngine
    private let systemEngine: SttEngine
    /// `docs/design/33-meeting-two-pass-decode.md` MT10: this recording's snapshot of
    /// `SttEngineConfig.twoPassDecode`, read once at `init` (never re-read mid-recording).
    private let twoPassDecode: Bool
    /// The resolved STT language (`SttEngineConfig.language`), used to pick the batch decoder's
    /// `AsrModelVersion` (MT1) once `prepare()` decides to acquire one.
    private let language: String
    /// Forwarded verbatim to `SttWindowRedecode.resplit(...)` (section 3.4/MT3).
    private let maxSegmentCharacters: Int
    /// Injectable acquire function for the shared two-pass batch decoder (MT7/MT8's default pool
    /// path; tests substitute a fake that never touches FluidAudio, section 3.1's seam).
    private let batchDecoderAcquire: @Sendable (String) async throws -> AcquiredBatchDecoder
    /// Set once `prepare()`'s acquire `Task` (below) resolves successfully; read by both forwarding
    /// `Task`s at redecode time (MT5). `OSAllocatedUnfairLock`-protected like `onDegradeStorage`
    /// below -- written from the acquire `Task`, read from two other `Task`s, no closure-box needed
    /// since what's stored is a `Sendable` struct wrapping an actor reference, not a bare closure
    /// read in a hot per-buffer loop (`onSystemAudioStorage`'s doc comment explains why *that* one
    /// needs boxing; this one is read at most once per confirmed window).
    private let batchDecoderStorage = OSAllocatedUnfairLock<AcquiredBatchDecoder?>(initialState: nil)
    /// The in-flight (or already-resolved) acquire `Task`, held so `stopAndDrain()` can `cancel()` ->
    /// `await` it and release the lease exactly once if one was obtained (MT8). `nil` when
    /// `twoPassDecode` is `false` -- two-pass OFF never touches the pool at all.
    private let batchDecoderAcquireTaskStorage = OSAllocatedUnfairLock<Task<AcquiredBatchDecoder, Error>?>(initialState: nil)
    /// `true` once `startBatchDecoderAcquire()`'s `Task` has actually installed the decoder into
    /// `batchDecoderStorage` -- the exact moment from which a newly-confirmed window is re-decoded
    /// (MT5) rather than falling back to streaming text. Exists so tests can wait on that transition
    /// instead of sleeping a fixed interval and hoping the acquire won the race; a fixed sleep here
    /// made `TranscriptPipelineTwoPassTests` flaky under parallel test load, silently turning
    /// "decoded by batch" expectations into streaming-fallback text.
    var hasAcquiredBatchDecoder: Bool {
        batchDecoderStorage.withLock { $0 != nil }
    }
    /// This recording segment's `startMsOffset` (kikimi.md 5/6 章): added to every
    /// `SttFinalizedSegment.startMs`/`endMs` (which are relative to *this instance's* own
    /// `AudioCapture.start()`, since a fresh `TranscriptPipeline`/`SttEngine` pair is created for
    /// every recording segment, section 3 "cache-aware streaming... fresh start") before appending
    /// to `transcript.jsonl`, so `TranscriptSegment.startMs` lands on the cumulative "recording
    /// active time" timeline that spans every segment in the session.
    private let startMsOffset: Int

    /// Forward `SttEngine.confirmedWindows` (redecoded or falling back, MT4) into
    /// `SessionHandle.appendTranscriptSegment`. One per source (section 5.2).
    private var micForwardingTask: Task<Void, Never>?
    private var systemForwardingTask: Task<Void, Never>?

    /// Section 3.3: one buffer queue + one dedicated consumer `Task` per source, so that the order in
    /// which buffers are enqueued to the `SttEngine` actor's mailbox can never drift from the order
    /// `didCapture` delivered them in. `didCapture` only ever `yield`s into these continuations
    /// synchronously on `AudioCapture`'s `eventQueue` — it never spawns a `Task` itself (section 3.3).
    private let micBufferStream: AsyncStream<PendingBuffer>
    private let micBufferContinuation: AsyncStream<PendingBuffer>.Continuation
    private let systemBufferStream: AsyncStream<PendingBuffer>
    private let systemBufferContinuation: AsyncStream<PendingBuffer>.Continuation

    /// The dedicated per-source consumer `Task`s described above (section 3.3). Each runs
    /// `for await pending in <source>BufferStream { await <source>Engine.feed(...) }`, so a given
    /// `feed()` call is never enqueued to the `SttEngine` actor until the previous one has actually
    /// completed — this single-task-driven-by-`for-await` shape is what makes per-source FIFO ordering
    /// structural rather than incidental (section 3.3). Mic/system order relative to each other is
    /// deliberately not coordinated; `start_ms`/`end_ms` remain the only cross-source time reference
    /// (kikimi.md 6章).
    private var micFeedTask: Task<Void, Never>?
    private var systemFeedTask: Task<Void, Never>?

    /// Backing storage for `liveSegments` (`docs/design/06-ui-panels.md` section 6.3, "Transcript タブ"
    /// live update). `liveSegmentsContinuation` is only ever `yield`ed to by `appendOrLog(_:source:to:logger:liveSegmentsContinuation:)`,
    /// and only *after* `SessionHandle.appendTranscriptSegment` has actually returned successfully (i.e.
    /// the segment's `id` is already durable in `transcript.jsonl`). A failed append is logged there and
    /// never reaches this stream — see that method's doc comment for why. `AsyncStream.Continuation` is
    /// `Sendable`, so it is safe to capture into the two per-source forwarding `Task`s below (section
    /// 5.2) without capturing `self`.
    private let liveSegmentsStream: AsyncStream<TranscriptSegment>
    private let liveSegmentsContinuation: AsyncStream<TranscriptSegment>.Continuation

    /// Backing storage for `volatileTranscripts` (section 3.6). Fed by two per-source forwarding
    /// `Task`s in `startForwarding()`, mirroring `confirmedWindows`' own forwarding shape.
    private let volatileTranscriptsStream: AsyncStream<SttVolatileTranscript>
    private let volatileTranscriptsContinuation: AsyncStream<SttVolatileTranscript>.Continuation
    private var micVolatileForwardingTask: Task<Void, Never>?
    private var systemVolatileForwardingTask: Task<Void, Never>?

    /// Reference-type box for closures stored inside `OSAllocatedUnfairLock`.
    ///
    /// Storing a function value *directly* as the lock's generic `State` makes every
    /// `withLock { $0 }` read re-abstract the function through a reabstraction thunk and write the
    /// re-wrapped value back -- the stored closure grows one wrapper layer per read (~26 layers/sec in
    /// `onSystemAudioStorage`'s per-buffer feed loop below). After a >30 min recording the wrapper
    /// chain exceeds 50k links and its recursive deinit overflows the main thread's stack when the
    /// pipeline is released (SIGSEGV at meeting end, reproduced 2026-07-06; crash reports show
    /// recursion depth 52,214, all four samples). Boxing the closure in a `final class` means a read
    /// only copies a class reference -- no thunk, no chain.
    private final class DegradeHandlerBox: Sendable {
        let handler: @Sendable (AudioSourceKind, AudioCaptureError) -> Void
        init(_ handler: @escaping @Sendable (AudioSourceKind, AudioCaptureError) -> Void) {
            self.handler = handler
        }
    }

    /// Backing storage for `onDegrade` (`RecordingTranscriptPipelining`'s protocol doc comment).
    /// Lock-protected (mirroring `AudioCapture`'s own `OSAllocatedUnfairLock`-backed
    /// delegate-adjacent state, e.g. `writersStorage`) rather than a plain `var`: the setter is
    /// called from `MeetingWorkspaceViewModel.startRecording()` on `@MainActor`, while the getter is
    /// read from `audioCapture(_:didDegrade:error:)` below, which fires on `AudioCapture`'s
    /// `eventQueue` -- a different, non-`@MainActor` thread. `TranscriptPipeline` itself is not
    /// actor-isolated, so a plain `var` here would be a data race under strict concurrency.
    ///
    /// Stored boxed (`DegradeHandlerBox?`, see its doc comment) rather than as a bare closure to avoid
    /// the same reabstraction-thunk wrapper-chain growth `onSystemAudioStorage` suffered from --
    /// `onDegrade` fires far less often, but the underlying bug is structural, not frequency-dependent.
    private let onDegradeStorage = OSAllocatedUnfairLock<DegradeHandlerBox?>(initialState: nil)
    var onDegrade: (@Sendable (AudioSourceKind, AudioCaptureError) -> Void)? {
        get { onDegradeStorage.withLock { $0 }?.handler }
        set { onDegradeStorage.withLock { $0 = newValue.map(DegradeHandlerBox.init) } }
    }

    /// Forwarding hook for `docs/design/13-speaker-diarization.md` section 5: system-source samples
    /// are handed to this closure (if set) right after they are fed to `systemEngine`, in the same
    /// per-source feed `Task` (section 3.3) that drives the STT feed itself -- so the handler sees
    /// every buffer exactly once, in arrival order, with no risk of drifting ahead of or behind
    /// `SttEngine.feed(...)`. `TranscriptPipeline` never talks to `RealtimeDiarizationCoordinator`
    /// directly (same isolation goal as `onDegrade` above, and as `DiarizationBackend`'s own doc
    /// comment: "a future model/vendor swap only touches this file plus its replacement") -- the
    /// caller (`MeetingWorkspaceViewModel`) wires this to `RealtimeDiarizationCoordinator.feed(samples:)`.
    ///
    /// `async` (unlike `onDegrade`, which is a fire-and-forget notification): the handler is `await`ed
    /// inline in the feed `Task`'s loop, so the coordinator actually finishes processing one buffer's
    /// samples before the next is handed to it -- the same ordering guarantee `systemBufferStream`'s
    /// single-consumer-`Task` shape already gives `SttEngine.feed(...)` (section 3.3's doc comment).
    /// Never invoked for `mic` samples: diarization only ever runs on the system stream (design
    /// section 1, "対象はシステム音声ストリームのみ"). Left unset (`nil`) whenever diarization is disabled
    /// or the caller has no coordinator for this segment (design section 8: "本機能のいかなる失敗も録音・
    /// 書き起こし...をブロックしない" -- a `nil` handler here costs nothing beyond the `nil` check).
    ///
    /// Stored boxed (`SystemAudioHandlerBox?`, see `DegradeHandlerBox`'s doc comment above for the
    /// full reabstraction-thunk rationale) rather than as a bare closure: this storage is read once
    /// per audio buffer in `startForwarding()`'s `systemFeedTask` loop below (~26 times/sec), so a
    /// bare-closure `State` here is exactly the shape that produced the meeting-end crash.
    private final class SystemAudioHandlerBox: Sendable {
        let handler: @Sendable ([Float]) async -> Void
        init(_ handler: @escaping @Sendable ([Float]) async -> Void) {
            self.handler = handler
        }
    }

    private let onSystemAudioStorage = OSAllocatedUnfairLock<SystemAudioHandlerBox?>(initialState: nil)
    var onSystemAudio: (@Sendable ([Float]) async -> Void)? {
        get { onSystemAudioStorage.withLock { $0 }?.handler }
        set { onSystemAudioStorage.withLock { $0 = newValue.map(SystemAudioHandlerBox.init) } }
    }

    /// `docs/design/06-ui-panels.md` section 6.3: yields one `TranscriptSegment` per successful
    /// `transcript.jsonl` append, in append order. `06-ui-panels.md`'s `MeetingWorkspaceViewModel`
    /// subscribes to this after `startRecording()` succeeds to drive the Transcript タブ's live update
    /// (`start_ms`-sorted insertion, not a plain append — see that document's `TranscriptRowList`).
    ///
    /// Write failures are intentionally **not** surfaced through this stream: kikimi.md 8.5章
    /// "リアルタイム表示は生 JSONL の内容で行われる" means the live UI must stay consistent with what is
    /// actually durable on disk, not with what was merely attempted. A failed append is instead reported
    /// through a separate channel (`WorkspaceBanner.transcriptWriteFailed`, `06-ui-panels.md`), so the
    /// display-omission and the failure-notification are two independent, non-conflated signals.
    ///
    /// `nonisolated` because `TranscriptPipeline` is not itself actor-isolated and this property only
    /// vends an immutable, `Sendable` `AsyncStream` value set once at `init` — safe to read from any
    /// isolation context.
    nonisolated var liveSegments: AsyncStream<TranscriptSegment> {
        liveSegmentsStream
    }

    /// Section 3.6: one source-tagged stream carrying each source's current pending-segment text,
    /// replacing `SttEngine.volatileTranscripts` per-engine streams with a single merged one the UI can
    /// subscribe to alongside `liveSegments`. Replaces the previous batch-era `previewCleared`
    /// reference (which this file never itself forwarded; `06-ui-panels.md` was expected to subscribe
    /// per-engine directly — streaming instead has real incremental text worth merging here).
    nonisolated var volatileTranscripts: AsyncStream<SttVolatileTranscript> {
        volatileTranscriptsStream
    }

    /// - Parameters:
    ///   - sessionHandle: The single owner of this session's `transcript.jsonl` (07-session-store.md).
    ///   - startMsOffset: This recording segment's `RecordingSegment.startMsOffset` (kikimi.md 5/6
    ///     章); `0` for a session's very first segment. See `startMsOffset`'s doc comment.
    ///   - config: Shared mic/system `SttEngineConfig` (language/chunk_ms/segment confirmation tuning,
    ///     `docs/design/11-streaming-stt.md` section 3.9), forwarded to both `SttEngine`s unchanged.
    ///   - backendFactory: Shared mic/system `SttEngine.BackendFactory`. Defaults to
    ///     `FluidAudioSttBackendFactory.makeBackend`, whose `SttSharedModelCoordinator` transparently
    ///     dedups the expensive shared-model preload across the two `SttEngine`s this initializer
    ///     constructs (section 3.7). Injectable so tests never depend on a real, possibly-not-downloaded
    ///     FluidAudio model or network access.
    ///   - batchDecoderAcquire: Acquires the shared two-pass batch decoder (MT1/MT7/section 3.1).
    ///     Defaults to `defaultBatchDecoderAcquire`, which resolves `config.language` to an
    ///     `AsrModelVersion` and acquires it from `BatchAsrDecoderPool.shared`. Injectable so tests
    ///     never touch FluidAudio's network path; only ever called when `config.twoPassDecode` is
    ///     `true` (MT10's OFF-means-untouched guarantee).
    init(
        sessionHandle: SessionHandle,
        startMsOffset: Int = 0,
        config: SttEngineConfig = SttEngineConfig(),
        backendFactory: @escaping SttEngine.BackendFactory = FluidAudioSttBackendFactory.makeBackend,
        batchDecoderAcquire: @escaping @Sendable (String) async throws -> AcquiredBatchDecoder = TranscriptPipeline.defaultBatchDecoderAcquire
    ) {
        self.sessionHandle = sessionHandle
        self.startMsOffset = startMsOffset
        self.twoPassDecode = config.twoPassDecode
        self.language = config.language
        self.maxSegmentCharacters = config.maxSegmentCharacters
        self.batchDecoderAcquire = batchDecoderAcquire
        self.micEngine = SttEngine(source: .mic, config: config, backendFactory: backendFactory)
        self.systemEngine = SttEngine(source: .system, config: config, backendFactory: backendFactory)
        (micBufferStream, micBufferContinuation) = AsyncStream.makeStream()
        (systemBufferStream, systemBufferContinuation) = AsyncStream.makeStream()
        (liveSegmentsStream, liveSegmentsContinuation) = AsyncStream.makeStream()
        (volatileTranscriptsStream, volatileTranscriptsContinuation) = AsyncStream.makeStream()
    }

    // MARK: - Lifecycle

    /// Prepares both `SttEngine`s (shared model preload/download → per-stream backend construction,
    /// section 3.2/3.7) and, once both have succeeded, starts the forwarding/feeding `Task`s
    /// (`startForwarding()`).
    ///
    /// The two `prepare()` calls run concurrently via `async let`; this is intentional (section 3.7) —
    /// `SttSharedModelCoordinator`'s single-flight join is what prevents this from downloading/loading
    /// the shared model bundle twice, not serialization at this call site. The caller (step ②) must
    /// await this method's success before calling `AudioCapture.start()` (step ③).
    ///
    /// - Throws: Whatever either `SttEngine.prepare(downloadProgress:)` throws (e.g. model download
    ///   failure). If either side throws, `AudioCapture.start()` must not be called; the recording never
    ///   reaches step ③ of the contract above.
    func prepare(
        downloadProgress: (@Sendable (AudioSourceKind, SttModelDownloadProgress) -> Void)? = nil
    ) async throws {
        async let mic: Void = micEngine.prepare { downloadProgress?(.mic, $0) }
        async let system: Void = systemEngine.prepare { downloadProgress?(.system, $0) }
        try await mic
        try await system
        if twoPassDecode {
            startBatchDecoderAcquire()
        }
        startForwarding()
    }

    /// Starts the two-pass batch decoder acquire as a `Task` running concurrently with the recording
    /// itself (`docs/design/33-meeting-two-pass-decode.md` MT8) -- never awaited here, so a slow or
    /// failing model download/load never delays `prepare()`'s return or blocks step ③
    /// (`AudioCapture.start()`). Windows confirmed before this resolves simply fall back to streaming
    /// text (`redecodeOrFallback`'s `decoder == nil` guard); `stopAndDrain()` cancels and awaits this
    /// same `Task` to release the lease exactly once if one was ever obtained (MT8).
    private func startBatchDecoderAcquire() {
        let acquire = batchDecoderAcquire
        let language = language
        let task = Task<AcquiredBatchDecoder, Error> { [weak self, logger] in
            do {
                let acquired = try await acquire(language)
                self?.batchDecoderStorage.withLock { $0 = acquired }
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
        batchDecoderAcquireTaskStorage.withLock { $0 = task }
    }

    /// Starts the four long-lived `Task`s this pipeline owns while recording: one buffer-feeding `Task`
    /// per source (section 3.3) and one segment-forwarding `Task` per source (section 5.2). Called once,
    /// after both `SttEngine`s have finished `prepare()`.
    private func startForwarding() {
        micForwardingTask = Task { [micEngine, sessionHandle, logger, liveSegmentsContinuation, startMsOffset, twoPassDecode, maxSegmentCharacters, batchDecoderStorage] in
            for await window in micEngine.confirmedWindows {
                let outcome = await Self.redecodeWindowIfEnabled(
                    window,
                    twoPassDecode: twoPassDecode,
                    batchDecoderStorage: batchDecoderStorage,
                    maxSegmentCharacters: maxSegmentCharacters,
                    logger: logger
                )
                for segment in outcome.segments {
                    await Self.appendOrLog(
                        segment,
                        source: .mic,
                        startMsOffset: startMsOffset,
                        to: sessionHandle,
                        logger: logger,
                        liveSegmentsContinuation: liveSegmentsContinuation,
                        sttSource: outcome.sttSource
                    )
                }
            }
        }
        systemForwardingTask = Task { [systemEngine, sessionHandle, logger, liveSegmentsContinuation, startMsOffset, twoPassDecode, maxSegmentCharacters, batchDecoderStorage] in
            for await window in systemEngine.confirmedWindows {
                let outcome = await Self.redecodeWindowIfEnabled(
                    window,
                    twoPassDecode: twoPassDecode,
                    batchDecoderStorage: batchDecoderStorage,
                    maxSegmentCharacters: maxSegmentCharacters,
                    logger: logger
                )
                for segment in outcome.segments {
                    await Self.appendOrLog(
                        segment,
                        source: .system,
                        startMsOffset: startMsOffset,
                        to: sessionHandle,
                        logger: logger,
                        liveSegmentsContinuation: liveSegmentsContinuation,
                        sttSource: outcome.sttSource
                    )
                }
            }
        }
        // Section 3.3: the dedicated buffer-feeding consumer Task per source. A single Task driving
        // `feed()` via `for await` (rather than a fresh `Task` per `didCapture` call) is what guarantees
        // enqueue order to the `SttEngine` actor can never drift from arrival order.
        micFeedTask = Task { [micEngine, micBufferStream] in
            for await pending in micBufferStream {
                await micEngine.feed(samples: pending.samples, elapsedAtBufferStart: pending.elapsedAtBufferStart)
            }
        }
        systemFeedTask = Task { [systemEngine, systemBufferStream, onSystemAudioStorage] in
            for await pending in systemBufferStream {
                await systemEngine.feed(samples: pending.samples, elapsedAtBufferStart: pending.elapsedAtBufferStart)
                // `docs/design/13-speaker-diarization.md` section 5: forwarded *after* the STT feed
                // above so a diarization hook can never delay/reorder the STT path itself -- this is
                // strictly additive. Read fresh on every iteration (not captured once outside the
                // loop) so a handler set after `startForwarding()` has already begun (e.g. once
                // `RealtimeDiarizationCoordinator.beginSegment(...)` finishes) still takes effect for
                // every buffer arriving afterward.
                if let handler = onSystemAudioStorage.withLock({ $0 })?.handler {
                    await handler(pending.samples)
                }
            }
        }
        // Section 3.6: forward each engine's `volatileTranscripts` into the single merged,
        // source-tagged stream.
        micVolatileForwardingTask = Task { [micEngine, volatileTranscriptsContinuation] in
            for await text in micEngine.volatileTranscripts {
                volatileTranscriptsContinuation.yield(SttVolatileTranscript(source: .mic, text: text))
            }
        }
        systemVolatileForwardingTask = Task { [systemEngine, volatileTranscriptsContinuation] in
            for await text in systemEngine.volatileTranscripts {
                volatileTranscriptsContinuation.yield(SttVolatileTranscript(source: .system, text: text))
            }
        }
        // Forwarding `failures` (for UI/logging) is left to `06-ui-panels.md`'s own subscription; only
        // forwarding `confirmedWindows`/`volatileTranscripts` is mandatory here.
    }

    /// Appends one finalized segment to `transcript.jsonl` via `SessionHandle`, then — only if that
    /// append actually succeeded and returned the now-`id`-assigned `TranscriptSegment` — yields it into
    /// `liveSegmentsContinuation` (`06-ui-panels.md` section 6.3, `liveSegments`). Failure is logged and
    /// swallowed rather than propagated: "録音は絶対に止めない" (kikimi.md 8.5章) applies to this forwarding
    /// path too — one failed append must not stop later segments (this source or the other) from being
    /// attempted (section 11, failure mode #6). A failed append is deliberately **not** yielded to
    /// `liveSegmentsContinuation`: kikimi.md 8.5章 "リアルタイム表示は生 JSONL の内容で行われる" means the
    /// live Transcript タブ must only ever show what actually made it into `transcript.jsonl`. Write
    /// failures are surfaced to the user through a separate channel
    /// (`WorkspaceBanner.transcriptWriteFailed`, `06-ui-panels.md`), not by this stream.
    ///
    /// Not `private` so `KikimiTests/Stt/TranscriptPipelineLiveSegmentsTests.swift` can exercise the
    /// success/failure-yield behavior directly against a real `SessionHandle` and a test-owned
    /// `AsyncStream.Continuation`, without needing a real `SttEngine`/model (mirroring this file's
    /// existing testability constraints — see `TranscriptPipelineTests.swift`'s doc comment).
    ///
    /// - Parameters:
    ///   - startMsOffset: Added to `segment.startMs`/`endMs` (which are relative to this recording
    ///     segment's own `AudioCapture.start()`) before appending, so the persisted
    ///     `TranscriptSegment.startMs`/`endMs` land on the cumulative "recording active time"
    ///     timeline (kikimi.md 5/6 章). See `TranscriptPipeline.startMsOffset`'s doc comment.
    ///   - sttSource: Passed straight through to `SessionHandle.appendTranscriptSegment(sttSource:)`
    ///     (`docs/design/33-meeting-two-pass-decode.md` MT9): `"batch"` on a successful two-pass
    ///     re-decode, `nil` for every fallback path and when two-pass is off.
    static func appendOrLog(
        _ segment: SttFinalizedSegment,
        source: AudioSourceKind,
        startMsOffset: Int = 0,
        to sessionHandle: SessionHandle,
        logger: Logger,
        liveSegmentsContinuation: AsyncStream<TranscriptSegment>.Continuation,
        sttSource: String? = nil
    ) async {
        do {
            let appended = try await sessionHandle.appendTranscriptSegment(
                source: source,
                startMs: segment.startMs + startMsOffset,
                endMs: segment.endMs + startMsOffset,
                text: segment.text,
                confidence: segment.confidence,
                sttSource: sttSource
            )
            liveSegmentsContinuation.yield(appended)
        } catch {
            logger.error(
                "Failed to append a \(source.rawValue, privacy: .public) transcript segment: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - AudioCaptureDelegate

    func audioCapture(
        _ capture: AudioCapture,
        didCapture buffer: AVAudioPCMBuffer,
        source: AudioSourceKind,
        elapsed: TimeInterval
    ) {
        // Called on AudioCapture's eventQueue (01-audio-capture.md 5.1節). Section 3.3: no Task is spawned
        // here — this only synchronously `yield`s into the per-source buffer continuation. `yield` is
        // non-blocking, and eventQueue's FIFO ordering is carried straight through into the buffer queue.
        //
        // Samples are copied out *here*, on eventQueue, before the buffer object is left behind —
        // see `PendingBuffer`'s doc comment for the thread-safety rationale. This also serializes
        // the only two `floatChannelData` readers (this extraction and `AudioCapture`'s RMS level
        // meter) onto the same queue.
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              buffer.format.channelCount == 1
        else {
            logUnsupportedFormatOnce(source: source)
            return
        }
        let samples = SttEngine.extractSamples(from: buffer)
        guard !samples.isEmpty else {
            return
        }
        let pending = PendingBuffer(samples: samples, elapsedAtBufferStart: elapsed)
        switch source {
        case .mic:
            micBufferContinuation.yield(pending)
        case .system:
            systemBufferContinuation.yield(pending)
        }
    }

    /// `AudioCapture`'s contract guarantees Float32/16kHz/mono buffers, so a mismatch is a
    /// programming error worth surfacing — but only once, not per 64ms buffer. Only ever touched
    /// on `eventQueue` (the sole caller is `didCapture`), so a plain `var` is race-free.
    private var hasLoggedUnsupportedFormat = false

    private func logUnsupportedFormatOnce(source: AudioSourceKind) {
        guard !hasLoggedUnsupportedFormat else {
            return
        }
        hasLoggedUnsupportedFormat = true
        logger.warning(
            "dropping \(source.rawValue, privacy: .public) buffer(s) with unsupported format (expected Float32/mono/non-interleaved)"
        )
    }

    func audioCapture(_ capture: AudioCapture, didDegrade source: AudioSourceKind, error: AudioCaptureError) {
        // Recording continues; only the degraded source's own engine is stopped (kikimi.md 8.5章). The
        // remaining source (typically mic) keeps transcribing.
        logger.warning(
            "\(source.rawValue, privacy: .public) degraded (\(String(describing: error), privacy: .public)); stopping its SttEngine only."
        )
        let engine = source == .mic ? micEngine : systemEngine
        Task { await engine.stop() }
        // `docs/design/10-audio-input-selection.md` section 5.2 / 8章 failure modes #7/#9: forwards
        // this event so the caller can surface it as a `WorkspaceBanner` -- this class has no
        // UI-facing concept of a banner itself.
        onDegrade?(source, error)
    }

    func audioCapture(_ capture: AudioCapture, didUpdateLevel level: Double, source: AudioSourceKind) {
        // Out of scope for this document; `06-ui-panels.md` subscribes separately for level metering.
    }

    func audioCaptureDidStop(_ capture: AudioCapture) {
        // Intentional no-op: the normal stop flow always goes through the caller explicitly invoking
        // `stopAndDrain()` (section 9.2), so this delegate callback needs no additional teardown of its
        // own.
    }

    /// Must be called after `AudioCapture.stop()` and before `SessionStore.endRecording(_:)` (section 9.2,
    /// steps ⑤–⑦). Drains, in order:
    ///
    /// 1. Finish both buffer continuations, then await both feed `Task`s — guarantees every buffer
    ///    `didCapture` handed off before `AudioCapture.stop()` returned has been passed to `feed()`.
    /// 2. Await both `SttEngine.stop()` calls — each flushes any remaining chunk, drains its decode
    ///    queue, force-confirms any still-pending segment (section 3.2/3.3 route 4), then finishes its
    ///    `confirmedWindows`/`volatileTranscripts` streams.
    /// 3. Await all four forwarding `Task`s (two `confirmedWindows`, two `volatileTranscripts`) —
    ///    guarantees every window confirmed in step 2 has been re-decoded (or fallen back) and passed
    ///    to `SessionHandle.appendTranscriptSegment` (or logged as a failure) before this method
    ///    returns (`docs/design/33-meeting-two-pass-decode.md` MT5/MT8: this includes waiting for any
    ///    still-in-flight residual window's re-decode to finish).
    /// 4. Cancel the two-pass batch decoder acquire `Task` (if `twoPassDecode` is on) and await it,
    ///    releasing the lease exactly once if one was ever obtained (MT8) — done *last*, after every
    ///    forwarding `Task` has already finished using `batchDecoderStorage`, so the lease is never
    ///    released out from under an in-flight `transcribe` call above.
    ///
    /// Together these steps guarantee that once `stopAndDrain()` returns, everything captured up to
    /// `AudioCapture.stop()` has been reflected in `transcript.jsonl` — the property the caller relies on
    /// before calling `SessionStore.endRecording(_:)`.
    ///
    /// Finishing `liveSegmentsContinuation`/`volatileTranscriptsContinuation` last, only once all
    /// forwarding `Task`s have fully drained, guarantees every segment this method's guarantee above
    /// covers was also yielded to `liveSegments` (or logged as a failed append) before the stream ends —
    /// a `for await` consumer of either stream (`06-ui-panels.md` section 6.3) sees its loop terminate
    /// naturally instead of hanging once recording has fully stopped.
    func stopAndDrain() async {
        micBufferContinuation.finish()
        systemBufferContinuation.finish()
        _ = await micFeedTask?.value
        _ = await systemFeedTask?.value

        await micEngine.stop()
        await systemEngine.stop()
        _ = await micForwardingTask?.value
        _ = await systemForwardingTask?.value
        _ = await micVolatileForwardingTask?.value
        _ = await systemVolatileForwardingTask?.value

        liveSegmentsContinuation.finish()
        volatileTranscriptsContinuation.finish()

        if let acquireTask = batchDecoderAcquireTaskStorage.withLock({ $0 }) {
            acquireTask.cancel()
            if let acquired = try? await acquireTask.value {
                acquired.release()
            }
        }
    }
}
