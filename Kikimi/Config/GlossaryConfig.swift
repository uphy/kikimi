import Foundation

// MARK: - GlossaryEntry

/// A single `glossary[]` entry (`docs/design/28-glossary.md` §2, formerly `dictation.context.glossary`
/// per `docs/design/25-dictation-mode.md` §15/R19 before the glossary was promoted to a top-level,
/// feature-independent `config.yaml` section shared by both dictation refinement
/// (`DictationContextResolver.resolve(bundleID:config:glossary:)`) and meeting-transcript refinement
/// (`RefinementPromptBuilder.buildSystemPrompt(context:glossaryBlock:dedupSystemLeakSegments:)`): the
/// notation the LLM should write, plus an optional `reading` -- the notation it should replace.
///
/// `reading` covers both a mis-transcription STT commonly produces (`term: "nekosuke", reading:
/// "ねこすけ"`) and a perfectly faithful transcription the user simply wants normalized (`term:
/// "stg環境", reading: "ステージング環境"`). These are the same operation to the model -- "see A, write
/// B" -- so they share one field and one rule; see `GlossaryRenderer.header`'s doc comment for why
/// splitting them into a 種別 field would have been the wrong axis.
///
/// `reading` empty means there is nothing to replace: the term is listed bare, purely so the LLM
/// recognizes it as a real proper noun rather than "correcting" it into something more common.
///
/// One term with several source notations is a single entry with a comma-separated `reading`
/// (`term: "yamada", reading: "山田, やまだ"`), not one entry per notation -- the rendered
/// prompt spends one bullet (and one repetition of the term) instead of N, and
/// `GlossaryRenderer.header` tells the LLM how to read the commas.
struct GlossaryEntry: Codable, Equatable, Sendable {
    var term: String
    var reading: String
    /// References a `GlossaryCategory.id`. `nil` -- the default, and what every pre-categories
    /// `config.yaml` decodes to -- means "uncategorized".
    ///
    /// An id that matches no `glossary_categories[].id` (a category deleted out from under a
    /// hand-edited `config.yaml`) is deliberately **not** repaired at decode time: it is preserved
    /// verbatim here and degrades to uncategorized where it is consumed, via
    /// `GlossaryCategorization`. That keeps exactly one implementation of "what counts as
    /// uncategorized", shared by `GlossaryRenderer` and the Settings UI, instead of one repair rule at
    /// decode and another at render. Read this field through `GlossaryCategorization` rather than
    /// comparing it directly.
    var category: String?

    enum CodingKeys: String, CodingKey {
        case term
        case reading
        case category
    }

    /// `category` defaults so every pre-categories call site -- `GlossaryEntry(term:reading:)`, of
    /// which there are dozens across the tests -- keeps compiling unchanged.
    init(term: String, reading: String, category: String? = nil) {
        self.term = term
        self.reading = reading
        self.category = category
    }
}

// MARK: - GlossaryCategory

/// One `glossary_categories[]` entry (`docs/design/28-glossary.md` §1.2): a user-defined grouping of
/// glossary terms that carries its own prompt instruction.
///
/// **`id` and `name` are split so a category can be renamed freely.** `id` is app-generated (a UUID
/// string, minted only when the user presses `[+]` in Settings) and is what `GlossaryEntry.category`
/// references; `name` is a pure display label, shown in Settings and rendered as the `## {name}`
/// heading. Deriving `id` from `name` would make every rename orphan its own entries.
///
/// `instruction` is optional extra prompt text rendered under the heading, before the term list --
/// e.g. 「以下は人物名です。敬称（さん・様）は原文のまま残してください。」. This is the axis categories
/// exist on: a *domain hint*, not a replacement mode. Whether a given entry is a mis-transcription fix
/// or a notation normalization is settled once, for all entries, by `GlossaryRenderer.header`.
struct GlossaryCategory: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var instruction: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case instruction
    }

    init(id: String, name: String, instruction: String = "") {
        self.id = id
        self.name = name
        self.instruction = instruction
    }

    /// `id`/`name` are required: Settings always mints a UUID `id` and seeds a non-empty `name`, so a
    /// category missing either can only come from a hand-edited `config.yaml`. Throwing here fails the
    /// **whole** `glossary_categories:` array (caught in `KikimiConfigData.init(from:)`), matching
    /// `GlossaryEntry`'s existing "one malformed entry -> empty list + warning" convention.
    /// `instruction` is optional and defaults to empty.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        instruction = try container.decodeIfPresent(String.self, forKey: .instruction) ?? ""
    }
}
