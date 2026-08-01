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
            {"id": "dc_001", "text": "スライド検索結果の新規UI開発はスコープ外", "source_seg_ids": ["seg_00087"]}
          ],
          "decisions_modify": [
            {"id": "dc_002", "text": "予算は50万円以内で進める", "source_seg_ids": ["seg_00090"]}
          ],
          "decisions_remove": ["dc_003"],
          "topics_add": [
            {
              "id": "tp_001", "heading": "検索基盤の移行方針",
              "body": "- Elasticsearchへの移行を検討\\n- 移行はQ3目標",
              "source_seg_ids": ["seg_00050", "seg_00051"]
            }
          ],
          "topics_update": [
            {"id": "tp_002", "heading": null, "body": "- 追加の論点を反映", "source_seg_ids": ["seg_00060"]}
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
        #expect(patch.decisionsModify?.first?.id == "dc_002")
        #expect(patch.decisionsModify?.first?.text == "予算は50万円以内で進める")
        #expect(patch.decisionsRemove == ["dc_003"])
        #expect(patch.topicsAdd?.first?.id == "tp_001")
        #expect(patch.topicsAdd?.first?.heading == "検索基盤の移行方針")
        #expect(patch.topicsUpdate?.first?.id == "tp_002")
        #expect(patch.topicsUpdate?.first?.heading == nil)
        #expect(patch.topicsUpdate?.first?.body == "- 追加の論点を反映")
        #expect(patch.actionItems?.add?.first?.id == "ai_003")
        #expect(patch.actionItems?.modify?.first?.due == "7月末")
        #expect(patch.actionItems?.complete == nil)
    }

    @Test("a fully-null patch JSON (no changes) decodes into an all-nil SummaryPatch")
    func fullyNullPatchJSONDecodes() throws {
        let json = """
        {
          "title": null, "participants_add": null, "overview": null,
          "decisions_add": null, "decisions_modify": null, "decisions_remove": null,
          "topics_add": null, "topics_update": null, "action_items": null
        }
        """
        let decoder = SessionJSONCoding.makeDecoder()
        let patch = try decoder.decode(SummaryPatch.self, from: Data(json.utf8))

        #expect(
            patch == SummaryPatch(
                title: nil,
                participantsAdd: nil,
                overview: nil,
                decisionsAdd: nil,
                actionItems: nil,
                topicsAdd: nil,
                topicsUpdate: nil,
                decisionsModify: nil,
                decisionsRemove: nil
            )
        )
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

    @Test("patchSchemaJSON's decisions_add requires an id and topics_add/topics_update are present")
    func patchSchemaHasTopicsAndDecisionsExtensions() throws {
        let data = Data(SummaryJSONSchema.patchSchemaJSON.utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(object["properties"] as? [String: Any])

        #expect(properties["topics_add"] != nil)
        #expect(properties["topics_update"] != nil)
        #expect(properties["decisions_modify"] != nil)
        #expect(properties["decisions_remove"] != nil)

        let decisionsAdd = try #require(properties["decisions_add"] as? [String: Any])
        let decisionsAddItems = try #require(decisionsAdd["items"] as? [String: Any])
        let decisionsAddRequired = try #require(decisionsAddItems["required"] as? [String])
        #expect(decisionsAddRequired.contains("id"))
    }

    @Test("finalRevisionSchemaJSON is valid JSON with overview/decisions/action_items all required")
    func finalRevisionSchemaIsValidJSON() throws {
        let data = Data(SummaryJSONSchema.finalRevisionSchemaJSON.utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["type"] as? String == "object")
        #expect(object["additionalProperties"] as? Bool == false)
        let required = try #require(object["required"] as? [String])
        #expect(Set(required) == ["overview", "decisions", "action_items"])
    }

    @Test("a representative final revision JSON decodes into SummaryFinalRevision")
    func representativeFinalRevisionJSONDecodes() throws {
        let json = """
        {
          "overview": "会議全体では検索基盤の移行方針を議論し、Q3までの計画に合意した。",
          "decisions": [
            {"text": "Elasticsearchへの移行をQ3までに完了する", "source_seg_ids": ["seg_00050", "seg_00120"]}
          ],
          "action_items": [
            {
              "task": "移行計画のドラフト作成", "assignee": "tanaka-san", "due": "8月末",
              "status": "open", "source_seg_ids": ["seg_00130"]
            },
            {
              "task": "予算承認の依頼", "assignee": "yamada-san", "due": null,
              "status": "done", "source_seg_ids": ["seg_00040"]
            }
          ]
        }
        """
        let decoder = SessionJSONCoding.makeDecoder()
        let revision = try decoder.decode(SummaryFinalRevision.self, from: Data(json.utf8))

        #expect(revision.overview == "会議全体では検索基盤の移行方針を議論し、Q3までの計画に合意した。")
        #expect(revision.decisions.first?.text == "Elasticsearchへの移行をQ3までに完了する")
        #expect(revision.actionItems.first?.assignee == "tanaka-san")
        #expect(revision.actionItems.last?.status == .done)
        #expect(revision.actionItems.last?.due == nil)
    }
}
