import Foundation
import Testing

@testable import Kikimi

/// `RefinementResponse`/`RefinementJSONSchema` coverage: the schema string handed to
/// `LLMRequest.schema` must be valid JSON and 1:1 with `RefinementResponse`
/// (`docs/design/03-refinement-batch.md` §4.2).
@Suite("RefinementResponse")
struct RefinementResponseTests {
    @Test("schemaJSON is valid JSON matching the design doc's shape")
    func schemaJSONIsValidJSON() throws {
        let data = Data(RefinementJSONSchema.schemaJSON.utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["type"] as? String == "object")
        #expect(object?["required"] as? [String] == ["segments"])
        let properties = try #require(object?["properties"] as? [String: Any])
        let segmentsProperty = try #require(properties["segments"] as? [String: Any])
        #expect(segmentsProperty["type"] as? String == "array")
        let items = try #require(segmentsProperty["items"] as? [String: Any])
        #expect(items["required"] as? [String] == ["id", "refined_text"])
        let itemProperties = try #require(items["properties"] as? [String: Any])
        let joinsNextProperty = try #require(itemProperties["joins_next"] as? [String: Any])
        #expect(joinsNextProperty["type"] as? String == "boolean")
    }

    @Test("a representative snake_case response JSON decodes into RefinementResponse via SessionJSONCoding")
    func representativeSnakeCaseJSONDecodes() throws {
        let json = """
        {
          "segments": [
            {"id": "seg_00042", "refined_text": "次のスプリントで対応します。"},
            {"id": "seg_00043", "refined_text": "テストシナリオも追加します。"}
          ]
        }
        """
        let decoder = SessionJSONCoding.makeDecoder()
        let response = try decoder.decode(RefinementResponse.self, from: Data(json.utf8))

        #expect(response.segments.count == 2)
        #expect(response.segments[0].id == "seg_00042")
        #expect(response.segments[0].refinedText == "次のスプリントで対応します。")
        #expect(response.segments[1].id == "seg_00043")
        #expect(response.segments[1].refinedText == "テストシナリオも追加します。")
        // §15.2.2: `joins_next` is optional in the schema -- absent in this fixture, both items must
        // default to `false` rather than throwing a missing-key decode error.
        #expect(response.segments[0].joinsNext == false)
        #expect(response.segments[1].joinsNext == false)
    }

    @Test("joins_next decodes when present, defaults to false when absent, per §15.2.2")
    func joinsNextDecodesWhenPresentAndDefaultsWhenAbsent() throws {
        let json = """
        {
          "segments": [
            {"id": "seg_00042", "refined_text": "そうですね次のスプリントで", "joins_next": true},
            {"id": "seg_00043", "refined_text": "対応します。", "joins_next": false},
            {"id": "seg_00044", "refined_text": "了解しました。"}
          ]
        }
        """
        let decoder = SessionJSONCoding.makeDecoder()
        let response = try decoder.decode(RefinementResponse.self, from: Data(json.utf8))

        #expect(response.segments[0].joinsNext == true)
        #expect(response.segments[1].joinsNext == false)
        #expect(response.segments[2].joinsNext == false)
    }

    @Test("an empty segments array decodes cleanly (kikimi-verify's built-in stub response shape)")
    func emptySegmentsArrayDecodes() throws {
        let json = """
        {"segments": []}
        """
        let decoder = SessionJSONCoding.makeDecoder()
        let response = try decoder.decode(RefinementResponse.self, from: Data(json.utf8))

        #expect(response.segments.isEmpty)
    }
}
