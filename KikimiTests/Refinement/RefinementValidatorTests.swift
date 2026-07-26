import Foundation
import Testing

@testable import Kikimi

/// `RefinementValidator` coverage: every row of `docs/design/03-refinement-batch.md` §5.1's table.
@Suite("RefinementValidator")
struct RefinementValidatorTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let model = "claude-haiku-4-5-20251001"
    private let batchId = "batch_00001"

    @Test("id present with non-empty refined_text -> refinedText set, error nil")
    func matchingNonEmptyRefinedText() {
        let batch = [makeSegment(id: "seg_00001")]
        let response = RefinementResponse(segments: [.init(id: "seg_00001", refinedText: "整形済みテキスト")])

        let (segments, warnings) = RefinementValidator.validate(batch: batch, response: response, now: now, model: model, batchId: batchId)

        #expect(segments.count == 1)
        #expect(segments[0].refinedText == "整形済みテキスト")
        #expect(segments[0].error == nil)
        #expect(warnings.isEmpty)
    }

    @Test("id missing from response -> refinedText nil, error 'missing from LLM response'")
    func idMissingFromResponse() throws {
        let batch = [makeSegment(id: "seg_00001"), makeSegment(id: "seg_00002")]
        let response = RefinementResponse(segments: [.init(id: "seg_00001", refinedText: "ok")])

        let (segments, warnings) = RefinementValidator.validate(batch: batch, response: response, now: now, model: model, batchId: batchId)

        let missing = try #require(segments.first { $0.id == "seg_00002" })
        #expect(missing.refinedText == nil)
        #expect(missing.error == "missing from LLM response")
        #expect(warnings.isEmpty)
    }

    @Test("refined_text is empty string -> intentional drop: refinedText \"\", error nil")
    func emptyRefinedTextIsIntentionalDrop() {
        let batch = [makeSegment(id: "seg_00001")]
        let response = RefinementResponse(segments: [.init(id: "seg_00001", refinedText: "")])

        let (segments, warnings) = RefinementValidator.validate(batch: batch, response: response, now: now, model: model, batchId: batchId)

        #expect(segments[0].refinedText == "")
        #expect(segments[0].error == nil)
        #expect(warnings.isEmpty)
    }

    @Test("duplicate id in response -> first entry wins, warning logged")
    func duplicateIdInResponse() {
        let batch = [makeSegment(id: "seg_00001")]
        let response = RefinementResponse(segments: [
            .init(id: "seg_00001", refinedText: "first wins"),
            .init(id: "seg_00001", refinedText: "second ignored"),
        ])

        let (segments, warnings) = RefinementValidator.validate(batch: batch, response: response, now: now, model: model, batchId: batchId)

        #expect(segments.count == 1)
        #expect(segments[0].refinedText == "first wins")
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("duplicate id"))
        #expect(warnings[0].contains("seg_00001"))
    }

    @Test("unknown id in response is ignored (no segment written for it) and warns")
    func unknownIdInResponse() {
        let batch = [makeSegment(id: "seg_00001")]
        let response = RefinementResponse(segments: [
            .init(id: "seg_00001", refinedText: "ok"),
            .init(id: "seg_99999", refinedText: "not in batch"),
        ])

        let (segments, warnings) = RefinementValidator.validate(batch: batch, response: response, now: now, model: model, batchId: batchId)

        #expect(segments.count == 1)
        #expect(segments[0].id == "seg_00001")
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("unknown id"))
        #expect(warnings[0].contains("seg_99999"))
    }

    @Test("always produces exactly batch.count segments, in batch order, even with an empty response")
    func alwaysProducesOneSegmentPerBatchEntryInOrder() {
        let batch = [makeSegment(id: "seg_00001"), makeSegment(id: "seg_00002"), makeSegment(id: "seg_00003")]
        let response = RefinementResponse(segments: [])

        let (segments, _) = RefinementValidator.validate(batch: batch, response: response, now: now, model: model, batchId: batchId)

        #expect(segments.map(\.id) == ["seg_00001", "seg_00002", "seg_00003"])
        #expect(segments.allSatisfy { $0.error == "missing from LLM response" })
    }

    @Test("every returned segment is stamped with refinedAt/model/batchId and preserves timing/speaker/rawText")
    func stampsMetadataAndPreservesSourceFields() {
        let segment = TranscriptSegment(id: "seg_00001", startMs: 1_000, endMs: 1_500, speaker: .system, text: "raw text", confidence: 0.8)
        let response = RefinementResponse(segments: [.init(id: "seg_00001", refinedText: "refined")])

        let (segments, _) = RefinementValidator.validate(batch: [segment], response: response, now: now, model: model, batchId: batchId)

        let result = segments[0]
        #expect(result.startMs == 1_000)
        #expect(result.endMs == 1_500)
        #expect(result.speaker == .system)
        #expect(result.rawText == "raw text")
        #expect(result.refinedAt == now)
        #expect(result.model == model)
        #expect(result.batchId == batchId)
    }

    // MARK: - Helpers

    private func makeSegment(id: String) -> TranscriptSegment {
        TranscriptSegment(id: id, startMs: 0, endMs: 500, speaker: .mic, text: "raw \(id)", confidence: 0.9)
    }
}
