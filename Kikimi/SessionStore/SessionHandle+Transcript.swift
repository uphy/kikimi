import Foundation
import OSLog

// MARK: - SessionHandle + Transcript (transcript.jsonl / refined.jsonl)

/// Append-only logging of `transcript.jsonl`/`refined.jsonl` and their full-file readback
/// (`docs/design/07-session-store.md` sections 5.2/6/7; kikimi.md 5 章/6 章).
///
/// Split into its own file, alongside `SessionHandle+Prep.swift`/`SessionStore+CrashRecovery.swift`
/// and friends, to keep the primary `SessionHandle` declaration (`Kikimi/SessionStore/SessionHandle.swift`:
/// `sessionId`/`directoryURL`/`meta`/`updateMeta`/`flush`) focused on the actor's core lifecycle. Only
/// uses that file's already-`internal` surface (`meta`, `updateMeta(_:)`) — no access to anything
/// `private` on the primary declaration is required.
///
/// `transcript.jsonl`/`refined.jsonl` are append-only (never atomically overwritten, unlike
/// `meta.json`/`summary.state.json`), so this file does not reuse `SessionHandle`'s
/// `atomicWriteJSON`/`atomicWriteText` primitives — those are for the "JSON, 上書き型" /
/// "プレインテキスト, 上書き型" file kinds design doc section 7 describes, not the "追記専用" kind this
/// file handles. Instead, each of the two log files gets a `FileHandle` that is opened exactly
/// once — creating the file and seeking to its current end if it already has content — and kept
/// open thereafter, mirroring `WavFileWriter`'s "open once, append only, never seek back" design
/// (`Kikimi/AudioCapture/WavFileWriter.swift`, section 7/8). That `FileHandle` is owned by
/// `AppendOnlyLogFile` and cached in `AppendOnlyLogFileRegistry` below, keyed by the file's absolute
/// path, rather than as a new stored property on `SessionHandle`: Swift extensions cannot add stored
/// instance properties to the type they extend, and the primary `SessionHandle` declaration is owned
/// by a different module task (`SessionHandle.swift`). Since every session's
/// `transcript.jsonl`/`refined.jsonl` lives at a unique, stable path for the lifetime of the app
/// process, keying by path is equivalent to keying by session.
extension SessionHandle {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SessionHandle.Transcript")

    // MARK: transcript.jsonl

    /// Assigns the next `"seg_" + 5-digit zero-padded sequence` id, derived from `meta.segmentCount`
    /// (kikimi.md 5 章: `id` は `seg_` + 5桁ゼロ埋め連番, "id の採番と書き込み順序は必ず一致する"), appends one line
    /// to `transcript.jsonl`, then bumps `meta.segmentCount` via `updateMeta(_:)` — which already
    /// implements section 7's throttled-write exception for counter-only changes, so this method does
    /// not need its own flush-interval logic. The line is appended before the counter bump so a
    /// `meta.json` write failure never loses the already-durable transcript line (kikimi.md 8.5 章
    /// "録音は絶対に止めない"; design doc section 12 failure mode #4/#5).
    @discardableResult
    func appendTranscriptSegment(
        source: AudioSourceKind,
        startMs: Int,
        endMs: Int,
        text: String,
        confidence: Double,
        sttSource: String? = nil
    ) async throws -> TranscriptSegment {
        let nextSequence = meta.segmentCount + 1
        let segment = TranscriptSegment(
            id: Self.formatSegmentId(nextSequence),
            startMs: startMs,
            endMs: endMs,
            speaker: source,
            text: text,
            confidence: confidence,
            sttSource: sttSource
        )
        try appendLine(segment, to: transcriptFileURL())
        try await updateMeta { meta in
            meta.segmentCount = nextSequence
        }
        return segment
    }

    /// Appends one line to `refined.jsonl` for an already-assigned `seg_id` and bumps
    /// `meta.refinedCount` via `updateMeta(_:)` (same append-before-count-bump ordering and
    /// throttled-write behavior as `appendTranscriptSegment`). Counts refinement *attempts*, not
    /// just successes: a segment with `refinedText == nil`/`error != nil` (refinement failure,
    /// kikimi.md 5 章) is still appended and still counted.
    func appendRefinedSegment(_ segment: RefinedSegment) async throws {
        try appendLine(segment, to: refinedFileURL())
        try await updateMeta { meta in
            meta.refinedCount += 1
        }
    }

    /// Full read of `transcript.jsonl` (used by サマリ全文再生成 / Wiki export / クラッシュ復旧 duration
    /// estimation; section 5.2). See `readAppendOnlyJSONLines(at:fileName:)` for the corrupt-line
    /// tolerance contract. Returns an empty array if the file does not exist yet.
    func readTranscriptSegments() async throws -> [TranscriptSegment] {
        try readAppendOnlyJSONLines(at: transcriptFileURL(), fileName: "transcript.jsonl")
    }

    /// Full read of `refined.jsonl`. See `readAppendOnlyJSONLines(at:fileName:)` for the corrupt-line
    /// tolerance contract. Returns an empty array if the file does not exist yet.
    func readRefinedSegments() async throws -> [RefinedSegment] {
        try readAppendOnlyJSONLines(at: refinedFileURL(), fileName: "refined.jsonl")
    }

    /// Ensures `transcript.jsonl`/`refined.jsonl` exist on disk, without appending anything to either.
    /// Design doc section 7: "`SessionHandle` がセッションを開いた時点で `FileHandle` を1つ開きっぱなしにし" —
    /// both log files are meant to exist from the moment a session is opened/created, not only once the
    /// first segment is appended. `SessionStore.createDraftSession()`/`openSession(_:)` call this right
    /// after constructing a `SessionHandle` (kikimi.md 4 章 lists both files as present in a freshly
    /// created session's layout). Safe to call on a session that already has content in either file: this
    /// goes through the same `AppendOnlyLogFileRegistry` cache `appendTranscriptSegment`/
    /// `appendRefinedSegment` use, whose `AppendOnlyLogFile.init` only creates a file if it does not
    /// already exist and always seeks to the current end before any future write — so this never
    /// truncates or otherwise disturbs pre-existing content.
    func ensureTranscriptAndRefinedLogFilesExist() throws {
        _ = try AppendOnlyLogFileRegistry.shared.writer(for: transcriptFileURL())
        _ = try AppendOnlyLogFileRegistry.shared.writer(for: refinedFileURL())
    }

    /// Closes and discards any `FileHandle`s `AppendOnlyLogFileRegistry` has cached for
    /// `transcript.jsonl`/`refined.jsonl` under `directoryURL`, without requiring a live
    /// `SessionHandle` instance — the registry is keyed by absolute path and shared process-wide
    /// (see its doc comment), so this closes the handles even for a session this particular
    /// `SessionStore` instance never `openSession`'d in the current app run. `static`/directory-based
    /// rather than an instance method so `SessionStore.deleteSession(_:)` can call it for sessions
    /// with no cached `SessionHandle` at all.
    static func closeAppendOnlyLogFiles(inSessionDirectory directoryURL: URL) {
        let transcriptURL = directoryURL.appendingPathComponent((try? SessionFile.transcriptJSONL.relativePath()) ?? "transcript.jsonl")
        let refinedURL = directoryURL.appendingPathComponent((try? SessionFile.refinedJSONL.relativePath()) ?? "refined.jsonl")
        AppendOnlyLogFileRegistry.shared.removeWriters(for: [transcriptURL, refinedURL])
    }

    // MARK: - Private helpers

    private func transcriptFileURL() throws -> URL {
        directoryURL.appendingPathComponent(try SessionFile.transcriptJSONL.relativePath())
    }

    private func refinedFileURL() throws -> URL {
        directoryURL.appendingPathComponent(try SessionFile.refinedJSONL.relativePath())
    }

    /// Encodes `value` and appends it, plus a trailing `\n`, to `fileURL` as a single
    /// `write(contentsOf:)` call (via `AppendOnlyLogFile`), so a line is never interleaved with
    /// another write.
    private func appendLine<T: Encodable>(_ value: T, to fileURL: URL) throws {
        var line = try TranscriptSessionJSON.encoder.encode(value)
        line.append(0x0A) // "\n"
        try AppendOnlyLogFileRegistry.shared.writer(for: fileURL).appendLine(line)
    }

    /// Decodes one `T` per non-empty line of `fileURL`. A malformed **trailing** line is treated as
    /// evidence of a crash mid-write and skipped with `.warning`; a malformed line **anywhere else**
    /// is treated as more serious corruption and skipped with `.error`. Either way the remaining
    /// lines are still read — one bad line never loses the rest of the session's data (design doc
    /// section 7/12, kikimi.md 8.5 章 "データは絶対に失わない").
    private func readAppendOnlyJSONLines<T: Decodable>(at fileURL: URL, fileName: String) throws -> [T] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else {
            return []
        }
        guard let content = String(data: data, encoding: .utf8) else {
            Self.logger.error(
                "\(fileName, privacy: .public) for session \(self.sessionId, privacy: .public) is not valid UTF-8; treating it as unreadable."
            )
            return []
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        var results: [T] = []
        results.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            do {
                results.append(try TranscriptSessionJSON.decoder.decode(T.self, from: Data(line.utf8)))
            } catch {
                if index == lines.count - 1 {
                    Self.logger.warning(
                        """
                        Skipping a malformed trailing line in \(fileName, privacy: .public) for session \
                        \(self.sessionId, privacy: .public) (likely a mid-write crash): \
                        \(String(describing: error), privacy: .public)
                        """
                    )
                } else {
                    Self.logger.error(
                        """
                        Skipping a malformed line (index \(index, privacy: .public), not the last line) in \
                        \(fileName, privacy: .public) for session \(self.sessionId, privacy: .public): \
                        \(String(describing: error), privacy: .public)
                        """
                    )
                }
            }
        }
        return results
    }

    private static func formatSegmentId(_ sequence: Int) -> String {
        "seg_" + String(format: "%05d", sequence)
    }
}

// MARK: - TranscriptSessionJSON

/// Cached `JSONEncoder`/`JSONDecoder` for `transcript.jsonl`/`refined.jsonl` lines, built via
/// `SessionJSONCoding` (`SessionModels.swift`) so the `.iso8601` date strategy and `snake_case` key
/// strategy match every other session JSON file (design doc section 5.3). `SessionHandle`'s own
/// cached encoder/decoder are `private` to `SessionHandle.swift`, so this extension file builds its
/// own instead of reaching into those.
private enum TranscriptSessionJSON {
    static let encoder = SessionJSONCoding.makeEncoder()
    static let decoder = SessionJSONCoding.makeDecoder()
}

// MARK: - AppendOnlyLogFileError

private enum AppendOnlyLogFileError: LocalizedError, Equatable {
    case unableToCreateFile(String)
    case unableToOpenFileHandle(String)

    var errorDescription: String? {
        switch self {
        case .unableToCreateFile(let path):
            return "Failed to create the append-only log file at \(path)."
        case .unableToOpenFileHandle(let path):
            return "Failed to open a file handle for the append-only log file at \(path)."
        }
    }
}

// MARK: - AppendOnlyLogFile

/// A single append-only file whose `FileHandle` is opened once — creating the file first if it does
/// not exist, then seeking to its current end exactly once at `init` — and kept open for the
/// lifetime of this instance. Every subsequent `appendLine(_:)` call is a single
/// `write(contentsOf:)` with no further seeking, mirroring `WavFileWriter`'s "open once, append
/// only, never seek back" design (`Kikimi/AudioCapture/WavFileWriter.swift`, design doc section 7).
///
/// Not itself thread-safe: callers must serialize their own access to one instance.
/// `SessionHandle`'s actor isolation does this for calls belonging to one session;
/// `AppendOnlyLogFileRegistry` below only protects the *cache* of instances, not calls into a given
/// instance once vended.
private final class AppendOnlyLogFile {
    private let fileHandle: FileHandle

    init(fileURL: URL) throws {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw AppendOnlyLogFileError.unableToCreateFile(fileURL.path)
            }
        }
        guard let handle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw AppendOnlyLogFileError.unableToOpenFileHandle(fileURL.path)
        }
        self.fileHandle = handle
        // The one and only seek: if the file already had content (e.g. re-opening a session whose
        // transcript.jsonl was started in a previous run), appends must continue after it, never
        // overwrite it.
        _ = try handle.seekToEnd()
    }

    /// Appends `line` (already newline-terminated) as a single `write(contentsOf:)` call.
    func appendLine(_ line: Data) throws {
        try fileHandle.write(contentsOf: line)
    }
}

// MARK: - AppendOnlyLogFileRegistry

/// Caches one `AppendOnlyLogFile` per absolute file path, so each session's
/// `transcript.jsonl`/`refined.jsonl` is opened at most once per app run and then reused by every
/// subsequent append (see `AppendOnlyLogFile`'s doc comment for why this lives here, keyed by path,
/// rather than as a stored property on `SessionHandle` itself). `NSLock`-protected because distinct
/// `SessionHandle` actor instances (each already serializing its own calls) can still race on this
/// shared cache concurrently.
private final class AppendOnlyLogFileRegistry: @unchecked Sendable {
    static let shared = AppendOnlyLogFileRegistry()

    private let lock = NSLock()
    private var writers: [String: AppendOnlyLogFile] = [:]

    func writer(for fileURL: URL) throws -> AppendOnlyLogFile {
        lock.lock()
        defer { lock.unlock() }
        if let existing = writers[fileURL.path] {
            return existing
        }
        let created = try AppendOnlyLogFile(fileURL: fileURL)
        writers[fileURL.path] = created
        return created
    }

    /// Removes and (via `AppendOnlyLogFile`'s deinit-free `FileHandle` release once the last
    /// reference drops) closes any cached writer for each of `fileURLs`. A no-op for any URL that
    /// was never opened. Used by `SessionStore.deleteSession(_:)` so the registry — and the
    /// underlying open `FileHandle`s pinning that inode's disk space — doesn't grow forever across a
    /// long-running app's lifetime.
    func removeWriters(for fileURLs: [URL]) {
        lock.lock()
        defer { lock.unlock() }
        for fileURL in fileURLs {
            writers.removeValue(forKey: fileURL.path)
        }
    }
}
