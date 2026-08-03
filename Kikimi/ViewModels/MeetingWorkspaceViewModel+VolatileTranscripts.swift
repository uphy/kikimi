import Foundation

// MARK: - MeetingWorkspaceViewModel + volatile transcript subscription
// (`docs/design/11-streaming-stt.md` section 3.6)

/// Split into its own file (alongside `MeetingWorkspaceViewModel.swift`'s other extensions, e.g.
/// `+Prep.swift`/`+AudioInput.swift`) to keep that file under the project's `file_length` lint limit.
/// `MeetingWorkspaceViewModel.startRecording()`/`stopRecording()` are this extension's only callers.
extension MeetingWorkspaceViewModel {
    /// How long a confirming buffer may sit unclaimed before it is dropped. Only ever reached when
    /// the segment's `transcript.jsonl` append failed (`TranscriptPipeline.appendOrLog` logs and
    /// swallows those, deliberately never yielding them to `liveSegments`), since the normal path
    /// clears the buffer as soon as the row arrives. Sized well above the worst realistic re-decode:
    /// a 120s retention window (`docs/design/33-meeting-two-pass-decode.md` MT6) splits into four
    /// 30s Qwen3 windows at RTF 0.046, i.e. under 6s of decode.
    static let volatileConfirmingExpiry: Duration = .seconds(30)

    /// Subscribes to `pipeline.volatileTranscripts` and mirrors each source's in-progress text into
    /// `micVolatileText`/`systemVolatileText`, and each source's just-confirmed text into
    /// `micConfirmingText`/`systemConfirmingText`.
    ///
    /// The confirming half is what keeps the Transcript タブ's trailing line from blinking out.
    /// `SttEngine` clears its pending text the instant a segment is confirmed, but that segment only
    /// becomes a row after `TranscriptPipeline` has re-decoded its window (~1.15s for a 25s window,
    /// `docs/design/45-qwen3-batch-decode.md`) and appended it to `transcript.jsonl`. Mirroring only
    /// `text` meant erasing the line for that whole interval and re-drawing it afterwards. Holding
    /// `confirming` until the matching `liveSegments` value arrives (`clearConfirmingText(for:)`,
    /// called from `+RecordingInternals.swift`) makes the handoff continuous instead.
    ///
    /// Appends rather than replaces: a source can confirm a second window while the first is still
    /// being re-decoded, so more than one can be in flight at a time.
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
                guard !volatile.confirming.isEmpty else { continue }
                self.appendConfirmingText(volatile.confirming, for: volatile.source)
            }
        }
    }

    /// Cancels the subscription and clears every property it drives -- a stopped/ended recording must
    /// never keep showing a stale in-progress line (there is no `SttEngine` left running to ever
    /// clear it via a later value, and no `liveSegments` value left to claim a confirming buffer).
    func stopVolatileTranscriptSubscription() {
        volatileTranscriptTask?.cancel()
        volatileTranscriptTask = nil
        micVolatileText = ""
        systemVolatileText = ""
        for task in volatileConfirmingExpiryTasks.values {
            task.cancel()
        }
        volatileConfirmingExpiryTasks.removeAll()
        micConfirmingText = ""
        systemConfirmingText = ""
    }

    /// Clears one source's confirming buffer -- called the moment that source's next row arrives via
    /// `liveSegments`, which is exactly the point where the text it was standing in for became
    /// visible as a real row.
    ///
    /// Clears the whole buffer rather than just the arriving row's share. Matching share-for-share is
    /// not possible anyway (the row carries *re-decoded* text, which deliberately differs from the
    /// streaming text held here), and it is not needed: a window's rows are appended back to back by
    /// the same forwarding `Task`, so they land together, and a second window cannot confirm while
    /// the first is still decoding -- confirmation events are at least one chunk apart (2.24s by
    /// default) and a chunk-sized window re-decodes in well under that.
    func clearConfirmingText(for source: AudioSourceKind) {
        volatileConfirmingExpiryTasks.removeValue(forKey: source)?.cancel()
        switch source {
        case .mic:
            // Guarded rather than assigned unconditionally: this runs for every confirmed row, and
            // `@Published` publishes on every write, changed or not.
            if !micConfirmingText.isEmpty { micConfirmingText = "" }
        case .system:
            if !systemConfirmingText.isEmpty { systemConfirmingText = "" }
        }
    }

    private func appendConfirmingText(_ text: String, for source: AudioSourceKind) {
        switch source {
        case .mic:
            micConfirmingText += text
        case .system:
            systemConfirmingText += text
        }
        volatileConfirmingExpiryTasks[source]?.cancel()
        volatileConfirmingExpiryTasks[source] = Task { [weak self] in
            try? await Task.sleep(for: Self.volatileConfirmingExpiry)
            guard !Task.isCancelled, let self else { return }
            self.clearConfirmingText(for: source)
        }
    }
}
