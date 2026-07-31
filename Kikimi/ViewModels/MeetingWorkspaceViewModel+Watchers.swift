import Foundation

// MARK: - MeetingWorkspaceViewModel + Watchers (`docs/design/05-watcher-runner.md` §10.1)

/// Split into its own file (alongside `MeetingWorkspaceViewModel.swift`'s other extensions, e.g.
/// `+Summary.swift`/`+Refinement.swift`) to keep that file under the project's `file_length` lint
/// limit. Owns `watcherItems`/`selectedWatcherId`/`pendingTranscriptScrollTarget`'s entire
/// read/write surface: building/refreshing the Watchers-tab item list from `enabled.yaml` +
/// `watcherLibrary`, the `watcherRunner.events` subscription that keeps it live, and every Prep-tab
/// management operation (§10.3: enable/disable, fork, promote, create/delete/edit a session-local
/// Watcher).
///
/// The stored properties this file writes (`watcherItems`/`selectedWatcherId`/
/// `pendingTranscriptScrollTarget`/`watcherEventsTask`) and the `watcherLibrary`/`watcherRunner`
/// dependencies it reads are declared on `MeetingWorkspaceViewModel` itself (§10.1: "stored property
/// ... は extension に置けないため本体に宣言"); this file contains only methods.
extension MeetingWorkspaceViewModel {
    // MARK: - Lifecycle

    /// Subscribes to `watcherRunner.events` and performs the initial LLM-free render of every
    /// enabled Watcher's already-persisted `watchers/<id>.state.json` (§10.1's "ワークスペースを開いた
    /// 時点で... 初期レンダリングを 1 回行う。LLM は呼ばない"). Called once from `onAppear()`; a no-op on a
    /// second call (mirrors `startSummaryUpdaterIfNeeded()`'s own `summaryUpdater == nil` guard) so a
    /// `.task` re-run (e.g. the hosting window briefly re-appearing) never double-subscribes.
    func startWatchersIfNeeded() async {
        guard watcherEventsTask == nil else { return }
        watcherEventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.watcherRunner.events {
                self.applyWatcherEvent(event)
            }
        }
        await refreshWatcherItems()
    }

    // MARK: - Items construction (§10.1, §12's "実体なし -> missing バッジ")

    /// Rebuilds `watcherItems` from `enabled.yaml`, in `enabled.yaml`'s own order. Every id's
    /// `name`/`origin` is re-resolved from its current definition text so a live `.md` edit (name
    /// change, preset -> session-local fork, ...) is reflected immediately; `renderedMarkdown`/
    /// `status`/`lastRunAt` are carried over from the previous `watcherItems` entry for the same id
    /// (a refresh must never blank out an already-rendered result just because some *other* id's
    /// enabled state changed). An id with no resolvable definition becomes `origin: .missing` with an
    /// `.error` status badge (§12) rather than being silently dropped -- `run(trigger:)` itself
    /// already skips it silently, so this is the only place that badge can come from.
    ///
    /// An unreadable `enabled.yaml` (`readEnabledWatchers()` throwing) degrades to an empty list --
    /// same "処理は継続" spirit as `WatcherRunner.run(trigger:)`'s own handling of that failure.
    func refreshWatcherItems() async {
        let ids = (try? await sessionHandle.readEnabledWatchers()) ?? []
        // `uniquingKeysWith:` (not `uniqueKeysWithValues:`) defensively tolerates a hand-edited
        // `enabled.yaml` with a duplicate id -- `watcherItems` itself is keyed by this same rebuild,
        // so a crash here would be self-inflicted from malformed input, not a real invariant.
        let previousById = Dictionary(watcherItems.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })

        var items: [WatcherPanelItem] = []
        items.reserveCapacity(ids.count)
        var seenIds = Set<String>()
        for id in ids {
            // Defensively de-duplicates a hand-edited `enabled.yaml` with a repeated id -- SwiftUI's
            // `ForEach(watcherItems)` needs `id` to actually be unique.
            guard seenIds.insert(id).inserted else { continue }
            let previous = previousById[id]
            if let resolved = try? await watcherLibrary.resolveDefinitionText(id: id, sessionHandle: sessionHandle),
               let definition = try? WatcherDefinitionParser.parse(text: resolved.text, expectedId: id, simpleWatcherTemplate: currentSimpleWatcherTemplate()) {
                items.append(WatcherPanelItem(
                    id: id,
                    name: definition.name,
                    origin: resolved.origin,
                    isSimple: definition.simpleSpec != nil,
                    inputScope: definition.inputScope,
                    renderedMarkdown: previous?.renderedMarkdown,
                    status: previous?.status ?? .idle,
                    lastRunAt: previous?.lastRunAt
                ))
            } else {
                items.append(WatcherPanelItem(
                    id: id,
                    name: previous?.name ?? id,
                    origin: .missing,
                    isSimple: false,
                    // Not carried over from `previous`: an id that no longer resolves has no
                    // definition to read a scope from, and showing the last-known one would claim
                    // knowledge about a run that can no longer happen.
                    inputScope: nil,
                    renderedMarkdown: previous?.renderedMarkdown,
                    status: .error("Watcher定義が見つからないか、解析に失敗しました。"),
                    lastRunAt: previous?.lastRunAt
                ))
            }
        }
        watcherItems = items

        if let selectedWatcherId, !items.contains(where: { $0.id == selectedWatcherId }) {
            self.selectedWatcherId = items.first?.id
        } else if selectedWatcherId == nil {
            selectedWatcherId = items.first?.id
        }

        for item in items where item.renderedMarkdown == nil && item.origin != .missing {
            await renderExistingState(for: item.id)
        }
    }

    /// The initial, LLM-free render for one Watcher id (§10.1): loads whatever `state.json` is
    /// already on disk (falling back to the definition's `initial_state`, then giving up quietly if
    /// neither exists or the persisted state no longer matches the current schema -- the *next*
    /// actual trigger is what performs the real §7.1 reset-and-badge flow, not this best-effort
    /// preview) and renders it through the current `view` template.
    private func renderExistingState(for id: String) async {
        guard let resolved = try? await watcherLibrary.resolveDefinitionText(id: id, sessionHandle: sessionHandle),
              let definition = try? WatcherDefinitionParser.parse(text: resolved.text, expectedId: id, simpleWatcherTemplate: currentSimpleWatcherTemplate()) else {
            return
        }
        let stateText = try? await sessionHandle.readText(.watcherState(id: id))
        var persisted: JSONValue?
        if let stateText, !stateText.isEmpty,
           let parsed = try? JSONValue.parse(string: stateText),
           definition.schema.validate(parsed).isEmpty {
            persisted = definition.schema.canonicalize(parsed)
        }
        guard let state = persisted ?? definition.initialState else { return }
        guard let rendered = WatcherViewRenderer.render(state: state, schema: definition.schema, template: definition.view) else { return }

        // Recovers when the displayed result was produced, and from what. Without this a reopened
        // session (any Ended meeting, or any window opened from the session list) rendered a real
        // result under a "未実行" footer, since `lastRunAt` otherwise only ever comes from a live
        // `WatcherEvent.finished(at:)` this process observed itself.
        //
        // Deliberately skipped when `persisted == nil`: `rendered` then came from the definition's
        // `initial_state`, which really has never been run, and any record on disk would describe a
        // run whose output is no longer what's on screen.
        let lastRun = persisted == nil ? nil : await lastRunMetadata(for: id)
        updateWatcherItem(id: id) {
            $0.renderedMarkdown = rendered
            // Never overwrites what a live `.finished` already told us -- that is the run itself
            // reporting, while this is reconstructed after the fact.
            if $0.lastRunAt == nil, let lastRun {
                $0.lastRunAt = lastRun.finishedAt
                $0.lastRunInputScope = lastRun.inputScope
            }
        }
    }

    /// The last run's timestamp and `input_scope` for `id`, preferring `watchers/<id>.run.json`
    /// (`WatcherRunRecord`, written by every run since `docs/design/05-watcher-runner.md` §7.2) and
    /// falling back to `watchers/<id>.state.json`'s mtime for results produced before that file
    /// existed. The fallback can only supply the timestamp -- the scope stays `nil`, and the footer
    /// then describes the definition's current value alone.
    ///
    /// The mtime is a faithful proxy: `state.json` is written exactly once per successful run and
    /// never touched otherwise.
    private func lastRunMetadata(for id: String) async -> (finishedAt: Date, inputScope: WatcherInputScope?)? {
        if let record = try? await sessionHandle.readJSON(.watcherRunRecord(id: id), as: WatcherRunRecord.self) {
            return (record.finishedAt, record.inputScope)
        }
        guard let mtime = try? await sessionHandle.modificationDate(of: .watcherState(id: id)) else { return nil }
        return (mtime, nil)
    }

    private func updateWatcherItem(id: String, _ mutate: (inout WatcherPanelItem) -> Void) {
        guard let index = watcherItems.firstIndex(where: { $0.id == id }) else { return }
        mutate(&watcherItems[index])
    }

    /// Applies one `WatcherRunner.events` push to the matching `watcherItems` entry (a no-op if `id`
    /// isn't currently listed, e.g. a stale event racing a `refreshWatcherItems()` that just disabled
    /// it). `.stateReset` is intentionally not reflected in `status` -- per `WatcherEvent.Kind`'s own
    /// doc comment it's yielded *before* the same run's terminal `.finished`/`.failed`, so surfacing
    /// it as a transient status here would just be overwritten a moment later; a `.warning` log is
    /// enough for diagnosing it after the fact.
    private func applyWatcherEvent(_ event: WatcherEvent) {
        switch event.kind {
        case .started:
            updateWatcherItem(id: event.watcherId) { $0.status = .running }
        case .finished(let renderedMarkdown, let at, let inputScope):
            updateWatcherItem(id: event.watcherId) {
                $0.renderedMarkdown = renderedMarkdown
                $0.status = .idle
                $0.lastRunAt = at
                $0.lastRunInputScope = inputScope
            }
        case .failed(let message):
            updateWatcherItem(id: event.watcherId) { $0.status = .error(message) }
        case .stateReset(let message):
            logger.warning(
                "Watcher \(event.watcherId, privacy: .public) state was reset to its initial_state: \(message, privacy: .public)"
            )
        }
    }

    // MARK: - Watchers tab (§10.2)

    /// "今すぐ実行" button. Fire-and-forget (not `async`) so the button tap returns immediately -- the
    /// `.started`/`.finished`/`.failed` badge transitions arrive via `watcherRunner.events` regardless
    /// of whether the caller awaits this call.
    func runWatcherNow(id: String) {
        let runner = watcherRunner
        Task { await runner.runManually(id: id) }
    }

    /// A Watchers-tab seg-id link's jump request (§10.4). Only sets `pendingTranscriptScrollTarget`
    /// (and switches to the 会議 tab, `docs/design/17-session-window-redesign.md` §4.5) if `id` is
    /// actually present in `transcriptRows` right now -- a stale/typo'd id from a Watcher's LLM output
    /// must not silently switch tabs to a `TranscriptTabView.scrollTo(_:)` that can never resolve.
    func jumpToTranscriptSegment(_ segId: String) {
        guard transcriptRows.contains(where: { $0.id == segId }) else {
            logger.warning(
                "Ignoring jump to transcript segment \(segId, privacy: .public): no matching row in transcriptRows."
            )
            return
        }
        activeTab = .meeting
        // §4.5: narrowed-to-サマリのみ has to widen back to `.both` so the transcript pane the jump is
        // targeting is actually on screen; `.transcript`/`.both` are already showing it, so they're
        // left untouched.
        if meetingPaneMode == .summary {
            meetingPaneMode = .both
        }
        pendingTranscriptScrollTarget = segId
        // Set together with the scroll request rather than when the scroll lands: the marker means
        // "this is the segment the Watcher cited", which is true from the moment the link was clicked.
        // The attention-grabbing flash is what `TranscriptTabView` adds on arrival.
        jumpHighlightedSegmentId = segId
    }

    // MARK: - Prep tab management (§10.3)

    /// Prep tab's per-row enable/disable checkbox. Fire-and-forget (not `async`, matching §10.1's
    /// listed signature) so the checkbox itself toggles instantly; the `enabled.yaml` write and
    /// `watcherItems` rebuild happen in the background.
    func setWatcherEnabled(id: String, enabled: Bool) {
        Task { [weak self] in
            guard let self else { return }
            var ids = (try? await self.sessionHandle.readEnabledWatchers()) ?? []
            if enabled {
                if !ids.contains(id) { ids.append(id) }
            } else {
                ids.removeAll { $0 == id }
            }
            do {
                try await self.sessionHandle.writeEnabledWatchers(ids)
            } catch {
                self.logger.error(
                    "Failed to update watchers/enabled.yaml toggling \(id, privacy: .public) to \(enabled, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
            await self.refreshWatcherItems()
        }
    }

    /// "[fork]": copies preset `id` into this session's `watchers/<id>.md` (kikimi.md 9 章 "Preset を
    /// fork"). `id` is expected to already be enabled (the fork action only appears on an
    /// already-listed preset row, §10.3) -- `enabled.yaml` itself never needs to change, since
    /// resolution already prefers session-local over preset for the same id.
    func forkPresetWatcher(id: String) async {
        do {
            try await watcherLibrary.fork(id: id, into: sessionHandle)
        } catch {
            logger.error("Failed to fork preset watcher \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        await refreshWatcherItems()
    }

    /// Whether a preset named `id` already exists -- the Prep tab's "[プリセットとして保存]" confirmation
    /// gate (§10.1: "昇格前の上書き確認判定（UI が alert を出す）"). The UI is responsible for asking the
    /// user before calling `promoteWatcherToPreset(id:)` when this returns `true`.
    func presetExists(id: String) -> Bool {
        watcherLibrary.presetText(id: id) != nil
    }

    /// "[プリセットとして保存]": writes this session-local Watcher out to the global preset library,
    /// unconditionally overwriting any existing preset under the same id (kikimi.md 9 章
    /// "Session-local Watcher の Preset への昇格"). Callers must have already confirmed the overwrite
    /// with the user when `presetExists(id:)` returned `true` -- this method itself never asks.
    func promoteWatcherToPreset(id: String) async {
        do {
            try await watcherLibrary.promote(id: id, from: sessionHandle)
        } catch {
            logger.error("Failed to promote watcher \(id, privacy: .public) to preset: \(String(describing: error), privacy: .public)")
        }
    }

    /// "[+ 新規 local watcher]": writes a minimal-but-valid scaffold to `watchers/<id>.md` and enables
    /// it, so the caller can immediately open the edit sheet on real (parseable) content. Throws
    /// `LocalWatcherCreationError` for an invalid id or an id that already has a session-local
    /// definition -- both are user input mistakes the creation sheet should surface inline, not log
    /// and swallow.
    func createLocalWatcher(id: String) async throws {
        guard Self.isValidLocalWatcherId(id) else {
            throw LocalWatcherCreationError.invalidId(id)
        }
        if (try? await sessionHandle.readText(.watcherDefinition(id: id))) != nil {
            throw LocalWatcherCreationError.alreadyExists(id)
        }
        try await sessionHandle.writeText(Self.localWatcherTemplate(id: id), to: .watcherDefinition(id: id))
        var ids = (try? await sessionHandle.readEnabledWatchers()) ?? []
        if !ids.contains(id) { ids.append(id) }
        try await sessionHandle.writeEnabledWatchers(ids)
        await refreshWatcherItems()
    }

    /// "[削除]" (local Watchers only): removes both `watchers/<id>.md` and `watchers/<id>.state.json`
    /// and drops `id` from `enabled.yaml`. Best-effort -- a failed file delete is logged, not
    /// rethrown, so a partial failure (e.g. the state file was already gone) still leaves `id`
    /// unenabled and `watcherItems` refreshed rather than stuck.
    func deleteLocalWatcher(id: String) async {
        do {
            try await sessionHandle.deleteFile(.watcherDefinition(id: id))
        } catch {
            logger.error("Failed to delete watchers/\(id, privacy: .public).md: \(String(describing: error), privacy: .public)")
        }
        do {
            try await sessionHandle.deleteFile(.watcherState(id: id))
        } catch {
            logger.error("Failed to delete watchers/\(id, privacy: .public).state.json: \(String(describing: error), privacy: .public)")
        }
        do {
            try await sessionHandle.deleteFile(.watcherRunRecord(id: id))
        } catch {
            logger.error("Failed to delete watchers/\(id, privacy: .public).run.json: \(String(describing: error), privacy: .public)")
        }
        var ids = (try? await sessionHandle.readEnabledWatchers()) ?? []
        ids.removeAll { $0 == id }
        try? await sessionHandle.writeEnabledWatchers(ids)
        await refreshWatcherItems()
    }

    /// "[+ preset から追加]" picker's candidate list: every preset id not already enabled for this
    /// session.
    func availablePresets() -> [String] {
        let enabledIds = Set(watcherItems.map(\.id))
        return watcherLibrary.listPresetIds().filter { !enabledIds.contains($0) }
    }

    /// Edit sheet's initial content: `id`'s currently-resolved definition text (session-local if it
    /// has one, else the preset), or `nil` if neither exists.
    func watcherDefinitionText(id: String) async -> String? {
        (try? await watcherLibrary.resolveDefinitionText(id: id, sessionHandle: sessionHandle))?.text
    }

    /// Edit sheet's "保存" action for a session-local Watcher. Always saves `text` as-is (§10.3: "保存
    /// 自体は許す" even for text that fails to parse -- a mid-edit save must not be blocked), then
    /// returns a human-readable parse-error message for the sheet to display inline, or `nil` if
    /// `text` parses cleanly.
    @discardableResult
    func saveLocalWatcherText(id: String, text: String) async -> String? {
        do {
            try await sessionHandle.writeText(text, to: .watcherDefinition(id: id))
        } catch {
            logger.error("Failed to save watchers/\(id, privacy: .public).md: \(String(describing: error), privacy: .public)")
            return "保存に失敗しました。"
        }
        await refreshWatcherItems()
        do {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: id, simpleWatcherTemplate: currentSimpleWatcherTemplate())
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "定義の解析に失敗しました。"
        }
    }

    // MARK: - Simple Watcher CRUD (`docs/design/34-simple-watchers.md` §6.3, §7)

    /// "簡易フォーム" create action: generates a fresh `simple-<6 hex>` id (retrying on collision),
    /// writes `SimpleWatcherSpec.fileText()` to `watchers/<id>.md`, enables it, and refreshes
    /// `watcherItems`. Throws whatever `LocalizedError`-conforming error the underlying
    /// `sessionHandle` write surfaces (§6.3: "変更系 3 API はすべて... throw する") -- the form sheet
    /// displays it inline and keeps the sheet open rather than closing on a failed save.
    func createSimpleWatcher(_ draft: SimpleWatcherSpecDraft) async throws {
        let id = await generateUniqueSimpleWatcherId()
        try await sessionHandle.writeText(draft.spec(id: id).fileText(), to: .watcherDefinition(id: id))
        var ids = (try? await sessionHandle.readEnabledWatchers()) ?? []
        if !ids.contains(id) { ids.append(id) }
        try await sessionHandle.writeEnabledWatchers(ids)
        await refreshWatcherItems()
    }

    /// "簡易フォーム" save action for an existing simple Watcher: overwrites `watchers/<id>.md` with
    /// `draft`'s `SimpleWatcherSpec.fileText()` and refreshes `watcherItems`. Unlike
    /// `createSimpleWatcher(_:)`, `id` is already enabled, so `enabled.yaml` is left untouched.
    ///
    /// `draft.model` is *not* re-derived from the existing file here -- §6.3 puts that
    /// responsibility on the caller (typically `simpleWatcherSpec(id:)`'s result, carried into the
    /// draft before the form is even shown) so a hand-authored `model:` a user never sees in the
    /// form still round-trips through an edit instead of being silently dropped.
    func updateSimpleWatcher(id: String, _ draft: SimpleWatcherSpecDraft) async throws {
        try await sessionHandle.writeText(draft.spec(id: id).fileText(), to: .watcherDefinition(id: id))
        await refreshWatcherItems()
    }

    /// The simple form's initial-value source, both for editing an existing simple Watcher and for
    /// seeding `updateSimpleWatcher(id:_:)`'s `model` carry-over (§6.3). Resolves + parses `id`'s
    /// current definition and returns its `simpleSpec`, or `nil` if `id` has no resolvable
    /// definition or isn't a `kind: simple` one (the caller shouldn't have routed here in that case,
    /// but this stays a query rather than throwing so a stale/racing call degrades quietly).
    func simpleWatcherSpec(id: String) async -> SimpleWatcherSpec? {
        guard let resolved = try? await watcherLibrary.resolveDefinitionText(id: id, sessionHandle: sessionHandle),
              let definition = try? WatcherDefinitionParser.parse(text: resolved.text, expectedId: id, simpleWatcherTemplate: currentSimpleWatcherTemplate()) else {
            return nil
        }
        return definition.simpleSpec
    }

    /// "詳細形式に変換…" (§7): one-way eject from a session-local simple Watcher to a full-format
    /// `.md`. Generates `SimpleWatcherSpec.desugaredFullText(promptTemplate:)` and round-trip-verifies
    /// it *before* touching disk -- parses the generated text and compares the result against
    /// `spec.desugar(promptTemplate:)` (ignoring `simpleSpec`, which the generated text can never
    /// carry since it has no `kind: simple`). Both failure branches throw without writing:
    /// - the generated text fails to parse at all -> `.parseFailed` (wraps the parse error's own
    ///   message so the cause -- almost always a YAML-hostile character `fileText()`'s escaping
    ///   missed -- isn't hidden)
    /// - parsing succeeds but disagrees with `desugar(promptTemplate:)` -> `.roundTripMismatch` (the
    ///   known cause is a `# `-prefixed line in the prompt colliding with the `# System`/`# User`
    ///   section split, §8.2)
    ///
    /// `template` is read once, up front, and reused for every step below
    /// (`docs/design/42-prompt-overrides.md` §4.3): `desugaredFullText`/`parse`/`desugar` must all see
    /// the *same* `simple-watcher` prompt template value, or a live `prompts/simple-watcher.md` edit
    /// racing this conversion could fail the round-trip comparison on an unrelated `systemPrompt`
    /// mismatch that has nothing to do with the `# `-prefixed-line bug it exists to catch.
    ///
    /// Only on success is `watchers/<id>.md` overwritten and `watcherItems` refreshed.
    func convertSimpleWatcherToFull(id: String) async throws {
        guard let spec = await simpleWatcherSpec(id: id) else {
            throw SimpleWatcherConversionError.parseFailed(
                detail: "Watcher \"\(id)\" は簡易形式として解決できませんでした。"
            )
        }
        let template = currentSimpleWatcherTemplate()
        let fullText = spec.desugaredFullText(promptTemplate: template)

        let parsed: WatcherDefinition
        do {
            parsed = try WatcherDefinitionParser.parse(text: fullText, expectedId: id, simpleWatcherTemplate: template)
        } catch {
            throw SimpleWatcherConversionError.parseFailed(
                detail: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            )
        }
        var parsedIgnoringSimpleSpec = parsed
        parsedIgnoringSimpleSpec.simpleSpec = nil
        var expectedIgnoringSimpleSpec = spec.desugar(promptTemplate: template)
        expectedIgnoringSimpleSpec.simpleSpec = nil
        guard parsedIgnoringSimpleSpec == expectedIgnoringSimpleSpec else {
            throw SimpleWatcherConversionError.roundTripMismatch
        }

        try await sessionHandle.writeText(fullText, to: .watcherDefinition(id: id))
        await refreshWatcherItems()
    }

    /// The `simple-watcher` prompt override's currently-active body (or the built-in default if none
    /// is active), read fresh at each call site rather than cached (`docs/design/42-prompt-overrides.md`
    /// §4.3/§5.2): a live `prompts/simple-watcher.md` edit shows up immediately in every Prep-tab
    /// parse/preview/convert path this file drives. `WatcherRunner` deliberately does *not* use this --
    /// it holds its own session-start snapshot instead, so a live recording's Watcher executions stay
    /// on the prompt-cache-friendly "System は実行間で完全固定" template for the session's duration.
    private func currentSimpleWatcherTemplate() -> String {
        PromptStore.shared.policyBody(for: .builtin(.simpleWatcher))
    }

    /// `createSimpleWatcher(_:)`'s id-uniqueness loop: keeps drawing candidates from
    /// `simpleWatcherIdGenerator` until one collides with neither a session-local definition nor a
    /// preset id (§6.2: "衝突チェックは session-local だけでなく preset（`listPresetIds()`）も含める" -- a
    /// simple id that happens to match a promoted-then-forgotten preset must not silently shadow it
    /// under the session-local-first resolution order).
    private func generateUniqueSimpleWatcherId() async -> String {
        let presetIds = Set(watcherLibrary.listPresetIds())
        while true {
            let candidate = Self.nextSimpleWatcherIdCandidate()
            if presetIds.contains(candidate) { continue }
            if (try? await sessionHandle.readText(.watcherDefinition(id: candidate))) != nil { continue }
            return candidate
        }
    }

    /// Testable seam for the `simple-<6 hex>` id `createSimpleWatcher(_:)` generates. A `@TaskLocal`
    /// (not a mutable global `static var`) specifically because swift-testing runs a suite's `@Test`s
    /// concurrently by default: a shared mutable var would let one test's scripted override leak into
    /// another test's concurrently-running call to `generateUniqueSimpleWatcherId()`, whereas a
    /// task-local is only visible within the `Task` tree that bound it (`$simpleWatcherIdGeneratorOverride
    /// .withValue(_:operation:)`), making it safe to override per-test without serializing the suite.
    /// `nil` (production's default) draws from a fresh `UUID()`; tests bind a scripted sequence to
    /// deterministically exercise `generateUniqueSimpleWatcherId()`'s collision-retry loop without
    /// depending on random UUIDs actually colliding.
    @TaskLocal
    static var simpleWatcherIdGeneratorOverride: (@Sendable () -> String)?

    private static func nextSimpleWatcherIdCandidate() -> String {
        if let override = simpleWatcherIdGeneratorOverride {
            return override()
        }
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "simple-" + hex.prefix(6)
    }

    // MARK: - Local watcher id validation / scaffold

    /// Same character rule `SessionFile`/`WatcherLibrary` enforce for a watcher id (ASCII letters,
    /// digits, hyphens only) -- kept as a private duplicate here for the same reason
    /// `WatcherLibrary.isValidWatcherId(_:)` is: this file needs it before ever touching
    /// `SessionFile`/`SessionHandle`.
    private static func isValidLocalWatcherId(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(Character(scalar)) ||
                ("A"..."Z").contains(Character(scalar)) ||
                ("0"..."9").contains(Character(scalar)) ||
                scalar == "-"
        }
    }

    /// "[+ 新規 local watcher]"'s starting-point scaffold: a minimal but fully valid Watcher
    /// definition (parses cleanly, so the edit sheet opens with no warning) that the user is expected
    /// to flesh out. `on_summary_update`/`cumulative`/`summary_and_recent` mirror the most common
    /// shape among kikimi.md 9 章's own preset examples (e.g. `pre-check`).
    private static func localWatcherTemplate(id: String) -> String {
        """
        ---
        id: \(id)
        name: \(id)
        trigger: on_summary_update
        state_mode: cumulative
        input_scope: summary_and_recent
        schema:
          note: string
        view: |
          {{note}}
        ---

        # System

        （このWatcherが会議中に追跡する観点をここに書いてください）

        # User

        【現在の state】
        {{state}}

        【直近のサマリ】
        {{summary}}

        【直近の会話】
        {{recent_segments}}

        schema に沿った更新後の JSON を返してください。
        """
    }
}
