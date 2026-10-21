import Foundation

// MARK: - SessionStore + abandoned recording (docs/design/50-meet-auto-record.md section 3.5)

/// Split out of `SessionStore.swift` to keep that file under the `file_length` lint limit.
extension SessionStore {
    /// Releases the recording-exclusivity flag for `sessionId` without touching `meta.json`
    /// (`docs/design/50-meet-auto-record.md` §3.5). Unlike `pauseRecording(_:)` it does not close the
    /// open segment or change state: the caller deletes the session right afterward, so the write
    /// would be wasted (and would race the deletion). A no-op unless `sessionId` holds the flag.
    func abandonRecording(_ sessionId: String) {
        guard recordingSessionId == sessionId else { return }
        setRecordingSessionId(nil)
    }

    /// Recovery for a failed discard after `abandonRecording(_:)` (`docs/design/50-meet-auto-record.md`
    /// §3.5): closes the open segment and marks the session `.paused`, like `pauseRecording(_:)` but
    /// without requiring (or touching) the recording-exclusivity flag, which was already released.
    func markAbandonedRecordingPaused(_ sessionId: String) async throws {
        let handle = try await openSession(sessionId)
        try await handle.updateMeta { meta in
            guard meta.state == .recording else { return }
            Self.closeCurrentSegment(in: &meta, at: Date())
            meta.state = .paused
        }
    }
}
