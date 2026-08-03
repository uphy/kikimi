import Foundation

// MARK: - SummaryUpdater + participants merge (docs/design/13-speaker-diarization.md §6.2, "R2 module 4")

/// Split out of `SummaryUpdater.swift` to keep that file under the project's `file_length` lint limit
/// (mirrors `RealtimeDiarizationCoordinator+Voiceprint.swift`'s/`MeetingWorkspaceViewModel
/// +DiarizationEnded.swift`'s own file-length splits). Only needs `SummaryUpdater`'s already-`internal`
/// surface (`sessionHandle`/`logger`/`eventsContinuation`/`runSerialized(kind:)`/`RequestKind` -- see
/// each one's own "Not `private`: ... `+ParticipantsMerge.swift`" doc comment in `SummaryUpdater.swift`,
/// plus `readSanitizedSummaryState()` per `summary-quality-topics-and-final-pass.md` §2.3), not any
/// genuinely `private` member of the primary actor declaration.
extension SummaryUpdater {
    /// `docs/design/13-speaker-diarization.md` section 6.2 ("R2 module 4"): the sole sanctioned way
    /// any caller outside this actor may add names to `summary.state.json`'s `participants` --
    /// merges `names` in with the same exact-match, append_only dedup `SummaryPatchApplier
    /// .swift`'s `applyParticipants` already gives LLM-proposed participants (routed through the
    /// very same `applyPatch(_:to:)` pure function, wrapped in a `SummaryPatch` whose every other
    /// field is `nil`), then re-renders `summary.md`. A plain read-modify-write of
    /// `summary.state.json` from outside this actor would race an in-flight incremental update or
    /// regeneration writing the same file (design 6.2: "独立書き込みは lost update を起こす") -- going
    /// through `runSerialized(kind:)` here closes that race the same way every other public entry
    /// point in `SummaryUpdater.swift` does. Awaitable, like `updateNow(reason:)`/
    /// `generateFinalTitleProposal()`, so a caller (`MeetingWorkspaceViewModel`'s Ended-time hook /
    /// post-Ended rename hook, `+DiarizationEnded.swift`) can know the merge (and its `summary.md`
    /// re-render) has actually completed before moving on.
    func mergeParticipants(_ names: [String]) async {
        await runSerialized(kind: .participantsMerge(names))
    }

    /// Reads the current `summary.state.json` (or `.empty` if none exists yet -- a Draft/short
    /// session with no summary update ever run can still reach Ended and have diarization-named
    /// speakers to merge), folds `names` in via `applyPatch(_:to:)`/`SummaryPatch.participantsAdd`
    /// (the exact same append_only, exact-match-dedup path an LLM patch's own `participants_add`
    /// already goes through -- `SummaryPatchApplier.swift`'s `applyParticipants`), writes the result
    /// back, and re-renders `summary.md`. Deliberately does **not** touch `lastSummarizedStartMs`:
    /// this merge is not driven by newly-summarized transcript segments, so the incremental cursor
    /// must stay exactly where the last real summary update (or full regeneration) left it -- an
    /// unrelated later `noteSegmentAppended()` threshold trigger must still see the correct "未反映
    /// 分" starting point.
    ///
    /// A no-op (no write, no render, no event) when every name in `names` was already present --
    /// `applyParticipants`'s dedup is silent, not an error, and there is nothing new to persist or
    /// notify about (design 6.2's dedup rule; mirrors `performIncrementalUpdate`'s own "nothing to do"
    /// early-return for empty pending input).
    ///
    /// Not `private` (unlike `SummaryUpdater.swift`'s other `perform*` methods): called from
    /// `execute(_:)` in `SummaryUpdater.swift`, across the file split.
    func performParticipantsMerge(_ names: [String]) async {
        guard !names.isEmpty else { return }

        let priorState: SummaryState
        do {
            priorState = try await readSanitizedSummaryState()
        } catch {
            logger.error("Failed to read summary.state.json for a participants merge: \(String(describing: error), privacy: .public)")
            return
        }

        var updatedState = priorState
        applyPatch(SummaryPatch(participantsAdd: names), to: &updatedState)

        guard updatedState.participants != priorState.participants else {
            logger.debug("participants merge: every name already present, nothing to persist.")
            return
        }

        do {
            try await sessionHandle.writeJSON(updatedState, to: .summaryState)
        } catch {
            logger.error("Failed to persist summary.state.json after a participants merge: \(String(describing: error), privacy: .public)")
            return
        }

        let templateString = await sessionHandle.readSummaryTemplate()
        var renderedMarkdown: SummaryMarkdown?
        if let rendered = SummaryRenderer.render(updatedState, templateString: templateString) {
            renderedMarkdown = rendered
            do {
                try await sessionHandle.writeText(rendered.joined, to: .summaryMarkdown)
            } catch {
                logger.error("Failed to write summary.md after a participants merge: \(String(describing: error), privacy: .public)")
                renderedMarkdown = nil
            }
        } else {
            logger.warning("Summary render failed after a participants merge even with the default template; keeping the previous summary.md.")
        }

        logger.info("Merged \(names.count, privacy: .public) diarization-named participant(s) into summary.state.json.")
        eventsContinuation.yield(SummaryUpdateEvent(summaryMarkdown: renderedMarkdown, metaChanged: false))
    }
}
