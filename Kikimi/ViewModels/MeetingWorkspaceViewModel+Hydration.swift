import Foundation

// MARK: - MeetingWorkspaceViewModel + init-time hydration
//
// Split out of `MeetingWorkspaceViewModel.swift` to keep that file under the project's
// `file_length` lint limit, like the other `+*.swift` extensions. `internal` rather than `private`
// because Swift's `private` does not span files.

extension MeetingWorkspaceViewModel {
    /// Replaces the placeholder `meta`/empty `contextText`/`summaryTemplateText` seeded by `init`
    /// with the real values read from `sessionHandle` (a `var` actor property, unreadable
    /// synchronously from `init` — see `init`'s doc comment). Also derives the real initial
    /// `recordingButtonState` from `meta.state`, but only if nothing has driven
    /// `recordingButtonState` away from its `init`-time default yet (`startRecording()` etc. always
    /// wins if it raced ahead of this hydration).
    ///
    /// Also applies `docs/design/10-audio-input-selection.md` section 4 ①'s hydrate-time
    /// resolution via `hydrateAudioInputSelectionIfStillDefault()`
    /// (`MeetingWorkspaceViewModel+AudioInput.swift`), guarded by the same race pattern as
    /// `recordingButtonState` above (section 6.1).
    func hydrateFromSessionHandle() async {
        let loadedMeta = await sessionHandle.meta
        meta = loadedMeta
        contextText = await sessionHandle.readContext()
        summaryTemplateText = await sessionHandle.readSummaryTemplate()
        if recordingButtonState == .startRecording {
            recordingButtonState = Self.initialRecordingButtonState(for: loadedMeta, now: now())
        }
        hydrateAudioInputSelectionIfStillDefault()

        // kikimi.md 4 章/8 章: a reopened Paused/Ended session must show whatever `summary.md` a
        // prior recording segment already rendered, not just newly-arriving updates --
        // `startSummaryUpdaterIfNeeded()` (only called when Recording actually (re)starts) is not
        // enough on its own, since Paused/Ended sessions never call it again. Missing/unreadable is
        // the normal case for a Draft session with no summary yet, so this is a silent no-op then.
        if summaryMarkdown == nil, let onDisk = try? await sessionHandle.readText(.summaryMarkdown), !onDisk.isEmpty {
            summaryMarkdown = onDisk
        }
    }

    /// `onAppear()`'s first step (section 6.3 "初期表示"): fills `transcriptRows` from
    /// `transcript.jsonl`, then folds `refined.jsonl` over it (`docs/design/03-refinement-batch.md`
    /// §6 -- `refinedText` present -> `.refined`, present but `nil` -> `.refinedFailed`, no matching
    /// refined row -> stays `.raw`), so a reopened session shows its already-refined rows rather than
    /// only newly-arriving ones. Either read failing is logged and skipped, never propagated: a
    /// window that cannot backfill still has to open.
    ///
    /// Lives here rather than inline in `onAppear()` for the usual `file_length` reason, and here
    /// specifically because it is the same kind of "read what is already on disk into the ViewModel"
    /// step as `hydrateFromSessionHandle()` above.
    func backfillTranscriptRows() async {
        do {
            let segments = try await sessionHandle.readTranscriptSegments()
            transcriptRows = segments
                .map {
                    TranscriptRowViewModel(
                        id: $0.id,
                        startMs: $0.startMs,
                        endMs: $0.endMs,
                        speaker: $0.speaker,
                        rawText: $0.text,
                        state: .raw
                    )
                }
                .sorted { lhs, rhs in
                    lhs.startMs != rhs.startMs ? lhs.startMs < rhs.startMs : lhs.id < rhs.id
                }
        } catch {
            logger.error(
                "Failed to backfill transcript segments for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }

        do {
            let refinedSegments = try await sessionHandle.readRefinedSegments()
            transcriptRows = Self.mergeRefinedState(refinedSegments, into: transcriptRows)
        } catch {
            logger.error(
                "Failed to backfill refined segments for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
