import Foundation

// MARK: - OutputRouteBannerState

/// Groups `MeetingWorkspaceViewModel`'s `docs/design/24-system-audio-leak-mitigation.md` §5.1/§5.2
/// state into a single stored property (`MeetingWorkspaceViewModel.outputRoute`) to avoid adding
/// three separate top-level stored properties to that file (`file_length` lint limit).
struct OutputRouteBannerState {
    /// This recording segment's `OutputRouteMonitor`; created at Recording entry, stopped at
    /// Paused/Ended (§5.1's "Recording 突入時に 1 回評価し... Paused/Ended ではタイマーを止め"). `nil`
    /// when `audio.suggest_headphones_on_builtin_speaker == false` (§5.3).
    var monitor: OutputRouteMonitor?
    /// `true` once the user dismissed `.builtInSpeakerOutputDetected` for this `MeetingWorkspace
    /// ViewModel` instance's lifetime (§5.2). Never reset on Paused/Ended -- only a fresh window (a
    /// new instance) starts this back at `false`.
    var dismissedBuiltInSpeakerBanner = false
    /// `true` once a `.systemAudioUnavailable` degradation hit the *current* recording segment. Part
    /// of the `activeSources == {mic}` gate (§5.2's last bullet): `audioInputSelection.system.enabled`
    /// alone doesn't reflect a mid-recording degradation, since `audioInputSelection` stays read-only
    /// for the whole Recording state (`handleAudioCaptureDegraded`'s own doc comment). Reset to
    /// `false` at the start of every recording segment.
    var systemAudioDegradedInCurrentSegment = false
}

// MARK: - MeetingWorkspaceViewModel + Output route banner (docs/design/24-system-audio-leak-mitigation.md §5)

/// Split into its own file (alongside `MeetingWorkspaceViewModel.swift`'s other extensions) to keep
/// that file under the project's `file_length` lint limit. Owns `OutputRouteMonitor`'s
/// Recording/Paused/Ended lifecycle wiring and the `builtInSpeakerOutputDetected` banner's
/// append/remove/permanent-dismiss state machine.
extension MeetingWorkspaceViewModel {
    /// Creates and starts this segment's `OutputRouteMonitor`, called from `runRecordingSegmentStart`
    /// (`+Recording.swift`) alongside its other Recording-scoped collaborator setup. A no-op if
    /// `audio.suggest_headphones_on_builtin_speaker == false` (§5.3's config gate) or if a monitor is
    /// already running (idempotent across `startRecording()`/`resumeRecording()`/`reopenRecording()`,
    /// mirroring `refinementQueueIfNeeded().start()`'s own idempotency).
    ///
    /// Also resets `systemAudioDegradedInCurrentSegment` -- a fresh segment starts with system audio
    /// presumed healthy, regardless of whether the *previous* segment degraded.
    func startOutputRouteMonitorIfNeeded() {
        outputRoute.systemAudioDegradedInCurrentSegment = false

        guard appConfig.data.audio.suggestHeadphonesOnBuiltInSpeaker else {
            return
        }
        guard outputRoute.monitor == nil else {
            return
        }

        let monitor = OutputRouteMonitor()
        monitor.onChange = { [weak self] classification in
            Task { @MainActor in
                self?.handleOutputRouteClassification(classification)
            }
        }
        outputRoute.monitor = monitor
        monitor.start()
    }

    /// Stops and discards this segment's `OutputRouteMonitor`, called from `finishStoppingCapture`
    /// (`+Recording.swift`) alongside its other Recording-scoped teardown -- i.e. on both
    /// `pauseRecording()` and `endMeeting()`. Also removes any currently-shown
    /// `.builtInSpeakerOutputDetected` banner: with no monitor running, a stale banner could otherwise
    /// linger through a Paused/Ended state where the claim ("音声を録音中です") is no longer accurate.
    func stopOutputRouteMonitor() {
        outputRoute.monitor?.stop()
        outputRoute.monitor = nil
        banners.removeAll { $0.id == WorkspaceBanner.builtInSpeakerOutputDetected.id }
    }

    /// `OutputRouteMonitor.onChange` handler (hopped to `@MainActor`). Appends/removes
    /// `.builtInSpeakerOutputDetected` per §5.2: `.builtInSpeaker` adds the banner (unless already
    /// dismissed this session, or system audio isn't actually active for this segment); `.other`
    /// removes it so a later device change can re-trigger the banner.
    private func handleOutputRouteClassification(_ classification: OutputRouteClassification) {
        switch classification {
        case .builtInSpeaker:
            guard isSystemAudioActiveForOutputRouteBanner else { return }
            guard !outputRoute.dismissedBuiltInSpeakerBanner else { return }
            guard !banners.contains(where: { $0.id == WorkspaceBanner.builtInSpeakerOutputDetected.id }) else { return }
            banners.append(.builtInSpeakerOutputDetected)
        case .other:
            banners.removeAll { $0.id == WorkspaceBanner.builtInSpeakerOutputDetected.id }
        }
    }

    /// `docs/design/24-system-audio-leak-mitigation.md` §5.2's last bullet: this banner only makes
    /// sense while system audio is actually being captured for this segment -- with no `(system)`
    /// stream, there is nothing for the mic to acoustically duplicate. Checks both the static
    /// per-segment selection and any mid-recording degradation (`OutputRouteBannerState
    /// .systemAudioDegradedInCurrentSegment`, set by `handleAudioCaptureDegraded(source:error:)`).
    private var isSystemAudioActiveForOutputRouteBanner: Bool {
        audioInputSelection.system.enabled && !outputRoute.systemAudioDegradedInCurrentSegment
    }

    /// Called by `MeetingWorkspaceView`'s banner dismiss button specifically for
    /// `.builtInSpeakerOutputDetected` (§5.2): removes the banner *and* latches
    /// `dismissedBuiltInSpeakerBanner`, so `handleOutputRouteClassification(_:)` won't re-append it
    /// for the rest of this `MeetingWorkspaceViewModel` instance's lifetime (i.e. across
    /// Recording/Paused/Resume within this session window, but not across reopening the window).
    func dismissBuiltInSpeakerBanner() {
        outputRoute.dismissedBuiltInSpeakerBanner = true
        banners.removeAll { $0.id == WorkspaceBanner.builtInSpeakerOutputDetected.id }
    }
}
