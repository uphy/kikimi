import Foundation

// MARK: - MeetingWorkspaceViewModel + Chat tab
//
// `docs/design/38-session-chat.md` §3.6. Only methods live here: Swift extensions cannot add stored
// properties, so `chatTurns`/`isChatResponding`/`chatDraft`/`chatCopyFeedbackTurnId` are declared in
// `MeetingWorkspaceViewModel.swift` itself, the same split every other `+*.swift` file in this
// directory follows.

extension MeetingWorkspaceViewModel {
    /// See `chatRunner`'s doc comment for why this is built once at `init` rather than lazily.
    typealias ChatRunnerFactory = @MainActor (SessionHandle) -> ChatRunner

    /// Reads `chat.jsonl` and folds away answers a retry has superseded (CH21). Called from
    /// `onAppear()`.
    ///
    /// A read failure leaves the history empty and logs: the chat tab still works, the user just
    /// starts from a blank slate this session. `readChatTurns()` already tolerates individual
    /// corrupt lines on its own.
    func loadChatHistory() async {
        do {
            chatTurns = ChatTurnLog.fold(try await sessionHandle.readChatTurns())
        } catch {
            logger.warning("Failed to read chat.jsonl for \(self.sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sends `chatDraft` and appends both the question and the answer to the history.
    func sendChatMessage() async {
        let question = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isChatResponding else { return }

        let userTurn = ChatTurn(id: EntryIdNaming.makeId(for: now()), role: .user, text: question, createdAt: now())
        // Persisted before the call, not after it: a crash or a quit while waiting for the answer
        // must not lose what the user typed. Same reasoning as `transcript.jsonl` being appended per
        // confirmed segment rather than at the end.
        await appendChatTurn(userTurn)
        chatDraft = ""

        await runChatTurn(question: question, parentTurnId: userTurn.id, replacesTurnId: nil)
    }

    /// Re-asks the question behind a failed answer (§3.6/CH21).
    ///
    /// - Parameter id: the **failed assistant turn**'s id, not the question's.
    func retryChatTurn(id: String) async {
        guard !isChatResponding,
              let failed = chatTurns.first(where: { $0.id == id }),
              let parentTurnId = failed.parentTurnId,
              let question = chatTurns.first(where: { $0.id == parentTurnId })?.text
        else { return }

        await runChatTurn(question: question, parentTurnId: parentTurnId, replacesTurnId: id)
    }

    /// Discards this session's chat history, on screen and on disk.
    ///
    /// Refused while an answer is in flight: that call is going to append its result when it lands,
    /// which would resurrect a history the user just cleared. The UI disables the control for the
    /// same reason, so this guard only covers the race.
    func clearChatHistory() async {
        guard !isChatResponding else { return }

        chatTurns = []
        chatCopyFeedbackTurnId = nil
        do {
            try await sessionHandle.deleteChatTurns()
        } catch {
            // The screen is already cleared, which is what was asked for. A failed delete only means
            // the history comes back on the next open -- worth logging, not worth refusing the
            // action the user took.
            logger.error("Failed to delete chat.jsonl for \(self.sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copies one answer's Markdown, reusing design 37's injected `PasteboardWriting`.
    func copyChatAnswer(id: String) {
        guard let turn = chatTurns.first(where: { $0.id == id }), !turn.text.isEmpty else { return }
        guard pasteboard.writeString(turn.text) else {
            logger.error("Failed to copy chat answer \(id, privacy: .public) to the pasteboard")
            return
        }
        chatCopyFeedbackTurnId = id
    }

    // MARK: - Private

    /// The shared send/retry body: call the runner, then record the outcome as an assistant turn --
    /// a successful one carrying usage and scope, a failed one carrying `error` so the row can offer
    /// a retry. Both are appended, never rewritten, which is what keeps `chat.jsonl` append-only
    /// (CH8/CH9).
    private func runChatTurn(question: String, parentTurnId: String, replacesTurnId: String?) async {
        isChatResponding = true
        defer { isChatResponding = false }

        let runner = chatRunner
        let handle = sessionHandle
        let turns = chatTurns
        let modelOverride = chatModelOverride
        let answerTurn: ChatTurn
        do {
            let answer = try await runner.ask(question: question, history: turns, sessionHandle: handle, modelOverride: modelOverride)
            answerTurn = ChatTurn(
                id: EntryIdNaming.makeId(for: now()),
                role: .assistant,
                text: answer.markdown,
                createdAt: now(),
                parentTurnId: parentTurnId,
                replacesTurnId: replacesTurnId,
                usage: LLMUsageRecord.make(
                    usage: answer.usage,
                    // `ChatAnswer.model` already resolved responded-vs-requested, so the factory's
                    // own fallback has nothing left to choose between.
                    respondedModel: nil,
                    requestedModel: answer.model,
                    purpose: "chat",
                    timestamp: now()
                ),
                contextScope: answer.contextScope
            )
        } catch {
            logger.error("Chat call failed for \(self.sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            answerTurn = ChatTurn(
                id: EntryIdNaming.makeId(for: now()),
                role: .assistant,
                text: "",
                createdAt: now(),
                parentTurnId: parentTurnId,
                replacesTurnId: replacesTurnId,
                error: error.localizedDescription
            )
        }

        await appendChatTurn(answerTurn)
    }

    /// Appends to both the on-screen history and `chat.jsonl`, applying the same fold rule the
    /// reload path uses so a retry's superseded failure disappears from the list immediately rather
    /// than only after the window is reopened.
    ///
    /// A write failure does not roll back the on-screen turn: the answer is right there and worth
    /// more than the guarantee that the next launch will still have it (§5).
    private func appendChatTurn(_ turn: ChatTurn) async {
        chatTurns = ChatTurnLog.fold(chatTurns + [turn])
        do {
            try await sessionHandle.appendChatTurn(turn)
        } catch {
            logger.error("Failed to append to chat.jsonl for \(self.sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
