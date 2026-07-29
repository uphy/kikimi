import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `ChatTurnLog.fold(_:)` (`docs/design/38-session-chat.md` §7/CH21): the file
/// keeps both a failed answer and its retry, and this is what stops the screen from showing both.
@Suite("ChatTurnLog")
struct ChatTurnLogTests {
    private func makeTurn(
        _ id: String,
        _ role: ChatRole,
        _ text: String,
        parentTurnId: String? = nil,
        replacesTurnId: String? = nil,
        error: String? = nil
    ) -> ChatTurn {
        ChatTurn(
            id: id,
            role: role,
            text: text,
            createdAt: Date(timeIntervalSince1970: 1_751_000_000),
            parentTurnId: parentTurnId,
            replacesTurnId: replacesTurnId,
            error: error
        )
    }

    @Test("a retried answer hides the failure it replaced")
    func retryFoldsTheReplacedFailure() {
        let turns = [
            makeTurn("u1", .user, "q1"),
            makeTurn("a1", .assistant, "", parentTurnId: "u1", error: "timed out"),
            makeTurn("a2", .assistant, "answer", parentTurnId: "u1", replacesTurnId: "a1")
        ]

        let folded = ChatTurnLog.fold(turns)

        #expect(folded.map(\.id) == ["u1", "a2"])
        #expect(folded.count == 2, "the question must survive; only the superseded answer goes")
    }

    @Test("a failure that has not been retried stays visible")
    func unretriedFailureSurvives() {
        let turns = [
            makeTurn("u1", .user, "q1"),
            makeTurn("a1", .assistant, "", parentTurnId: "u1", error: "timed out")
        ]

        #expect(ChatTurnLog.fold(turns).map(\.id) == ["u1", "a1"])
    }

    @Test("fold preserves append order rather than re-sorting by createdAt")
    func foldPreservesAppendOrder() {
        // Same-second timestamps: sorting by `createdAt` could legitimately swap these, so append
        // order is the only total order to trust.
        let turns = [
            makeTurn("u1", .user, "q1"),
            makeTurn("a1", .assistant, "a1", parentTurnId: "u1"),
            makeTurn("u2", .user, "q2"),
            makeTurn("a2", .assistant, "a2", parentTurnId: "u2")
        ]

        #expect(ChatTurnLog.fold(turns).map(\.id) == ["u1", "a1", "u2", "a2"])
    }

    @Test("a second retry folds away the first retry as well")
    func repeatedRetriesFoldTransitively() {
        let turns = [
            makeTurn("u1", .user, "q1"),
            makeTurn("a1", .assistant, "", parentTurnId: "u1", error: "first failure"),
            makeTurn("a2", .assistant, "", parentTurnId: "u1", replacesTurnId: "a1", error: "second failure"),
            makeTurn("a3", .assistant, "answer", parentTurnId: "u1", replacesTurnId: "a2")
        ]

        #expect(ChatTurnLog.fold(turns).map(\.id) == ["u1", "a3"])
    }

    @Test("an empty log folds to an empty list")
    func emptyLogFoldsToEmpty() {
        #expect(ChatTurnLog.fold([]).isEmpty)
    }
}
