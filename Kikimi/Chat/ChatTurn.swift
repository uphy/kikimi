import Foundation

// MARK: - ChatRole

/// Who produced a `ChatTurn` (`docs/design/38-session-chat.md` §3.4).
///
/// Distinct from `LLMMessage.Role` on purpose: this one is persisted in `chat.jsonl` and so is part
/// of an on-disk format, while `LLMMessage.Role` is a wire detail of one LLM call. Collapsing them
/// would tie the file format to the LLM layer's shape.
enum ChatRole: String, Codable, Sendable, Equatable {
    case user
    case assistant
}

// MARK: - ChatTurn

/// One line of `chat.jsonl`: a question or an answer (`docs/design/38-session-chat.md` §3.4,
/// CH8/CH9). Append-only, like `transcript.jsonl`/`llm_usage.jsonl` -- a turn is never rewritten,
/// which is why a retried answer arrives as a *new* line carrying `replacesTurnId` rather than an
/// edit of the failed one (CH21).
///
/// The question and its answer are separate lines rather than one round-trip record: when an answer
/// fails, the question still needs to exist on its own so it can be retried.
struct ChatTurn: Codable, Sendable, Equatable, Identifiable {
    /// Minted with `EntryIdNaming.makeId(for:)`, the same shape session/dictation-history ids use.
    var id: String
    var role: ChatRole
    /// The question (`.user`) or the answer's Markdown (`.assistant`). Empty on a failed answer --
    /// `error` carries the reason in that case.
    var text: String
    var createdAt: Date
    /// `.assistant` only: the `.user` turn this answers (CH21). Retries reuse the same value, which
    /// is how `retryChatTurn(id:)` recovers the question to re-ask.
    var parentTurnId: String?
    /// `.assistant` only: the id of the failed answer this one supersedes (CH21). Non-nil only on a
    /// retry; `ChatTurnLog.fold(_:)` uses it to hide the superseded line at display time.
    var replacesTurnId: String?
    /// `.assistant` only. `LLMUsageRecord`, deliberately not `LLMUsage`: `LLMUsage` is not `Codable`
    /// at all, and bolting `Codable` onto it would put `totalCostUSD` through `SessionJSONCoding`'s
    /// `.convertToSnakeCase`/`.convertFromSnakeCase` pair, which is not lossless for a trailing
    /// acronym (encodes `total_cost_usd`, decodes looking for `totalCostUsd`). Being non-optional it
    /// would then throw on decode and take the whole line with it. `LLMUsageRecord` already spells
    /// out the `CodingKeys` that avoid this, and `DictationHistoryEntry.llmUsage` persists it for
    /// the same reason (CH8). `model` lives inside it too.
    var usage: LLMUsageRecord?
    /// `.assistant` only: whether the answer saw the whole transcript or only the tail (§4.5), so a
    /// history read back later still shows why an old answer was thin.
    var contextScope: ChatContextScope?
    /// `.assistant` only. Non-nil marks this turn as a failure (§6); the row then offers a retry.
    var error: String?

    /// No explicit `CodingKeys`. Every field name above is a fixed point of `SessionJSONCoding`'s
    /// snake_case round trip (none ends in an all-caps acronym, the one shape that does not survive
    /// it -- see `LLMUsageRecord`'s own `CodingKeys` comment). Spelling out snake_case raw values
    /// here would double-convert, exactly as `SessionParticipants` documents.
    init(
        id: String,
        role: ChatRole,
        text: String,
        createdAt: Date,
        parentTurnId: String? = nil,
        replacesTurnId: String? = nil,
        usage: LLMUsageRecord? = nil,
        contextScope: ChatContextScope? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.parentTurnId = parentTurnId
        self.replacesTurnId = replacesTurnId
        self.usage = usage
        self.contextScope = contextScope
        self.error = error
    }
}

// MARK: - ChatTurnLog

/// Turns the append-only `chat.jsonl` into the list the UI shows (`docs/design/38-session-chat.md`
/// §3.4, CH21).
enum ChatTurnLog {
    /// Drops every turn that a later turn's `replacesTurnId` supersedes.
    ///
    /// Without this, reopening a window after a successful retry would show both the failed answer
    /// and its replacement -- the file legitimately contains both, since nothing is ever rewritten.
    /// Folding at read time keeps "append only" and "no duplicates on screen" from being in
    /// conflict.
    ///
    /// Order is preserved as-read and never re-sorted by `createdAt`: append order is the only total
    /// order the file guarantees, and two turns written within the same second would otherwise be
    /// free to swap places.
    ///
    /// A failed answer that has *not* been retried survives here (the user still needs the retry
    /// button); it is `ChatHistoryNormalizer`'s job to keep it out of the next prompt.
    static func fold(_ turns: [ChatTurn]) -> [ChatTurn] {
        let superseded = Set(turns.compactMap(\.replacesTurnId))
        guard !superseded.isEmpty else { return turns }
        return turns.filter { !superseded.contains($0.id) }
    }
}
