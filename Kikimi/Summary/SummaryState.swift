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

    /// Chronological topic list ("議事詳細"). `docs/design/summary-quality-topics-and-final-pass.md`
    /// §2.1. Absent from pre-existing `summary.state.json` files -- see the custom `init(from:)`
    /// below, which defaults it to `[]` when the key is missing.
    var topics: [Topic]

    /// Cursor: the highest `TranscriptSegment.startMs` already fed into a summary update.
    /// Segments with `startMs > lastSummarizedStartMs` are the "未反映分" for the next update
    /// (kikimi.md 8 章 user prompt「前回サマリ更新以降の未反映分」). `nil` before the first update.
    /// This is a Kikimi-internal bookkeeping field, not part of kikimi.md 8 章's schema, and is
    /// never exposed to the view template (04-summary-updater.md §2.1 note).
    var lastSummarizedStartMs: Int?

    /// Explicit `CodingKeys` (camelCase case names, no raw values) so the custom `init(from:)`
    /// below can reference `.topics`. `source_seg_ids` etc. still map to `sourceSegIds` via
    /// `.convertFromSnakeCase` on both persistence paths -- `SessionJSONCoding`
    /// (`summary.state.json`) and `LLMClient.decodeResult` (`structured_output`, when this type
    /// is decoded as part of a `SummaryPatch`). Explicit snake_case keys would conflict with that
    /// conversion (`docs/design/summary-quality-topics-and-final-pass.md` §2.2).
    enum CodingKeys: String, CodingKey {
        case title
        case participants
        case overview
        case decisions
        case actionItems
        case topics
        case lastSummarizedStartMs
    }

    init(
        title: String?,
        participants: [String],
        overview: String,
        decisions: [Decision],
        actionItems: [ActionItem],
        topics: [Topic] = [],
        lastSummarizedStartMs: Int?
    ) {
        self.title = title
        self.participants = participants
        self.overview = overview
        self.decisions = decisions
        self.actionItems = actionItems
        self.topics = topics
        self.lastSummarizedStartMs = lastSummarizedStartMs
    }

    /// Backward-compatible decode: pre-existing `summary.state.json` files (written before
    /// `topics` was introduced) have no `topics` key. Defaulting it to `[]` here -- instead of
    /// throwing -- lets `SummaryUpdater`'s `sanitizeState` normalize the rest (id numbering,
    /// reserved-name participant cleanup) without a migration step
    /// (`docs/design/summary-quality-topics-and-final-pass.md` §2.2, §8).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        participants = try container.decode([String].self, forKey: .participants)
        overview = try container.decode(String.self, forKey: .overview)
        decisions = try container.decode([Decision].self, forKey: .decisions)
        actionItems = try container.decode([ActionItem].self, forKey: .actionItems)
        topics = try container.decodeIfPresent([Topic].self, forKey: .topics) ?? []
        lastSummarizedStartMs = try container.decodeIfPresent(Int.self, forKey: .lastSummarizedStartMs)
    }

    /// A single chronological entry in "議事詳細" (`docs/design/summary-quality-topics-and-final-pass.md`
    /// §2.1). Populated incrementally via `SummaryPatch.topicsAdd` / `.topicsUpdate`; never rewritten
    /// wholesale by the session-end final pass (§7.2).
    struct Topic: Codable, Sendable, Equatable {
        /// `"tp_"` + zero-padded sequence number (e.g. `"tp_001"`), same numbering convention as
        /// `ActionItem.id`.
        var id: String
        var heading: String
        var body: String
        var sourceSegIds: [String]
    }

    /// A single confirmed decision. `id` (`"dc_001"` etc.) is the reference key for
    /// `SummaryPatch.decisionsModify` / `.decisionsRemove`
    /// (`docs/design/summary-quality-topics-and-final-pass.md` §2.1).
    struct Decision: Codable, Sendable, Equatable {
        var id: String
        var text: String
        var sourceSegIds: [String]

        // swiftlint:disable:next nesting
        enum CodingKeys: String, CodingKey { // intentional domain nesting, same as `ActionItem.Status`
            case id
            case text
            case sourceSegIds
        }

        init(id: String = "", text: String, sourceSegIds: [String]) {
            self.id = id
            self.text = text
            self.sourceSegIds = sourceSegIds
        }

        /// Backward-compatible decode: pre-existing decisions have no `id` key. `""` means
        /// "not yet numbered" and is filled in by `sanitizeState`'s `dc_00N` numbering pass
        /// (`docs/design/summary-quality-topics-and-final-pass.md` §2.2, §2.3).
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            text = try container.decode(String.self, forKey: .text)
            sourceSegIds = try container.decode([String].self, forKey: .sourceSegIds)
        }
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

        // No explicit `CodingKeys` (no backward-compat gap to bridge here): `source_seg_ids` maps
        // to `sourceSegIds` via `.convertFromSnakeCase` on both persistence paths, same as before
        // `Decision` above grew its own explicit `CodingKeys` for its custom `init(from:)`.
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
