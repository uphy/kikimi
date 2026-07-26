import Foundation
import Testing

@testable import Kikimi

// MARK: - FakeDictationSttBackend

/// Deterministic, network-free stand-in for `FluidAudioStreamingBackend`, mirroring
/// `SttEngineTests.FakeSttStreamingBackend`'s shape (`docs/design/25-dictation-mode.md` §11's
/// "`SttStreamingBackend` をフェイク注入し、reset → feed → finish の順序と、finish の全文がそのまま
/// 返ることを検証"). Declared separately (rather than reusing that private type) since it lives in a
/// different file and `SttEngineTests`' fake is `private`.
private actor FakeDictationSttBackend: SttStreamingBackend {
    nonisolated let chunkSampleCount: Int

    private(set) var callOrder: [String] = []
    private(set) var processChunkSamples: [[Float]] = []
    var finishText = ""
    var processChunkError: Error?
    var finishError: Error?
    /// Queue of cumulative-text values `processChunk` returns, consumed one per call (falls back to
    /// `""` once exhausted). Lets tests assert `feed(samples:)`'s return value without depending on
    /// `SttStreamingBackend.processChunk`'s real "cumulative, not delta" FluidAudio behavior.
    private var processChunkReturnQueue: [String] = []

    init(chunkSampleCount: Int) {
        self.chunkSampleCount = chunkSampleCount
    }

    func setFinishText(_ text: String) {
        finishText = text
    }

    func setProcessChunkError(_ error: Error?) {
        processChunkError = error
    }

    func enqueueProcessChunkText(_ text: String) {
        processChunkReturnQueue.append(text)
    }

    func processChunk(_ samples: [Float]) async throws -> String {
        callOrder.append("processChunk")
        processChunkSamples.append(samples)
        if let processChunkError {
            throw processChunkError
        }
        if !processChunkReturnQueue.isEmpty {
            return processChunkReturnQueue.removeFirst()
        }
        return ""
    }

    func finish() async throws -> String {
        callOrder.append("finish")
        if let finishError {
            throw finishError
        }
        return finishText
    }

    func reset() async {
        callOrder.append("reset")
    }
}

private struct FakeBackendError: Error, Equatable {}

@Suite("DictationTranscriber")
struct DictationTranscriberTests {
    @Test("beginUtterance resets the backend before any feed")
    func beginUtteranceResetsBackend() async {
        let backend = FakeDictationSttBackend(chunkSampleCount: 4)
        let transcriber = DictationTranscriber(backend: backend)

        await transcriber.beginUtterance()

        let order = await backend.callOrder
        #expect(order == ["reset"])
    }

    @Test("feed processes samples only once a full chunk has accumulated")
    func feedAccumulatesToChunkBoundary() async throws {
        let backend = FakeDictationSttBackend(chunkSampleCount: 4)
        let transcriber = DictationTranscriber(backend: backend)

        try await transcriber.feed(samples: [1, 2])
        #expect(await backend.callOrder.isEmpty, "fewer samples than chunkSampleCount must not call processChunk yet")

        try await transcriber.feed(samples: [3, 4])
        let order = await backend.callOrder
        #expect(order == ["processChunk"])
        let received = await backend.processChunkSamples
        #expect(received == [[1, 2, 3, 4]])
    }

    @Test("feed processes every full chunk when a single feed spans more than one")
    func feedExtractsMultipleChunksFromOneCall() async throws {
        let backend = FakeDictationSttBackend(chunkSampleCount: 2)
        let transcriber = DictationTranscriber(backend: backend)

        try await transcriber.feed(samples: [1, 2, 3, 4, 5])

        let received = await backend.processChunkSamples
        #expect(received == [[1, 2], [3, 4]])
    }

    @Test("finishUtterance zero-pads a partial remainder and returns the backend's finish() text")
    func finishUtteranceFlushesRemainderAndReturnsFinishText() async throws {
        let backend = FakeDictationSttBackend(chunkSampleCount: 4)
        await backend.setFinishText("次のスプリントで対応します")
        let transcriber = DictationTranscriber(backend: backend)

        try await transcriber.feed(samples: [1, 2])
        let text = try await transcriber.finishUtterance()

        #expect(text == "次のスプリントで対応します")
        let order = await backend.callOrder
        #expect(order == ["processChunk", "finish"])
        let received = await backend.processChunkSamples
        #expect(received == [[1, 2, 0, 0]], "the partial remainder must be zero-padded to a full chunk")
    }

    @Test("finishUtterance skips the flush processChunk call when no remainder is buffered")
    func finishUtteranceSkipsFlushWhenExactlyAligned() async throws {
        let backend = FakeDictationSttBackend(chunkSampleCount: 2)
        await backend.setFinishText("done")
        let transcriber = DictationTranscriber(backend: backend)

        try await transcriber.feed(samples: [1, 2])
        let text = try await transcriber.finishUtterance()

        #expect(text == "done")
        let order = await backend.callOrder
        #expect(order == ["processChunk", "finish"])
    }

    @Test("a full reset -> feed -> finish cycle runs in that order")
    func fullCycleRunsInOrder() async throws {
        let backend = FakeDictationSttBackend(chunkSampleCount: 4)
        await backend.setFinishText("こんにちは")
        let transcriber = DictationTranscriber(backend: backend)

        await transcriber.beginUtterance()
        try await transcriber.feed(samples: [1, 2, 3, 4])
        let text = try await transcriber.finishUtterance()

        #expect(text == "こんにちは")
        let order = await backend.callOrder
        #expect(order == ["reset", "processChunk", "finish"])
    }

    @Test("a second utterance's beginUtterance clears the leftover sub-chunk remainder from the first")
    func beginUtteranceClearsLeftoverRemainder() async throws {
        let backend = FakeDictationSttBackend(chunkSampleCount: 4)
        let transcriber = DictationTranscriber(backend: backend)

        try await transcriber.feed(samples: [1, 2]) // leaves a 2-sample remainder, never flushed
        await transcriber.beginUtterance()
        try await transcriber.feed(samples: [9, 9])
        _ = try await transcriber.finishUtterance()

        let received = await backend.processChunkSamples
        #expect(received == [[9, 9, 0, 0]], "the first utterance's unflushed remainder must not leak into the second")
    }

    @Test("finishUtterance propagates a processChunk failure from the flush call")
    func finishUtterancePropagatesProcessChunkError() async throws {
        let backend = FakeDictationSttBackend(chunkSampleCount: 4)
        await backend.setProcessChunkError(FakeBackendError())
        let transcriber = DictationTranscriber(backend: backend)

        try await transcriber.feed(samples: [1])
        await #expect(throws: FakeBackendError.self) {
            _ = try await transcriber.finishUtterance()
        }
    }

    // MARK: - feed's live-preview return value (docs/design/25-dictation-mode.md's "ライブプレビューHUD")

    @Test("feed returns nil when accumulated samples do not reach a full chunk")
    func feedReturnsNilBelowChunkBoundary() async throws {
        let backend = FakeDictationSttBackend(chunkSampleCount: 4)
        let transcriber = DictationTranscriber(backend: backend)

        let text = try await transcriber.feed(samples: [1, 2])

        #expect(text == nil)
    }

    @Test("feed returns the backend's cumulative text once a chunk boundary is crossed")
    func feedReturnsCumulativeTextAtChunkBoundary() async throws {
        let backend = FakeDictationSttBackend(chunkSampleCount: 2)
        await backend.enqueueProcessChunkText("こんにち")
        let transcriber = DictationTranscriber(backend: backend)

        let text = try await transcriber.feed(samples: [1, 2])

        #expect(text == "こんにち")
    }

    @Test("feed returns the last of multiple processChunk calls made within a single invocation")
    func feedReturnsLastOfMultipleChunksInOneCall() async throws {
        let backend = FakeDictationSttBackend(chunkSampleCount: 2)
        await backend.enqueueProcessChunkText("A")
        await backend.enqueueProcessChunkText("AB")
        let transcriber = DictationTranscriber(backend: backend)

        let text = try await transcriber.feed(samples: [1, 2, 3, 4])

        #expect(text == "AB")
    }

    @Test("consecutive feed calls each return their own latest cumulative text")
    func consecutiveFeedCallsReturnTheirOwnLatestText() async throws {
        let backend = FakeDictationSttBackend(chunkSampleCount: 2)
        let transcriber = DictationTranscriber(backend: backend)

        await backend.enqueueProcessChunkText("A")
        let first = try await transcriber.feed(samples: [1, 2])
        #expect(first == "A")

        await backend.enqueueProcessChunkText("AB")
        let second = try await transcriber.feed(samples: [3, 4])
        #expect(second == "AB")
    }
}
