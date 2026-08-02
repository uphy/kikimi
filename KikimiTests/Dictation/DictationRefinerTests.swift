import Foundation
import Testing

@testable import Kikimi

// MARK: - FakeLLM

/// Deterministic, network-free stand-in for `LLMCompleting`, mirroring `SummaryUpdaterTests`'
/// `FakeLLM` (`docs/design/25-dictation-mode.md` §11's "`DictationRefiner` が `KIKIMI_STUB_LLM=1` +
/// `stubKey: "dictation"` で決定論応答を返すこと、timeout/エラーで raw フォールバックすること").
private actor FakeLLM: LLMCompleting {
    private(set) var receivedRequests: [LLMRequest] = []

    var response: String?
    var error: LLMClientError?
    var respondedModel: String?
    /// When set, `complete(_:)` suspends for this long before resolving -- used to prove
    /// `LLMRequest.timeout` is actually threaded through, without a real network timeout.
    var delay: Duration?

    func complete<T: Decodable & Sendable>(_ request: LLMRequest) async throws -> LLMResult<T> {
        receivedRequests.append(request)
        if let delay {
            try await Task.sleep(for: delay)
        }
        if let error {
            throw error
        }
        guard let response, let data = response.data(using: .utf8) else {
            throw LLMClientError.missingStructuredOutput(raw: "no fake response registered")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(T.self, from: data)
        return LLMResult(value: value, usage: .zero, respondedModel: respondedModel)
    }

    func completeRaw(_ request: LLMRequest) async throws -> LLMResult<Data> {
        receivedRequests.append(request)
        guard let response, let data = response.data(using: .utf8) else {
            throw LLMClientError.missingStructuredOutput(raw: "no fake response registered")
        }
        return LLMResult(value: data, usage: .zero)
    }
}

@Suite("DictationRefiner")
struct DictationRefinerTests {
    @Test("a successful call returns the LLM's refined_text, usage, model, and no failure")
    func successfulCallReturnsRefinedText() async {
        let llm = FakeLLM()
        await llm.setResponse(#"{"refined_text":"次のスプリントで対応します。"}"#)
        let refiner = DictationRefiner(llm: llm)

        let outcome = await refiner.refine(
            rawText: "次のスプリントで対応しますえーと",
            resolvedModel: ResolvedModel(provider: "claude", model: "claude-haiku-4-5-20251001"),
            timeoutMs: 3_000,
            resolvedContext: nil
        )

        #expect(outcome.text == "次のスプリントで対応します。")
        #expect(outcome.usage == .zero)
        #expect(outcome.model == "claude-haiku-4-5-20251001")
        #expect(outcome.failure == nil)
        #expect(outcome.succeeded)
    }

    @Test("a successful call prefers respondedModel over the requested model when the backend reports one")
    func successfulCallPrefersRespondedModel() async {
        let llm = FakeLLM()
        await llm.setResponse(#"{"refined_text":"ok"}"#)
        await llm.setRespondedModel("claude-haiku-4-5-20251001-v2")
        let refiner = DictationRefiner(llm: llm)

        let outcome = await refiner.refine(
            rawText: "raw",
            resolvedModel: ResolvedModel(provider: "claude", model: "claude-haiku-4-5-20251001"),
            timeoutMs: 3_000,
            resolvedContext: nil
        )

        #expect(outcome.model == "claude-haiku-4-5-20251001-v2")
    }

    @Test("the request carries stubKey \"dictation\", the resolved model/provider, and the timeout as a Duration")
    func requestCarriesExpectedFields() async throws {
        let llm = FakeLLM()
        await llm.setResponse(#"{"refined_text":"ok"}"#)
        let refiner = DictationRefiner(llm: llm)

        _ = await refiner.refine(
            rawText: "raw",
            resolvedModel: ResolvedModel(provider: "azure", model: "claude-sonnet-4-5"),
            timeoutMs: 1_500,
            resolvedContext: nil
        )

        let requests = await llm.receivedRequests
        let request = try #require(requests.first)
        #expect(request.stubKey == "dictation")
        #expect(request.model == "claude-sonnet-4-5")
        #expect(request.provider == "azure")
        #expect(request.timeout == .milliseconds(1_500))
        #expect(request.user == "raw")
        #expect(request.schema == DictationRefinerSchema.json)
    }

    @Test("a model definition's timeout_seconds extends (never shortens) refine_timeout_ms, in milliseconds")
    func requestTimeoutExtendsButNeverShortens() async throws {
        let llm = FakeLLM()
        await llm.setResponse(#"{"refined_text":"ok"}"#)
        let refiner = DictationRefiner(llm: llm)

        // Extends: a 10s model-definition timeout beats a 1.5s refine_timeout_ms.
        _ = await refiner.refine(
            rawText: "raw",
            resolvedModel: ResolvedModel(provider: "claude", model: "premium-model", params: LLMCallParams(timeoutSeconds: 10)),
            timeoutMs: 1_500,
            resolvedContext: nil
        )
        let extendedRequest = try #require(await llm.receivedRequests.first)
        #expect(extendedRequest.timeout == .milliseconds(10_000))

        // Never shortens: a 1s model-definition timeout does not undercut a 3s refine_timeout_ms.
        _ = await refiner.refine(
            rawText: "raw",
            resolvedModel: ResolvedModel(provider: "claude", model: "short-timeout-model", params: LLMCallParams(timeoutSeconds: 1)),
            timeoutMs: 3_000,
            resolvedContext: nil
        )
        let unshortenedRequest = try #require(await llm.receivedRequests.last)
        #expect(unshortenedRequest.timeout == .milliseconds(3_000))
    }

    @Test("resolvedContext is threaded through into the request's system prompt")
    func requestSystemReflectsResolvedContext() async throws {
        let llm = FakeLLM()
        await llm.setResponse(#"{"refined_text":"ok"}"#)
        let refiner = DictationRefiner(llm: llm)

        _ = await refiner.refine(
            rawText: "raw",
            resolvedModel: ResolvedModel(provider: "claude", model: "claude-sonnet-4-5"),
            timeoutMs: 1_500,
            resolvedContext: "Slack向けルール"
        )

        let requests = await llm.receivedRequests
        let request = try #require(requests.first)
        #expect(request.system == DictationRefiner.buildSystemPrompt(resolvedContext: "Slack向けルール"))
        #expect(request.system.contains("Slack向けルール"))
    }

    @Test("an LLM error falls back to the raw text unchanged and reports the failure reason")
    func llmErrorFallsBackToRawText() async {
        let llm = FakeLLM()
        await llm.setError(.timedOut(.seconds(3)))
        let refiner = DictationRefiner(llm: llm)

        let outcome = await refiner.refine(
            rawText: "次のスプリントで対応します",
            resolvedModel: ResolvedModel(provider: "claude", model: "claude-haiku-4-5-20251001"),
            timeoutMs: 3_000,
            resolvedContext: nil
        )

        #expect(outcome.text == "次のスプリントで対応します")
        #expect(outcome.usage == nil)
        #expect(outcome.model == nil)
        #expect(outcome.failure == String(describing: LLMClientError.timedOut(.seconds(3))))
        #expect(!outcome.succeeded)
    }

    @Test("a decode failure (malformed structured_output) falls back to the raw text unchanged and reports the failure reason")
    func decodeFailureFallsBackToRawText() async {
        let llm = FakeLLM()
        await llm.setResponse(#"{"unexpected_field":"oops"}"#)
        let refiner = DictationRefiner(llm: llm)

        let outcome = await refiner.refine(
            rawText: "そのままの文章",
            resolvedModel: ResolvedModel(provider: "claude", model: "claude-haiku-4-5-20251001"),
            timeoutMs: 3_000,
            resolvedContext: nil
        )

        #expect(outcome.text == "そのままの文章")
        #expect(outcome.usage == nil)
        #expect(outcome.model == nil)
        #expect(outcome.failure != nil)
        #expect(!outcome.succeeded)
    }

    @Test(
        "an empty or whitespace-only refined_text is passed through as a success -- the empty-refinement fallback is owned by DictationController (design 29 §3.2), not the refiner",
        arguments: [#"{"refined_text":""}"#, #"{"refined_text":" \n "}"#]
    )
    func emptyRefinedTextIsPassedThroughAsSuccess(response: String) async throws {
        let llm = FakeLLM()
        await llm.setResponse(response)
        let refiner = DictationRefiner(llm: llm)

        let outcome = await refiner.refine(
            rawText: "このスキルの追加コミットをフィックスアップしてください",
            resolvedModel: ResolvedModel(provider: "claude", model: "claude-haiku-4-5-20251001"),
            timeoutMs: 3_000,
            resolvedContext: nil
        )

        // Guarding here as well would pre-empt the controller's richer bookkeeping (fallback to
        // rawText with `llmUsage` kept), so the refiner deliberately does not special-case this.
        #expect(outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(outcome.usage == .zero)
        #expect(outcome.model == "claude-haiku-4-5-20251001")
        #expect(outcome.failure == nil)
        #expect(outcome.succeeded)
    }

    @Test("empty raw text short-circuits without calling the LLM at all")
    func emptyRawTextSkipsLLMCall() async {
        let llm = FakeLLM()
        let refiner = DictationRefiner(llm: llm)

        let outcome = await refiner.refine(
            rawText: "",
            resolvedModel: ResolvedModel(provider: "claude", model: "claude-haiku-4-5-20251001"),
            timeoutMs: 3_000,
            resolvedContext: nil
        )

        #expect(outcome.text == "")
        #expect(outcome.usage == nil)
        #expect(outcome.model == nil)
        #expect(outcome.failure == nil)
        #expect(outcome.succeeded)
        let requests = await llm.receivedRequests
        #expect(requests.isEmpty)
    }

    // MARK: - buildSystemPrompt (R17/§14.4)

    @Test("buildSystemPrompt with a nil resolvedContext returns just the preamble and output format")
    func buildSystemPromptWithNilContext() {
        let expected = "\(DictationRefiner.preamble)\n\n\(DictationRefiner.outputFormatSuffix)"

        #expect(DictationRefiner.buildSystemPrompt(resolvedContext: nil) == expected)
    }

    @Test("buildSystemPrompt with an empty resolvedContext returns just the preamble and output format")
    func buildSystemPromptWithEmptyContext() {
        let expected = "\(DictationRefiner.preamble)\n\n\(DictationRefiner.outputFormatSuffix)"

        #expect(DictationRefiner.buildSystemPrompt(resolvedContext: "") == expected)
    }

    @Test("buildSystemPrompt with a non-empty resolvedContext joins preamble, context, then output format in order")
    func buildSystemPromptWithNonEmptyContext() {
        let expected = "\(DictationRefiner.preamble)\n\n共通ルール\n\n\(DictationRefiner.outputFormatSuffix)"

        #expect(DictationRefiner.buildSystemPrompt(resolvedContext: "共通ルール") == expected)
    }

    // MARK: - resolveModel (R9, docs/design/44-llm-model-config.md §4/§7)

    /// A "new-format" `LLMConfig` (`llm.providers`/`llm.models`/`llm.default` genuinely present --
    /// `isLegacySentinelDefault == false`), mirroring `ModelResolverTests.newFormatConfig(...)`.
    private func newFormatConfig(defaultAlias: String = "auto") -> LLMConfig {
        LLMConfig(
            provider: .claudeCLI, claude: .default, openai: .default, pricing: [:],
            providers: ["claude": .claudeCLI(.default)],
            models: ["auto": ModelAliasConfig(provider: "claude", model: "claude-haiku-4-5-20251001")],
            defaultAlias: defaultAlias, defaultProviderName: nil
        )
    }

    /// A "legacy" `LLMConfig` (§4's migration sentinel set, `isLegacySentinelDefault == true`) --
    /// `LLMConfig.default` already has this shape, but this helper spells it out explicitly for
    /// readability at each call site below.
    private func legacyConfig() -> LLMConfig {
        LLMConfig(
            provider: .claudeCLI, claude: .default, openai: .default, pricing: [:],
            providers: ["claude": .claudeCLI(.default)],
            models: [:], defaultAlias: "", defaultProviderName: "claude"
        )
    }

    @Test("new-format config: an empty dictation.model falls through to llm.default, not watchers.default_model")
    func newFormatEmptyDictationModelFallsToLLMDefault() {
        let config = newFormatConfig()
        let resolved = DictationRefiner.resolveModel(
            dictationModel: "",
            watchersDefaultModel: "claude-sonnet-4-5",
            config: config,
            availableProviders: ["claude"]
        )
        // `llm.default: auto` -> the "auto" alias, not the "claude-sonnet-4-5" watchers default --
        // proves the new-format candidate list is `[dictationModel]` alone (§4's revised fallback).
        #expect(resolved == ResolvedModel(provider: "claude", model: "claude-haiku-4-5-20251001"))
    }

    @Test("new-format config: a non-empty dictation.model resolves as its own candidate, ignoring watchers.default_model")
    func newFormatNonEmptyDictationModelIgnoresWatchersDefault() {
        let config = newFormatConfig()
        let resolved = DictationRefiner.resolveModel(
            dictationModel: "claude-sonnet-4-5",
            watchersDefaultModel: "claude-opus-4-1",
            config: config,
            availableProviders: ["claude"]
        )
        #expect(resolved == ResolvedModel(provider: "claude", model: "claude-sonnet-4-5"))
    }

    @Test("legacy config (sentinel default): an empty dictation.model still falls back to watchers.default_model, not llm.default (§4/§13-3's regression guard)")
    func legacyEmptyDictationModelFallsBackToWatchersDefault() {
        let config = legacyConfig()
        let resolved = DictationRefiner.resolveModel(
            dictationModel: "",
            watchersDefaultModel: "claude-sonnet-4-5",
            config: config,
            availableProviders: ["claude"]
        )
        #expect(resolved == ResolvedModel(provider: "claude", model: "claude-sonnet-4-5"))
    }

    @Test("legacy config (sentinel default): a non-empty dictation.model passes through unchanged, ignoring watchers.default_model")
    func legacyNonEmptyDictationModelPassesThroughUnchanged() {
        let config = legacyConfig()
        let resolved = DictationRefiner.resolveModel(
            dictationModel: "claude-sonnet-4-5",
            watchersDefaultModel: "claude-haiku-4-5-20251001",
            config: config,
            availableProviders: ["claude"]
        )
        #expect(resolved == ResolvedModel(provider: "claude", model: "claude-sonnet-4-5"))
    }
}

private extension FakeLLM {
    func setResponse(_ value: String) {
        response = value
    }

    func setError(_ value: LLMClientError) {
        error = value
    }

    func setRespondedModel(_ value: String) {
        respondedModel = value
    }
}
