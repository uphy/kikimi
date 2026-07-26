import Foundation
import OSLog
import Testing
import os

@testable import Kikimi

/// Unit tests for `TranscriptPipeline`'s redecode-selection static functions
/// (`Kikimi/Stt/TranscriptPipeline+Redecode.swift`, `docs/design/33-meeting-two-pass-decode.md` MT4,
/// section 7 layer 1's "選択規則（MT4）" bullet). Unlike `TranscriptPipelineTwoPassTests.swift` (which
/// drives the whole pipeline end to end through `audioCapture(_:didCapture:source:elapsed:)`), these
/// tests call `isEligibleForBatchRedecode`/`redecodeOrFallback`/`redecodeWindowIfEnabled` directly so
/// every MT4 fallback guard (no decoder / under the 0.3s minimum / truncated / throw / empty result)
/// is exercised in isolation, including combinations (e.g. a decoder present but the window still
/// ineligible) that would be awkward to force through the full `SttEngine` confirmation pipeline.
@Suite("TranscriptPipeline redecode selection (MT4)")
struct TranscriptPipelineRedecodeSelectionTests {
    // MARK: - Test doubles

    private struct FakeTranscribeFailure: Error {}

    /// A `SttBatchDecoding` fake that either always succeeds with a fixed string or always throws,
    /// and records every `samples` it was called with -- lets a test assert `transcribe` was (or was
    /// not) invoked at all for a given guard.
    private actor FakeBatchDecoder: SttBatchDecoding {
        enum Outcome {
            case succeed(String)
            case fail
        }

        private let outcome: Outcome
        private(set) var transcribeCallCount = 0

        init(outcome: Outcome) {
            self.outcome = outcome
        }

        func transcribe(samples: [Float]) async throws -> String {
            transcribeCallCount += 1
            switch outcome {
            case .succeed(let text):
                return text
            case .fail:
                throw FakeTranscribeFailure()
            }
        }
    }

    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "TranscriptPipelineRedecodeSelectionTests")

    /// FluidAudio's hard minimum (0.3s @ 16kHz = 4,800 samples) -- the same constant
    /// `isEligibleForBatchRedecode`/`redecodeOrFallback` gate on in production.
    private static let minimumSampleCount = DictationBatchTranscriber.minimumSampleCount

    private func makePieces(text: String = "テスト。", startMs: Int = 0, endMs: Int = 1_000) -> [SttFinalizedSegment] {
        [SttFinalizedSegment(startMs: startMs, endMs: endMs, text: text, confidence: 1.0)]
    }

    private func makeWindow(
        pieces: [SttFinalizedSegment]? = nil,
        sampleCount: Int,
        startElapsed: TimeInterval = 0.0,
        endElapsed: TimeInterval = 1.0,
        truncated: Bool = false
    ) -> SttConfirmedWindow {
        SttConfirmedWindow(
            pieces: pieces ?? makePieces(),
            samples: [Float](repeating: 0, count: sampleCount),
            startElapsed: startElapsed,
            endElapsed: endElapsed,
            truncated: truncated
        )
    }

    // MARK: - isEligibleForBatchRedecode

    @Test("returns false when hasDecoder is false, regardless of samples or truncated")
    func ineligibleWithoutDecoder() {
        let eligibleWindow = makeWindow(sampleCount: Self.minimumSampleCount, truncated: false)
        #expect(TranscriptPipeline.isEligibleForBatchRedecode(window: eligibleWindow, hasDecoder: false) == false)

        let truncatedWindow = makeWindow(sampleCount: Self.minimumSampleCount, truncated: true)
        #expect(TranscriptPipeline.isEligibleForBatchRedecode(window: truncatedWindow, hasDecoder: false) == false)
    }

    @Test("returns false when the window's samples are under the 0.3s minimum even with a decoder")
    func ineligibleUnderMinimumSamples() {
        let window = makeWindow(sampleCount: Self.minimumSampleCount - 1)
        #expect(TranscriptPipeline.isEligibleForBatchRedecode(window: window, hasDecoder: true) == false)
    }

    @Test("returns true at exactly the 0.3s minimum with a decoder and no truncation")
    func eligibleAtExactMinimum() {
        let window = makeWindow(sampleCount: Self.minimumSampleCount)
        #expect(TranscriptPipeline.isEligibleForBatchRedecode(window: window, hasDecoder: true) == true)
    }

    @Test("returns false when the window was truncated by the retention cap, even with enough samples and a decoder")
    func ineligibleWhenTruncated() {
        let window = makeWindow(sampleCount: Self.minimumSampleCount * 10, truncated: true)
        #expect(TranscriptPipeline.isEligibleForBatchRedecode(window: window, hasDecoder: true) == false)
    }

    // MARK: - redecodeOrFallback: guard ① (no decoder / too short / truncated)

    @Test("redecodeOrFallback falls back to the streaming pieces with no stt_source when decoder is nil")
    func fallsBackWhenDecoderNil() async {
        let window = makeWindow(sampleCount: Self.minimumSampleCount)

        let outcome = await TranscriptPipeline.redecodeOrFallback(
            window: window,
            decoder: nil,
            maxSegmentCharacters: 120,
            logger: logger
        )

        #expect(outcome.segments == window.pieces)
        #expect(outcome.sttSource == nil)
    }

    @Test("redecodeOrFallback falls back without calling transcribe when the window is under the minimum, even with a decoder")
    func fallsBackWithoutCallingTranscribeWhenTooShort() async {
        let decoder = FakeBatchDecoder(outcome: .succeed("バッチ結果"))
        let window = makeWindow(sampleCount: Self.minimumSampleCount - 1)

        let outcome = await TranscriptPipeline.redecodeOrFallback(
            window: window,
            decoder: decoder,
            maxSegmentCharacters: 120,
            logger: logger
        )

        #expect(outcome.segments == window.pieces)
        #expect(outcome.sttSource == nil)
        #expect(await decoder.transcribeCallCount == 0)
    }

    @Test("redecodeOrFallback falls back without calling transcribe when the window was truncated, even with a decoder")
    func fallsBackWithoutCallingTranscribeWhenTruncated() async {
        let decoder = FakeBatchDecoder(outcome: .succeed("バッチ結果"))
        let window = makeWindow(sampleCount: Self.minimumSampleCount * 10, truncated: true)

        let outcome = await TranscriptPipeline.redecodeOrFallback(
            window: window,
            decoder: decoder,
            maxSegmentCharacters: 120,
            logger: logger
        )

        #expect(outcome.segments == window.pieces)
        #expect(outcome.sttSource == nil)
        #expect(await decoder.transcribeCallCount == 0)
    }

    // MARK: - redecodeOrFallback: guard ② (transcribe throws)

    @Test("redecodeOrFallback falls back to the streaming pieces when transcribe() throws")
    func fallsBackWhenTranscribeThrows() async {
        let decoder = FakeBatchDecoder(outcome: .fail)
        let window = makeWindow(sampleCount: Self.minimumSampleCount)

        let outcome = await TranscriptPipeline.redecodeOrFallback(
            window: window,
            decoder: decoder,
            maxSegmentCharacters: 120,
            logger: logger
        )

        #expect(outcome.segments == window.pieces)
        #expect(outcome.sttSource == nil)
        #expect(await decoder.transcribeCallCount == 1)
    }

    // MARK: - redecodeOrFallback: guard ③ (empty / whitespace-only batch result)

    @Test("redecodeOrFallback falls back when the batch result is an empty string")
    func fallsBackWhenBatchResultEmpty() async {
        let decoder = FakeBatchDecoder(outcome: .succeed(""))
        let window = makeWindow(sampleCount: Self.minimumSampleCount)

        let outcome = await TranscriptPipeline.redecodeOrFallback(
            window: window,
            decoder: decoder,
            maxSegmentCharacters: 120,
            logger: logger
        )

        #expect(outcome.segments == window.pieces)
        #expect(outcome.sttSource == nil)
    }

    @Test("redecodeOrFallback falls back when the batch result is whitespace-only")
    func fallsBackWhenBatchResultWhitespaceOnly() async {
        let decoder = FakeBatchDecoder(outcome: .succeed("   \n\t "))
        let window = makeWindow(sampleCount: Self.minimumSampleCount)

        let outcome = await TranscriptPipeline.redecodeOrFallback(
            window: window,
            decoder: decoder,
            maxSegmentCharacters: 120,
            logger: logger
        )

        #expect(outcome.segments == window.pieces)
        #expect(outcome.sttSource == nil)
    }

    // MARK: - redecodeOrFallback: success

    @Test("redecodeOrFallback resplits the batch text and tags stt_source \"batch\" on success")
    func successResplitsAndTagsBatchSource() async {
        let decoder = FakeBatchDecoder(outcome: .succeed("こんにちは。元気ですか？"))
        let window = makeWindow(
            pieces: makePieces(text: "こんにちは", startMs: 200, endMs: 900),
            sampleCount: Self.minimumSampleCount,
            startElapsed: 0.0,
            endElapsed: 2.0
        )

        let outcome = await TranscriptPipeline.redecodeOrFallback(
            window: window,
            decoder: decoder,
            maxSegmentCharacters: 120,
            logger: logger
        )

        let expected = SttWindowRedecode.resplit(
            batchText: "こんにちは。元気ですか？",
            windowStartMs: 0,
            windowEndMs: 2_000,
            speechStartMs: 200,
            maxSegmentCharacters: 120
        )
        #expect(outcome.segments == expected)
        #expect(outcome.sttSource == "batch")
        #expect(await decoder.transcribeCallCount == 1)
    }

    @Test("redecodeOrFallback derives speechStartMs from the window's startElapsed when pieces is empty")
    func speechStartMsFallsBackToWindowStartWhenPiecesEmpty() async {
        let decoder = FakeBatchDecoder(outcome: .succeed("バッチのみのテキスト。"))
        let window = makeWindow(
            pieces: [],
            sampleCount: Self.minimumSampleCount,
            startElapsed: 1.5,
            endElapsed: 3.0
        )

        let outcome = await TranscriptPipeline.redecodeOrFallback(
            window: window,
            decoder: decoder,
            maxSegmentCharacters: 120,
            logger: logger
        )

        let expected = SttWindowRedecode.resplit(
            batchText: "バッチのみのテキスト。",
            windowStartMs: 1_500,
            windowEndMs: 3_000,
            speechStartMs: 1_500,
            maxSegmentCharacters: 120
        )
        #expect(outcome.segments == expected)
        #expect(outcome.sttSource == "batch")
    }

    // MARK: - redecodeWindowIfEnabled

    @Test("redecodeWindowIfEnabled passes window.pieces straight through with no stt_source when two-pass is off, without ever calling the stored decoder")
    func passesThroughUntouchedWhenTwoPassOff() async {
        let decoder = FakeBatchDecoder(outcome: .succeed("バッチ結果"))
        let lease = TranscriptPipeline.AcquiredBatchDecoder(decoder: decoder, release: {})
        let storage = OSAllocatedUnfairLock<TranscriptPipeline.AcquiredBatchDecoder?>(initialState: lease)
        let window = makeWindow(sampleCount: Self.minimumSampleCount)

        let outcome = await TranscriptPipeline.redecodeWindowIfEnabled(
            window,
            twoPassDecode: false,
            batchDecoderStorage: storage,
            maxSegmentCharacters: 120,
            logger: logger
        )

        #expect(outcome.segments == window.pieces)
        #expect(outcome.sttSource == nil)
        #expect(await decoder.transcribeCallCount == 0)
    }

    @Test("redecodeWindowIfEnabled falls back when two-pass is on but no decoder has been stored yet")
    func fallsBackWhenTwoPassOnButStorageEmpty() async {
        let storage = OSAllocatedUnfairLock<TranscriptPipeline.AcquiredBatchDecoder?>(initialState: nil)
        let window = makeWindow(sampleCount: Self.minimumSampleCount)

        let outcome = await TranscriptPipeline.redecodeWindowIfEnabled(
            window,
            twoPassDecode: true,
            batchDecoderStorage: storage,
            maxSegmentCharacters: 120,
            logger: logger
        )

        #expect(outcome.segments == window.pieces)
        #expect(outcome.sttSource == nil)
    }

    @Test("redecodeWindowIfEnabled delegates to the stored decoder and tags stt_source \"batch\" when two-pass is on")
    func delegatesToStoredDecoderWhenTwoPassOn() async {
        let decoder = FakeBatchDecoder(outcome: .succeed("バッチ結果。"))
        let lease = TranscriptPipeline.AcquiredBatchDecoder(decoder: decoder, release: {})
        let storage = OSAllocatedUnfairLock<TranscriptPipeline.AcquiredBatchDecoder?>(initialState: lease)
        let window = makeWindow(sampleCount: Self.minimumSampleCount)

        let outcome = await TranscriptPipeline.redecodeWindowIfEnabled(
            window,
            twoPassDecode: true,
            batchDecoderStorage: storage,
            maxSegmentCharacters: 120,
            logger: logger
        )

        #expect(outcome.sttSource == "batch")
        #expect(await decoder.transcribeCallCount == 1)
    }
}
