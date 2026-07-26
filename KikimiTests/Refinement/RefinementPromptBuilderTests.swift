import Foundation
import Testing

@testable import Kikimi

/// `RefinementPromptBuilder` coverage: system prompt embedding + 32KB clamp, and user prompt
/// ordering/formatting (`docs/design/03-refinement-batch.md` §4.2, §13).
@Suite("RefinementPromptBuilder")
struct RefinementPromptBuilderTests {
    // MARK: buildSystemPrompt

    @Test("embeds the context verbatim under 【事前知識】 and reports no clamping when it fits")
    func systemPromptEmbedsContextUnderLimit() {
        let (prompt, wasClamped) = RefinementPromptBuilder.buildSystemPrompt(context: "用語集: PJX = 案件コード")

        #expect(!wasClamped)
        #expect(prompt.contains("【事前知識】\n用語集: PJX = 案件コード"))
        #expect(prompt.contains("あなたは会議書き起こしを整形する専門家です"))
        #expect(prompt.contains("【出力形式】"))
    }

    @Test("instructs the LLM to return an empty refined_text for meaningless segments")
    func systemPromptIncludesMeaninglessSegmentDropRule() {
        let (prompt, _) = RefinementPromptBuilder.buildSystemPrompt(context: "")

        #expect(prompt.contains("refined_text を空文字にする"))
        #expect(prompt.contains("{\"id\": \"seg_XXXXX\", \"refined_text\": \"\"}"))
    }

    @Test("dedupSystemLeakSegments defaults to true and includes the leak-dedup rule (24-system-audio-leak-mitigation.md §4.2)")
    func systemPromptDefaultsToIncludingLeakDedupRule() {
        let (prompt, _) = RefinementPromptBuilder.buildSystemPrompt(context: "")

        #expect(prompt.contains("スピーカーの音がマイクに回り込んで二重に書き起こされたものとみなし"))
    }

    @Test("dedupSystemLeakSegments: true includes the leak-dedup rule")
    func systemPromptIncludesLeakDedupRuleWhenEnabled() {
        let (prompt, _) = RefinementPromptBuilder.buildSystemPrompt(context: "", dedupSystemLeakSegments: true)

        #expect(prompt.contains("(mic) セグメントの内容が、直前の文脈または今回のバッチ内にある近い時刻の (system) セグメントとほぼ同じ内容の場合"))
        #expect(prompt.contains("その (mic) セグメントの refined_text を空文字にする（対応する (system) セグメント側は変更しない）"))
    }

    @Test("dedupSystemLeakSegments: false omits the leak-dedup rule")
    func systemPromptOmitsLeakDedupRuleWhenDisabled() {
        let (prompt, _) = RefinementPromptBuilder.buildSystemPrompt(context: "", dedupSystemLeakSegments: false)

        #expect(!prompt.contains("スピーカーの音がマイクに回り込んで二重に書き起こされたものとみなし"))
        #expect(!prompt.contains("(system) セグメントとほぼ同じ内容の場合"))
        // Everything else (filler-removal rule, output-format section) is unaffected.
        #expect(prompt.contains("refined_text を空文字にする（そのセグメントを削除する扱い）"))
        #expect(prompt.contains("【出力形式】"))
    }

    @Test("instructs the LLM on the joins_next hint (§15.2.2)")
    func systemPromptIncludesJoinsNextRule() {
        let (prompt, _) = RefinementPromptBuilder.buildSystemPrompt(context: "")

        #expect(prompt.contains("joins_next"))
        #expect(prompt.contains("文が不自然に途切れて次のセグメントに続いている場合は joins_next を true にする"))
    }

    @Test("empty context still produces a valid prompt")
    func systemPromptWithEmptyContext() {
        let (prompt, wasClamped) = RefinementPromptBuilder.buildSystemPrompt(context: "")

        #expect(!wasClamped)
        #expect(prompt.contains("【事前知識】"))
        #expect(prompt.contains("【出力形式】"))
        #expect(extractContext(from: prompt).isEmpty)
    }

    @Test("context over 32KB is clamped to the limit and wasClamped is true")
    func systemPromptClampsOversizedContext() {
        let oversized = String(repeating: "a", count: RefinementPromptBuilder.maxContextBytes + 100)

        let (prompt, wasClamped) = RefinementPromptBuilder.buildSystemPrompt(context: oversized)

        #expect(wasClamped)
        // The embedded context (between the two known headers) should be exactly at the byte limit.
        let embedded = extractContext(from: prompt)
        #expect(embedded.utf8.count == RefinementPromptBuilder.maxContextBytes)
    }

    @Test("context exactly at the limit is not clamped")
    func systemPromptExactlyAtLimitIsNotClamped() {
        let exact = String(repeating: "a", count: RefinementPromptBuilder.maxContextBytes)

        let (_, wasClamped) = RefinementPromptBuilder.buildSystemPrompt(context: exact)

        #expect(!wasClamped)
    }

    // MARK: - glossaryBlock (`docs/design/28-glossary.md` §3)

    @Test("glossaryBlock defaults to nil, so omitting it leaves the prompt exactly as before")
    func systemPromptOmitsGlossarySectionWhenNil() {
        let (prompt, _) = RefinementPromptBuilder.buildSystemPrompt(context: "アジェンダ: 進捗確認")

        #expect(prompt.contains("【事前知識】\nアジェンダ: 進捗確認\n\n【出力形式】"))
    }

    @Test("a non-nil glossaryBlock is appended after the 事前知識 block, before 出力形式")
    func systemPromptAppendsGlossaryBlockAfterContext() {
        let glossaryBlock = GlossaryRenderer.render(entries: [GlossaryEntry(term: "nekosuke", reading: "ねこすけ")])!

        let (prompt, _) = RefinementPromptBuilder.buildSystemPrompt(context: "アジェンダ: 進捗確認", glossaryBlock: glossaryBlock)

        #expect(prompt.contains("【事前知識】\nアジェンダ: 進捗確認\n\n\(glossaryBlock)\n\n【出力形式】"))
    }

    @Test("an empty context still renders the glossary block correctly")
    func systemPromptAppendsGlossaryBlockWithEmptyContext() {
        let glossaryBlock = GlossaryRenderer.render(entries: [GlossaryEntry(term: "nekosuke", reading: "ねこすけ")])!

        let (prompt, _) = RefinementPromptBuilder.buildSystemPrompt(context: "", glossaryBlock: glossaryBlock)

        #expect(prompt.contains("【事前知識】\n\n\n\(glossaryBlock)\n\n【出力形式】"))
    }

    // MARK: clampToByteLimit (multi-byte safety)

    @Test("clampToByteLimit never splits a multi-byte UTF-8 character")
    func clampDoesNotSplitMultiByteCharacters() {
        // Each "あ" is 3 bytes in UTF-8; a limit that lands mid-character must back off cleanly.
        let text = String(repeating: "あ", count: 10)
        let limit = 3 * 3 + 1 // 10 bytes: 3 full characters (9 bytes) plus 1 stray byte

        let (clamped, wasClamped) = RefinementPromptBuilder.clampToByteLimit(text, limit: limit)

        #expect(wasClamped)
        #expect(clamped == String(repeating: "あ", count: 3))
        #expect(clamped.utf8.count <= limit)
    }

    // MARK: buildUserPrompt

    @Test("orders context segments by startMs ascending regardless of input order")
    func userPromptOrdersContextByStartMsAscending() {
        let contextSegments = [
            makeContextSegment(id: "seg_00003", startMs: 3_000, speaker: .mic, text: "third"),
            makeContextSegment(id: "seg_00001", startMs: 1_000, speaker: .system, text: "first"),
            makeContextSegment(id: "seg_00002", startMs: 2_000, speaker: .mic, text: "second"),
        ]

        let prompt = RefinementPromptBuilder.buildUserPrompt(contextSegments: contextSegments, batchSegments: [])

        let contextBlock = extractSection(prompt, header: "【直前の文脈（整形済み）】", nextHeader: "【今回整形する対象】")
        #expect(contextBlock == "seg_00001 (system): first\nseg_00002 (mic): second\nseg_00003 (mic): third")
    }

    @Test("prefers refinedText over raw text when present, falls back to raw otherwise")
    func userPromptPrefersRefinedTextOverRaw() {
        let contextSegments = [
            RefinementContextSegment(
                segment: TranscriptSegment(id: "seg_00001", startMs: 0, endMs: 100, speaker: .mic, text: "raw one", confidence: 0.9),
                refinedText: "refined one"
            ),
            RefinementContextSegment(
                segment: TranscriptSegment(id: "seg_00002", startMs: 100, endMs: 200, speaker: .mic, text: "raw two", confidence: 0.9),
                refinedText: nil
            ),
        ]

        let prompt = RefinementPromptBuilder.buildUserPrompt(contextSegments: contextSegments, batchSegments: [])

        let contextBlock = extractSection(prompt, header: "【直前の文脈（整形済み）】", nextHeader: "【今回整形する対象】")
        #expect(contextBlock == "seg_00001 (mic): refined one\nseg_00002 (mic): raw two")
    }

    @Test("omits context segments dropped by refinement (empty refinedText)")
    func userPromptOmitsDroppedContextSegments() {
        let contextSegments = [
            RefinementContextSegment(
                segment: TranscriptSegment(id: "seg_00001", startMs: 0, endMs: 100, speaker: .mic, text: "えーと", confidence: 0.9),
                refinedText: ""
            ),
            RefinementContextSegment(
                segment: TranscriptSegment(id: "seg_00002", startMs: 100, endMs: 200, speaker: .mic, text: "raw two", confidence: 0.9),
                refinedText: "refined two"
            ),
        ]

        let prompt = RefinementPromptBuilder.buildUserPrompt(contextSegments: contextSegments, batchSegments: [])

        let contextBlock = extractSection(prompt, header: "【直前の文脈（整形済み）】", nextHeader: "【今回整形する対象】")
        #expect(contextBlock == "seg_00002 (mic): refined two")
    }

    @Test("orders batch segments by startMs ascending regardless of input order")
    func userPromptOrdersBatchByStartMsAscending() {
        let batch = [
            TranscriptSegment(id: "seg_00042", startMs: 2_000, endMs: 2_500, speaker: .mic, text: "second", confidence: 0.9),
            TranscriptSegment(id: "seg_00041", startMs: 1_000, endMs: 1_500, speaker: .system, text: "first", confidence: 0.9),
        ]

        let prompt = RefinementPromptBuilder.buildUserPrompt(contextSegments: [], batchSegments: batch)

        let batchBlock = extractSection(prompt, header: "【今回整形する対象】", nextHeader: nil)
        #expect(batchBlock == "seg_00041 (system): first\nseg_00042 (mic): second")
    }

    @Test("empty context and batch still render both headers with empty bodies")
    func userPromptWithEmptyInputsRendersBothHeaders() {
        let prompt = RefinementPromptBuilder.buildUserPrompt(contextSegments: [], batchSegments: [])

        #expect(prompt.contains("【直前の文脈（整形済み）】"))
        #expect(prompt.contains("【今回整形する対象】"))
    }

    // MARK: - Helpers

    private func makeContextSegment(id: String, startMs: Int, speaker: AudioSourceKind, text: String) -> RefinementContextSegment {
        RefinementContextSegment(
            segment: TranscriptSegment(id: id, startMs: startMs, endMs: startMs + 100, speaker: speaker, text: text, confidence: 0.9),
            refinedText: nil
        )
    }

    /// Extracts the text between `【事前知識】\n` and `\n\n【出力形式】` from a rendered system prompt.
    private func extractContext(from prompt: String) -> String {
        guard
            let startRange = prompt.range(of: "【事前知識】\n"),
            let endRange = prompt.range(of: "\n\n【出力形式】")
        else {
            return ""
        }
        return String(prompt[startRange.upperBound..<endRange.lowerBound])
    }

    /// Extracts the body text under `header` up to (but not including) `nextHeader`, or to the end
    /// of the string if `nextHeader` is `nil`.
    private func extractSection(_ prompt: String, header: String, nextHeader: String?) -> String {
        guard let headerRange = prompt.range(of: header) else { return "" }
        let afterHeader = prompt[headerRange.upperBound...].drop { $0 == "\n" }
        if let nextHeader, let nextRange = afterHeader.range(of: nextHeader) {
            return String(afterHeader[afterHeader.startIndex..<nextRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(afterHeader).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
