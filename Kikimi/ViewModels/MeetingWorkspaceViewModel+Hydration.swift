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
}
