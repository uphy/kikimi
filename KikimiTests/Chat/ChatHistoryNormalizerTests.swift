import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `ChatHistoryNormalizer` (`docs/design/38-session-chat.md` §7). The point of
/// every case here is the same invariant: whatever the stored log looks like, what reaches the
/// prompt alternates.
@Suite("ChatHistoryNormalizer")
struct ChatHistoryNormalizerTests {
    private func makeTurn(
        _ id: String,
        _ role: ChatRole,
        _ text: String,
        error: String? = nil
    ) -> ChatTurn {
        ChatTurn(
            id: id,
            role: role,
            text: text,
            createdAt: Date(timeIntervalSince1970: 1_751_000_000),
            error: error
        )
    }

    private func assertAlternating(_ turns: [ChatTurn], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(turns.count.isMultiple(of: 2), "must be even-length", sourceLocation: sourceLocation)
        #expect(turns.first?.role == .user || turns.isEmpty, "must start with .user", sourceLocation: sourceLocation)
        #expect(turns.last?.role == .assistant || turns.isEmpty, "must end with .assistant", sourceLocation: sourceLocation)
        for (index, turn) in turns.enumerated() {
            let expected: ChatRole = index.isMultiple(of: 2) ? .user : .assistant
            #expect(turn.role == expected, "role at \(index) must be \(expected)", sourceLocation: sourceLocation)
        }
    }

    @Test("a clean alternating log passes through unchanged")
    func cleanHistoryPassesThrough() {
        let turns = [
            makeTurn("u1", .user, "q1"),
            makeTurn("a1", .assistant, "a1"),
            makeTurn("u2", .user, "q2"),
            makeTurn("a2", .assistant, "a2")
        ]

        let normalized = ChatHistoryNormalizer.normalize(turns, maxTurns: 6)

        #expect(normalized.map(\.id) == ["u1", "a1", "u2", "a2"])
        assertAlternating(normalized)
    }

    // MARK: - (a) failures do not leave two users adjacent

    @Test("a failed answer drops with its question, so no two user turns end up adjacent")
    func failedAnswersDropWithTheirQuestion() {
        let turns = [
            makeTurn("u1", .user, "q1"),
            makeTurn("a1", .assistant, "", error: "timed out"),
            makeTurn("u2", .user, "q2"),
            makeTurn("a2", .assistant, "answer 2")
        ]

        let normalized = ChatHistoryNormalizer.normalize(turns, maxTurns: 6)

        #expect(normalized.map(\.id) == ["u2", "a2"])
        #expect(!normalized.contains { $0.error != nil }, "a failure must not shape the next answer")
        assertAlternating(normalized)
    }

    // MARK: - (b) unanswered questions drop

    @Test("a question whose answer never arrived is dropped")
    func unansweredQuestionsDrop() {
        // What the log looks like after a crash (or a window close) mid-answer.
        let turns = [
            makeTurn("u1", .user, "q1"),
            makeTurn("u2", .user, "q2"),
            makeTurn("a2", .assistant, "answer 2")
        ]

        let normalized = ChatHistoryNormalizer.normalize(turns, maxTurns: 6)

        #expect(normalized.map(\.id) == ["u2", "a2"])
        assertAlternating(normalized)
    }

    @Test("a trailing unanswered question is dropped rather than left dangling")
    func trailingUnansweredQuestionDrops() {
        let turns = [
            makeTurn("u1", .user, "q1"),
            makeTurn("a1", .assistant, "a1"),
            makeTurn("u2", .user, "in flight")
        ]

        let normalized = ChatHistoryNormalizer.normalize(turns, maxTurns: 6)

        #expect(normalized.map(\.id) == ["u1", "a1"])
        assertAlternating(normalized)
    }

    @Test("an answer with no preceding question is ignored")
    func orphanAnswerIsIgnored() {
        let turns = [
            makeTurn("a0", .assistant, "orphan"),
            makeTurn("u1", .user, "q1"),
            makeTurn("a1", .assistant, "a1")
        ]

        let normalized = ChatHistoryNormalizer.normalize(turns, maxTurns: 6)

        #expect(normalized.map(\.id) == ["u1", "a1"])
        assertAlternating(normalized)
    }

    // MARK: - (c)/(d) maxTurns

    @Test("maxTurns keeps the newest pairs and counts turns, not pairs")
    func maxTurnsKeepsNewestPairs() {
        let turns = (1...5).flatMap { index in
            [makeTurn("u\(index)", .user, "q\(index)"), makeTurn("a\(index)", .assistant, "a\(index)")]
        }

        let normalized = ChatHistoryNormalizer.normalize(turns, maxTurns: 6)

        #expect(normalized.count == 6)
        #expect(normalized.map(\.id) == ["u3", "a3", "u4", "a4", "u5", "a5"])
        assertAlternating(normalized)
    }

    @Test("an odd maxTurns rounds down rather than breaking alternation")
    func oddMaxTurnsRoundsDown() {
        let turns = (1...3).flatMap { index in
            [makeTurn("u\(index)", .user, "q\(index)"), makeTurn("a\(index)", .assistant, "a\(index)")]
        }

        let normalized = ChatHistoryNormalizer.normalize(turns, maxTurns: 5)

        #expect(normalized.count == 4, "5 turns would have to start on an assistant")
        #expect(normalized.map(\.id) == ["u2", "a2", "u3", "a3"])
        assertAlternating(normalized)
    }

    @Test("maxTurns below one pair yields an empty history")
    func tinyMaxTurnsYieldsNothing() {
        let turns = [makeTurn("u1", .user, "q1"), makeTurn("a1", .assistant, "a1")]

        #expect(ChatHistoryNormalizer.normalize(turns, maxTurns: 1).isEmpty)
        #expect(ChatHistoryNormalizer.normalize(turns, maxTurns: 0).isEmpty)
    }

    @Test("an empty log normalizes to an empty history")
    func emptyHistoryStaysEmpty() {
        #expect(ChatHistoryNormalizer.normalize([], maxTurns: 6).isEmpty)
    }
}
