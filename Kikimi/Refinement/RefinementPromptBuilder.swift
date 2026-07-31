import Foundation

// MARK: - RefinementContextSegment

/// One "直前の文脈" line's worth of information (kikimi.md 7 章's user prompt example / this
/// design's §4.2). Pairs a `TranscriptSegment` with its refined text when one exists, so
/// `RefinementPromptBuilder` can apply the "refined があれば refined、なければ raw" fallback without
/// itself needing to know about `refined.jsonl`/`SessionHandle` (kept pure, per the task's "no I/O"
/// constraint).
struct RefinementContextSegment: Sendable, Equatable {
    var segment: TranscriptSegment
    /// `nil` when this segment has not been refined yet (or refinement failed for it); the raw
    /// `segment.text` is used in that case.
    var refinedText: String?
}

// MARK: - RefinementPromptBuilder

/// Builds the fixed system prompt and per-batch user prompt for a refinement LLM call
/// (`docs/design/03-refinement-batch.md` §4.2, kikimi.md 7 章「Prompt 設計」).
///
/// Pure by construction: no file I/O, no `Date()`/environment reads. Callers (`RefinementQueue`)
/// resolve `context.md` contents, in-memory context history, and the current batch, and pass
/// everything in explicitly.
enum RefinementPromptBuilder {
    /// Context embedded in the system prompt is clamped to this many UTF-8 bytes before being
    /// folded in (kikimi.md 7 章「ファイルサイズ上限は 32KB。超過時は warning（内容は使う）」,
    /// 03-refinement-batch.md §4.2). Logging the warning is the caller's job -- this type only
    /// reports whether clamping happened via `wasClamped`.
    static let maxContextBytes = 32 * 1_024

    /// The `{{leak_dedup_rule}}` placeholder token `ruleBody` may embed (`docs/design/42-prompt-
    /// overrides.md` §2.1's optional placeholder for the `refinement` prompt id, `PromptSpec.spec(for:
    /// .refinement).optionalPlaceholders`). `ruleBody`'s built-in default value lives at
    /// `PromptSpec.spec(for: .refinement).defaultBody` (`Kikimi/Prompts/PromptSpec.swift`) -- not
    /// duplicated here -- with this exact token at the same position the pre-refactor hardcoded prompt
    /// used to conditionally interpolate the leak-dedup bullet (§9.1's default-equivalence requirement).
    static let leakDedupRuleToken = "{{leak_dedup_rule}}"

    /// Assembles the refinement system prompt from a 方針層 (policy-layer) `ruleBody` plus the fixed
    /// 契約層 (contract-layer) blocks the app always appends (`docs/design/42-prompt-overrides.md`
    /// §2.2's fixed structure: `<ruleBody>` + 【事前知識】 + 【出力形式】). `context` is clamped to
    /// `maxContextBytes` first; `wasClamped` tells the caller whether that happened so it can log the
    /// kikimi.md-mandated warning.
    ///
    /// - Parameters:
    ///   - ruleBody: The 方針層 body, `{{leak_dedup_rule}}` unexpanded (`RefinementQueue
    ///     .ruleBodyProvider()`'s session-start snapshot -- either `PromptSpec.spec(for:
    ///     .refinement).defaultBody` or an active `prompts/refinement.md` override's body). Expanded
    ///     via `PromptPlaceholder.expand` before being folded into the assembled prompt, so an override
    ///     that omits the optional token simply never sees the leak-dedup rule appended, and one that
    ///     repeats it gets the same text at every occurrence (single left-to-right pass, no
    ///     re-expansion -- §4.1).
    ///   - dedupSystemLeakSegments: When `true` (the default), `{{leak_dedup_rule}}` expands to the
    ///     24-system-audio-leak-mitigation.md §4.2 rule instructing the LLM to empty out a `(mic)`
    ///     segment's `refined_text` when it duplicates a nearby `(system)` segment (acoustic leakage
    ///     of speaker output into the mic). `false` expands it to the empty string instead, restoring
    ///     the prior prompt verbatim. Callers pass `config.dedupSystemLeakSegments` (§4.3), which is
    ///     fixed for the lifetime of a session, so this never breaks the system prompt's cache-hit
    ///     fixedness (kikimi.md 7 章).
    ///   - glossaryBlock: `GlossaryRenderer.render(entries:)`'s output for the top-level `glossary`
    ///     config section (`docs/design/28-glossary.md` §2/§3), or `nil` to omit the section entirely
    ///     (the default -- also what `GlossaryRenderer.render(entries:)` itself returns for an empty
    ///     glossary). Injected as its own block, separate from `context`'s "【事前知識】" section, so a
    ///     `context.md` edit and a glossary edit never fight over the same slot. Shared verbatim with
    ///     `DictationContextResolver.resolve(bundleID:config:glossary:)` -- both refinement call sites
    ///     use the same `GlossaryRenderer`, per that design doc's "会議・ディクテーションで別々の実装を
    ///     持たない" decision.
    static func buildSystemPrompt(
        ruleBody: String,
        context: String,
        glossaryBlock: String? = nil,
        dedupSystemLeakSegments: Bool = true
    ) -> (prompt: String, wasClamped: Bool) {
        let (clamped, wasClamped) = clampToByteLimit(context, limit: maxContextBytes)
        let leakDedupRule = dedupSystemLeakSegments
            ? "\n- (mic) セグメントの内容が、直前の文脈または今回のバッチ内にある近い時刻の (system) セグメントとほぼ同じ内容の場合、スピーカーの音がマイクに回り込んで二重に書き起こされたものとみなし、その (mic) セグメントの refined_text を空文字にする（対応する (system) セグメント側は変更しない）"
            : ""
        let expandedRuleBody = PromptPlaceholder.expand(
            template: ruleBody,
            replacements: [(leakDedupRuleToken, leakDedupRule)]
        )
        let glossarySection = glossaryBlock.map { "\n\n\($0)" } ?? ""
        let prompt = """
        \(expandedRuleBody)

        【事前知識】
        \(clamped)\(glossarySection)

        【出力形式】
        schema の "segments" 配列で、対象セグメント数分の整形結果を返す。
        segments の各要素: {"id": "seg_XXXXX", "refined_text": "...", "joins_next": false}
        意味のある内容がないセグメントは refined_text を空文字（{"id": "seg_XXXXX", "refined_text": ""}）にする。
        文が不自然に途切れて次のセグメントに続いている場合は joins_next を true にする。意味的に独立していれば false にする。
        """
        return (prompt, wasClamped)
    }

    /// Builds the per-batch user prompt (kikimi.md 7 章's "User prompt（毎回変わる）" example,
    /// 03-refinement-batch.md §4.2).
    ///
    /// Both `contextSegments` and `batchSegments` are sorted `startMs` ascending internally, so
    /// callers do not need to pre-sort them (the queue's in-memory history/pending buffer order is
    /// not guaranteed to match timeline order across the two independent mic/system streams --
    /// kikimi.md 6 章 "`id` は投入順に採番されるので、時系列とはズレる可能性がある").
    ///
    /// - Parameters:
    ///   - contextSegments: The "直前の文脈" segments (typically the last `context_segments`
    ///     entries before the batch). Refined text is preferred over raw when present. Segments
    ///     whose `refinedText` is an empty string were judged meaningless (filler-only) and
    ///     dropped by refinement, so they are omitted from the context block entirely.
    ///   - batchSegments: The segments being refined in this call ("今回整形する対象").
    static func buildUserPrompt(
        contextSegments: [RefinementContextSegment],
        batchSegments: [TranscriptSegment]
    ) -> String {
        let sortedContext = contextSegments
            .filter { $0.refinedText?.isEmpty != true }
            .sorted { $0.segment.startMs < $1.segment.startMs }
        let sortedBatch = batchSegments.sorted { $0.startMs < $1.startMs }

        let contextBlock = sortedContext
            .map { formatLine(id: $0.segment.id, speaker: $0.segment.speaker, text: $0.refinedText ?? $0.segment.text) }
            .joined(separator: "\n")
        let batchBlock = sortedBatch
            .map { formatLine(id: $0.id, speaker: $0.speaker, text: $0.text) }
            .joined(separator: "\n")

        return """
        【直前の文脈（整形済み）】
        \(contextBlock)

        【今回整形する対象】
        \(batchBlock)
        """
    }

    /// `seg_00042 (mic): text` (kikimi.md 7 章).
    private static func formatLine(id: String, speaker: AudioSourceKind, text: String) -> String {
        "\(id) (\(speaker.rawValue)): \(text)"
    }

    /// Truncates `string` to at most `limit` UTF-8 bytes, without splitting a multi-byte UTF-8
    /// sequence (dropping trailing bytes one at a time until the result decodes cleanly). Returns
    /// the original string unchanged with `wasClamped == false` when it already fits.
    static func clampToByteLimit(_ string: String, limit: Int) -> (String, Bool) {
        guard string.utf8.count > limit else { return (string, false) }

        var bytes = Array(string.utf8.prefix(limit))
        while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
            bytes.removeLast()
        }
        return (String(bytes: bytes, encoding: .utf8) ?? "", true)
    }
}
