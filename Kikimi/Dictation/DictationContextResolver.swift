import Foundation

// MARK: - DictationContextResolver

/// Pure resolution logic for dictation's injected context (`docs/design/25-dictation-mode.md`
/// §14.3/R15, resignatured by `docs/design/42-prompt-overrides.md` §4.2/§7.2), mirroring
/// `FrontmostGuard.decide`'s pure-function style: takes every input the real caller has and returns
/// what to inject, so it is unit-testable without a real `PromptStore`/`capturedTarget`.
///
/// This type no longer knows about `DictationContextConfig`/bundle-id matching at all -- both
/// already-resolved bodies (which override file, if any, is active) and the bundle-id match itself
/// are the caller's job now (`DictationController` via `PromptStore.dictationAppBundleIDs()`, §7.2).
/// That split keeps this resolver a pure string-combining function while the "is there an override
/// for this bundle id" lookup, which needs `PromptStore` state, stays out of it.
enum DictationContextResolver {
    /// Prepended to the app-specific portion (added after a real-world report: without this label, an
    /// app context asking for a tone/style change -- e.g. "笑えるほどカジュアルに" -- read to the LLM
    /// as a weak trailing addendum after `globalBody`'s conservative rewrite-scope constraint, and the
    /// LLM kept following the conservative global rule instead. Labeling the block as app-specific and
    /// explicitly higher-priority for tone/wording fixes this without having to touch `globalBody`'s
    /// content itself (the resolver has no idea what it says).
    static let appContextHeader = "【このアプリ向けの追加指示(トーン・言い回しはこちらを優先)】"

    /// Combines the global policy body, the shared glossary block, and the app-specific policy body
    /// (already resolved by the caller for whichever bundle id matched, or `nil` if none did). Both
    /// `globalBody` and `appBody` are trimmed before being considered; an empty (after trimming)
    /// piece contributes nothing -- this is what keeps R17's "empty override = inject no context"
    /// escape hatch working after the `prompts/` migration (`docs/design/42-prompt-overrides.md`
    /// §3.2: an empty `prompts/dictation.md` override resolves to an empty `globalBody` here, which
    /// trims away and falls straight through to the `sections.isEmpty` `nil` return below --
    /// `DictationRefiner.buildSystemPrompt(resolvedContext: nil)`'s pass-through path is unchanged).
    /// Returns `nil` when nothing is left to inject, so the caller can skip adding a "事前知識" block
    /// to the system prompt entirely rather than injecting an empty one.
    ///
    /// - Parameters:
    ///   - globalBody: The resolved `dictation` prompt policy body -- `PromptStore.policyBody(for:
    ///     .builtin(.dictation))`, i.e. the active `prompts/dictation.md` override or the built-in
    ///     default when there is none.
    ///   - appBody: The resolved per-app policy body for whichever bundle id the caller already
    ///     matched (`PromptStore.dictationAppBundleIDs()`'s exact-match lookup, R14, done by the
    ///     caller -- this type has no bundle-id concept at all), or `nil` when no app matched (no
    ///     frontmost-app capture, or no registered override for that bundle id).
    ///   - glossary: the top-level `glossary` config section (`docs/design/28-glossary.md` §2) --
    ///     callers resolve this themselves (`DictationController` passes
    ///     `AppConfig.shared.data.glossary`) rather than this type reaching out for it.
    ///   - glossaryCategories: the top-level `glossary_categories` section, passed straight through to
    ///     `GlossaryRenderer.render(entries:categories:header:)`. Defaults to `[]` (flat rendering).
    ///   - glossaryHeader: the resolved `glossary-header` prompt policy body
    ///     (`PromptStore.policyBody(for: .builtin(.glossaryHeader))`), passed straight through to
    ///     `GlossaryRenderer.render`. Defaults to `GlossaryRenderer.defaultHeader`, so a caller that
    ///     never overrides it (and every test that predates overrides) is unaffected.
    static func resolve(
        globalBody: String,
        appBody: String?,
        glossary: [GlossaryEntry] = [],
        glossaryCategories: [GlossaryCategory] = [],
        glossaryHeader: String = GlossaryRenderer.defaultHeader
    ) -> String? {
        var sections: [String] = []

        let trimmedGlobal = globalBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGlobal.isEmpty {
            sections.append(trimmedGlobal)
        }

        if let glossaryBlock = GlossaryRenderer.render(entries: glossary, categories: glossaryCategories, header: glossaryHeader) {
            sections.append(glossaryBlock)
        }

        if let appBody {
            let trimmedAppBody = appBody.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedAppBody.isEmpty {
                sections.append("\(appContextHeader)\n\(trimmedAppBody)")
            }
        }

        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }
}
