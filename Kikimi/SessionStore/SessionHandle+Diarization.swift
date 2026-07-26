import Foundation
import OSLog

// MARK: - SessionHandle + Diarization (diarization.jsonl / speaker_assignments.json)

/// Persistence for the two speaker-diarization sidecar files
/// (`docs/design/13-speaker-diarization.md` section 4.1-4.3): the append-only
/// `diarization.jsonl` log of finalized speaker turns, and the overwrite-but-mutate-guarded
/// `speaker_assignments.json` slot -> display-name mapping. Neither is exposed through
/// `SessionHandle+GenericStorage.swift`'s generic `readJSON`/`writeJSON` primitives — see
/// `SessionFile.swift`'s `GenericAccessibleFile` doc comment for why.
///
/// Split into its own file for the same reason as `SessionHandle+Transcript.swift`/
/// `SessionHandle+Prep.swift`: it only needs `SessionHandle`'s already-`internal` surface
/// (`readJSONIfPresent`/`atomicWriteJSON`, both declared in `SessionHandle.swift`), not any
/// `private` member of the primary declaration.
extension SessionHandle {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SessionHandle.Diarization")

    // MARK: - diarization.jsonl (append-only)

    /// Appends one line to `diarization.jsonl` for a finalized speaker turn (design section 4.2).
    /// Unlike `appendTranscriptSegment`/`appendRefinedSegment` (`SessionHandle+Transcript.swift`),
    /// this does not keep a cached, always-open `FileHandle` for the file: `AppendOnlyLogFileRegistry`
    /// backing that behavior is `private` to `SessionHandle+Transcript.swift`, and diarization turns
    /// are finalized at a much lower rate (LS-EEND's `.step500ms` cadence, design section 5) than
    /// STT segments, so the per-call open/seek/close cost here is not a bottleneck. Every call is
    /// still a single `write(contentsOf:)` so one turn's bytes are never interleaved with another's.
    ///
    /// Does not touch `meta.json` — `diarization.jsonl` has no counter mirrored there (unlike
    /// `transcript.jsonl`'s `segmentCount`).
    func appendDiarizationTurn(_ turn: DiarizationTurn) throws {
        let url = try diarizationFileURL()
        var line = try DiarizationSessionJSON.encoder.encode(turn)
        line.append(0x0A) // "\n"

        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw SessionHandleDiarizationError.unableToCreateFile(url.path)
            }
        }
        guard let fileHandle = FileHandle(forWritingAtPath: url.path) else {
            throw SessionHandleDiarizationError.unableToOpenFileHandle(url.path)
        }
        defer { try? fileHandle.close() }
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: line)
    }

    /// Full read of `diarization.jsonl` (used for seg-to-turn attribution and Ended-time processing;
    /// design section 5.2/4.4). Returns an empty array if the file does not exist yet — a session
    /// whose system stream never triggered diarization (5.1 節 "入力選択との関係"), or one where
    /// diarization is disabled entirely (config `diarization.enabled: false`).
    ///
    /// Append order does not guarantee `startMs` ascending (design section 4.2: "slot ごとに確定
    /// タイミングが異なる") — callers must sort by time themselves; this method does not.
    ///
    /// Tolerates a corrupt **trailing** line (evidence of a crash mid-write) by skipping it with a
    /// `.warning` log and still returning every other line, the same tolerance
    /// `SessionHandle+Transcript.swift`'s `readTranscriptSegments`/`readRefinedSegments` apply. A
    /// corrupt line anywhere else is more serious corruption and is skipped with an `.error` log
    /// instead, but still does not prevent reading the remaining lines (kikimi.md 8.5 章 "データは
    /// 絶対に失わない").
    func readDiarizationTurns() throws -> [DiarizationTurn] {
        let url = try diarizationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return []
        }
        guard let content = String(data: data, encoding: .utf8) else {
            Self.logger.error(
                "diarization.jsonl for session \(self.sessionId, privacy: .public) is not valid UTF-8; treating it as unreadable."
            )
            return []
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        var results: [DiarizationTurn] = []
        results.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            do {
                results.append(try DiarizationSessionJSON.decoder.decode(DiarizationTurn.self, from: Data(line.utf8)))
            } catch {
                if index == lines.count - 1 {
                    Self.logger.warning(
                        """
                        Skipping a malformed trailing line in diarization.jsonl for session \
                        \(self.sessionId, privacy: .public) (likely a mid-write crash): \
                        \(String(describing: error), privacy: .public)
                        """
                    )
                } else {
                    Self.logger.error(
                        """
                        Skipping a malformed line (index \(index, privacy: .public), not the last line) in \
                        diarization.jsonl for session \(self.sessionId, privacy: .public): \
                        \(String(describing: error), privacy: .public)
                        """
                    )
                }
            }
        }
        return results
    }

    // MARK: - speaker_assignments.json (mutate-closure overwrite)

    /// Reads `speaker_assignments.json` (design section 4.3). Returns an empty
    /// `SpeakerAssignments()` if the file does not exist yet — a session where no `system` slot has
    /// ever been created, not a failure.
    func readSpeakerAssignments() throws -> SpeakerAssignments {
        try readJSONIfPresent(.speakerAssignments, as: SpeakerAssignments.self) ?? SpeakerAssignments()
    }

    /// Read-modify-write over `speaker_assignments.json`, mirroring `updateMeta(_:)`'s shape
    /// (`SessionHandle.swift`). Design section 4.1 calls this out explicitly: `auto` writes from
    /// `RealtimeDiarizationCoordinator` (voiceprint match results) and `user` writes from the UI
    /// (renames) can happen concurrently, so a caller doing a plain
    /// `readSpeakerAssignments()` -> mutate -> `writeJSON(...)` outside of `SessionHandle` could lose
    /// one side's update to the other. Serializing the whole read-modify-write inside one actor
    /// method (this one) closes that race, the same way `updateMeta(_:)` does for `meta.json`.
    ///
    /// `mutate` is synchronous (unlike `updateMeta`'s `mutate`, which can throw but is also
    /// synchronous) — assignment mutations are pure in-memory edits with no reason to fail
    /// mid-mutation, so there is no error path to propagate from inside the closure.
    func updateSpeakerAssignments(_ mutate: (inout SpeakerAssignments) -> Void) throws {
        var current = try readSpeakerAssignments()
        mutate(&current)
        try atomicWriteJSON(current, to: .speakerAssignments)
    }

    // MARK: - participants.json (mutate-closure overwrite, docs/design/22-participant-hints.md section 1.2)

    /// Reads `participants.json`, or `SessionParticipants()` (empty roster) if it does not exist, is
    /// unreadable, or fails to decode. **Deliberately non-throwing** -- unlike
    /// `readSpeakerAssignments()` above, a broken roster file must never block anything that reads it
    /// (voiceprint matching falling back to open-set, the prep UI rendering an empty list, ...), so the
    /// failure is swallowed here (logged at `.warning`, design section 6's "participants.json 欠落・破損 →
    /// 空名簿として読む（warning ログ）") rather than propagated for every call site to handle identically.
    func readParticipants() -> SessionParticipants {
        do {
            return try readJSONIfPresent(.participants, as: SessionParticipants.self) ?? SessionParticipants()
        } catch {
            Self.logger.warning(
                """
                participants.json for session \(self.sessionId, privacy: .public) could not be \
                read/decoded; treating it as an empty roster (open-set matching): \
                \(String(describing: error), privacy: .public)
                """
            )
            return SessionParticipants()
        }
    }

    /// Read-modify-write over `participants.json`, mirroring `updateSpeakerAssignments(_:)`'s shape
    /// exactly (design section 1.2: "read-modify-write を actor 呼び出し 1 回で完結（auto 追加と UI 操作の並行
    /// 書き込み対策）"). Unlike `readParticipants()`, this **does** throw -- a write failure here is a
    /// real persistence problem the caller (`MeetingWorkspaceViewModel+Participants.swift`, P2) needs to
    /// know about, even though design section 6 says it should still update its own in-memory state and
    /// push to the diarization coordinator regardless (best-effort at the ViewModel layer, not silently
    /// swallowed here).
    ///
    /// `mutate` is synchronous, same rationale as `updateSpeakerAssignments`'s `mutate`: roster edits
    /// (`addParticipant`/`removeParticipant`) are pure in-memory list operations with no failure mode of
    /// their own.
    func updateParticipants(_ mutate: (inout SessionParticipants) -> Void) throws {
        var current = readParticipants()
        mutate(&current)
        try atomicWriteJSON(current, to: .participants)
    }

    // MARK: - Private helpers

    private func diarizationFileURL() throws -> URL {
        directoryURL.appendingPathComponent(try SessionFile.diarizationJSONL.relativePath())
    }
}

// MARK: - SessionHandleDiarizationError

private enum SessionHandleDiarizationError: LocalizedError, Equatable {
    case unableToCreateFile(String)
    case unableToOpenFileHandle(String)

    var errorDescription: String? {
        switch self {
        case .unableToCreateFile(let path):
            return "Failed to create diarization.jsonl at \(path)."
        case .unableToOpenFileHandle(let path):
            return "Failed to open a file handle for diarization.jsonl at \(path)."
        }
    }
}

// MARK: - DiarizationSessionJSON

/// Cached `JSONEncoder`/`JSONDecoder` for `diarization.jsonl` lines, built via `SessionJSONCoding`
/// (`SessionModels.swift`) so the `snake_case` key strategy matches every other session JSON file
/// (design doc section 5.3 of `07-session-store.md`). `speaker_assignments.json` does not need its
/// own copy here: `readJSONIfPresent`/`atomicWriteJSON` (used by `readSpeakerAssignments`/
/// `updateSpeakerAssignments`) already go through `SessionHandle`'s own cached encoder/decoder.
/// `SessionHandle`'s cached encoder/decoder are `private` to `SessionHandle.swift`, so — like
/// `SessionHandle+Transcript.swift`'s `TranscriptSessionJSON` — this extension file builds its own
/// instead of reaching into those.
private enum DiarizationSessionJSON {
    static let encoder = SessionJSONCoding.makeEncoder()
    static let decoder = SessionJSONCoding.makeDecoder()
}
