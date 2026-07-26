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
