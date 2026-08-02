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
    /// Session-start snapshot of `ModelResolver.resolve(candidates: [config.model], ...)`
    /// (`docs/design/44-llm-model-config.md` §7). `defaultChatRunnerFactory`
    /// (`MeetingWorkspaceViewModel+Factories.swift`) passes the real resolved value; `init` derives a
    /// fallback straight from `config.model` under the builtin provider when omitted (mirrors
    /// `RefinementQueue.resolvedModel`'s doc comment), so every existing test call site that never
    /// passes this parameter keeps building the same `LLMRequest.model` it did before this field
    /// existed. Phase 2's manual chat model picker (§8) will override this per-question -- out of
    /// scope here.
    var resolvedModel: ResolvedModel

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

    init(
        llm: any LLMCompleting,
        source: TranscriptMarkdownSource,
        config: ChatConfig,
        resolvedModel: ResolvedModel? = nil,
        promptBodyProvider: @escaping @Sendable (PromptID) -> String = { PromptStore.shared.policyBody(for: .builtin($0)) }
    ) {
        self.llm = llm
        self.source = source
        self.config = config
        self.resolvedModel = resolvedModel ?? ResolvedModel(provider: ModelResolver.builtinProviderName, model: config.model)
        self.promptBodyProvider = promptBodyProvider
    }

    /// - Parameter history: every stored turn, unfiltered. Trimming and normalization happen here so
    ///   callers never have to know about `historyTurns` or the alternation rule.
    /// - Parameter modelOverride: The チャット tab's small model picker (`docs/design/44-llm-model-config.md`
    ///   §8), resolved at click/selection time by the caller (`MeetingWorkspaceViewModel`'s session-only
    ///   `chatModelOverride`, never persisted). `nil` (every pre-existing call site) keeps using
    ///   `resolvedModel` exactly as before this parameter existed.
    func ask(
        question: String,
        history: [ChatTurn],
        sessionHandle: SessionHandle,
        modelOverride: ResolvedModel? = nil
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
            resolved: modelOverride ?? resolvedModel,
            // `config.timeoutSeconds` is chat's own "機能側の基底値" (`docs/design/44-llm-model-config.md`
            // §3.3/§7) -- the extended-only max rule still lets a `resolvedModel` with a longer
            // `params.timeoutSeconds` (e.g. a `premium` alias) wait longer than 180s, never shorter.
            functionDefaultSeconds: config.timeoutSeconds,
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
