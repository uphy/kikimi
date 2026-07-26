import Foundation

// MARK: - MeetingWorkspaceViewModel + Audio input selection (docs/design/10-audio-input-selection.md
// section 6.1)

/// Split into its own file (alongside `MeetingWorkspaceViewModel.swift`'s other extensions, e.g.
/// `+Prep.swift`) to keep that file under the project's `file_length` lint limit.
/// `MeetingWorkspaceViewModel` (a different file) is this extension's only caller, besides its own
/// `hydrateFromSessionHandle()`/`startRecording()` also calling `enumerateAudioInputs()` directly.
extension MeetingWorkspaceViewModel {
    /// Runs `docs/design/10-audio-input-selection.md` section 6.2's steps 0/1/1b at the top of
    /// `startRecording()`: the defensive `hasEnabledSource` guard, re-resolving `audioInputSelection`
    /// against a fresh enumeration for the `.recordingStart` phase (section 4 ②, validating both mic
    /// UID and system bundle id -- unlike phase ①'s hydrate-time resolution, which only validates
    /// the mic), and the "mic enabled but zero input devices" guard (section 4 ③/section 8 failure
    /// mode #4; `AudioCapture` itself has no device enumeration, so this check is this view model's
    /// responsibility).
    ///
    /// Returns `false` (having already presented a `.recordingStartFailed` banner) if
    /// `startRecording()` must abort before ever calling `SessionStore.beginRecording(_:)` --
    /// `recordingButtonState` is left untouched by both failure branches, since nothing has started
    /// yet and no rollback is needed.
    func resolveAudioInputSelectionForRecordingStart() -> Bool {
        guard audioInputSelection.hasEnabledSource else {
            logger.warning("startRecording() called with no enabled audio input source for session \(self.sessionId, privacy: .public)")
            presentRecordingStartFailedBanner("入力がすべて無効です。マイクまたはシステム音声を有効にしてください")
            return false
        }

        enumerateAudioInputs()
        // The `bundleId` resolution below must be checked against `inputEnumerator
        // .registeredSystemAudioApps()` (unfiltered by `isRunningOutput`), not the published
        // `availableSystemAudioApps` (Picker display list, output-filtered): the selected app may
        // simply not be producing audio *yet* at the moment recording starts (e.g. Zoom launched but
        // the meeting hasn't started), which is not the same as "gone". Using the output-filtered
        // list here would destructively widen the selection to "All System Audio" on every such
        // recording start, silently capturing audio the user did not intend to record
        // (`docs/design/10-audio-input-selection.md` section 4 ②, section 5.1's
        // `resolveIncludedProcesses` basis).
        audioInputSelection = AudioInputResolver.resolve(
            selection: audioInputSelection,
            availableDevices: availableInputDevices,
            availableApps: inputEnumerator.registeredSystemAudioApps(),
            phase: .recordingStart
        )

        if audioInputSelection.mic.enabled && availableInputDevices.isEmpty {
            logger.error("startRecording() aborted for session \(self.sessionId, privacy: .public): mic enabled but no input devices are available")
            presentRecordingStartFailedBanner("利用できるマイクがありません")
            return false
        }

        return true
    }

    /// `docs/design/10-audio-input-selection.md` section 4 ①'s hydrate-time resolution, called from
    /// `hydrateFromSessionHandle()`: reads `appState.lastAudioInput`, resolves it against a fresh
    /// enumeration (`.windowOpen` phase -- mic UID validated, system bundle id left as-is), and
    /// publishes the result as `audioInputSelection`.
    ///
    /// Guarded the same way as `hydrateFromSessionHandle()`'s `recordingButtonState` hydration
    /// (section 6.1): if a popover already moved `audioInputSelection` away from `.default` before
    /// this hydration completed, that edit wins and is left untouched here.
    func hydrateAudioInputSelectionIfStillDefault() {
        guard audioInputSelection == .default else { return }
        enumerateAudioInputs()
        audioInputSelection = AudioInputResolver.resolve(
            selection: appState.data.lastAudioInput,
            availableDevices: availableInputDevices,
            availableApps: availableSystemAudioApps,
            phase: .windowOpen
        )
    }

    /// Re-enumerates input devices/system-audio apps and, only in the two states where the
    /// destructive mic resolution (section 4 ①) is safe to reapply, re-resolves
    /// `audioInputSelection` against the fresh enumeration.
    ///
    /// Called by the (not-yet-built) input popover's `onAppear` (section 7.2: "開くたびに列挙").
    /// `Draft` and `.disabledOtherRecording` are the only states where re-resolving is appropriate
    /// (section 6.1): while `Recording`/`.starting`/`.stopping`, the popover exists purely to show
    /// the configuration actually in use for the in-flight recording, so `audioInputSelection` must
    /// not be rewritten out from under it.
    func refreshAudioInputs() {
        enumerateAudioInputs()
        guard shouldReapplyDestructiveMicResolution else { return }
        audioInputSelection = AudioInputResolver.resolve(
            selection: audioInputSelection,
            availableDevices: availableInputDevices,
            availableApps: availableSystemAudioApps,
            phase: .windowOpen
        )
    }

    /// Refreshes `availableInputDevices`/`availableSystemAudioApps` from `inputEnumerator` without
    /// touching `audioInputSelection`. Shared by `hydrateFromSessionHandle()`, `startRecording()`
    /// (which always needs a fresh enumeration regardless of state), and `refreshAudioInputs()`
    /// above.
    func enumerateAudioInputs() {
        availableInputDevices = inputEnumerator.inputDevices()
        availableSystemAudioApps = inputEnumerator.systemAudioProcesses()
    }

    /// `true` only for `.startRecording` (Draft), `.disabledOtherRecording`, `.paused`, and
    /// `.pausedDisabledOtherRecording` -- see `refreshAudioInputs()`'s doc comment. Paused is
    /// included alongside Draft: no audio capture is in flight while Paused (kikimi.md 4 章), so
    /// re-resolving the selection ahead of a future `resumeRecording()` is exactly as safe as
    /// ahead of a fresh `startRecording()`.
    private var shouldReapplyDestructiveMicResolution: Bool {
        switch recordingButtonState {
        case .startRecording, .disabledOtherRecording, .paused, .pausedDisabledOtherRecording:
            return true
        case .starting, .recording, .pausing, .resuming, .ending, .ended:
            return false
        }
    }

    /// Production default for `MeetingWorkspaceViewModel.AudioCaptureFactory`: a real `AudioCapture`
    /// rooted at the session's directory (`AudioCapture` itself derives
    /// `audio/mic_NNN.wav`/`audio/system_NNN.wav` beneath it, `NNN` = `recordingIndex`), recording
    /// from the given (already-resolved, section 4 ②) `AudioInputSelection`.
    static func defaultAudioCaptureFactory(_ directory: URL, _ selection: AudioInputSelection, _ recordingIndex: Int) -> RecordingAudioCapturing {
        AudioCapture(sessionDirectory: directory, selection: selection, recordingIndex: recordingIndex)
    }

    // MARK: - Degradation banner wiring (section 5.2 / 8章 failure modes #7/#9)

    /// Maps a `RecordingTranscriptPipelining.onDegrade` event onto a `WorkspaceBanner`, wired by
    /// `startRecording()`. This is the gap identified by section 8's failure mode table: previously
    /// nothing ever constructed `.systemAudioUnavailable`/`.fileWriteFailed` `WorkspaceBanner`s, so a
    /// mid-recording (or start-time system-only) degradation was silently invisible to the user.
    /// Every other `AudioCaptureError` case is only ever thrown from `AudioCapture.start()`, never
    /// delegate-reported via `didDegrade`, so it is logged defensively rather than mapped to a banner.
    ///
    /// `MainActor`-isolated: called only through the `Task { @MainActor in ... }` hop
    /// `startRecording()` wires around `pipeline.onDegrade` (the callback itself fires on
    /// `AudioCapture`'s `eventQueue`, not the main thread).
    func handleAudioCaptureDegraded(source: AudioSourceKind, error: AudioCaptureError) {
        switch error {
        case .systemAudioUnavailable:
            // `noActiveSourcesRemain` (section 5.2's wording-branch requirement) is derived from
            // `audioInputSelection.mic.enabled` rather than threaded through `AudioCaptureError`
            // itself: given the section 5.2 start() outcome matrix (mic enabled and failing to start
            // is always fatal, never a degradation), `AudioCapture`'s `activeSources` can only become
            // empty from a system-audio degradation if the microphone was never an active source to
            // begin with -- i.e. iff `audioInputSelection.mic.enabled == false` for this recording.
            // `audioInputSelection` stays read-only for the whole Recording state (section 7.1: the
            // popover is read-only while recording), so it reliably still reflects the selection
            // `capture.start()` was actually called with.
            presentSystemAudioUnavailableBanner(noActiveSourcesRemain: !audioInputSelection.mic.enabled)
            // `docs/design/24-system-audio-leak-mitigation.md` §5.2's `activeSources == {mic}` gate:
            // once system audio has degraded away, the built-in-speaker banner no longer applies.
            outputRoute.systemAudioDegradedInCurrentSegment = true
            banners.removeAll { $0.id == WorkspaceBanner.builtInSpeakerOutputDetected.id }
        case .fileWriteFailed:
            banners.removeAll { $0.id == WorkspaceBanner.fileWriteFailed(source: source).id }
            banners.append(.fileWriteFailed(source: source))
        default:
            logger.warning(
                """
                Unexpected AudioCaptureError reached didDegrade for session \(self.sessionId, privacy: .public), \
                source \(source.rawValue, privacy: .public): \(String(describing: error), privacy: .public)
                """
            )
        }
    }

    /// De-duplicates like `presentRecordingStartFailedBanner`/`upsertDownloadingBanner`
    /// (`MeetingWorkspaceViewModel.swift`): replaces any existing `.systemAudioUnavailable` banner
    /// rather than appending alongside it, since `WorkspaceBanner.id` does not vary by
    /// `noActiveSourcesRemain`.
    private func presentSystemAudioUnavailableBanner(noActiveSourcesRemain: Bool) {
        banners.removeAll {
            if case .systemAudioUnavailable = $0 { return true }
            return false
        }
        banners.append(.systemAudioUnavailable(noActiveSourcesRemain: noActiveSourcesRemain))
    }
}
