import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `ChatPromptBuilder` (`docs/design/38-session-chat.md` §7). Entirely pure --
/// no `SessionHandle`, no LLM, no config.
@Suite("ChatPromptBuilder")
struct ChatPromptBuilderTests {
    private func makeTurn(_ role: ChatRole, _ text: String, id: String = UUID().uuidString) -> ChatTurn {
        ChatTurn(id: id, role: role, text: text, createdAt: Date(timeIntervalSince1970: 1_751_000_000))
    }

    private func makeInput(history: [ChatTurn] = [], question: String = "決まったことは？") -> ChatPromptBuilder.Input {
        ChatPromptBuilder.Input(contextMarkdown: "# 定例MTG\n\n## 書き起こし\n\n本文", history: history, question: question)
    }

    // MARK: - (a) buildUser carries the question alone

    @Test("buildUser returns only the question, never the context or the history")
    func buildUserReturnsQuestionOnly() {
        let input = makeInput(history: [makeTurn(.user, "前半の論点は？"), makeTurn(.assistant, "価格と納期")])

        let user = ChatPromptBuilder.buildUser(input)

        #expect(user == "決まったことは？")
        #expect(!user.contains("定例MTG"), "the meeting record belongs to buildMessages, not here")
        #expect(!user.contains("前半の論点は？"), "prior turns belong to buildMessages, not here")
    }

    // MARK: - (b) buildMessages shape

    @Test("buildMessages returns [user(context), assistant(ack)] when there is no history")
    func buildMessagesWithoutHistory() {
        let messages = ChatPromptBuilder.buildMessages(makeInput())

        #expect(messages.count == 2)
        #expect(messages[0] == LLMMessage(role: .user, text: "# 定例MTG\n\n## 書き起こし\n\n本文"))
        #expect(messages[1] == LLMMessage(role: .assistant, text: ChatPromptBuilder.contextAcknowledgement))
    }

    @Test("buildMessages appends history after the context pair, keeping roles alternating")
    func buildMessagesWithHistoryAlternates() {
        let history = [
            makeTurn(.user, "前半の論点は？"),
            makeTurn(.assistant, "価格と納期"),
            makeTurn(.user, "価格の結論は？"),
            makeTurn(.assistant, "据え置き")
        ]

        let messages = ChatPromptBuilder.buildMessages(makeInput(history: history))

        #expect(messages.count == 6)
        #expect(messages.count.isMultiple(of: 2), "an odd length would break the alternation some backends require")
        #expect(messages.first?.role == .user)
        #expect(messages.map(\.role) == [.user, .assistant, .user, .assistant, .user, .assistant])
        #expect(messages[2].text == "前半の論点は？")
        #expect(messages[5].text == "据え置き")
        #expect(!messages.contains { $0.text == "決まったことは？" }, "the latest question is buildUser's job")
    }

    @Test("buildMessages puts the meeting record first so the cacheable prefix survives history churn")
    func buildMessagesKeepsContextFirst() {
        let withoutHistory = ChatPromptBuilder.buildMessages(makeInput())
        let withHistory = ChatPromptBuilder.buildMessages(
            makeInput(history: [makeTurn(.user, "q"), makeTurn(.assistant, "a")])
        )

        #expect(Array(withHistory.prefix(2)) == withoutHistory, "adding turns must not disturb the first two messages")
    }

    // MARK: - (c) schema

    @Test("answerSchema is valid JSON declaring a required string answer field")
    func answerSchemaIsValid() throws {
        let data = try #require(ChatPromptBuilder.answerSchema.data(using: .utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["type"] as? String == "object")
        let properties = try #require(json["properties"] as? [String: Any])
        let answer = try #require(properties["answer"] as? [String: Any])
        #expect(answer["type"] as? String == "string")
        #expect(json["required"] as? [String] == ["answer"])
    }

    @Test("a schema-shaped response decodes into ChatAnswerPayload")
    func answerSchemaRoundTripsIntoPayload() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(
            ChatAnswerPayload.self,
            // `###"..."###`: the payload contains `"##` (a quoted Markdown heading), which would
            // close a `#`- or `##`-delimited raw literal early.
            from: Data(###"{"answer": "## 決定事項\n- リリースは来週火曜"}"###.utf8)
        )

        #expect(payload.answer.hasPrefix("## 決定事項"))
    }

    // MARK: - (d) system prompt rules

    @Test("buildSystem states the no-guessing rule, the raw marker, and the no-mermaid rule")
    func buildSystemStatesTheRules() {
        let system = ChatPromptBuilder.buildSystem()

        #expect(system.contains("推測"), "the transcript is ASR output; filling gaps plausibly produces confident wrong answers")
        #expect(system.contains("読み取れない"))
        #expect(system.contains("*(raw)*"))
        #expect(system.contains("mermaid"), "MarkdownUI cannot render mermaid (CH6)")
        #expect(system.contains("HH:MM:SS"))
    }
}
