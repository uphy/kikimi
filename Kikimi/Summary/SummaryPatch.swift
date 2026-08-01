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
    /// 新トピック開始（時系列末尾に append）. `docs/design/summary-quality-topics-and-final-pass.md`
    /// §3.1/§3.2.
    var topicsAdd: [SummaryState.Topic]?
    /// 既存トピックの更新（body は全文置換）. 同上 §3.1/§3.2.
    var topicsUpdate: [TopicUpdate]?
    /// 既存 decision の修正（text は全文置換）. 同上 §3.1/§3.2.
    var decisionsModify: [DecisionModify]?
    /// 削除する decision の id 群. 同上 §3.1/§3.2.
    var decisionsRemove: [String]?

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

    /// A per-topic update op: `id` selects the target topic, all other fields replace the
    /// corresponding `SummaryState.Topic` field only when non-nil (`body` is a full-text
    /// replacement, not a diff -- `docs/design/summary-quality-topics-and-final-pass.md` §3.1).
    struct TopicUpdate: Codable, Sendable, Equatable {
        var id: String
        var heading: String?
        var body: String?
        var sourceSegIds: [String]?
    }

    /// A per-decision update op: `id` selects the target decision, `text` replaces the decision's
    /// text when non-nil (`docs/design/summary-quality-topics-and-final-pass.md` §3.1).
    struct DecisionModify: Codable, Sendable, Equatable {
        var id: String
        var text: String?
        var sourceSegIds: [String]?
    }
}

// MARK: - TitleOnly

/// A minimal structured-output type for the session-end final title proposal
/// (`docs/design/04-summary-updater.md` §3.4). Kept as its own LLM call/schema (separate from
/// `SummaryPatch`) so that prompt stays small (SWE review C9).
struct TitleOnly: Codable, Sendable {
    var title: String
}

// MARK: - SummaryFinalRevision

/// The structured output the session-end final refinement pass returns
/// (`docs/design/summary-quality-topics-and-final-pass.md` §7.2). A single LLM call rewrites
/// `overview` / `decisions` / `actionItems` wholesale from the full transcript + current state.
/// Unlike `SummaryPatch`, ids are **not** returned by the LLM -- `applyFinalRevision(_:to:)` (see
/// `SummaryPatchApplier.swift`) renumbers `dc_00N` / `ai_00N` from scratch on apply. `title` /
/// `participants` / `topics` / `lastSummarizedStartMs` are out of scope for this pass (§7.2).
struct SummaryFinalRevision: Codable, Sendable, Equatable {
    var overview: String
    var decisions: [RevisedDecision]
    var actionItems: [RevisedActionItem]

    struct RevisedDecision: Codable, Sendable, Equatable {
        var text: String
        var sourceSegIds: [String]
    }

    struct RevisedActionItem: Codable, Sendable, Equatable {
        var task: String
        var assignee: String
        var due: String?
        var status: SummaryState.ActionItem.Status
        var sourceSegIds: [String]
    }
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
              "id": { "type": "string" },
              "text": { "type": "string" },
              "source_seg_ids": {
                "type": "array",
                "items": { "type": "string" }
              }
            },
            "required": ["id", "text", "source_seg_ids"],
            "additionalProperties": false
          }
        },
        "decisions_modify": {
          "type": ["array", "null"],
          "items": {
            "type": "object",
            "properties": {
              "id": { "type": "string" },
              "text": { "type": ["string", "null"] },
              "source_seg_ids": { "type": ["array", "null"], "items": { "type": "string" } }
            },
            "required": ["id"],
            "additionalProperties": false
          }
        },
        "decisions_remove": { "type": ["array", "null"], "items": { "type": "string" } },
        "topics_add": {
          "type": ["array", "null"],
          "items": {
            "type": "object",
            "properties": {
              "id": { "type": "string" },
              "heading": { "type": "string" },
              "body": { "type": "string" },
              "source_seg_ids": { "type": "array", "items": { "type": "string" } }
            },
            "required": ["id", "heading", "body", "source_seg_ids"],
            "additionalProperties": false
          }
        },
        "topics_update": {
          "type": ["array", "null"],
          "items": {
            "type": "object",
            "properties": {
              "id": { "type": "string" },
              "heading": { "type": ["string", "null"] },
              "body": { "type": ["string", "null"] },
              "source_seg_ids": { "type": ["array", "null"], "items": { "type": "string" } }
            },
            "required": ["id"],
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

    /// Schema for `SummaryFinalRevision`. All top-level fields required and
    /// `additionalProperties: false` (`docs/design/summary-quality-topics-and-final-pass.md` §7.2).
    /// Note ids are intentionally absent from `decisions`/`action_items` items -- the LLM does not
    /// return them, `applyFinalRevision(_:to:)` renumbers on apply.
    static let finalRevisionSchemaJSON = """
    {
      "type": "object",
      "properties": {
        "overview": { "type": "string" },
        "decisions": {
          "type": "array",
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
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "task": { "type": "string" },
              "assignee": { "type": "string" },
              "due": { "type": ["string", "null"] },
              "status": { "type": "string", "enum": ["open", "done"] },
              "source_seg_ids": {
                "type": "array",
                "items": { "type": "string" }
              }
            },
            "required": ["task", "assignee", "status", "source_seg_ids"],
            "additionalProperties": false
          }
        }
      },
      "required": ["overview", "decisions", "action_items"],
      "additionalProperties": false
    }
    """
}
