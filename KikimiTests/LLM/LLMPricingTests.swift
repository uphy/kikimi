import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `LLMPricing`/`LLMModelPricing` (`docs/design/16-llm-usage-stats.md`
/// section 4): prefix-match resolution (built-in vs. config priority), cache-inclusive cost
/// computation, and the `cache_read`/`cache_write` default-derivation logic.
@Suite("LLMPricing")
struct LLMPricingTests {
    // MARK: - LLMModelPricing defaults

    @Test("cache_read/cache_write default to input * 0.1 / input * 1.25 when omitted")
    func modelPricingDerivesCacheDefaults() {
        let pricing = LLMModelPricing(inputUSDPerMTok: 4.0, outputUSDPerMTok: 20.0)
        #expect(pricing.cacheReadUSDPerMTok == 0.4)
        #expect(pricing.cacheWriteUSDPerMTok == 5.0)
    }

    @Test("explicit cache_read/cache_write override the derived defaults")
    func modelPricingHonorsExplicitCacheValues() {
        let pricing = LLMModelPricing(inputUSDPerMTok: 4.0, outputUSDPerMTok: 20.0, cacheReadUSDPerMTok: 1.0, cacheWriteUSDPerMTok: 2.0)
        #expect(pricing.cacheReadUSDPerMTok == 1.0)
        #expect(pricing.cacheWriteUSDPerMTok == 2.0)
    }

    @Test("decoding a config entry without cache_read/cache_write derives the defaults")
    func decodingPartialEntryDerivesCacheDefaults() throws {
        let json = """
        {"input": 2.5, "output": 10.0}
        """
        let decoder = JSONDecoder()
        let pricing = try decoder.decode(LLMModelPricing.self, from: Data(json.utf8))
        #expect(pricing.inputUSDPerMTok == 2.5)
        #expect(pricing.outputUSDPerMTok == 10.0)
        #expect(pricing.cacheReadUSDPerMTok == 0.25)
        #expect(pricing.cacheWriteUSDPerMTok == 3.125)
    }

    @Test("decoding a config entry with explicit cache_read/cache_write honors them")
    func decodingFullEntryHonorsExplicitCacheValues() throws {
        let json = """
        {"input": 2.5, "output": 10.0, "cache_read": 1.25, "cache_write": 2.5}
        """
        let decoder = JSONDecoder()
        let pricing = try decoder.decode(LLMModelPricing.self, from: Data(json.utf8))
        #expect(pricing.cacheReadUSDPerMTok == 1.25)
        #expect(pricing.cacheWriteUSDPerMTok == 2.5)
    }

    // MARK: - resolve(model:configPricing:) -- prefix match / longest match wins

    @Test("resolve matches a built-in model id by exact prefix")
    func resolveMatchesBuiltInExact() {
        let pricing = LLMPricing.resolve(model: "claude-haiku-4-5-20251001", configPricing: [:])
        #expect(pricing == LLMPricing.builtIn["claude-haiku-4-5"])
    }

    @Test("resolve returns nil for an unknown model with no config override")
    func resolveReturnsNilForUnknownModel() {
        #expect(LLMPricing.resolve(model: "some-unknown-model", configPricing: [:]) == nil)
    }

    @Test("resolve prefers config pricing over the built-in table for the same prefix")
    func resolvePrefersConfigOverBuiltIn() {
        let override = LLMModelPricing(inputUSDPerMTok: 999, outputUSDPerMTok: 999)
        let resolved = LLMPricing.resolve(model: "claude-haiku-4-5-20251001", configPricing: ["claude-haiku-4-5": override])
        #expect(resolved == override)
    }

    @Test("resolve picks the longest matching prefix across both tables")
    func resolvePicksLongestPrefix() {
        let genericPricing = LLMModelPricing(inputUSDPerMTok: 1, outputUSDPerMTok: 2)
        let specificPricing = LLMModelPricing(inputUSDPerMTok: 3, outputUSDPerMTok: 4)
        let configPricing = ["claude-opus": genericPricing, "claude-opus-4-5": specificPricing]

        let resolved = LLMPricing.resolve(model: "claude-opus-4-5-20251001", configPricing: configPricing)
        #expect(resolved == specificPricing)
    }

    @Test("resolve for an Azure deployment name that is not a real model id only matches via a config override")
    func resolveAzureDeploymentNameNeedsConfigOverride() {
        // A deployment name that does not start with any built-in model id: the built-in table
        // cannot price it, so a `llm.pricing` override is required (design section 4's Azure
        // deployment-name workflow). Deployment names that *do* start with a real model id (e.g.
        // "gpt-4o-...") now resolve against the built-in OpenAI prices instead -- see
        // `resolveOpenAIDeploymentNameByPrefix`.
        let override = LLMModelPricing(inputUSDPerMTok: 2.5, outputUSDPerMTok: 10.0)
        let resolved = LLMPricing.resolve(model: "my-azure-deployment", configPricing: ["my-azure-deployment": override])
        #expect(resolved == override)
        #expect(LLMPricing.resolve(model: "my-azure-deployment", configPricing: [:]) == nil)
    }

    // MARK: - resolve(model:configPricing:) -- built-in OpenAI/Azure prices

    @Test("resolve matches a built-in OpenAI model id by exact prefix")
    func resolveMatchesBuiltInOpenAI() {
        let pricing = LLMPricing.resolve(model: "gpt-4.1-mini-2025-04-14", configPricing: [:])
        #expect(pricing == LLMPricing.builtIn["gpt-4.1-mini"])
    }

    @Test("resolve prefers the specific OpenAI prefix over the generic family prefix")
    func resolveOpenAIPrefersSpecificPrefix() {
        // gpt-4o-mini / gpt-5-mini / gpt-5.4 must win over their gpt-4o / gpt-5 family prefixes.
        #expect(LLMPricing.resolve(model: "gpt-4o-mini", configPricing: [:]) == LLMPricing.builtIn["gpt-4o-mini"])
        #expect(LLMPricing.resolve(model: "gpt-5-mini", configPricing: [:]) == LLMPricing.builtIn["gpt-5-mini"])
        #expect(LLMPricing.resolve(model: "gpt-5.4-mini", configPricing: [:]) == LLMPricing.builtIn["gpt-5.4-mini"])
        #expect(LLMPricing.resolve(model: "gpt-5.4", configPricing: [:]) == LLMPricing.builtIn["gpt-5.4"])
        #expect(LLMPricing.resolve(model: "gpt-5.5", configPricing: [:]) == LLMPricing.builtIn["gpt-5.5"])
    }

    @Test("an OpenAI Azure deployment name that starts with a real model id resolves against the built-in price")
    func resolveOpenAIDeploymentNameByPrefix() {
        // The Azure legacy-deployments workflow can leave a request model id like "gpt-4o-..." --
        // it now prices against the built-in gpt-4o entry without a config override.
        #expect(LLMPricing.resolve(model: "gpt-4o-my-deployment", configPricing: [:]) == LLMPricing.builtIn["gpt-4o"])
    }

    @Test("the gpt-5.6 variants win over the gpt-5.6 family fallback, which wins over gpt-5")
    func resolveGPT56Variants() {
        #expect(LLMPricing.resolve(model: "gpt-5.6-luna", configPricing: [:]) == LLMPricing.builtIn["gpt-5.6-luna"])
        #expect(LLMPricing.resolve(model: "gpt-5.6-sol", configPricing: [:]) == LLMPricing.builtIn["gpt-5.6-sol"])
        #expect(LLMPricing.resolve(model: "gpt-5.6-terra", configPricing: [:]) == LLMPricing.builtIn["gpt-5.6-terra"])
        // An unrecognized variant still prices, via the family fallback rather than the gpt-5 entry.
        #expect(LLMPricing.resolve(model: "gpt-5.6-vega", configPricing: [:]) == LLMPricing.builtIn["gpt-5.6"])
    }

    // MARK: - resolve(model:configPricing:) -- models reached through the LiteLLM proxy

    @Test("the model ids served by the LiteLLM proxy all resolve to a built-in price")
    func resolveLiteLLMProxyModelIds() {
        // The ids the proxy exposes verbatim -- none may fall through to `nil` (design section 4's
        // "価格表に無いモデル" case would drop them from the cost totals entirely).
        let ids = [
            "claude-opus-5", "claude-fable-5", "claude-sonnet-5", "claude-opus-4-8",
            "claude-haiku-4-5-20251001", "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra",
            "kimi-k2.5", "kimi-k2.6-preview"
        ]
        for id in ids {
            #expect(LLMPricing.resolve(model: id, configPricing: [:]) != nil, "\(id) has no built-in price")
        }
    }

    @Test("claude-opus-5 and claude-sonnet-5 price at their current published rates")
    func resolveCurrentAnthropicRates() throws {
        let opus5 = try #require(LLMPricing.resolve(model: "claude-opus-5", configPricing: [:]))
        #expect(opus5.inputUSDPerMTok == 5.00)
        #expect(opus5.outputUSDPerMTok == 25.00)
        #expect(opus5.cacheReadUSDPerMTok == 0.50)
        #expect(opus5.cacheWriteUSDPerMTok == 6.25)

        // Introductory pricing through 2026-08-31; see the built-in table's comment.
        let sonnet5 = try #require(LLMPricing.resolve(model: "claude-sonnet-5", configPricing: [:]))
        #expect(sonnet5.inputUSDPerMTok == 2.00)
        #expect(sonnet5.outputUSDPerMTok == 10.00)
    }

    @Test("kimi-k2.6 prices the -preview id by prefix and is distinct from kimi-k2.5")
    func resolveKimiVariants() throws {
        let k25 = try #require(LLMPricing.resolve(model: "kimi-k2.5", configPricing: [:]))
        #expect(k25.inputUSDPerMTok == 0.60)
        #expect(k25.outputUSDPerMTok == 3.00)
        #expect(k25.cacheReadUSDPerMTok == 0.10)
        #expect(k25.cacheWriteUSDPerMTok == k25.inputUSDPerMTok)

        let k26 = try #require(LLMPricing.resolve(model: "kimi-k2.6-preview", configPricing: [:]))
        #expect(k26 == LLMPricing.builtIn["kimi-k2.6"])
        #expect(k26.inputUSDPerMTok == 0.95)
        #expect(k26.outputUSDPerMTok == 4.00)
        #expect(k26.cacheReadUSDPerMTok == 0.16)
    }

    @Test("built-in OpenAI prices set cache_write equal to input (no cache-creation premium)")
    func openAICacheWriteEqualsInput() throws {
        let mini = try #require(LLMPricing.builtIn["gpt-4.1-mini"])
        #expect(mini.inputUSDPerMTok == 0.40)
        #expect(mini.cacheReadUSDPerMTok == 0.10)
        #expect(mini.cacheWriteUSDPerMTok == mini.inputUSDPerMTok)
    }

    // MARK: - estimatedCostUSD(...)

    @Test("estimatedCostUSD computes cost including cache read/creation tokens")
    func estimatedCostUSDIncludesCacheTokens() {
        // claude-haiku-4-5: input 1.00, output 5.00, cache_read 0.1, cache_write 1.25 (USD/1M).
        let cost = LLMPricing.estimatedCostUSD(
            model: "claude-haiku-4-5-20251001",
            configPricing: [:],
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheReadInputTokens: 1_000_000,
            cacheCreationInputTokens: 1_000_000
        )
        // 1.00 + 5.00 + 0.10 + 1.25 = 7.35
        #expect(cost == 7.35)
    }

    @Test("estimatedCostUSD returns nil when the model resolves to no pricing entry")
    func estimatedCostUSDReturnsNilForUnknownModel() {
        let cost = LLMPricing.estimatedCostUSD(
            model: "some-unknown-model",
            configPricing: [:],
            inputTokens: 100,
            outputTokens: 100,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0
        )
        #expect(cost == nil)
    }

    @Test("estimatedCostUSD returns 0 for a zero-usage call against a resolvable model")
    func estimatedCostUSDZeroUsageIsZero() {
        let cost = LLMPricing.estimatedCostUSD(
            model: "claude-haiku-4-5-20251001",
            configPricing: [:],
            inputTokens: 0,
            outputTokens: 0,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0
        )
        #expect(cost == 0)
    }
}
