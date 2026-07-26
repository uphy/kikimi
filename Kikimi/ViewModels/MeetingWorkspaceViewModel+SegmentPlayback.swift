import Foundation

// MARK: - MeetingWorkspaceViewModel + Segment playback (docs/design/15-segment-playback.md)

/// Split into its own file (alongside `MeetingWorkspaceViewModel.swift`'s other extensions) to keep
/// that file under the project's `file_length` lint limit. `MeetingWorkspaceView` (a different file)
/// is this extension's only caller.
extension MeetingWorkspaceViewModel {
    /// Transcript row play/stop toggle (`docs/design/15-segment-playback.md` sections 3/6). Tapping
    /// the currently-playing row's button stops it; tapping any other row resolves that row's WAV
    /// slice and starts playing it (which itself stops whatever was previously playing, per
    /// `SegmentAudioPlayer.play(...)`'s "同時に再生できるセグメントは1つ" rule).
    func toggleSegmentPlayback(_ row: TranscriptRowViewModel) {
        if playingSegmentId == row.id {
            segmentAudioPlayer.stop()
            return
        }

        guard let slice = SegmentPlaybackResolver.resolve(
            startMs: row.startMs, endMs: row.endMs, recordings: meta.recordings
        ) else {
            logger.warning(
                "Could not resolve a recording segment for transcript row \(row.id, privacy: .public) (startMs=\(row.startMs, privacy: .public), endMs=\(row.endMs, privacy: .public))"
            )
            return
        }

        let fileName = row.speaker == .mic
            ? AudioCapture.micFileName(recordingIndex: slice.recordingIndex)
            : AudioCapture.systemFileName(recordingIndex: slice.recordingIndex)
        let fileURL = sessionHandle.directoryURL
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent(fileName)

        segmentAudioPlayer.play(
            segmentId: row.id,
            fileURL: fileURL,
            localStartMs: slice.localStartMs,
            durationMs: slice.durationMs
        )
    }
}
