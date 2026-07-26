import Foundation
import Testing

@testable import Kikimi

/// `SummaryJSONSchema` coverage: the schema strings handed to `LLMRequest.schema` must be valid JSON
/// and 1:1 with `SummaryPatch`/`TitleOnly` (`docs/design/04-summary-updater.md` §2.2/§3.4).
@Suite("SummaryJSONSchema")
struct SummaryJSONSchemaTests {
    @Test("patchSchemaJSON is valid JSON")
    func patchSchemaIsValidJSON() throws {
        let data = Data(SummaryJSONSchema.patchSchemaJSON.utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["type"] as? String == "object")
        #expect((object?["required"] as? [String])?.isEmpty == true)
        #expect(object?["additionalProperties"] as? Bool == false)
    }

    @Test("titleSchemaJSON is valid JSON and matches the 04-summary-updater.md §3.4 example verbatim")
    func titleSchemaIsValidJSONAndMatchesExample() throws {
        let data = Data(SummaryJSONSchema.titleSchemaJSON.utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["type"] as? String == "object")
        #expect(object?["required"] as? [String] == ["title"])
        #expect(object?["additionalProperties"] as? Bool == false)
        let properties = try #require(object?["properties"] as? [String: Any])
        let titleProperty = try #require(properties["title"] as? [String: Any])
        #expect(titleProperty["type"] as? String == "string")
    }

    @Test("a representative full patch JSON (kikimi.md 8 章's example) decodes into SummaryPatch")
    func representativePatchJSONDecodes() throws {
        let json = """
        {
          "title": null,
          "participants_add": null,
          "overview": "顧客A向け提案書作成の支援について...",
          "decisions_add": [
            {"text": "スライド検索結果の新規UI開発はスコープ外", "source_seg_ids": ["seg_00087"]}
          ],
          "action_items": {
            "add": [
              {
                "id": "ai_003", "task": "検索対象テーブルのデータ量確認", "assignee": "tanaka-san",
                "due": null, "status": "open", "source_seg_ids": ["seg_00102"]
              }
            ],
            "modify": [
              {"id": "ai_001", "task": null, "assignee": null, "due": "7月末"}
            ],
            "complete": null
          }
        }
        """
        let decoder = SessionJSONCoding.makeDecoder()
        let patch = try decoder.decode(SummaryPatch.self, from: Data(json.utf8))

        #expect(patch.title == nil)
        #expect(patch.overview == "顧客A向け提案書作成の支援について...")
        #expect(patch.decisionsAdd?.first?.text == "スライド検索結果の新規UI開発はスコープ外")
        #expect(patch.actionItems?.add?.first?.id == "ai_003")
        #expect(patch.actionItems?.modify?.first?.due == "7月末")
        #expect(patch.actionItems?.complete == nil)
    }

    @Test("a fully-null patch JSON (no changes) decodes into an all-nil SummaryPatch")
    func fullyNullPatchJSONDecodes() throws {
        let json = """
        {
          "title": null, "participants_add": null, "overview": null,
          "decisions_add": null, "action_items": null
        }
        """
        let decoder = SessionJSONCoding.makeDecoder()
        let patch = try decoder.decode(SummaryPatch.self, from: Data(json.utf8))

        #expect(patch == SummaryPatch(title: nil, participantsAdd: nil, overview: nil, decisionsAdd: nil, actionItems: nil))
    }

    @Test("a representative TitleOnly JSON decodes")
    func titleOnlyJSONDecodes() throws {
        let json = """
        {"title": "デイリースクラム振り返り"}
        """
        let decoder = SessionJSONCoding.makeDecoder()
        let titleOnly = try decoder.decode(TitleOnly.self, from: Data(json.utf8))

        #expect(titleOnly.title == "デイリースクラム振り返り")
    }
}
