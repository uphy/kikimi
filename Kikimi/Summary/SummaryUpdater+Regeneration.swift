import Foundation

// MARK: - SummaryUpdater + full regeneration (救済パス, docs/design/04-summary-updater.md §6)

/// Split out of `SummaryUpdater.swift` to keep that file under the project's `file_length` lint limit
/// (same rationale/pattern as `+ParticipantsMerge.swift`). Only needs `SummaryUpdater`'s
/// already-internal surface (`sessionHandle`/`llm`/`config`/`now`/`logger`/`eventsContinuation`/
/// `isRegenerating`/`segmentsSinceLastUpdate`/`lastUpdateAt`/`applyAutomaticTitle(proposal:)`/
/// `loadComposedContext()` (`docs/design/22-participant-hints.md` §9)/`promptBodyProvider`
/// (`docs/design/42-prompt-overrides.md` §4.3) -- each widened from `private` to internal in
/// `SummaryUpdater.swift` for exactly this split), not any genuinely private member of the primary
/// actor declaration.
extension SummaryUpdater {
    /// Chunk size for full regeneration (§6: "例 40 セグメントずつ複数回").
    private static let regenerationChunkSize = 40

    /// Not `private`: called from `execute(_:)` in `SummaryUpdater.swift`, across the file split.
    /// `modelOverride`: forward-looking hook for a future manual re-run UI
    /// (`docs/design/44-llm-model-config.md` §7/§8) -- `nil` (every current call site) falls back to
    /// `resolvedModel`, the same session-start snapshot the incremental/final-title flows use.
    func performRegeneration(modelOverride: ResolvedModel? = nil) async {
        isRegenerating = true
        defer { isRegenerating = false }
        let resolved = modelOverride ?? resolvedModel

        let allSegments: [SummarySegmentInput]
        do {
            allSegments = try await loadAllSegmentsSorted()
        } catch {
            logger.error("Failed to load transcript for full regeneration: \(String(describing: error), privacy: .public)")
            return
        }

        var state = SummaryState.empty
        let contextMarkdown = await loadComposedContext()

        for chunk in allSegments.chunked(into: Self.regenerationChunkSize) {
            guard !chunk.isEmpty else { continue }
            do {
                let userPrompt = try SummaryPromptBuilder.buildUserPrompt(
                    state: state,
                    segments: chunk,
                    now: now(),
                    contextMarkdown: contextMarkdown
                )
                let result: LLMResult<SummaryPatch> = try await llm.complete(
                    LLMRequest(
                        system: SummaryPromptBuilder.systemPrompt(policyBody: promptBodyProvider(.summary)),
                        user: userPrompt,
                        schema: SummaryJSONSchema.patchSchemaJSON,
                        resolved: resolved,
                        stubKey: "summary_patch"
                    )
                )
                applyPatch(result.value, to: &state)
                state.lastSummarizedStartMs = chunk.map(\.startMs).max() ?? state.lastSummarizedStartMs
            } catch {
                // §6/§9: a single chunk failing during regeneration should not abort the whole
                // operation -- skip it (state simply doesn't reflect that chunk) and continue, same
                // "録音・整形に波及させない" spirit as the incremental flow.
                logger.warning("Regeneration chunk failed, skipping it: \(String(describing: error), privacy: .public)")
                continue
            }
        }

        do {
            try await sessionHandle.writeJSON(state, to: .summaryState)
        } catch {
            logger.error("Failed to persist summary.state.json after regeneration: \(String(describing: error), privacy: .public)")
            return
        }

        let templateString = await sessionHandle.readSummaryTemplate()
        var renderedMarkdown: String?
        if let rendered = SummaryRenderer.render(state, templateString: templateString) {
            renderedMarkdown = rendered
            do {
                try await sessionHandle.writeText(rendered, to: .summaryMarkdown)
            } catch {
                logger.error("Failed to write summary.md after regeneration: \(String(describing: error), privacy: .public)")
                renderedMarkdown = nil
            }
        } else {
            logger.warning("Summary render failed after regeneration even with the default template; keeping the previous summary.md.")
        }

        // §4.1.1: bring the incremental cursor up to date with the freshly-regenerated state so the
        // next incremental trigger picks up only what's genuinely new.
        segmentsSinceLastUpdate = 0
        lastUpdateAt = now()

        logger.info("Full summary regeneration completed (\(allSegments.count, privacy: .public) segments).")

        let metaChanged = await applyAutomaticTitle(proposal: state.title)
        eventsContinuation.yield(SummaryUpdateEvent(summaryMarkdown: renderedMarkdown, metaChanged: metaChanged))
    }

    /// Full transcript (refined preferred), `startMs` ascending, no cursor filtering. Used by
    /// `performRegeneration()` (§6) and, since `summary-quality-topics-and-final-pass.md` §7.2,
    /// shared with `+FinalPass.swift`'s `performFinalPass(modelOverride:)`. Not `private` for that
    /// reason (was `private` before the final pass needed it too).
    func loadAllSegmentsSorted() async throws -> [SummarySegmentInput] {
        let transcriptSegments = try await sessionHandle.readTranscriptSegments()
        let refinedSegments = try await sessionHandle.readRefinedSegments()
        // §15.2.5: same `sourceSegIds`-expansion + last-wins robustness as `loadPendingInput()`
        // above (03-refinement-batch.md §3.2 "防御の二重化").
        let refinedById = refinedSegments.indexedBySourceSegId()

        return transcriptSegments.compactMap { transcript in
            if let refined = refinedById[transcript.id], let refinedText = refined.refinedText {
                // Same drop rule as `loadPendingInput()`: empty refined text = segment judged
                // meaningless by refinement, excluded from summary input.
                guard !refinedText.isEmpty else { return nil }
                return SummarySegmentInput(id: transcript.id, startMs: transcript.startMs, speaker: transcript.speaker, text: refinedText)
            }
            return SummarySegmentInput(id: transcript.id, startMs: transcript.startMs, speaker: transcript.speaker, text: transcript.text)
        }.sorted { $0.startMs < $1.startMs }
    }
}
