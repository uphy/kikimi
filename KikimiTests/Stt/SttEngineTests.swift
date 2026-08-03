import AVFoundation
import Foundation
import Testing

@testable import Kikimi

// MARK: - FakeSttStreamingBackend

/// Deterministic, network-free stand-in for `FluidAudioStreamingBackend`
/// (`docs/design/11-streaming-stt.md` section 3.12's "`StreamingNemotronAsrManager` はプロトコルで抽象化し、
/// フェイク注入で `SttEngine` の状態遷移を検証する"). An `actor` (like the real backend's underlying
/// `StreamingNemotronMultilingualAsrManager`) so call-count/received-samples assertions are race-free,
/// with `chunkSampleCount` declared `nonisolated let` to match `SttStreamingBackend`'s synchronous
/// property requirement (mirrors `FluidAudioStreamingBackend`'s own `let chunkSampleCount: Int`).
private actor FakeSttStreamingBackend: SttStreamingBackend {
    nonisolated let chunkSampleCount: Int

    /// `processChunk(_:)` returns `responses[callIndex]`, clamped to the last element once exhausted
    /// (mirrors the real backend's "cumulative text, only grows or stays the same" semantics -- a test
    /// simply keeps repeating the final cumulative value once its scripted sequence runs out).
    private var responses: [String]
    private(set) var processChunkCallCount = 0
    private(set) var receivedChunks: [[Float]] = []
    var processChunkError: Error?

    private(set) var finishCallCount = 0
    var finishText = ""
    var finishError: Error?

    private(set) var resetCallCount = 0

    init(chunkSampleCount: Int, responses: [String] = []) {
        self.chunkSampleCount = chunkSampleCount
        self.responses = responses
    }

    func setProcessChunkError(_ error: Error?) {
        processChunkError = error
    }

    func setFinishText(_ text: String) {
        finishText = text
    }

    func setFinishError(_ error: Error?) {
        finishError = error
    }

    func processChunk(_ samples: [Float]) async throws -> String {
        receivedChunks.append(samples)
        defer { processChunkCallCount += 1 }
        if let processChunkError {
            throw processChunkError
        }
        guard !responses.isEmpty else {
            return ""
        }
        let index = min(processChunkCallCount, responses.count - 1)
        return responses[index]
    }

    func finish() async throws -> String {
        finishCallCount += 1
        if let finishError {
            throw finishError
        }
        return finishText
    }

    func reset() async {
        resetCallCount += 1
    }
}

// MARK: - Test helpers

/// `LocalizedError`-conforming so `SttEngineError.transcriptionFailed(error.localizedDescription)`
/// (`SttEngine.finishChunk(chunk:result:)`) actually surfaces `message` rather than
/// `NSError`'s generic default description.
private struct FakeBackendFactoryError: Error, LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

/// A trivial `Sendable` counter used to assert how many times a test `BackendFactory` closure was
/// invoked. An `actor` (rather than `OSAllocatedUnfairLock`) to avoid an extra `import os` just for
/// this file.
private actor CallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

/// Builds an `SttEngine.BackendFactory` that always succeeds with `backend`, recording how many times
/// it was invoked via `callCounter`.
private func makeSucceedingFactory(
    backend: FakeSttStreamingBackend,
    callCounter: CallCounter = CallCounter()
) -> SttEngine.BackendFactory {
    { _, _ in
        await callCounter.increment()
        return backend
    }
}

/// A well-formed Float32/16kHz/mono buffer of `frameCount` frames -- the only format `SttEngine.feed`
/// accepts (section 3.4).
private func makeMonoFloatBuffer(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    return buffer
}

/// An unsupported-format buffer (stereo Float32) -- triggers `SttEngineError.unsupportedAudioFormat`.
private func makeStereoFloatBuffer(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    return buffer
}

private func collectFirst<T>(_ n: Int, of stream: AsyncStream<T>) async -> [T] {
    var results: [T] = []
    for await value in stream {
        results.append(value)
        if results.count == n {
            break
        }
    }
    return results
}

/// Collects whole `SttConfirmedWindow`s from `confirmedWindows` until at least `n` total pieces
/// across the windows gathered have been seen, then returns exactly the first `n` pieces flattened
/// in confirmation order. Lets most per-piece assertions written for the pre-design-33
/// `finalizedSegments` stream (`docs/design/33-meeting-two-pass-decode.md`) keep asserting on
/// `SttFinalizedSegment` content without needing to know how many windows those pieces landed in;
/// tests that specifically care about windowing (MT2/MT3) collect `confirmedWindows` directly instead.
private func collectFirstPieces(_ n: Int, of stream: AsyncStream<SttConfirmedWindow>) async -> [SttFinalizedSegment] {
    var pieces: [SttFinalizedSegment] = []
    for await window in stream {
        pieces.append(contentsOf: window.pieces)
        if pieces.count >= n {
            break
        }
    }
    return Array(pieces.prefix(n))
}

// MARK: - Lifecycle: idle -> preparing -> ready / idle -> preparing -> idle

@Suite("SttEngine lifecycle")
struct SttEngineLifecycleTests {
    @Test("starts in .idle")
    func initialState() async {
        let engine = SttEngine(source: .mic, backendFactory: makeSucceedingFactory(backend: FakeSttStreamingBackend(chunkSampleCount: 4)))
        #expect(await engine.state == .idle)
    }

    @Test("prepare() success transitions .idle -> .ready and constructs the backend exactly once")
    func prepareSuccess() async throws {
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4)
        let callCounter = CallCounter()
        let engine = SttEngine(source: .mic, backendFactory: makeSucceedingFactory(backend: backend, callCounter: callCounter))

        try await engine.prepare()

        #expect(await engine.state == .ready)
        #expect(await callCounter.count == 1)
    }

    @Test("prepare() failure reverts .idle -> .preparing -> .idle and rethrows")
    func prepareFailurePropagatesAndRevertsState() async {
        let engine = SttEngine(
            source: .mic,
            backendFactory: { _, _ in throw FakeBackendFactoryError(message: "boom") }
        )

        await #expect(throws: FakeBackendFactoryError.self) {
            try await engine.prepare()
        }

        #expect(await engine.state == .idle)
    }

    @Test("prepare() is idempotent: a second call while already .ready is a no-op")
    func prepareIsIdempotentOnceReady() async throws {
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4)
        let callCounter = CallCounter()
        let engine = SttEngine(source: .mic, backendFactory: makeSucceedingFactory(backend: backend, callCounter: callCounter))

        try await engine.prepare()
        try await engine.prepare()

        #expect(await engine.state == .ready)
        #expect(await callCounter.count == 1)
    }

    @Test("stop() before prepare() is safe and moves .idle -> .stopped without touching a backend")
    func stopWithoutPrepareIsSafe() async {
        let engine = SttEngine(
            source: .mic,
            backendFactory: { _, _ in throw FakeBackendFactoryError(message: "should never be called") }
        )

        await engine.stop()

        #expect(await engine.state == .stopped)
    }

    @Test("stop() is idempotent: a second call is a no-op")
    func stopIsIdempotent() async throws {
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4)
        let engine = SttEngine(source: .mic, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        await engine.stop()
        await engine.stop()

        #expect(await engine.state == .stopped)
        #expect(await backend.resetCallCount == 1)
    }
}

// MARK: - feed(): dropped-buffer and format-validation paths

@Suite("SttEngine.feed dropped/invalid paths")
struct SttEngineFeedInvalidPathTests {
    @Test("feed() while .idle (never prepared) is dropped without crashing or emitting a segment")
    func feedWhileIdleIsDropped() async throws {
        let engine = SttEngine(
            source: .mic,
            backendFactory: { _, _ in throw FakeBackendFactoryError(message: "should never be called") }
        )
        let buffer = try makeMonoFloatBuffer(frameCount: 4)

        await engine.feed(buffer: buffer, elapsedAtBufferStart: 0)

        #expect(await engine.state == .idle)
    }

    @Test("feed() after stop() is dropped without crashing")
    func feedAfterStopIsDropped() async throws {
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4, responses: ["hi"])
        let engine = SttEngine(source: .mic, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()
        await engine.stop()

        let buffer = try makeMonoFloatBuffer(frameCount: 4)
        await engine.feed(buffer: buffer, elapsedAtBufferStart: 0)

        // No new chunk should have reached the (already-reset) backend.
        #expect(await backend.processChunkCallCount == 0)
    }

    @Test("feed() with an unsupported audio format yields .unsupportedAudioFormat on failures and is not queued")
    func feedWithUnsupportedFormatYieldsFailure() async throws {
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4)
        let engine = SttEngine(source: .mic, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        async let failures = collectFirst(1, of: engine.failures)
        let buffer = try makeStereoFloatBuffer(frameCount: 4)
        await engine.feed(buffer: buffer, elapsedAtBufferStart: 0)
        await engine.stop()

        let received = await failures
        #expect(received == [.unsupportedAudioFormat])
        #expect(await backend.processChunkCallCount == 0)
    }

    @Test("feed() with an empty buffer (frameLength 0) is silently ignored")
    func feedWithEmptyBufferIsIgnored() async throws {
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4)
        let engine = SttEngine(source: .mic, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        let buffer = try makeMonoFloatBuffer(frameCount: 0)
        await engine.feed(buffer: buffer, elapsedAtBufferStart: 0)
        await engine.stop()

        #expect(await backend.processChunkCallCount == 0)
    }
}

// MARK: - Segment confirmation routes, end to end through the actor

@Suite("SttEngine segment confirmation (end to end via a fake backend)")
struct SttEngineSegmentConfirmationTests {
    @Test("route 1 (punctuation): a segment confirms once its chunk's cumulative text gains a terminator")
    func confirmsOnPunctuation() async throws {
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4, responses: ["こんにちは", "こんにちは。"])
        let engine = SttEngine(source: .mic, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        async let finalized = collectFirstPieces(1, of: engine.confirmedWindows)

        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.0)
        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 1.0)

        let segments = await finalized
        #expect(segments == [SttFinalizedSegment(startMs: 0, endMs: 1_000, text: "こんにちは。", confidence: 1.0)])

        await engine.stop()
        #expect(await backend.finishCallCount == 1)
        #expect(await backend.resetCallCount == 1)
    }

    @Test("route 1 (punctuation): multiple sentences confirmed from a single chunk's growth each get a valid (non-collapsed) duration, in one window (MT3)")
    func multipleSentencesInSingleChunkGetDistinctTimestamps() async throws {
        // chunkSampleCount 8 with two 4-frame feeds means both buffers accumulate into a single chunk,
        // whose startElapsed (0.0, the first feed) differs from its endElapsed (1.0, the second feed) --
        // this is what exposes the bug (previously the 2nd+ piece collapsed to startMs == endMs).
        let backend = FakeSttStreamingBackend(chunkSampleCount: 8, responses: ["はい。了解です。"])
        let engine = SttEngine(source: .mic, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        async let windows = collectFirst(1, of: engine.confirmedWindows)

        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.0)
        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 1.0)

        let received = await windows
        // Both sentences were confirmed within the same `processChunkResult` call (one chunk's
        // growth), so design 33 MT3 groups them into a single window rather than two.
        #expect(received.count == 1)
        let segments = received[0].pieces
        #expect(segments.count == 2)
        #expect(segments[0] == SttFinalizedSegment(startMs: 0, endMs: 1_000, text: "はい。", confidence: 1.0))
        // Before the fix this collapsed to startMs: 1_000, endMs: 1_000 (zero duration, pinned to the
        // chunk's end) instead of spanning the same chunk-granularity window as the first piece.
        #expect(segments[1] == SttFinalizedSegment(startMs: 0, endMs: 1_000, text: "了解です。", confidence: 1.0))
    }

    @Test("MT13 (two-pass ON): route 1's post-punctuation remainder is consumed into the same window as its preceding piece, and a later idle timeout does not re-confirm it")
    func twoPassConsumesRoute1ResidualIntoSameWindow() async throws {
        var config = SttEngineConfig()
        config.segmentIdleTimeout = 1.0
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4, responses: ["a。b", "a。b"])
        let engine = SttEngine(source: .mic, config: config, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        async let firstWindow = collectFirst(1, of: engine.confirmedWindows)
        async let firstVolatile = collectFirst(1, of: engine.volatileTranscripts)

        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.0)

        let windows = await firstWindow
        #expect(windows.count == 1)
        // "a。" confirms via route 1's punctuation split; "b" is the punctuation-less remainder MT13
        // consumes into the same window instead of leaving it pending for the next event.
        #expect(windows[0].pieces.map(\.text) == ["a。", "b"])
        #expect(await firstVolatile == [SttVolatileUpdate(text: "", confirming: "a。b")])

        // A later chunk past the idle timeout, with cumulative text unchanged, must not re-confirm
        // "b" a second time -- MT13 already advanced confirmedCharacterCount past it. No further
        // window should ever be yielded (the first `collectFirst` above already drained the only one).
        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 2.0)
        await engine.stop()

        var laterPieces: [SttFinalizedSegment] = []
        for await window in engine.confirmedWindows {
            laterPieces.append(contentsOf: window.pieces)
        }
        #expect(laterPieces.isEmpty)
    }

    @Test("route 2 (idle timeout): a non-empty pending segment is force-confirmed once growth stalls")
    func confirmsOnIdleTimeout() async throws {
        var config = SttEngineConfig()
        config.segmentIdleTimeout = 1.0
        config.maxSegmentCharacters = 999
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4, responses: ["残り", "残り", "残り"])
        let engine = SttEngine(source: .mic, config: config, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        async let finalized = collectFirstPieces(1, of: engine.confirmedWindows)

        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.0)
        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.5)
        // Still below the 1.0s idle threshold measured from the first chunk's growth.
        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 1.2)

        let segments = await finalized
        // endMs is anchored to the chunk that produced the *last actual text increment* (design section
        // 3.4), which is the first chunk (elapsed 0.0s) here — the text stops growing after that, and the
        // 2nd/3rd chunks only re-confirm the same unchanged text once the idle timeout elapses.
        #expect(segments == [SttFinalizedSegment(startMs: 0, endMs: 0, text: "残り", confidence: 1.0)])
    }

    @Test("route 3 (max characters): a runaway pending segment force-confirms once it exceeds the limit")
    func confirmsOnMaxCharacters() async throws {
        var config = SttEngineConfig()
        config.maxSegmentCharacters = 3
        config.segmentIdleTimeout = 999
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4, responses: ["ab", "abcd"])
        let engine = SttEngine(source: .mic, config: config, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        async let finalized = collectFirstPieces(1, of: engine.confirmedWindows)

        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.0)
        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.2)

        let segments = await finalized
        #expect(segments == [SttFinalizedSegment(startMs: 0, endMs: 200, text: "abcd", confidence: 1.0)])
    }

    @Test("route 3 (soft boundary backoff, section 15.1) with two-pass OFF: backs off to the last soft boundary instead of confirming the whole runaway text, the leftover pending's startMs continues from the next chunk, and every window's samples stay empty")
    func confirmsOnMaxCharactersBacksOffToSoftBoundaryThenContinuesRemainder() async throws {
        var config = SttEngineConfig()
        config.maxSegmentCharacters = 3
        config.segmentIdleTimeout = 999
        // `two_pass_decode` OFF: MT13's residual consumption only applies when it's on (see
        // `twoPassConsumesRoute3ResidualIntoSameWindow` below for the ON equivalent of this same
        // scenario) -- this test documents that OFF's confirmation behavior is byte-for-byte
        // unchanged from before design 33 (MT9/MT10).
        config.twoPassDecode = false
        // chunk1 "ab" (<= 3 chars, no trigger) -> chunk2 "ab、cd" (5 chars, exceeds the limit; "、" sits
        // at index 2, inside the first-3-characters window, so route 3 backs off to it instead of
        // confirming "ab、cd" whole) -> chunk3 "ab、cd。" (the leftover "cd" now terminates with "。",
        // confirming via route 1 and exercising whether its startMs picked up chunk3's elapsed time
        // rather than staying pinned to chunk1's).
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4, responses: ["ab", "ab、cd", "ab、cd。"])
        let engine = SttEngine(source: .mic, config: config, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        async let windows = collectFirst(2, of: engine.confirmedWindows)

        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.0)
        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.2)
        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.5)

        let received = await windows
        #expect(received.count == 2)
        #expect(received[0].pieces == [SttFinalizedSegment(startMs: 0, endMs: 200, text: "ab、", confidence: 1.0)])
        // The leftover "cd" (from the backoff) is anchored to chunk3's own elapsed time (0.5s), not
        // chunk1's (0.0s) -- confirming pendingSegmentStartElapsed correctly resets to the next chunk
        // that still has this leftover pending, rather than staying stuck at the original span's start.
        #expect(received[1].pieces == [SttFinalizedSegment(startMs: 500, endMs: 500, text: "cd。", confidence: 1.0)])
        #expect(received.allSatisfy { $0.samples.isEmpty && !$0.truncated })
    }

    @Test("MT13 (two-pass ON): route 3's soft-boundary remainder is consumed into the same window as its preceding piece, and a later idle timeout does not re-confirm it")
    func twoPassConsumesRoute3ResidualIntoSameWindow() async throws {
        var config = SttEngineConfig()
        config.maxSegmentCharacters = 3
        config.segmentIdleTimeout = 1.0
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4, responses: ["ab、cd", "ab、cd", "ab、cd"])
        let engine = SttEngine(source: .mic, config: config, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        async let firstWindow = collectFirst(1, of: engine.confirmedWindows)
        async let firstVolatile = collectFirst(1, of: engine.volatileTranscripts)

        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.0)

        let windows = await firstWindow
        #expect(windows.count == 1)
        #expect(windows[0].pieces.map(\.text) == ["ab、", "cd"])
        // The residual is consumed in the same event that confirmed "ab、", so volatile clears to ""
        // instead of showing "cd" as still-pending text -- and both pieces travel in `confirming` so
        // the UI can keep them on screen until their rows arrive.
        #expect(await firstVolatile == [SttVolatileUpdate(text: "", confirming: "ab、cd")])

        // A later chunk past the idle timeout, with cumulative text unchanged, must not re-confirm
        // "cd" a second time -- MT13 already advanced confirmedCharacterCount past it. No further
        // window should ever be yielded (the first `collectFirst` above already drained the only one).
        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 2.0)
        await engine.stop()

        var laterPieces: [SttFinalizedSegment] = []
        for await window in engine.confirmedWindows {
            laterPieces.append(contentsOf: window.pieces)
        }
        #expect(laterPieces.isEmpty)
    }

    @Test("route 4 (stop): whatever is still pending at stop() is force-confirmed, even with no punctuation/idle/max trigger")
    func confirmsOnStopWhenNothingElseTriggered() async throws {
        var config = SttEngineConfig()
        config.segmentIdleTimeout = 999
        config.maxSegmentCharacters = 999
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4, responses: ["残り"])
        await backend.setFinishText("残り")
        let engine = SttEngine(source: .mic, config: config, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        async let finalized = collectFirstPieces(1, of: engine.confirmedWindows)

        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.0)
        await engine.stop()

        let segments = await finalized
        #expect(segments == [SttFinalizedSegment(startMs: 0, endMs: 0, text: "残り", confidence: 1.0)])
        #expect(await backend.finishCallCount == 1)
        #expect(await backend.resetCallCount == 1)
    }

    @Test("volatile transcripts carry the pending text as it grows, then hand it over in `confirming` once confirmed")
    func volatileTranscriptsTrackPendingTextThenClear() async throws {
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4, responses: ["こんに", "こんにちは。"])
        let engine = SttEngine(source: .mic, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        async let volatile = collectFirst(2, of: engine.volatileTranscripts)

        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.0)
        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 1.0)

        let received = await volatile
        // The confirming event empties `text` *and* names what left it, so the UI never has to erase
        // the line while the confirmed window is still being re-decoded into a row.
        #expect(received == [
            SttVolatileUpdate(text: "こんに", confirming: ""),
            SttVolatileUpdate(text: "", confirming: "こんにちは。"),
        ])
    }

    @Test("route 4 (stop): the force-confirmed remainder is named in `confirming`, not silently dropped")
    func volatileConfirmingCarriesStopRemainder() async throws {
        var config = SttEngineConfig()
        config.segmentIdleTimeout = 999
        config.maxSegmentCharacters = 999
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4, responses: ["残り"])
        await backend.setFinishText("残り")
        let engine = SttEngine(source: .mic, config: config, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.0)
        await engine.stop()

        var updates: [SttVolatileUpdate] = []
        for await update in engine.volatileTranscripts {
            updates.append(update)
        }
        #expect(updates.last == SttVolatileUpdate(text: "", confirming: "残り"))
    }

    @Test("startMs/endMs stay monotonically non-decreasing across a sequence of confirmed segments")
    func timingIsMonotonic() async throws {
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4, responses: ["まず。", "まず。次に。"])
        let engine = SttEngine(source: .mic, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        async let finalized = collectFirstPieces(2, of: engine.confirmedWindows)

        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.5)
        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 1.5)

        let segments = await finalized
        #expect(segments.count == 2)
        #expect(segments[0].startMs <= segments[0].endMs)
        #expect(segments[1].startMs <= segments[1].endMs)
        #expect(segments[0].endMs <= segments[1].startMs)
    }

    @Test("a processChunk failure is reported on failures and skips that chunk without stopping the engine")
    func transcriptionFailureIsSkippedNotFatal() async throws {
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4)
        await backend.setProcessChunkError(FakeBackendFactoryError(message: "decode blew up"))
        let engine = SttEngine(source: .mic, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        async let failures = collectFirst(1, of: engine.failures)

        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.0)

        let received = await failures
        if case .transcriptionFailed(let message) = received[0] {
            #expect(message.contains("decode blew up"))
        } else {
            Issue.record("expected .transcriptionFailed, got \(received[0])")
        }

        // The engine keeps running after a chunk failure ("録音は絶対に止めない").
        #expect(await engine.state == .ready)
        await engine.stop()
        #expect(await engine.state == .stopped)
    }
}

// MARK: - Confirmed window tiling (design 33 MT2/MT3)

@Suite("SttEngine confirmed window tiling (design 33 MT2)")
struct SttEngineWindowTilingTests {
    /// A mono Float32/16kHz buffer whose every sample is `value` -- distinguishable content lets
    /// tests assert `SttConfirmedWindow.samples` actually matches a specific set of chunks by value,
    /// not just by count.
    private func fillBuffer(frameCount: AVAudioFrameCount, value: Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channelData = try #require(buffer.floatChannelData)
        for index in 0..<Int(frameCount) {
            channelData[0][index] = value
        }
        return buffer
    }

    @Test("each confirmation event yields exactly one window, whose samples are exactly the chunks tiled up to that event, with no overlap with the next window")
    func windowsTileWithoutOverlapOrGap() async throws {
        // chunk1 "a" (no trigger) -> chunk2 "a。" (confirms "a。", cutting window 1 through chunk1+2)
        // -> chunk3 "a。b" (leftover "b" stays pending until stop()'s route 4 residual confirms it,
        // cutting window 2 through chunk3 alone).
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4, responses: ["a", "a。", "a。b"])
        await backend.setFinishText("a。b")
        let engine = SttEngine(source: .mic, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        async let windows = collectFirst(2, of: engine.confirmedWindows)

        await engine.feed(buffer: try fillBuffer(frameCount: 4, value: 1), elapsedAtBufferStart: 0.0)
        await engine.feed(buffer: try fillBuffer(frameCount: 4, value: 2), elapsedAtBufferStart: 1.0)
        await engine.feed(buffer: try fillBuffer(frameCount: 4, value: 3), elapsedAtBufferStart: 2.0)
        await engine.stop()

        let received = await windows
        #expect(received.count == 2)

        // Window 1 (confirmed by chunk2's "a。"): chunk1 + chunk2 tiled together, no overlap.
        #expect(received[0].pieces.map(\.text) == ["a。"])
        #expect(received[0].samples == Array(repeating: Float(1), count: 4) + Array(repeating: Float(2), count: 4))
        #expect(received[0].truncated == false)

        // Window 2 (confirmed by stop()'s route 4 residual "b"): chunk3 alone -- never repeats
        // chunk1/chunk2's samples, proving the tiling has no gap and no overlap across the cut.
        #expect(received[1].pieces.map(\.text) == ["b"])
        #expect(received[1].samples == Array(repeating: Float(3), count: 4))
        #expect(received[1].truncated == false)
    }
}

// MARK: - stop() draining

@Suite("SttEngine.stop draining")
struct SttEngineStopDrainingTests {
    @Test("stop() flushes a zero-padded remainder chunk when one is still accumulating")
    func stopFlushesPartialRemainder() async throws {
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4, responses: ["ab"])
        let engine = SttEngine(source: .mic, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        // Only 2 of 4 samples -- never reaches chunkSampleCount on its own, so only stop()'s flush
        // will ever turn it into a processChunk() call.
        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 2), elapsedAtBufferStart: 0.0)
        #expect(await backend.processChunkCallCount == 0)

        await engine.stop()

        #expect(await backend.processChunkCallCount == 1)
        let received = await backend.receivedChunks
        #expect(received.first?.count == 4)
        // The trailing 2 samples are zero-padded (section 3.2/3.3 route 4's flush semantics).
        #expect(received.first?.suffix(2) == [0, 0])
    }

    @Test("stop() awaits the full decode queue before finishing the confirmedWindows stream")
    func stopWaitsForQueueToDrainBeforeFinishingStreams() async throws {
        let backend = FakeSttStreamingBackend(chunkSampleCount: 4, responses: ["一。", "一。二。", "一。二。三。"])
        let engine = SttEngine(source: .mic, backendFactory: makeSucceedingFactory(backend: backend))
        try await engine.prepare()

        // Feed three whole chunks before ever calling stop() -- exercises the queue (not just the
        // single-in-flight-chunk path other tests cover).
        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 0.0)
        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 1.0)
        await engine.feed(buffer: try makeMonoFloatBuffer(frameCount: 4), elapsedAtBufferStart: 2.0)

        await engine.stop()

        var segments: [SttFinalizedSegment] = []
        for await window in engine.confirmedWindows {
            segments.append(contentsOf: window.pieces)
        }
        // The stream must have already finished (queue fully drained by stop()); collecting it after
        // the fact still terminates and reflects everything that was ever queued.
        #expect(segments.map(\.text) == ["一。", "二。", "三。"])
    }
}
