import Foundation
import OSLog

// MARK: - SessionHandle + LLM Usage (llm_usage.jsonl)

/// Append-only logging of `llm_usage.jsonl` and its full-file readback
/// (`docs/design/16-llm-usage-stats.md` sections 2/6). Split into its own file for the same
/// `file_length` reason as `SessionHandle+Transcript.swift`.
///
/// Unlike `transcript.jsonl`/`refined.jsonl` (appended for every STT segment, so their
/// `FileHandle`s are opened once and cached in `AppendOnlyLogFileRegistry`), usage records arrive
/// at most once per LLM batch — a few times a minute. At that rate an open-seek-write-close per
/// append is plenty, keeps this extension self-contained (that registry is `private` to
/// `SessionHandle+Transcript.swift` by design), and leaves nothing to clean up on session delete.
extension SessionHandle {
    /// Appends one record as a single JSONL line. Creating the file on first append is fine here
    /// (kikimi.md 4 章's "セッション作成時点で存在するファイル" list doesn't include `llm_usage.jsonl`;
    /// sessions that never call an LLM simply never get one).
    func appendLLMUsageRecord(_ record: LLMUsageRecord) async throws {
        let fileURL = try llmUsageFileURL()
        var line = try LLMUsageSessionJSON.encoder.encode(record)
        line.append(0x0A) // "\n"

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
            }
        }
        guard let handle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Full read of `llm_usage.jsonl`. Returns an empty array if the file does not exist yet.
    /// Same corrupt-line tolerance contract as `readTranscriptSegments()`: a malformed line is
    /// skipped with a log (warning for the trailing line — likely a mid-write crash — error
    /// elsewhere) and never loses the remaining records. Delegates the actual parsing to
    /// `LLMUsageJSONLFile.read(from:loggingContext:)`, shared with `SessionStore
    /// .readAllLLMUsageRecords()` (`SessionStore+LLMUsage.swift`,
    /// `docs/design/16-llm-usage-stats.md` section 5) so the two read paths can never drift apart.
    func readLLMUsageRecords() async throws -> [LLMUsageRecord] {
        let fileURL = try llmUsageFileURL()
        return try LLMUsageJSONLFile.read(from: fileURL, loggingContext: "session \(sessionId)")
    }

    private func llmUsageFileURL() throws -> URL {
        directoryURL.appendingPathComponent(try SessionFile.llmUsageJSONL.relativePath())
    }
}

// MARK: - LLMUsageJSONLFile

/// Shared `llm_usage.jsonl` line-parsing core, factored out of `SessionHandle
/// .readLLMUsageRecords()` above so `SessionStore.readAllLLMUsageRecords()`
/// (`SessionStore+LLMUsage.swift`) — which reads every session's `llm_usage.jsonl` directly rather
/// than through a `SessionHandle` (`docs/design/16-llm-usage-stats.md` section 5's "openSession を
/// 使わない" requirement) — can reuse the exact same corrupt-line tolerance instead of
/// reimplementing it. Not `private`: both call sites live in different files.
enum LLMUsageJSONLFile {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "LLMUsageJSONLFile")

    /// Reads and decodes every line of the `llm_usage.jsonl` at `fileURL`. Returns an empty array
    /// if the file does not exist. `loggingContext` identifies the owning session in log messages
    /// (a session id, or a directory name when no `SessionHandle` was ever opened for it).
    static func read(from fileURL: URL, loggingContext: String) throws -> [LLMUsageRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
            return []
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        var records: [LLMUsageRecord] = []
        records.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            do {
                records.append(try LLMUsageSessionJSON.decoder.decode(LLMUsageRecord.self, from: Data(line.utf8)))
            } catch {
                let level: OSLogType = index == lines.count - 1 ? .default : .error
                logger.log(
                    level: level,
                    "Skipping a malformed line (index \(index, privacy: .public)) in llm_usage.jsonl for \(loggingContext, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return records
    }
}

// MARK: - LLMUsageSessionJSON

/// Cached `JSONEncoder`/`JSONDecoder` for `llm_usage.jsonl` lines, built via `SessionJSONCoding`
/// so key/date strategies match every other session JSON file (same pattern as
/// `TranscriptSessionJSON` in `SessionHandle+Transcript.swift`, which is `private` to that file).
private enum LLMUsageSessionJSON {
    static let encoder = SessionJSONCoding.makeEncoder()
    static let decoder = SessionJSONCoding.makeDecoder()
}
