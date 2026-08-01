import Foundation
import Mustache
import OSLog

// MARK: - SummaryRenderer

/// Renders a `SummaryState` to Markdown via a Mustache view template (kikimi.md 5/8 章,
/// `docs/design/04-summary-updater.md` §5). Shared core for both the Summary tab (`summary.md`) and
/// (in a future phase) Watcher output, per 04-summary-updater.md §5's "サマリと Watcher の両方で使う
/// 中核" note.
///
/// - Frontmatter is deliberately **not** emitted here: kikimi.md 8 章 states the Wiki export's
///   frontmatter is authoritative, so `summary.md` itself must stay frontmatter-free (11 章).
/// - Uses GRMustache.swift (product name `Mustache`), confirmed usable under Swift 6 strict
///   concurrency (04-summary-updater.md §5's timeboxed check). GRMustache does not implement the
///   spec-extension `{{^-last}}` "last element" inverted-section key kikimi.md 8 章's prose uses, so
///   the default template below instead derives an explicit `is_last` boolean per participant (see
///   `renderableParticipants(_:)`) -- the *rendered Markdown* still matches kikimi.md 8 章's
///   "読点区切り、末尾以外" shape, only the template's internal notation differs
///   (04-summary-updater.md §5: "既定 template をそのライブラリの記法に合わせて調整して構わない").
enum SummaryRenderer {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SummaryRenderer")

    /// Built-in default view template (kikimi.md 8 章), adapted to GRMustache's notation. Used when
    /// a session's `summary_template.md` is missing or fails to parse
    /// (04-summary-updater.md §5 / kikimi.md 8 章「テンプレート読み込み規則」).
    static let defaultTemplate = """
    # {{title}}

    ## 概要

    {{overview}}

    **参加者:** {{#participants}}{{name}}{{^is_last}}、{{/is_last}}{{/participants}}

    ## 決定事項

    {{#decisions}}- {{text}}
    {{/decisions}}

    ## アクションアイテム

    | タスク | 担当 | 期限 |
    |--------|------|------|
    {{#action_items}}| {{task}} | {{assignee}} | {{#due}}{{due}}{{/due}}{{^due}}—{{/due}} |
    {{/action_items}}

    ## 議事詳細

    {{#topics}}### {{heading}}

    {{body}}

    {{/topics}}
    """

    /// Prepended (with no intervening newline, so it emits no output of its own -- see
    /// `render(_:usingTemplateSource:)`) to every template source, built-in or user-provided, before
    /// parsing (04-summary-updater.md §5 / this module's design doc §4.2 "HTML エスケープ対策"). GRMustache's
    /// default `contentType` is `.html`, which escapes `& < >` etc.; `overview`/topic `body` are
    /// free-form Markdown (blockquotes, ampersands, ...) that must pass through unescaped. There is no
    /// settable `Template.contentType` API and `Mustache.DefaultConfiguration` is deliberately avoided
    /// (global mutable state under Swift 6 strict concurrency), so a `{{% CONTENT_TYPE:TEXT }}` pragma
    /// tag is the mechanism instead.
    private static let textModeContentTypePragma = "{{% CONTENT_TYPE:TEXT }}"

    /// Renders `state` using `templateString` (a session's `summary_template.md` contents), falling
    /// back to `defaultTemplate` if `templateString` is `nil`/empty, or if it fails to parse/render
    /// (04-summary-updater.md §9 "Mustache レンダリング失敗（template 破損）→ 内蔵デフォルト template
    /// で再試行").
    ///
    /// - Returns: The rendered Markdown, or `nil` if even the default template fails to render (the
    ///   caller is expected to keep the previous `summary.md` on-disk in that case, per §9's "なお
    ///   失敗なら前回 summary.md を保持し warn" -- this function has no access to that previous
    ///   content, so it only signals failure via `nil`).
    static func render(_ state: SummaryState, templateString: String?) -> String? {
        let trimmedTemplate = templateString?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTemplate, !trimmedTemplate.isEmpty {
            if let rendered = render(state, usingTemplateSource: trimmedTemplate) {
                return rendered
            }
            logger.warning("session summary_template.md failed to render, falling back to the built-in default template")
        }
        if let rendered = render(state, usingTemplateSource: defaultTemplate) {
            return rendered
        }
        logger.error("built-in default summary template failed to render; no summary.md output produced")
        return nil
    }

    private static func render(_ state: SummaryState, usingTemplateSource templateSource: String) -> String? {
        do {
            // No newline between the pragma and `templateSource`: the pragma tag renders to nothing,
            // but GRMustache.swift does not fold standalone lines, so a newline here would leak a
            // leading blank line into the rendered output (see `textModeContentTypePragma`'s doc).
            let template = try Template(string: textModeContentTypePragma + templateSource)
            return try template.render(renderingContext(for: state))
        } catch {
            logger.warning("Mustache render failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Mustache context construction

    /// Converts `SummaryState` into the `[String: Any]`-shaped box Mustache consumes, injecting the
    /// derived values (`is_last`, due-present-ness via plain optionality) the default template needs
    /// (04-summary-updater.md §5). Only schema fields are exposed (kikimi.md 8 章: "template が参照
    /// できる変数は schema で定義された field のみ") -- `lastSummarizedStartMs` is never included.
    private static func renderingContext(for state: SummaryState) -> [String: Any] {
        [
            "title": state.title ?? "",
            "overview": state.overview,
            "participants": renderableParticipants(state.participants),
            "decisions": state.decisions.map { decision in
                ["text": decision.text] as [String: Any]
            },
            "action_items": state.actionItems.map(renderableActionItem),
            // `id`/`source_seg_ids` are intentionally omitted -- internal bookkeeping keys, not a view
            // concern (this module's design doc §4.2).
            "topics": state.topics.map { topic in
                ["heading": topic.heading, "body": topic.body] as [String: Any]
            }
        ]
    }

    /// Each participant paired with `is_last`, so `{{^is_last}}、{{/is_last}}` reproduces kikimi.md
    /// 8 章's "、" separator with no trailing separator after the final name.
    private static func renderableParticipants(_ participants: [String]) -> [[String: Any]] {
        participants.enumerated().map { index, name in
            ["name": name, "is_last": index == participants.count - 1]
        }
    }

    /// `due` is passed through as an `Any?`-boxed optional: GRMustache treats `nil` as an empty
    /// (falsy) box (see GRMustache.swift's `Box(_:)`), so `{{#due}}...{{/due}}` /
    /// `{{^due}}...{{/due}}` behave exactly like presence/absence without any extra derived flag.
    private static func renderableActionItem(_ item: SummaryState.ActionItem) -> [String: Any?] {
        [
            "task": item.task,
            "assignee": item.assignee,
            "due": item.due
        ]
    }
}
