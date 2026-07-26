import Foundation

// MARK: - LLMUsageTotals

/// Aggregated call count/token counts/cost over some set of `LLMUsageRecord`s
/// (`docs/design/16-llm-usage-stats.md` section 5). Used both for the grand total
/// (`LLMUsageSummary.overall`) and per-`purpose` breakdowns (`LLMUsageSummary.byPurpose`).
struct LLMUsageTotals: Equatable, Sendable {
    var callCount: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadInputTokens: Int = 0
    var cacheCreationInputTokens: Int = 0
    var costUSD: Double = 0
    /// Number of calls whose cost could not be determined (no `reportedCostUSD` and no resolvable
    /// `LLMPricing` entry, design section 4's "価格表に無いモデル"). These calls still contribute their
    /// token counts above -- only `costUSD` excludes them.
    var unknownCostCallCount: Int = 0

    static let zero = LLMUsageTotals()
}

// MARK: - LLMUsageSummary

/// Result of `LLMUsageAggregator.summarize(records:configPricing:)`: the grand total plus a
/// per-`purpose` breakdown, both consumed by the header's cost badge/popover
/// (`docs/design/16-llm-usage-stats.md` section 5).
struct LLMUsageSummary: Equatable, Sendable {
    var overall: LLMUsageTotals = .zero
    var byPurpose: [String: LLMUsageTotals] = [:]

    static let empty = LLMUsageSummary()
}

// MARK: - LLMUsageAggregator

/// Pure aggregation over `llm_usage.jsonl`'s decoded records (`docs/design/16-llm-usage-stats.md`
/// section 5). Deliberately has no I/O of its own -- `MeetingWorkspaceViewModel+LLMUsage.swift`
/// reads the records via `SessionHandle.readLLMUsageRecords()` and passes them here.
enum LLMUsageAggregator {
    /// Per-line cost resolution: `record.reportedCostUSD` wins when present (design section 4's "行
    /// ごとのコスト" priority), otherwise falls back to `LLMPricing.estimatedCostUSD`. A record with
    /// neither is counted in `unknownCostCallCount` and excluded from `costUSD`, but its token
    /// counts still accumulate into every other field.
    static func summarize(records: [LLMUsageRecord], configPricing: [String: LLMModelPricing]) -> LLMUsageSummary {
        var overall = LLMUsageTotals.zero
        var byPurpose: [String: LLMUsageTotals] = [:]

        for record in records {
            let cost = resolvedCost(for: record, configPricing: configPricing)
            apply(record, cost: cost, to: &overall)
            var purposeTotals = byPurpose[record.purpose] ?? .zero
            apply(record, cost: cost, to: &purposeTotals)
            byPurpose[record.purpose] = purposeTotals
        }

        return LLMUsageSummary(overall: overall, byPurpose: byPurpose)
    }

    private static func resolvedCost(for record: LLMUsageRecord, configPricing: [String: LLMModelPricing]) -> Double? {
        if let reported = record.reportedCostUSD {
            return reported
        }
        return LLMPricing.estimatedCostUSD(
            model: record.model,
            configPricing: configPricing,
            inputTokens: record.inputTokens,
            outputTokens: record.outputTokens,
            cacheReadInputTokens: record.cacheReadInputTokens,
            cacheCreationInputTokens: record.cacheCreationInputTokens
        )
    }

    private static func apply(_ record: LLMUsageRecord, cost: Double?, to totals: inout LLMUsageTotals) {
        totals.callCount += 1
        totals.inputTokens += record.inputTokens
        totals.outputTokens += record.outputTokens
        totals.cacheReadInputTokens += record.cacheReadInputTokens
        totals.cacheCreationInputTokens += record.cacheCreationInputTokens
        if let cost {
            totals.costUSD += cost
        } else {
            totals.unknownCostCallCount += 1
        }
    }
}
