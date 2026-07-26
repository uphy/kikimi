import Foundation

// MARK: - DictationContextResolver

/// Pure resolution logic for `dictation.context` (`docs/design/25-dictation-mode.md` §14.3/R15),
/// mirroring `FrontmostGuard.decide`'s pure-function style: takes every input the real caller has
/// and returns what to inject, so it is unit-testable without a real `AppConfig`/`capturedTarget`.
enum DictationContextResolver {
    /// Prepended to the app-specific portion (added after a real-world report: without this label, an
    /// app context asking for a tone/style change -- e.g. "笑えるほどカジュアルに" -- read to the LLM
    /// as a weak trailing addendum after `global`'s conservative rewrite-scope constraint (at the time,
    /// "意味を変えない範囲での軽微な言い換えは可"; see `DictationContextConfig.default.global`'s current
    /// wording), and the LLM kept following the conservative global rule instead. Labeling the block
    /// as app-specific and explicitly higher-priority for tone/wording fixes this without having to
    /// touch `global`'s content itself (the resolver has no idea what `global` says).
    static let appContextHeader = "【このアプリ向けの追加指示(トーン・言い回しはこちらを優先)】"

    /// Combines the global context, the shared glossary block, and the app-specific context that
    /// matches `bundleID` (exact match only, R14 -- first entry wins if the config somehow has
    /// duplicates). Both `global` and the app context are trimmed before being considered; an empty
    /// (after trimming) piece contributes nothing. Returns `nil` when nothing is left to inject, so
    /// the caller can skip adding a "事前知識" block to the system prompt entirely rather than
    /// injecting an empty one.
    ///
    /// - Parameters:
    ///   - bundleID: The `keyDown`-time frontmost app's bundle identifier (R13), or `nil` when it
    ///     could not be captured.
    ///   - config: `dictation.context` from `AppConfig`.
    ///   - glossary: the top-level `glossary` config section (`docs/design/28-glossary.md` §2,
    ///     formerly `config.glossary` before the glossary was promoted out of `DictationContextConfig`
    ///     into a section shared with meeting-transcript refinement) -- callers resolve this
    ///     themselves (`DictationController` passes `AppConfig.shared.data.glossary`) rather than this
    ///     type reaching into `config` for it.
    ///   - glossaryCategories: the top-level `glossary_categories` section, passed straight through to
    ///     `GlossaryRenderer.render(entries:categories:)`. Defaults to `[]` (flat rendering).
    static func resolve(
        bundleID: String?,
        config: DictationContextConfig,
        glossary: [GlossaryEntry] = [],
        glossaryCategories: [GlossaryCategory] = []
    ) -> String? {
        var sections: [String] = []

        let global = config.global.trimmingCharacters(in: .whitespacesAndNewlines)
        if !global.isEmpty {
            sections.append(global)
        }

        if let glossaryBlock = GlossaryRenderer.render(entries: glossary, categories: glossaryCategories) {
            sections.append(glossaryBlock)
        }

        if let bundleID, let match = config.apps.first(where: { $0.bundleID == bundleID }) {
            let appContext = match.context.trimmingCharacters(in: .whitespacesAndNewlines)
            if !appContext.isEmpty {
                sections.append("\(appContextHeader)\n\(appContext)")
            }
        }

        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }
}
