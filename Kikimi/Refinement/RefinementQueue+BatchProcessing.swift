import Foundation

// MARK: - RefinementQueue + Batch Processing (§4.2/§5)

/// Prompt assembly, the LLM call (with §5.2's single-retry/fatal-failure handling), and the
/// durable-append + event-emission step for one already-cut batch. Split out from
/// `RefinementQueue.swift` purely for `file_length` (see that file's top-of-type doc comment).
extension RefinementQueue {
    /// Processes one batch end to end: builds the system/user prompt (§4.2), calls the LLM with
    /// §5.2's retry policy, validates the response (`RefinementValidator`), and appends the result
    /// (`appendAndEmit(batch:segments:warnings:)`). Always consumes exactly one `nextBatchSequence`
    /// value, even on total failure -- a batch's `batchId` never changes between its first attempt
    /// and its retry (§5.1: "batchId: 同一 Haiku 呼び出しで整形された仲間の識別").
    func processBatch(_ batch: [TranscriptSegment]) async {
        let (systemPrompt, wasClamped) = await currentSystemPrompt()
        if wasClamped {
            logger.warning("context.md exceeds the 32KB limit embedded in the refinement system prompt; using the first 32KB (kikimi.md 7 章).")
        }
        let contextSegments = Array(contextHistory.suffix(config.contextSegments))
        let userPrompt = RefinementPromptBuilder.buildUserPrompt(contextSegments: contextSegments, batchSegments: batch)
        let batchId = Self.formatBatchId(nextBatchSequence)
        nextBatchSequence += 1

        let request = LLMRequest(
            system: systemPrompt,
            user: userPrompt,
            schema: RefinementJSONSchema.schemaJSON,
            resolved: resolvedModel,
            stubKey: "refinement"
        )

        switch await callLLM(request) {
        case .success(let result):
            let effectiveModel = result.respondedModel ?? resolvedModel.model
            let (segments, warnings) = RefinementValidator.validate(batch: batch, response: result.value, now: now(), model: effectiveModel, batchId: batchId)
            logLeakDedupCandidates(batch: batch, contextSegments: contextSegments, validated: segments)
            let finalSegments = await mergeIfPossible(batch: batch, validated: segments, response: result.value)
            await appendAndEmit(batch: batch, segments: finalSegments, warnings: warnings)
        case .failure(let firstError):
            await handleFailure(firstError, request: request, batch: batch, batchId: batchId, contextSegments: contextSegments)
        }
    }

    // MARK: - §4.6 leak-dedup observability

    /// `docs/design/24-system-audio-leak-mitigation.md` §4.6: emits a `debug` log line for each
    /// `RefinedSegment` in `validated` that is `speaker == .mic && refinedText == ""`, estimating
    /// (heuristically, not ground truth) whether that empty-out was the §4.2 leak-dedup rule firing
    /// versus ordinary filler removal, by checking whether the LLM call that produced it could see any
    /// `(system)` segment -- i.e. one present in `contextSegments` (the "直前の文脈" window passed to
    /// `buildUserPrompt`) or in `batch` itself (the "今回整形する対象" set). Must be called with
    /// `validated` -- the 1:1-with-`batch` output of `RefinementValidator.validate` -- *before*
    /// `mergeIfPossible` folds it into merged units (§15.2.3), so no candidate is lost to merging.
    /// Does not change `refined.jsonl`'s format or `RefinementResponse`'s schema; debug-only signal
    /// for measuring leak-dedup effectiveness during Phase 4 field testing.
    ///
    /// Message construction itself is factored into the pure, directly-testable
    /// `leakDedupLogMessages(batch:contextSegments:validated:)` below (an actor's `static` members
    /// are not actor-isolated, so tests can call it without an instance); this method's only job is
    /// forwarding those strings to `logger.debug`.
    private func logLeakDedupCandidates(
        batch: [TranscriptSegment],
        contextSegments: [RefinementContextSegment],
        validated: [RefinedSegment]
    ) {
        for message in Self.leakDedupLogMessages(batch: batch, contextSegments: contextSegments, validated: validated) {
            logger.debug("\(message, privacy: .public)")
        }
    }

    /// Pure computation behind `logLeakDedupCandidates`: one message per `validated` entry that is
    /// `speaker == .mic && refinedText == ""`, `validated` order preserved. See
    /// `logLeakDedupCandidates`'s doc comment for the heuristic this implements.
    static func leakDedupLogMessages(
        batch: [TranscriptSegment],
        contextSegments: [RefinementContextSegment],
        validated: [RefinedSegment]
    ) -> [String] {
        let visibleSystemIds = (contextSegments.map(\.segment) + batch)
            .filter { $0.speaker == .system }
            .sorted { $0.startMs < $1.startMs }
            .map(\.id)

        return validated
            .filter { $0.speaker == .mic && $0.refinedText?.isEmpty == true }
            .map { segment in
                if visibleSystemIds.isEmpty {
                    return "refinement leak-dedup candidate: \(segment.id) (mic) refined to empty; no system segment visible to this batch (likely filler removal)"
                } else {
                    let idList = visibleSystemIds.joined(separator: ", ")
                    return "refinement leak-dedup candidate: \(segment.id) (mic) refined to empty; nearby system segment(s) in this batch's LLM context: \(idList)"
                }
            }
    }

    // MARK: - §15.2.3/§15.2.4 merge + coverage fallback

    /// Applies `RefinementMerge`'s deterministic merge gate to `validated` (§15.2.3), then verifies
    /// the coverage invariant, falling back to `validated` unmerged (1:1) for this batch only if it's
    /// violated (§15.2.4). Not called from `handleFailure`'s "both LLM attempts failed" branch --
    /// there is no `RefinementResponse` to pull `joins_next` hints from there, and every one of that
    /// branch's segments is already `refinedText: nil` (never a legitimate merge candidate per the
    /// gate's own "non-empty, non-nil `refinedText`" guard anyway).
    private func mergeIfPossible(batch: [TranscriptSegment], validated: [RefinedSegment], response: RefinementResponse) async -> [RefinedSegment] {
        let joinsNext = Dictionary(response.segments.map { ($0.id, $0.joinsNext) }, uniquingKeysWith: { _, last in last })
        let meta = await sessionHandle.meta
        let merged = RefinementMerge.merge(
            validated,
            joinsNext: joinsNext,
            recordingIndexOf: { meta.recordingIndex(atStartMs: $0) },
            logger: logger
        )
        return RefinementMerge.applyCoverageFallback(
            original: validated,
            merged: merged,
            batchIds: batch.map(\.id),
            logger: logger
        )
    }

    /// §5.2's table: a fatal error (`cliNotFound`/`notAuthenticated`) stops the queue immediately,
    /// with no retry ("リトライ無意味"). Any other error waits `retryDelay` and retries the *same*
    /// request once; if the retry also fails fatally the queue still stops, otherwise (whether the
    /// retry succeeded or failed transiently again) that outcome is final for this batch.
    private func handleFailure(
        _ firstError: LLMClientError,
        request: LLMRequest,
        batch: [TranscriptSegment],
        batchId: String,
        contextSegments: [RefinementContextSegment]
    ) async {
        if Self.isFatal(firstError) {
            await handleFatalFailure(firstError, discarding: batch)
            return
        }

        try? await Task.sleep(for: retryDelay)
        switch await callLLM(request) {
        case .success(let result):
            let effectiveModel = result.respondedModel ?? resolvedModel.model
            let (segments, warnings) = RefinementValidator.validate(batch: batch, response: result.value, now: now(), model: effectiveModel, batchId: batchId)
            logLeakDedupCandidates(batch: batch, contextSegments: contextSegments, validated: segments)
            let finalSegments = await mergeIfPossible(batch: batch, validated: segments, response: result.value)
            await appendAndEmit(batch: batch, segments: finalSegments, warnings: warnings)
        case .failure(let retryError):
            if Self.isFatal(retryError) {
                await handleFatalFailure(retryError, discarding: batch)
                return
            }
            // §5.2: both attempts failed transiently -- append every segment in the batch as
            // `refinedText: nil` with the *actual* retry error description (not a fixed string), so
            // refined.jsonl stays traceable, and move on to the next batch.
            let segments = batch.map { segment in
                RefinedSegment(
                    id: segment.id,
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    speaker: segment.speaker,
                    rawText: segment.text,
                    refinedText: nil,
                    error: retryError.errorDescription,
                    refinedAt: now(),
                    model: resolvedModel.model,
                    batchId: batchId
                )
            }
            await appendAndEmit(batch: batch, segments: segments, warnings: [])
        }
    }

    /// Returns the full `LLMResult` (not just `.value`) on success so callers can read
    /// `.respondedModel` -- the model that actually answered, when the backend reports one -- and stamp
    /// `refined.jsonl`'s `model` field with it instead of the configured `config.model`
    /// (`docs/design/16-llm-usage-stats.md` section 2; see `UsageRecordingLLM.recordUsage`'s doc
    /// comment for why `config.model`/`request.model` alone can misreport an Azure legacy deployment).
    private func callLLM(_ request: LLMRequest) async -> Result<LLMResult<RefinementResponse>, LLMClientError> {
        do {
            let result: LLMResult<RefinementResponse> = try await llm.complete(request)
            return .success(result)
        } catch let error as LLMClientError {
            return .failure(error)
        } catch {
            return .failure(.processFailed(exitCode: -1, stderr: String(describing: error)))
        }
    }

    /// `.missingAPIKey` (`docs/design/14-llm-provider.md` section 5) joins `cliNotFound`/
    /// `notAuthenticated` as fatal: like those, it is a configuration problem retrying cannot fix.
    /// `.unknownProvider` (`docs/design/44-llm-model-config.md` §5.2) joins the same bucket for the
    /// same reason -- a provider name the registry cannot construct a backend for never becomes
    /// constructible by retrying. `.httpFailed`/`.networkFailed` are treated as transient (same bucket
    /// as `processFailed`/`timedOut`) since a single bad HTTP call or network blip doesn't imply the
    /// endpoint is permanently unusable.
    private static func isFatal(_ error: LLMClientError) -> Bool {
        switch error {
        case .cliNotFound, .notAuthenticated, .missingAPIKey, .unknownProvider:
            return true
        case .processFailed, .timedOut, .invalidJSON, .missingStructuredOutput, .decodeFailed, .httpFailed, .networkFailed:
            return false
        }
    }

    /// §5.2's `cliNotFound`/`notAuthenticated` row: stop the queue, discard `batch` plus everything
    /// still in `pending` (removing their ids from `knownIds` so the next `start()`'s backlog scan
    /// recovers them, §3.2), and emit `.disabled`. Nothing is appended to `refined.jsonl`.
    private func handleFatalFailure(_ error: LLMClientError, discarding batch: [TranscriptSegment]) async {
        logger.warning("RefinementQueue stopping after a fatal LLM failure: \(error.errorDescription ?? String(describing: error), privacy: .public)")
        stopped = true
        for segment in batch {
            knownIds.remove(segment.id)
            appendFailedIds.remove(segment.id)
        }
        for segment in pending {
            knownIds.remove(segment.id)
            appendFailedIds.remove(segment.id)
        }
        pending.removeAll()
        forceCutFlag = false
        timerTask?.cancel()
        timerTask = nil
        eventsContinuation.yield(.disabled(reason: error.errorDescription ?? String(describing: error)))
    }

    // MARK: - §4.3 context.md cache

    /// Returns this batch's system prompt, reloading `context.md` first if this is the very first
    /// batch (`cachedContextText == nil`), `refreshContextNow()` was called since the last reload,
    /// or `config.contextRefreshBatches` batches have gone by since the last reload (§4.3). Bumps
    /// `batchesSinceContextLoad` unconditionally afterward, so a fresh reload counts as batch 1 of
    /// the next window.
    private func currentSystemPrompt() async -> (prompt: String, wasClamped: Bool) {
        let shouldReload = cachedContextText == nil || forceContextRefresh || batchesSinceContextLoad >= config.contextRefreshBatches
        if shouldReload {
            // §9: `loadComposedContext()` folds the participant roster's "【参加者】" block in at the
            // same reload cadence as `context.md` itself.
            cachedContextText = await loadComposedContext()
            batchesSinceContextLoad = 0
            forceContextRefresh = false
        }
        batchesSinceContextLoad += 1
        // `docs/design/28-glossary.md` §3: rendered fresh on every batch, not gated by the
        // context-reload cadence above -- `glossaryProvider()`/`glossaryCategoriesProvider()` return an
        // in-memory snapshot already (see their doc comments), so there is no I/O to throttle, and their
        // output is stable for the lifetime of a production queue anyway (re-rendering it doesn't change
        // cache-hit behavior). `glossaryHeaderProvider()` and `ruleBodyProvider()` below are the same
        // shape: called fresh every batch, but each always returns the same session-start-snapshotted
        // value for this queue's lifetime (`docs/design/42-prompt-overrides.md` §4.2/§4.3 -- see
        // `RefinementQueue.ruleBodyProvider`'s doc comment for why the snapshotting itself happens at
        // the caller, not here).
        let glossaryBlock = GlossaryRenderer.render(
            entries: glossaryProvider(),
            categories: glossaryCategoriesProvider(),
            header: glossaryHeaderProvider()
        )
        return RefinementPromptBuilder.buildSystemPrompt(
            ruleBody: ruleBodyProvider(),
            context: cachedContextText ?? "",
            glossaryBlock: glossaryBlock,
            dedupSystemLeakSegments: config.dedupSystemLeakSegments
        )
    }

    // MARK: - Durable append + events (§5.1/§5.3)

    /// Appends every segment in `segments` to `refined.jsonl` (§5.1: always `batch.count` of them,
    /// success or failure alike). Per §5.2's I/O-error row: if *any* append throws, this batch gets
    /// no `.batchCompleted` event and its context history isn't updated -- the affected ids simply
    /// stay in `knownIds` (never removed, unlike the fatal-failure path) so they are neither
    /// double-refined nor immediately retried by this instance; the next `start()`'s backlog scan is
    /// what recovers them, via `appendFailedIds` (`RefinementQueue+Backlog.swift`'s `enqueueBacklog`
    /// treats that set as an exception to the normal `knownIds` gate -- see its doc comment).
    private func appendAndEmit(batch: [TranscriptSegment], segments: [RefinedSegment], warnings: [String]) async {
        for warning in warnings {
            logger.warning("Refinement response validation warning: \(warning, privacy: .public)")
        }

        var appendFailed = false
        for segment in segments {
            do {
                try await sessionHandle.appendRefinedSegment(segment)
                // §15.2.1: a merged unit's `sourceSegIds` can include an id from an *earlier* batch's
                // failed append attempt (rare, but not structurally impossible) -- clear every raw id
                // this unit now durably covers, not just its own leading `id`.
                for sourceId in segment.sourceSegIds {
                    appendFailedIds.remove(sourceId)
                }
            } catch {
                logger.error("Failed to append refined segment \(segment.id, privacy: .public) to refined.jsonl: \(String(describing: error), privacy: .public)")
                appendFailed = true
                for sourceId in segment.sourceSegIds {
                    appendFailedIds.insert(sourceId)
                }
            }
        }
        guard !appendFailed else { return }

        updateContextHistory(batch: batch, refinedSegments: segments)
        eventsContinuation.yield(.batchCompleted(segments))
    }

    /// Folds this batch's segments (paired with whatever refined text they ended up with, `nil` on
    /// failure) into `contextHistory`, `start_ms`-ascending, then trims to the last
    /// `Self.contextHistoryLimit` (§4.2). `refinedSegments` may be merged (fewer elements than
    /// `batch`, §15.2.1) -- `indexedBySourceSegId()` still resolves every raw `batch` segment
    /// (including a merged unit's non-leading covered ones) to its owning unit's `refinedText`,
    /// rather than only the leading id, so a covered segment's own context-history entry correctly
    /// shows as already-refined instead of falling back to "not yet refined".
    private func updateContextHistory(batch: [TranscriptSegment], refinedSegments: [RefinedSegment]) {
        let unitById = refinedSegments.indexedBySourceSegId()
        let additions = batch
            .sorted { $0.startMs < $1.startMs }
            .map { segment in
                RefinementContextSegment(segment: segment, refinedText: unitById[segment.id]?.refinedText)
            }
        contextHistory.append(contentsOf: additions)
        if contextHistory.count > Self.contextHistoryLimit {
            contextHistory.removeFirst(contextHistory.count - Self.contextHistoryLimit)
        }
    }

    // MARK: - Batch id formatting (§5.1)

    static func formatBatchId(_ sequence: Int) -> String {
        "batch_" + String(format: "%05d", sequence)
    }

    /// Parses a `"batch_" + digits` id back into its sequence number; `nil` for anything else
    /// (hand-edited/corrupt rows are simply excluded from the max when `start()` restores
    /// `nextBatchSequence`).
    static func parseBatchSequence(_ batchId: String) -> Int? {
        guard batchId.hasPrefix("batch_") else { return nil }
        return Int(batchId.dropFirst("batch_".count))
    }
}
