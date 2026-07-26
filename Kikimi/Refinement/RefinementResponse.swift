import Foundation

// MARK: - RefinementResponse

/// The structured output an LLM call returns for a refinement batch
/// (`docs/design/03-refinement-batch.md` §4.2, §15.2.2).
///
/// No explicit `CodingKeys`: per `docs/design/12-llm-client.md` §6.2's key strategy, the CLI's
/// `structured_output` (snake_case, matching `RefinementJSONSchema.schemaJSON` below) is decoded with
/// a `.convertFromSnakeCase` decoder, so `refined_text`/`joins_next` map onto `refinedText`/
/// `joinsNext` automatically.
struct RefinementResponse: Codable, Sendable, Equatable {
    var segments: [Item]

    struct Item: Codable, Sendable, Equatable {
        var id: String
        var refinedText: String
        /// §15.2.2's "このセグメントは次のセグメントと同一発話の続きで、1単位に繋げてよい" hint. Optional
        /// in the schema (not in `required`) and defaults to `false` when the LLM omits it --
        /// `decodeIfPresent(...) ?? false` needs a custom `init(from:)` since synthesized
        /// `Decodable` does not honor a stored property's default value for a missing key.
        var joinsNext: Bool

        init(id: String, refinedText: String, joinsNext: Bool = false) {
            self.id = id
            self.refinedText = refinedText
            self.joinsNext = joinsNext
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            refinedText = try container.decode(String.self, forKey: .refinedText)
            joinsNext = try container.decodeIfPresent(Bool.self, forKey: .joinsNext) ?? false
        }
    }
}

// MARK: - RefinementJSONSchema

/// JSON Schema string handed to `LLMRequest.schema` (`docs/design/12-llm-client.md` §4) for
/// refinement calls. Kept 1:1 with `RefinementResponse`; a unit test decodes a representative
/// response JSON into it to keep this constant honest.
enum RefinementJSONSchema {
    /// Schema for `RefinementResponse` (`docs/design/03-refinement-batch.md` §4.2, verbatim).
    static let schemaJSON = """
    {
      "type": "object",
      "properties": {
        "segments": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "id": { "type": "string" },
              "refined_text": { "type": "string" },
              "joins_next": { "type": "boolean" }
            },
            "required": ["id", "refined_text"]
          }
        }
      },
      "required": ["segments"]
    }
    """
}
