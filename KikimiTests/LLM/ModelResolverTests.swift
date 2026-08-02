import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `ModelResolver.resolve(candidates:config:availableProviders:)`
/// (`docs/design/44-llm-model-config.md` §3, §11's test list). Every test builds an `LLMConfig`
/// directly via its designated `init(provider:claude:openai:pricing:providers:models:defaultAlias:
/// defaultProviderName:)` -- never through YAML decode -- so each rule can be exercised in isolation
/// from `LLMConfig`'s own decode/migration behavior (covered separately by `LLMConfigProvidersAndModelsTests`).
@Suite("ModelResolver")
struct ModelResolverTests {
    /// A "new-format" config with one `claude-cli` provider and no aliases, matching the shape most
    /// tests below build on top of (`llm.default: auto`, so bare-model-name resolution -- rule 3 --
    /// has a real provider to borrow).
    private func newFormatConfig(
        providers: [String: LLMProviderConfig] = ["claude": .claudeCLI(.default)],
        models: [String: ModelAliasConfig] = [:],
        defaultAlias: String = "auto"
    ) -> LLMConfig {
        LLMConfig(
            provider: .claudeCLI, claude: .default, openai: .default, pricing: [:],
            providers: providers, models: models, defaultAlias: defaultAlias, defaultProviderName: nil
        )
    }

    // MARK: - Rule 1: alias exact match

    @Test("an alias name expands to its full definition, including effort/timeout params")
    func aliasExpandsToItsDefinition() {
        let config = newFormatConfig(
            providers: ["claude": .claudeCLI(.default), "azure": .openai(.default)],
            models: ["premium": ModelAliasConfig(provider: "claude", model: "claude-sonnet-5", effort: "high", timeoutSeconds: 300)]
        )
        let resolved = ModelResolver.resolve(candidates: ["premium"], config: config, availableProviders: ["claude", "azure"])
        #expect(resolved == ResolvedModel(provider: "claude", model: "claude-sonnet-5", params: LLMCallParams(effort: "high", timeoutSeconds: 300)))
    }

    // MARK: - Rule 2: "provider/model" split

    @Test("provider/model splits at the first slash, leaving any further slashes in the model half")
    func providerModelSplitKeepsExtraSlashesInModelHalf() {
        let config = newFormatConfig(providers: ["azure": .openai(.default)])
        let resolved = ModelResolver.resolve(candidates: ["azure/gpt-4/turbo"], config: config, availableProviders: ["claude", "azure"])
        #expect(resolved == ResolvedModel(provider: "azure", model: "gpt-4/turbo"))
    }

    @Test("provider/model carries no params of its own -- only an llm.models alias can")
    func providerModelSplitCarriesNoParams() {
        let config = newFormatConfig(providers: ["azure": .openai(.default)])
        let resolved = ModelResolver.resolve(candidates: ["azure/gpt-4"], config: config, availableProviders: ["claude", "azure"])
        #expect(resolved.params == LLMCallParams())
    }

    // MARK: - Rule 3: bare model name + default's provider

    @Test("a bare model name (no alias, no slash) resolves to the default alias's provider")
    func bareModelNameBorrowsDefaultProvider() {
        let config = newFormatConfig(
            providers: ["claude": .claudeCLI(.default)],
            models: ["auto": ModelAliasConfig(provider: "claude", model: "claude-haiku-4-5-20251001")],
            defaultAlias: "auto"
        )
        let resolved = ModelResolver.resolve(candidates: ["claude-sonnet-5"], config: config, availableProviders: ["claude"])
        #expect(resolved == ResolvedModel(provider: "claude", model: "claude-sonnet-5"))
    }

    @Test("a bare model name does not inherit the default alias's own params (effort/timeout)")
    func bareModelNameDoesNotInheritDefaultAliasParams() {
        let config = newFormatConfig(
            providers: ["claude": .claudeCLI(.default)],
            models: ["auto": ModelAliasConfig(provider: "claude", model: "claude-haiku-4-5-20251001", effort: "high", timeoutSeconds: 300)],
            defaultAlias: "auto"
        )
        let resolved = ModelResolver.resolve(candidates: ["claude-sonnet-5"], config: config, availableProviders: ["claude"])
        #expect(resolved.params == LLMCallParams(), "the bare model-name path must never carry over auto's effort/timeout")
    }

    @Test("a legacy-migrated config (defaultProviderName sentinel) resolves a bare model name via the sentinel provider")
    func bareModelNameUsesLegacySentinelProvider() {
        let config = LLMConfig(
            provider: .claudeCLI, claude: .default, openai: .default, pricing: [:],
            providers: ["claude": .claudeCLI(.default)], models: [:], defaultAlias: "", defaultProviderName: "claude"
        )
        let resolved = ModelResolver.resolve(candidates: ["claude-haiku-4-5-20251001"], config: config, availableProviders: ["claude"])
        #expect(resolved == ResolvedModel(provider: "claude", model: "claude-haiku-4-5-20251001"))
    }

    // MARK: - Candidate-list fallthrough

    @Test("a first candidate that is a defined-but-unavailable-provider alias falls through to the next candidate")
    func definedButInvalidAliasFallsThroughToNextCandidate() {
        let config = newFormatConfig(
            providers: ["claude": .claudeCLI(.default)],
            models: [
                "stale": ModelAliasConfig(provider: "azure", model: "gpt-4"), // "azure" is not in availableProviders
                "auto": ModelAliasConfig(provider: "claude", model: "claude-haiku-4-5-20251001")
            ]
        )
        let resolved = ModelResolver.resolve(candidates: ["stale", "auto"], config: config, availableProviders: ["claude"])
        #expect(resolved == ResolvedModel(provider: "claude", model: "claude-haiku-4-5-20251001"))
    }

    @Test("every candidate invalid falls through llm.default and finally to the builtin default")
    func everyCandidateInvalidFallsThroughToBuiltinDefault() {
        let config = newFormatConfig(providers: [:], models: [:], defaultAlias: "does-not-exist")
        let resolved = ModelResolver.resolve(
            candidates: ["also-undefined/model", nil, ""],
            config: config,
            availableProviders: []
        )
        #expect(resolved == ResolvedModel(provider: ModelResolver.builtinProviderName, model: ModelResolver.builtinModelName))
    }

    @Test("nil and empty-string candidates are skipped silently, falling straight to the next candidate")
    func nilAndEmptyCandidatesAreSkipped() {
        let config = newFormatConfig(
            providers: ["claude": .claudeCLI(.default)],
            models: ["auto": ModelAliasConfig(provider: "claude", model: "claude-haiku-4-5-20251001")]
        )
        let resolved = ModelResolver.resolve(candidates: [nil, "", "auto"], config: config, availableProviders: ["claude"])
        #expect(resolved == ResolvedModel(provider: "claude", model: "claude-haiku-4-5-20251001"))
    }

    // MARK: - availableProviders validation

    @Test("a provider present in live config.providers but absent from availableProviders is treated as unavailable")
    func providerMissingFromAvailableProvidersSnapshotIsInvalid() {
        // "azure" is a real, valid entry in config.providers (simulating a provider added to
        // config.yaml after LLMClient's startup snapshot was taken, §3.2) -- but is deliberately
        // left out of `availableProviders`.
        let config = newFormatConfig(
            providers: ["claude": .claudeCLI(.default), "azure": .openai(.default)],
            models: [:]
        )
        let resolved = ModelResolver.resolve(candidates: ["azure/gpt-4"], config: config, availableProviders: ["claude"])
        #expect(resolved == ResolvedModel(provider: ModelResolver.builtinProviderName, model: ModelResolver.builtinModelName))
    }

    // MARK: - Collision priority

    @Test("an alias name that collides with a provider name resolves as the alias, not the provider")
    func aliasProviderNameCollisionPrefersAlias() {
        let config = newFormatConfig(
            providers: ["claude": .claudeCLI(.default)],
            models: ["claude": ModelAliasConfig(provider: "claude", model: "claude-sonnet-5")]
        )
        let resolved = ModelResolver.resolve(candidates: ["claude"], config: config, availableProviders: ["claude"])
        #expect(resolved == ResolvedModel(provider: "claude", model: "claude-sonnet-5"), "the alias definition must win over the bare provider/rule-3 interpretation")
    }

    @Test("resolution through an explicit \"claude\" provider entry never falls all the way to step 5's builtin")
    func explicitClaudeProviderResolvesWithoutReachingBuiltinFallback() {
        // §3.1's "builtin 暗黙 claude プロバイダとユーザー定義の同名プロバイダが衝突した場合は明示
        // 定義が勝つ": at the `ModelResolver` layer (which only ever returns a provider *name*, never
        // provider connection config -- `LLMClient`'s job) this collision means an explicit
        // `providers.claude` entry is resolved via the ordinary rule-2 "provider/model" path and the
        // builtin fallback (step 5) is never reached for it.
        let config = newFormatConfig(providers: ["claude": .claudeCLI(ClaudeBackendConfig(cliPath: "/custom/path/claude"))], models: [:])
        let resolved = ModelResolver.resolve(candidates: ["claude/claude-opus-4"], config: config, availableProviders: ["claude"])
        #expect(resolved == ResolvedModel(provider: "claude", model: "claude-opus-4"), "must resolve claude-opus-4 via rule 2, not the builtin haiku default")
    }

    // MARK: - No reserved alias names (§2.1's "予約名は設けない")

    @Test("an undefined \"auto\" candidate is just an ordinary undefined alias -- falls straight through to the builtin default")
    func undefinedAutoFallsBackToBuiltin() {
        let config = newFormatConfig(providers: [:], models: [:])
        let resolved = ModelResolver.resolve(candidates: ["auto"], config: config, availableProviders: [])
        #expect(resolved == ResolvedModel(provider: ModelResolver.builtinProviderName, model: ModelResolver.builtinModelName))
    }

    @Test("an undefined \"premium\" candidate is just an ordinary bare model name now -- it never falls back to \"auto\"'s definition, and never inherits its params")
    func undefinedPremiumIsJustABareModelName() {
        let config = newFormatConfig(
            providers: ["claude": .claudeCLI(.default)],
            models: ["auto": ModelAliasConfig(provider: "claude", model: "claude-haiku-4-5-20251001", effort: "low")]
        )
        let resolved = ModelResolver.resolve(candidates: ["premium"], config: config, availableProviders: ["claude"])
        // Rule 3 (bare model name): borrows "auto"'s (== llm.default's) *provider* only, per the usual
        // rule -- the literal string "premium" becomes the model id, not auto's actual model/params.
        #expect(resolved == ResolvedModel(provider: "claude", model: "premium"))
    }

    @Test("an explicitly-defined \"premium\" alias resolves like any other alias name")
    func explicitPremiumDefinitionResolvesAsAnOrdinaryAlias() {
        let config = newFormatConfig(
            providers: ["claude": .claudeCLI(.default)],
            models: ["premium": ModelAliasConfig(provider: "claude", model: "claude-sonnet-5")]
        )
        let resolved = ModelResolver.resolve(candidates: ["premium"], config: config, availableProviders: ["claude"])
        #expect(resolved == ResolvedModel(provider: "claude", model: "claude-sonnet-5"))
    }

    @Test("a bare model name candidate falls through to the builtin default when llm.default names an alias that llm.models never defines")
    func bareModelNameFallsBackToBuiltinWhenDefaultAliasIsUndefined() {
        // "auto" is llm.default here but llm.models never defines it (§2.1: "llm.default が指す定義が
        // 無ければ warning + builtin 既定へフォールスルー") -- rule 3 has no default provider to borrow,
        // so the candidate's own model name ("claude-sonnet-5") is discarded, not just its provider.
        let config = newFormatConfig(providers: [:], models: [:], defaultAlias: "auto")
        let resolved = ModelResolver.resolve(candidates: ["claude-sonnet-5"], config: config, availableProviders: [])
        #expect(resolved == ResolvedModel(provider: ModelResolver.builtinProviderName, model: ModelResolver.builtinModelName))
    }

    // MARK: - Rule 1: alias definition with no provider (bare short-form) borrows the default's provider

    @Test("an alias defined via the bare-model-name short form (no provider) borrows the default alias's provider")
    func aliasWithNilProviderBorrowsDefaultProvider() {
        let config = newFormatConfig(
            providers: ["claude": .claudeCLI(.default)],
            models: [
                "auto": ModelAliasConfig(provider: "claude", model: "claude-haiku-4-5-20251001"),
                "bare": ModelAliasConfig(provider: nil, model: "claude-sonnet-5")
            ],
            defaultAlias: "auto"
        )
        let resolved = ModelResolver.resolve(candidates: ["bare"], config: config, availableProviders: ["claude"])
        #expect(resolved == ResolvedModel(provider: "claude", model: "claude-sonnet-5"))
    }

    @Test("an alias with no provider falls through when the default alias's provider is unavailable")
    func aliasWithNilProviderFallsThroughWhenDefaultProviderUnavailable() {
        let config = newFormatConfig(
            providers: ["claude": .claudeCLI(.default), "azure": .openai(.default)],
            models: [
                "auto": ModelAliasConfig(provider: "azure", model: "gpt-4"), // "azure" is unavailable below
                "bare": ModelAliasConfig(provider: nil, model: "claude-sonnet-5")
            ],
            defaultAlias: "auto"
        )
        let resolved = ModelResolver.resolve(candidates: ["bare"], config: config, availableProviders: ["claude"])
        #expect(resolved == ResolvedModel(provider: ModelResolver.builtinProviderName, model: ModelResolver.builtinModelName))
    }

    // MARK: - Step 4 (`llm.default`) reached once every explicit candidate is exhausted

    @Test("llm.default resolves via its own alias definition once every explicit candidate is exhausted")
    func llmDefaultResolvesViaAliasWhenCandidatesExhausted() {
        let config = newFormatConfig(
            providers: ["claude": .claudeCLI(.default)],
            models: ["auto": ModelAliasConfig(provider: "claude", model: "claude-haiku-4-5-20251001", effort: "low")],
            defaultAlias: "auto"
        )
        let resolved = ModelResolver.resolve(candidates: [nil, ""], config: config, availableProviders: ["claude"])
        #expect(resolved == ResolvedModel(provider: "claude", model: "claude-haiku-4-5-20251001", params: LLMCallParams(effort: "low")))
    }

    @Test("llm.default resolves via a \"provider/model\" string directly, without needing an llm.models alias")
    func llmDefaultResolvesViaProviderModelForm() {
        let config = newFormatConfig(providers: ["azure": .openai(.default)], models: [:], defaultAlias: "azure/gpt-4o-mini")
        let resolved = ModelResolver.resolve(candidates: [], config: config, availableProviders: ["azure"])
        #expect(resolved == ResolvedModel(provider: "azure", model: "gpt-4o-mini"))
    }

    @Test("llm.default naming an alias llm.models never defines falls through to the builtin default, even when a different alias happens to be named \"auto\"")
    func llmDefaultUndefinedAliasDoesNotFallBackToAuto() {
        let config = newFormatConfig(
            providers: ["claude": .claudeCLI(.default)],
            models: ["auto": ModelAliasConfig(provider: "claude", model: "claude-haiku-4-5-20251001")],
            defaultAlias: "premium"
        )
        let resolved = ModelResolver.resolve(candidates: [], config: config, availableProviders: ["claude"])
        #expect(resolved == ResolvedModel(provider: ModelResolver.builtinProviderName, model: ModelResolver.builtinModelName))
    }

    // MARK: - resolveDefaultProvider's own branches (rule 3's "default's provider" lookup)

    @Test("a bare model name borrows the provider that \"premium\" itself resolves to, when llm.default is \"premium\"")
    func bareModelNameBorrowsPremiumsProviderWhenDefaultIsPremium() {
        let config = newFormatConfig(
            providers: ["claude": .claudeCLI(.default)],
            models: ["premium": ModelAliasConfig(provider: "claude", model: "claude-sonnet-5")],
            defaultAlias: "premium"
        )
        let resolved = ModelResolver.resolve(candidates: ["gpt-4o-mini"], config: config, availableProviders: ["claude"])
        #expect(resolved == ResolvedModel(provider: "claude", model: "gpt-4o-mini"))
    }

    @Test("a bare model name candidate falls back to the plain builtin default when llm.default names an undefined alias")
    func bareModelNameFallsBackToBuiltinWhenDefaultAliasUndefined() {
        let config = newFormatConfig(providers: [:], models: [:], defaultAlias: "premium")
        let resolved = ModelResolver.resolve(candidates: ["claude-sonnet-5"], config: config, availableProviders: [])
        #expect(resolved == ResolvedModel(provider: ModelResolver.builtinProviderName, model: ModelResolver.builtinModelName))
    }

    @Test("a bare model name borrows the provider half of llm.default when llm.default itself is a \"provider/model\" string")
    func bareModelNameBorrowsProviderFromSlashFormDefault() {
        let config = newFormatConfig(providers: ["azure": .openai(.default)], models: [:], defaultAlias: "azure/gpt-4o-mini")
        let resolved = ModelResolver.resolve(candidates: ["gpt-4-turbo"], config: config, availableProviders: ["azure"])
        #expect(resolved == ResolvedModel(provider: "azure", model: "gpt-4-turbo"))
    }

    // MARK: - §3.3 params: effort priority

    @Test("resolvedEffort prefers the model definition's effort over the provider's reasoning_effort")
    func resolvedEffortPrefersModelDefinitionOverProvider() {
        let provider = LLMProviderConfig.openai(OpenAIBackendConfig(baseURL: "", apiKey: "", apiKeyEnv: "", apiVersion: "", model: "", authHeader: "", reasoningEffort: "low"))
        let effort = ModelResolver.resolvedEffort(params: LLMCallParams(effort: "high"), provider: provider)
        #expect(effort == "high")
    }

    @Test("resolvedEffort falls back to the openai provider's reasoning_effort when the model definition has none")
    func resolvedEffortFallsBackToProviderReasoningEffort() {
        let provider = LLMProviderConfig.openai(OpenAIBackendConfig(baseURL: "", apiKey: "", apiKeyEnv: "", apiVersion: "", model: "", authHeader: "", reasoningEffort: "low"))
        let effort = ModelResolver.resolvedEffort(params: LLMCallParams(), provider: provider)
        #expect(effort == "low")
    }

    @Test("resolvedEffort is nil when neither the model definition nor an openai provider set one")
    func resolvedEffortIsNilWhenNothingIsSet() {
        #expect(ModelResolver.resolvedEffort(params: LLMCallParams(), provider: nil) == nil)
        #expect(ModelResolver.resolvedEffort(params: LLMCallParams(), provider: .claudeCLI(.default)) == nil)
    }

    @Test("resolvedEffort ignores a claude-cli provider's (nonexistent) reasoning_effort field entirely")
    func resolvedEffortIgnoresClaudeCLIProvider() {
        let effort = ModelResolver.resolvedEffort(params: LLMCallParams(), provider: .claudeCLI(.default))
        #expect(effort == nil)
    }

    // MARK: - §3.3 params: timeout is extension-only

    @Test("resolvedTimeoutSeconds extends the function-side default when the model definition is longer")
    func resolvedTimeoutExtendsWhenModelDefinitionIsLonger() {
        #expect(ModelResolver.resolvedTimeoutSeconds(functionDefaultSeconds: 60, modelDefinitionSeconds: 300) == 300)
    }

    @Test("resolvedTimeoutSeconds never shrinks below the function-side default even when the model definition is shorter")
    func resolvedTimeoutNeverShrinksBelowFunctionDefault() {
        #expect(ModelResolver.resolvedTimeoutSeconds(functionDefaultSeconds: 300, modelDefinitionSeconds: 10) == 300)
    }

    @Test("resolvedTimeoutSeconds passes through the function-side default when the model definition has none")
    func resolvedTimeoutPassesThroughWhenModelDefinitionHasNone() {
        #expect(ModelResolver.resolvedTimeoutSeconds(functionDefaultSeconds: 60, modelDefinitionSeconds: nil) == 60)
    }
}
