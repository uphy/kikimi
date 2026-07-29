import Foundation
import OSLog

// MARK: - SessionHandle + Chat (chat.jsonl)

/// Append-only logging of `chat.jsonl` and its full-file readback
/// (`docs/design/38-session-chat.md` §3.4). Modeled directly on `SessionHandle+LLMUsage.swift`:
/// chat turns arrive at human typing speed, so an open-seek-write-close per append is more than
/// fast enough and keeps this extension independent of the cached-`FileHandle` registry that
/// `SessionHandle+Transcript.swift` keeps `private` to itself.
extension SessionHandle {
    /// Appends one turn as a single JSONL line. The file is created on first append -- a session
    /// where nobody opened the chat tab simply never grows one (same as `llm_usage.jsonl`).
    func appendChatTurn(_ turn: ChatTurn) async throws {
        let fileURL = try chatFileURL()
        var line = try ChatSessionJSON.encoder.encode(turn)
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

    /// Full read of `chat.jsonl` in append order, empty when the file does not exist yet.
    ///
    /// Same corrupt-line tolerance as `readTranscriptSegments()`/`readLLMUsageRecords()`: a
    /// malformed line is skipped and logged rather than failing the read, so one bad line cannot
    /// cost the user the rest of their chat history. The trailing line logs at `.default` (a
    /// mid-write crash is the ordinary explanation for it) and any other at `.error`.
    ///
    /// Returned unfolded -- `ChatTurnLog.fold(_:)` is the caller's step, so the file's actual
    /// contents and the display list stay distinguishable.
    func readChatTurns() async throws -> [ChatTurn] {
        let fileURL = try chatFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
            return []
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        let sessionId = self.sessionId
        var turns: [ChatTurn] = []
        turns.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            do {
                turns.append(try ChatSessionJSON.decoder.decode(ChatTurn.self, from: Data(line.utf8)))
            } catch {
                let level: OSLogType = index == lines.count - 1 ? .default : .error
                ChatSessionJSON.logger.log(
                    level: level,
                    "Skipping a malformed line (index \(index, privacy: .public)) in chat.jsonl for session \(sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return turns
    }

    private func chatFileURL() throws -> URL {
        directoryURL.appendingPathComponent(try SessionFile.chatJSONL.relativePath())
    }
}

// MARK: - ChatSessionJSON

/// Cached `JSONEncoder`/`JSONDecoder` for `chat.jsonl` lines, built through `SessionJSONCoding` so
/// key/date strategies match every other session JSON file (same pattern as `LLMUsageSessionJSON`).
private enum ChatSessionJSON {
    static let encoder = SessionJSONCoding.makeEncoder()
    static let decoder = SessionJSONCoding.makeDecoder()
    static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SessionHandleChat")
}
