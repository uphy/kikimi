import Foundation

// MARK: - MeetingWorkspaceViewModel + recording-lifecycle internals
//
// Split into its own file (alongside `+Prep.swift`/`+AudioInput.swift`/`+VolatileTranscripts.swift`/
// `+Summary.swift`) to keep `MeetingWorkspaceViewModel.swift` under the project's `file_length` lint
// limit. Everything below used to live directly in that file; `MeetingWorkspaceViewModel.swift`
// (a different file) is this extension's only external caller, so every method a main-file method
// invokes had to drop its former `private` (file-scoped, not type-scoped) access.
extension MeetingWorkspaceViewModel {
    // MARK: - WindowManager.$recordingSessionId subscription (section 6.1/10.1)

    /// Not `private`: called from `onAppear()` in `MeetingWorkspaceViewModel.swift`.
    func subscribeToRecordingSessionId() {
        guard recordingSessionIdCancellable == nil else { return }
        recordingSessionIdCancellable = WindowManager.shared.$recordingSessionId
            .sink { [weak self] activeSessionId in
                self?.applyRecordingSessionIdChange(activeSessionId)
            }
    }

    private func applyRecordingSessionIdChange(_ activeSessionId: String?) {
        recordingButtonState = Self.nextRecordingButtonState(
            current: recordingButtonState,
            selfSessionId: sessionId,
            activeSessionId: activeSessionId
        )
    }

    /// Pure state-transition helper (section 10.1) driving the `.startRecording` <->
    /// `.disabledOtherRecording` and `.paused` <-> `.pausedDisabledOtherRecording` transitions from
    /// `WindowManager.$recordingSessionId` changes (kikimi.md 10 章: "他ウィンドウが Recording 中は、この
    /// ウィンドウの `録音開始`/`録音再開` が disabled"), kept as a `static func` (independent of
    /// Combine/`WindowManager`) so it is directly unit-testable (section 12). Every other state
    /// (`.starting`/`.recording`/`.pausing`/`.resuming`/`.ending`/`.ended`) is self-driven by this
    /// view model's own recording methods and is left untouched by external notifications about
    /// *other* sessions' recording state.
    nonisolated static func nextRecordingButtonState(
        current: RecordingButtonState,
        selfSessionId: String,
        activeSessionId: String?
    ) -> RecordingButtonState {
        switch current {
        case .startRecording, .disabledOtherRecording:
            if let activeSessionId, activeSessionId != selfSessionId {
                return .disabledOtherRecording(otherSessionId: activeSessionId)
            }
            return .startRecording
        case .paused(let elapsedSeconds), .pausedDisabledOtherRecording(let elapsedSeconds, _):
            if let activeSessionId, activeSessionId != selfSessionId {
                return .pausedDisabledOtherRecording(elapsedSeconds: elapsedSeconds, otherSessionId: activeSessionId)
            }
            return .paused(elapsedSeconds: elapsedSeconds)
        case .starting, .recording, .pausing, .resuming, .ending, .ended:
            return current
        }
    }

    // MARK: - Recording-start rollback/banners

    /// Shared "already recording elsewhere" vs. generic-failure banner wording for
    /// `beginRecording(_:)`/`resumeRecording(_:)`/`reopenForRecording(_:)` all failing the same way
    /// (`SessionStoreError.anotherSessionRecording`, section 11 failure mode #4).
    private static func recordingStoreFailureMessage(_ error: Error) -> String {
        if case SessionStoreError.anotherSessionRecording = error {
            // Race: two windows' record buttons clicked almost simultaneously. The UI is expected to
            // already disable this button once `WindowManager.$recordingSessionId` catches up; this
            // is just the defensive message for the narrow window before that happens.
            return "既に別の会議を録音中です"
        }
        return "録音を開始できませんでした"
    }

    /// Not `private`: called from `startRecording()` in `MeetingWorkspaceViewModel.swift`.
    func handleBeginRecordingFailure(_ error: Error) {
        logger.warning(
            "beginRecording failed for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
        )
        presentRecordingStartFailedBanner(Self.recordingStoreFailureMessage(error))
        recordingButtonState = .startRecording
    }

    /// Shared failure handler for `resumeRecording()`/`reopenRecording()`'s own
    /// `SessionStore.resumeRecording(_:)`/`reopenForRecording(_:)` call failing (before any
    /// audio/pipeline work has started) — mirrors `handleBeginRecordingFailure(_:)` but returns to
    /// `.paused`/`.ended` respectively instead of `.startRecording`. `meta` is untouched by the
    /// failed `SessionStore` call, so its already-loaded `durationMs` is still accurate for the
    /// `.paused` case's elapsed-time display. Not `private`: called from `resumeRecording()`/
    /// `reopenRecording()` in `MeetingWorkspaceViewModel.swift`.
    func handleResumeOrReopenFailure(_ error: Error, previousState: SessionState) {
        logger.warning(
            "resume/reopen recording failed for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
        )
        presentRecordingStartFailedBanner(Self.recordingStoreFailureMessage(error))
        switch previousState {
        case .paused:
            recordingButtonState = .paused(elapsedSeconds: Self.cumulativeElapsedSeconds(for: meta, now: now()))
        case .ended:
            recordingButtonState = .ended
        case .draft, .recording:
            // Unreachable from this call site (only `.paused`/`.ended` ever call this), but handled
            // exhaustively rather than assumed impossible.
            recordingButtonState = .startRecording
        }
    }

    /// Rolls back a recording-segment-start attempt that failed at `TranscriptPipeline.prepare(...)`
    /// or `AudioCapture.start()` via `SessionStore.cancelRecordingStart(_:revertingTo:)` — never
    /// `pauseRecording(_:)`/`endMeeting(_:)`, since `AudioCapture.start()` has not (yet, or ever, in
    /// this attempt) succeeded and no audio bytes have been written for this segment
    /// (`07-session-store.md` section 6.1's `cancelRecordingStart(_:revertingTo:)` contract). Not
    /// `private`: called from `runRecordingSegmentStart` in `MeetingWorkspaceViewModel.swift`.
    func rollbackFailedSegmentStart(reason: String, previousState: SessionState) async {
        // `docs/design/13-speaker-diarization.md` section 5.1: by the time either failure site that
        // calls this has run, `runRecordingSegmentStart` already called
        // `diarizationCoordinatorIfEnabled()`'s `beginSegment(startMsOffset:hasSystemAudio:)` for this
        // (now-abandoned) attempt, leaving an open `DiarizationActiveRange` (and, if system audio was
        // enabled, a live backend generation) with nothing to ever close it -- this segment never
        // reaches `pauseRecording()`/`endMeeting()`'s own `endSegment(reason:)` call, since it never
        // successfully started. Left alone, that stale open range would (a) make a retried
        // `beginSegment` append a *second* open range, violating the "only the last range is open"
        // invariant `closeCurrentActiveRange()` (and `currentActiveRanges()` above) both assume, and
        // (b) keep reporting "diarization active" for this segment's `startMsOffset` onward even into a
        // later, diarization-disabled segment, misattributing its `system` rows as diarized instead of
        // showing the physical-source fallback (design section 5.3's precondition). `.paused` (not
        // `.ended`) matches this case exactly: the meeting itself is not over, only this one segment
        // -start attempt failed. A no-op if `diarizationCoordinatorIfEnabled()` returned `nil` (feature
        // disabled) or `beginSegment` itself already left `isRunningThisSegment == false` (no system
        // audio this attempt) -- `endSegment`'s own guard handles both.
        await diarizationCoordinator?.endSegment(reason: .paused)

        do {
            try await sessionStore.cancelRecordingStart(sessionId, revertingTo: previousState)
        } catch {
            logger.error(
                "cancelRecordingStart failed while rolling back a failed segment start for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        presentRecordingStartFailedBanner(reason)
        meta = await sessionHandle.meta
        switch previousState {
        case .draft:
            recordingButtonState = .startRecording
        case .paused:
            recordingButtonState = .paused(elapsedSeconds: Self.cumulativeElapsedSeconds(for: meta, now: now()))
        case .ended:
            recordingButtonState = .ended
        case .recording:
            // Unreachable: `runRecordingSegmentStart(previousStateOnFailure:)`'s three callers only
            // ever pass `.draft`/`.paused`/`.ended`. Handled exhaustively rather than assumed
            // impossible.
            recordingButtonState = .startRecording
        }
    }

    /// Surfaces a `.recordingStartFailed` banner, replacing any previous one instead of appending
    /// alongside it. `WorkspaceBanner.id` for `.recordingStartFailed` does not vary by `message`
    /// (`MeetingWorkspaceTypes.swift`), so a bare `banners.append(...)` on a retried failed start
    /// would leave two banner entries sharing one `id` — `MeetingWorkspaceView`'s `ForEach(viewModel
    /// .banners)` requires unique ids, so that would corrupt the banner list's rendering/dismissal.
    /// Also clears any leftover `.sttModelDownloading` banner: a start attempt can fail mid-download
    /// (`prepare()` throwing after emitting progress for one source but not completing), and without
    /// this the stale "downloading NN%" banner would never be cleared (the success path's
    /// `clearDownloadingBanners()` call is never reached on this branch).
    ///
    /// Not `private`: also called from `MeetingWorkspaceViewModel+AudioInput.swift`'s
    /// `resolveAudioInputSelectionForRecordingStart()`, so section 6.2 steps 0/1b's guard banners
    /// surface through the same de-duplicating path.
    func presentRecordingStartFailedBanner(_ message: String) {
        clearDownloadingBanners()
        banners.removeAll {
            if case .recordingStartFailed = $0 { return true }
            return false
        }
        banners.append(.recordingStartFailed(message: message))
    }

    /// Not `private`: called from `runRecordingSegmentStart` in `MeetingWorkspaceViewModel.swift`.
    func upsertDownloadingBanner(source: AudioSourceKind, progress: SttModelDownloadProgress) {
        let updated = WorkspaceBanner.sttModelDownloading(source: source, progress: progress.fractionCompleted)
        if let index = banners.firstIndex(where: {
            if case .sttModelDownloading(let existingSource, _) = $0 { return existingSource == source }
            return false
        }) {
            banners[index] = updated
        } else {
            banners.append(updated)
        }
    }

    /// Not `private`: called from `runRecordingSegmentStart` in `MeetingWorkspaceViewModel.swift`
    /// (and from `presentRecordingStartFailedBanner` above, in this file).
    func clearDownloadingBanners() {
        banners.removeAll {
            if case .sttModelDownloading = $0 { return true }
            return false
        }
    }

    // MARK: - Elapsed-time ticker (section 6.1)

    /// One-second `Task.sleep` loop recomputing `recordingButtonState`'s `elapsedSeconds` as the
    /// cumulative recording-active time (`Self.cumulativeElapsedSeconds(for:)`: closed segments'
    /// `durationMs` + elapsed time in the currently-open segment). Safe to assume `meta.recordings`
    /// has an open last segment here because `runRecordingSegmentStart` always reloads `meta`
    /// immediately before calling this, so the just-opened segment is guaranteed present at the
    /// moment this is invoked. Not `private`: called from `runRecordingSegmentStart` in
    /// `MeetingWorkspaceViewModel.swift`.
    func startElapsedTimer() {
        elapsedTimerTask?.cancel()
        guard let lastSegment = meta.recordings.last, lastSegment.endedAt == nil else {
            logger.error("startElapsedTimer() called with no open recording segment for session \(self.sessionId, privacy: .public); not starting the ticker.")
            return
        }
        let baseDurationMs = meta.durationMs
        let segmentStartedAt = lastSegment.startedAt
        elapsedTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let elapsedInSegment = self.now().timeIntervalSince(segmentStartedAt)
                let totalSeconds = max(0, Int((Double(baseDurationMs) / 1_000) + elapsedInSegment))
                self.recordingButtonState = .recording(elapsedSeconds: totalSeconds)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Not `private`: called from `finishStoppingCapture()` in `MeetingWorkspaceViewModel.swift`.
    func stopElapsedTimer() {
        elapsedTimerTask?.cancel()
        elapsedTimerTask = nil
    }

    /// Cumulative recording-active time, in seconds, for `meta` at the current moment (kikimi.md
    /// 10 章 "表示は常に累積"): every closed `recordings[]` segment's length (`meta.durationMs`) plus,
    /// if the last segment is still open (`.recording`), the elapsed time since it started. Shared
    /// by `startElapsedTimer()`'s per-second tick, every transition that sets `.recording(...)`/
    /// `.paused(...)`, and `MeetingWorkspaceViewModel.initialRecordingButtonState(for:)`'s hydration.
    /// Moved here (a `static func`, so any extension file can host it) to keep
    /// `MeetingWorkspaceViewModel.swift` itself under the project's `file_length` lint limit.
    static func cumulativeElapsedSeconds(for meta: SessionMeta, now: Date = Date()) -> Int {
        guard let lastSegment = meta.recordings.last, lastSegment.endedAt == nil else {
            return max(0, meta.durationMs / 1_000)
        }
        let elapsedInSegment = now.timeIntervalSince(lastSegment.startedAt)
        return max(0, Int((Double(meta.durationMs) / 1_000) + elapsedInSegment))
    }

    /// Derives the `recordingButtonState` a freshly-hydrated `meta.state` implies. `.recording` is
    /// not expected in ordinary operation (a session left `.recording` across an app relaunch is
    /// instead resolved by `SessionStore.finalizeCrashedSession(_:)` — to `.paused`, not `.ended` —
    /// before any workspace window reopens it, `07-session-store.md` section 10), but is handled
    /// defensively rather than assumed impossible. Lives here (not next to its only caller,
    /// `hydrateFromSessionHandle()`) to keep `MeetingWorkspaceViewModel.swift` under the project's
    /// `file_length` lint limit, same as `cumulativeElapsedSeconds(for:now:)` above.
    static func initialRecordingButtonState(for meta: SessionMeta, now: Date = Date()) -> RecordingButtonState {
        switch meta.state {
        case .draft:
            return .startRecording
        case .recording:
            return .recording(elapsedSeconds: cumulativeElapsedSeconds(for: meta, now: now))
        case .paused:
            return .paused(elapsedSeconds: cumulativeElapsedSeconds(for: meta, now: now))
        case .ended:
            return .ended
        }
    }

    // MARK: - Live transcript segment subscription (section 6.3)

    /// Not `private`: called from `runRecordingSegmentStart` in `MeetingWorkspaceViewModel.swift`.
    func startLiveSegmentSubscription(pipeline: RecordingTranscriptPipelining) {
        liveSegmentTask?.cancel()
        liveSegmentTask = Task { [weak self] in
            for await segment in pipeline.liveSegments {
                guard let self else { return }
                let row = TranscriptRowViewModel(
                    id: segment.id,
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    speaker: segment.speaker,
                    rawText: segment.text,
                    state: .raw
                )
                self.transcriptRows = TranscriptRowList.inserted(row, into: self.transcriptRows)
                // The row this source's confirming buffer was standing in for is now on screen, so
                // drop the buffer in the same update -- rendering both would double the text. Must
                // stay ahead of the `await`s below: they suspend, and a suspension between the
                // insert and the clear is exactly the one-frame duplicate this ordering avoids.
                self.clearConfirmingText(for: segment.speaker)
                // Section 7.1 (`docs/design/04-summary-updater.md`): only newly-confirmed live
                // segments count; onAppear()'s backfill never reaches this loop, so it can't
                // double-count.
                await self.summaryUpdater?.noteSegmentAppended()
                // `docs/design/03-refinement-batch.md` §3.3: this `segment` is only ever yielded here
                // after `TranscriptPipeline.appendOrLog` already durably appended it to
                // `transcript.jsonl`, so every `enqueue(_:)` call is guaranteed to be for a persisted
                // segment. A silent no-op while no queue exists yet (not Recording).
                await self.refinementQueue?.enqueue(segment)
                // `docs/design/13-speaker-diarization.md` sections 4.5/5.3: derives/refreshes
                // `speakerLabels[row.id]` the moment a row is confirmed -- mic rows resolve
                // immediately (static `self_name`), system rows get their `confirmedAt` anchor here
                // and an initial (likely `.recognizing`) label.
                await self.handleSegmentConfirmedForDiarization(segment: segment)
            }
        }
    }

    /// Not `private`: called from `finishStoppingCapture()` in `MeetingWorkspaceViewModel.swift`.
    func stopLiveSegmentSubscription() {
        liveSegmentTask?.cancel()
        liveSegmentTask = nil
    }
}
