import Foundation

// MARK: - ModelMenuItems

/// The manual-override menu's candidate list (`docs/design/44-llm-model-config.md` §8), shared by the
/// three call sites that need it: the Summary tab's "サマリ全文再生成" button, the Ended-only "最終整形を
/// 再実行" button, and the チャット tab's small model picker.
///
/// Deliberately just the candidate *list* -- click-time resolution against live config +
/// `LLMClient.shared.availableProviders` is `ModelResolver.resolve(candidates:config:availableProviders:)`
/// itself (called with the one selected alias as `candidates`), which already implements exactly the
/// "unresolvable alias/provider → warning + fallthrough, execution never stops" contract §8 asks for
/// (§3.2). No separate resolution helper belongs here.
enum ModelMenuItems {
    /// One entry in the manual-override menu, in display order. No "モデルを指定して実行…" custom-entry
    /// case anymore (§8's revised list, `docs/design/44-llm-model-config.md` §2.1's "予約名は設けない":
    /// direct model-id entry has been removed from every manual-override menu -- every `llm.models`
    /// alias is equally selectable instead).
    enum Candidate: Equatable, Sendable {
        /// Run with no override at all -- the feature's own session-start-snapshotted assignment
        /// (`modelOverride: nil` at every call site this menu feeds).
        case useDefault
        /// Run with this `llm.models` alias name (`config.models` key), resolved at click time.
        case alias(String)
    }

    /// `既定` + every `llm.models` alias, name-sorted (§2.1's "予約名は設けない" -- no more fixed
    /// `auto`/`premium` lead; every definition is ordered the same way).
    static func build(config: LLMConfig) -> [Candidate] {
        [.useDefault] + aliasNames(config: config).map { .alias($0) }
    }

    /// Just the alias-name ordering `build(config:)` inserts after `useDefault`, split out so a test
    /// can assert the ordering rule directly without unwrapping every `Candidate` case.
    ///
    /// Definitions whose model name is still empty (a Settings row added but not yet filled in) are
    /// excluded: `ModelResolver` skips them with a warning anyway (§3.1 rule 1's empty-model guard),
    /// so offering them as menu entries would only produce a pick that silently runs the default.
    static func aliasNames(config: LLMConfig) -> [String] {
        config.models.filter { !$0.value.model.isEmpty }.keys.sorted()
    }
}
