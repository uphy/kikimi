import Foundation
import OSLog

// MARK: - UpdateReason

/// Why a given `updateNow(reason:)`/internal trigger fired (`docs/design/04-summary-updater.md`
/// §4.1). Currently only used for logging; every reason goes through the same update flow (§4.3).
enum UpdateReason: Sendable {
    case segmentThreshold
    case timeThreshold
    case manual
    case pauseFlush
}

// MARK: - SummaryUpdateEvent

/// One push over `SummaryUpdater.events` (`docs/design/04-summary-updater.md` §4.1/§5.1). Every
/// completed update/regeneration/title-proposal -- auto-triggered or user-triggered -- yields one of
/// these so the (out-of-scope-here) `@MainActor` ViewModel can refresh `summaryMarkdown`/`meta`
/// live, since the auto-trigger path never goes through the ViewModel directly.
struct SummaryUpdateEvent: Sendable {
    /// The latest rendered `summary.md`, or `nil` if this event carries no new render (e.g. a
    /// title-only event, or an update that had nothing to summarize).
    var summaryMarkdown: String?
    /// `true` if `meta.json` was updated (title/titleAutoNamedOnce/titleProposal) as part of this
    /// event, so the ViewModel knows to reload `meta`.
    var metaChanged: Bool
}

// MARK: - SummaryUpdater

/// Session-scoped actor orchestrating summary updates: trigger judgment, LLM invocation, file I/O,
/// and automatic-title bookkeeping (`docs/design/04-summary-updater.md`, the single source of truth
/// for every design decision below). Owned by `MeetingWorkspaceViewModel`, created when Recording
/// starts and torn down on Paused/Ended (§4.1) -- wiring that ViewModel/UI work is explicitly out of
/// scope for this type itself (§1's scope table).
actor SummaryUpdater {
    /// Not `private` (this and every other member below marked the same way): `+ParticipantsMerge
    /// .swift`/`+Regeneration.swift` (both split out for `file_length`) read/write these directly.
    let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SummaryUpdater")
    let sessionHandle: SessionHandle
    let llm: LLMCompleting
    let config: SummaryConfig
    /// Session-start snapshot of `ModelResolver.resolve(candidates: [config.model], ...)`
    /// (`docs/design/44-llm-model-config.md` §7): the incremental update / full regeneration /
    /// final-title flows' resolved model. `defaultSummaryUpdaterFactory`
    /// (`MeetingWorkspaceViewModel+Factories.swift`) passes the real resolved value; `init` derives a
    /// fallback straight from `config.model` under the builtin provider when omitted (mirrors
    /// `RefinementQueue.resolvedModel`'s doc comment), so every existing test/DI call site that never
    /// passes this parameter keeps building the same `LLMRequest.model` it did before this field
    /// existed.
    ///
    /// `nonisolated`: `docs/design/44-llm-model-config.md` §8's manual-override menu displays this
    /// value verbatim as the "既定" item's label (`MeetingWorkspaceViewModel+Summary.swift`'s
    /// `summaryDefaultModelLabel(final:)`) without an `await` -- reading it is synchronous the same
    /// way `LLMClient.availableProviders` is, since it is a `let` set once at `init` and never
    /// mutated afterward.
    nonisolated let resolvedModel: ResolvedModel
    /// Session-start snapshot of `ModelResolver.resolve(candidates: [config.finalModel, config.model],
    /// ...)` (§7, §3.2): the session-end final pass's own resolved model, used by
    /// `+FinalPass.swift`'s `performFinalPass(modelOverride:)` whenever no `modelOverride` was given.
    /// Resolved from the two-element candidate list, never `config.finalModel ?? config.model`
    /// collapsed first -- see `SummaryConfig.finalModel`'s doc comment for why. Falls back to
    /// `resolvedModel` itself (not a fresh `config.model`-only resolution) when omitted, since an
    /// unset `finalModel` candidate is exactly what falls through to `model` in the real candidate
    /// list anyway.
    ///
    /// `nonisolated`: same rationale as `resolvedModel` above -- the manual-override menu's "既定"
    /// label for the final-pass re-run button reads this synchronously.
    nonisolated let resolvedFinalModel: ResolvedModel
    let now: @Sendable () -> Date
    /// Resolves `sessionHandle.readParticipants()`'s ids to display names for the §9 "【参加者】" block
    /// injected into every `readContext()` call (`docs/design/22-participant-hints.md` §9). Defaults
    /// to `.shared`, mirroring `RefinementQueue`'s same injection point
    /// (`Kikimi/Refinement/RefinementQueue.swift`).
    let voiceprintStore: VoiceprintStore
    /// Resolves a `PromptID`'s current policy-layer body (`docs/design/42-prompt-overrides.md`
    /// §4.3): override file content if `prompts/<id>.md` is active, `PromptSpec.defaultBody`
    /// otherwise. Read fresh on every call (`.summary`/`.finalTitle` are both `reload: immediate`),
    /// unlike `RefinementQueue`'s `ruleBodyProvider`, which the caller snapshots once at session
    /// start for its `session-start` reload prompts -- there is no such snapshotting here. Defaults
    /// to `PromptStore.shared`, mirroring `voiceprintStore`'s own default-to-`.shared` shape above.
    let promptBodyProvider: @Sendable (PromptID) -> String

    // MARK: Trigger bookkeeping (§4.2)

    /// Count of segments appended (via `noteSegmentAppended()`) since the last completed update.
    var segmentsSinceLastUpdate = 0
    /// Wall-clock time of the last completed update, used for the time-threshold trigger.
    var lastUpdateAt: Date

    // MARK: Serialization (§4.1.1)

    /// `true` while one update/regeneration/title-proposal request is actually running. Every
    /// public entry point funnels through `runSerialized(_:)` below, which is the single in-flight
    /// gate covering *all* of them (not just the auto-trigger path) per §4.1.1.
    private var isRunning = false
    /// Coalesced follow-up requests that arrived while `isRunning`. At most one pending request of
    /// each "kind" is kept -- running one more time after the in-flight request finishes is enough
    /// to observe whatever state changed meanwhile (§4.1.1's "保留中フラグに畳み込み" / §4.2's
    /// "更新待ちフラグを立て、完了後にもう一度回す").
    private var pendingIncrementalUpdate: UpdateReason?
    private var pendingFinalTitleProposal = false
    /// Coalesced follow-up for `.regeneration` (`docs/design/44-llm-model-config.md` §7): `modelOverride`
    /// is last-writer-wins across coalesced requests, the same shape (and rationale) as
    /// `pendingFinalPass` below.
    private var pendingRegeneration: (requested: Bool, modelOverride: ResolvedModel?) = (false, nil)
    /// Coalesced names for a pending `mergeParticipants(_:)` call (design section 6.2, "R2 module 4").
    /// A `Set`, not an array: coalescing while a merge is already running only needs the union of
    /// names, never duplicates (`performParticipantsMerge(_:)`'s own dedup would collapse them anyway).
    private var pendingParticipantsMergeNames: Set<String> = []
    /// Coalesced follow-up for `.finalPass` (summary-quality-topics-and-final-pass.md §7.5):
    /// `modelOverride` is last-writer-wins across coalesced requests.
    private var pendingFinalPass: (requested: Bool, modelOverride: ResolvedModel?) = (false, nil)

    /// `true` while `regenerateFromScratch()` is in progress. §4.1.1: incremental triggers must
    /// stand down while a full regeneration is rewriting `summary.state.json` from scratch, so
    /// `noteSegmentAppended()`'s threshold check consults this flag before enqueuing anything.
    var isRegenerating = false

    /// - Parameters:
    ///   - sessionHandle: The session this updater reads/writes through. `SummaryUpdater` never
    ///     touches `FileManager` itself (§4.1).
    ///   - llm: The narrow `LLMCompleting` seam, not the concrete `LLMClient`, so unit tests inject
    ///     a fake directly (§4.1, SWE review C8).
    ///   - config: Trigger thresholds / model / auto-naming toggle (§8).
    ///   - now: Injectable wall clock, so tests can drive the time-threshold trigger deterministically
    ///     instead of sleeping (mirrors `SessionHandle`'s own `now` injection point).
    ///   - voiceprintStore: See the stored property's doc comment above.
    ///   - promptBodyProvider: See the stored property's doc comment above.
    init(
        sessionHandle: SessionHandle,
        llm: LLMCompleting,
        config: SummaryConfig = SummaryConfig(),
        resolvedModel: ResolvedModel? = nil,
        resolvedFinalModel: ResolvedModel? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        voiceprintStore: VoiceprintStore = .shared,
        promptBodyProvider: @escaping @Sendable (PromptID) -> String = { PromptStore.shared.policyBody(for: .builtin($0)) }
    ) {
        self.sessionHandle = sessionHandle
        self.llm = llm
        self.config = config
        let fallbackResolvedModel = resolvedModel ?? ResolvedModel(provider: ModelResolver.builtinProviderName, model: config.model)
        self.resolvedModel = fallbackResolvedModel
        self.resolvedFinalModel = resolvedFinalModel ?? fallbackResolvedModel
        self.now = now
        self.voiceprintStore = voiceprintStore
        self.promptBodyProvider = promptBodyProvider
        self.lastUpdateAt = now()
        (eventsStream, eventsContinuation) = AsyncStream.makeStream()
    }

    // MARK: - §9 participant context injection (docs/design/22-participant-hints.md §9)

    /// Reads `context.md` and, if the session has a non-empty participant roster, appends the
    /// "【参加者】" block resolved from `voiceprintStore` (design §9). Unlike `RefinementQueue`'s cached
    /// reload, this is called fresh on every summary update/regeneration (§9: "サマリは毎回組み立て直す
    /// ので即時反映"), so no separate cache invalidation is needed here.
    func loadComposedContext() async -> String {
        let rawContext = await sessionHandle.readContext()
        let participants = await sessionHandle.readParticipants()
        guard !participants.participantIds.isEmpty else { return rawContext }
        let speakers = await voiceprintStore.listSpeakers()
        let names = ParticipantContextComposer.resolveParticipantNames(participantIds: participants.participantIds, in: speakers)
        return ParticipantContextComposer.compose(context: rawContext, participantNames: names)
    }

    // MARK: - events (§4.1/§5.1)

    private let eventsStream: AsyncStream<SummaryUpdateEvent>
    let eventsContinuation: AsyncStream<SummaryUpdateEvent>.Continuation

    /// `nonisolated` because this only vends an immutable, `Sendable` `AsyncStream` value set once
    /// at `init` -- safe to read from any isolation context, mirroring `TranscriptPipeline.liveSegments`.
    nonisolated var events: AsyncStream<SummaryUpdateEvent> {
        eventsStream
    }

    // MARK: - Public API (§4.1)

    /// A new transcript segment was appended. Bumps the since-last-update counter and, once the
    /// segment threshold is reached, enqueues an incremental update (non-blocking: this method
    /// returns immediately, the update itself runs on a detached `Task`). Also arms a time-based
    /// trigger `Task` so an update fires `updateTriggerSeconds` after the *first* segment of a new
    /// window, even if the segment count never reaches the threshold (§4.2 "どちらか早い方").
    func noteSegmentAppended() {
        segmentsSinceLastUpdate += 1
        if segmentsSinceLastUpdate == 1 {
            armTimeTrigger()
        }
        if segmentsSinceLastUpdate >= config.updateTriggerSegments {
            enqueue(reason: .segmentThreshold)
        }
    }

    /// Manual "更新" button, or the Recording→Paused/Ended transition's final flush (`.pauseFlush`).
    /// Awaitable so the caller can react on completion (§4.1).
    func updateNow(reason: UpdateReason) async {
        await runSerialized(kind: .incrementalUpdate(reason))
    }

    /// `on_session_end` final title proposal (§3.4). Awaitable.
    func generateFinalTitleProposal() async {
        await runSerialized(kind: .finalTitleProposal)
    }

    /// Full regeneration from all segments (救済パス, §6). Awaitable. `modelOverride`: forward-looking
    /// hook for a future manual re-run UI (`docs/design/44-llm-model-config.md` §7/§8); every current
    /// call site passes `nil`, which resolves to `resolvedModel` (`performRegeneration(modelOverride:)`).
    func regenerateFromScratch(modelOverride: ResolvedModel? = nil) async {
        await runSerialized(kind: .regeneration(modelOverride: modelOverride))
    }

    // `mergeParticipants(_:)` (design section 6.2, "R2 module 4") lives in `+ParticipantsMerge.swift`,
    // split out for `file_length`.

    // MARK: - Serialization core (§4.1.1)

    /// The one request "kind" a caller can ask to run. Not `private` (unlike every other type here):
    /// `+ParticipantsMerge.swift`'s `mergeParticipants(_:)` constructs/passes `.participantsMerge(names)`
    /// to `runSerialized(kind:)` below -- still only `internal`, so only this module's own extension
    /// files see it.
    enum RequestKind {
        case incrementalUpdate(UpdateReason)
        case finalTitleProposal
        /// Full regeneration (救済パス, §6). `modelOverride`: forward-looking hook for a future manual
        /// re-run UI (`docs/design/44-llm-model-config.md` §7/§8); every current call site passes
        /// `nil` (`regenerateFromScratch(modelOverride:)`).
        case regeneration(modelOverride: ResolvedModel?)
        case participantsMerge([String])
        /// Session-end final refinement pass (summary-quality-topics-and-final-pass.md §7.5).
        /// `modelOverride`: forward-looking hook for a future manual re-run UI; every current call
        /// site passes `nil` (`+FinalPass.swift`'s `runFinalPass(modelOverride:)`).
        case finalPass(modelOverride: ResolvedModel?)
    }

    /// Single in-flight gate covering every entry point (§4.1.1). If a request is already running,
    /// this coalesces the new request into the appropriate pending flag and returns once *a*
    /// subsequent run (not necessarily driven by this exact call) has completed -- matching
    /// "実行中の要求は保留中フラグに畳み込み、完了後 1 回だけ後続" while still letting every caller `await`
    /// completion of some run that reflects their request. Not `private` (see `RequestKind` above):
    /// `+ParticipantsMerge.swift`'s `mergeParticipants(_:)` calls this directly too.
    func runSerialized(kind: RequestKind) async {
        if isRunning {
            coalesce(kind)
            // Poll-free wait: spin on the actor's own serial executor until the in-flight run (and
            // any coalesced follow-up it triggers) has cleared. Each iteration re-enters the actor
            // only after yielding, so this never busy-loops synchronously.
            while isRunning {
                await Task.yield()
            }
            return
        }

        isRunning = true
        defer { isRunning = false }
        await execute(kind)

        // Drain coalesced follow-ups one at a time, newest-request-semantics per §4.1.1 ("保留中に
        // 他経路が state を書いた可能性があるため" state is always re-read at the start of `execute`).
        while let next = takePendingRequest() {
            await execute(next)
        }
    }

    private func coalesce(_ kind: RequestKind) {
        switch kind {
        case .incrementalUpdate(let reason):
            pendingIncrementalUpdate = mergedReason(pendingIncrementalUpdate, reason)
        case .finalTitleProposal:
            pendingFinalTitleProposal = true
        case .regeneration(let modelOverride):
            pendingRegeneration = (true, modelOverride)
        case .participantsMerge(let names):
            pendingParticipantsMergeNames.formUnion(names)
        case .finalPass(let modelOverride):
            pendingFinalPass = (true, modelOverride)
        }
    }

    /// Manual/pauseFlush reasons carry user-visible intent; keep the more specific one if both a
    /// threshold trigger and a manual/pauseFlush request coalesce together.
    private func mergedReason(_ existing: UpdateReason?, _ incoming: UpdateReason) -> UpdateReason {
        guard let existing else { return incoming }
        switch (existing, incoming) {
        case (.segmentThreshold, _), (.timeThreshold, .manual), (.timeThreshold, .pauseFlush):
            return incoming
        default:
            return existing
        }
    }

    /// Priority order: regeneration → finalPass → finalTitleProposal → incrementalUpdate →
    /// participantsMerge (`docs/design/summary-quality-topics-and-final-pass.md` §7.5).
    /// `finalPass` runs ahead of `finalTitleProposal` so the final title is generated from the
    /// final pass's improved `overview`/`decisions`, not the pre-final-pass state.
    private func takePendingRequest() -> RequestKind? {
        // Regeneration takes priority: it is the "救済パス" the user explicitly asked for, and
        // §4.1.1 already dedicates a special standdown for incremental updates while it runs.
        if pendingRegeneration.requested {
            let modelOverride = pendingRegeneration.modelOverride
            pendingRegeneration = (false, nil)
            return .regeneration(modelOverride: modelOverride)
        }
        if pendingFinalPass.requested {
            let modelOverride = pendingFinalPass.modelOverride
            pendingFinalPass = (false, nil)
            return .finalPass(modelOverride: modelOverride)
        }
        if pendingFinalTitleProposal {
            pendingFinalTitleProposal = false
            return .finalTitleProposal
        }
        if let reason = pendingIncrementalUpdate {
            pendingIncrementalUpdate = nil
            return .incrementalUpdate(reason)
        }
        if !pendingParticipantsMergeNames.isEmpty {
            let names = Array(pendingParticipantsMergeNames)
            pendingParticipantsMergeNames = []
            return .participantsMerge(names)
        }
        return nil
    }

    private func execute(_ kind: RequestKind) async {
        switch kind {
        case .incrementalUpdate(let reason):
            await performIncrementalUpdate(reason: reason)
        case .finalTitleProposal:
            await performFinalTitleProposal()
        case .regeneration(let modelOverride):
            await performRegeneration(modelOverride: modelOverride)
        case .participantsMerge(let names):
            await performParticipantsMerge(names)
        case .finalPass(let modelOverride):
            await performFinalPass(modelOverride: modelOverride)
        }
    }

    /// Fire-and-forget entry point for the non-blocking triggers (`noteSegmentAppended`'s threshold
    /// crossing, the time-trigger `Task`). Manual/awaitable callers go through `runSerialized`
    /// directly via the `async` public methods above.
    private func enqueue(reason: UpdateReason) {
        Task { [weak self] in
            await self?.runSerialized(kind: .incrementalUpdate(reason))
        }
    }

    // MARK: - Time-based trigger (§4.2)

    private var timeTriggerTask: Task<Void, Never>?

    /// Arms a one-shot timer that fires an update `updateTriggerSeconds` after the first segment of
    /// a new since-last-update window, so a low-volume tail of the meeting isn't stuck waiting for
    /// the segment-count threshold (§4.2 "3分経過... どちらか早い方"). Replacing any previous timer
    /// task is safe: this is only called when `segmentsSinceLastUpdate` just became `1`, i.e. right
    /// after a window reset.
    private func armTimeTrigger() {
        timeTriggerTask?.cancel()
        let seconds = config.updateTriggerSeconds
        timeTriggerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.enqueue(reason: .timeThreshold)
        }
    }

    // MARK: - Shared sanitized state read (docs/design/summary-quality-topics-and-final-pass.md §2.3)

    /// The single call site for `sessionHandle.readJSON(.summaryState, as: SummaryState.self)`, so
    /// `sanitizeState(_:)`'s normalization (unnumbered `dc_00N`/`tp_00N` id backfill,
    /// reserved-channel-name participant removal -- `SummaryPatchApplier.swift`) applies uniformly
    /// on every read, including sessions written before that normalization existed. Not `private`:
    /// used here, and from `+FinalTitle.swift`/`+ParticipantsMerge.swift`/`+FinalPass.swift`.
    func readSanitizedSummaryState() async throws -> SummaryState {
        var state = (try await sessionHandle.readJSON(.summaryState, as: SummaryState.self)) ?? .empty
        sanitizeState(&state)
        return state
    }

    // MARK: - §4.3 Incremental update flow

    private func performIncrementalUpdate(reason: UpdateReason) async {
        // State is read fresh at the start of execution, never carried across an `await` boundary
        // from an earlier check (§4.1.1's "state の読み込みは必ず実行の直前に行い").
        let segments: [SummarySegmentInput]
        let cursor: Int?
        let priorState: SummaryState
        do {
            (segments, cursor, priorState) = try await loadPendingInput()
        } catch {
            logger.error("Failed to load transcript/state for summary update: \(String(describing: error), privacy: .public)")
            return
        }

        guard !segments.isEmpty else {
            // §4.3 step 2 / §9: nothing unsummarized. Manual/pauseFlush requests are also expected
            // to no-op here rather than force an LLM call with no new content.
            logger.debug("No unsummarized segments (reason: \(String(describing: reason), privacy: .public)); skipping update.")
            return
        }

        let contextMarkdown = await loadComposedContext()
        let userPrompt: String
        do {
            userPrompt = try SummaryPromptBuilder.buildUserPrompt(
                state: priorState,
                segments: segments,
                now: now(),
                contextMarkdown: contextMarkdown
            )
        } catch {
            logger.error("Failed to build summary prompt: \(String(describing: error), privacy: .public)")
            return
        }

        let patch: SummaryPatch
        do {
            let result: LLMResult<SummaryPatch> = try await llm.complete(
                LLMRequest(
                    system: SummaryPromptBuilder.systemPrompt(policyBody: promptBodyProvider(.summary)),
                    user: userPrompt,
                    schema: SummaryJSONSchema.patchSchemaJSON,
                    resolved: resolvedModel,
                    stubKey: "summary_patch"
                )
            )
            patch = result.value
        } catch {
            // §4.3 step 5 / §9: skip this update entirely on LLM failure. state/cursor stay
            // unchanged; recording/transcript are never affected.
            logger.warning("Summary patch LLM call failed, skipping this update: \(String(describing: error), privacy: .public)")
            return
        }

        var updatedState = priorState
        applyPatch(patch, to: &updatedState)
        let maxStartMs = segments.map(\.startMs).max() ?? cursor ?? 0
        updatedState.lastSummarizedStartMs = maxStartMs

        do {
            try await sessionHandle.writeJSON(updatedState, to: .summaryState)
        } catch {
            logger.error("Failed to persist summary.state.json: \(String(describing: error), privacy: .public)")
            return
        }

        let templateString = await sessionHandle.readSummaryTemplate()
        var renderedMarkdown: String?
        if let rendered = SummaryRenderer.render(updatedState, templateString: templateString) {
            renderedMarkdown = rendered
            do {
                try await sessionHandle.writeText(rendered, to: .summaryMarkdown)
            } catch {
                // §9: renderer succeeded but the write itself failed -- previous summary.md is left
                // in place on disk (we simply didn't overwrite it); still log.
                logger.error("Failed to write summary.md: \(String(describing: error), privacy: .public)")
                renderedMarkdown = nil
            }
        } else {
            // SummaryRenderer already tried the default template internally and still failed
            // (§9: "内蔵デフォルト template で再試行... なお失敗なら前回 summary.md を保持し warn"). Leave the
            // on-disk summary.md untouched.
            logger.warning("Summary render failed even with the default template; keeping the previous summary.md.")
        }

        segmentsSinceLastUpdate = 0
        lastUpdateAt = now()
        timeTriggerTask?.cancel()
        timeTriggerTask = nil

        logger.info("Summary update completed (reason: \(String(describing: reason), privacy: .public), segments: \(segments.count, privacy: .public)).")

        let metaChanged = await applyAutomaticTitle(proposal: patch.title)
        eventsContinuation.yield(SummaryUpdateEvent(summaryMarkdown: renderedMarkdown, metaChanged: metaChanged))
    }

    /// Reads transcript input for one update: refined segments preferred, falling back to raw
    /// transcript per-segment when no refined counterpart exists yet (§1's scope note / kikimi.md
    /// 8.5 章), merged and sorted `startMs` ascending, then filtered to the "未反映分" using the
    /// current `summary.state.json`'s cursor with strict `>` (§4.2).
    private func loadPendingInput() async throws -> (segments: [SummarySegmentInput], cursor: Int?, state: SummaryState) {
        let transcriptSegments = try await sessionHandle.readTranscriptSegments()
        let refinedSegments = try await sessionHandle.readRefinedSegments()
        // Defense-in-depth (§3.2 "防御の二重化") + §15.2.5's sourceSegIds expansion: last-wins on a
        // duplicate id, and a merged unit's non-leading raw ids resolve to the same unit here too.
        let refinedById = refinedSegments.indexedBySourceSegId()

        let merged: [SummarySegmentInput] = transcriptSegments.compactMap { transcript in
            if let refined = refinedById[transcript.id], let refinedText = refined.refinedText {
                // Empty refined text means refinement dropped the segment as meaningless
                // (filler-only, kikimi.md 7 章の整形ルール) -- exclude it from summary input
                // instead of falling back to raw.
                guard !refinedText.isEmpty else { return nil }
                return SummarySegmentInput(id: transcript.id, startMs: transcript.startMs, speaker: transcript.speaker, text: refinedText)
            }
            return SummarySegmentInput(id: transcript.id, startMs: transcript.startMs, speaker: transcript.speaker, text: transcript.text)
        }.sorted { $0.startMs < $1.startMs }

        let priorState = try await readSanitizedSummaryState()
        let cursor = priorState.lastSummarizedStartMs
        let pending = merged.filter { cursor == nil || $0.startMs > cursor! }
        return (pending, cursor, priorState)
    }

    // MARK: - §3.1 Automatic title (Recording-time reflection)

    /// Applies the once-only-auto-reflect / proposal-badge state machine (§3.1) inside a single
    /// `updateMeta` closure, atomically. Returns whether `meta.json` actually changed, so the caller
    /// can set `SummaryUpdateEvent.metaChanged`. Not `private`: `+Regeneration.swift`'s
    /// `performRegeneration()` also calls this, at the end of a full regeneration.
    @discardableResult
    func applyAutomaticTitle(proposal: String?) async -> Bool {
        guard config.autoNaming else { return false }
        guard let proposal, !proposal.isEmpty else { return false }

        var changed = false
        do {
            try await sessionHandle.updateMeta { meta in
                guard meta.titleAutoGenerated else { return }
                if meta.titleAutoNamedOnce == false {
                    meta.title = proposal
                    meta.titleAutoNamedOnce = true
                    meta.titleProposal = nil
                    changed = true
                } else if proposal != meta.title {
                    meta.titleProposal = proposal
                    changed = true
                }
            }
        } catch {
            logger.error("Failed to apply automatic title to meta.json: \(String(describing: error), privacy: .public)")
            return false
        }
        return changed
    }

    // `performFinalTitleProposal()` lives in `+FinalTitle.swift`; `performRegeneration()`/
    // `loadAllSegmentsSorted()` (§6) live in `+Regeneration.swift`; `mergeParticipants(_:)`/
    // `performParticipantsMerge(_:)` (§6.2 "R2 module 4") live in `+ParticipantsMerge.swift`;
    // `runFinalPass(modelOverride:)`/`performFinalPass(modelOverride:)`
    // (summary-quality-topics-and-final-pass.md §7) live in `+FinalPass.swift` -- all four split
    // out for `file_length`.
}
