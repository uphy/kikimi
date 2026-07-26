import Foundation
import OSLog

// MARK: - WatcherTriggerKind

/// Associated-value-free counterpart of `WatcherTrigger`, used purely for trigger-kind comparison
/// (`docs/design/05-watcher-runner.md` §9: "`WatcherTrigger` は interval 秒の連想値を持つため別に定義").
enum WatcherTriggerKind: Sendable, Equatable {
    case onSummaryUpdate
    case onSessionEnd
    case onManual
    case onInterval
}

// MARK: - WatcherEvent

/// One push over `WatcherRunner.events` (§9), mirroring `SummaryUpdateEvent`/`RefinementEvent`'s
/// vend-an-`AsyncStream` shape so the (out-of-scope-here) ViewModel can update `WatcherPanelItem`
/// state live.
struct WatcherEvent: Sendable {
    var watcherId: String
    var kind: Kind

    enum Kind: Sendable {
        case started
        case finished(renderedMarkdown: String, at: Date)
        /// Every failure mode -- parse/LLM/validation/render -- collapses into this one case
        /// (§9.1: "どの段で失敗しても `.failed(message:)` を yield").
        case failed(message: String)
        /// A persisted `watchers/<id>.state.json` failed schema validation and was reset to
        /// `initial_state` (§7.1/§12). Yielded in addition to (before) whatever `.finished`/`.failed`
        /// this same run produces.
        case stateReset(message: String)
    }
}

// MARK: - WatcherRunner

/// Session-scoped actor executing Watchers: trigger dispatch, LLM invocation, state persistence, and
/// view rendering (`docs/design/05-watcher-runner.md` §9, the single source of truth for every
/// decision below). Owned by `MeetingWorkspaceViewModel` for the ViewModel's entire lifetime (not
/// torn down on Paused, unlike `SummaryUpdater` -- §9's "Ended セッションでも `on_manual` を実行できる
/// ようにするため").
actor WatcherRunner {
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "WatcherRunner")

    private let sessionHandle: SessionHandle
    private let llm: LLMCompleting
    private let library: WatcherLibrary
    private let defaultModel: String
    /// Injectable wall clock for `.finished(at:)`, so tests can assert its value deterministically
    /// instead of racing `Date()` (mirrors `SummaryUpdater`/`RefinementQueue`'s own `now` injection).
    private let now: @Sendable () -> Date
    /// Injectable sleep for `on_interval` loop testability (§9's init signature), mirroring
    /// `SummaryUpdater`/`RefinementQueue`'s own timer-`Task` patterns.
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Watcher ids currently mid-execution, guarding against multiple in-flight runs of the same
    /// Watcher (§9.2: "同一 Watcher の多重実行は抑止... スキップは debug ログ"). Both `run(trigger:)`'s
    /// per-id dispatch and `runManually(id:)` funnel through `execute(id:definition:)` below, so this
    /// one set covers both call paths.
    private var inFlightWatcherIds: Set<String> = []

    /// One `Task` per currently-active `on_interval` Watcher (§9.3), keyed by watcher id.
    private var intervalTasks: [String: Task<Void, Never>] = [:]

    init(
        sessionHandle: SessionHandle,
        llm: LLMCompleting,
        library: WatcherLibrary,
        defaultModel: String,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.sessionHandle = sessionHandle
        self.llm = llm
        self.library = library
        self.defaultModel = defaultModel
        self.now = now
        self.sleep = sleep
        (eventsStream, eventsContinuation) = AsyncStream.makeStream()
    }

    // MARK: - events

    private let eventsStream: AsyncStream<WatcherEvent>
    private let eventsContinuation: AsyncStream<WatcherEvent>.Continuation

    /// `nonisolated` because this only vends an immutable, `Sendable` `AsyncStream` value set once at
    /// `init` -- safe to read from any isolation context (mirrors `SummaryUpdater.events`).
    nonisolated var events: AsyncStream<WatcherEvent> {
        eventsStream
    }

    // MARK: - Public API (§9)

    /// Runs every enabled Watcher whose `trigger` matches `trigger` kind, in parallel
    /// (§9.2: "同一トリガで複数 Watcher が発火する場合は `withTaskGroup` で並列"). An unreadable
    /// `enabled.yaml` skips the whole trigger with an `.error` log (§12); an individual id with no
    /// resolvable definition is silently skipped (§12: "実体なし... 実行はスキップ", no event -- the
    /// ViewModel's own `watcherItems` construction is what surfaces a `missing` badge for that id,
    /// not this method). A resolvable-but-unparseable definition *does* yield `.failed`, since that's
    /// a real Watcher misconfiguration worth surfacing regardless of which trigger caught it.
    func run(trigger: WatcherTriggerKind) async {
        let ids: [String]
        do {
            ids = try await sessionHandle.readEnabledWatchers()
        } catch {
            logger.error("Failed to read watchers/enabled.yaml; skipping trigger \(String(describing: trigger), privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { [weak self] in
                    await self?.runIfMatchingTrigger(id: id, trigger: trigger)
                }
            }
        }
    }

    /// Runs `id` regardless of its declared `trigger` (§9's "trigger を問わず単発実行", the Watchers tab's
    /// "今すぐ実行" button). Yields `.failed` if `id` has no resolvable definition or fails to parse --
    /// unlike `run(trigger:)`'s bulk path, this is always an explicit user action that deserves direct
    /// feedback.
    func runManually(id: String) async {
        guard let resolved = try? await library.resolveDefinitionText(id: id, sessionHandle: sessionHandle) else {
            eventsContinuation.yield(WatcherEvent(watcherId: id, kind: .failed(message: "Watcher定義が見つかりません（id: \(id)）")))
            return
        }
        do {
            let definition = try WatcherDefinitionParser.parse(text: resolved.text, expectedId: id)
            await execute(id: id, definition: definition)
        } catch {
            eventsContinuation.yield(WatcherEvent(watcherId: id, kind: .failed(message: Self.describe(error))))
        }
    }

    /// Starts one `on_interval` loop `Task` per currently-enabled `on_interval` Watcher (§9.3),
    /// called at Recording start/resume. Clears any previously-started loops first, so a stray
    /// `startIntervalWatchers()` re-call is idempotent rather than doubling up loops for the same id.
    func startIntervalWatchers() async {
        stopIntervalWatchers()
        guard let ids = try? await sessionHandle.readEnabledWatchers() else { return }
        for id in ids {
            guard let definition = await resolveAndParse(id: id), case .onInterval = definition.trigger else { continue }
            intervalTasks[id] = Task { [weak self] in
                await self?.runIntervalLoop(id: id)
            }
        }
    }

    /// Cancels every `on_interval` loop `Task` (§9.3, called at Paused/Ended/window-close). A no-op
    /// if none are running.
    func stopIntervalWatchers() {
        for task in intervalTasks.values {
            task.cancel()
        }
        intervalTasks.removeAll()
    }

    /// Ends `events` and stops every `on_interval` loop (§9: "events 終了 + interval 停止").
    func shutdown() {
        stopIntervalWatchers()
        eventsContinuation.finish()
    }

    // MARK: - Trigger dispatch

    private func runIfMatchingTrigger(id: String, trigger: WatcherTriggerKind) async {
        guard let resolved = try? await library.resolveDefinitionText(id: id, sessionHandle: sessionHandle) else {
            logger.debug("Watcher \(id, privacy: .public) has no resolvable definition; skipping this trigger.")
            return
        }
        let definition: WatcherDefinition
        do {
            definition = try WatcherDefinitionParser.parse(text: resolved.text, expectedId: id)
        } catch {
            eventsContinuation.yield(WatcherEvent(watcherId: id, kind: .failed(message: Self.describe(error))))
            return
        }
        guard Self.triggerKind(of: definition.trigger) == trigger else { return }
        await execute(id: id, definition: definition)
    }

    private func resolveAndParse(id: String) async -> WatcherDefinition? {
        guard let resolved = try? await library.resolveDefinitionText(id: id, sessionHandle: sessionHandle) else {
            return nil
        }
        return try? WatcherDefinitionParser.parse(text: resolved.text, expectedId: id)
    }

    private static func triggerKind(of trigger: WatcherTrigger) -> WatcherTriggerKind {
        switch trigger {
        case .onSummaryUpdate: return .onSummaryUpdate
        case .onSessionEnd: return .onSessionEnd
        case .onManual: return .onManual
        case .onInterval: return .onInterval
        }
    }

    // MARK: - §9.3 on_interval loop

    private func runIntervalLoop(id: String) async {
        while !Task.isCancelled {
            guard let definition = await resolveAndParse(id: id) else {
                // §9.3: "interval Watcher の定義再読込失敗 -> ループ停止 + .failed。次の Recording 再開で再始動".
                eventsContinuation.yield(WatcherEvent(watcherId: id, kind: .failed(message: "Watcher定義の再読込に失敗しました（id: \(id)）")))
                return
            }
            guard case .onInterval(let seconds) = definition.trigger else {
                // A live .md edit changed this Watcher's trigger away from on_interval; this loop's
                // job is done (the next startIntervalWatchers() call will not restart it for this id).
                return
            }
            do {
                try await sleep(.seconds(seconds))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await execute(id: id, definition: definition)
        }
    }

    // MARK: - §9.1 single-Watcher execution

    private func execute(id: String, definition: WatcherDefinition) async {
        guard !inFlightWatcherIds.contains(id) else {
            logger.debug("Watcher \(id, privacy: .public) is already running; skipping this trigger.")
            return
        }
        inFlightWatcherIds.insert(id)
        defer { inFlightWatcherIds.remove(id) }

        eventsContinuation.yield(WatcherEvent(watcherId: id, kind: .started))

        let (loadedState, wasReset) = await loadState(id: id, definition: definition)
        if wasReset {
            eventsContinuation.yield(WatcherEvent(
                watcherId: id,
                kind: .stateReset(message: "保存されていた state が schema と一致しないため、初期状態にリセットしました。")
            ))
        }

        let summaryMarkdown = (try? await sessionHandle.readText(.summaryMarkdown)) ?? ""
        let recentSegments = await resolveRecentSegments(inputScope: definition.inputScope)
        let userPrompt = WatcherPromptBuilder.buildUserPrompt(
            template: definition.userPromptTemplate,
            stateText: WatcherPromptBuilder.stateText(for: loadedState, stateMode: definition.stateMode),
            summaryMarkdown: summaryMarkdown,
            recentSegmentsText: WatcherPromptBuilder.recentSegmentsText(recentSegments)
        )

        let request = LLMRequest(
            system: definition.systemPrompt,
            user: userPrompt,
            schema: definition.schema.jsonSchemaString(),
            model: definition.model ?? defaultModel,
            stubKey: "watcher_\(id)"
        )

        let rawResult: LLMResult<Data>
        do {
            rawResult = try await llm.completeRaw(request)
        } catch {
            eventsContinuation.yield(WatcherEvent(watcherId: id, kind: .failed(message: Self.describe(error))))
            return
        }

        let outputValue: JSONValue
        do {
            outputValue = try JSONValue.parse(data: rawResult.value)
        } catch {
            eventsContinuation.yield(WatcherEvent(watcherId: id, kind: .failed(message: "LLM の出力を JSON として解析できませんでした。")))
            return
        }
        let outputErrors = definition.schema.validate(outputValue)
        guard outputErrors.isEmpty else {
            eventsContinuation.yield(WatcherEvent(watcherId: id, kind: .failed(message: "出力が schema に一致しません: \(outputErrors.joined(separator: "; "))")))
            return
        }
        let canonicalOutput = definition.schema.canonicalize(outputValue)

        let mergedState = WatcherStateMerge.apply(llmOutput: canonicalOutput, to: loadedState, stateMode: definition.stateMode)
        let mergeErrors = definition.schema.validate(mergedState)
        guard mergeErrors.isEmpty else {
            eventsContinuation.yield(WatcherEvent(watcherId: id, kind: .failed(message: "更新後の state が schema に一致しません: \(mergeErrors.joined(separator: "; "))")))
            return
        }
        let canonicalMergedState = definition.schema.canonicalize(mergedState)

        do {
            try await sessionHandle.writeText(canonicalMergedState.serialize(pretty: true), to: .watcherState(id: id))
        } catch {
            eventsContinuation.yield(WatcherEvent(watcherId: id, kind: .failed(message: "state の保存に失敗しました。")))
            return
        }

        guard let renderedMarkdown = WatcherViewRenderer.render(state: canonicalMergedState, schema: definition.schema, template: definition.view) else {
            // §12: view のレンダリング失敗 -- state は更新済みのまま. The next successful render (after the
            // user fixes the view template) picks up this already-persisted state.
            eventsContinuation.yield(WatcherEvent(watcherId: id, kind: .failed(message: "view のレンダリングに失敗しました。")))
            return
        }

        eventsContinuation.yield(WatcherEvent(watcherId: id, kind: .finished(renderedMarkdown: renderedMarkdown, at: now())))
    }

    /// Loads `watchers/<id>.state.json` (§7.1). No file yet is the normal pre-first-run case
    /// (`definition.initialState`, no reset event); a file that exists but fails to parse or fails
    /// `schema.validate` resets to `initialState` and reports `wasReset: true` so the caller yields
    /// `.stateReset`.
    private func loadState(id: String, definition: WatcherDefinition) async -> (state: JSONValue?, wasReset: Bool) {
        guard let stateText = try? await sessionHandle.readText(.watcherState(id: id)), !stateText.isEmpty else {
            return (definition.initialState, false)
        }
        guard let parsed = try? JSONValue.parse(string: stateText) else {
            return (definition.initialState, true)
        }
        guard definition.schema.validate(parsed).isEmpty else {
            return (definition.initialState, true)
        }
        return (definition.schema.canonicalize(parsed), false)
    }

    /// Resolves `{{recent_segments}}`'s source list per `input_scope` (§6's table): refined text
    /// preferred over raw per segment (falling back to raw when unrefined), segments whose refined
    /// text is empty (intentionally dropped by refinement) excluded entirely, sorted `start_ms`
    /// ascending -- the same merge `SummaryUpdater.loadPendingInput()` performs, just without a
    /// high-water-mark cursor (Watchers re-send the whole window every run, per §6's "ステートレスな
    /// 固定窓" rationale).
    private func resolveRecentSegments(inputScope: WatcherInputScope) async -> [WatcherSegmentInput] {
        guard inputScope != .summary else { return [] }
        let merged = await mergedSegments()
        switch inputScope {
        case .summary:
            return []
        case .summaryAndRecent(let count):
            return Array(merged.suffix(count))
        case .fullRefined:
            return merged
        }
    }

    private func mergedSegments() async -> [WatcherSegmentInput] {
        let transcriptSegments = (try? await sessionHandle.readTranscriptSegments()) ?? []
        let refinedSegments = (try? await sessionHandle.readRefinedSegments()) ?? []
        // `docs/design/03-refinement-batch.md` §15.2.5 (`full_refined` scope): a merged unit's
        // `sourceSegIds` all resolve to the same (already-merged) unit here, matching
        // `SummaryUpdater.loadPendingInput()`'s identical generalization.
        let refinedById = refinedSegments.indexedBySourceSegId()

        return transcriptSegments.compactMap { transcript -> WatcherSegmentInput? in
            if let refined = refinedById[transcript.id], let refinedText = refined.refinedText {
                guard !refinedText.isEmpty else { return nil }
                return WatcherSegmentInput(id: transcript.id, startMs: transcript.startMs, speaker: transcript.speaker, text: refinedText)
            }
            return WatcherSegmentInput(id: transcript.id, startMs: transcript.startMs, speaker: transcript.speaker, text: transcript.text)
        }.sorted { $0.startMs < $1.startMs }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
