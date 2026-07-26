import AVFoundation
import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `TranscriptPipeline`'s two-pass window re-decode wiring
/// (`docs/design/33-meeting-two-pass-decode.md` MT4/MT5/MT8, section 7 layer 1). Every test injects
/// a fake `SttBatchDecoding` via `batchDecoderAcquire` (never a real `BatchAsrDecoderPool`/FluidAudio
/// model), and a `ScriptedSttStreamingBackend` (never a real streaming model) -- mirrors
/// `TranscriptPipelineTests.swift`/`TranscriptPipelineIntegrationTests.swift`'s existing fake-injection
/// conventions.
@Suite("TranscriptPipeline two-pass redecode")
struct TranscriptPipelineTwoPassTests {
    // MARK: - Test doubles

    /// A `SttStreamingBackend` whose `processChunk` returns `responses[callIndex]` (clamped to the
    /// last element once exhausted), and whose `finish()` repeats the last response this *instance*
    /// actually returned from `processChunk` -- a no-op contribution at `stop()` (`textGrew` stays
    /// false), matching `SttEngineTests.swift`'s `FakeSttStreamingBackend` convention. Returns `""` if
    /// this instance never processed a single chunk, so a source that a test never feeds any audio
    /// (e.g. `.system`, in a mic-only test) never has `stop()`'s `finish()` call manufacture
    /// cumulative text out of nothing -- every `TranscriptPipeline` test below therefore constructs a
    /// *fresh* instance per `backendFactory` call (one for mic, one for system) rather than sharing a
    /// single instance's state across both `SttEngine`s.
    private actor ScriptedSttStreamingBackend: SttStreamingBackend {
        nonisolated let chunkSampleCount: Int
        private var responses: [String]
        private(set) var processChunkCallCount = 0

        init(chunkSampleCount: Int, responses: [String]) {
            self.chunkSampleCount = chunkSampleCount
            self.responses = responses
        }

        func processChunk(_ samples: [Float]) async throws -> String {
            defer { processChunkCallCount += 1 }
            guard !responses.isEmpty else {
                return ""
            }
            let index = min(processChunkCallCount, responses.count - 1)
            return responses[index]
        }

        func finish() async throws -> String {
            guard processChunkCallCount > 0, !responses.isEmpty else {
                return ""
            }
            return responses[min(processChunkCallCount - 1, responses.count - 1)]
        }

        func reset() async {}
    }

    private struct FakeTranscribeFailure: Error {}

    /// A `SttBatchDecoding` fake whose outcome (success text, or failure) can be flipped mid-test
    /// (`setOutcome`), and which can optionally block on a `Gate` before returning/throwing --
    /// lets a test hold a redecode "in flight" to prove `stopAndDrain()` waits for it.
    private actor FakeBatchDecoder: SttBatchDecoding {
        enum Outcome {
            case succeed(String)
            case fail
        }

        private var outcome: Outcome
        private var delayGate: Gate?
        private(set) var transcribeCallCount = 0
        private(set) var receivedSampleCounts: [Int] = []

        init(outcome: Outcome) {
            self.outcome = outcome
        }

        func setOutcome(_ outcome: Outcome) {
            self.outcome = outcome
        }

        func setDelayGate(_ gate: Gate) {
            delayGate = gate
        }

        func transcribe(samples: [Float]) async throws -> String {
            transcribeCallCount += 1
            receivedSampleCounts.append(samples.count)
            if let delayGate {
                await delayGate.wait()
            }
            switch outcome {
            case .succeed(let text):
                return text
            case .fail:
                throw FakeTranscribeFailure()
            }
        }
    }

    /// A one-shot async gate a test can hold something on until it explicitly wants it to proceed --
    /// used both to control when a fake `batchDecoderAcquire` resolves and when a fake `transcribe`
    /// returns. Mirrors `BatchAsrDecoderPoolTests.LoadGate`.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let pending = waiters
            waiters = []
            for continuation in pending {
                continuation.resume()
            }
        }
    }

    /// Counts fire-and-forget `release()` calls -- `AcquiredBatchDecoder.release` is a synchronous
    /// `@Sendable () -> Void`, mirroring `BatchAsrDecoderLease.release()`'s contract, so a test hops
    /// onto this actor via a child `Task` the same way `BatchAsrDecoderPool.makeLease` does.
    private actor ReleaseCounter {
        private(set) var count = 0

        func increment() {
            count += 1
        }
    }

    // MARK: - Test helpers

    private func makeTempSessionDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptPipelineTwoPassTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSessionHandle() -> SessionHandle {
        let meta = SessionMeta(
            id: "2026-07-01T14-30-00_a1b2c3d4",
            title: "Test Session",
            titleAutoGenerated: true,
            titleAutoNamedOnce: false,
            titleProposal: nil,
            state: .recording,
            createdAt: Date(timeIntervalSince1970: 1_751_000_000),
            startedAt: Date(timeIntervalSince1970: 1_751_000_010),
            endedAt: nil,
            durationMs: 0,
            basedOnSession: nil,
            segmentCount: 0,
            refinedCount: 0,
            appVersion: "0.1.0"
        )
        return SessionHandle(directoryURL: makeTempSessionDirectory(), meta: meta)
    }

    private func makeMonoFloatBuffer(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        return buffer
    }

    /// FluidAudio's hard minimum (`DictationBatchTranscriber.minimumSampleCount`, 0.3s @ 16kHz =
    /// 4,800 samples) -- every test below uses this as `chunkSampleCount` so a single-chunk window
    /// already clears MT4's eligibility gate.
    private static let chunkSampleCount = 4_800

    // MARK: - Batch success

    @Test("a successful batch re-decode appends the batch text with stt_source \"batch\"")
    func batchSuccessAppendsBatchTextWithSttSource() async throws {
        let sessionHandle = makeSessionHandle()
        let fakeDecoder = FakeBatchDecoder(outcome: .succeed("バッチ結果です。"))
        let pipeline = TranscriptPipeline(
            sessionHandle: sessionHandle,
            backendFactory: { _, _ in ScriptedSttStreamingBackend(chunkSampleCount: Self.chunkSampleCount, responses: ["テスト", "テストです。"]) },
            batchDecoderAcquire: { _ in TranscriptPipeline.AcquiredBatchDecoder(decoder: fakeDecoder, release: {}) }
        )
        try await pipeline.prepare()
        // Let the (immediately-resolving) fake acquire land before the window is confirmed.
        try await Task.sleep(for: .milliseconds(50))

        let dummyCapture = AudioCapture(sessionDirectory: makeTempSessionDirectory())
        pipeline.audioCapture(dummyCapture, didCapture: try makeMonoFloatBuffer(frameCount: AVAudioFrameCount(Self.chunkSampleCount)), source: .mic, elapsed: 0.0)
        pipeline.audioCapture(dummyCapture, didCapture: try makeMonoFloatBuffer(frameCount: AVAudioFrameCount(Self.chunkSampleCount)), source: .mic, elapsed: 1.0)

        await pipeline.stopAndDrain()

        let segments = try await sessionHandle.readTranscriptSegments()
        #expect(segments.map(\.text) == ["バッチ結果です。"])
        #expect(segments.map(\.sttSource) == ["batch"])
        #expect(await fakeDecoder.transcribeCallCount == 1)
    }

    // MARK: - Fallback: decoder never acquired

    @Test("a batch decoder acquire that never resolves falls back to the streaming piece with no stt_source")
    func decoderUnavailableFallsBackToStreamingText() async throws {
        let sessionHandle = makeSessionHandle()
        struct AcquireFailure: Error {}
        let pipeline = TranscriptPipeline(
            sessionHandle: sessionHandle,
            backendFactory: { _, _ in ScriptedSttStreamingBackend(chunkSampleCount: Self.chunkSampleCount, responses: ["テスト", "テストです。"]) },
            batchDecoderAcquire: { _ in throw AcquireFailure() }
        )
        try await pipeline.prepare()
        try await Task.sleep(for: .milliseconds(50))

        let dummyCapture = AudioCapture(sessionDirectory: makeTempSessionDirectory())
        pipeline.audioCapture(dummyCapture, didCapture: try makeMonoFloatBuffer(frameCount: AVAudioFrameCount(Self.chunkSampleCount)), source: .mic, elapsed: 0.0)
        pipeline.audioCapture(dummyCapture, didCapture: try makeMonoFloatBuffer(frameCount: AVAudioFrameCount(Self.chunkSampleCount)), source: .mic, elapsed: 1.0)

        await pipeline.stopAndDrain()

        let segments = try await sessionHandle.readTranscriptSegments()
        #expect(segments.map(\.text) == ["テストです。"])
        #expect(segments.allSatisfy { $0.sttSource == nil })
    }

    // MARK: - Fallback: transcribe() throws

    @Test("a transcribe() failure falls back to the streaming piece with no stt_source")
    func transcribeFailureFallsBackToStreamingText() async throws {
        let sessionHandle = makeSessionHandle()
        let fakeDecoder = FakeBatchDecoder(outcome: .fail)
        let pipeline = TranscriptPipeline(
            sessionHandle: sessionHandle,
            backendFactory: { _, _ in ScriptedSttStreamingBackend(chunkSampleCount: Self.chunkSampleCount, responses: ["テスト", "テストです。"]) },
            batchDecoderAcquire: { _ in TranscriptPipeline.AcquiredBatchDecoder(decoder: fakeDecoder, release: {}) }
        )
        try await pipeline.prepare()
        try await Task.sleep(for: .milliseconds(50))

        let dummyCapture = AudioCapture(sessionDirectory: makeTempSessionDirectory())
        pipeline.audioCapture(dummyCapture, didCapture: try makeMonoFloatBuffer(frameCount: AVAudioFrameCount(Self.chunkSampleCount)), source: .mic, elapsed: 0.0)
        pipeline.audioCapture(dummyCapture, didCapture: try makeMonoFloatBuffer(frameCount: AVAudioFrameCount(Self.chunkSampleCount)), source: .mic, elapsed: 1.0)

        await pipeline.stopAndDrain()

        let segments = try await sessionHandle.readTranscriptSegments()
        #expect(segments.map(\.text) == ["テストです。"])
        #expect(segments.allSatisfy { $0.sttSource == nil })
        #expect(await fakeDecoder.transcribeCallCount == 1)
    }

    // MARK: - Mode transitions (fallback -> batch -> fallback)

    @Test("mode transitions right after a residual-consuming window neither double-emit nor drop text")
    func modeTransitionsNeitherDuplicateNorDropText() async throws {
        let sessionHandle = makeSessionHandle()
        // chunk1 "あ" (no trigger) -> chunk2 "あ。い" (route 1 confirms "あ。", MT13 consumes the "い"
        // remainder into the same window -- this is window 1, decoded *before* the acquire resolves)
        // -> chunk3 "あ。いう。" (confirms "う。" alone -- window 2, decoded once the acquire has
        // resolved and the fake decoder is set to succeed) -> chunk4 "あ。いう。え。" (confirms "え。"
        // alone -- window 3, decoded after the fake decoder is flipped to fail).
        let acquireGate = Gate()
        let fakeDecoder = FakeBatchDecoder(outcome: .succeed("バッチ2"))
        let pipeline = TranscriptPipeline(
            sessionHandle: sessionHandle,
            backendFactory: { _, _ in
                ScriptedSttStreamingBackend(chunkSampleCount: Self.chunkSampleCount, responses: ["あ", "あ。い", "あ。いう。", "あ。いう。え。"])
            },
            batchDecoderAcquire: { _ in
                await acquireGate.wait()
                return TranscriptPipeline.AcquiredBatchDecoder(decoder: fakeDecoder, release: {})
            }
        )
        try await pipeline.prepare()

        let dummyCapture = AudioCapture(sessionDirectory: makeTempSessionDirectory())
        func feed(elapsed: TimeInterval) throws {
            pipeline.audioCapture(dummyCapture, didCapture: try makeMonoFloatBuffer(frameCount: AVAudioFrameCount(Self.chunkSampleCount)), source: .mic, elapsed: elapsed)
        }

        try feed(elapsed: 0.0)
        try feed(elapsed: 1.0)
        // Window 1 confirms here (decoder not yet acquired -- fallback).
        try await Task.sleep(for: .milliseconds(50))

        await acquireGate.open()
        try await Task.sleep(for: .milliseconds(50))

        try feed(elapsed: 2.0)
        // Window 2 confirms here (decoder now available and succeeding -- batch).
        try await Task.sleep(for: .milliseconds(50))

        await fakeDecoder.setOutcome(.fail)
        try feed(elapsed: 3.0)
        // Window 3 confirms here (decoder available but failing -- fallback again).

        await pipeline.stopAndDrain()

        let segments = try await sessionHandle.readTranscriptSegments()
        #expect(segments.map(\.text) == ["あ。", "い", "バッチ2", "え。"])
        #expect(segments.map(\.sttSource) == [nil, nil, "batch", nil])
    }

    // MARK: - Per-source ordering

    @Test("per-source append order is preserved end to end with a successful two-pass redecode")
    func perSourceOrderPreservedWithTwoPassRedecode() async throws {
        let sessionHandle = makeSessionHandle()
        let fakeDecoder = FakeBatchDecoder(outcome: .succeed("バッチ"))
        let pipeline = TranscriptPipeline(
            sessionHandle: sessionHandle,
            backendFactory: { _, _ in
                ScriptedSttStreamingBackend(chunkSampleCount: Self.chunkSampleCount, responses: ["a", "a。"])
            },
            batchDecoderAcquire: { _ in TranscriptPipeline.AcquiredBatchDecoder(decoder: fakeDecoder, release: {}) }
        )
        try await pipeline.prepare()
        try await Task.sleep(for: .milliseconds(50))

        let dummyCapture = AudioCapture(sessionDirectory: makeTempSessionDirectory())
        let frameCount = AVAudioFrameCount(Self.chunkSampleCount)
        pipeline.audioCapture(dummyCapture, didCapture: try makeMonoFloatBuffer(frameCount: frameCount), source: .mic, elapsed: 0.0)
        pipeline.audioCapture(dummyCapture, didCapture: try makeMonoFloatBuffer(frameCount: frameCount), source: .system, elapsed: 0.0)
        pipeline.audioCapture(dummyCapture, didCapture: try makeMonoFloatBuffer(frameCount: frameCount), source: .mic, elapsed: 1.0)
        pipeline.audioCapture(dummyCapture, didCapture: try makeMonoFloatBuffer(frameCount: frameCount), source: .system, elapsed: 1.0)

        await pipeline.stopAndDrain()

        let segments = try await sessionHandle.readTranscriptSegments()
        let micSegments = segments.filter { $0.speaker == .mic }
        let systemSegments = segments.filter { $0.speaker == .system }

        #expect(micSegments.map(\.text) == ["バッチ"])
        #expect(systemSegments.map(\.text) == ["バッチ"])
        #expect(micSegments.allSatisfy { $0.sttSource == "batch" })
        #expect(systemSegments.allSatisfy { $0.sttSource == "batch" })
        // `id`s are assigned in append (call) order -- confirms neither source's redecode blocked the
        // other's append indefinitely nor interleaved out of order (mirrors
        // `TranscriptPipelineIntegrationTests`' own "id は投入順に採番される" invariant).
        #expect(segments.map(\.id) == segments.map(\.id).sorted())
    }

    // MARK: - stopAndDrain() waits for an in-flight redecode

    @Test("stopAndDrain() waits for an in-flight two-pass redecode of the final (residual) window to finish before returning")
    func stopAndDrainWaitsForResidualWindowRedecode() async throws {
        let sessionHandle = makeSessionHandle()
        let delayGate = Gate()
        let fakeDecoder = FakeBatchDecoder(outcome: .succeed("バッチ最終"))
        await fakeDecoder.setDelayGate(delayGate)
        let pipeline = TranscriptPipeline(
            sessionHandle: sessionHandle,
            backendFactory: { _, _ in ScriptedSttStreamingBackend(chunkSampleCount: Self.chunkSampleCount, responses: ["残り"]) },
            batchDecoderAcquire: { _ in TranscriptPipeline.AcquiredBatchDecoder(decoder: fakeDecoder, release: {}) }
        )
        try await pipeline.prepare()
        try await Task.sleep(for: .milliseconds(50))

        let dummyCapture = AudioCapture(sessionDirectory: makeTempSessionDirectory())
        pipeline.audioCapture(dummyCapture, didCapture: try makeMonoFloatBuffer(frameCount: AVAudioFrameCount(Self.chunkSampleCount)), source: .mic, elapsed: 0.0)

        // Nothing confirms yet (no punctuation) -- everything is still pending, so `stop()`'s route 4
        // residual confirms it and cuts the only window, which must go through the gated redecode.
        let stopTask = Task { await pipeline.stopAndDrain() }

        // Give stopAndDrain a moment to actually reach the gated transcribe() call before opening it.
        try await Task.sleep(for: .milliseconds(100))
        await delayGate.open()
        await stopTask.value

        let segments = try await sessionHandle.readTranscriptSegments()
        #expect(segments.map(\.text) == ["バッチ最終"])
        #expect(segments.map(\.sttSource) == ["batch"])
    }

    // MARK: - stopAndDrain() releases the acquired lease exactly once (MT8)

    @Test("stopAndDrain() releases the acquired batch decoder exactly once")
    func stopAndDrainReleasesAcquiredDecoderExactlyOnce() async throws {
        let sessionHandle = makeSessionHandle()
        let fakeDecoder = FakeBatchDecoder(outcome: .succeed("x"))
        let releaseCounter = ReleaseCounter()
        let pipeline = TranscriptPipeline(
            sessionHandle: sessionHandle,
            backendFactory: { _, _ in ScriptedSttStreamingBackend(chunkSampleCount: Self.chunkSampleCount, responses: []) },
            batchDecoderAcquire: { _ in
                TranscriptPipeline.AcquiredBatchDecoder(
                    decoder: fakeDecoder,
                    release: { Task { await releaseCounter.increment() } }
                )
            }
        )
        try await pipeline.prepare()
        try await Task.sleep(for: .milliseconds(50))

        await pipeline.stopAndDrain()
        try await Task.sleep(for: .milliseconds(50))

        #expect(await releaseCounter.count == 1)
    }
}
