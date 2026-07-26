import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `BatchAsrDecoder.splitForSingleWindowDecode`, the pure silence-seeking split
/// that keeps every piece handed to `AsrManager.transcribe` at or below
/// `ASRConstants.maxModelSamples` so FluidAudio never reroutes internally to its lossy
/// `ChunkProcessor` (see `BatchAsrDecoder.transcribe(samples:)`'s doc comment and
/// `BatchRedecodeReproTests`, which reproduced the token drop against real audio). All fixtures
/// here are synthesized tones/silence -- no real audio or model, matching this suite's existing
/// fake-only convention (`SttEnginePureHelpersTests.swift`).
@Suite("BatchAsrDecoder.splitForSingleWindowDecode")
struct BatchAsrDecoderSplitTests {
    private static let sampleRate = 16_000

    @Test("empty input returns a single empty range")
    func emptyInput() {
        let ranges = BatchAsrDecoder.splitForSingleWindowDecode(samples: [])
        #expect(ranges == [0..<0])
    }

    @Test("input at or under the max window comes back as a single range spanning it all")
    func underOrAtMaxWindow() {
        let exactlyAtMax = Self.constantSignal(count: 240_000)
        let underMax = Self.constantSignal(count: 100)

        #expect(BatchAsrDecoder.splitForSingleWindowDecode(samples: exactlyAtMax) == [0..<240_000])
        #expect(BatchAsrDecoder.splitForSingleWindowDecode(samples: underMax) == [0..<100])
    }

    @Test("31s-equivalent input splits into 2-3 pieces, each within FluidAudio's window bounds")
    func longInputSplitsIntoBoundedPieces() {
        // 31s @ 16kHz, loud throughout (no silence to seek) -- exercises the pure offset-based
        // fallback (lowest-energy frame still picked, but energy is uniform).
        let samples = Self.constantSignal(count: 31 * Self.sampleRate, amplitude: 0.5)

        let ranges = BatchAsrDecoder.splitForSingleWindowDecode(samples: samples)

        #expect((2...3).contains(ranges.count))
        // Contiguous, gapless, and covers the whole input.
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == samples.count)
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            #expect(previous.upperBound == next.lowerBound)
        }
        let minimumSampleCount = Int(0.3 * Double(Self.sampleRate))
        for range in ranges {
            #expect(range.count <= 240_000, "piece exceeds ASRConstants.maxModelSamples")
            #expect(range.count >= minimumSampleCount, "piece violates FluidAudio's 0.3s minimum")
        }
    }

    @Test("split point lands inside a silent gap placed within the search window")
    func splitPrefersSilence() {
        // 18s total: loud, then a 1s silent gap starting at 12s, then loud again. The search
        // window for the first (only) split on 18s input is [10s, 14.5s], which fully contains
        // the gap, so the chosen split point must fall inside [12s, 13s).
        let sampleRate = Self.sampleRate
        var samples = Self.constantSignal(count: 12 * sampleRate, amplitude: 0.8)
        samples += Self.constantSignal(count: 1 * sampleRate, amplitude: 0.0)
        samples += Self.constantSignal(count: 5 * sampleRate, amplitude: 0.8)

        let ranges = BatchAsrDecoder.splitForSingleWindowDecode(samples: samples)

        #expect(ranges.count == 2)
        let splitPoint = ranges[0].upperBound
        #expect((12 * sampleRate..<13 * sampleRate).contains(splitPoint))
    }

    @Test("every remainder after a split satisfies the 0.5s floor implied by the [10s, 14.5s] search window")
    func remainderFloor() {
        // Just over 3 max windows (45.5s) to exercise multiple loop iterations.
        let samples = Self.constantSignal(count: Int(45.5 * Double(Self.sampleRate)), amplitude: 0.3)

        let ranges = BatchAsrDecoder.splitForSingleWindowDecode(samples: samples)

        let halfSecond = Int(0.5 * Double(Self.sampleRate))
        var cursor = 0
        for range in ranges.dropLast() {
            cursor = range.upperBound
            let remainder = samples.count - cursor
            #expect(remainder >= halfSecond)
        }
    }

    private static func constantSignal(count: Int, amplitude: Float = 1.0) -> [Float] {
        Array(repeating: amplitude, count: count)
    }
}

/// Unit tests for `BatchAsrDecoder.joinPieceTexts`: piece boundaries in CJK text must join with
/// no separator (FluidAudio's own merge never inserted one; a mid-sentence ASCII space would be
/// visible in pasted Japanese dictation text), while space-delimited scripts keep their space.
@Suite("BatchAsrDecoder.joinPieceTexts")
struct BatchAsrDecoderJoinTests {
    @Test("CJK boundaries join without a separator")
    func cjkBoundariesJoinDirectly() {
        #expect(BatchAsrDecoder.joinPieceTexts(["書き込み先を", "テーブルを分ける。"]) == "書き込み先をテーブルを分ける。")
        // CJK punctuation on the left side also joins directly.
        #expect(BatchAsrDecoder.joinPieceTexts(["必要ですか。", "顧客と両方が"]) == "必要ですか。顧客と両方が")
        // Katakana boundary.
        #expect(BatchAsrDecoder.joinPieceTexts(["テーブ", "ルを別に"]) == "テーブルを別に")
    }

    @Test("Latin boundaries keep an ASCII space separator")
    func latinBoundariesKeepSpace() {
        #expect(BatchAsrDecoder.joinPieceTexts(["hello world", "this is a test"]) == "hello world this is a test")
    }

    @Test("a mixed boundary (either side CJK) joins without a separator")
    func mixedBoundaryJoinsDirectly() {
        #expect(BatchAsrDecoder.joinPieceTexts(["LayerX側の書き込み", "APIとの競合"]) == "LayerX側の書き込みAPIとの競合")
        #expect(BatchAsrDecoder.joinPieceTexts(["書き込みはAPI", "経由で行う"]) == "書き込みはAPI経由で行う")
    }

    @Test("empty and single-piece inputs pass through")
    func degenerateInputs() {
        #expect(BatchAsrDecoder.joinPieceTexts([]).isEmpty)
        #expect(BatchAsrDecoder.joinPieceTexts(["一つだけ"]) == "一つだけ")
    }
}
