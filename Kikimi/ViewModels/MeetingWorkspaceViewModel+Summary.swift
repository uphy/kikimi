import Foundation

// MARK: - MeetingWorkspaceViewModel + Summary tab / automatic title (`docs/design/04-summary-updater.md`
// section 7)

/// Split into its own file (alongside `MeetingWorkspaceViewModel.swift`'s other extensions, e.g.
/// `+Prep.swift`/`+AudioInput.swift`) to keep that file under the project's `file_length` lint limit.
/// Owns the `SummaryUpdater` lifecycle (created when a recording segment starts, flushed and torn
/// down when it closes), the `events` subscription that pushes `summaryMarkdown`/`meta` updates to
/// the UI, and the three user-facing operations the Summary tab / header proposal badge call.
extension MeetingWorkspaceViewModel {
    // MARK: - Lifecycle (section 4.1: created on Recording start, torn down on Paused/Ended)

    /// Called from `runRecordingSegmentStart(previousStateOnFailure:)` once a recording segment has
    /// actually started. A no-op if a `summaryUpdater` already exists (defensive; every code path that
    /// tears one down also nils it out first, so this should always create a fresh instance in
    /// practice -- each new recording segment gets its own `SummaryUpdater` actor, with continuity
    /// carried by the file-backed `summary.state.json` cursor rather than in-memory actor state).
    func startSummaryUpdaterIfNeeded() {
        guard summaryUpdater == nil else { return }

        let updater = summaryUpdaterFactory(sessionHandle)
        summaryUpdater = updater

        // Section 5.1: seed the Summary tab with whatever summary.md already exists on disk (e.g. a
        // prior recording segment's last render) so the tab isn't blank until the next update fires.
        // Only on a genuinely fresh display (nothing shown yet) -- a resumed session already has
        // `summaryMarkdown` populated from its own earlier updates in this window's lifetime.
        if summaryMarkdown == nil {
            Task { [weak self] in
                guard let self else { return }
                if let onDisk = try? await self.sessionHandle.readText(.summaryMarkdown), !onDisk.isEmpty {
                    self.summaryMarkdown = onDisk
                }
            }
        }

        summaryEventsTask = Task { [weak self] in
            for await event in updater.events {
                guard let self else { return }
                if let markdown = event.summaryMarkdown {
                    self.summaryMarkdown = markdown
                    // `docs/design/17-session-window-redesign.md` §4.4/§4.5: mark the update as
                    // "unseen" only while the Summary pane genuinely isn't on screen right now (not on
                    // the 会議 tab at all, or narrowed to 書き起こしのみ). `updateSummaryUnseenVisibility()`
                    // clears this the moment the pane becomes visible again.
                    if self.activeTab != .meeting || self.meetingPaneMode == .transcript {
                        self.summaryHasUnseenUpdate = true
                    }
                }
                if event.metaChanged {
                    self.meta = await self.sessionHandle.meta
                }
                // `docs/design/05-watcher-runner.md` §9.4: fire-and-forget so a slow/backlogged
                // Watcher run never delays the next summary update. Restricted to events that
                // actually re-rendered `summary.md` (`event.summaryMarkdown != nil`) -- a title-only
                // proposal event (§8's once-only auto-naming / final-title generation) must not
                // trigger `on_summary_update` Watchers.
                if event.summaryMarkdown != nil {
                    let runner = self.watcherRunner
                    Task { await runner.run(trigger: .onSummaryUpdate) }
                }
            }
        }
    }

    /// Cancels the `events` subscription and drops the `SummaryUpdater` reference. Callers are
    /// responsible for having already awaited any final flush/title-proposal call on `summaryUpdater`
    /// before calling this (section 4.1: the actor itself is discarded, not merely paused).
    func stopSummaryUpdater() {
        summaryEventsTask?.cancel()
        summaryEventsTask = nil
        summaryUpdater = nil
    }

    // MARK: - Session Window redesign (`docs/design/17-session-window-redesign.md` §4.4). Moved here
    // (rather than staying in `MeetingWorkspaceViewModel.swift` itself) purely to keep that file under
    // the project's `file_length` lint limit -- `isDraft`/`updateSummaryUnseenVisibility()` have no
    // other tie to Summary specifically beyond `updateSummaryUnseenVisibility()` already living
    // alongside the `summaryHasUnseenUpdate`-setting code above.

    /// `true` while this session has never been recorded (`meta.state == .draft`). Drives
    /// `MeetingWorkspaceView`'s dedicated Draft-only preparation screen (§3.1/§5.1) instead of the
    /// 3-tab `TabView` shown in every other state.
    var isDraft: Bool { meta.state == .draft }

    /// Clears `summaryHasUnseenUpdate` the moment the Summary pane becomes visible again (§4.4/§4.5's
    /// "サマリペインが可視になった時（タブ切替 or ペインモード変更）... クリア"), called from
    /// `MeetingWorkspaceViewModel.swift`'s `activeTab`/`meetingPaneMode` `didSet` (not `private`, since
    /// a cross-file `didSet` call needs at least internal visibility). Never *sets* the flag -- only
    /// `startSummaryUpdaterIfNeeded()`'s `SummaryUpdater.events` subscription above does that, when a
    /// fresh `summaryMarkdown` arrives while the pane is invisible.
    func updateSummaryUnseenVisibility() {
        guard summaryHasUnseenUpdate else { return }
        if activeTab == .meeting && meetingPaneMode != .transcript {
            summaryHasUnseenUpdate = false
        }
    }

    // MARK: - Public operations (section 7)

    /// Header's "新しいタイトル案: XX [採用]" badge action (section 3.2). Replaces `meta.title` with
    /// the current `meta.titleProposal` and clears the proposal, inside a single `updateMeta` closure
    /// so this can never race a concurrent `SummaryUpdater` title write (section 3.1's atomicity
    /// requirement). `titleAutoGenerated` is left untouched (stays `true`): adopting a proposal is
    /// still part of the automatic-naming lineage, unlike a manual `renameTitle(_:)`.
    func adoptTitleProposal() async {
        do {
            try await sessionHandle.updateMeta { meta in
                guard let proposal = meta.titleProposal else { return }
                meta.title = proposal
                meta.titleProposal = nil
            }
            meta = await sessionHandle.meta
        } catch {
            logger.error(
                "Failed to adopt title proposal for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Summary tab's manual "更新" button -> `SummaryUpdater.updateNow(.manual)`. A silent no-op if no
    /// updater is live (not Recording), matching `noteSegmentAppended()`'s own silent-no-op shape
    /// below -- this button is only ever shown while Recording (section 7).
    func requestSummaryUpdateNow() async {
        await summaryUpdater?.updateNow(reason: .manual)
    }

    /// Summary tab's "サマリ全文再生成" button (section 6's 救済パス). Works whether or not a
    /// `SummaryUpdater` is currently live: while Recording, reuses the live instance so its in-memory
    /// trigger bookkeeping (`segmentsSinceLastUpdate`/cursor) stays consistent; once Paused/Ended (no
    /// live updater), spins up a transient instance just for this one call -- `regenerateFromScratch()`
    /// rebuilds `summary.state.json` entirely from the file-backed transcript, so no continuity is lost
    /// by using a throwaway actor (section 6: "Recording 中でも Ended 後でも呼べる"). Rather than
    /// juggling a second `events` subscription for the transient case, this simply re-reads
    /// `summary.md`/`meta` from disk after the call completes -- `regenerateFromScratch()` has already
    /// persisted both by the time it returns (`SummaryUpdater.performRegeneration()`).
    ///
    /// - Parameter modelOverride: The regenerate menu's manual override
    ///   (`docs/design/44-llm-model-config.md` §8), resolved by the caller at click time (`nil` for
    ///   "既定で実行" -- `SummaryUpdater.performRegeneration(modelOverride:)` then falls back to
    ///   `resolvedModel`, the session-start snapshot, exactly as before this parameter existed).
    func regenerateSummary(modelOverride: ResolvedModel? = nil) async {
        let updater = summaryUpdater ?? summaryUpdaterFactory(sessionHandle)
        await updater.regenerateFromScratch(modelOverride: modelOverride)
        summaryMarkdown = (try? await sessionHandle.readText(.summaryMarkdown)) ?? summaryMarkdown
        meta = await sessionHandle.meta
    }

    /// Ended-only Summary tab's "最終整形を再実行" button (`docs/design/44-llm-model-config.md` §8).
    /// Same shape as `regenerateSummary(modelOverride:)` above -- reuse the live updater if one somehow
    /// exists (defensive; never true while genuinely Ended, since `stopSummaryUpdater()` already ran),
    /// otherwise spin up a transient one from `sessionHandle` alone. That is also what makes this work
    /// for an Ended session reopened after an app restart, with no live `MeetingWorkspaceViewModel`
    /// history at all: `summaryUpdaterFactory(sessionHandle)` only ever needs the `SessionHandle`
    /// this instance was constructed with (`+Factories.swift`'s `defaultSummaryUpdaterFactory`
    /// reads `AppConfig`/`LLMClient.shared` fresh, not anything cached from a prior recording segment)
    /// -- §8's "実装量の大半" is precisely that this needed no new construction path at all, only
    /// reusing the one `endMeeting()`'s Paused → Ended branch already established
    /// (`+Recording.swift`).
    ///
    /// `runFinalPass(modelOverride:)` never throws (§8's "失敗は warn + 既存サマリ維持" is handled
    /// entirely inside `SummaryUpdater.performFinalPass(modelOverride:)`), so there is nothing here to
    /// catch -- a failed LLM call simply leaves `summary.md` exactly as it was, which the re-read below
    /// then reflects unchanged.
    func rerunFinalPass(modelOverride: ResolvedModel? = nil) async {
        let updater = summaryUpdater ?? summaryUpdaterFactory(sessionHandle)
        await updater.runFinalPass(modelOverride: modelOverride)
        summaryMarkdown = (try? await sessionHandle.readText(.summaryMarkdown)) ?? summaryMarkdown
        meta = await sessionHandle.meta
    }

    // MARK: - Manual-override menu display (`docs/design/44-llm-model-config.md` §8)

    /// The manual-override menu's "既定" model name for whichever `SummaryUpdater` a `nil` override
    /// will actually run against right now -- the live instance's `resolvedModel` while Recording (a
    /// genuine session-start snapshot, fixed when this recording segment began), or a fresh transient
    /// instance's otherwise (`regenerateSummary(modelOverride: nil)` is about to build exactly this
    /// same transient instance itself; `SummaryUpdater.init` does no I/O, so reading a throwaway
    /// instance's `resolvedModel` here has no side effect beyond the allocation). §8 explicitly wants
    /// this to reflect "what a `nil` override actually uses", never a fresh `ModelResolver.resolve`
    /// call independent of the updater that is about to run.
    var summaryDefaultModelLabel: String {
        (summaryUpdater ?? summaryUpdaterFactory(sessionHandle)).resolvedModel.model
    }

    /// Same shape as `summaryDefaultModelLabel` above, for the Ended-only final-pass re-run button.
    var summaryFinalPassDefaultModelLabel: String {
        (summaryUpdater ?? summaryUpdaterFactory(sessionHandle)).resolvedFinalModel.model
    }

    // MARK: - Title (kikimi.md 8 章 "自動タイトル命名"). Moved here from `MeetingWorkspaceViewModel.swift`
    // itself purely to keep that file under the project's `file_length` lint limit -- this sits
    // beside `adoptTitleProposal()` above, the other half of the same "自動タイトル命名" feature.

    /// User-driven manual rename. Fixes `titleAutoGenerated = false` so future summary-update title
    /// proposals no longer auto-apply or surface a proposal badge (kikimi.md 8 章).
    func renameTitle(_ newTitle: String) async {
        do {
            try await sessionHandle.updateMeta { meta in
                meta.title = newTitle
                meta.titleAutoGenerated = false
            }
            meta = await sessionHandle.meta
        } catch {
            logger.error(
                "Failed to rename session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
