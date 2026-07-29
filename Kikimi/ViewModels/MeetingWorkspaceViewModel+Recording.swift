import Foundation

// MARK: - MeetingWorkspaceViewModel + Recording (kikimi.md 4 章 "「停止」と「終了」を分離する"; section 6.1)

/// Split into its own file (alongside `MeetingWorkspaceViewModel.swift`'s other extensions, e.g.
/// `+Summary.swift`/`+Refinement.swift`) to keep that file under the project's `file_length` lint
/// limit. Owns the five-entry-point recording-segment state machine (`startRecording()`/
/// `pauseRecording()`/`resumeRecording()`/`endMeeting()`/`reopenRecording()`) and its shared private
/// helpers (`runRecordingSegmentStart(previousStateOnFailure:)`/`stopCaptureAndPipelineIfNeeded(
/// diarizationEndReason:)`/`finishStoppingCapture()`), plus `flushSessionHandle()` (§9's
/// app-termination flush, kept alongside this group since it touches the same `sessionHandle`
/// recording-data-safety concerns).
extension MeetingWorkspaceViewModel {

    // MARK: - Recording (section 6.1; kikimi.md 4 章 "「停止」と「終了」を分離する")
    //
    // Five entry points drive the recording-segment state machine:
    // - `startRecording()`: Draft -> Recording (opens the session's first segment).
    // - `pauseRecording()`: Recording -> Paused (closes the current segment; audio resources freed).
    // - `resumeRecording()`: Paused -> Recording (opens a new segment).
    // - `endMeeting()`: Recording/Paused -> Ended (the sole confirmation operation).
    // - `reopenRecording()`: Ended -> Recording (opens a new segment; 救済パス).
    //
    // `startRecording()`/`resumeRecording()`/`reopenRecording()` all funnel their post-`SessionStore`
    // continuation (prepare the STT model, start audio capture, wire subscriptions) through the
    // shared `runRecordingSegmentStart(previousStateOnFailure:)`; `pauseRecording()`/`endMeeting()`
    // share the same "stop capture/pipeline, then commit to SessionStore" shape.

    /// Draft -> Recording. Runs `docs/design/10-audio-input-selection.md` section 6.2's audio-input
    /// guard/resolution, then `SessionStore.beginRecording(_:)`, then
    /// `runRecordingSegmentStart(previousStateOnFailure:)`. A no-op unless
    /// `recordingButtonState == .startRecording` (defensive; the UI is expected to already disable
    /// the button otherwise).
    func startRecording() async {
        guard recordingButtonState == .startRecording else { return }

        // Steps 0/1/1b (section 6.2), factored out to `+AudioInput.swift`'s
        // `resolveAudioInputSelectionForRecordingStart()` (see its own doc comment for detail).
        guard resolveAudioInputSelectionForRecordingStart() else { return }

        recordingButtonState = .starting

        do {
            try await sessionStore.beginRecording(sessionId)
        } catch {
            handleBeginRecordingFailure(error)
            return
        }

        await runRecordingSegmentStart(previousStateOnFailure: .draft)

        // `docs/design/17-session-window-redesign.md` §4.5: only on an actual success (the Draft
        // preparation screen is about to disappear in favor of the 3-tab layout, §4.5's "Draft ->
        // Recording 遷移" row) -- a failed `runRecordingSegmentStart` rolls back to `.draft` and must
        // leave `activeTab` untouched. `meetingPaneMode` is left as whatever the user last chose.
        if case .recording = recordingButtonState {
            activeTab = .meeting
        }
    }

    /// Recording -> Paused. Stops audio capture/the STT pipeline, then
    /// `SessionStore.pauseRecording(_:)`. `on_session_end` never runs (kikimi.md 4 章): this is the
    /// "stop but the meeting continues" operation, resumable via `resumeRecording()`.
    ///
    /// A no-op unless `recordingButtonState` is `.recording` (normal first call) or `.pausing`
    /// (retry after a failed `pauseRecording(_:)` call, mirroring `endMeeting()`'s retry shape). On
    /// retry, the already-completed `AudioCapture.stop()`/`TranscriptPipeline.stopAndDrain()` are
    /// **not** re-invoked (`hasStoppedAudioAndTranscript`).
    func pauseRecording() async {
        switch recordingButtonState {
        case .recording:
            recordingButtonState = .pausing
        case .pausing:
            break // Retry: capture/pipeline may already be stopped (see hasStoppedAudioAndTranscript).
        default:
            return
        }

        await stopCaptureAndPipelineIfNeeded(diarizationEndReason: .paused)

        do {
            try await sessionStore.pauseRecording(sessionId)
        } catch {
            logger.error(
                """
                pauseRecording failed for session \(self.sessionId, privacy: .public); recording data is safe \
                (capture/pipeline already stopped), staying .pausing for retry: \(String(describing: error), privacy: .public)
                """
            )
            return
        }

        // Section 4.1/7: flush the trailing <20 segments before discarding the updater. No
        // final-title call -- on_session_end doesn't run on a pause.
        if let updater = summaryUpdater {
            await updater.updateNow(reason: .pauseFlush)
            stopSummaryUpdater()
        }

        // `docs/design/03-refinement-batch.md` §4.1/§7 "一時停止（Recording → Paused）": cuts the
        // trailing under-`batchSize` remainder into its own batch immediately, without waiting for
        // the timeout. The instance itself is **not** discarded -- it keeps processing (and stays
        // ready for the next `resumeRecording()`'s `start()` call) unlike `summaryUpdater` above.
        await refinementQueue?.flush()

        // `docs/design/05-watcher-runner.md` §9.3/§9.4: `on_interval` Watchers only fire while
        // Recording -- stop every loop `Task` now that this segment is closing. `watcherRunner`
        // itself (unlike `summaryUpdater`) is never discarded here.
        await watcherRunner.stopIntervalWatchers()

        finishStoppingCapture()
        meta = await sessionHandle.meta
        recordingButtonState = .paused(elapsedSeconds: Self.cumulativeElapsedSeconds(for: meta, now: now()))
    }

    /// Paused -> Recording. Re-runs the audio-input guard/resolution (a different device/app may
    /// have become (un)available since the pause), then `SessionStore.resumeRecording(_:)`, then
    /// `runRecordingSegmentStart(previousStateOnFailure:)`. A no-op unless `recordingButtonState`
    /// is `.paused` (the UI is expected to already disable this action from
    /// `.pausedDisabledOtherRecording`).
    func resumeRecording() async {
        guard case .paused = recordingButtonState else { return }
        guard resolveAudioInputSelectionForRecordingStart() else { return }

        recordingButtonState = .resuming

        do {
            try await sessionStore.resumeRecording(sessionId)
        } catch {
            handleResumeOrReopenFailure(error, previousState: .paused)
            return
        }

        await runRecordingSegmentStart(previousStateOnFailure: .paused)
    }

    /// Recording/Paused -> Ended: the sole confirmation operation (kikimi.md 4 章 "会議終了"). If
    /// still Recording, stops audio capture/the STT pipeline first (same as `pauseRecording()`); if
    /// already Paused, both are already stopped (`hasStoppedAudioAndTranscript` reflects that from
    /// the prior `pauseRecording()` call, so `stopCaptureAndPipelineIfNeeded()` is a no-op).
    ///
    /// A no-op unless `recordingButtonState` is `.recording`/`.paused`/`.pausedDisabledOtherRecording`
    /// (normal first call) or `.ending` (retry after a failed `endMeeting(_:)` call).
    func endMeeting() async {
        switch recordingButtonState {
        case .recording, .paused, .pausedDisabledOtherRecording:
            recordingButtonState = .ending
        case .ending:
            break // Retry.
        default:
            return
        }

        await stopCaptureAndPipelineIfNeeded(diarizationEndReason: .ended)

        do {
            try await sessionStore.endMeeting(sessionId)
        } catch {
            logger.error(
                """
                endMeeting failed for session \(self.sessionId, privacy: .public); recording data is safe \
                (capture/pipeline already stopped), staying .ending for retry: \(String(describing: error), privacy: .public)
                """
            )
            return
        }

        // Section 3.4/4.1/7 (on_session_end, once): if still Recording, `summaryUpdater` is live --
        // flush trailing segments, then the final-title call, then discard it. If already Paused,
        // it was already torn down by `pauseRecording()`, so a transient instance handles this
        // one-shot call (`summary.state.json` is file-backed, no continuity lost). `meta` reloaded
        // below surfaces the final title proposal -- this never goes through `SummaryUpdater.events`.
        if let updater = summaryUpdater {
            await updater.updateNow(reason: .pauseFlush)
            await updater.generateFinalTitleProposal()
            // `docs/design/13-speaker-diarization.md` section 4.4/6.2 ("R2 module 4"): the
            // Ended-time moving-average voiceprint update + participants merge, run exactly once
            // per `endMeeting()` call (idempotent across an `Ended -> Recording -> Ended` reopen
            // thanks to `VoiceprintStore.applyMovingAverageUpdate`'s own dedup guard -- see
            // `applyDiarizationEndedHooks(updater:)`'s own doc comment).
            await applyDiarizationEndedHooks(updater: updater)
            stopSummaryUpdater()
        } else {
            let transientUpdater = summaryUpdaterFactory(sessionHandle)
            await transientUpdater.generateFinalTitleProposal()
            await applyDiarizationEndedHooks(updater: transientUpdater)
        }

        // `docs/design/05-watcher-runner.md` §9.3/§9.4: stop `on_interval` loops (recording is
        // ending), then run every `on_session_end` Watcher exactly once, awaited as part of
        // `on_session_end`'s confirmation processing (design's "実行中はヘッダの `.ending` 状態が延びる —
        // final title 生成と同じ扱い"). Never runs on a pause (`pauseRecording()` above never calls this).
        await watcherRunner.stopIntervalWatchers()
        await watcherRunner.run(trigger: .onSessionEnd)

        // `docs/design/08-wiki-export.md` (kikimi.md 11 章 "セッション終了時に自動 export"): best-effort,
        // using whatever `refined.jsonl` already has at this point -- the trailing under-batch-size
        // remainder the `refinementQueue.flush()`/fire-and-forget `drain()` below is about to process
        // may not be reflected yet, but that gap is closed by the re-export run once `drain()`
        // completes (design 37 §5.1 / TC17, below). A failure here must never abort `endMeeting()`'s
        // own confirmation processing (kikimi.md 8.5 章 "録音は絶対に止めない" extends to every
        // `on_session_end` side effect, not just recording itself).
        do {
            try await wikiExporter.export(sessionHandle: sessionHandle)
        } catch {
            logger.error(
                "Wiki export failed for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }

        // `docs/design/03-refinement-batch.md` §7 "会議終了（→ Ended）": `flush()` cuts the trailing
        // remainder, then `drain()` is started **fire-and-forget** (never awaited here) so a slow/
        // backlogged Haiku call never delays `on_session_end` (kikimi.md 8.5 章 "会議終了後に自然に
        // バッチ処理が追いつく"). The queue instance itself is left alive (not nilled out) -- it may
        // still be draining when this window closes, and survives a later `reopenRecording()`.
        //
        // `docs/design/37-transcript-markdown-copy.md` §5.1 (TC17): once `drain()` finishes, re-run
        // the export so the trailing batch that missed the pre-drain export above (and would
        // otherwise be permanently stuck as `*(raw)*`) gets folded in. `WikiExporter.export` is an
        // idempotent overwrite (kikimi.md 4 章), so re-running it is safe. The `Task` only captures
        // `Sendable` values (`WikiExporting`, `SessionHandle`) -- never the view model -- so it keeps
        // running even after this window closes.
        if let queue = refinementQueue {
            await queue.flush()
            // Capture `Sendable` values only (`WikiExporting`, `SessionHandle`, `Logger`) -- never
            // `self` -- so the detached `Task` below outlives this view model without retaining it.
            let exporter = wikiExporter
            let handle = sessionHandle
            let logger = logger
            Task {
                await queue.drain()
                do {
                    try await exporter.export(sessionHandle: handle)
                } catch {
                    logger.error(
                        "Post-drain wiki re-export failed for session \(handle.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }

        finishStoppingCapture()
        meta = await sessionHandle.meta
        recordingButtonState = .ended

        // `docs/design/17-session-window-redesign.md` §4.5 "会議終了完了": always surfaces the 会議
        // tab, and promotes a narrowed-to-transcript-only pane mode back to `.both` so the just
        // rendered final summary/title proposal is actually visible (§2 R3/R4) -- `.summary`/`.both`
        // are left untouched, matching the design table's "そのまま".
        activeTab = .meeting
        if meetingPaneMode == .transcript {
            meetingPaneMode = .both
        }

        // `docs/design/18-recording-window-stow-and-compact.md` §3.4/§5.4/R6: unconditionally reset
        // out of compact mode (covers "コンパクトの復帰") and unconditionally notify the wiring
        // closure (covers "しまってあった場合の再表示") -- the decision of whether the closure should
        // actually reveal the window belongs to whoever wired it (`MeetingWorkspaceWindowController
        // .init`), not to this view model.
        windowMode = .normal
        onMeetingEnded?(sessionId)
    }

    /// Ended -> Recording: the "救済パス" (kikimi.md 4 章 "Ended も可逆"). Same shape as
    /// `resumeRecording()`, via `SessionStore.reopenForRecording(_:)`. A no-op unless
    /// `recordingButtonState == .ended`.
    func reopenRecording() async {
        guard recordingButtonState == .ended else { return }
        guard resolveAudioInputSelectionForRecordingStart() else { return }

        recordingButtonState = .resuming

        do {
            try await sessionStore.reopenForRecording(sessionId)
        } catch {
            handleResumeOrReopenFailure(error, previousState: .ended)
            return
        }

        await runRecordingSegmentStart(previousStateOnFailure: .ended)
    }

    /// Shared continuation for `startRecording()`/`resumeRecording()`/`reopenRecording()` once
    /// `SessionStore` has already opened a new `RecordingSegment` (`beginRecording`/
    /// `resumeRecording`/`reopenForRecording`): builds a fresh `TranscriptPipeline`/`AudioCapture`
    /// pair for that segment (kikimi.md 6 章: STT resets fresh per segment) using its `index`/
    /// `startMsOffset`, prepares/starts them, and on success reloads `meta`, persists
    /// `audioInputSelection` as `appState.lastAudioInput`, and starts the elapsed-time ticker and
    /// the `TranscriptPipeline.liveSegments`/`volatileTranscripts` subscriptions.
    ///
    /// If `TranscriptPipeline.prepare(...)`/`AudioCapture.start()` fails, rolls back via
    /// `SessionStore.cancelRecordingStart(_:revertingTo:)` (never `pauseRecording(_:)`/
    /// `endMeeting(_:)` — no audio has been written yet for this segment) and returns to the
    /// button state `previousStateOnFailure` implies, with a `.recordingStartFailed` banner
    /// (section 6.1 steps 2-5, section 11 failure modes #1/#2/#4).
    private func runRecordingSegmentStart(previousStateOnFailure: SessionState) async {
        let openSegment = await sessionHandle.meta.recordings.last
        let recordingIndex = openSegment?.index ?? 0
        let startMsOffset = openSegment?.startMsOffset ?? 0

        let pipeline = transcriptPipelineFactory(sessionHandle, startMsOffset)
        // `docs/design/10-audio-input-selection.md` section 5.2 / 8章 failure modes #7/#9: wired
        // before `capture.start()` (same ordering requirement as `capture.delegate = pipeline`
        // below) so no mid-recording (or start-time system-only) degradation event is missed.
        // Without this, `AudioCaptureDelegate.didDegrade` events reached only `TranscriptPipeline`
        // (which stops the degraded source's `SttEngine`) and never became visible in the UI.
        pipeline.onDegrade = { [weak self] source, error in
            Task { @MainActor in
                self?.handleAudioCaptureDegraded(source: source, error: error)
            }
        }
        // `docs/design/13-speaker-diarization.md` section 5.1 "入力選択との関係": the coordinator's
        // startup decision is made once per recording segment, here, using *this* segment's resolved
        // `audioInputSelection.system.enabled` -- not the coordinator's own memory of a previous
        // segment. Must happen before `capture.start()` (mirrors `capture.delegate = pipeline`'s own
        // ordering requirement above): `beginSegment` must complete before any `feed(samples:)` call
        // could possibly arrive (`RealtimeDiarizationCoordinator`'s documented lifecycle contract).
        if let coordinator = await diarizationCoordinatorIfEnabled() {
            await coordinator.beginSegment(startMsOffset: startMsOffset, hasSystemAudio: audioInputSelection.system.enabled)
            pipeline.onSystemAudio = { [weak self] samples in
                await self?.feedDiarization(samples: samples)
            }
        }
        do {
            try await pipeline.prepare(downloadProgress: { [weak self] source, progress in
                Task { @MainActor in
                    self?.upsertDownloadingBanner(source: source, progress: progress)
                }
            })
        } catch {
            logger.error(
                "TranscriptPipeline.prepare() failed for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            await rollbackFailedSegmentStart(reason: "録音を開始できませんでした（モデルの準備に失敗しました）", previousState: previousStateOnFailure)
            return
        }
        clearDownloadingBanners()

        let capture = audioCaptureFactory(sessionHandle.directoryURL, audioInputSelection, recordingIndex)
        // Step ④ of TranscriptPipeline's call-order contract (`Kikimi/Stt/TranscriptPipeline.swift`):
        // must be wired before step ③ (`capture.start()` below) so no captured buffer is dropped.
        capture.delegate = pipeline
        do {
            try await capture.start()
        } catch {
            logger.error(
                "AudioCapture.start() failed for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            await rollbackFailedSegmentStart(
                reason: (error as? LocalizedError)?.errorDescription ?? "録音を開始できませんでした",
                previousState: previousStateOnFailure
            )
            return
        }

        audioCapture = capture
        transcriptPipeline = pipeline
        hasStoppedAudioAndTranscript = false

        // Only persisted once `capture.start()` has actually succeeded -- a start failing earlier
        // never overwrites the previous `lastAudioInput`.
        let resolvedSelection = audioInputSelection
        appState.update { $0.lastAudioInput = resolvedSelection }

        // Mandatory meta reload: `startElapsedTimer()` reads `meta.recordings.last`/`meta.durationMs`,
        // and the `meta` loaded before this segment started never reflects the just-opened segment.
        meta = await sessionHandle.meta

        recordingButtonState = .recording(elapsedSeconds: Self.cumulativeElapsedSeconds(for: meta, now: now()))
        startElapsedTimer()
        startLiveSegmentSubscription(pipeline: pipeline)
        startVolatileTranscriptSubscription(pipeline: pipeline)
        // Section 4.1: Recording-scoped lifecycle, same as audioCapture/transcriptPipeline above.
        startSummaryUpdaterIfNeeded()
        // `docs/design/05-watcher-runner.md` §9.3/§9.4: (re)starts every enabled `on_interval`
        // Watcher's loop for this recording segment. `startIntervalWatchers()` itself first clears
        // any previously-started loops, so this is idempotent across start/resume/reopen.
        await watcherRunner.startIntervalWatchers()
        // `docs/design/03-refinement-batch.md` §7 "録音開始（Draft/Paused/Ended → Recording)": creates
        // the queue on the first call (idempotent thereafter -- `refinementQueueIfNeeded()`) and always
        // calls `start()`, which itself is idempotent (clears `stopped`, rescans the backlog, reloads
        // `context.md`).
        await refinementQueueIfNeeded().start()
        // `docs/design/13-speaker-diarization.md` section 5.3 rule 1: keeps "(認識中…)" rows ticking
        // over into "Speaker ?" once the grace period elapses, even with no new turn arriving.
        startDiarizationLabelTicker()
        // `docs/design/24-system-audio-leak-mitigation.md` §5.1: (re)starts this segment's
        // `OutputRouteMonitor` (idempotent, config-gated -- see its own doc comment).
        startOutputRouteMonitorIfNeeded()
    }

    /// Stops `audioCapture`/`transcriptPipeline` exactly once per stop attempt, shared by
    /// `pauseRecording()` and `endMeeting()`. On a retry (state already `.pausing`/`.ending`), this
    /// is a no-op — `hasStoppedAudioAndTranscript` already reflects that they were stopped by the
    /// first attempt.
    /// - Parameter diarizationEndReason: Forwarded to `RealtimeDiarizationCoordinator.endSegment(
    ///   reason:)` (design section 5.1's "区間終了時のドレインと flush") once `transcriptPipeline
    ///   .stopAndDrain()` has returned -- only then is it guaranteed every buffer this segment ever
    ///   forwarded via `onSystemAudio` has actually reached `coordinator.feed(samples:)` (see
    ///   `TranscriptPipeline.onSystemAudio`'s doc comment and `endSegment(reason:)`'s own "Important"
    ///   note about this ordering requirement).
    private func stopCaptureAndPipelineIfNeeded(diarizationEndReason: DiarizationSegmentEndReason) async {
        guard !hasStoppedAudioAndTranscript else { return }
        await audioCapture?.stop()
        await transcriptPipeline?.stopAndDrain()
        await diarizationCoordinator?.endSegment(reason: diarizationEndReason)
        hasStoppedAudioAndTranscript = true
    }

    /// Tears down the subscriptions/references `runRecordingSegmentStart` set up, shared by
    /// `pauseRecording()` and `endMeeting()` once their `SessionStore` call has durably committed.
    private func finishStoppingCapture() {
        stopElapsedTimer()
        stopLiveSegmentSubscription()
        stopVolatileTranscriptSubscription()
        stopDiarizationLabelTicker()
        // `docs/design/24-system-audio-leak-mitigation.md` §5.1: stops polling and clears any
        // shown banner -- Paused/Ended don't need output-route detection.
        stopOutputRouteMonitor()
        audioCapture = nil
        transcriptPipeline = nil
        hasStoppedAudioAndTranscript = false
    }

    // MARK: - Termination (section 9)

    /// `WindowManager.prepareForTermination()`-only entry point: flushes any deferred
    /// `segmentCount`/`refinedCount` writes (`SessionHandle.flush()`, `07-session-store.md` section
    /// 7) without throwing, so a flush failure during app-termination cleanup never aborts the
    /// termination sequence (hence `async`, not `async throws`).
    func flushSessionHandle() async {
        do {
            try await sessionHandle.flush()
        } catch {
            logger.error(
                "flush() failed for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
