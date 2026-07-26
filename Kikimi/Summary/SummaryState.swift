import Foundation

// MARK: - SummaryState

/// `summary.state.json`: the internal structured state a session's summary is built from.
/// kikimi.md 8 章「内部 state の schema」/ `docs/design/04-summary-updater.md` 2.1 章.
///
/// MVP ships an app-builtin fixed schema (no per-session override). LLM calls return a
/// `SummaryPatch` (see `SummaryPatch.swift`); `applyPatch(_:to:)` folds a patch into this state
/// deterministically, and `SummaryRenderer` renders it to Markdown via the view template.
struct SummaryState: Codable, Sendable, Equatable {
    var title: String?
    var participants: [String]
    var overview: String
    var decisions: [Decision]
    var actionItems: [ActionItem]

    /// Cursor: the highest `TranscriptSegment.startMs` already fed into a summary update.
    /// Segments with `startMs > lastSummarizedStartMs` are the "未反映分" for the next update
    /// (kikimi.md 8 章 user prompt「前回サマリ更新以降の未反映分」). `nil` before the first update.
    /// This is a Kikimi-internal bookkeeping field, not part of kikimi.md 8 章's schema, and is
    /// never exposed to the view template (04-summary-updater.md §2.1 note).
    var lastSummarizedStartMs: Int?

    /// No explicit `CodingKeys`: `source_seg_ids` maps to `sourceSegIds` via `.convertFromSnakeCase`
    /// on both persistence paths -- `SessionJSONCoding` (`summary.state.json`) and
    /// `LLMClient.decodeResult` (`structured_output`, when this type is decoded as part of a
    /// `SummaryPatch`). Explicit snake_case keys would conflict with that conversion.
    struct Decision: Codable, Sendable, Equatable {
        var text: String
        var sourceSegIds: [String]
    }

    struct ActionItem: Codable, Sendable, Equatable {
        /// `"ai_"` + zero-padded sequence number (e.g. `"ai_001"`). The LLM proposes an id, but
        /// `applyPatch` is the sole authority on uniqueness -- see 04-summary-updater.md §2.3's
        /// "id 衝突時は Kikimi 側でリネーム".
        var id: String
        var task: String
        var assignee: String
        var due: String?
        var status: Status
        var sourceSegIds: [String]

        // swiftlint:disable:next nesting
        enum Status: String, Codable, Sendable { // intentional domain nesting: an ActionItem's status
            case open
            case done
        }

        // No explicit `CodingKeys`, same rationale as `Decision` above (`source_seg_ids` ↔
        // `sourceSegIds` via `.convertFromSnakeCase` on both persistence paths).
    }

    /// The state a brand-new session starts from, before any summary update has ever run
    /// (04-summary-updater.md §2.1's code example).
    static let empty = SummaryState(
        title: nil,
        participants: [],
        overview: "",
        decisions: [],
        actionItems: [],
        lastSummarizedStartMs: nil
    )
}
