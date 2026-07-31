import Foundation

// MARK: - WatcherSegmentInput

/// One segment's worth of information `WatcherPromptBuilder.recentSegmentsText(_:)` needs to render
/// a `seg_XXXXX (mic): text` line (`docs/design/05-watcher-runner.md` §6, mirrors `SummarySegmentInput`).
/// Callers (`WatcherRunner`) resolve the refined-over-raw fallback and empty-refined-text exclusion
/// before constructing these, same as `SummaryUpdater` does for `SummarySegmentInput`.
struct WatcherSegmentInput: Sendable, Equatable {
    var id: String
    var startMs: Int
    var speaker: AudioSourceKind
    var text: String
}

// MARK: - WatcherPromptBuilder

/// Builds a Watcher's per-run user prompt by expanding the `{{state}}`/`{{summary}}`/
/// `{{recent_segments}}` placeholders in its `# User` section template
/// (`docs/design/05-watcher-runner.md` §6). Pure by construction: no file I/O, no `Date()` --
/// `WatcherRunner` resolves state/summary/segment content and passes it in explicitly.
enum WatcherPromptBuilder {
    /// The three recognized placeholder tokens, in the fixed order §6's table lists them. Any other
    /// `{{...}}`-shaped text in a Watcher's `# User` section is left untouched (not Mustache -- §6:
    /// "単純文字列置換する（Mustache は使わない）").
    private static let stateToken = "{{state}}"
    private static let summaryToken = "{{summary}}"
    private static let recentSegmentsToken = "{{recent_segments}}"

    /// `{{state}}`'s substitution text (§7's table + §6's "state 未初期化... は `{}`"):
    /// - `snapshot`: always empty (state is rebuilt from scratch every run).
    /// - `cumulative`/`append_only`: the current state's pretty-printed JSON, or `"{}"` if there is
    ///   no state yet (no `watchers/<id>.state.json` on disk and no `initial_state`).
    static func stateText(for state: JSONValue?, stateMode: WatcherStateMode) -> String {
        switch stateMode {
        case .snapshot:
            return ""
        case .cumulative, .appendOnly:
            return (state ?? .object([])).serialize(pretty: true)
        }
    }

    /// `{{recent_segments}}`'s substitution text: `segments` formatted one per line via the same
    /// `seg_XXXXX (mic): text` format `SummaryPromptBuilder` uses (§6: "セグメント行の整形は
    /// SummaryPromptBuilder の既存フォーマットを共通ヘルパに切り出して共用する"). `WatcherRunner` is
    /// responsible for resolving which segments belong here per `input_scope` (§6's table) --
    /// this function only formats whatever list it is given (an empty list for `input_scope: summary`
    /// yields an empty string).
    static func recentSegmentsText(_ segments: [WatcherSegmentInput]) -> String {
        segments
            .map { SummaryPromptBuilder.formatLine(id: $0.id, speaker: $0.speaker, text: $0.text) }
            .joined(separator: "\n")
    }

    /// Expands `{{state}}`/`{{summary}}`/`{{recent_segments}}` in `template` (a Watcher's `# User`
    /// section) in a single left-to-right pass over the *original* template text (§6: "置換は 1 パス
    /// で行う"). Deliberately not three sequential `replacingOccurrences(of:with:)` calls: the state
    /// JSON substituted for `{{state}}` could -- in principle -- itself contain the literal text
    /// `"{{summary}}"` (e.g. if a Watcher's state happens to store that string), and a sequential
    /// replace would then wrongly re-expand it. Delegates to `PromptPlaceholder.expand`, the shared
    /// single-pass helper (`docs/design/42-prompt-overrides.md` §4.1) that implements this same
    /// scan-once-and-copy-through logic.
    static func buildUserPrompt(template: String, stateText: String, summaryMarkdown: String, recentSegmentsText: String) -> String {
        PromptPlaceholder.expand(template: template, replacements: [
            (stateToken, stateText),
            (summaryToken, summaryMarkdown),
            (recentSegmentsToken, recentSegmentsText)
        ])
    }
}
