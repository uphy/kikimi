import Combine
import Foundation

// MARK: - MeetingWorkspaceViewModel + LLM Usage
//
// Split into its own file to keep `MeetingWorkspaceViewModel.swift` under the project's
// `file_length` lint limit, alongside `+Summary.swift`/`+Refinement.swift`. Observes
// `UsageRecordingLLM`'s `.kikimiLLMUsageRecorded` notification and republishes `llmUsageSummary`
// (`docs/design/16-llm-usage-stats.md` section 5) for the header's cost badge
// (`Kikimi/Views/MeetingWorkspace/LLMUsageBadge.swift`).

extension MeetingWorkspaceViewModel {
    /// Starts observing `.kikimiLLMUsageRecorded` notifications for *this* session only, called
    /// once from `onAppear()`. Every matching notification triggers a full `llm_usage.jsonl`
    /// re-read + re-aggregate rather than an incremental update -- usage records arrive at most a
    /// few times a minute (once per refinement batch / summary update), so a full re-read is cheap
    /// enough (design section 5's "呼び出し頻度は高々バッチ毎…全読みで十分").
    func startObservingLLMUsage() {
        llmUsageObservation = NotificationCenter.default.publisher(for: .kikimiLLMUsageRecorded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, notification.userInfo?["sessionId"] as? String == self.sessionId else { return }
                Task { await self.refreshLLMUsage() }
            }
    }

    /// Re-reads `llm_usage.jsonl` and re-aggregates `llmUsageSummary` against
    /// `appConfig.data.llm.pricing` (design section 4/5). Called once from `onAppear()` (so a
    /// reopened session shows its already-accumulated cost immediately) and again from
    /// `startObservingLLMUsage()`'s notification sink. A read failure is logged and leaves
    /// `llmUsageSummary` at its previous value -- never worth surfacing a banner over.
    func refreshLLMUsage() async {
        do {
            let records = try await sessionHandle.readLLMUsageRecords()
            llmUsageSummary = LLMUsageAggregator.summarize(records: records, configPricing: appConfig.data.llm.pricing)
        } catch {
            logger.error(
                "Failed to read llm_usage.jsonl for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
