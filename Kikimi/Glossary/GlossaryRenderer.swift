import Foundation

// MARK: - GlossaryRenderer

/// Renders the top-level `glossary` config section (`docs/design/28-glossary.md` §2, formerly
/// `dictation.context.glossary` per `docs/design/25-dictation-mode.md` §15/R19) into the Markdown
/// block both refinement call sites inject into their system prompts:
/// `DictationContextResolver.resolve(bundleID:config:glossary:)` (dictation) and
/// `RefinementPromptBuilder.buildSystemPrompt(context:glossaryBlock:dedupSystemLeakSegments:)` (meeting
/// transcript refinement). Kept separate from `GlossaryEntry` itself (schema) so the prompt text can
/// be improved independently of the config shape -- the same schema+view separation Kikimi already
/// uses for Watchers/summary. Living outside both `Kikimi/Dictation/` and `Kikimi/Refinement/` reflects
/// that neither feature owns this type -- it is shared, feature-independent rendering logic.
enum GlossaryRenderer {
    /// Fixed instructions preceding the term list.
    ///
    /// Deliberately framed as a **substitution rule**, not as mis-transcription repair. The earlier
    /// wording ("音声認識でよく誤変換される〜。文中に読みが似た誤変換が含まれている場合は置換してください")
    /// only ever fired on readings that were obviously broken Japanese: 「デブ環境」→「dev環境」 worked,
    /// but 「ステージング環境」→「stg環境」 never did, because the LLM correctly judged「ステージング環境」
    /// to be a faithful transcription and therefore not a 誤変換 to repair (2026-07 実戦フィードバック).
    /// Notation normalization and mis-transcription repair are the same operation from the model's
    /// side -- "if you see A, write B" -- so the rule now says exactly that, and explicitly covers the
    /// correctly-transcribed case.
    ///
    /// The bare-term case (`reading` empty) also gets an explicit line. It previously had none: its
    /// meaning ("this is a real proper noun, do not 'correct' it into a commoner word") lived only in
    /// `GlossaryEntry`'s doc comment, i.e. nowhere the LLM could read it.
    ///
    /// Bullets render as `A → B` (arrow), not the original `A: B` (colon): with a colon, small
    /// models fall back on the dictionary prior "headword: gloss" and emit the *left* side --
    /// 「根建さん」 came out as 「こんけんさん」 (the reading) instead of 「konkenさん」, and before
    /// that as 「ねこかく」, a *different* entry's reading force-matched onto a then-unlisted name
    /// (2026-07-10 実戦フィードバック, gpt-5.4-nano). The arrow matches the header's own examples,
    /// the direction is restated outright ("必ず「→」の右側"), and force-matching unlisted words
    /// onto some nearby entry is explicitly forbidden.
    ///
    /// The final clause still lets the LLM decline a replacement the surrounding context clearly
    /// doesn't call for -- a glossary hit is a strong hint, not an unconditional find-and-replace.
    static let header = """
    # Glossary

    以下は、この書き起こしに登場する固有名詞・専門用語の一覧です。

    - 「A → B」形式の行は、文中に A（またはそれに近い表記・誤変換）が現れたら B に置換してください。A が正しく書き起こされていても、B の表記に統一してください。
      (例:「猫助」→「nekosuke」、「デブ環境」→「dev環境」、「ステージング環境」→「stg環境」)
    - 「A1, A2 → B」のようにカンマ区切りで複数並ぶ行は、そのいずれの表記が現れても B に置換してください。
    - 置換結果として出力してよいのは、必ず「→」の右側の表記です。左側（読み・誤変換の側）を出力に使わないでください。
    - 用語のみの行は、実在の固有名詞です。別の一般語に「訂正」しないでください。
    - どの行の A とも読みが明確に一致しない語は、そのまま残してください。一覧のどれかへ無理に寄せてはいけません。
    - ただし、文脈上明らかに無関係な語だと分かる場合は、無理に置換しないでください。
    """

    /// - Parameters:
    ///   - entries: the `glossary` config section. Entries whose `term` is blank (after trimming) are
    ///     skipped -- e.g. a freshly-added, not-yet-filled-in Settings row.
    ///   - categories: `glossary_categories`, in the order their sections should render. Uncategorized
    ///     entries (including any whose `category` names a category that no longer exists -- see
    ///     `GlossaryCategorization`) render first, bare, directly under the header; each non-empty
    ///     category then follows as `## {name}`, its optional `instruction`, and its bullets. A
    ///     category with no renderable entries emits nothing at all, heading included.
    ///
    ///     Defaults to `[]`, which renders exactly the pre-categories flat list -- so a caller that
    ///     has no categories (and every test that predates them) is unaffected.
    /// - Returns: `nil` when there is nothing left to render, so the caller can omit the block
    ///   entirely rather than injecting a header with no terms under it.
    static func render(entries: [GlossaryEntry], categories: [GlossaryCategory] = []) -> String? {
        var blocks: [String] = []

        let uncategorized = GlossaryCategorization
            .uncategorizedIndices(entries: entries, categories: categories)
            .compactMap { bullet(for: entries[$0]) }
        if !uncategorized.isEmpty {
            blocks.append(uncategorized.joined(separator: "\n"))
        }

        for category in categories {
            let bullets = GlossaryCategorization
                .indices(entries: entries, in: category.id)
                .compactMap { bullet(for: entries[$0]) }
            guard !bullets.isEmpty else { continue }

            let instruction = category.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = ["## \(category.name)"] + (instruction.isEmpty ? [] : [instruction]) + bullets
            blocks.append(lines.joined(separator: "\n"))
        }

        guard !blocks.isEmpty else { return nil }
        return "\(header)\n\n\(blocks.joined(separator: "\n\n"))"
    }

    /// `- reading → term`, or `- term` when there is nothing to replace. `nil` for a blank term.
    private static func bullet(for entry: GlossaryEntry) -> String? {
        let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        let reading = entry.reading.trimmingCharacters(in: .whitespacesAndNewlines)
        return reading.isEmpty ? "- \(term)" : "- \(reading) → \(term)"
    }
}
