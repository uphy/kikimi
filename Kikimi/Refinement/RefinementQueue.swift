import Foundation
import OSLog

// MARK: - RefinementEvent

/// One push over `RefinementQueue.events` (`docs/design/03-refinement-batch.md` §5.3). The
/// `@MainActor` `MeetingWorkspaceViewModel` subscribes with `for await` and updates
/// `transcriptRows` accordingly (§6).
enum RefinementEvent: Sendable {
    /// `segmentIds` were accepted into `pending` (a live `enqueue(_:)` call, or the backlog scan
    /// `start()` performs -- §5.3's "再オープン直後の行が `.raw` のまま「整形待ち」に見えない、を防ぐ"). The
    /// ViewModel sets the matching rows to `.refining`.
    case queued(segmentIds: [String])
    /// One batch's worth of durably-appended `RefinedSegment`s (§5.1). The ViewModel sets each
    /// matching row to `.refined`/`.refinedFailed` depending on `refinedText`.
    case batchCompleted([RefinedSegment])
    /// The queue has stopped itself after a fatal LLM failure (§5.2's `cliNotFound`/
    /// `notAuthenticated` row). The ViewModel resets any `.refining` rows back to `.raw`.
    case disabled(reason: String)
}

// MARK: - RefinementQueue

/// Session-scoped actor batching confirmed transcript segments into Haiku refinement calls and
/// appending the results to `refined.jsonl` (`docs/design/03-refinement-batch.md`, the single
/// source of truth for every design decision below). Owned by `MeetingWorkspaceViewModel` for the
/// lifetime of the ViewModel (§3, "`RealtimeDiarizationCoordinator` と同型の... ガード付き遅延生成"), not
/// torn down on Paused (unlike `SummaryUpdater` -- §7's lifecycle table: the in-memory context
/// history and pending queue must survive a pause/resume).
///
/// Split across `RefinementQueue.swift` (this file: stored state, public API, dispatch/timer core),
/// `RefinementQueue+BatchProcessing.swift` (prompt assembly, the LLM call + retry/fatal-failure
/// handling, and durable-append), and `RefinementQueue+Backlog.swift` (`start()`'s backlog scan +
/// batch-sequence/context-history recovery) -- purely to stay under `file_length`, matching how
/// `SummaryUpdater`/`+Regeneration`/`+ParticipantsMerge` are split.
actor RefinementQueue {
    let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "RefinementQueue")

    let sessionHandle: SessionHandle
    let llm: LLMCompleting
    let config: RefinementConfig
    let now: @Sendable () -> Date
    /// Resolves `sessionHandle.readParticipants()`'s ids to display names for the §9 "【参加者】" block
    /// injected into every `context.md` reload (`docs/design/22-participant-hints.md` §9). Defaults to
    /// `.shared`, mirroring `RealtimeDiarizationCoordinator`'s same injection point
    /// (`Kikimi/Diarization/RealtimeDiarizationCoordinator.swift`).
    let voiceprintStore: VoiceprintStore
    /// Delay before the single retry attempt for a transient LLM failure (§5.2). Not part of the
    /// design's `init(sessionHandle:llm:config:now:)` signature (kikimi.md 7 章 doesn't call this
    /// out as configurable), but every call site keeps the design's default (`.seconds(2)`) and
    /// only unit tests override it, so batches with an injected failing `FakeLLM` don't have to
    /// burn 2 real seconds each (task instructions: "must be injectable... to keep timing
    /// deterministic").
    let retryDelay: Duration
    /// `docs/design/28-glossary.md` §3: the top-level `glossary` config section, injected as its own
    /// system-prompt block by `RefinementPromptBuilder.buildSystemPrompt(context:glossaryBlock:
    /// dedupSystemLeakSegments:)`. A closure (mirroring `now`'s DI shape) purely so tests can inject a
    /// fake list without touching `AppConfig.shared` -- unlike `now: Date.init`, this is **not** meant
    /// to be called with a closure that reads `AppConfig.shared` live from this actor's own isolation
    /// context: `AppConfig` is a plain `ObservableObject` class, `@MainActor` by convention but not
    /// itself `Sendable` (see `WikiExporter`'s doc comment for the same constraint), so touching it
    /// from this actor's background executor would be a data race. The default below is therefore a
    /// fixed empty list, not a live read; `defaultRefinementQueueFactory`
    /// (`MeetingWorkspaceViewModel+Factories.swift`) snapshots `AppConfig.shared.data.glossary` once on
    /// the main actor and passes `{ snapshot }` instead, the same "capture a value, not a live
    /// reference" pattern already used for `config: RefinementConfig` itself.
    let glossaryProvider: @Sendable () -> [GlossaryEntry]
    /// The `glossary_categories` half of the same block (`docs/design/28-glossary.md` §1.2), passed
    /// alongside `glossaryProvider()` to `GlossaryRenderer.render(entries:categories:)`. Same DI shape
    /// and, crucially, the same constraint as `glossaryProvider` above: the default is a fixed empty
    /// list rather than a live `AppConfig.shared` read, for exactly the data-race reason spelled out
    /// there. `defaultRefinementQueueFactory` snapshots the real value once on the main actor.
    let glossaryCategoriesProvider: @Sendable () -> [GlossaryCategory]

    // MARK: - §3.2 id dedup invariant

    /// "refined.jsonl に追記済みの id" ∪ "pending 中の id" ∪ "in-flight バッチ中の id" (§3.2). Never holds
    /// the same id twice by construction (`Set`); `enqueue(_:)` and the backlog scan both consult it
    /// before adding anything to `pending`.
    var knownIds: Set<String> = []

    /// ids kept in `knownIds` specifically because their `appendRefinedSegment` call failed (§5.2's
    /// I/O-error row: "id は knownIds に残し... 次回 start() のバックログスキャン... は recovers them").
    /// `enqueueBacklog(...)` (`RefinementQueue+Backlog.swift`) treats membership here as an exception
    /// to the normal "already in knownIds -> skip" rule, so these ids -- unlike ids that are merely
    /// still `pending`/in-flight from a live `enqueue(_:)` -- *are* re-enqueued by the next `start()`.
    /// Cleared the moment a later attempt actually appends the id successfully.
    var appendFailedIds: Set<String> = []

    /// FIFO-ish buffer of segments accepted but not yet cut into a batch. Order is "insertion order"
    /// (backlog-scan segments inserted `start_ms` ascending, then live `enqueue(_:)` appends) --
    /// `RefinementPromptBuilder.buildUserPrompt` sorts by `start_ms` again itself, so this buffer's
    /// order only needs to be "roughly chronological" for batches to be cut in a sensible sequence.
    var pending: [TranscriptSegment] = []

    // MARK: - §3.1 single-worker serialization

    /// `true` while a batch-processing `Task` is running (or about to start its first iteration).
    /// The one gate `enqueue(_:)`/`flush()`/`start()`'s backlog scan all go through instead of ever
    /// processing a batch themselves (§3.1) -- checked-and-set synchronously (no `await` in
    /// between), so actor isolation makes "at most one in-flight batch" structural, not advisory.
    var isDispatching = false
    /// `true` once §5.2's `cliNotFound`/`notAuthenticated` row has fired. `enqueue(_:)` stops
    /// accepting new segments and the dispatch loop stops taking batches while this is set; the
    /// next `start()` clears it (§7 "次の `start()` で停止フラグを解除して再挑戦する").
    var stopped = false
    /// Set by `flush()` or a fired batch-timeout timer: "cut whatever is in `pending` right now as
    /// one batch, regardless of `config.batchSize`" (§4.1's "件数に関わらずバッチ化対象にする"/timeout row).
    var forceCutFlag = false
    /// One-shot timer armed when `pending` starts accumulating and cancelled the moment any batch
    /// is cut (mirrors `SummaryUpdater.armTimeTrigger`'s "goes 0->1 arm / trigger cancel" shape,
    /// §4.1 "タイマーは... バッチ確定で解除").
    var timerTask: Task<Void, Never>?
    /// Incremented only when `armTimerIfNeeded()` actually starts a *new* timer (not when it's a
    /// no-op because one is already armed). Exists purely so unit tests can assert the "goes 0->1,
    /// not renewed by later arrivals" invariant deterministically (via a counter) instead of via
    /// wall-clock bounds, which are flaky under a heavily parallel `swift test` run.
    var timerArmCount = 0

    /// `drain()` callers parked here; resumed once `pending.isEmpty && !isDispatching` (§3.1's
    /// "pending が空 **かつ** in-flight バッチなし" -- never on pending-empty alone, mirroring
    /// `SttEngine.waitUntilDrained()`'s `drainWaiters` shape).
    var drainWaiters: [CheckedContinuation<Void, Never>] = []

    /// `start()` callers parked here while `isDispatching` is `true`, resumed the moment it flips back
    /// to `false`. Unlike `drainWaiters`, this does **not** wait for `pending` to empty out too --
    /// segments legitimately sitting in `pending` (not yet cut into a batch) are harmless to race
    /// against a backlog scan (the existing `knownIds` check already prevents re-adding them; see the
    /// "a live enqueue racing the backlog scan for the same id does not duplicate it" test). Only an
    /// **in-flight** batch is unsafe to race: `processBatch(_:)` bumps `nextBatchSequence` and appends
    /// to `refined.jsonl` (consumed by `restoreBatchSequence`/`seedContextHistory`) only *after*
    /// suspending on the LLM call, so a concurrent backlog scan could read stale disk state and roll
    /// `nextBatchSequence` back down / seed `contextHistory` from data that's about to be overwritten
    /// -- two unrelated batches could then durably share one `batchId`. `start()` waits on this before
    /// `performBacklogScan()` to make that race structurally impossible.
    var dispatchIdleWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - §4.2 in-memory context history

    /// Last up to 50 confirmed segments (paired with their refined text, if any), used to build each
    /// batch's "直前の文脈" (§4.2). Seeded from disk by `start()`'s backlog scan and kept current by
    /// every successfully-appended batch afterward (`RefinementQueue+BatchProcessing.swift`).
    var contextHistory: [RefinementContextSegment] = []
    static let contextHistoryLimit = 50

    // MARK: - §4.3 context.md cache

    /// The last-loaded `context.md` contents, embedded verbatim into every batch's system prompt
    /// until the next refresh (§4.3). `nil` only before the very first `start()` call completes.
    var cachedContextText: String?
    /// Batches processed since `cachedContextText` was last (re)loaded; reload once this reaches
    /// `config.contextRefreshBatches` (§4.3).
    var batchesSinceContextLoad = 0
    /// Set by `refreshContextNow()`; forces a reload before the next batch regardless of
    /// `batchesSinceContextLoad` (§4.3 "今すぐ反映").
    var forceContextRefresh = false

    // MARK: - §5.1 batch sequencing

    /// Next `"batch_" + 5-digit sequence` to assign. Restored by `start()`'s backlog scan from the
    /// max existing `batchId` in `refined.jsonl` (§5.1); defaults to `1` for a session with no
    /// refined rows yet.
    var nextBatchSequence = 1

    /// - Parameters:
    ///   - sessionHandle: The session this queue reads/writes through (§10: only
    ///     `appendRefinedSegment`/`readRefinedSegments`/`readTranscriptSegments`/`readContext`).
    ///   - llm: The narrow `LLMCompleting` seam, not the concrete `LLMClient`, so unit tests inject
    ///     a fake directly (mirrors `SummaryUpdater`'s same choice).
    ///   - config: Batch-size/timeout/context thresholds and the refinement model (§8).
    ///   - now: Injectable wall clock stamped onto every `RefinedSegment.refinedAt` (§5.1), so tests
    ///     don't depend on real time.
    ///   - retryDelay: See the stored property's doc comment above.
    ///   - voiceprintStore: See the stored property's doc comment above.
    ///   - glossaryProvider: See the stored property's doc comment above.
    ///   - glossaryCategoriesProvider: See the stored property's doc comment above.
    init(
        sessionHandle: SessionHandle,
        llm: LLMCompleting,
        config: RefinementConfig,
        now: @escaping @Sendable () -> Date = Date.init,
        retryDelay: Duration = .seconds(2),
        voiceprintStore: VoiceprintStore = .shared,
        glossaryProvider: @escaping @Sendable () -> [GlossaryEntry] = { [] },
        glossaryCategoriesProvider: @escaping @Sendable () -> [GlossaryCategory] = { [] }
    ) {
        self.sessionHandle = sessionHandle
        self.llm = llm
        self.config = config
        self.now = now
        self.retryDelay = retryDelay
        self.voiceprintStore = voiceprintStore
        self.glossaryProvider = glossaryProvider
        self.glossaryCategoriesProvider = glossaryCategoriesProvider
        (eventsStream, eventsContinuation) = AsyncStream.makeStream()
    }

    // MARK: - events (§5.3)

    private let eventsStream: AsyncStream<RefinementEvent>
    let eventsContinuation: AsyncStream<RefinementEvent>.Continuation

    /// `nonisolated` because this only vends an immutable, `Sendable` `AsyncStream` value set once
    /// at `init` -- safe to read from any isolation context (mirrors `SummaryUpdater.events`).
    nonisolated var events: AsyncStream<RefinementEvent> {
        eventsStream
    }

    // MARK: - Public API (§3)

    /// Idempotent start/resume (§7): called once per recording segment (Draft/Paused/Ended ->
    /// Recording). Clears `stopped` (§5.2 recovery), waits for any still-in-flight batch from a prior
    /// active period to finish (see `dispatchIdleWaiters`'s doc comment -- §7 explicitly keeps this
    /// instance's worker running through Paused, e.g. `pauseRecording()`'s fire-and-forget `flush()`,
    /// so a quick resume can otherwise race an in-flight batch), rescans the transcript/refined
    /// backlog (`RefinementQueue+Backlog.swift`), and reloads `context.md`. Safe to call repeatedly --
    /// every step here is itself idempotent (guarded by `knownIds`, or simply re-deriving the same disk
    /// state again).
    func start() async {
        stopped = false
        await waitUntilDispatchIdle()
        await performBacklogScan()
        maybeStartDispatch()
    }

    /// Accepts one confirmed segment (§3.3's call site: `TranscriptPipeline`'s live segment stream,
    /// already durably appended to `transcript.jsonl`). Ignored while `stopped` (§5.2) or if `id` is
    /// already known (§3.2) -- both silent no-ops, matching the design's "既に pending / in-flight /
    /// 整形済みの id は無視する".
    func enqueue(_ segment: TranscriptSegment) {
        guard !stopped else { return }
        guard !knownIds.contains(segment.id) else { return }
        knownIds.insert(segment.id)
        pending.append(segment)
        eventsContinuation.yield(.queued(segmentIds: [segment.id]))
        armTimerIfNeeded()
        maybeStartDispatch()
    }

    /// Marks the current `pending` buffer as batch-able immediately, regardless of `config.batchSize`
    /// (§4.1's Paused/Ended flush). A no-op if `pending` is already empty -- there's nothing to
    /// flush, and setting `forceCutFlag` anyway would incorrectly force-cut the *next* segment to
    /// arrive as its own single-item batch.
    func flush() {
        guard !pending.isEmpty else { return }
        forceCutFlag = true
        maybeStartDispatch()
    }

    /// Waits until `pending` is empty **and** no batch is in flight (§3.1) -- never satisfied by
    /// pending-empty alone while a batch is still being refined/appended.
    func drain() async {
        guard !(pending.isEmpty && !isDispatching) else { return }
        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
        }
    }

    /// Forces the next batch's system prompt to reload `context.md`, regardless of
    /// `batchesSinceContextLoad` (§4.3's "今すぐ反映" button).
    func refreshContextNow() {
        forceContextRefresh = true
    }

    // MARK: - §9 participant context injection (docs/design/22-participant-hints.md §9)

    /// Reads `context.md` and, if the session has a non-empty participant roster, appends the "【参加者】"
    /// block resolved from `voiceprintStore` (design §9). Called from every point `cachedContextText`
    /// is (re)loaded -- `RefinementQueue+Backlog.swift`'s `performBacklogScan()` and
    /// `RefinementQueue+BatchProcessing.swift`'s `currentSystemPrompt()` -- so participant injection
    /// follows the exact same reload cadence as `context.md` itself (§9: "反映粒度は既存の
    /// `context_refresh_batches` に従う... 名簿変更のたびに `refreshContextNow()` は呼ばない"). Not `private`:
    /// both of those extension files (different files, for `file_length`) call this.
    func loadComposedContext() async -> String {
        let rawContext = await sessionHandle.readContext()
        let participants = await sessionHandle.readParticipants()
        guard !participants.participantIds.isEmpty else { return rawContext }
        let speakers = await voiceprintStore.listSpeakers()
        let names = ParticipantContextComposer.resolveParticipantNames(participantIds: participants.participantIds, in: speakers)
        return ParticipantContextComposer.compose(context: rawContext, participantNames: names)
    }

    // MARK: - Dispatch/timer core (§3.1/§4.1)

    /// Starts the single batch-processing `Task` for this "active period" if one isn't already
    /// running and a batch is actually ready to cut. Not a single perpetual loop `Task` kept alive
    /// for the queue's entire lifetime -- instead a fresh `Task` is spun up each time `pending`
    /// crosses a flush threshold and it runs `runDispatchLoop()` until there is nothing left ready,
    /// then exits. This keeps the *serialization* invariant (`isDispatching` is only ever flipped
    /// `true`/`false` from synchronous, non-suspending actor-isolated code, so at most one such
    /// `Task` can ever be alive) without pinning the actor alive forever via an infinite `while true`
    /// loop that never lets its captured `self` go.
    private func maybeStartDispatch() {
        guard !isDispatching, !stopped, readyToCutBatch() else { return }
        isDispatching = true
        Task { [weak self] in
            await self?.runDispatchLoop()
        }
    }

    private func readyToCutBatch() -> Bool {
        !pending.isEmpty && (pending.count >= config.batchSize || forceCutFlag)
    }

    private func runDispatchLoop() async {
        while !stopped, let batch = takeNextBatch() {
            await processBatch(batch)
        }
        isDispatching = false
        resumeDispatchIdleWaiters()
        resumeDrainWaitersIfIdle()
    }

    /// Suspends until `isDispatching` is `false` -- a no-op if no batch is currently in flight. See
    /// `dispatchIdleWaiters`'s doc comment for why `start()` needs this and why it deliberately does
    /// *not* also wait for `pending` to be empty (unlike `drain()`).
    private func waitUntilDispatchIdle() async {
        guard isDispatching else { return }
        await withCheckedContinuation { continuation in
            dispatchIdleWaiters.append(continuation)
        }
    }

    /// Resumes every parked `waitUntilDispatchIdle()` caller. Called only from the end of
    /// `runDispatchLoop()`, right after `isDispatching` has been flipped back to `false`.
    private func resumeDispatchIdleWaiters() {
        guard !dispatchIdleWaiters.isEmpty else { return }
        let waiters = dispatchIdleWaiters
        dispatchIdleWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Cuts one batch off the front of `pending`, per §4.1: a full `config.batchSize`-sized chunk
    /// whenever there's enough (repeated as many times as needed to work through a large backlog),
    /// otherwise the entire remainder once `forceCutFlag` says to ("件数に関わらず"). Returns `nil` if
    /// neither condition holds (still waiting on more segments or the timeout).
    private func takeNextBatch() -> [TranscriptSegment]? {
        guard !pending.isEmpty else { return nil }
        if pending.count >= config.batchSize {
            let batch = Array(pending.prefix(config.batchSize))
            pending.removeFirst(config.batchSize)
            cutTimerAndRearmIfNeeded()
            return batch
        }
        guard forceCutFlag else { return nil }
        forceCutFlag = false
        let batch = pending
        pending.removeAll()
        cutTimerAndRearmIfNeeded()
        return batch
    }

    /// §4.1 "バッチ確定で解除": cancels the current timer unconditionally, then re-arms a fresh one if
    /// `pending` still has a remainder (treated as a brand-new "0->positive" window, not a
    /// continuation of the just-cancelled one).
    private func cutTimerAndRearmIfNeeded() {
        timerTask?.cancel()
        timerTask = nil
        if !pending.isEmpty {
            armTimerIfNeeded()
        }
    }

    /// Arms a one-shot timer that force-cuts whatever is pending after `config.batchTimeoutMs`
    /// (§4.1 "最初のセグメント投入から... 経過"). A no-op if a timer is already armed -- this is what
    /// makes the "goes 0->1" semantics work even though this is called on every `enqueue(_:)`: only
    /// the call that finds `timerTask == nil` actually starts one. Not `private` (unlike this file's
    /// other dispatch/timer internals): `RefinementQueue+Backlog.swift`'s `enqueueBacklog(...)` calls
    /// this too, so segments recovered from disk are just as eligible for a timeout-based flush as
    /// live `enqueue(_:)` calls -- otherwise a backlog smaller than `config.batchSize` with no
    /// explicit `flush()` would sit in `pending` forever with no timer ever armed for it.
    func armTimerIfNeeded() {
        guard timerTask == nil else { return }
        timerArmCount += 1
        let timeoutMs = config.batchTimeoutMs
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(timeoutMs))
            guard !Task.isCancelled else { return }
            await self?.timerExpired()
        }
    }

    private func timerExpired() {
        timerTask = nil
        guard !pending.isEmpty else { return }
        forceCutFlag = true
        maybeStartDispatch()
    }

    /// Resumes every parked `drain()` caller once `pending.isEmpty && !isDispatching` actually holds
    /// (§3.1). Called only from the end of `runDispatchLoop()`, after `isDispatching` has already
    /// been flipped back to `false`.
    private func resumeDrainWaitersIfIdle() {
        guard pending.isEmpty, !isDispatching else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
