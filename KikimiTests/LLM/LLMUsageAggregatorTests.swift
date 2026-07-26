import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `LLMUsageAggregator.summarize(records:configPricing:)`
/// (`docs/design/16-llm-usage-stats.md` section 5): `reportedCostUSD` priority over estimation,
/// the estimation fallback itself, unknown-cost counting, and per-`purpose` breakdowns.
@Suite("LLMUsageAggregator")
struct LLMUsageAggregatorTests {
    private func makeRecord(
        purpose: String = "refinement",
        model: String = "claude-haiku-4-5-20251001",
        inputTokens: Int = 100,
        outputTokens: Int = 50,
        cacheReadInputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        reportedCostUSD: Double? = nil
    ) -> LLMUsageRecord {
        LLMUsageRecord(
            timestamp: Date(timeIntervalSince1970: 1_751_000_000),
            purpose: purpose,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            reportedCostUSD: reportedCostUSD
        )
    }

    @Test("summarize returns .empty for an empty record list")
    func summarizeEmptyRecordsReturnsEmpty() {
        let summary = LLMUsageAggregator.summarize(records: [], configPricing: [:])
        #expect(summary == .empty)
    }

    @Test("summarize prefers reportedCostUSD over the estimated cost when both are available")
    func summarizePrefersReportedCostOverEstimate() {
        // claude-haiku-4-5 estimated cost for 1M/1M tokens would be far more than 0.0001.
        let record = makeRecord(inputTokens: 1_000_000, outputTokens: 1_000_000, reportedCostUSD: 0.0001)
        let summary = LLMUsageAggregator.summarize(records: [record], configPricing: [:])
        #expect(summary.overall.costUSD == 0.0001)
        #expect(summary.overall.unknownCostCallCount == 0)
    }

    @Test("summarize falls back to LLMPricing estimation when reportedCostUSD is nil")
    func summarizeFallsBackToEstimatedCost() {
        let record = makeRecord(
            model: "claude-haiku-4-5-20251001",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            reportedCostUSD: nil
        )
        let summary = LLMUsageAggregator.summarize(records: [record], configPricing: [:])
        // 1.00 (input) + 5.00 (output) per LLMPricing.builtIn's claude-haiku-4-5 entry.
        #expect(summary.overall.costUSD == 6.0)
        #expect(summary.overall.unknownCostCallCount == 0)
    }

    @Test("summarize counts a record with no reported cost and no resolvable pricing as unknownCostCallCount")
    func summarizeCountsUnknownCostCalls() {
        let record = makeRecord(model: "some-unknown-model", reportedCostUSD: nil)
        let summary = LLMUsageAggregator.summarize(records: [record], configPricing: [:])
        #expect(summary.overall.callCount == 1)
        #expect(summary.overall.unknownCostCallCount == 1)
        #expect(summary.overall.costUSD == 0)
        // Token counts still accumulate even when cost is unknown.
        #expect(summary.overall.inputTokens == 100)
        #expect(summary.overall.outputTokens == 50)
    }

    @Test("summarize aggregates token counts and cost across multiple records")
    func summarizeAccumulatesAcrossRecords() {
        let records = [
            makeRecord(inputTokens: 100, outputTokens: 50, reportedCostUSD: 0.01),
            makeRecord(inputTokens: 200, outputTokens: 75, cacheReadInputTokens: 10, reportedCostUSD: 0.02)
        ]
        let summary = LLMUsageAggregator.summarize(records: records, configPricing: [:])
        #expect(summary.overall.callCount == 2)
        #expect(summary.overall.inputTokens == 300)
        #expect(summary.overall.outputTokens == 125)
        #expect(summary.overall.cacheReadInputTokens == 10)
        #expect(summary.overall.costUSD == 0.03)
    }

    @Test("summarize breaks totals down by purpose")
    func summarizeGroupsByPurpose() throws {
        let records = [
            makeRecord(purpose: "refinement", inputTokens: 100, reportedCostUSD: 0.01),
            makeRecord(purpose: "refinement", inputTokens: 100, reportedCostUSD: 0.02),
            makeRecord(purpose: "summary_patch", inputTokens: 200, reportedCostUSD: 0.05)
        ]
        let summary = LLMUsageAggregator.summarize(records: records, configPricing: [:])

        #expect(summary.overall.callCount == 3)
        #expect(summary.overall.costUSD == 0.08)

        let refinementTotals = try #require(summary.byPurpose["refinement"])
        #expect(refinementTotals.callCount == 2)
        #expect(refinementTotals.costUSD == 0.03)
        #expect(refinementTotals.inputTokens == 200)

        let summaryTotals = try #require(summary.byPurpose["summary_patch"])
        #expect(summaryTotals.callCount == 1)
        #expect(summaryTotals.costUSD == 0.05)
    }

    @Test("summarize resolves cost using config pricing overrides when the model has no built-in entry")
    func summarizeUsesConfigPricingOverride() {
        let override = LLMModelPricing(inputUSDPerMTok: 2.0, outputUSDPerMTok: 8.0)
        let record = makeRecord(model: "gpt-4o-deployment", inputTokens: 1_000_000, outputTokens: 1_000_000, reportedCostUSD: nil)
        let summary = LLMUsageAggregator.summarize(records: [record], configPricing: ["gpt-4o-deployment": override])
        #expect(summary.overall.costUSD == 10.0)
        #expect(summary.overall.unknownCostCallCount == 0)
    }
}
