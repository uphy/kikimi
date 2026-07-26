import Foundation

// MARK: - MeetingWorkspaceViewModel + volatile transcript subscription
// (`docs/design/11-streaming-stt.md` section 3.6)

/// Split into its own file (alongside `MeetingWorkspaceViewModel.swift`'s other extensions, e.g.
/// `+Prep.swift`/`+AudioInput.swift`) to keep that file under the project's `file_length` lint limit.
/// `MeetingWorkspaceViewModel.startRecording()`/`stopRecording()` are this extension's only callers.
extension MeetingWorkspaceViewModel {
    /// Subscribes to `pipeline.volatileTranscripts` and mirrors each source's latest in-progress text
    /// into `micVolatileText`/`systemVolatileText`. No extra "clear on confirm" logic is needed here:
    /// per `SttVolatileTranscript`'s contract, the pipeline itself yields an empty-`text` value for a
    /// source the moment its pending content is confirmed into a `SttFinalizedSegment` (which arrives
    /// via the separate `liveSegments` subscription in `MeetingWorkspaceViewModel.swift`), so simply
    /// assigning whatever text arrives keeps both properties correct.
    func startVolatileTranscriptSubscription(pipeline: RecordingTranscriptPipelining) {
        volatileTranscriptTask?.cancel()
        volatileTranscriptTask = Task { [weak self] in
            for await volatile in pipeline.volatileTranscripts {
                guard let self else { return }
                switch volatile.source {
                case .mic:
                    self.micVolatileText = volatile.text
                case .system:
                    self.systemVolatileText = volatile.text
                }
            }
        }
    }

    /// Cancels the subscription and clears both properties -- a stopped/ended recording must never
    /// keep showing a stale in-progress line (there is no `SttEngine` left running to ever clear it
    /// via an empty-text value).
    func stopVolatileTranscriptSubscription() {
        volatileTranscriptTask?.cancel()
        volatileTranscriptTask = nil
        micVolatileText = ""
        systemVolatileText = ""
    }
}
