import AVFoundation
import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `SttEngine`'s side-effect-free helpers (`Kikimi/Stt/SttEngine+PureHelpers.swift`,
/// `docs/design/11-streaming-stt.md` section 3.12's "新設の純粋ロジックを検証する"). These exercise the
/// static functions directly (no actor, no `SttStreamingBackend`, no async) -- the streaming
/// counterpart to the previous VAD-era `SttEnginePureHelpersTests.swift`, replaced wholesale because
/// the pure-logic surface itself is entirely new (chunk accumulation + cumulative-text segment
/// confirmation instead of RMS/dedup + a VAD state machine).
@Suite("SttEngine.extractSamples")
struct SttEngineExtractSamplesTests {
    @Test("returns the buffer's samples in order for a populated Float32 mono buffer")
    func populatedBuffer() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let channel = try #require(buffer.floatChannelData)
        for index in 0..<4 {
            channel[0][index] = Float(index) * 0.1
        }

        let samples = SttEngine.extractSamples(from: buffer)

        #expect(samples == [0.0, 0.1, 0.2, 0.3])
    }

    @Test("returns an empty array when frameLength is zero")
    func zeroFrameLength() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 0

        #expect(SttEngine.extractSamples(from: buffer).isEmpty)
    }

    @Test("returns an empty array when the buffer has no float channel data (e.g. an Int16 format)")
    func nonFloatBuffer() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4

        #expect(SttEngine.extractSamples(from: buffer).isEmpty)
    }
}

@Suite("SttEngine.accumulateAndExtractChunks")
struct SttEngineAccumulateAndExtractChunksTests {
    @Test("accumulates below chunkSampleCount without extracting anything")
    func belowThreshold() {
        var accumulator = SttChunkAccumulator()

        let chunks = SttEngine.accumulateAndExtractChunks(
            accumulator: &accumulator,
            newSamples: [1, 2, 3],
            elapsedAtBufferStart: 0.5,
            chunkSampleCount: 10
        )

        #expect(chunks.isEmpty)
        #expect(accumulator.samples == [1, 2, 3])
        #expect(accumulator.startElapsed == 0.5)
    }

    @Test("extracts exactly one chunk once the threshold is reached, leaving no remainder")
    func exactThreshold() {
        var accumulator = SttChunkAccumulator()

        let chunks = SttEngine.accumulateAndExtractChunks(
            accumulator: &accumulator,
            newSamples: [1, 2, 3, 4],
            elapsedAtBufferStart: 1.0,
            chunkSampleCount: 4
        )

        #expect(chunks.count == 1)
        #expect(chunks[0].samples == [1, 2, 3, 4])
        #expect(chunks[0].startElapsed == 1.0)
        #expect(chunks[0].endElapsed == 1.0)
        #expect(accumulator.samples.isEmpty)
        #expect(accumulator.startElapsed == nil)
    }

    @Test("extracts multiple chunks from a single oversized feed() call")
    func multipleChunksInOneCall() {
        var accumulator = SttChunkAccumulator()

        let chunks = SttEngine.accumulateAndExtractChunks(
            accumulator: &accumulator,
            newSamples: Array(1...9).map { Float($0) },
            elapsedAtBufferStart: 2.0,
            chunkSampleCount: 4
        )

        #expect(chunks.count == 2)
        #expect(chunks[0].samples == [1, 2, 3, 4])
        #expect(chunks[1].samples == [5, 6, 7, 8])
        // The remainder (sample 9) stays in the accumulator, anchored to this call's elapsed time
        // since it just became non-empty.
        #expect(accumulator.samples == [9])
        #expect(accumulator.startElapsed == 2.0)
    }

    @Test("startElapsed of a chunk reflects when its first sample arrived, not the completing call")
    func startElapsedTracksFirstArrival() {
        var accumulator = SttChunkAccumulator()

        let firstCall = SttEngine.accumulateAndExtractChunks(
            accumulator: &accumulator,
            newSamples: [1, 2],
            elapsedAtBufferStart: 0.1,
            chunkSampleCount: 4
        )
        #expect(firstCall.isEmpty)

        let secondCall = SttEngine.accumulateAndExtractChunks(
            accumulator: &accumulator,
            newSamples: [3, 4],
            elapsedAtBufferStart: 0.3,
            chunkSampleCount: 4
        )

        #expect(secondCall.count == 1)
        #expect(secondCall[0].samples == [1, 2, 3, 4])
        // Anchored to the call that started the chunk (0.1), not the call that completed it (0.3).
        #expect(secondCall[0].startElapsed == 0.1)
        #expect(secondCall[0].endElapsed == 0.3)
    }

    @Test("chunkSampleCount <= 0 yields no chunks and leaves the accumulator untouched")
    func nonPositiveChunkSampleCount() {
        var accumulator = SttChunkAccumulator()

        let chunks = SttEngine.accumulateAndExtractChunks(
            accumulator: &accumulator,
            newSamples: [1, 2, 3],
            elapsedAtBufferStart: 0.0,
            chunkSampleCount: 0
        )

        #expect(chunks.isEmpty)
        #expect(accumulator.samples.isEmpty)
    }
}

@Suite("SttEngine.flushChunk")
struct SttEngineFlushChunkTests {
    @Test("returns nil when the accumulator is empty")
    func emptyAccumulator() {
        let flushed = SttEngine.flushChunk(
            accumulator: SttChunkAccumulator(),
            elapsedAtBufferStart: 5.0,
            chunkSampleCount: 4
        )

        #expect(flushed == nil)
    }

    @Test("zero-pads a partial remainder up to chunkSampleCount")
    func zeroPadsPartialRemainder() {
        let accumulator = SttChunkAccumulator(samples: [1, 2], startElapsed: 3.0)

        let flushed = SttEngine.flushChunk(
            accumulator: accumulator,
            elapsedAtBufferStart: 3.5,
            chunkSampleCount: 4
        )

        let result = try? #require(flushed)
        #expect(result?.samples == [1, 2, 0, 0])
        #expect(result?.startElapsed == 3.0)
        #expect(result?.endElapsed == 3.5)
    }

    @Test("does not pad when the remainder already equals chunkSampleCount")
    func exactRemainderIsNotPadded() {
        let accumulator = SttChunkAccumulator(samples: [1, 2, 3, 4], startElapsed: 1.0)

        let flushed = SttEngine.flushChunk(
            accumulator: accumulator,
            elapsedAtBufferStart: 1.2,
            chunkSampleCount: 4
        )

        #expect(flushed?.samples == [1, 2, 3, 4])
    }

    @Test("falls back to elapsedAtBufferStart when startElapsed is nil but samples are non-empty")
    func fallsBackToElapsedAtBufferStartWhenStartElapsedMissing() {
        // Not reachable in practice (accumulator.startElapsed is only nil when samples is empty), but
        // the `?? elapsedAtBufferStart` fallback is defensive code worth pinning down explicitly.
        let accumulator = SttChunkAccumulator(samples: [1], startElapsed: nil)

        let flushed = SttEngine.flushChunk(
            accumulator: accumulator,
            elapsedAtBufferStart: 9.0,
            chunkSampleCount: 2
        )

        #expect(flushed?.startElapsed == 9.0)
    }

    @Test("chunkSampleCount <= 0 returns nil even with pending samples")
    func nonPositiveChunkSampleCountReturnsNil() {
        let accumulator = SttChunkAccumulator(samples: [1, 2], startElapsed: 0.0)

        let flushed = SttEngine.flushChunk(
            accumulator: accumulator,
            elapsedAtBufferStart: 0.0,
            chunkSampleCount: 0
        )

        #expect(flushed == nil)
    }
}

@Suite("SttEngine.computePendingText")
struct SttEngineComputePendingTextTests {
    @Test("returns the full text when nothing has been confirmed yet")
    func nothingConfirmed() {
        #expect(SttEngine.computePendingText(cumulativeText: "こんにちは", confirmedCharacterCount: 0) == "こんにちは")
    }

    @Test("returns the suffix beyond confirmedCharacterCount")
    func partiallyConfirmed() {
        #expect(SttEngine.computePendingText(cumulativeText: "こんにちは世界", confirmedCharacterCount: 5) == "世界")
    }

    @Test("returns empty once confirmedCharacterCount has caught up to the full text")
    func fullyConfirmed() {
        #expect(SttEngine.computePendingText(cumulativeText: "こんにちは", confirmedCharacterCount: 5) == "")
    }

    @Test("returns empty when confirmedCharacterCount exceeds the text length (defensive)")
    func confirmedCountExceedsLength() {
        #expect(SttEngine.computePendingText(cumulativeText: "こんにちは", confirmedCharacterCount: 100) == "")
    }

    @Test("returns empty for an empty cumulative text")
    func emptyCumulativeText() {
        #expect(SttEngine.computePendingText(cumulativeText: "", confirmedCharacterCount: 0) == "")
    }
}

@Suite("SttEngine.splitPendingTextOnPunctuation")
struct SttEngineSplitPendingTextOnPunctuationTests {
    @Test("returns no confirmed segments and the original text when there is no punctuation")
    func noPunctuation() {
        let result = SttEngine.splitPendingTextOnPunctuation("そうですね次のスプリントで対応します")

        #expect(result.confirmedSegments.isEmpty)
        #expect(result.remainingPendingText == "そうですね次のスプリントで対応します")
    }

    @Test("splits a single terminated sentence, including the terminator, with no remainder")
    func singleSentence() {
        let result = SttEngine.splitPendingTextOnPunctuation("次のスプリントで対応します。")

        #expect(result.confirmedSegments == ["次のスプリントで対応します。"])
        #expect(result.remainingPendingText.isEmpty)
    }

    @Test("splits multiple sentences within one chunk, in order, keeping the trailing remainder pending")
    func multipleSentencesWithRemainder() {
        let result = SttEngine.splitPendingTextOnPunctuation("了解しました。次は何ですか？残りは")

        #expect(result.confirmedSegments == ["了解しました。", "次は何ですか？"])
        #expect(result.remainingPendingText == "残りは")
    }

    @Test("half-width terminators (?/!) are also treated as sentence endings")
    func halfWidthTerminators() {
        let result = SttEngine.splitPendingTextOnPunctuation("Really!Are you sure?ok")

        #expect(result.confirmedSegments == ["Really!", "Are you sure?"])
        #expect(result.remainingPendingText == "ok")
    }

    @Test("a custom sentenceEndingCharacters set is honored")
    func customTerminatorSet() {
        let result = SttEngine.splitPendingTextOnPunctuation("foo;bar;baz", sentenceEndingCharacters: [";"])

        #expect(result.confirmedSegments == ["foo;", "bar;"])
        #expect(result.remainingPendingText == "baz")
    }

    @Test("empty input returns no confirmed segments and an empty remainder")
    func emptyInput() {
        let result = SttEngine.splitPendingTextOnPunctuation("")

        #expect(result.confirmedSegments.isEmpty)
        #expect(result.remainingPendingText.isEmpty)
    }
}

@Suite("SttEngine.shouldForceConfirmOnMaxCharacters")
struct SttEngineShouldForceConfirmOnMaxCharactersTests {
    @Test("false when at or below the limit")
    func atOrBelowLimit() {
        #expect(!SttEngine.shouldForceConfirmOnMaxCharacters(pendingText: String(repeating: "a", count: 120), maxSegmentCharacters: 120))
        #expect(!SttEngine.shouldForceConfirmOnMaxCharacters(pendingText: "short", maxSegmentCharacters: 120))
    }

    @Test("true once strictly above the limit")
    func aboveLimit() {
        #expect(SttEngine.shouldForceConfirmOnMaxCharacters(pendingText: String(repeating: "a", count: 121), maxSegmentCharacters: 120))
    }

    @Test("empty pending text never force-confirms regardless of the limit")
    func emptyPendingText() {
        #expect(!SttEngine.shouldForceConfirmOnMaxCharacters(pendingText: "", maxSegmentCharacters: 0))
    }
}

@Suite("SttEngine.splitPendingTextAtSoftBoundary")
struct SttEngineSplitPendingTextAtSoftBoundaryTests {
    @Test("backs off to the last soft boundary within the max-character window, keeping the rest pending")
    func backsOffToLastSoftBoundaryInRange() {
        // "あ" x5 + "、" (boundary, index 5) + "い" x10, maxSegmentCharacters = 8: the window
        // (indices 0..<8) contains exactly one soft boundary, at index 5.
        let pendingText = String(repeating: "あ", count: 5) + "、" + String(repeating: "い", count: 10)

        let result = SttEngine.splitPendingTextAtSoftBoundary(
            pendingText,
            maxSegmentCharacters: 8,
            softBoundaryCharacters: SttEngineConfig.softBoundaryCharacters
        )

        #expect(result.confirmedSegments == [String(repeating: "あ", count: 5) + "、"])
        #expect(result.remainingPendingText == String(repeating: "い", count: 10))
    }

    @Test("falls back to confirming the entire text when no soft boundary is in range")
    func fallsBackToWholeTextWhenNoBoundaryInRange() {
        let pendingText = String(repeating: "a", count: 130)

        let result = SttEngine.splitPendingTextAtSoftBoundary(
            pendingText,
            maxSegmentCharacters: 120,
            softBoundaryCharacters: SttEngineConfig.softBoundaryCharacters
        )

        #expect(result.confirmedSegments == [pendingText])
        #expect(result.remainingPendingText.isEmpty)
    }

    @Test("includes a soft boundary that lands exactly at the last character of the window")
    func softBoundaryExactlyAtWindowEdge() {
        // maxSegmentCharacters = 6: window is indices 0..<6, so a boundary at index 5 (the 6th
        // character) is the last character still inside the window.
        let pendingText = String(repeating: "a", count: 5) + "、" + String(repeating: "b", count: 10)

        let result = SttEngine.splitPendingTextAtSoftBoundary(
            pendingText,
            maxSegmentCharacters: 6,
            softBoundaryCharacters: SttEngineConfig.softBoundaryCharacters
        )

        #expect(result.confirmedSegments == [String(repeating: "a", count: 5) + "、"])
        #expect(result.remainingPendingText == String(repeating: "b", count: 10))
    }

    @Test("picks the last of multiple soft boundaries within the window, not the first")
    func picksLastOfMultipleSoftBoundariesInRange() {
        // Two boundaries within the window (indices 0..<10): "、" at index 3 and "・" at index 7.
        let expectedConfirmed = "abc、defg・"
        let expectedRemainder = String(repeating: "z", count: 20)
        let pendingText = expectedConfirmed + expectedRemainder

        let result = SttEngine.splitPendingTextAtSoftBoundary(
            pendingText,
            maxSegmentCharacters: 10,
            softBoundaryCharacters: SttEngineConfig.softBoundaryCharacters
        )

        #expect(result.confirmedSegments == [expectedConfirmed])
        #expect(result.remainingPendingText == expectedRemainder)
    }

    @Test("text at or below the limit is confirmed whole, with no attempt to back off")
    func atOrBelowLimitConfirmsWhole() {
        let pendingText = "abc、def"

        let result = SttEngine.splitPendingTextAtSoftBoundary(
            pendingText,
            maxSegmentCharacters: 100,
            softBoundaryCharacters: SttEngineConfig.softBoundaryCharacters
        )

        #expect(result.confirmedSegments == [pendingText])
        #expect(result.remainingPendingText.isEmpty)
    }
}

@Suite("SttEngine.shouldConfirmOnIdleTimeout")
struct SttEngineShouldConfirmOnIdleTimeoutTests {
    @Test("false while pending text is empty, even past the timeout")
    func emptyPendingTextNeverTimesOut() {
        #expect(!SttEngine.shouldConfirmOnIdleTimeout(pendingText: "", elapsedSinceLastGrowth: 10.0, segmentIdleTimeout: 2.0))
    }

    @Test("false before the timeout elapses")
    func beforeTimeout() {
        #expect(!SttEngine.shouldConfirmOnIdleTimeout(pendingText: "残り", elapsedSinceLastGrowth: 1.9, segmentIdleTimeout: 2.0))
    }

    @Test("true exactly at the timeout boundary (inclusive)")
    func exactlyAtTimeout() {
        #expect(SttEngine.shouldConfirmOnIdleTimeout(pendingText: "残り", elapsedSinceLastGrowth: 2.0, segmentIdleTimeout: 2.0))
    }

    @Test("true once past the timeout")
    func pastTimeout() {
        #expect(SttEngine.shouldConfirmOnIdleTimeout(pendingText: "残り", elapsedSinceLastGrowth: 5.0, segmentIdleTimeout: 2.0))
    }
}
