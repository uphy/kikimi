import Foundation
import OSLog

// MARK: - Notification.Name

extension Notification.Name {
    /// Posted by `UsageRecordingLLM` after it successfully appends a call's usage record to
    /// `llm_usage.jsonl` (`docs/design/16-llm-usage-stats.md` section 3/5). `userInfo["sessionId"]`
    /// carries the session the record belongs to, so `MeetingWorkspaceViewModel` can ignore
    /// notifications from every session but its own.
    static let kikimiLLMUsageRecorded = Notification.Name("io.github.uphy.Kikimi.llmUsageRecorded")
}

// MARK: - UsageRecordingLLM

/// `LLMCompleting` decorator that records every successful call's token usage/cost to
/// `sessions/<id>/llm_usage.jsonl` (`docs/design/16-llm-usage-stats.md` section 3). This -- not
/// `LLMClient` itself -- is where session persistence happens, keeping `LLMClient`'s "never touches
/// session storage" contract intact (`docs/design/12-llm-client.md` section 8). Wraps `LLMClient
/// .shared` at the two production call sites that make session-scoped LLM calls
/// (`MeetingWorkspaceViewModel+Factories.swift`'s `defaultSummaryUpdaterFactory`/
/// `defaultRefinementQueueFactory`); `RefinementQueue`/`SummaryUpdater` themselves are unaware this
/// decorator exists.
struct UsageRecordingLLM: LLMCompleting {
    let base: LLMCompleting
    let sessionHandle: SessionHandle
    /// Injectable wall clock for `LLMUsageRecord.timestamp`, so tests can assert its value
    /// deterministically instead of racing `Date()`. Defaults to the real clock.
    var now: @Sendable () -> Date = { Date() }

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "UsageRecordingLLM")

    /// Forwards to `base.complete(_:)` unchanged (including rethrowing any error without recording --
    /// design section 6's "LLM 呼び出し失敗 -> 記録しない"). Once `base` returns successfully, records
    /// usage via `recordUsage(_:for:)` below.
    func complete<T: Decodable & Sendable>(_ request: LLMRequest) async throws -> LLMResult<T> {
        let result: LLMResult<T> = try await base.complete(request)
        await recordUsage(result.usage, respondedModel: result.respondedModel, for: request)
        return result
    }

    /// Raw-JSON counterpart of `complete(_:)` (`docs/design/05-watcher-runner.md` §5.1): forwards to
    /// `base.completeRaw(_:)` unchanged, then records usage exactly like `complete(_:)` does --
    /// `WatcherRunner`'s calls get the same `llm_usage.jsonl`/`.kikimiLLMUsageRecorded` bookkeeping
    /// as every other LLM consumer, without `WatcherRunner` itself knowing this decorator exists.
    func completeRaw(_ request: LLMRequest) async throws -> LLMResult<Data> {
        let result = try await base.completeRaw(request)
        await recordUsage(result.usage, respondedModel: result.respondedModel, for: request)
        return result
    }

    /// Shared success-path bookkeeping for `complete(_:)`/`completeRaw(_:)`: appends a
    /// `LLMUsageRecord` and posts `.kikimiLLMUsageRecorded`. A failure to append is logged as a
    /// warning only and never propagated -- the LLM call itself already succeeded and must not be
    /// turned into a failure by a bookkeeping problem (design section 6's "記録の append 失敗 -> warning
    /// ログのみ").
    ///
    /// `respondedModel` (forwarded from `LLMBackendResponse.respondedModel`) is preferred over
    /// `request.model` when the backend reported one: for the `openai` provider against an Azure
    /// legacy deployment URL, the request body's `model` is a `refinement.model`/`summary.model`
    /// config default that Azure ignores server-side, so it does not reflect which model actually
    /// answered (`docs/design/16-llm-usage-stats.md` section 2). `ClaudeCLIBackend` never reports one,
    /// so this keeps recording `request.model` there, unchanged from before.
    private func recordUsage(_ usage: LLMUsage, respondedModel: String?, for request: LLMRequest) async {
        let record = LLMUsageRecord.make(
            usage: usage,
            respondedModel: respondedModel,
            requestedModel: request.model,
            purpose: request.stubKey ?? "unknown",
            timestamp: now()
        )

        do {
            try await sessionHandle.appendLLMUsageRecord(record)
            NotificationCenter.default.post(
                name: .kikimiLLMUsageRecorded,
                object: nil,
                userInfo: ["sessionId": sessionHandle.sessionId]
            )
        } catch {
            Self.logger.warning(
                "Failed to append llm_usage.jsonl record for session \(sessionHandle.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
