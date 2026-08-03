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
    /// The result is split into the Summary tab's two panes where the template allows it
    /// (`docs/design/47-summary-split-pane.md` §3). A template that cannot be split comes back as a
    /// `SummaryMarkdown` with `topics == nil`, i.e. the whole document in `top` -- **not** as a
    /// failure. `nil` still means only one thing: rendering itself failed, so the fallback chain here
    /// keeps its original one-to-one shape.
    ///
    /// - Returns: The rendered Markdown, or `nil` if even the default template fails to render (the
    ///   caller is expected to keep the previous `summary.md` on-disk in that case, per §9's "なお
    ///   失敗なら前回 summary.md を保持し warn" -- this function has no access to that previous
    ///   content, so it only signals failure via `nil`).
    static func render(_ state: SummaryState, templateString: String?) -> SummaryMarkdown? {
        let trimmedTemplate = templateString?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTemplate, !trimmedTemplate.isEmpty {
            if let rendered = renderSplit(state, usingTemplateSource: trimmedTemplate) {
                return rendered
            }
            logger.warning("session summary_template.md failed to render, falling back to the built-in default template")
        }
        if let rendered = renderSplit(state, usingTemplateSource: defaultTemplate) {
            return rendered
        }
        logger.error("built-in default summary template failed to render; no summary.md output produced")
        return nil
    }

    /// Renders `templateSource` and splits the result in two, or renders it as a single pane.
    ///
    /// Both halves always come from **the same** template source (design 47 §3.3): resolving the
    /// session-template-then-default fallback in `render(_:templateString:)` *before* getting here is
    /// what stops `joined` and the on-disk `summary.md` from ending up with different origins.
    ///
    /// The split is only kept if the two halves concatenate back to the unsplit render. Mustache
    /// sections hold no state across each other, so cutting the source in two and rendering the
    /// halves separately *should* equal one whole render -- but a boundary that lands inside an
    /// enclosing section (`{{#foo}}## 議事詳細 {{#topics}}…{{/topics}}{{/foo}}`) breaks that. Rather
    /// than enumerate the ways a custom template can defeat the cut, this checks the equality that
    /// actually matters and drops the split when it does not hold.
    private static func renderSplit(_ state: SummaryState, usingTemplateSource templateSource: String) -> SummaryMarkdown? {
        guard let whole = render(state, usingTemplateSource: templateSource) else { return nil }
        guard let (topSource, topicsSource) = splitTemplate(templateSource),
              let top = render(state, usingTemplateSource: topSource),
              let topics = render(state, usingTemplateSource: topicsSource),
              // A boundary at offset 0 renders an empty top pane, and `"" + whole == whole` sails
              // straight through the concatenation check below (design 47 §3.2). Half the Summary tab
              // would be blank, which is worse than not splitting at all.
              !top.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              top + topics == whole
        else {
            logger.debug("summary template could not be split; falling back to the single-pane layout")
            return SummaryMarkdown(top: whole, topics: nil)
        }
        return SummaryMarkdown(top: top, topics: topics)
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

    // MARK: - Template splitting

    /// Cuts `source` at the heading line that introduces its `topics` section
    /// (`docs/design/47-summary-split-pane.md` §3.2), or returns `nil` if there is nothing to cut on.
    ///
    /// Deliberately structural rather than a "did the user customize the template?" check: every
    /// session gets a `summary_template.md` written at creation time (`SessionStore+Defaults
    /// .loadInitialSummaryTemplate`, kikimi.md 626 行), so presence- or equality-based detection would
    /// classify practically everything as customized and never split at all (§3.1).
    private static func splitTemplate(_ source: String) -> (top: String, topics: String)? {
        guard let sectionStart = topicsSectionStart(in: source) else { return nil }
        let boundary = headingLineStart(in: source, before: sectionStart) ?? lineStart(in: source, of: sectionStart)
        let top = String(source[source.startIndex..<boundary])
        // Checked again after rendering (`renderSplit`), but catching it here avoids two pointless
        // Mustache passes for the common `{{#topics}}`-at-the-very-top case.
        guard !top.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (top, String(source[boundary...]))
    }

    /// The earliest `{{#topics}}` / `{{^topics}}` in `source`. `{{^topics}}` counts because a template
    /// may lead with an "まだありません" empty-state block, and that block belongs to the 議事詳細 half.
    private static func topicsSectionStart(in source: String) -> String.Index? {
        ["{{#topics}}", "{{^topics}}"]
            .compactMap { source.range(of: $0)?.lowerBound }
            .min()
    }

    /// Start of the nearest `##`-or-deeper heading line before `position`.
    ///
    /// A lone `# ` line is not a candidate: in a template whose only heading above the topics section
    /// is `# {{title}}`, cutting there leaves the top half empty (§3.2). Falling through to `nil` --
    /// and thus to the `{{#topics}}` line itself as the boundary -- keeps the title in the top pane.
    private static func headingLineStart(in source: String, before position: String.Index) -> String.Index? {
        var result: String.Index?
        var index = source.startIndex
        while index < position {
            if source[index...].hasPrefix("##") { result = index }
            guard let newline = source[index...].firstIndex(of: "\n") else { break }
            index = source.index(after: newline)
        }
        return result
    }

    /// Start of the line containing `position`.
    private static func lineStart(in source: String, of position: String.Index) -> String.Index {
        var result = source.startIndex
        var index = source.startIndex
        while index < position {
            if source[index] == "\n" { result = source.index(after: index) }
            index = source.index(after: index)
        }
        return result
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
