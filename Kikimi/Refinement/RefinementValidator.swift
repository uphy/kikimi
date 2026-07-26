import Foundation

// MARK: - RefinementValidator

/// Validates a `RefinementResponse` against the batch it was generated for, producing exactly one
/// `RefinedSegment` per batch segment (`docs/design/03-refinement-batch.md` §5.1, kikimi.md 5 章
/// 「整形失敗時: `refined_text: null, error: "エラーメッセージ"` を追記して次に進む」).
///
/// Pure: no file I/O, no `Date()`. Callers (`RefinementQueue`) pass `now`/`model`/`batchId` in
/// explicitly and are responsible for appending the returned segments and logging the returned
/// warnings.
enum RefinementValidator {
    /// Matches each segment in `batch` against `response` (matching direction is always "batch
    /// segment -> look up in response by id", never the other way around -- §5.1) and returns:
    ///
    /// - `segments`: exactly `batch.count` `RefinedSegment` values, one per batch segment, in the
    ///   same order as `batch`, per the §5.1 table:
    ///   - id present in response -> `refinedText` set (verbatim, including `""`), `error: nil`.
    ///     An empty string is the prompt-sanctioned "meaningless segment, drop it" marker
    ///     (kikimi.md 7 章の整形ルール), not a failure -- downstream consumers hide/skip these
    ///     instead of falling back to `rawText`.
    ///   - id missing from response -> `refinedText: nil, error: "missing from LLM response"`
    /// - `warnings`: one entry per anomaly worth logging (caller's job to log), covering:
    ///   - a duplicate id within `response.segments` (first occurrence wins; later ones warn+skip)
    ///   - an id in `response.segments` that is not in `batch` (ignored; no `RefinedSegment` written
    ///     for it, since output is always driven by `batch`, not by the response)
    ///
    /// - Parameters:
    ///   - batch: The segments this response is for. Order is preserved in the output.
    ///   - response: The decoded LLM response.
    ///   - now: Current time, stamped onto every returned segment's `refinedAt`.
    ///   - model: The model id stamped onto every returned segment. Callers pass the backend's
    ///     `respondedModel` when available (the model that actually answered), falling back to the
    ///     configured `refinement.model` otherwise -- see `RefinementQueue+BatchProcessing.swift`'s
    ///     `callLLM`/`processBatch`.
    ///   - batchId: This batch's identifier (`"batch_" + 5-digit sequence`, §5.1), stamped onto
    ///     every returned segment.
    static func validate(
        batch: [TranscriptSegment],
        response: RefinementResponse,
        now: Date,
        model: String,
        batchId: String
    ) -> (segments: [RefinedSegment], warnings: [String]) {
        let batchIds = Set(batch.map(\.id))
        var byId: [String: RefinementResponse.Item] = [:]
        var warnings: [String] = []

        for item in response.segments {
            guard batchIds.contains(item.id) else {
                warnings.append("unknown id in LLM response: \(item.id) (ignored)")
                continue
            }
            guard byId[item.id] == nil else {
                warnings.append("duplicate id in LLM response: \(item.id) (first occurrence kept)")
                continue
            }
            byId[item.id] = item
        }

        let segments = batch.map { transcriptSegment in
            makeRefinedSegment(
                for: transcriptSegment,
                matched: byId[transcriptSegment.id],
                now: now,
                model: model,
                batchId: batchId
            )
        }
        return (segments, warnings)
    }

    private static func makeRefinedSegment(
        for transcriptSegment: TranscriptSegment,
        matched: RefinementResponse.Item?,
        now: Date,
        model: String,
        batchId: String
    ) -> RefinedSegment {
        let refinedText: String?
        let error: String?
        switch matched {
        case .some(let item):
            refinedText = item.refinedText
            error = nil
        case .none:
            refinedText = nil
            error = "missing from LLM response"
        }

        return RefinedSegment(
            id: transcriptSegment.id,
            startMs: transcriptSegment.startMs,
            endMs: transcriptSegment.endMs,
            speaker: transcriptSegment.speaker,
            rawText: transcriptSegment.text,
            refinedText: refinedText,
            error: error,
            refinedAt: now,
            model: model,
            batchId: batchId
        )
    }
}
