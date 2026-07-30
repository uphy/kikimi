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

    /// The system prompt: role, how far the transcript can be trusted, and the output rules.
    ///
    /// The "do not guess" rule is the important one. A transcript is speech recognition plus LLM
    /// refinement, so mishearings and misattributed speakers are normal; a model that fills gaps
    /// plausibly produces answers that read as confident and are wrong about who said what.
    ///
    /// The instruction that steered diagrams to tables and lists (CH6) is gone: the chat history is
    /// rendered by `ChatWebView` now, which draws mermaid (`docs/design/39-webview-markdown.md`).
    /// Keeping that restriction in the prompt rather than in the view is what made removing it a
    /// one-line change, as CH6 intended.
    static func buildSystem() -> String {
        """
        あなたは、ある会議の書き起こしについて質問に答えるアシスタントです。与えられた会議の記録だけを\
        根拠に、簡潔に答えてください。

        書き起こしの性質:

        - 音声認識と LLM 整形を経ているため、誤変換・話者の取り違えがあり得ます
        - `*(raw)*` が付いた行は未整形の生テキストです
        - 記録から読み取れないことは推測で埋めず、「書き起こしからは読み取れない」と答えてください

        回答の形式:

        - Markdown で書いてください
        - 図で示したほうが分かりやすいときは mermaid のコードブロックを使ってください
        - 発言を引用するときは `HH:MM:SS` と話者名を添えてください
        """
    }

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
