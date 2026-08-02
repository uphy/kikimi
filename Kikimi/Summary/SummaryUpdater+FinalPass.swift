import Foundation

// MARK: - SummaryUpdater + §7 session-end final refinement pass
// (`docs/design/summary-quality-topics-and-final-pass.md`)

/// Split out of `SummaryUpdater.swift` to keep that file under the project's `file_length` lint
/// limit (mirrors `+FinalTitle.swift`/`+Regeneration.swift`/`+ParticipantsMerge.swift`'s own
/// splits). Only needs `SummaryUpdater`'s already-`internal` surface (`sessionHandle`/`llm`/
/// `config`/`logger`/`eventsContinuation`/`promptBodyProvider`/`loadComposedContext()`/
/// `readSanitizedSummaryState()`/`loadAllSegmentsSorted()`/`runSerialized(kind:)`/`RequestKind`
/// -- the last five added to `SummaryUpdater.swift` for exactly this feature -- not any genuinely
/// `private` member of the primary actor declaration.
extension SummaryUpdater {
    // MARK: Paired constants (§7.4/§7.5)

    /// LLM call timeout for `performFinalPass(modelOverride:)`'s single full-transcript call
    /// (§7.5). The default `LLMRequest.timeout` (60s, `Kikimi/LLM/LLMTypes.swift`) is sized for
    /// incremental updates and is insufficient for a `SummaryPromptBuilder
    /// .finalPassMaxTranscriptChars`-sized transcript block plus the full overview/decisions/
    /// action_items structured-output response.
    ///
    /// Paired with `SummaryPromptBuilder.finalPassMaxTranscriptChars` (150_000,
    /// `Kikimi/Summary/SummaryPromptBuilder.swift`) per §7.5's "同じファイルに隣接して定義しコメントで
    /// 相互参照" -- since the two constants can't literally live in the same file (this one is
    /// consumed by this LLM-calling `SummaryUpdater` extension, that one by the pure prompt
    /// builder), this doc comment is the cross-reference; that constant's doc comment points back
    /// here. Raising the transcript budget requires raising this timeout too, and vice versa.
    static let finalPassTimeout: Duration = .seconds(300)

    // MARK: Public entry point (§7.5)

    /// Session-end final refinement pass: rewrites `overview`/`decisions`/`actionItems` from a
    /// whole-meeting view in a single LLM call (§7.1). Awaitable. `modelOverride` is a hook for a
    /// future manual re-run UI (`docs/design/44-llm-model-config.md` §7/§8) -- every current call
    /// site passes `nil`, which resolves to `resolvedFinalModel`
    /// (`ModelResolver.resolve(candidates: [config.finalModel, config.model], ...)`, session-start
    /// snapshotted).
    ///
    /// Goes through the same `runSerialized(kind:)` in-flight gate as every other request kind
    /// (§4.1.1), so this never races an incremental update/regeneration/title proposal/
    /// participants merge over `summary.state.json`.
    func runFinalPass(modelOverride: ResolvedModel? = nil) async {
        await runSerialized(kind: .finalPass(modelOverride: modelOverride))
    }

    // MARK: Implementation (§7.5's numbered flow)

    /// Not `private`: called from `execute(_:)` in `SummaryUpdater.swift`, across the file split
    /// (mirrors `performFinalTitleProposal()`/`performRegeneration()`/`performParticipantsMerge(_:)`).
    func performFinalPass(modelOverride: ResolvedModel? = nil) async {
        // (1) State is read fresh, sanitized, and defaults to `.empty` if it cannot be read at all
        // (missing file or a corrupt/undecodable one) -- a final pass with nothing to revise from
        // should still be able to produce a first-ever overview rather than aborting.
        var priorState: SummaryState
        do {
            priorState = try await readSanitizedSummaryState()
        } catch {
            logger.warning("Failed to read summary.state.json for final pass, treating as empty: \(String(describing: error), privacy: .public)")
            priorState = .empty
        }

        // (2) Full transcript (refined preferred, raw fallback), startMs ascending, no cursor
        // filtering -- unlike the incremental flow, this pass always considers the whole meeting
        // (§7.2). An empty session has nothing to revise, so skip without ever calling the LLM.
        let segments: [SummarySegmentInput]
        do {
            segments = try await loadAllSegmentsSorted()
        } catch {
            logger.error("Failed to load transcript for final pass: \(String(describing: error), privacy: .public)")
            return
        }
        guard !segments.isEmpty else {
            logger.debug("No segments to finalize; skipping the final pass.")
            return
        }

        // (3) Build the prompt and call the LLM with the model override (if any) and the extended
        // 300s timeout above -- the default 60s is sized for incremental calls, not a whole-meeting
        // transcript.
        let contextMarkdown = await loadComposedContext()
        let userPrompt: String
        do {
            userPrompt = try SummaryPromptBuilder.buildFinalRevisionUserPrompt(
                state: priorState,
                segments: segments,
                contextMarkdown: contextMarkdown
            )
        } catch {
            logger.error("Failed to build final-pass prompt: \(String(describing: error), privacy: .public)")
            return
        }

        let revision: SummaryFinalRevision
        do {
            let result: LLMResult<SummaryFinalRevision> = try await llm.complete(
                LLMRequest(
                    system: Self.finalRevisionSystemPrompt(policyBody: promptBodyProvider(.summaryFinal)),
                    user: userPrompt,
                    schema: SummaryJSONSchema.finalRevisionSchemaJSON,
                    resolved: modelOverride ?? resolvedFinalModel,
                    functionDefaultSeconds: Int(Self.finalPassTimeout.components.seconds),
                    stubKey: "summary_final"
                )
            )
            revision = result.value
        } catch {
            // (4) §8's failure mode table: warn and skip entirely on LLM failure (CLI missing,
            // auth, timeout, malformed JSON, ...). The incremental state/summary.md already on disk
            // remain the final artifact; `endMeeting()` continues regardless.
            logger.warning("Final-pass LLM call failed, skipping: \(String(describing: error), privacy: .public)")
            return
        }

        // (5) Wholesale-replace overview/decisions/actionItems; `applyFinalRevision` itself guards
        // against an effectively-empty revision wiping non-empty existing content (§7.3), and never
        // touches title/participants/topics/lastSummarizedStartMs (§7.2).
        var updatedState = priorState
        applyFinalRevision(revision, to: &updatedState)

        // (6) Persist + re-render, same fallback shape as the incremental/regeneration flows: a
        // write failure aborts before any event fires (state on disk is left exactly as it was); a
        // render failure keeps the previous summary.md on disk but still lets the (title-less) event
        // below fire so callers know the pass ran.
        do {
            try await sessionHandle.writeJSON(updatedState, to: .summaryState)
        } catch {
            logger.error("Failed to persist summary.state.json after final pass: \(String(describing: error), privacy: .public)")
            return
        }

        let templateString = await sessionHandle.readSummaryTemplate()
        var renderedMarkdown: String?
        if let rendered = SummaryRenderer.render(updatedState, templateString: templateString) {
            renderedMarkdown = rendered
            do {
                try await sessionHandle.writeText(rendered, to: .summaryMarkdown)
            } catch {
                logger.error("Failed to write summary.md after final pass: \(String(describing: error), privacy: .public)")
                renderedMarkdown = nil
            }
        } else {
            logger.warning("Summary render failed after final pass even with the default template; keeping the previous summary.md.")
        }

        logger.info("Final pass completed (\(segments.count, privacy: .public) segments).")

        // (7) `lastSummarizedStartMs` is deliberately left untouched (`updatedState` carries
        // `priorState`'s cursor forward unchanged) so a post-Ended reopen's incremental cursor stays
        // intact. `metaChanged` is always `false`: this pass never writes `meta.json` (title is the
        // final-title proposal's job, §7.6).
        eventsContinuation.yield(SummaryUpdateEvent(summaryMarkdown: renderedMarkdown, metaChanged: false))
    }

    // MARK: System prompt (§7.4's contract layer)

    /// Fixed structural rules the app affixes to the policy-layer body
    /// (`PromptSpec.summaryFinalDefaultBody`'s own doc comment calls this out as "app-owned, not in
    /// this string"). Analogous to `SummaryPromptBuilder.patchContract` for the incremental
    /// `.summary` prompt, but distinct: this pass returns a wholesale replacement, not a patch, and
    /// never returns ids (the app renumbers `dc_00N`/`ai_00N` on apply, `applyFinalRevision(_:to:)`
    /// in `SummaryPatchApplier.swift`). Not `private` (unlike every other member in this file): also
    /// used by `PromptCLI.renderedSystemPrompt(for:policyBody:glossaryHeaderBody:)`'s `--render-prompt
    /// .summaryFinal` case, which needs the same contract layer applied for a faithful preview
    /// (`docs/design/42-prompt-overrides.md` §6.2's "ランタイムと同じ組み立て関数を通す").
    static let finalRevisionContract = """
    - 出力は overview / decisions / action_items のすべてを含む JSON
    - decisions / action_items に id は含めない（アプリが dc_001 / ai_001 から採番し直す）
    """

    static func finalRevisionSystemPrompt(policyBody: String) -> String {
        policyBody + "\n\n【出力契約】\n" + finalRevisionContract
    }
}
