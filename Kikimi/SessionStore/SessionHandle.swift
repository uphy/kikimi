import Foundation
import OSLog

// MARK: - SessionHandleError

/// Failure modes specific to `SessionHandle`'s own file I/O, distinct from `SessionStoreError`
/// (`SessionStoreTypes.swift`), which covers `SessionStore`'s session-lifecycle/registry failures.
/// See `docs/design/07-session-store.md` section 12.
enum SessionHandleError: LocalizedError, Equatable, Sendable {
    /// A text file (`context.md`/`summary_template.md`/`summary.md`/watcher `.md`) was read back
    /// as bytes that are not valid UTF-8.
    case invalidTextEncoding(relativePath: String)

    var errorDescription: String? {
        switch self {
        case .invalidTextEncoding(let relativePath):
            return "File at \(relativePath) is not valid UTF-8 text."
        }
    }
}

// MARK: - SessionHandle

/// Per-session actor: the sole owner of all file I/O under one
/// `~/.local/state/kikimi/sessions/<id>/` directory (`docs/design/07-session-store.md` sections
/// 3/4). Each open session gets its own `SessionHandle` instance (vended/cached by
/// `SessionStore.openSession(_:)`), so one session's disk I/O never blocks another session's —
/// see section 4 for why a single app-wide actor was rejected in favor of this per-session split.
///
/// This file implements the "core" surface only: identity (`sessionId`/`directoryURL`), the
/// in-memory `meta` cache with its read-modify-write/flush API (section 5.2/7), and the private
/// atomic read/write primitives every other `SessionHandle+*` extension file (transcript/refined,
/// context/summary template, the generic `summary.state.json`/watcher JSON primitives, ...) reuses
/// rather than reimplementing its own crash-safe I/O. Those other methods from design doc section
/// 5.2 (`appendTranscriptSegment`, `readContext`, `readJSON(_:GenericAccessibleFile,...)`, etc.)
/// are implemented in sibling `SessionHandle+*.swift` files, not here.
actor SessionHandle {
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SessionHandle")

    let sessionId: String
    let directoryURL: URL

    /// In-memory cache of `meta.json`, mutated via `updateMeta(_:)`. See that method's doc comment
    /// for when a mutation is written to disk immediately versus deferred (section 7).
    private(set) var meta: SessionMeta

    /// Built once at `init` via `SessionJSONCoding` and reused for every JSON read/write this
    /// handle performs (including by sibling extension files), rather than constructing a fresh
    /// `JSONEncoder`/`JSONDecoder` per call (section 5.2/5.3).
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    /// Section 7's throttle window for deferred `segmentCount`/`refinedCount` writes. Defaults to
    /// the design doc's "既定 5 秒"; overridable so tests can assert throttling behavior without
    /// waiting in real time.
    private let metaFlushInterval: TimeInterval

    /// Injectable wall clock backing the `metaFlushInterval` check, so tests can control elapsed
    /// time deterministically instead of sleeping.
    private let now: @Sendable () -> Date

    /// `true` once `updateMeta(_:)` has applied a counter-only change (section 7's
    /// `segmentCount`/`refinedCount` throttling exception) that has not yet reached disk.
    private var hasPendingMetaWrite = false

    /// Wall-clock time of the last successful `meta.json` write, real or deferred-then-flushed.
    private var lastMetaWriteAt: Date

    /// - Parameters:
    ///   - directoryURL: The session's directory. Must already exist; `SessionHandle` never
    ///     creates it itself (`SessionStore.createDraftSession()`'s job).
    ///   - meta: Initial in-memory `meta` cache. Callers (`SessionStore.openSession(_:)`) are
    ///     expected to have already loaded this from `meta.json` on disk — `SessionHandle` never
    ///     reads `meta.json` at `init` time. Injectable for testability (design doc section 5.2:
    ///     "init はテスト容易性のため directoryURL/初期 meta を注入可能にする"). `sessionId` is derived from
    ///     `meta.id`, which section 5.3.1 fixes as the session's directory name.
    ///   - metaFlushInterval: See `metaFlushInterval` above. Defaults to 5 seconds.
    ///   - now: See `now` above. Defaults to `Date.init`.
    init(
        directoryURL: URL,
        meta: SessionMeta,
        metaFlushInterval: TimeInterval = 5.0,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directoryURL = directoryURL
        self.sessionId = meta.id
        self.meta = meta
        self.jsonEncoder = SessionJSONCoding.makeEncoder()
        self.jsonDecoder = SessionJSONCoding.makeDecoder()
        self.metaFlushInterval = metaFlushInterval
        self.now = now
        self.lastMetaWriteAt = now()
    }

    // MARK: - meta.json

    /// Read-modify-write over the in-memory `meta` cache (section 5.2). Whether this also writes
    /// `meta.json` to disk immediately, or only updates memory and defers the disk write, depends
    /// on *what* `mutate` changed:
    ///
    /// - If anything other than `segmentCount`/`refinedCount` changed (this covers the
    ///   `state`/`startedAt`/`endedAt`/`durationMs` transitions section 7 calls out by name, but
    ///   also e.g. a title update from `SummaryUpdater`, or no change at all), the write happens
    ///   immediately — this method's general "呼び出しごとに atomic write する" contract.
    /// - If *only* `segmentCount`/`refinedCount` changed (the high-frequency counters
    ///   `appendTranscriptSegment`/`appendRefinedSegment` bump on every call), the write is
    ///   deferred until `metaFlushInterval` has elapsed since the last write, or until an
    ///   explicit `flush()` — section 7's stated throttling exception, scoped to exactly those two
    ///   fields.
    ///
    /// Throws whatever `mutate` throws (in which case `meta` is left unchanged) or whatever the
    /// underlying atomic write throws (in which case `meta` still reflects the mutated value in
    /// memory: section 7 doesn't specify unwinding the in-memory value on a write failure, and
    /// discarding the mutation entirely would lose more than leaving `meta` momentarily ahead of
    /// disk until the next successful write).
    func updateMeta(_ mutate: (inout SessionMeta) throws -> Void) async throws {
        var updated = meta
        try mutate(&updated)

        let previous = meta
        meta = updated

        if isCounterOnlyChange(from: previous, to: updated) {
            hasPendingMetaWrite = true
            if now().timeIntervalSince(lastMetaWriteAt) >= metaFlushInterval {
                try writeMetaToDisk()
            }
        } else {
            try writeMetaToDisk()
        }
    }

    /// Writes any deferred `segmentCount`/`refinedCount` change to disk immediately, regardless of
    /// `metaFlushInterval`. Idempotent: a no-op when nothing is pending (section 5.2: "保留中の変更が
    /// 無ければ何もせず即座に返る（冪等）"). Callers (`WindowManager`/`AppDelegate`) must call this when
    /// closing a session's window or quitting the app, or a pending increment can be lost — the
    /// design doc is explicit that an actor's `deinit` cannot run `async` cleanup, so this is the
    /// only sanctioned way to flush (section 7).
    func flush() async throws {
        guard hasPendingMetaWrite else { return }
        try writeMetaToDisk()
    }

    /// True when `updated` differs from `previous` in `segmentCount`/`refinedCount` only. Section
    /// 7's throttling exception applies *only* to those two fields, so any other simultaneous
    /// change (or no change at all) must take the immediate-write path.
    private func isCounterOnlyChange(from previous: SessionMeta, to updated: SessionMeta) -> Bool {
        guard previous != updated else { return false }
        var previousWithUpdatedCounters = previous
        previousWithUpdatedCounters.segmentCount = updated.segmentCount
        previousWithUpdatedCounters.refinedCount = updated.refinedCount
        return previousWithUpdatedCounters == updated
    }

    private func writeMetaToDisk() throws {
        do {
            try atomicWriteJSON(meta, to: .meta)
        } catch {
            // Failure mode #4 (design doc section 12): atomic write of meta.json failed
            // (disk full, permissions, ...). Propagate to the caller; `meta` keeps the mutated
            // in-memory value (see `updateMeta`'s doc comment) so the next successful write still
            // carries this change.
            logger.error("Failed to write meta.json for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
        hasPendingMetaWrite = false
        lastMetaWriteAt = now()
    }

    // MARK: - Atomic read/write primitives (shared with `SessionHandle+*` extension files)
    //
    // Deliberately typed on `SessionFile`, not the narrower `GenericAccessibleFile` the public
    // `readJSON`/`writeJSON`/`readText`/`writeText` primitives from design doc section 5.2/11 are
    // typed on: these are the shared low-level building blocks *for* every `SessionHandle+*`
    // extension file (including the ones implementing that narrower public surface, and this
    // file's own `writeMetaToDisk()`), not a public API in their own right. Not marked `private`
    // because Swift's `private`/`fileprivate` can't express "usable only from other `SessionHandle`
    // files" across separate files in the same module (see `SessionFile.swift`'s doc comment for
    // the same limitation applied to `SessionFile` itself) — kept at the default `internal` level
    // and restricted to `SessionHandle`-family use by convention/review instead.

    /// Encodes `value` with the cached encoder and atomically overwrites `file` (section 7: "JSON,
    /// 上書き型" -> `Data.write(to:options:[.atomic])`, a temp-file-then-`rename(2)` under the hood,
    /// so a crash mid-write never leaves a half-written file behind). Creates `file`'s parent
    /// directory first (e.g. `watchers/`) if it doesn't exist yet.
    func atomicWriteJSON<T: Encodable>(_ value: T, to file: SessionFile) throws {
        let data = try jsonEncoder.encode(value)
        try atomicWriteData(data, to: file)
    }

    /// Decodes `file`'s contents with the cached decoder, or returns `nil` if the file doesn't
    /// exist yet (matches section 5.2's "存在しなければ nil を返す（初回実行前の Watcher 等、正常系として扱う）"
    /// contract, which the public `readJSON(_:GenericAccessibleFile,...)` primitive inherits from
    /// this helper).
    func readJSONIfPresent<T: Decodable>(_ file: SessionFile, as type: T.Type) throws -> T? {
        guard let data = try readDataIfPresent(file) else { return nil }
        return try jsonDecoder.decode(T.self, from: data)
    }

    /// Atomically overwrites `file` with `text` (section 7: "プレインテキスト, 上書き型" ->
    /// `String.write(to:atomically:true,encoding:.utf8)`). Creates `file`'s parent directory first
    /// if it doesn't exist yet.
    func atomicWriteText(_ text: String, to file: SessionFile) throws {
        let url = try resolvedURL(for: file)
        try createParentDirectoryIfNeeded(for: url)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Reads `file`'s contents as UTF-8 text, or returns `nil` if the file doesn't exist yet.
    /// Throws `SessionHandleError.invalidTextEncoding` if the file exists but is not valid UTF-8.
    func readTextIfPresent(_ file: SessionFile) throws -> String? {
        guard let data = try readDataIfPresent(file) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SessionHandleError.invalidTextEncoding(relativePath: try file.relativePath())
        }
        return text
    }

    private func atomicWriteData(_ data: Data, to file: SessionFile) throws {
        let url = try resolvedURL(for: file)
        try createParentDirectoryIfNeeded(for: url)
        try data.write(to: url, options: [.atomic])
    }

    private func readDataIfPresent(_ file: SessionFile) throws -> Data? {
        let url = try resolvedURL(for: file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func resolvedURL(for file: SessionFile) throws -> URL {
        directoryURL.appendingPathComponent(try file.relativePath())
    }

    private func createParentDirectoryIfNeeded(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
}
