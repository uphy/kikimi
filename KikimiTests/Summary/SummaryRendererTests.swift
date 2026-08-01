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

        let rendered = try #require(SummaryRenderer.render(state, templateString: nil))

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

        let rendered = try #require(SummaryRenderer.render(state, templateString: nil))

        #expect(rendered.contains("**参加者:** "))
    }

    @Test("falls back to the default template when the session template is empty")
    func fallsBackWhenSessionTemplateEmpty() throws {
        var state = SummaryState.empty
        state.title = "フォールバック確認"

        let rendered = try #require(SummaryRenderer.render(state, templateString: ""))

        #expect(rendered.contains("# フォールバック確認"))
    }

    @Test("falls back to the default template when the session template fails to parse")
    func fallsBackWhenSessionTemplateBroken() throws {
        var state = SummaryState.empty
        state.title = "壊れたテンプレート"

        // Unclosed section tag -- GRMustache.swift should throw a MustacheError while parsing this.
        let broken = "{{#decisions}}{{text}}"

        let rendered = try #require(SummaryRenderer.render(state, templateString: broken))

        #expect(rendered.contains("# 壊れたテンプレート"))
    }

    @Test("a custom session template can reorder/reword headings while still reading schema fields")
    func rendersCustomSessionTemplate() throws {
        var state = SummaryState.empty
        state.title = "カスタム見出し確認"
        state.overview = "概要本文"

        let customTemplate = "見出し: {{title}}\n本文: {{overview}}"

        let rendered = try #require(SummaryRenderer.render(state, templateString: customTemplate))

        #expect(rendered == "見出し: カスタム見出し確認\n本文: 概要本文")
    }

    @Test("does not emit frontmatter")
    func doesNotEmitFrontmatter() throws {
        var state = SummaryState.empty
        state.title = "フロントマター確認"

        let rendered = try #require(SummaryRenderer.render(state, templateString: nil))

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

        let rendered = try #require(SummaryRenderer.render(state, templateString: nil))

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

        let rendered = try #require(SummaryRenderer.render(state, templateString: nil))

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

        let rendered = try #require(SummaryRenderer.render(state, templateString: nil))

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

        let rendered = try #require(SummaryRenderer.render(state, templateString: "{{overview}}"))

        #expect(rendered == "A & B <C>")
    }

    @Test("does not leak the CONTENT_TYPE:TEXT pragma tag itself into rendered output")
    func pragmaTagProducesNoOutput() throws {
        var state = SummaryState.empty
        state.title = "pragma確認"

        let rendered = try #require(SummaryRenderer.render(state, templateString: nil))

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
        let rendered = try #require(SummaryRenderer.render(state, templateString: nil))

        // GFM tables are broken by any blank line -- the header/separator/data rows must be
        // consecutive non-blank lines, or the data rows fall out of the table and render as raw text.
        #expect(rendered.contains("|--------|------|------|\n| task1 | x | — |\n| task2 | y | — |"))
    }
}
