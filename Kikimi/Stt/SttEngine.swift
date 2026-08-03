import AVFoundation
import Foundation
import OSLog

// MARK: - SttEngine

/// One independent streaming transcription pipeline for a single audio source (mic or system audio).
///
/// `SttEngine` owns the full "PCM buffer → confirmed transcript segment" pipeline for exactly one
/// `AudioSourceKind` (`docs/design/11-streaming-stt.md` section 3.1's "2ストリーム独立処理" — unchanged
/// from the previous batch design): chunk accumulation (section 3.4), streaming inference via a
/// dedicated `SttDecodeWorker` actor (section 3.2), and segment confirmation (section 3.3).
/// `TranscriptPipeline` owns exactly two of these (`.mic` / `.system`) and wires their
/// `confirmedWindows` into a re-decode step and then `SessionHandle.appendTranscriptSegment`
/// (`docs/design/33-meeting-two-pass-decode.md` section 3.3).
///
/// `SttEngineConfig`/`SttEngineState`/`SttEngineError`/`SttFinalizedSegment`/`SttModelDownloadProgress`/
/// `SttVolatileTranscript` are defined in `SttTypes.swift`. `SttChunkAccumulator`/`SttExtractedChunk`/
/// `SttSegmentSplitResult` and the pure segment-confirmation helpers are defined in
/// `SttEngine+PureHelpers.swift`. `SttStreamingBackend`/`FluidAudioStreamingBackend`/
/// `SttSharedModelCoordinator`/`FluidAudioSttBackendFactory` are defined in `SttStreamingBackend.swift`.
actor SttEngine {
    /// Constructs the `SttStreamingBackend` used once `prepare()` succeeds. Injectable so tests can
    /// substitute a fake that never touches the network or a real model (section 3.12's "フェイク注入で
    /// `SttEngine` の状態遷移を検証する"). Defaults to `FluidAudioSttBackendFactory.makeBackend`, which
    /// transparently dedups the expensive shared model preload across the mic/system `SttEngine`s a
    /// single `TranscriptPipeline` constructs (section 3.7, via `SttSharedModelCoordinator`).
    typealias BackendFactory = @Sendable (
        SttEngineConfig,
        (@Sendable (SttModelDownloadProgress) -> Void)?
    ) async throws -> SttStreamingBackend

    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SttEngine")

    /// The audio source this instance transcribes. `nonisolated` so callers (e.g. `TranscriptPipeline`,
    /// log sites) can read it synchronously without hopping onto the actor.
    nonisolated let source: AudioSourceKind

    private let config: SttEngineConfig
    private let backendFactory: BackendFactory

    private(set) var state: SttEngineState = .idle

    /// Created in `prepare()` once the backend exists (section 3.2); `nil` before that. Inference is
    /// delegated to this separate actor so a slow chunk transcription never blocks `feed()`'s
    /// chunk-accumulation bookkeeping.
    private var decodeWorker: SttDecodeWorker?

    /// Chunk-granularity retention backing the two-pass re-decode window
    /// (`docs/design/33-meeting-two-pass-decode.md` MT2/MT6). Only ever appended to / cut / trimmed
    /// when `config.twoPassDecode` is `true`; otherwise stays permanently empty (matching pre-design-33
    /// memory behavior byte for byte, MT9/MT10).
    private var retention = SttWindowRetention()

    // MARK: Chunk accumulation (section 3.4)

    private var chunkAccumulator = SttChunkAccumulator()
    /// The elapsed time (seconds since `AudioCapture.start()`) of the most recent `feed()` call.
    /// Used by `stop()` to time-anchor the final flushed chunk (section 3.2 "残余バッファ...を最後の chunk
    /// として flush").
    private var lastFeedElapsed: TimeInterval = 0

    // MARK: Decode queue (section 3.2)

    private var chunkQueue: [SttExtractedChunk] = []
    private var isProcessingChunk = false

    // MARK: Segment confirmation state (section 3.3)

    /// The full cumulative transcript text last returned by the backend (spike
    /// `incrementalTextMode: "cumulative"`).
    private var cumulativeText = ""
    /// Character count (of `cumulativeText`) already emitted as `SttFinalizedSegment`s.
    private var confirmedCharacterCount = 0
    /// Elapsed time at which the currently-pending (unconfirmed) segment's text first appeared, or
    /// `nil` when there is no pending text. Becomes `startMs` once the segment is confirmed.
    private var pendingSegmentStartElapsed: TimeInterval?
    /// Elapsed time of the most recent chunk while pending text existed. Becomes `endMs` once the
    /// segment is confirmed.
    private var pendingSegmentEndElapsed: TimeInterval = 0
    /// Elapsed time at which `cumulativeText` last actually changed — the idle-timeout clock's origin
    /// (section 3.3 route 2).
    private var lastGrowthElapsed: TimeInterval = 0

    private let confirmedWindowsStream: AsyncStream<SttConfirmedWindow>
    private let confirmedWindowsContinuation: AsyncStream<SttConfirmedWindow>.Continuation
    private let volatileTranscriptsStream: AsyncStream<SttVolatileUpdate>
    private let volatileTranscriptsContinuation: AsyncStream<SttVolatileUpdate>.Continuation
    private let failuresStream: AsyncStream<SttEngineError>
    private let failuresContinuation: AsyncStream<SttEngineError>.Continuation

    /// Resumed once the decode queue has fully drained (`isDrained`). `stop()` awaits this.
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    /// Section 3.10 #2-ish: only warn once per engine instance, not once per dropped buffer.
    private var hasLoggedFeedWhileNotReady = false

    /// Set synchronously as the very first statement of `stop()`, before its first `await`. `SttEngine`
    /// is a reentrant actor, and `stop()` suspends multiple times (`waitUntilDrained()`,
    /// `decodeWorker.finish()`/`.reset()`) while `state` itself stays `.ready` until the very end; without
    /// this flag a `feed()` call scheduled during one of those suspensions would still pass the
    /// `state == .ready` guard and race `stop()`'s flush/drain/finish/reset sequence (re-accumulating
    /// into the already-flushed `chunkAccumulator`, or dispatching a stray `decodeWorker.processChunk`
    /// concurrently with `decodeWorker.finish()`/`.reset()`). Because this assignment happens before any
    /// suspension point in `stop()`, every `feed()` job the actor runs afterward is guaranteed to observe
    /// it, closing the race.
    private var isStopping = false

    init(
        source: AudioSourceKind,
        config: SttEngineConfig = SttEngineConfig(),
        backendFactory: @escaping BackendFactory = FluidAudioSttBackendFactory.makeBackend
    ) {
        self.source = source
        self.config = config
        self.backendFactory = backendFactory
        (confirmedWindowsStream, confirmedWindowsContinuation) = AsyncStream.makeStream()
        (volatileTranscriptsStream, volatileTranscriptsContinuation) = AsyncStream.makeStream()
        (failuresStream, failuresContinuation) = AsyncStream.makeStream()
    }

    /// Confirmed windows, in the order they were decoded (`docs/design/33-meeting-two-pass-decode.md`
    /// MT2/MT3/MT5/section 3.2). Finishes once `stop()` has fully drained the decode queue.
    nonisolated var confirmedWindows: AsyncStream<SttConfirmedWindow> {
        confirmedWindowsStream
    }

    /// The current content of the pending (unconfirmed) segment plus whatever the same event just
    /// confirmed out of it (section 3.2/3.6, see `SttVolatileUpdate`). Replaces the previous
    /// batch-era `previewCleared: AsyncStream<Void>`, which never carried text.
    nonisolated var volatileTranscripts: AsyncStream<SttVolatileUpdate> {
        volatileTranscriptsStream
    }

    /// Non-fatal error notifications (`state` does not change because of these; section 3.10).
    nonisolated var failures: AsyncStream<SttEngineError> {
        failuresStream
    }

    // MARK: - Lifecycle

    /// Model download/preload → per-stream backend construction → `state = .ready` (section 3.2/3.7).
    /// Idempotent: a no-op unless `state == .idle`.
    ///
    /// - Throws: `SttEngineError.modelPreparationFailed`/`.recognizerCreationFailed` (or whatever
    ///   `backendFactory` throws, for a test fake). On failure, `state` reverts to `.idle` so the
    ///   caller may retry.
    func prepare(
        downloadProgress: (@Sendable (SttModelDownloadProgress) -> Void)? = nil
    ) async throws {
        guard state == .idle else {
            return
        }
        state = .preparing
        do {
            let backend = try await backendFactory(config, downloadProgress)
            decodeWorker = SttDecodeWorker(backend: backend)
            state = .ready
        } catch {
            state = .idle
            throw error
        }
    }

    // MARK: - feed()

    /// Feeds one converted PCM buffer (Float32/16kHz/mono) into the chunk accumulator (section 3.4).
    /// Buffers fed while `state != .ready` are dropped (section 3.10); a `.warning`/`.debug` is logged
    /// only the first time this happens for this instance.
    ///
    /// IMPORTANT: `AVAudioPCMBuffer` is not thread-safe, so this overload must only be handed
    /// buffers that no other thread is still touching (e.g. test-local buffers). The production
    /// path (`TranscriptPipeline.didCapture`) extracts `[Float]` on the producer's `eventQueue`
    /// and calls `feed(samples:elapsedAtBufferStart:)` instead, because the same buffer object is
    /// concurrently read by the WAV writer and the level meter (crash 2026-07-02, memmove from 0x0
    /// via a half-initialized `floatChannelData`).
    func feed(buffer: AVAudioPCMBuffer, elapsedAtBufferStart: TimeInterval) async {
        guard state == .ready, !isStopping else {
            logFeedWhileNotReadyIfNeeded()
            return
        }

        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              buffer.format.channelCount == 1
        else {
            failuresContinuation.yield(.unsupportedAudioFormat)
            return
        }

        await feed(samples: Self.extractSamples(from: buffer), elapsedAtBufferStart: elapsedAtBufferStart)
    }

    /// Value-type variant of `feed(buffer:elapsedAtBufferStart:)`: takes samples already extracted
    /// on the producer's serial queue, so no shared `AVAudioPCMBuffer` object ever crosses a thread
    /// boundary into this actor.
    func feed(samples: [Float], elapsedAtBufferStart: TimeInterval) async {
        guard state == .ready, !isStopping else {
            logFeedWhileNotReadyIfNeeded()
            return
        }

        guard !samples.isEmpty else {
            return
        }

        lastFeedElapsed = elapsedAtBufferStart

        guard let decodeWorker else {
            return
        }
        let newChunks = Self.accumulateAndExtractChunks(
            accumulator: &chunkAccumulator,
            newSamples: samples,
            elapsedAtBufferStart: elapsedAtBufferStart,
            chunkSampleCount: decodeWorker.chunkSampleCount
        )
        chunkQueue.append(contentsOf: newChunks)
        scheduleNextChunkIfNeeded()
    }

    private func logFeedWhileNotReadyIfNeeded() {
        guard !hasLoggedFeedWhileNotReady else {
            return
        }
        hasLoggedFeedWhileNotReady = true
        if state == .stopped || isStopping {
            // Residual buffers still trickling in after `AudioCapture.didDegrade(source:)` caused
            // `TranscriptPipeline` to `stop()` this engine early (or `stop()` is currently in flight).
            // Benign and expected.
            logger.debug(
                "feed() called after stop() source=\(self.source.rawValue, privacy: .public); dropping buffer(s)"
            )
        } else {
            logger.warning(
                "feed() called while state=\(String(describing: self.state), privacy: .public) source=\(self.source.rawValue, privacy: .public); dropping buffer(s)"
            )
        }
    }

    // MARK: - Decode queue (section 3.2)

    /// Dispatches the next queued chunk to `decodeWorker`, if any and if one is not already in flight.
    /// The actual `decodeWorker.processChunk(...)` call runs on `SttDecodeWorker`'s own executor, so
    /// this actor's `feed()` keeps accepting buffers (and accumulating further chunks) while a chunk
    /// transcription is in flight (section 3.2).
    private func scheduleNextChunkIfNeeded() {
        guard let decodeWorker else {
            notifyDrainedIfNeeded()
            return
        }
        guard !isProcessingChunk, !chunkQueue.isEmpty else {
            notifyDrainedIfNeeded()
            return
        }

        isProcessingChunk = true
        let chunk = chunkQueue.removeFirst()

        Task { [weak self, decodeWorker] in
            let result: Result<String, Error>
            do {
                result = .success(try await decodeWorker.processChunk(chunk.samples))
            } catch {
                result = .failure(error)
            }
            await self?.finishChunk(chunk: chunk, result: result)
        }
    }

    private func finishChunk(chunk: SttExtractedChunk, result: Result<String, Error>) async {
        defer {
            isProcessingChunk = false
            scheduleNextChunkIfNeeded()
        }

        // Retained regardless of decode success/failure (design 33 MT2/MT6, section 3.2): the audio
        // is still part of the window tile even when this chunk's transcription itself failed --
        // it's exactly the audio a batch re-decode can recover. Only when two-pass is on; OFF must
        // never accumulate any memory here (MT9/MT10 compatibility).
        if config.twoPassDecode {
            retention.append(chunk: chunk)
        }

        switch result {
        case .failure(let error):
            // Section 3.10 #3: skip this chunk and keep going; the engine never stops because of a
            // single transcription failure ("録音は絶対に止めない").
            let sttError = (error as? SttEngineError) ?? .transcriptionFailed(error.localizedDescription)
            logger.error(
                "transcription failed source=\(self.source.rawValue, privacy: .public): \(String(describing: sttError), privacy: .public)"
            )
            failuresContinuation.yield(sttError)
        case .success(let cumulativeText):
            processChunkResult(cumulativeText, chunkStartElapsed: chunk.startElapsed, chunkEndElapsed: chunk.endElapsed)
        }
    }

    // MARK: - Segment confirmation (section 3.3)

    /// Reacts to one chunk's (possibly unchanged) cumulative text: updates pending-segment timing,
    /// then applies section 3.3's routes 1-3 in order (punctuation, then max-characters, then
    /// idle-timeout), confirming zero or more segments before yielding the remaining pending text to
    /// `volatileTranscripts`.
    private func processChunkResult(_ newCumulativeText: String, chunkStartElapsed: TimeInterval, chunkEndElapsed: TimeInterval) {
        let textGrew = newCumulativeText != cumulativeText
        cumulativeText = newCumulativeText

        var pendingText = Self.computePendingText(cumulativeText: cumulativeText, confirmedCharacterCount: confirmedCharacterCount)

        if !pendingText.isEmpty, pendingSegmentStartElapsed == nil {
            pendingSegmentStartElapsed = chunkStartElapsed
        }
        if textGrew {
            // Design section 3.4: endMs is anchored to the chunk that produced the *last actual text
            // increment*, not merely the most recent chunk that happened to still have pending text
            // (e.g. an idle-timeout-confirming chunk whose text didn't change at all).
            pendingSegmentEndElapsed = chunkEndElapsed
            lastGrowthElapsed = chunkEndElapsed
        }

        var confirmedPieces: [SttFinalizedSegment] = []

        let split = Self.splitPendingTextOnPunctuation(pendingText, sentenceEndingCharacters: SttEngineConfig.sentenceEndingCharacters)
        for piece in split.confirmedSegments {
            // `chunkStartElapsed` (this chunk's own start) is the correct chunk-granularity fallback
            // for the 2nd+ piece confirmed from a single chunk's growth (`confirmSegment` resets
            // `pendingSegmentStartElapsed` to `nil` after the first), since all such pieces originated
            // within this same chunk.
            if let segment = confirmSegment(text: piece, startElapsedFallback: chunkStartElapsed) {
                confirmedPieces.append(segment)
            }
        }
        pendingText = split.remainingPendingText

        if Self.shouldForceConfirmOnMaxCharacters(pendingText: pendingText, maxSegmentCharacters: config.maxSegmentCharacters) {
            // Section 15.1 (docs/design/03-refinement-batch.md): back off to the last soft boundary
            // within the max-character window instead of confirming the whole runaway pending text, so
            // segments don't get cut mid-word. Falls back to confirming everything (the pre-15.1
            // behavior) when no soft boundary is found in range.
            let softSplit = Self.splitPendingTextAtSoftBoundary(
                pendingText,
                maxSegmentCharacters: config.maxSegmentCharacters,
                softBoundaryCharacters: SttEngineConfig.softBoundaryCharacters
            )
            for piece in softSplit.confirmedSegments {
                if let segment = confirmSegment(text: piece, startElapsedFallback: chunkStartElapsed) {
                    confirmedPieces.append(segment)
                }
            }
            pendingText = softSplit.remainingPendingText
        } else if Self.shouldConfirmOnIdleTimeout(
            pendingText: pendingText,
            elapsedSinceLastGrowth: chunkEndElapsed - lastGrowthElapsed,
            segmentIdleTimeout: config.segmentIdleTimeout
        ) {
            if let segment = confirmSegment(text: pendingText, startElapsedFallback: chunkStartElapsed) {
                confirmedPieces.append(segment)
            }
            pendingText = ""
        }

        // MT13 (docs/design/33-meeting-two-pass-decode.md): two-pass ON consumes whatever remains
        // pending in the *same* event that is about to cut a window, so the window tile and the
        // confirmed text stay in sync -- pending never survives past a cut. Only applies when this
        // event actually confirmed >= 1 piece above; otherwise no window is cut at all this event; the
        // residual (if any) simply stays pending for the next event, unchanged (matching two-pass OFF).
        if config.twoPassDecode, !confirmedPieces.isEmpty, !pendingText.isEmpty {
            if let residual = confirmSegment(text: pendingText, startElapsedFallback: chunkStartElapsed) {
                confirmedPieces.append(residual)
            }
            pendingText = ""
        }

        if pendingText.isEmpty {
            pendingSegmentStartElapsed = nil
        }
        // `confirming` carries this event's confirmed text alongside the (now shorter, often empty)
        // pending text, so the UI can keep the line on screen while the confirmed window is still
        // being re-decoded and appended -- see `SttVolatileUpdate`.
        volatileTranscriptsContinuation.yield(
            SttVolatileUpdate(text: pendingText, confirming: confirmedPieces.map(\.text).joined())
        )

        finishConfirmationEvent(pieces: confirmedPieces, cutThroughElapsed: pendingSegmentEndElapsed)

        // MT6 (a): once pending text is empty, whatever remains retained is just the next window's
        // silence lead -- cap it to ~20s rather than letting a long pause accumulate tens of seconds
        // of silence samples a re-decode would gain nothing from.
        if config.twoPassDecode, pendingText.isEmpty {
            retention.trimLead()
        }
    }

    /// Confirms one piece of `cumulativeText` (already trimmed to a sentence/max-char/idle boundary by
    /// the caller) into a `SttFinalizedSegment`, advancing `confirmedCharacterCount` by the piece's
    /// *untrimmed* length so it stays in lockstep with `cumulativeText`'s indexing. A piece that is
    /// entirely whitespace after trimming (e.g. a lone punctuation mark) advances the confirmed offset
    /// but returns `nil` (kikimi.md 5 章's `text` field should never be empty) instead of yielding
    /// directly -- callers collect the non-`nil` results into one confirmation event's `pieces`
    /// (`docs/design/33-meeting-two-pass-decode.md` MT3, section 3.2).
    ///
    /// - Parameter startElapsedFallback: Used as `startMs`'s source only when `pendingSegmentStartElapsed`
    ///   is `nil` — i.e. for the 2nd+ piece confirmed within a single `processChunkResult` call (see the
    ///   call sites). Falling back to `pendingSegmentEndElapsed` (this segment's own `endMs` source)
    ///   there would collapse the piece to zero duration; the caller passes the current chunk's start
    ///   time instead, which stays within this design's stated chunk-granularity precision (section 3.4).
    @discardableResult
    private func confirmSegment(text: String, startElapsedFallback: TimeInterval) -> SttFinalizedSegment? {
        confirmedCharacterCount += text.count
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let startElapsed = pendingSegmentStartElapsed ?? startElapsedFallback
        let endElapsed = pendingSegmentEndElapsed
        pendingSegmentStartElapsed = nil

        guard !trimmed.isEmpty else {
            return nil
        }
        let startMs = Int((startElapsed * 1_000).rounded())
        let endMs = max(startMs, Int((endElapsed * 1_000).rounded()))
        return SttFinalizedSegment(startMs: startMs, endMs: endMs, text: trimmed, confidence: 1.0)
    }

    /// Turns one confirmation event's collected pieces into a `SttConfirmedWindow` and yields it
    /// (`docs/design/33-meeting-two-pass-decode.md` MT2/MT3, section 3.2) -- a no-op (no retention
    /// cut, no yield) when `pieces` is empty, so the window's audio simply stays retained for the
    /// *next* event's window instead of being cut here. `two_pass_decode` OFF never touches
    /// `retention` at all and always yields an empty-`samples`/`truncated: false` window, matching
    /// pre-design-33 confirmation behavior byte for byte (MT9/MT10).
    private func finishConfirmationEvent(pieces: [SttFinalizedSegment], cutThroughElapsed: TimeInterval) {
        guard !pieces.isEmpty else {
            return
        }

        guard config.twoPassDecode else {
            confirmedWindowsContinuation.yield(
                SttConfirmedWindow(pieces: pieces, samples: [], startElapsed: cutThroughElapsed, endElapsed: cutThroughElapsed, truncated: false)
            )
            return
        }

        let cut = retention.cut(throughEndElapsed: cutThroughElapsed)
        confirmedWindowsContinuation.yield(
            SttConfirmedWindow(pieces: pieces, samples: cut.samples, startElapsed: cut.startElapsed, endElapsed: cut.endElapsed, truncated: cut.truncated)
        )
    }

    // MARK: - stop()

    /// Flushes any remaining accumulated samples as a final (zero-padded) chunk, drains the decode
    /// queue, calls `SttStreamingBackend.finish()`/`reset()`, force-confirms whatever text is still
    /// pending (section 3.3 route 4), then finishes all output streams. Safe to call more than once; a
    /// no-op once already `.stopped`.
    func stop() async {
        guard state != .stopped else {
            return
        }
        // Must be the very first statement (before any `await` below) — see `isStopping`'s doc comment.
        isStopping = true

        if let decodeWorker,
           let flush = Self.flushChunk(
               accumulator: chunkAccumulator,
               elapsedAtBufferStart: lastFeedElapsed,
               chunkSampleCount: decodeWorker.chunkSampleCount
           ) {
            chunkQueue.append(flush)
        }
        // `flushChunk` takes `chunkAccumulator` by value, so it must be cleared explicitly here — left
        // populated, a (now-impossible thanks to `isStopping`, but still worth defending) stray `feed()`
        // would otherwise re-accumulate these already-flushed samples into a later chunk.
        chunkAccumulator = SttChunkAccumulator()
        scheduleNextChunkIfNeeded()
        await waitUntilDrained()

        if let decodeWorker {
            do {
                let finalText = try await decodeWorker.finish()
                processChunkResult(finalText, chunkStartElapsed: pendingSegmentStartElapsed ?? lastFeedElapsed, chunkEndElapsed: lastFeedElapsed)
            } catch {
                logger.error(
                    "finish() failed source=\(self.source.rawValue, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                failuresContinuation.yield(.transcriptionFailed(error.localizedDescription))
            }
            await decodeWorker.reset()
        }

        // Route 4 (section 3.3): force-confirm whatever is still pending, through the same
        // `finishConfirmationEvent` path as every other route -- the window's end is the last flush
        // chunk (`lastFeedElapsed`, design 33 section 3.2's "窓の終端は最後の flush チャンクまで").
        let remaining = Self.computePendingText(cumulativeText: cumulativeText, confirmedCharacterCount: confirmedCharacterCount)
        if !remaining.isEmpty {
            let segment = confirmSegment(text: remaining, startElapsedFallback: lastFeedElapsed)
            volatileTranscriptsContinuation.yield(
                SttVolatileUpdate(text: "", confirming: segment?.text ?? "")
            )
            if let segment {
                finishConfirmationEvent(pieces: [segment], cutThroughElapsed: lastFeedElapsed)
            }
        }

        state = .stopped
        confirmedWindowsContinuation.finish()
        volatileTranscriptsContinuation.finish()
        failuresContinuation.finish()
    }

    private var isDrained: Bool {
        !isProcessingChunk && chunkQueue.isEmpty
    }

    private func waitUntilDrained() async {
        if isDrained {
            return
        }
        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
        }
    }

    private func notifyDrainedIfNeeded() {
        guard isDrained else {
            return
        }
        let waiters = drainWaiters
        drainWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
