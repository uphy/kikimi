import Foundation

// MARK: - ChatPromptBuilder

/// Assembles one chat call's prompt (`docs/design/38-session-chat.md` §3.1/§4.2). Pure, in the same
/// style as `WatcherPromptBuilder`: no I/O, no config reads, only the values it is handed.
///
/// `buildUser(_:)` and `buildMessages(_:)` are always used together, and neither decides on its own
/// where the context or the history goes -- §4.2's ordering is written down in `buildMessages(_:)`
/// and nowhere else, so `ChatRunner` just drops both results into an `LLMRequest`.
enum ChatPromptBuilder {
    /// One send's worth of input.
    struct Input: Sendable, Equatable {
        /// `ChatContextBuilder`'s output: the finished meeting record, `# タイトル` included.
        var contextMarkdown: String
        /// Oldest first, already through `ChatHistoryNormalizer` (even length, alternating).
        var history: [ChatTurn]
        var question: String
    }

    /// Fixed dummy answer sitting at `messages[1]`, acknowledging the meeting record so the
    /// conversation reads as user/assistant/user/... from the start (§4.2/CH22).
    static let contextAcknowledgement = "会議の記録を読みました。質問をどうぞ。"

    /// One-field wrapper schema (CH5). Every existing path goes through `--json-schema` and
    /// `LLMRequest.schema` is not optional, so a free-form Markdown answer is boxed rather than a
    /// new unstructured route being opened up.
    static let answerSchema = """
    {"type":"object","properties":{"answer":{"type":"string","description":"回答の Markdown 本文"}},"required":["answer"]}
    """

    // The system prompt (role, how far the transcript can be trusted, the output rules) used to
    // live here as `buildSystem()`. It is now the chat prompt's policy-layer default body,
    // `PromptSpec.spec(for: .chat).defaultBody` (`Kikimi/Prompts/`,
    // `docs/design/42-prompt-overrides.md` §4.2/§4.3): `ChatRunner` reads it (or a
    // `prompts/chat.md` override, immediate) through `promptBodyProvider` and hands the result to
    // `LLMRequest.system` itself, so this builder no longer owns any system-prompt text.
    //
    // `buildUser(_:)` and `buildMessages(_:)` below are unaffected -- they build the non-system
    // parts of the request, which stay fixed regardless of prompt overrides.

    /// `LLMRequest.user`: the latest question and nothing else. The context and the history belong
    /// to `buildMessages(_:)`.
    static func buildUser(_ input: Input) -> String {
        input.question
    }

    /// `LLMRequest.messages`: `[user(context), assistant(ack)] + history` (§4.2). Always even-length,
    /// alternating, `.user` first. The latest question is not here -- that is `buildUser(_:)`.
    ///
    /// The big, slow-changing block goes first and the per-turn additions after it. The first draft
    /// had it the other way round, which puts a growing block ahead of the transcript and breaks the
    /// cacheable prefix on every single turn. In this order, dropping old turns at the
    /// `historyTurns` boundary leaves the first two messages byte-identical.
    static func buildMessages(_ input: Input) -> [LLMMessage] {
        var messages = [
            LLMMessage(role: .user, text: input.contextMarkdown),
            LLMMessage(role: .assistant, text: contextAcknowledgement)
        ]
        for turn in input.history {
            messages.append(LLMMessage(role: turn.role == .user ? .user : .assistant, text: turn.text))
        }
        return messages
    }
}

// MARK: - ChatAnswerPayload

/// `answerSchema`'s decoded shape.
struct ChatAnswerPayload: Decodable, Sendable, Equatable {
    var answer: String
}
