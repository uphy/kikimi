import Foundation
import Testing

@testable import Kikimi

// MARK: - SummaryState

@Suite("SummaryState")
struct SummaryStateTests {
    /// kikimi.md 8 章's schema shape, rendered as the on-disk snake_case JSON
    /// (`docs/design/04-summary-updater.md` §2.1).
    static let sampleJSON = """
    {
      "title": "デイリースクラム",
      "participants": ["田中さん", "佐藤さん"],
      "overview": "顧客A向け提案書作成の支援について",
      "decisions": [
        { "text": "スライド検索結果の新規UI開発はスコープ外", "source_seg_ids": ["seg_00087"] }
      ],
      "action_items": [
        {
          "id": "ai_001",
          "task": "検索対象テーブルのデータ量確認",
          "assignee": "tanaka-san",
          "due": null,
          "status": "open",
          "source_seg_ids": ["seg_00102"]
        }
      ],
      "last_summarized_start_ms": 128100
    }
    """

    @Test("decodes snake_case JSON into camelCase fields")
    func decodesSampleJSON() throws {
        let decoder = SessionJSONCoding.makeDecoder()
        let state = try decoder.decode(SummaryState.self, from: Data(Self.sampleJSON.utf8))

        #expect(state.title == "デイリースクラム")
        #expect(state.participants == ["田中さん", "佐藤さん"])
        #expect(state.overview == "顧客A向け提案書作成の支援について")
        #expect(state.decisions == [
            SummaryState.Decision(text: "スライド検索結果の新規UI開発はスコープ外", sourceSegIds: ["seg_00087"])
        ])
        #expect(state.actionItems == [
            SummaryState.ActionItem(
                id: "ai_001",
                task: "検索対象テーブルのデータ量確認",
                assignee: "tanaka-san",
                due: nil,
                status: .open,
                sourceSegIds: ["seg_00102"]
            )
        ])
        #expect(state.lastSummarizedStartMs == 128_100)
    }

    @Test("round-trips through the shared encoder/decoder")
    func roundTrips() throws {
        let original = SummaryState(
            title: "デイリースクラム",
            participants: ["田中さん", "佐藤さん"],
            overview: "概要",
            decisions: [SummaryState.Decision(text: "決定1", sourceSegIds: ["seg_00001"])],
            actionItems: [
                SummaryState.ActionItem(
                    id: "ai_001",
                    task: "タスク",
                    assignee: "担当者",
                    due: "7月末",
                    status: .done,
                    sourceSegIds: ["seg_00002"]
                )
            ],
            lastSummarizedStartMs: 5_000
        )

        let encoder = SessionJSONCoding.makeEncoder()
        let decoder = SessionJSONCoding.makeDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SummaryState.self, from: data)

        #expect(decoded == original)
    }

    @Test("encodes keys as snake_case, including source_seg_ids/action_items/last_summarized_start_ms")
    func encodesSnakeCaseKeys() throws {
        let state = SummaryState(
            title: nil,
            participants: [],
            overview: "",
            decisions: [SummaryState.Decision(text: "x", sourceSegIds: ["seg_00001"])],
            actionItems: [
                SummaryState.ActionItem(
                    id: "ai_001", task: "t", assignee: "a", due: nil, status: .open, sourceSegIds: []
                )
            ],
            lastSummarizedStartMs: 10
        )
        let data = try SessionJSONCoding.makeEncoder().encode(state)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["action_items"] != nil)
        #expect(object?["last_summarized_start_ms"] as? Int == 10)
        let decisions = try #require(object?["decisions"] as? [[String: Any]])
        #expect(decisions[0]["source_seg_ids"] != nil)
        let actionItems = try #require(object?["action_items"] as? [[String: Any]])
        #expect(actionItems[0]["source_seg_ids"] != nil)
    }

    /// A pre-existing `summary.state.json` written before `topics` / `decisions[].id` were
    /// introduced (`docs/design/summary-quality-topics-and-final-pass.md` §2.2, §11).
    static let legacyJSON = """
    {
      "title": "デイリースクラム",
      "participants": ["田中さん", "system"],
      "overview": "顧客A向け提案書作成の支援について",
      "decisions": [
        { "text": "スライド検索結果の新規UI開発はスコープ外", "source_seg_ids": ["seg_00087"] }
      ],
      "action_items": [],
      "last_summarized_start_ms": 128100
    }
    """

    @Test("decodes a legacy summary.state.json (no topics key, no decisions[].id) without throwing")
    func decodesLegacyJSONWithoutTopicsOrDecisionIds() throws {
        let decoder = SessionJSONCoding.makeDecoder()
        let state = try decoder.decode(SummaryState.self, from: Data(Self.legacyJSON.utf8))

        #expect(state.topics.isEmpty)
        #expect(state.decisions == [
            SummaryState.Decision(id: "", text: "スライド検索結果の新規UI開発はスコープ外", sourceSegIds: ["seg_00087"])
        ])
        #expect(state.decisions.first?.id == "")
    }

    @Test("round-trips a session that has never been summarized (lastSummarizedStartMs nil, everything empty)")
    func roundTripsEmptyState() throws {
        let encoder = SessionJSONCoding.makeEncoder()
        let decoder = SessionJSONCoding.makeDecoder()
        let data = try encoder.encode(SummaryState.empty)
        let decoded = try decoder.decode(SummaryState.self, from: data)

        #expect(decoded == SummaryState.empty)
        #expect(decoded.title == nil)
        #expect(decoded.lastSummarizedStartMs == nil)
        #expect(decoded.participants.isEmpty)
        #expect(decoded.decisions.isEmpty)
        #expect(decoded.actionItems.isEmpty)
        #expect(decoded.topics.isEmpty)
    }
}
