import Foundation
import Testing

@testable import Kikimi

/// `docs/design/31-dictation-two-pass-decode.md` §7's layer-1 list for the pure raw-text selection
/// (TP2's batch-over-streaming precedence and the DH10 "both empty" rule).
@Suite("DictationRawSelection")
struct DictationRawSelectionTests {
    @Test("a non-empty batch text wins and keeps the streaming text as the diagnostic")
    func batchWinsAndKeepsStreamingText() {
        let selection = DictationRawSelection.select(batchText: "今日はレグ環境の構築を行います", streamingText: "はレグ環境の構築を行います")

        #expect(selection?.rawText == "今日はレグ環境の構築を行います")
        #expect(selection?.source == .batch)
        #expect(selection?.streamingText == "はレグ環境の構築を行います")
    }

    @Test("batch and streaming texts are trimmed before use")
    func textsAreTrimmed() {
        let selection = DictationRawSelection.select(batchText: "  バッチ結果 \n", streamingText: " ストリーミング結果\n")

        #expect(selection?.rawText == "バッチ結果")
        #expect(selection?.streamingText == "ストリーミング結果")
    }

    @Test("a batch win with an empty streaming text records no diagnostic")
    func batchWinWithEmptyStreamingHasNilDiagnostic() {
        let selection = DictationRawSelection.select(batchText: "バッチだけが認識した", streamingText: "   ")

        #expect(selection?.rawText == "バッチだけが認識した")
        #expect(selection?.source == .batch)
        #expect(selection?.streamingText == nil)
    }

    @Test("a nil batch text falls back to the streaming text with no diagnostic", arguments: [nil, "", "  \n"] as [String?])
    func unusableBatchFallsBackToStreaming(batchText: String?) {
        let selection = DictationRawSelection.select(batchText: batchText, streamingText: "ストリーミングの結果")

        #expect(selection?.rawText == "ストリーミングの結果")
        #expect(selection?.source == .streaming)
        #expect(selection?.streamingText == nil)
    }

    @Test("both decoders producing only whitespace selects nothing (DH10's empty utterance)")
    func bothEmptySelectsNothing() {
        #expect(DictationRawSelection.select(batchText: "  ", streamingText: " \n") == nil)
        #expect(DictationRawSelection.select(batchText: nil, streamingText: "") == nil)
    }
}
