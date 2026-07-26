import Foundation

// MARK: - SummaryPatch

/// The structured output an LLM call returns for a summary update (kikimi.md 8 章「セクションごとの
/// patch 戦略」/ `docs/design/04-summary-updater.md` 2.2 章). Every field is optional: "何も変更が
/// なければ全フィールド null" (kikimi.md 8 章's system prompt rule).
///
/// `applyPatch(_:to:)` (see `SummaryPatchApplier.swift`) is the sole consumer that folds this into
/// a `SummaryState`.
struct SummaryPatch: Codable, Sendable, Equatable {
    /// cumulative: 変更があれば新値、なければ null.
    var title: String?
    /// append_only: 追加された人だけ.
    var participantsAdd: [String]?
    /// snapshot: 全文（変更時のみ）.
    var overview: String?
    /// append_only: 新規のみ.
    var decisionsAdd: [SummaryState.Decision]?
    /// add / modify / complete operations on action items.
    var actionItems: ActionItemPatch?

    // No explicit `CodingKeys`: `LLMClient.decodeResult(from:)` decodes `structured_output` with a
    // `.convertFromSnakeCase` decoder, so the CLI's `participants_add`/`decisions_add`/`action_items`
    // /`source_seg_ids` map onto these camelCase properties automatically -- matching how
    // `SummaryState` round-trips through `SessionJSONCoding`. The JSON Schema (`patchSchemaJSON`
    // below) stays snake_case, which is what the LLM emits.

    struct ActionItemPatch: Codable, Sendable, Equatable {
        var add: [SummaryState.ActionItem]?
        var modify: [Modify]?
        /// ids of action items to mark `.done`.
        var complete: [String]?

        // swiftlint:disable:next nesting
        struct Modify: Codable, Sendable, Equatable { // intentional domain nesting: a per-item modify op
            var id: String
            var task: String?
            var assignee: String?
            var due: String?
        }
    }
}

// MARK: - TitleOnly

/// A minimal structured-output type for the session-end final title proposal
/// (`docs/design/04-summary-updater.md` §3.4). Kept as its own LLM call/schema (separate from
/// `SummaryPatch`) so that prompt stays small (SWE review C9).
struct TitleOnly: Codable, Sendable {
    var title: String
}

// MARK: - JSON Schema constants

/// JSON Schema strings handed to `LLMRequest.schema` (`--json-schema`, `docs/design/12-llm-client.md`
/// section 4). Kept 1:1 with `SummaryPatch`/`TitleOnly`; a unit test decodes a representative patch
/// JSON into each type to keep this constant honest (`docs/design/04-summary-updater.md` §2.2).
enum SummaryJSONSchema {
    /// Schema for `SummaryPatch`. All fields optional (`required` is empty) and
    /// `additionalProperties: false` (04-summary-updater.md §2.2).
    static let patchSchemaJSON = """
    {
      "type": "object",
      "properties": {
        "title": { "type": ["string", "null"] },
        "participants_add": {
          "type": ["array", "null"],
          "items": { "type": "string" }
        },
        "overview": { "type": ["string", "null"] },
        "decisions_add": {
          "type": ["array", "null"],
          "items": {
            "type": "object",
            "properties": {
              "text": { "type": "string" },
              "source_seg_ids": {
                "type": "array",
                "items": { "type": "string" }
              }
            },
            "required": ["text", "source_seg_ids"],
            "additionalProperties": false
          }
        },
        "action_items": {
          "type": ["object", "null"],
          "properties": {
            "add": {
              "type": ["array", "null"],
              "items": {
                "type": "object",
                "properties": {
                  "id": { "type": "string" },
                  "task": { "type": "string" },
                  "assignee": { "type": "string" },
                  "due": { "type": ["string", "null"] },
                  "status": { "type": "string", "enum": ["open", "done"] },
                  "source_seg_ids": {
                    "type": "array",
                    "items": { "type": "string" }
                  }
                },
                "required": ["id", "task", "assignee", "status", "source_seg_ids"],
                "additionalProperties": false
              }
            },
            "modify": {
              "type": ["array", "null"],
              "items": {
                "type": "object",
                "properties": {
                  "id": { "type": "string" },
                  "task": { "type": ["string", "null"] },
                  "assignee": { "type": ["string", "null"] },
                  "due": { "type": ["string", "null"] }
                },
                "required": ["id"],
                "additionalProperties": false
              }
            },
            "complete": {
              "type": ["array", "null"],
              "items": { "type": "string" }
            }
          },
          "required": [],
          "additionalProperties": false
        }
      },
      "required": [],
      "additionalProperties": false
    }
    """

    /// Schema for `TitleOnly` (04-summary-updater.md §3.4's code example, used verbatim).
    static let titleSchemaJSON = """
    {"type":"object","properties":{"title":{"type":"string"}},"required":["title"],"additionalProperties":false}
    """
}
