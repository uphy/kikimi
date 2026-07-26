import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `LLMUsageRecord.make(...)` (`docs/design/16-llm-usage-stats.md` section
/// 3.2), the shared factory `UsageRecordingLLM.recordUsage` funnels through. These two mapping
/// rules are the ones that matter -- everything else is a straight field copy:
/// - `reportedCostUSD` must be `nil` (not `0`) when `usage.totalCostUSD == 0`, or
///   `LLMUsageAggregator` reads the persisted `0` as confirmed and pins the call's displayed cost
///   at $0 forever.
/// - `model` prefers `respondedModel` over `requestedModel` when the backend reported one.
@Suite("LLMUsageRecord.make")
struct LLMUsageRecordFactoryTests {
    private let timestamp = Date(timeIntervalSince1970: 1_751_000_500)

    private func makeUsage(totalCostUSD: Double) -> LLMUsage {
        LLMUsage(
            inputTokens: 100,
            outputTokens: 50,
            cacheReadInputTokens: 10,
            cacheCreationInputTokens: 5,
            totalCostUSD: totalCostUSD
        )
    }

    @Test("reportedCostUSD is nil when usage.totalCostUSD is zero")
    func nilCostWhenTotalCostIsZero() {
        let record = LLMUsageRecord.make(
            usage: makeUsage(totalCostUSD: 0),
            respondedModel: nil,
            requestedModel: "claude-haiku-4-5-20251001",
            purpose: "refinement",
            timestamp: timestamp
        )

        #expect(record.reportedCostUSD == nil)
    }

    @Test("reportedCostUSD carries usage.totalCostUSD unchanged when it is greater than zero")
    func carriesCostWhenTotalCostIsPositive() {
        let record = LLMUsageRecord.make(
            usage: makeUsage(totalCostUSD: 0.01),
            respondedModel: nil,
            requestedModel: "claude-haiku-4-5-20251001",
            purpose: "refinement",
            timestamp: timestamp
        )

        #expect(record.reportedCostUSD == 0.01)
    }

    @Test("model prefers respondedModel over requestedModel when the backend reported one")
    func modelPrefersRespondedModel() {
        let record = LLMUsageRecord.make(
            usage: makeUsage(totalCostUSD: 0),
            respondedModel: "gpt-5.4-nano",
            requestedModel: "claude-haiku-4-5-20251001",
            purpose: "refinement",
            timestamp: timestamp
        )

        #expect(record.model == "gpt-5.4-nano")
    }

    @Test("model falls back to requestedModel when respondedModel is nil")
    func modelFallsBackToRequestedModel() {
        let record = LLMUsageRecord.make(
            usage: makeUsage(totalCostUSD: 0),
            respondedModel: nil,
            requestedModel: "claude-haiku-4-5-20251001",
            purpose: "refinement",
            timestamp: timestamp
        )

        #expect(record.model == "claude-haiku-4-5-20251001")
    }

    @Test("every other field is a straight copy from usage/purpose/timestamp")
    func copiesRemainingFieldsUnchanged() {
        let record = LLMUsageRecord.make(
            usage: makeUsage(totalCostUSD: 0.02),
            respondedModel: nil,
            requestedModel: "claude-haiku-4-5-20251001",
            purpose: "summary_patch",
            timestamp: timestamp
        )

        #expect(record.purpose == "summary_patch")
        #expect(record.inputTokens == 100)
        #expect(record.outputTokens == 50)
        #expect(record.cacheReadInputTokens == 10)
        #expect(record.cacheCreationInputTokens == 5)
        #expect(record.timestamp == timestamp)
    }
}
