import Foundation

// MARK: - RefinementQueue + Backlog (§7)

/// `start()`'s backlog scan: recovers unrefined segments after a crash/restart or a plain
/// pause/resume, restores the `batchId` sequence counter, seeds the in-memory context history, and
/// reloads `context.md`. Split out from `RefinementQueue.swift` purely for `file_length`.
extension RefinementQueue {
    /// One `readTranscriptSegments()`/`readRefinedSegments()` read serves three purposes at once
    /// (§5.1's "バックログ用の読み取りと同じ 1 回で済ませる。追加の全行スキャンはしない"):
    /// 1. The `transcript.jsonl` − `refined.jsonl` id diff becomes the recovered backlog, enqueued
    ///    `start_ms` ascending and reported via one `.queued` event (§7).
    /// 2. The max numeric suffix across every existing `batchId` restores `nextBatchSequence`.
    /// 3. The last `Self.contextHistoryLimit` transcript segments (paired with refined text where
    ///    present) reseed `contextHistory` (§4.2).
    ///
    /// A read failure is logged and this step is skipped entirely for this `start()` call (best
    /// effort, matching kikimi.md 8.5 章 "録音は絶対に止めない" -- a transient disk error here must
    /// never block Recording from starting); `context.md`'s own reload happens independently
    /// afterward and is unaffected by whether this succeeded.
    func performBacklogScan() async {
        do {
            let transcriptSegments = try await sessionHandle.readTranscriptSegments()
            let refinedSegments = try await sessionHandle.readRefinedSegments()
            // §15.2.4's "covered seg id 集合" generalization: a merged unit's non-leading
            // `sourceSegIds` must resolve here too, or `enqueueBacklog` below would wrongly treat an
            // already-refined-but-merged-away raw id as unrefined backlog.
            let refinedById = refinedSegments.indexedBySourceSegId()

            restoreBatchSequence(from: refinedSegments)
            seedContextHistory(transcriptSegments: transcriptSegments, refinedById: refinedById)
            enqueueBacklog(transcriptSegments: transcriptSegments, refinedById: refinedById)
        } catch {
            logger.error("Failed to read transcript/refined segments for the refinement backlog scan: \(String(describing: error), privacy: .public)")
        }

        // §4.3 "start() 時に初回読込": every start() (not just the very first) re-syncs context.md,
        // since it may have been edited during a pause. Read failure already degrades to "" with its
        // own warning inside `SessionHandle.readContext()`. §9: the participant roster is folded in at
        // the same cadence via `loadComposedContext()`.
        cachedContextText = await loadComposedContext()
        batchesSinceContextLoad = 0
        forceContextRefresh = false
    }

    private func restoreBatchSequence(from refinedSegments: [RefinedSegment]) {
        let maxSequence = refinedSegments.compactMap { Self.parseBatchSequence($0.batchId) }.max() ?? 0
        nextBatchSequence = maxSequence + 1
    }

    private func seedContextHistory(transcriptSegments: [TranscriptSegment], refinedById: [String: RefinedSegment]) {
        let sorted = transcriptSegments.sorted { $0.startMs < $1.startMs }
        contextHistory = sorted.suffix(Self.contextHistoryLimit).map { segment in
            RefinementContextSegment(segment: segment, refinedText: refinedById[segment.id]?.refinedText)
        }
    }

    private func enqueueBacklog(transcriptSegments: [TranscriptSegment], refinedById: [String: RefinedSegment]) {
        // `!knownIds.contains($0.id)` alone would never recover an id whose `appendRefinedSegment`
        // call failed (§5.2's I/O-error row keeps failed ids in `knownIds` on purpose, so a live
        // `enqueue(_:)` doesn't re-add them mid-run -- but that also means they'd never be picked up
        // by *this* scan again without the `appendFailedIds` escape hatch below). `appendFailedIds`
        // membership is the one case where "already known" must not block re-enqueueing, matching
        // §5.2's "次回 start() のバックログスキャン... は recovers them" (which is this exact call).
        let backlog = transcriptSegments
            .filter { refinedById[$0.id] == nil && (!knownIds.contains($0.id) || appendFailedIds.contains($0.id)) }
            .sorted { $0.startMs < $1.startMs }
        guard !backlog.isEmpty else { return }

        for segment in backlog {
            knownIds.insert(segment.id)
            appendFailedIds.remove(segment.id)
            pending.append(segment)
        }
        // §4.1: a recovered backlog is just as eligible for the timeout-based flush as a live
        // `enqueue(_:)` -- without this, a backlog smaller than `config.batchSize` would sit in
        // `pending` forever with nothing ever arming a timer for it (`start()`'s own
        // `maybeStartDispatch()` call right after this only helps if `flush()`/batchSize already
        // applies).
        armTimerIfNeeded()
        eventsContinuation.yield(.queued(segmentIds: backlog.map(\.id)))
    }
}
