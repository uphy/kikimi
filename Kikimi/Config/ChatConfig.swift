import Foundation
import OSLog

// MARK: - ChatConfig

/// `chat:` section of `config.yaml` (`docs/design/38-session-chat.md` §6/CH10). Drives `ChatRunner`'s
/// model, context budget, how much conversation history rides along in each prompt, and the per-call
/// timeout.
///
/// A section of its own rather than a couple of constants because model choice is a real user
/// decision here: the default is Haiku (cheap enough to ask a long meeting ten questions), but
/// "summarize this two-hour meeting from the transcript" is exactly the kind of question someone
/// will want to point a smarter model at.
struct ChatConfig: Codable, Equatable, Sendable {
    /// `chat.model`.
    var model: String
    /// `chat.max_context_chars`: the whole prompt's character budget -- transcript, summary,
    /// question, and the conversation history that rides along, not the transcript alone
    /// (§3.2/CH3). Exceeding it demotes the transcript to `.summaryAndRecent`.
    ///
    /// Measured in characters, not tokens: token counts are not knowable client-side.
    var maxContextChars: Int
    /// `chat.history_turns`: how many prior turns (user + assistant counted separately) are put in
    /// the prompt. The screen keeps the full history regardless -- this only bounds what is re-sent
    /// (CH4). Normalized down to whole (user, assistant) pairs by `ChatHistoryNormalizer`.
    var historyTurns: Int
    /// `chat.timeout_seconds`: passed to `LLMRequest.timeout`, overriding its 60-second default
    /// (CH19). That default was chosen for consumers that send batch-sized prompts; chat's input is
    /// an order of magnitude larger and additionally pays the `claude` CLI's startup time.
    var timeoutSeconds: Int

    enum CodingKeys: String, CodingKey {
        case model
        case maxContextChars = "max_context_chars"
        case historyTurns = "history_turns"
        case timeoutSeconds = "timeout_seconds"
    }

    /// The exact defaults documented in design 38 §6.
    ///
    /// `maxContextChars` 120,000 is roughly 100k tokens for Japanese text, leaving room inside
    /// Claude's 200k context for the answer. A one-hour meeting's refined transcript runs 30-40k
    /// characters, so an ordinary meeting never demotes. `timeoutSeconds` 180 is provisional --
    /// design §4.3's implementation spike measures a real `.full` call and adjusts it.
    static let `default` = ChatConfig(
        model: "claude-haiku-4-5-20251001",
        maxContextChars: 120_000,
        historyTurns: 6,
        timeoutSeconds: 180
    )

    init(model: String, maxContextChars: Int, historyTurns: Int, timeoutSeconds: Int) {
        self.model = model
        self.maxContextChars = maxContextChars
        self.historyTurns = historyTurns
        self.timeoutSeconds = timeoutSeconds
    }

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "ChatConfig")

    /// Custom decoder mirroring `WatchersConfig.init(from:)`: a partial (or absent) `chat:` section
    /// fills every missing field from `.default` rather than failing the whole `config.yaml` decode.
    /// The three numeric fields additionally fall back to their default with a `.warning` when set to
    /// zero or below, the same guard `RefinementConfig`/`DictationConfig` apply -- a
    /// `history_turns: 0` would silently make every question context-free, and a
    /// `timeout_seconds: 0` would fail every call instantly.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.default.model
        maxContextChars = Self.positiveOrDefault(
            try container.decodeIfPresent(Int.self, forKey: .maxContextChars),
            default: Self.default.maxContextChars,
            key: "chat.max_context_chars"
        )
        historyTurns = Self.positiveOrDefault(
            try container.decodeIfPresent(Int.self, forKey: .historyTurns),
            default: Self.default.historyTurns,
            key: "chat.history_turns"
        )
        timeoutSeconds = Self.positiveOrDefault(
            try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds),
            default: Self.default.timeoutSeconds,
            key: "chat.timeout_seconds"
        )
    }

    private static func positiveOrDefault(_ decoded: Int?, default defaultValue: Int, key: String) -> Int {
        guard let decoded else { return defaultValue }
        guard decoded > 0 else {
            logger.warning(
                "\(key, privacy: .public)=\(decoded, privacy: .public) must be > 0; falling back to \(defaultValue, privacy: .public)"
            )
            return defaultValue
        }
        return decoded
    }
}
