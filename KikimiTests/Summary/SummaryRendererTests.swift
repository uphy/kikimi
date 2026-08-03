import Foundation
import Testing

@testable import Kikimi

/// `SummaryRenderer.render(_:templateString:)` coverage (`docs/design/04-summary-updater.md` §5,
/// kikimi.md 5/8 章's view template).
@Suite("SummaryRenderer")
struct SummaryRendererTests {
    @Test("renders the default template: title/overview/participants separator/decisions/action items with due")
    func rendersDefaultTemplateRepresentativeState() throws {
        let state = SummaryState(
            title: "デイリースクラム",
            participants: ["田中さん", "佐藤さん", "鈴木さん"],
            overview: "顧客A向け提案書作成の支援について",
            decisions: [
                SummaryState.Decision(text: "スライド検索結果の新規UI開発はスコープ外", sourceSegIds: ["seg_00087"])
            ],
            actionItems: [
                SummaryState.ActionItem(
                    id: "ai_001", task: "検索対象テーブルのデータ量確認", assignee: "tanaka-san",
                    due: "7月末", status: .open, sourceSegIds: ["seg_00102"]
                ),
                SummaryState.ActionItem(
                    id: "ai_002", task: "見積書レビュー", assignee: "uphy",
                    due: nil, status: .open, sourceSegIds: []
                )
            ],
            lastSummarizedStartMs: 1_000
        )

        let rendered = try #require(SummaryRenderer.render(state, templateString: nil)).joined

        #expect(rendered.contains("# デイリースクラム"))
        #expect(rendered.contains("顧客A向け提案書作成の支援について"))
        // Trailing separator suppressed after the last participant (kikimi.md 8 章's "読点区切り、末尾以外").
        #expect(rendered.contains("**参加者:** 田中さん、佐藤さん、鈴木さん"))
        #expect(!rendered.contains("鈴木さん、"))
        #expect(rendered.contains("- スライド検索結果の新規UI開発はスコープ外"))
        #expect(rendered.contains("| 検索対象テーブルのデータ量確認 | tanaka-san | 7月末 |"))
        // due == nil renders as an em dash placeholder, not an empty cell.
        #expect(rendered.contains("| 見積書レビュー | uphy | — |"))
    }

    @Test("renders empty participants without emitting a stray separator")
    func rendersEmptyParticipants() throws {
        var state = SummaryState.empty
        state.title = "タイトルなし会議"

        let rendered = try #require(SummaryRenderer.render(state, templateString: nil)).joined

        #expect(rendered.contains("**参加者:** "))
    }

    @Test("falls back to the default template when the session template is empty")
    func fallsBackWhenSessionTemplateEmpty() throws {
        var state = SummaryState.empty
        state.title = "フォールバック確認"

        let rendered = try #require(SummaryRenderer.render(state, templateString: "")).joined

        #expect(rendered.contains("# フォールバック確認"))
    }

    @Test("falls back to the default template when the session template fails to parse")
    func fallsBackWhenSessionTemplateBroken() throws {
        var state = SummaryState.empty
        state.title = "壊れたテンプレート"

        // Unclosed section tag -- GRMustache.swift should throw a MustacheError while parsing this.
        let broken = "{{#decisions}}{{text}}"

        let rendered = try #require(SummaryRenderer.render(state, templateString: broken)).joined

        #expect(rendered.contains("# 壊れたテンプレート"))
    }

    @Test("a custom session template can reorder/reword headings while still reading schema fields")
    func rendersCustomSessionTemplate() throws {
        var state = SummaryState.empty
        state.title = "カスタム見出し確認"
        state.overview = "概要本文"

        let customTemplate = "見出し: {{title}}\n本文: {{overview}}"

        let rendered = try #require(SummaryRenderer.render(state, templateString: customTemplate)).joined

        #expect(rendered == "見出し: カスタム見出し確認\n本文: 概要本文")
    }

    @Test("does not emit frontmatter")
    func doesNotEmitFrontmatter() throws {
        var state = SummaryState.empty
        state.title = "フロントマター確認"

        let rendered = try #require(SummaryRenderer.render(state, templateString: nil)).joined

        #expect(!rendered.hasPrefix("---"))
    }

    @Test("renders the 議事詳細 section from topics, in order, after action items")
    func rendersTopicsSection() throws {
        let state = SummaryState(
            title: "t",
            participants: [],
            overview: "o",
            decisions: [],
            actionItems: [],
            topics: [
                SummaryState.Topic(
                    id: "tp_001",
                    heading: "検索基盤の移行方針",
                    body: "- Elasticsearchへの移行を検討\n- 移行コストは未見積り",
                    sourceSegIds: ["seg_00010"]
                ),
                SummaryState.Topic(
                    id: "tp_002",
                    heading: "次回会議の日程",
                    body: "来週火曜に再度確認する",
                    sourceSegIds: []
                )
            ],
            lastSummarizedStartMs: 0
        )

        let rendered = try #require(SummaryRenderer.render(state, templateString: nil)).joined

        #expect(rendered.contains(
            """
            ## 議事詳細

            ### 検索基盤の移行方針

            - Elasticsearchへの移行を検討
            - 移行コストは未見積り

            ### 次回会議の日程

            来週火曜に再度確認する
            """
        ))
        // Placement: after the action items section (設計 4.1's "アクションアイテムの後（末尾）").
        let actionItemsRange = try #require(rendered.range(of: "## アクションアイテム"))
        let topicsRange = try #require(rendered.range(of: "## 議事詳細"))
        #expect(actionItemsRange.lowerBound < topicsRange.lowerBound)
        // `id`/`source_seg_ids` are internal bookkeeping keys, never exposed to the view (設計 4.2).
        #expect(!rendered.contains("tp_001"))
        #expect(!rendered.contains("seg_00010"))
    }

    @Test("still emits the 議事詳細 heading when topics is empty, with no topic entries")
    func rendersTopicsHeadingWhenEmpty() throws {
        var state = SummaryState.empty
        state.title = "空トピック確認"

        let rendered = try #require(SummaryRenderer.render(state, templateString: nil)).joined

        #expect(rendered.contains("## 議事詳細"))
        // No topic heading ("### ...") is emitted for an empty topics array.
        #expect(!rendered.contains("### "))
    }

    @Test("passes '&'/'<'/'>' through overview and topic body unescaped instead of HTML-escaping them")
    func passesHTMLSpecialCharsThroughUnescaped() throws {
        let state = SummaryState(
            title: "t",
            participants: [],
            overview: "A社 & B社 <確認事項> の調整",
            decisions: [],
            actionItems: [],
            topics: [
                SummaryState.Topic(
                    id: "tp_001",
                    heading: "見積り確認",
                    body: "> 前回の見積りは100万円だったが、A<B & B>C の条件で再検討する",
                    sourceSegIds: []
                )
            ],
            lastSummarizedStartMs: 0
        )

        let rendered = try #require(SummaryRenderer.render(state, templateString: nil)).joined

        #expect(rendered.contains("A社 & B社 <確認事項> の調整"))
        #expect(rendered.contains("> 前回の見積りは100万円だったが、A<B & B>C の条件で再検討する"))
        #expect(!rendered.contains("&amp;"))
        #expect(!rendered.contains("&lt;"))
        #expect(!rendered.contains("&gt;"))
    }

    @Test("a custom session template also renders '&'/'<'/'>' unescaped (text-mode content type applies to user templates too)")
    func customTemplateAlsoUsesTextMode() throws {
        var state = SummaryState.empty
        state.overview = "A & B <C>"

        let rendered = try #require(SummaryRenderer.render(state, templateString: "{{overview}}")).joined

        #expect(rendered == "A & B <C>")
    }

    @Test("does not leak the CONTENT_TYPE:TEXT pragma tag itself into rendered output")
    func pragmaTagProducesNoOutput() throws {
        var state = SummaryState.empty
        state.title = "pragma確認"

        let rendered = try #require(SummaryRenderer.render(state, templateString: nil)).joined

        #expect(!rendered.contains("CONTENT_TYPE"))
        // No newline was inserted between the pragma and the template, so no leading blank line.
        #expect(rendered.hasPrefix("# pragma確認"))
    }

    @Test("multiple action items render as consecutive GFM table rows, with no blank line breaking the table")
    func rendersMultipleActionItemsAsConsecutiveTableRows() throws {
        let state = SummaryState(
            title: "t",
            participants: [],
            overview: "o",
            decisions: [],
            actionItems: [
                SummaryState.ActionItem(id: "a", task: "task1", assignee: "x", due: nil, status: .open, sourceSegIds: []),
                SummaryState.ActionItem(id: "b", task: "task2", assignee: "y", due: nil, status: .open, sourceSegIds: [])
            ],
            lastSummarizedStartMs: 0
        )
        let rendered = try #require(SummaryRenderer.render(state, templateString: nil)).joined

        // GFM tables are broken by any blank line -- the header/separator/data rows must be
        // consecutive non-blank lines, or the data rows fall out of the table and render as raw text.
        #expect(rendered.contains("|--------|------|------|\n| task1 | x | — |\n| task2 | y | — |"))
    }
}

// MARK: - Two-pane split

/// `docs/design/47-summary-split-pane.md` §3: splitting a template into the Summary tab's two panes.
///
/// The invariant that matters throughout: **`joined` equals what the unsplit template renders**.
/// `summary.md`, the copy action, the chat context, and the Wiki export all read `joined`, so a split
/// that changed it would silently corrupt four consumers at once.
@Suite("SummaryRenderer split")
struct SummaryRendererSplitTests {
    /// Representative state with content in every section, so a boundary that lands in the wrong
    /// place shows up as text on the wrong side rather than as two empty halves.
    private static func populatedState() -> SummaryState {
        SummaryState(
            title: "定例会議",
            participants: ["田中さん", "佐藤さん"],
            overview: "進捗の共有と次期スコープの確認",
            decisions: [SummaryState.Decision(id: "dc_001", text: "移行は来期に延期", sourceSegIds: ["seg_00001"])],
            actionItems: [
                SummaryState.ActionItem(
                    id: "ai_001", task: "見積りの再算出", assignee: "tanaka-san",
                    due: "8月末", status: .open, sourceSegIds: ["seg_00002"]
                )
            ],
            topics: [
                SummaryState.Topic(id: "tp_001", heading: "移行スケジュール", body: "工数が想定の倍だった", sourceSegIds: ["seg_00003"]),
                SummaryState.Topic(id: "tp_002", heading: "次回の議題", body: "見積りのレビュー", sourceSegIds: [])
            ],
            lastSummarizedStartMs: 5_000
        )
    }

    @Test("the built-in default template splits at 議事詳細: state above, topics below")
    func splitsBuiltInDefaultTemplate() throws {
        let rendered = try #require(SummaryRenderer.render(Self.populatedState(), templateString: nil))

        let topics = try #require(rendered.topics)
        #expect(rendered.top.contains("# 定例会議"))
        #expect(rendered.top.contains("## 概要"))
        #expect(rendered.top.contains("## 決定事項"))
        #expect(rendered.top.contains("## アクションアイテム"))
        #expect(!rendered.top.contains("## 議事詳細"))
        #expect(topics.hasPrefix("## 議事詳細"))
        #expect(topics.contains("### 移行スケジュール"))
        #expect(topics.contains("### 次回の議題"))
        // The state half must not leak into the log half.
        #expect(!topics.contains("## 概要"))
    }

    @Test("joined reproduces the unsplit render byte-for-byte")
    func joinedMatchesUnsplitRender() throws {
        // Same expectations the pre-split tests assert on the whole document -- if the boundary ever
        // dropped or duplicated so much as a newline, this is what catches it.
        let rendered = try #require(SummaryRenderer.render(Self.populatedState(), templateString: nil))

        #expect(rendered.joined.contains("## アクションアイテム\n\n| タスク | 担当 | 期限 |"))
        // Three newlines, not two: GRMustache.swift does not fold standalone lines, so the
        // `{{/action_items}}` line survives as a blank one. The boundary must not quietly absorb it.
        #expect(rendered.joined.contains("| 見積りの再算出 | tanaka-san | 8月末 |\n\n\n## 議事詳細"))
        #expect(rendered.joined == rendered.top + (rendered.topics ?? ""))
    }

    @Test("a template with no topics section renders as a single pane")
    func doesNotSplitTemplateWithoutTopics() throws {
        let template = "# {{title}}\n\n## 概要\n\n{{overview}}\n"

        let rendered = try #require(SummaryRenderer.render(Self.populatedState(), templateString: template))

        #expect(rendered.topics == nil)
        // `render(_:templateString:)` trims the template before parsing, so the source's trailing
        // newline is not part of the output.
        #expect(rendered.top == "# 定例会議\n\n## 概要\n\n進捗の共有と次期スコープの確認")
    }

    @Test("an empty-state {{^topics}} block is treated as the start of the topics half")
    func splitsOnInvertedTopicsSection() throws {
        let template = """
        ## 概要

        {{overview}}

        ## 議事詳細

        {{^topics}}まだありません{{/topics}}{{#topics}}### {{heading}}
        {{/topics}}
        """
        var state = Self.populatedState()
        state.topics = []

        let rendered = try #require(SummaryRenderer.render(state, templateString: template))

        let topics = try #require(rendered.topics)
        #expect(topics.hasPrefix("## 議事詳細"))
        #expect(topics.contains("まだありません"))
        #expect(rendered.top.contains("## 概要"))
    }

    @Test("a boundary inside an enclosing section is rejected by the concatenation check")
    func rejectsBoundaryInsideEnclosingSection() throws {
        // `## 議事詳細` sits inside `{{#decisions}}`, so cutting there puts the section's opening tag
        // in one half and its closing tag in the other. Both halves still parse (Mustache is happy to
        // render an unmatched-looking fragment differently), but they cannot concatenate back.
        let template = """
        # {{title}}

        ## 決定事項

        {{#decisions}}{{text}}

        ## 議事詳細

        {{#topics}}{{heading}}
        {{/topics}}{{/decisions}}
        """

        let rendered = try #require(SummaryRenderer.render(Self.populatedState(), templateString: template))

        #expect(rendered.topics == nil)
        #expect(rendered.top.contains("移行は来期に延期"))
    }

    @Test("with no ## heading above the topics section, the boundary is the {{#topics}} line itself")
    func fallsBackToTheTopicsLineWhenNoHeadingPrecedesIt() throws {
        let template = """
        # {{title}}

        概要: {{overview}}

        {{#topics}}### {{heading}}
        {{/topics}}
        """

        let rendered = try #require(SummaryRenderer.render(Self.populatedState(), templateString: template))

        let topics = try #require(rendered.topics)
        #expect(rendered.top.contains("# 定例会議"))
        #expect(rendered.top.contains("概要: 進捗の共有と次期スコープの確認"))
        #expect(topics.hasPrefix("### 移行スケジュール"))
    }

    @Test("a # title line above the topics section stays in the top pane rather than becoming the boundary")
    func keepsTheTitleInTheTopPane() throws {
        // §3.2's reason for excluding `# ` from the backwards heading scan: cutting there would leave
        // the top pane holding nothing at all. Falling through to the `{{#topics}}` line instead keeps
        // the title where a reader expects it.
        let template = "# {{title}}\n{{#topics}}### {{heading}}\n{{/topics}}"

        let rendered = try #require(SummaryRenderer.render(Self.populatedState(), templateString: template))

        #expect(rendered.top == "# 定例会議\n")
        #expect(try #require(rendered.topics).hasPrefix("### 移行スケジュール"))
    }

    @Test("a template starting with {{#topics}} renders as a single pane, never an empty top")
    func doesNotSplitWhenTheTopPaneWouldBeEmpty() throws {
        // The boundary lands at offset 0, and `"" + whole == whole` sails through the concatenation
        // check (§3.2). Only the explicit non-empty guard stops half the tab rendering blank.
        let template = "{{#topics}}### {{heading}}\n\n{{body}}\n{{/topics}}"

        let rendered = try #require(SummaryRenderer.render(Self.populatedState(), templateString: template))

        #expect(rendered.topics == nil)
        #expect(rendered.top.hasPrefix("### 移行スケジュール"))
    }

    @Test("a broken session template falls back to the built-in default, and the split comes from that default")
    func splitsTheFallbackTemplateNotTheBrokenOne() throws {
        // §3.3: the fallback is resolved *before* splitting. Splitting the broken source instead would
        // pair a default-template `joined` with a user-template boundary.
        let rendered = try #require(SummaryRenderer.render(Self.populatedState(), templateString: "{{#decisions}}{{text}}"))

        let topics = try #require(rendered.topics)
        #expect(topics.hasPrefix("## 議事詳細"))
        #expect(rendered.top.contains("## アクションアイテム"))
    }

    @Test("an empty topics array still yields a topics pane holding just the heading")
    func splitsWithEmptyTopics() throws {
        var state = Self.populatedState()
        state.topics = []

        let rendered = try #require(SummaryRenderer.render(state, templateString: nil))

        let topics = try #require(rendered.topics)
        #expect(topics.hasPrefix("## 議事詳細"))
        #expect(!topics.contains("### "))
        #expect(rendered.top.contains("## 決定事項"))
    }
}
