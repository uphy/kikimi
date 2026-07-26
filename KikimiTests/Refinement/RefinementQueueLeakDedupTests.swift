import Foundation
import Testing

@testable import Kikimi

/// `RefinementQueue.leakDedupLogMessages(batch:contextSegments:validated:)` coverage
/// (`docs/design/24-system-audio-leak-mitigation.md` §4.6). This is the pure computation behind
/// `RefinementQueue+BatchProcessing.swift`'s `logLeakDedupCandidates` debug logging -- an actor's
/// `static` members are not actor-isolated, so it is callable directly without spinning up a queue.
@Suite("RefinementQueue.leakDedupLogMessages")
struct RefinementQueueLeakDedupTests {
    @Test("emits a 'nearby system segment' message when a context segment is (system)")
    func candidateWithSystemSegmentInContext() {
        let contextSegments = [
            makeContextSegment(id: "seg_00040", startMs: 0, speaker: .system, text: "了解しました"),
        ]
        let batch = [
            makeSegment(id: "seg_00042", startMs: 1_000, speaker: .mic, text: "了解しました"),
        ]
        let validated = [
            makeRefinedSegment(id: "seg_00042", startMs: 1_000, speaker: .mic, refinedText: ""),
        ]

        let messages = RefinementQueue.leakDedupLogMessages(batch: batch, contextSegments: contextSegments, validated: validated)

        #expect(messages.count == 1)
        #expect(messages[0].contains("seg_00042"))
        #expect(messages[0].contains("nearby system segment(s) in this batch's LLM context: seg_00040"))
    }

    @Test("emits a 'nearby system segment' message when a (system) segment is in the same batch")
    func candidateWithSystemSegmentInBatch() {
        let batch = [
            makeSegment(id: "seg_00041", startMs: 900, speaker: .system, text: "了解しました"),
            makeSegment(id: "seg_00042", startMs: 1_000, speaker: .mic, text: "了解しました"),
        ]
        let validated = [
            makeRefinedSegment(id: "seg_00041", startMs: 900, speaker: .system, refinedText: "了解しました。"),
            makeRefinedSegment(id: "seg_00042", startMs: 1_000, speaker: .mic, refinedText: ""),
        ]

        let messages = RefinementQueue.leakDedupLogMessages(batch: batch, contextSegments: [], validated: validated)

        #expect(messages.count == 1)
        #expect(messages[0].contains("seg_00042"))
        #expect(messages[0].contains("nearby system segment(s) in this batch's LLM context: seg_00041"))
    }

    @Test("emits a 'no system segment visible' message when neither context nor batch has a (system) segment")
    func candidateWithoutAnySystemSegment() {
        let batch = [
            makeSegment(id: "seg_00042", startMs: 1_000, speaker: .mic, text: "えーと"),
        ]
        let validated = [
            makeRefinedSegment(id: "seg_00042", startMs: 1_000, speaker: .mic, refinedText: ""),
        ]

        let messages = RefinementQueue.leakDedupLogMessages(batch: batch, contextSegments: [], validated: validated)

        #expect(messages.count == 1)
        #expect(messages[0].contains("seg_00042"))
        #expect(messages[0].contains("no system segment visible to this batch (likely filler removal)"))
    }

    @Test("lists every visible system segment id, startMs ascending, from both context and batch")
    func candidateListsAllVisibleSystemIdsInStartMsOrder() {
        let contextSegments = [
            makeContextSegment(id: "seg_00039", startMs: 500, speaker: .system, text: "そうですね"),
        ]
        let batch = [
            makeSegment(id: "seg_00040", startMs: 1_500, speaker: .system, text: "了解です"),
            makeSegment(id: "seg_00041", startMs: 1_000, speaker: .mic, text: "了解です"),
        ]
        let validated = [
            makeRefinedSegment(id: "seg_00040", startMs: 1_500, speaker: .system, refinedText: "了解です。"),
            makeRefinedSegment(id: "seg_00041", startMs: 1_000, speaker: .mic, refinedText: ""),
        ]

        let messages = RefinementQueue.leakDedupLogMessages(batch: batch, contextSegments: contextSegments, validated: validated)

        #expect(messages.count == 1)
        #expect(messages[0].contains("nearby system segment(s) in this batch's LLM context: seg_00039, seg_00040"))
    }

    @Test("ignores (system) segments emptied out -- only speaker == .mic is a candidate")
    func systemSegmentEmptiedOutIsNotACandidate() {
        let batch = [
            makeSegment(id: "seg_00042", startMs: 1_000, speaker: .system, text: "えーと"),
        ]
        let validated = [
            makeRefinedSegment(id: "seg_00042", startMs: 1_000, speaker: .system, refinedText: ""),
        ]

        let messages = RefinementQueue.leakDedupLogMessages(batch: batch, contextSegments: [], validated: validated)

        #expect(messages.isEmpty)
    }

    @Test("ignores mic segments that were not emptied out (non-empty refinedText)")
    func nonEmptyRefinedTextIsNotACandidate() {
        let batch = [
            makeSegment(id: "seg_00042", startMs: 1_000, speaker: .mic, text: "次のスプリントで対応します"),
        ]
        let validated = [
            makeRefinedSegment(id: "seg_00042", startMs: 1_000, speaker: .mic, refinedText: "次のスプリントで対応します。"),
        ]

        let messages = RefinementQueue.leakDedupLogMessages(batch: batch, contextSegments: [], validated: validated)

        #expect(messages.isEmpty)
    }

    @Test("ignores mic segments that failed refinement (refinedText == nil, not empty string)")
    func nilRefinedTextIsNotACandidate() {
        let batch = [
            makeSegment(id: "seg_00042", startMs: 1_000, speaker: .mic, text: "次のスプリントで対応します"),
        ]
        let validated = [
            makeRefinedSegment(id: "seg_00042", startMs: 1_000, speaker: .mic, refinedText: nil, error: "boom"),
        ]

        let messages = RefinementQueue.leakDedupLogMessages(batch: batch, contextSegments: [], validated: validated)

        #expect(messages.isEmpty)
    }

    @Test("empty validated list produces no messages")
    func emptyValidatedProducesNoMessages() {
        let messages = RefinementQueue.leakDedupLogMessages(batch: [], contextSegments: [], validated: [])

        #expect(messages.isEmpty)
    }

    // MARK: - Helpers

    private func makeSegment(id: String, startMs: Int, speaker: AudioSourceKind, text: String) -> TranscriptSegment {
        TranscriptSegment(id: id, startMs: startMs, endMs: startMs + 500, speaker: speaker, text: text, confidence: 0.9)
    }

    private func makeContextSegment(id: String, startMs: Int, speaker: AudioSourceKind, text: String) -> RefinementContextSegment {
        RefinementContextSegment(segment: makeSegment(id: id, startMs: startMs, speaker: speaker, text: text), refinedText: text)
    }

    private func makeRefinedSegment(
        id: String,
        startMs: Int,
        speaker: AudioSourceKind,
        refinedText: String?,
        error: String? = nil
    ) -> RefinedSegment {
        RefinedSegment(
            id: id,
            startMs: startMs,
            endMs: startMs + 500,
            speaker: speaker,
            rawText: "raw",
            refinedText: refinedText,
            error: error,
            refinedAt: Date(timeIntervalSince1970: 0),
            model: "claude-haiku-4-5-20251001",
            batchId: "batch_00000"
        )
    }
}
