import Foundation
import OSLog

// MARK: - ChatAnswer

/// One completed chat exchange (`docs/design/38-session-chat.md` §3.3).
struct ChatAnswer: Sendable, Equatable {
    var markdown: String
    /// Whether the whole transcript was in reach, or only its tail (§4.5). Shown above the answer
    /// when demoted, and persisted with the turn so a later read still explains a thin answer.
    var contextScope: ChatContextScope
    var usage: LLMUsage
    /// `LLMResult.respondedModel ?? request.model`.
    var model: String
}

// MARK: - ChatRunner

/// Runs one chat question end to end: read the session, budget the context, build the prompt, call
/// the LLM (`docs/design/38-session-chat.md` §3.3).
///
/// **Isolation**: not `@MainActor`, for the same reason `TranscriptMarkdownSource` is not -- building
/// the context resolves a speaker name per segment across every diarization turn, which is segment
/// count × turn count work for a long meeting. `docs/design/13-speaker-diarization.md` §5 records
/// what running that on the main actor did to the UI. No `actor` either: `ask(...)` is a pure
/// function of its arguments plus `Sendable` dependencies, with no mutable state to protect.
struct ChatRunner: Sendable {
    var llm: any LLMCompleting
    var source: TranscriptMarkdownSource
    var config: ChatConfig

    /// Policy-layer prompt body lookup (`docs/design/42-prompt-overrides.md` §4.1/§4.3): override
    /// file content if `prompts/<id>.md` is active, `PromptSpec.defaultBody` otherwise. `ask(...)`
    /// calls this with `.chat` on every send rather than snapshotting it at `init` -- chat's reload
    /// timing is immediate (§5.2: "次の質問送信から即時"), so an edit to `prompts/chat.md` takes
    /// effect on the very next question, unlike the session-start snapshots `RefinementQueue` and
    /// `WatcherRunner` take for their own prompts.
    ///
    /// Defaults to `PromptStore.shared` directly (nonisolated read, safe from this non-`@MainActor`
    /// struct) rather than requiring `MeetingWorkspaceViewModel+Factories.swift` to wire it, the same
    /// default shape `SummaryUpdater.promptBodyProvider` uses for its own immediate-reload prompts.
    var promptBodyProvider: @Sendable (PromptID) -> String = { PromptStore.shared.policyBody(for: .builtin($0)) }

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "ChatRunner")

    /// - Parameter history: every stored turn, unfiltered. Trimming and normalization happen here so
    ///   callers never have to know about `historyTurns` or the alternation rule.
    func ask(
        question: String,
        history: [ChatTurn],
        sessionHandle: SessionHandle
    ) async throws -> ChatAnswer {
        let input = try await source.load(sessionHandle: sessionHandle)
        let normalizedHistory = ChatHistoryNormalizer.normalize(history, maxTurns: config.historyTurns)

        let measured = ChatContextBuilder.measure(input)
        let resolution = ChatContextScope.resolve(
            transcriptLength: measured.transcriptLength,
            summaryLength: measured.summaryLength,
            questionLength: question.count,
            // Measured after normalization: what is sent is what counts against the budget.
            historyLength: normalizedHistory.reduce(0) { $0 + $1.text.count },
            maxContextChars: config.maxContextChars
        )
        let context = ChatContextBuilder.build(input, resolution: resolution)

        let promptInput = ChatPromptBuilder.Input(
            contextMarkdown: context.markdown,
            history: normalizedHistory,
            question: question
        )
        let request = LLMRequest(
            system: promptBodyProvider(.chat),
            user: ChatPromptBuilder.buildUser(promptInput),
            messages: ChatPromptBuilder.buildMessages(promptInput),
            schema: ChatPromptBuilder.answerSchema,
            model: config.model,
            timeout: .seconds(config.timeoutSeconds),
            // Doubles as `LLMUsageRecord.purpose` via `UsageRecordingLLM`, which is what keeps chat
            // cost on its own row in the header badge instead of pooled into `unknown` (CH11).
            stubKey: "chat"
        )

        Self.logger.debug(
            """
            Asking chat (scope=\(context.scope.rawValue, privacy: .public), \
            contextChars=\(context.markdown.count, privacy: .public), \
            historyTurns=\(normalizedHistory.count, privacy: .public))
            """
        )

        let result: LLMResult<ChatAnswerPayload> = try await llm.complete(request)
        return ChatAnswer(
            markdown: result.value.answer,
            contextScope: context.scope,
            usage: result.usage,
            model: result.respondedModel ?? request.model
        )
    }
}
