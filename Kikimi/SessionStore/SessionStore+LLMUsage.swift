import Foundation
import OSLog

// MARK: - SessionStore + LLM Usage (all-session aggregation)

/// Session-List-wide LLM usage read path (`docs/design/16-llm-usage-stats.md` section 5's Session
/// List footer all-time total). Split into its own file for the same reason as
/// `SessionStore+CrashRecovery.swift`: keep `SessionStore.swift`'s primary declaration focused on
/// the lifecycle/registry API.
///
/// `readAllLLMUsageRecords()` deliberately does **not** go through `openSession(_:)`: that call
/// caches a `SessionHandle` for every session for the lifetime of this (long-running menu bar app)
/// process and, via `ensureTranscriptAndRefinedLogFilesExist()`, creates empty
/// `transcript.jsonl`/`refined.jsonl` files for sessions that were never actually opened this run —
/// neither side effect is acceptable just to read a cost total across every session in the list.
/// Instead this reads each session's `llm_usage.jsonl` directly via `sessionDirectoryURLs()`
/// (`SessionStore.swift`) and the parsing core shared with `SessionHandle.readLLMUsageRecords()`
/// (`LLMUsageJSONLFile`, `SessionHandle+LLMUsage.swift`).
extension SessionStore {
    private static let llmUsageLogger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SessionStore.LLMUsage")

    /// Reads every session folder's `llm_usage.jsonl` and returns every record across all of them,
    /// in no particular cross-session order (`LLMUsageAggregator.summarize(records:configPricing:)`
    /// does not care about ordering). A session with no `llm_usage.jsonl` at all (never called an
    /// LLM) contributes zero records; a session whose file cannot be read at all (permissions, a
    /// directory that disappeared mid-scan, etc.) is skipped with a logged error so the rest of the
    /// aggregation still completes — the same "skip one, keep going" tolerance `listSessions()`
    /// applies to a corrupt `meta.json`. An empty/missing sessions root simply yields no directories
    /// to iterate, so this returns `[]` without any special-casing.
    func readAllLLMUsageRecords() async -> [LLMUsageRecord] {
        var allRecords: [LLMUsageRecord] = []
        for directoryURL in sessionDirectoryURLs() {
            let sessionId = directoryURL.lastPathComponent
            let fileURL = directoryURL.appendingPathComponent((try? SessionFile.llmUsageJSONL.relativePath()) ?? "llm_usage.jsonl")
            do {
                let records = try LLMUsageJSONLFile.read(from: fileURL, loggingContext: "session \(sessionId)")
                allRecords.append(contentsOf: records)
            } catch {
                Self.llmUsageLogger.error(
                    "Skipping session \(sessionId, privacy: .public) while aggregating all-session LLM usage: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return allRecords
    }
}
