import Foundation
import OSLog

// MARK: - DictationRefinedText

/// Minimal structured-output type for `DictationRefiner`'s single-shot LLM call
/// (`docs/design/25-dictation-mode.md` R9/§3.4). Kept to one field so the prompt/response stays
/// small -- this is a per-utterance call, not a batch, so there is no prompt-caching benefit to
/// amortize a larger schema over.
struct DictationRefinedText: Codable, Sendable {
    var refinedText: String
}

// MARK: - DictationRefinerSchema

enum DictationRefinerSchema {
    /// Schema for `DictationRefinedText`, handed to `LLMRequest.schema`.
    static let json = """
    {"type":"object","properties":{"refined_text":{"type":"string"}},"required":["refined_text"],"additionalProperties":false}
    """
}

// MARK: - DictationRefineOutcome

/// Result of `DictationRefiner.refine` (`docs/design/29-dictation-history.md` §4.3, DH4). Replaces
/// the old bare `String` return so callers can tell success from fallback and record usage/model/
/// failure reason for the dictation history (design 29) and learning-mode correction log
/// (design 27 §5.1's `refinedSuccessfully` requirement, satisfied here by `succeeded`).
struct DictationRefineOutcome: Sendable {
    /// The text to insert. Falls back to `rawText` unchanged on any failure (R9 preserved).
    var text: String
    /// `nil` when refinement failed (fell back) -- usage is unobtainable for failed calls.
    var usage: LLMUsage?
    /// The model that actually responded (`LLMResult.respondedModel` ?? requested model). `nil` on
    /// failure, since there was no response to report a model from.
    var model: String?
    /// Human-readable failure description when the call fell back; `nil` on success. Same string as
    /// the existing warning log (`String(describing: error)`) -- this is the `refine_error` field's
    /// source (design 29).
    var failure: String?

    var succeeded: Bool { failure == nil }
}

// MARK: - DictationRefiner

/// D2's single-shot, low-latency LLM post-processing step (`docs/design/25-dictation-mode.md` R9).
/// Deliberately bypasses `RefinementQueue` (batch, serial, prompt-cached) -- dictation is one
/// utterance per call with no batching opportunity, and the design doc explicitly rules out
/// reusing that path.
///
/// Any failure mode (timeout, offline, decode error, LLM error) falls back to `rawText` unchanged
/// (kikimi.md 8.5 章's backpressure/fallback philosophy: never drop the dictated text).
struct DictationRefiner: Sendable {
    /// Fixed preamble, kept as a constant literal so the LLM's structured-output contract can never
    /// be edited away by a user rewriting `dictation.context.global` (R17,
    /// `docs/design/25-dictation-mode.md` §14.4). The actual filler-removal/punctuation/grammatical
    /// gap-filling rule body used to live here as part of a single `systemPrompt` constant; R17
    /// promoted that body to `DictationContextConfig.default.global` so it round-trips through
    /// `config.yaml` and is user-editable from Settings (§14.5) instead of being hardcoded.
    static let preamble = "あなたは音声入力を整形する専門家です。以下のルールに従ってください。"
    /// Fixed output-format instruction, kept constant for the same reason as `preamble` above.
    static let outputFormatSuffix = """
    【出力形式】
    schema の "refined_text" に整形結果の文字列を1つ返す。
    """

    private let llm: LLMCompleting
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "DictationRefiner")

    init(llm: LLMCompleting = LLMClient.shared) {
        self.llm = llm
    }

    /// Combines the fixed `preamble`/`outputFormatSuffix` with `resolvedContext`
    /// (`DictationContextResolver.resolve(bundleID:config:)`'s output) in between. `resolvedContext`
    /// being `nil` or empty (global and app context both resolved to nothing, R15's explicit escape
    /// hatch) still sends `preamble` + `outputFormatSuffix` -- the structured-output contract is
    /// never skipped, only the "事前知識" block is omitted.
    static func buildSystemPrompt(resolvedContext: String?) -> String {
        guard let resolvedContext, !resolvedContext.isEmpty else {
            return "\(preamble)\n\n\(outputFormatSuffix)"
        }
        return "\(preamble)\n\n\(resolvedContext)\n\n\(outputFormatSuffix)"
    }

    /// - Parameters:
    ///   - rawText: The STT output for this utterance. Returned unchanged (no LLM call at all) if
    ///     empty.
    ///   - resolvedModel: Resolved via `DictationRefiner.resolveModel(dictationModel:
    ///     watchersDefaultModel:config:availableProviders:)`.
    ///   - timeoutMs: `dictation.refine_timeout_ms`. The effective wait is extended (never shortened)
    ///     by `resolvedModel.params.timeoutSeconds` when set (`docs/design/44-llm-model-config.md`
    ///     §3.3's max rule) -- applied here in milliseconds directly rather than through
    ///     `LLMRequest.init(resolved:functionDefaultSeconds:)` (that helper only takes whole seconds,
    ///     which would lose `refine_timeout_ms`'s sub-second precision).
    ///   - resolvedContext: `DictationContextResolver.resolve(bundleID:config:)`'s output, passed
    ///     through unchanged -- `DictationRefiner` never reads `AppConfig`/`FrontmostGuard.Target`
    ///     itself (existing DI seam: it only ever receives already-resolved values).
    func refine(rawText: String, resolvedModel: ResolvedModel, timeoutMs: Int, resolvedContext: String?) async -> DictationRefineOutcome {
        guard !rawText.isEmpty else {
            return DictationRefineOutcome(text: rawText, usage: nil, model: nil, failure: nil)
        }

        let effectiveTimeoutMs = resolvedModel.params.timeoutSeconds.map { max(timeoutMs, $0 * 1_000) } ?? timeoutMs
        let request = LLMRequest(
            system: Self.buildSystemPrompt(resolvedContext: resolvedContext),
            user: rawText,
            schema: DictationRefinerSchema.json,
            model: resolvedModel.model,
            timeout: .milliseconds(effectiveTimeoutMs),
            stubKey: "dictation",
            provider: resolvedModel.provider,
            params: resolvedModel.params
        )

        do {
            let result: LLMResult<DictationRefinedText> = try await llm.complete(request)
            // A structurally valid but empty (or whitespace-only) `refined_text` is deliberately
            // returned as a *success* here: `DictationController.refineForHistory` owns that case
            // (design 29 §3.2's "empty refinement" -- finalText falls back to rawText, the entry is
            // recorded as `.fallback`, and `llmUsage` is kept because the call did cost tokens).
            // Guarding here as well would pre-empt that richer bookkeeping with a plain failure.
            return DictationRefineOutcome(
                text: result.value.refinedText,
                usage: result.usage,
                model: result.respondedModel ?? resolvedModel.model,
                failure: nil
            )
        } catch {
            logger.warning("dictation refinement failed, falling back to raw text: \(String(describing: error), privacy: .public)")
            return DictationRefineOutcome(text: rawText, usage: nil, model: nil, failure: String(describing: error))
        }
    }

    /// `dictation.model` resolution (`docs/design/44-llm-model-config.md` §4/§7, revised after D2
    /// shipped: a silently-used hardcoded model surprised the user in practice -- "設定していないのに
    /// 勝手に使っている").
    ///
    /// - New-format `config` (`!config.isLegacySentinelDefault`): candidates `[dictationModel]` --
    ///   an empty/unset `dictation.model` falls straight through `ModelResolver.resolve`'s own
    ///   fallthrough to `llm.default` (§2.2's table).
    /// - Legacy `config` (sentinel `defaultProviderName`, §4): candidates
    ///   `[dictationModel, watchersDefaultModel]`, the pre-44-章 fallback chain kept in place
    ///   deliberately (§4/§13-3's "旧形式は watchers.default_model に据え置く" -- resolving straight to
    ///   `llm.default` here would drop a legacy single-openai-provider config's dictation refine back
    ///   to the claude-cli builtin, a regression for anyone without the CLI installed).
    static func resolveModel(
        dictationModel: String,
        watchersDefaultModel: String,
        config: LLMConfig,
        availableProviders: Set<String>
    ) -> ResolvedModel {
        let candidates: [String?] = config.isLegacySentinelDefault
            ? [dictationModel, watchersDefaultModel]
            : [dictationModel]
        return ModelResolver.resolve(candidates: candidates, config: config, availableProviders: availableProviders)
    }
}
