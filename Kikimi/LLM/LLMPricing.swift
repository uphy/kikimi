import Foundation

// MARK: - LLMModelPricing

/// USD-per-1M-tokens pricing for one model (`docs/design/16-llm-usage-stats.md` section 4). Decoded
/// straight from `config.yaml`'s `llm.pricing.<model>` entries via Yams (same `YAMLDecoder` path as
/// every other `AppConfig` section) as well as constructed for `LLMPricing.builtIn`'s in-code table.
struct LLMModelPricing: Codable, Equatable, Sendable {
    var inputUSDPerMTok: Double
    var outputUSDPerMTok: Double
    /// Prompt-cache read price. Defaults to `inputUSDPerMTok * 0.1` when omitted (design section 4:
    /// Anthropic's cache-read discount).
    var cacheReadUSDPerMTok: Double
    /// Prompt-cache write price. Defaults to `inputUSDPerMTok * 1.25` when omitted (design section 4:
    /// Anthropic's 5-minute-TTL cache-write premium).
    var cacheWriteUSDPerMTok: Double

    enum CodingKeys: String, CodingKey {
        case inputUSDPerMTok = "input"
        case outputUSDPerMTok = "output"
        case cacheReadUSDPerMTok = "cache_read"
        case cacheWriteUSDPerMTok = "cache_write"
    }

    init(
        inputUSDPerMTok: Double,
        outputUSDPerMTok: Double,
        cacheReadUSDPerMTok: Double? = nil,
        cacheWriteUSDPerMTok: Double? = nil
    ) {
        self.inputUSDPerMTok = inputUSDPerMTok
        self.outputUSDPerMTok = outputUSDPerMTok
        self.cacheReadUSDPerMTok = cacheReadUSDPerMTok ?? inputUSDPerMTok * 0.1
        self.cacheWriteUSDPerMTok = cacheWriteUSDPerMTok ?? inputUSDPerMTok * 1.25
    }

    /// Custom decoder so `cache_read`/`cache_write` can be omitted from a hand-written
    /// `config.yaml` entry and still resolve to their `input`-derived defaults above, rather than
    /// synthesized `Decodable` conformance requiring every key (mirrors `DiarizationConfig.init(
    /// from:)`'s leniency pattern in `Kikimi/Config/AppConfig.swift`). `input`/`output` stay
    /// required: design section 4 documents them as mandatory per pricing entry.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let input = try container.decode(Double.self, forKey: .inputUSDPerMTok)
        let output = try container.decode(Double.self, forKey: .outputUSDPerMTok)
        let cacheRead = try container.decodeIfPresent(Double.self, forKey: .cacheReadUSDPerMTok)
        let cacheWrite = try container.decodeIfPresent(Double.self, forKey: .cacheWriteUSDPerMTok)
        self.init(inputUSDPerMTok: input, outputUSDPerMTok: output, cacheReadUSDPerMTok: cacheRead, cacheWriteUSDPerMTok: cacheWrite)
    }
}

// MARK: - LLMPricing

/// Resolves a model id to its `LLMModelPricing` and computes estimated call cost
/// (`docs/design/16-llm-usage-stats.md` section 4). Resolution is prefix-match, longest-match-wins,
/// checking `config.yaml`'s `llm.pricing` before `builtIn` -- so a config entry for e.g.
/// `"claude-haiku"` still loses to a more specific built-in `"claude-haiku-4-5"` entry if the
/// model id matches both, and a config override for the exact same prefix wins over the built-in
/// with the same prefix.
enum LLMPricing {
    /// In-code price table (design section 4), USD per 1M tokens, keyed by model id prefix.
    ///
    /// Anthropic models rely on `LLMModelPricing`'s `cache_read`/`cache_write` defaults
    /// (input × 0.1 / input × 1.25) rather than spelling them out here.
    ///
    /// OpenAI/Azure models spell out `cache_read` with the provider's published cached-input price
    /// and set `cache_write` equal to `input`: unlike Anthropic, OpenAI/Azure charge no
    /// cache-creation premium (cache writes bill at the normal input rate), and `OpenAIChatBackend`
    /// never reports `cacheCreationInputTokens` anyway. Prices verified 2026-07 (2026-08 for the
    /// `gpt-5.6` series) against OpenAI's official model pages; Azure Global Standard bills the same
    /// per-token rate. Prefix match is longest-wins, so dated ids (`gpt-4.1-mini-2025-04-14`) and the
    /// specific-over-generic pairs (`gpt-4o-mini` over `gpt-4o`, `gpt-5-mini` over `gpt-5`,
    /// `gpt-5.6-luna` over `gpt-5.6` over `gpt-5`) all resolve correctly. Azure deployment-name ids
    /// that don't start with a real model id still need a `llm.pricing` override.
    ///
    /// Moonshot (Kimi) models follow the OpenAI convention for the same reason -- they are only ever
    /// reachable through an `openai`-kind provider (a LiteLLM proxy), where cache creation is neither
    /// billed separately nor reported.
    static let builtIn: [String: LLMModelPricing] = [
        // Anthropic (kikimi.md 12 章)
        "claude-haiku-4-5": LLMModelPricing(inputUSDPerMTok: 1.00, outputUSDPerMTok: 5.00),
        "claude-sonnet-4-5": LLMModelPricing(inputUSDPerMTok: 3.00, outputUSDPerMTok: 15.00),
        "claude-sonnet-4-6": LLMModelPricing(inputUSDPerMTok: 3.00, outputUSDPerMTok: 15.00),
        // Introductory pricing, in effect through 2026-08-31. From 2026-09-01 Sonnet 5 reverts to the
        // 3.00 / 15.00 of Sonnet 4.5/4.6 -- update this entry (or add a `llm.pricing` override) then.
        "claude-sonnet-5": LLMModelPricing(inputUSDPerMTok: 2.00, outputUSDPerMTok: 10.00),
        "claude-opus-4-5": LLMModelPricing(inputUSDPerMTok: 5.00, outputUSDPerMTok: 25.00),
        "claude-opus-4-6": LLMModelPricing(inputUSDPerMTok: 5.00, outputUSDPerMTok: 25.00),
        "claude-opus-4-7": LLMModelPricing(inputUSDPerMTok: 5.00, outputUSDPerMTok: 25.00),
        "claude-opus-4-8": LLMModelPricing(inputUSDPerMTok: 5.00, outputUSDPerMTok: 25.00),
        "claude-opus-5": LLMModelPricing(inputUSDPerMTok: 5.00, outputUSDPerMTok: 25.00),
        "claude-fable-5": LLMModelPricing(inputUSDPerMTok: 10.00, outputUSDPerMTok: 50.00),

        // OpenAI / Azure OpenAI (verified 2026-07/2026-08; cache_write == input, no cache-creation premium)
        "gpt-4.1-mini": LLMModelPricing(inputUSDPerMTok: 0.40, outputUSDPerMTok: 1.60, cacheReadUSDPerMTok: 0.10, cacheWriteUSDPerMTok: 0.40),
        "gpt-4.1-nano": LLMModelPricing(inputUSDPerMTok: 0.10, outputUSDPerMTok: 0.40, cacheReadUSDPerMTok: 0.025, cacheWriteUSDPerMTok: 0.10),
        "gpt-4.1": LLMModelPricing(inputUSDPerMTok: 2.00, outputUSDPerMTok: 8.00, cacheReadUSDPerMTok: 0.50, cacheWriteUSDPerMTok: 2.00),
        "gpt-4o-mini": LLMModelPricing(inputUSDPerMTok: 0.15, outputUSDPerMTok: 0.60, cacheReadUSDPerMTok: 0.075, cacheWriteUSDPerMTok: 0.15),
        "gpt-4o": LLMModelPricing(inputUSDPerMTok: 2.50, outputUSDPerMTok: 10.00, cacheReadUSDPerMTok: 1.25, cacheWriteUSDPerMTok: 2.50),
        "o4-mini": LLMModelPricing(inputUSDPerMTok: 1.10, outputUSDPerMTok: 4.40, cacheReadUSDPerMTok: 0.275, cacheWriteUSDPerMTok: 1.10),
        "o3-mini": LLMModelPricing(inputUSDPerMTok: 1.10, outputUSDPerMTok: 4.40, cacheReadUSDPerMTok: 0.55, cacheWriteUSDPerMTok: 1.10),
        "o3": LLMModelPricing(inputUSDPerMTok: 2.00, outputUSDPerMTok: 8.00, cacheReadUSDPerMTok: 0.50, cacheWriteUSDPerMTok: 2.00),
        "gpt-5.6-luna": LLMModelPricing(inputUSDPerMTok: 0.20, outputUSDPerMTok: 1.20, cacheReadUSDPerMTok: 0.02, cacheWriteUSDPerMTok: 0.20),
        "gpt-5.6-sol": LLMModelPricing(inputUSDPerMTok: 5.00, outputUSDPerMTok: 30.00, cacheReadUSDPerMTok: 0.50, cacheWriteUSDPerMTok: 5.00),
        "gpt-5.6-terra": LLMModelPricing(inputUSDPerMTok: 2.00, outputUSDPerMTok: 12.00, cacheReadUSDPerMTok: 0.20, cacheWriteUSDPerMTok: 2.00),
        // Family fallback for any other `gpt-5.6-*` id: same rate as the top-tier `sol` variant, so an
        // unrecognized variant is over-estimated rather than silently dropped as unpriced.
        "gpt-5.6": LLMModelPricing(inputUSDPerMTok: 5.00, outputUSDPerMTok: 30.00, cacheReadUSDPerMTok: 0.50, cacheWriteUSDPerMTok: 5.00),
        "gpt-5.5": LLMModelPricing(inputUSDPerMTok: 5.00, outputUSDPerMTok: 30.00, cacheReadUSDPerMTok: 0.50, cacheWriteUSDPerMTok: 5.00),
        "gpt-5.4-mini": LLMModelPricing(inputUSDPerMTok: 0.75, outputUSDPerMTok: 4.50, cacheReadUSDPerMTok: 0.075, cacheWriteUSDPerMTok: 0.75),
        "gpt-5.4-nano": LLMModelPricing(inputUSDPerMTok: 0.20, outputUSDPerMTok: 1.25, cacheReadUSDPerMTok: 0.02, cacheWriteUSDPerMTok: 0.20),
        "gpt-5.4": LLMModelPricing(inputUSDPerMTok: 2.50, outputUSDPerMTok: 15.00, cacheReadUSDPerMTok: 0.25, cacheWriteUSDPerMTok: 2.50),
        "gpt-5-mini": LLMModelPricing(inputUSDPerMTok: 0.25, outputUSDPerMTok: 2.00, cacheReadUSDPerMTok: 0.025, cacheWriteUSDPerMTok: 0.25),
        "gpt-5-nano": LLMModelPricing(inputUSDPerMTok: 0.05, outputUSDPerMTok: 0.40, cacheReadUSDPerMTok: 0.005, cacheWriteUSDPerMTok: 0.05),
        "gpt-5": LLMModelPricing(inputUSDPerMTok: 1.25, outputUSDPerMTok: 10.00, cacheReadUSDPerMTok: 0.125, cacheWriteUSDPerMTok: 1.25),

        // Moonshot / Kimi (api.moonshot.ai USD rates, verified 2026-08). `cache_read` is Moonshot's
        // published cache-hit input price; automatic context caching has no creation charge, so
        // `cache_write` mirrors `input` like the OpenAI entries above. `kimi-k2.6` also prices the
        // `-preview` id by prefix.
        "kimi-k2.5": LLMModelPricing(inputUSDPerMTok: 0.60, outputUSDPerMTok: 3.00, cacheReadUSDPerMTok: 0.10, cacheWriteUSDPerMTok: 0.60),
        "kimi-k2.6": LLMModelPricing(inputUSDPerMTok: 0.95, outputUSDPerMTok: 4.00, cacheReadUSDPerMTok: 0.16, cacheWriteUSDPerMTok: 0.95)
    ]

    /// Prefix-match, longest-match-wins resolution: `configPricing` first, `builtIn` second. `nil`
    /// when neither table has a prefix of `model` (design section 4's "価格表に無いモデル" case).
    static func resolve(model: String, configPricing: [String: LLMModelPricing]) -> LLMModelPricing? {
        longestPrefixMatch(model: model, table: configPricing) ?? longestPrefixMatch(model: model, table: builtIn)
    }

    /// Estimated cost for one call, or `nil` if `model` resolves to no pricing entry in either table
    /// (design section 4's formula: `(input×in + output×out + cache_read×cr + cache_creation×cw) /
    /// 1_000_000`).
    static func estimatedCostUSD(
        model: String,
        configPricing: [String: LLMModelPricing],
        inputTokens: Int,
        outputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int
    ) -> Double? {
        guard let pricing = resolve(model: model, configPricing: configPricing) else { return nil }
        let total =
            Double(inputTokens) * pricing.inputUSDPerMTok
            + Double(outputTokens) * pricing.outputUSDPerMTok
            + Double(cacheReadInputTokens) * pricing.cacheReadUSDPerMTok
            + Double(cacheCreationInputTokens) * pricing.cacheWriteUSDPerMTok
        return total / 1_000_000
    }

    private static func longestPrefixMatch(model: String, table: [String: LLMModelPricing]) -> LLMModelPricing? {
        var bestKey: String?
        var bestPricing: LLMModelPricing?
        for (key, pricing) in table where model.hasPrefix(key) {
            if bestKey == nil || key.count > bestKey!.count {
                bestKey = key
                bestPricing = pricing
            }
        }
        return bestPricing
    }
}
