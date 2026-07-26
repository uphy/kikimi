import Foundation
import OSLog

// MARK: - SessionStore + Crash Recovery

/// Startup crash-recovery path (kikimi.md 15 章 Open Questions "セッション中のクラッシュ復旧";
/// `docs/design/07-session-store.md` section 10). Split into its own file to keep the primary
/// `SessionStore.swift` declaration focused on the lifecycle/registry API (section 5.1 groups
/// `detectIncompleteSessions()`/`finalizeCrashedSession(_:)` under their own `MARK: クラッシュ復旧`).
///
/// Both methods here only use `SessionStore`'s already-`internal` API (`listSessions()`/
/// `openSession(_:)`) and `SessionHandle`'s already-`internal` API (`meta`/`updateMeta`/
/// `readTranscriptSegments()`, the latter defined in `SessionHandle+Transcript.swift`) — no access
/// to `SessionStore`'s `private` stored properties (e.g. `sessionsRootDirectory`) is required.
extension SessionStore {
    private static let crashRecoveryLogger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SessionStore+CrashRecovery")

    /// Called once at app startup, before window restoration (section 10). Walks every session
    /// folder's `meta.json` via `listSessions()` (which already skips folders whose `meta.json`
    /// fails to decode, logging `.error` itself — failure mode #8) and returns those still
    /// `state == .recording`.
    ///
    /// At the point this is called, `recordingSessionId` is always `nil`: this is a freshly
    /// launched `SessionStore` instance that has not called `beginRecording(_:)` yet this run. So
    /// any session still `.recording` on disk is evidence the *previous* run crashed (or was force
    /// quit) before it could reach `endRecording(_:)`.
    func detectIncompleteSessions() async -> [SessionMeta] {
        let incomplete = await listSessions().filter { $0.state == .recording }

        // Failure mode #13: detecting one or more crashed sessions is itself the abnormal
        // condition worth flagging, even though this function never throws.
        if !incomplete.isEmpty {
            let ids = incomplete.map(\.id).joined(separator: ", ")
            Self.crashRecoveryLogger.warning(
                "Detected \(incomplete.count) session(s) left in .recording state from a previous run: \(ids, privacy: .public)"
            )
        }

        return incomplete
    }

    /// Finalizes a session left in `.recording` state by a crash, once the user has chosen to
    /// recover it (kikimi.md 15 章 Open Questions "セッション中のクラッシュ復旧"). Closes the crashed
    /// (still-open) `RecordingSegment` by estimating its length from the last transcript segment
    /// belonging to it, folds that length into `meta.durationMs`, and commits `state = .paused` —
    /// **not** `.ended`: a crash is not a user decision to end the meeting, so recovery only stops
    /// the broken recording segment and leaves the session resumable/endable like any other Paused
    /// session (`on_session_end` never runs here).
    ///
    /// If no transcript segment belonging to the crashed segment can be found at all — an empty
    /// `transcript.jsonl`, one that failed to read entirely, or a session folder with no file yet
    /// (failure mode #14) — this falls back to a zero-length segment (`endedAt = startedAt`) and
    /// logs `.warning` rather than throwing: the session itself is still salvaged rather than left
    /// stuck in `.recording`.
    @discardableResult
    func finalizeCrashedSession(_ sessionId: String) async throws -> SessionMeta {
        let handle = try await openSession(sessionId)

        let metaBeforeRecovery = await handle.meta

        // Guard against misuse: this API is only meaningful for sessions a previous run left in
        // `.recording` (as surfaced by `detectIncompleteSessions()`). Without this check, calling
        // it on a `.draft` session would silently promote an unstarted session, and calling it on
        // an already-`.paused`/`.ended` session would recompute/overwrite its duration from scratch.
        guard metaBeforeRecovery.state == .recording else {
            throw SessionStoreError.sessionNotInRecordingState(sessionId)
        }

        var segments: [TranscriptSegment] = []
        do {
            segments = try await handle.readTranscriptSegments()
        } catch {
            // `readTranscriptSegments()` already tolerates a corrupted trailing line on its own
            // (design section 7); reaching a thrown error here means something more fundamental
            // (e.g. the file could not be opened at all). Recovery still proceeds with an empty
            // segment list rather than leaving the session stuck in `.recording` forever.
            Self.crashRecoveryLogger.error(
                "Crash recovery for session \(sessionId, privacy: .public) could not read transcript.jsonl, treating as empty: \(String(describing: error), privacy: .public)"
            )
        }

        // `state == .recording` should always imply the last `recordings[]` entry is still open
        // (`beginRecording(_:)`/`resumeRecording(_:)`/`reopenForRecording(_:)` always append one).
        // If it is somehow missing (a hand-edited/corrupt fixture), still recover to `.paused`
        // rather than leaving the session stuck in `.recording` forever.
        guard let crashedSegment = metaBeforeRecovery.recordings.last, crashedSegment.endedAt == nil else {
            Self.crashRecoveryLogger.warning(
                "Session \(sessionId, privacy: .public) was .recording with no open recording segment; recovering to .paused without a duration estimate"
            )
            try await handle.updateMeta { meta in meta.state = .paused }
            return await handle.meta
        }

        // Uses the *last line* belonging to the crashed segment, not the maximum `end_ms` among
        // them (matching the pre-existing single-segment estimation rule): `transcript.jsonl`'s
        // append order reflects wall-clock arrival across the two independent mic/system streams,
        // so the last line written is the best available evidence of how far the crashed segment
        // got, even though `start_ms`/`end_ms` are not strictly increasing in file order (kikimi.md
        // 6 章: "`id` は投入順に採番される... 時系列参照は必ず `start_ms` を使う" — but "last written" is a
        // *recency*, not *timeline*, signal here). Segments from a prior, already-closed recording
        // segment (`start_ms < startMsOffset`) are excluded so an earlier pause/resume cycle can
        // never be mistaken for the crashed one.
        let lastLineInSegment = segments.last { $0.startMs >= crashedSegment.startMsOffset }
        let closedSegmentDurationMs: Int
        if let lastLineInSegment {
            closedSegmentDurationMs = max(0, lastLineInSegment.endMs - crashedSegment.startMsOffset)
        } else {
            closedSegmentDurationMs = 0
            Self.crashRecoveryLogger.warning(
                "Crash recovery for session \(sessionId, privacy: .public) found no transcript segments for the crashed recording segment; estimating its duration as 0"
            )
        }
        let estimatedEndedAt = crashedSegment.startedAt.addingTimeInterval(TimeInterval(closedSegmentDurationMs) / 1_000)

        try await handle.updateMeta { meta in
            guard var last = meta.recordings.last, last.endedAt == nil else { return }
            last.endedAt = estimatedEndedAt
            meta.recordings[meta.recordings.count - 1] = last
            meta.durationMs += closedSegmentDurationMs
            meta.state = .paused
        }

        let finalizedMeta = await handle.meta
        Self.crashRecoveryLogger.info(
            "Recovered crashed session \(sessionId, privacy: .public) to .paused: closedSegmentDurationMs=\(closedSegmentDurationMs), totalDurationMs=\(finalizedMeta.durationMs)"
        )
        return finalizedMeta
    }
}
