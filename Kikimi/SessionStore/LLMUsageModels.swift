import Foundation

// MARK: - LLMUsageRecord

/// One line of `llm_usage.jsonl` — token usage/cost of a single successful LLM call
/// (`docs/design/16-llm-usage-stats.md` section 2). Encoded via `SessionJSONCoding`
/// (snake_case keys, ISO 8601 dates), same as every other session JSON file.
struct LLMUsageRecord: Codable, Sendable, Equatable {
    var timestamp: Date
    /// What the call was for. Reuses `LLMRequest.stubKey` (`refinement` / `summary_patch` /
    /// `final_title` / ...) — the stub-dispatch key doubles as the purpose label. `"unknown"` when
    /// the request carried no stubKey.
    var purpose: String
    /// The model that actually answered this call when the backend reports one
    /// (`LLMBackendResponse.respondedModel`, forwarded via `LLMResult`), otherwise the model id the
    /// request was made with (`LLMRequest.model`). These two values can differ for the `openai`
    /// provider against an Azure legacy deployment URL, where the request body's `model` is a
    /// config default Azure ignores server-side (`docs/design/16-llm-usage-stats.md` section 2).
    var model: String
    /// Uncached input tokens only — cache read/creation tokens are counted separately below
    /// (Anthropic usage semantics; `OpenAIChatBackend` normalizes its `prompt_tokens` to match).
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadInputTokens: Int
    var cacheCreationInputTokens: Int
    /// Backend-reported cost (claude CLI's `total_cost_usd`). `nil` when the backend reports no
    /// cost (OpenAI-compatible provider) — the estimated cost is then computed at read time from
    /// `LLMPricing`, never persisted (design section 2's "価格表を後から修正しても過去分に反映").
    var reportedCostUSD: Double?

    /// Explicit `CodingKeys` are required for this one field: `SessionJSONCoding`'s shared
    /// `.convertToSnakeCase`/`.convertFromSnakeCase` strategies are not exact inverses of each other
    /// for a trailing all-caps acronym. Encoding the synthesized key `"reportedCostUSD"` with
    /// `.convertToSnakeCase` produces `"reported_cost_usd"` (correct, matches this section's
    /// documented field name) — but decoding that same string back with `.convertFromSnakeCase`
    /// produces the candidate key `"reportedCostUsd"` (lowercase "sd"), which does not match the
    /// synthesized `"reportedCostUSD"` case, so the field silently decoded to `nil` on every read
    /// despite a correct round-trip encode. Every other field here is plain lowercase-suffixed
    /// (`inputTokens`, `cacheReadInputTokens`, ...) and round-trips fine without this workaround —
    /// only the acronym suffix needs its rawValue spelled out to match what `.convertFromSnakeCase`
    /// actually produces.
    enum CodingKeys: String, CodingKey {
        case timestamp
        case purpose
        case model
        case inputTokens
        case outputTokens
        case cacheReadInputTokens
        case cacheCreationInputTokens
        case reportedCostUSD = "reportedCostUsd"
    }

    /// Shared factory for building a record from a completed LLM call (`docs/design/16-llm-usage-
    /// stats.md` section 3.2). Both of `UsageRecordingLLM`'s entry points (`complete(_:)`/
    /// `completeRaw(_:)`) funnel through this, so the two mapping rules below are defined exactly
    /// once:
    /// - `reportedCostUSD`: `nil` when `usage.totalCostUSD` is `0`, not `0` itself. `0` would be
    ///   indistinguishable from "the backend reported a confirmed cost of exactly zero", and
    ///   `LLMUsageAggregator` reads a non-nil `reportedCostUSD` as authoritative -- persisting a
    ///   literal `0` would pin that call's displayed cost at $0 forever, even after `LLMPricing`
    ///   is corrected later.
    /// - `model`: `respondedModel` when the backend reported one, else `requestedModel` (see
    ///   `LLMResult.respondedModel`'s doc comment for why these can differ).
    static func make(
        usage: LLMUsage,
        respondedModel: String?,
        requestedModel: String,
        purpose: String,
        timestamp: Date
    ) -> LLMUsageRecord {
        LLMUsageRecord(
            timestamp: timestamp,
            purpose: purpose,
            model: respondedModel ?? requestedModel,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadInputTokens: usage.cacheReadInputTokens,
            cacheCreationInputTokens: usage.cacheCreationInputTokens,
            reportedCostUSD: usage.totalCostUSD > 0 ? usage.totalCostUSD : nil
        )
    }
}
