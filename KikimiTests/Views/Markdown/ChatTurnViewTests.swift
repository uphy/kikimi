import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `ChatTurnView` (`docs/design/39-webview-markdown.md` §8.1): the projection
/// from `chat.jsonl`'s on-disk shape to what the page is handed.
@Suite("ChatTurnView")
struct ChatTurnViewTests {
    private func makeTurn(
        id: String = "turn-1",
        role: ChatRole = .assistant,
        text: String = "答え",
        error: String? = nil,
        contextScope: ChatContextScope? = nil
    ) -> ChatTurn {
        ChatTurn(
            id: id,
            role: role,
            text: text,
            createdAt: Date(timeIntervalSince1970: 1_751_000_000),
            contextScope: contextScope,
            error: error
        )
    }

    @Test("the display fields carry over, with the role as its raw value")
    func mapping() {
        let view = ChatTurnView(turn: makeTurn(id: "a1", role: .user, text: "質問です"))

        #expect(view.id == "a1")
        #expect(view.role == "user")
        #expect(view.text == "質問です")
        #expect(view.createdAt == 1_751_000_000)
    }

    @Test("a failed answer carries its reason so the page can offer a retry")
    func failedAnswer() {
        let view = ChatTurnView(turn: makeTurn(text: "", error: "timeout"))

        #expect(view.error == "timeout")
        #expect(view.payload["error"] as? String == "timeout")
    }

    @Test("contextScope crosses as its raw value, which is what drives the demotion note")
    func contextScope() {
        #expect(ChatTurnView(turn: makeTurn(contextScope: .summaryAndRecent)).contextScope == "summaryAndRecent")
        #expect(ChatTurnView(turn: makeTurn(contextScope: .full)).contextScope == "full")
        #expect(ChatTurnView(turn: makeTurn(contextScope: nil)).contextScope == nil)
    }

    @Test("nil fields are omitted from the payload rather than sent as null")
    func payloadOmitsNilFields() {
        let payload = ChatTurnView(turn: makeTurn()).payload

        #expect(payload["error"] == nil)
        #expect(payload["contextScope"] == nil)
        // The four always-present keys, and nothing else: `parentTurnId` / `replacesTurnId` / `usage`
        // are bookkeeping the page has no use for.
        #expect(Set(payload.keys) == ["id", "role", "text", "createdAt"])
    }

    @Test("bookkeeping fields never reach the page")
    func bookkeepingIsNotProjected() {
        var turn = makeTurn()
        turn.parentTurnId = "q1"
        turn.replacesTurnId = "a0"
        turn.usage = LLMUsageRecord(
            timestamp: Date(timeIntervalSince1970: 1_751_000_000),
            purpose: "chat",
            model: "claude-haiku-4-5-20251001",
            inputTokens: 10,
            outputTokens: 20,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            reportedCostUSD: 0.01
        )

        let payload = ChatTurnView(turn: turn).payload

        #expect(payload["parentTurnId"] == nil)
        #expect(payload["replacesTurnId"] == nil)
        #expect(payload["usage"] == nil)
    }
}
