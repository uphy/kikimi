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
    /// Fixed instructions preceding the term list. Forwards to
    /// `PromptSpec.spec(for: .glossaryHeader).defaultBody` -- `Kikimi/Prompts/PromptSpec.swift` is
    /// this text's single source of truth (same forwarding shape as
    /// `SimpleWatcherSpec.defaultSystemPromptTemplate`), so the `based_on` staleness hash and this
    /// render-time default can never drift apart. The wording's field-tuning history (why
    /// substitution-rule framing, why `A → B` arrows over colons) lives with the text there.
    static var defaultHeader: String {
        PromptSpec.spec(for: .glossaryHeader).defaultBody
    }

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
    ///   - header: the fixed instructions preceding the term list (`docs/design/42-prompt-overrides.md`
    ///     §2.2 "glossary-header" -- the only 方針層 slice of this renderer; term bullets and category
    ///     headings below stay code-owned and unconditional). Defaults to `defaultHeader`. Callers pass
    ///     a `PromptStore`-resolved override here instead of reading `defaultHeader` themselves, so a
    ///     caller that never overrides it (and every test that predates overrides) is unaffected.
    /// - Returns: `nil` when there is nothing left to render, so the caller can omit the block
    ///   entirely rather than injecting a header with no terms under it.
    static func render(entries: [GlossaryEntry], categories: [GlossaryCategory] = [], header: String = defaultHeader) -> String? {
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
