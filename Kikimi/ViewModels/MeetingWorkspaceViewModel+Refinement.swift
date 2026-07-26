import Foundation

// MARK: - MeetingWorkspaceViewModel + RefinementQueue lifecycle/events (`docs/design/03-refinement
// -batch.md` §3, §6, §7)

/// Split into its own file (alongside `MeetingWorkspaceViewModel.swift`'s other extensions, e.g.
/// `+Summary.swift`/`+Diarization.swift`) to keep that file under the project's `file_length` lint
/// limit. Owns the `RefinementQueue` lifecycle (created once, lazily, the first time a recording
/// segment starts; kept alive across Paused/Ended -- **unlike** `SummaryUpdater`, §7's lifecycle
/// table), the `events` subscription that pushes `.refining`/`.refined`/`.refinedFailed` row-state
/// updates to `transcriptRows`, and the pure `onAppear()` refined-segment backfill merge (§6).
extension MeetingWorkspaceViewModel {
    // MARK: - Lifecycle (§3, §7: one instance per ViewModel, created lazily on first Recording start)

    /// Returns this ViewModel instance's `RefinementQueue`, creating it (via `refinementQueueFactory`)
    /// and starting its `events` subscription the first time this is called -- mirrors
    /// `diarizationCoordinatorIfEnabled()`'s one-instance-per-ViewModel guard
    /// (`MeetingWorkspaceViewModel+Diarization.swift`), except there is no `AppConfig`-gated "disabled"
    /// case here (§7's lifecycle table never calls out an opt-out): every recording segment start
    /// wires this queue. Once created, the same instance is reused for the rest of this ViewModel's
    /// lifetime, spanning every Paused ⇄ Recording cycle (§7: "インスタンスは破棄しない" on pause) -- only a
    /// brand-new `MeetingWorkspaceViewModel` instance (window reopen, crash-recovery reopen) ever gets
    /// a fresh queue. Callers always follow this with `await ....start()` (idempotent: `runRecording
    /// SegmentStart` in `MeetingWorkspaceViewModel.swift` is this method's only call site), so `start()`
    /// itself -- not this method -- is what actually rescans the backlog/reloads `context.md` on every
    /// recording-segment start, including the very first one.
    ///
    /// Not `private`: called from `runRecordingSegmentStart` in `MeetingWorkspaceViewModel.swift`.
    func refinementQueueIfNeeded() -> RefinementQueue {
        if let existing = refinementQueue {
            return existing
        }
        let queue = refinementQueueFactory(sessionHandle)
        refinementQueue = queue
        startRefinementEventsSubscription(queue: queue)
        return queue
    }

    /// Consumes `queue.events` for the rest of this ViewModel instance's lifetime (cancelled only in
    /// `deinit`, same shape as `startDiarizationTurnsSubscription(coordinator:)` -- this queue is never
    /// torn down on Paused the way `summaryEventsTask`/`summaryUpdater` are, §7). Applies each event to
    /// `transcriptRows` per §5.3/§6:
    /// - `.queued`: the named rows become `.refining` (kikimi.md 10 章 "整形待ちは 🔄").
    /// - `.batchCompleted`: each segment's row becomes `.refined(text)` if `refinedText` is non-nil,
    ///   otherwise `.refinedFailed(error)` (falling back to an empty string if `error` is somehow nil
    ///   too -- defensive; `RefinementValidator` always populates `error` alongside a nil
    ///   `refinedText`, §5.1).
    /// - `.disabled`: every currently-`.refining` row reverts to `.raw` (§5.2's fatal-failure row: the
    ///   queue has stopped and discarded its pending/in-flight work, so those rows are no longer
    ///   actually queued for anything).
    private func startRefinementEventsSubscription(queue: RefinementQueue) {
        refinementEventsTask?.cancel()
        refinementEventsTask = Task { [weak self] in
            for await event in queue.events {
                guard let self else { return }
                switch event {
                case .queued(let segmentIds):
                    self.applyRefiningState(toRowIds: segmentIds)
                case .batchCompleted(let segments):
                    await self.applyRefinedResults(segments)
                case .disabled:
                    self.revertRefiningRowsToRaw()
                }
            }
        }
    }

    private func applyRefiningState(toRowIds ids: [String]) {
        for id in ids {
            setTranscriptRowState(id: id, state: .refining)
        }
    }

    private func applyRefinedResults(_ segments: [RefinedSegment]) async {
        for segment in segments {
            await applyRefinedUnit(segment)
        }
    }

    /// Applies one already-durably-appended derived unit (§15.2.6, `RefinementMerge`'s output may
    /// cover more than one raw seg_id): the leader row (`segment.sourceSegIds.first`, == `segment.id`
    /// for the common 1:1 case) becomes `.refined`/`.refinedFailed` with the unit's (possibly merged)
    /// text and adopts the unit's full `endMs` so `toggleSegmentPlayback(_:)`
    /// (`docs/design/15-segment-playback.md`) plays back the whole merged span from a single
    /// recording index's WAV; every subsequent covered id becomes `.mergedInto(leaderId:)` and is
    /// otherwise left untouched (never independently rendered).
    ///
    /// When a merge actually widens the leader row's `endMs` beyond what it was when
    /// `speakerLabels[leaderId]` was last computed, that cached `ResolvedSpeakerLabel` (and its
    /// `attributedSlots`, `MeetingWorkspaceView.swift`'s rename-popup source) still reflects the
    /// narrower pre-merge range until some other diarization trigger (a new turn, a rename, the
    /// grace-period ticker) happens to fire. Calling `recomputeSpeakerLabels()` here -- the same
    /// pattern every other `endMs`/state-affecting trigger already follows (see that method's doc
    /// comment) -- keeps the cache in sync with this widened range immediately instead of leaving it
    /// stale in between.
    private func applyRefinedUnit(_ segment: RefinedSegment) async {
        let leaderId = segment.sourceSegIds.first ?? segment.id
        let state: TranscriptRowState = segment.refinedText.map { .refined($0) } ?? .refinedFailed(segment.error ?? "")
        if let index = transcriptRows.firstIndex(where: { $0.id == leaderId }) {
            transcriptRows[index].state = state
            transcriptRows[index].endMs = segment.endMs
        }
        for coveredId in segment.sourceSegIds.dropFirst() {
            setTranscriptRowState(id: coveredId, state: .mergedInto(leaderId: leaderId))
        }
        await recomputeSpeakerLabels()
    }

    private func revertRefiningRowsToRaw() {
        for index in transcriptRows.indices where transcriptRows[index].state == .refining {
            transcriptRows[index].state = .raw
        }
    }

    private func setTranscriptRowState(id: String, state: TranscriptRowState) {
        guard let index = transcriptRows.firstIndex(where: { $0.id == id }) else { return }
        transcriptRows[index].state = state
    }

    // MARK: - onAppear() backfill merge (§6)

    /// Pure helper for `onAppear()`'s refined-segment backfill (§6/§15.2.6): for every `row` whose
    /// `id` is covered by a `RefinedSegment` (via `sourceSegIds`, §15.2.5's "covered seg id 集合"
    /// generalization -- not just an exact `id` match), the *leader* row (`sourceSegIds.first`)
    /// becomes `.refined(refinedText)`/`.refinedFailed(error)` (same fallback as
    /// `applyRefinedResults(_:)` above) and adopts the unit's full `endMs`; every other covered row
    /// becomes `.mergedInto(leaderId:)`. Rows with no matching refined unit are returned unchanged
    /// (left at whatever `state` the caller already assigned -- `onAppear()`'s transcript backfill
    /// always seeds `.raw`). `static`, not an instance method: independent of any ViewModel state, so
    /// `MeetingWorkspaceViewModelTests` can exercise it directly as a table-driven unit test,
    /// mirroring `nextRecordingButtonState(current:selfSessionId:activeSessionId:)`'s same rationale
    /// in `+RecordingInternals.swift`.
    static func mergeRefinedState(_ refinedSegments: [RefinedSegment], into rows: [TranscriptRowViewModel]) -> [TranscriptRowViewModel] {
        guard !refinedSegments.isEmpty else { return rows }
        let unitById = refinedSegments.indexedBySourceSegId()
        return rows.map { row in
            guard let unit = unitById[row.id] else { return row }
            var updated = row
            let leaderId = unit.sourceSegIds.first ?? unit.id
            if leaderId == row.id {
                updated.state = unit.refinedText.map { .refined($0) } ?? .refinedFailed(unit.error ?? "")
                updated.endMs = unit.endMs
            } else {
                updated.state = .mergedInto(leaderId: leaderId)
            }
            return updated
        }
    }
}
