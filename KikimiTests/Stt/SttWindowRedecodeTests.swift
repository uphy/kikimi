import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `SttWindowRedecode.resplit` (`Kikimi/Stt/SttWindowRedecode.swift`,
/// `docs/design/33-meeting-two-pass-decode.md` section 3.4/MT3, section 7 layer 1). Pure function,
/// no `SttEngine` actor, no FluidAudio.
@Suite("SttWindowRedecode.resplit")
struct SttWindowRedecodeTests {
    // MARK: - Punctuation splitting (route 1's character set)

    @Test("splits on the same sentence-ending characters as streaming route 1")
    func splitsOnPunctuation() {
        let segments = SttWindowRedecode.resplit(
            batchText: "こんにちは。元気ですか？",
            windowStartMs: 0,
            windowEndMs: 1_000,
            speechStartMs: 0,
            maxSegmentCharacters: 120
        )

        #expect(segments.map(\.text) == ["こんにちは。", "元気ですか？"])
        #expect(segments.allSatisfy { $0.confidence == 1.0 })
    }

    @Test("a punctuation-less remainder is kept as the final piece rather than dropped")
    func noPunctuationKeepsWholeTextAsOnePiece() {
        let segments = SttWindowRedecode.resplit(
            batchText: "まだ続いています",
            windowStartMs: 0,
            windowEndMs: 500,
            speechStartMs: 0,
            maxSegmentCharacters: 120
        )

        #expect(segments.map(\.text) == ["まだ続いています"])
        #expect(segments.first?.startMs == 0)
        #expect(segments.first?.endMs == 500)
    }

    // MARK: - Soft-boundary splitting (route 3's character set) for over-max pieces

    @Test("a piece over maxSegmentCharacters is further split at the last soft boundary in range")
    func splitsOverMaxAtSoftBoundary() {
        // No sentence-ending punctuation at all; "、" (index 3) is the only soft boundary and
        // falls within the first 5 characters ("abc、d"), so it is where the cut lands.
        let segments = SttWindowRedecode.resplit(
            batchText: "abc、defgh",
            windowStartMs: 0,
            windowEndMs: 900,
            speechStartMs: 0,
            maxSegmentCharacters: 5
        )

        #expect(segments.map(\.text) == ["abc、", "defgh"])
    }

    @Test("soft-boundary splitting is applied repeatedly until every piece is within maxSegmentCharacters")
    func repeatedSoftBoundarySplitting() {
        let segments = SttWindowRedecode.resplit(
            batchText: "a、bc、def",
            windowStartMs: 0,
            windowEndMs: 900,
            speechStartMs: 0,
            maxSegmentCharacters: 3
        )

        #expect(segments.map(\.text) == ["a、", "bc、", "def"])
        #expect(segments.allSatisfy { $0.text.count <= 3 })
    }

    // MARK: - Proration monotonicity and endMs == windowEndMs

    @Test("proration is character-count-proportional, floored, and monotonically non-decreasing")
    func prorationIsMonotonicAndFloored() {
        let segments = SttWindowRedecode.resplit(
            batchText: "あ。いい。ううう。",
            windowStartMs: 1_000,
            windowEndMs: 2_000,
            speechStartMs: 1_000,
            maxSegmentCharacters: 120
        )

        #expect(segments.map(\.text) == ["あ。", "いい。", "ううう。"])
        // Character counts: 2, 3, 4 out of 9 total, over a 1000ms span starting at 1000ms.
        #expect(segments[0].startMs == 1_000)
        #expect(segments[0].endMs == 1_000 + Int((1_000.0 * 2 / 9)))
        #expect(segments[1].startMs == segments[0].endMs)
        #expect(segments[1].endMs == 1_000 + Int((1_000.0 * 5 / 9)))
        #expect(segments[2].startMs == segments[1].endMs)

        var previousEnd = -1
        for segment in segments {
            #expect(segment.startMs <= segment.endMs)
            #expect(segment.startMs >= previousEnd)
            previousEnd = segment.endMs
        }
    }

    @Test("the last piece's endMs always equals windowEndMs")
    func lastPieceEndsAtWindowEnd() {
        let segments = SttWindowRedecode.resplit(
            batchText: "ひとつ。ふたつ。みっつ",
            windowStartMs: 0,
            windowEndMs: 12_345,
            speechStartMs: 0,
            maxSegmentCharacters: 120
        )

        #expect(segments.last?.endMs == 12_345)
    }

    // MARK: - speechStartMs clamp (silence-lead origin)

    @Test("when speechStartMs is after windowStartMs, the first piece's startMs is speechStartMs")
    func speechStartMsAfterWindowStartClampsOrigin() {
        let segments = SttWindowRedecode.resplit(
            batchText: "本題です。",
            windowStartMs: 0,
            windowEndMs: 1_000,
            speechStartMs: 300,
            maxSegmentCharacters: 120
        )

        #expect(segments.first?.startMs == 300)
    }

    @Test("when speechStartMs is at or before windowStartMs, the origin is windowStartMs")
    func speechStartMsAtOrBeforeWindowStartUsesWindowStart() {
        let atStart = SttWindowRedecode.resplit(
            batchText: "本題です。",
            windowStartMs: 200,
            windowEndMs: 1_000,
            speechStartMs: 200,
            maxSegmentCharacters: 120
        )
        #expect(atStart.first?.startMs == 200)

        let beforeStart = SttWindowRedecode.resplit(
            batchText: "本題です。",
            windowStartMs: 200,
            windowEndMs: 1_000,
            speechStartMs: 0,
            maxSegmentCharacters: 120
        )
        #expect(beforeStart.first?.startMs == 200)
    }

    @Test("a piece exactly at maxSegmentCharacters is not split further")
    func pieceExactlyAtMaxIsNotSplit() {
        let segments = SttWindowRedecode.resplit(
            batchText: "abc",
            windowStartMs: 0,
            windowEndMs: 300,
            speechStartMs: 0,
            maxSegmentCharacters: 3
        )

        #expect(segments.map(\.text) == ["abc"])
    }

    @Test("maxSegmentCharacters of 0 disables soft-boundary splitting instead of splitting every character")
    func nonPositiveMaxSegmentCharactersDoesNotSplit() {
        let segments = SttWindowRedecode.resplit(
            batchText: "まだ続いています",
            windowStartMs: 0,
            windowEndMs: 900,
            speechStartMs: 0,
            maxSegmentCharacters: 0
        )

        #expect(segments.map(\.text) == ["まだ続いています"])
    }

    // MARK: - Degenerate spans

    @Test("a zero-length window (windowStartMs == windowEndMs) collapses every piece to the same instant")
    func zeroLengthWindowCollapsesAllPieces() {
        let segments = SttWindowRedecode.resplit(
            batchText: "あ。い。",
            windowStartMs: 500,
            windowEndMs: 500,
            speechStartMs: 500,
            maxSegmentCharacters: 120
        )

        #expect(segments.map(\.text) == ["あ。", "い。"])
        #expect(segments.allSatisfy { $0.startMs == 500 && $0.endMs == 500 })
    }

    @Test("a pathological speechStartMs beyond windowEndMs is clamped so the span never goes negative")
    func speechStartMsBeyondWindowEndIsClampedToWindowEnd() {
        let segments = SttWindowRedecode.resplit(
            batchText: "あ。い。",
            windowStartMs: 0,
            windowEndMs: 1_000,
            speechStartMs: 5_000,
            maxSegmentCharacters: 120
        )

        // Origin is clamped to windowEndMs (min(max(windowStartMs, speechStartMs), windowEndMs)),
        // so every piece collapses to windowEndMs rather than reporting a negative span.
        #expect(segments.allSatisfy { $0.startMs == 1_000 && $0.endMs == 1_000 })
    }

    // MARK: - Edges: no punctuation / all whitespace / a single character

    @Test("a single character with no punctuation produces one piece spanning the whole window")
    func singleCharacterEdge() {
        let segments = SttWindowRedecode.resplit(
            batchText: "あ",
            windowStartMs: 0,
            windowEndMs: 250,
            speechStartMs: 0,
            maxSegmentCharacters: 120
        )

        #expect(segments.map(\.text) == ["あ"])
        #expect(segments.first?.startMs == 0)
        #expect(segments.first?.endMs == 250)
    }

    @Test("all-whitespace batch text produces no segments")
    func allWhitespaceEdge() {
        let segments = SttWindowRedecode.resplit(
            batchText: "   ",
            windowStartMs: 0,
            windowEndMs: 250,
            speechStartMs: 0,
            maxSegmentCharacters: 120
        )

        #expect(segments.isEmpty)
    }

    @Test("empty batch text produces no segments")
    func emptyBatchTextEdge() {
        let segments = SttWindowRedecode.resplit(
            batchText: "",
            windowStartMs: 0,
            windowEndMs: 250,
            speechStartMs: 0,
            maxSegmentCharacters: 120
        )

        #expect(segments.isEmpty)
    }
}
