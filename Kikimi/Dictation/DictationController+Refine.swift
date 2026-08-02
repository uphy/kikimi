import Foundation

// MARK: - DictationController refinement (`docs/design/25-dictation-mode.md` D2, design 29 §3.2)

/// The refine-and-derive-history-fields half of `DictationController`'s key-up tail, split out of
/// `DictationController.swift` once the HUD processing-phase wiring
/// (`docs/design/32-dictation-hud-refining-visibility.md`) pushed that file past SwiftLint's
/// 600-line file-length limit -- the same reason `DictationController+History.swift` exists. Same
/// `@MainActor` type, only the file boundary changed (which is why the stored properties these
/// methods consume -- `refiner` and the provider closures -- are `internal` on the main
/// declaration, mirroring `historyEntryHandle` and friends).
extension DictationController {
    /// `entry.json`'s refinement-related fields for one utterance
    /// (`docs/design/29-dictation-history.md` §3.2), computed alongside `finalText` so the two can
    /// never disagree about what actually happened (in particular the invariant "`outcome ==
    /// .success` => `finalText` is the refined text"). `internal` for
    /// `DictationController+History.swift`'s `finalizeHistoryEntryIfNeeded` (see `historyEntryHandle`).
    struct DictationRefineHistoryFields {
        var finalText: String
        var outcome: DictationHistoryRefineOutcome
        var error: String?
        var llmUsage: LLMUsageRecord?
    }

    /// Runs `DictationRefiner.refine` (only when `config.refine`) and derives both `finalText`
    /// (D1/D2's existing behavior, unchanged) and this utterance's history bookkeeping in the one
    /// place that reads `DictationRefineOutcome`, rather than duplicating the "was this a success,
    /// a fallback, or an empty-refinement fallback" branching at every caller.
    func refineForHistory(
        rawText: String,
        config: DictationConfig,
        capturedTarget: FrontmostGuard.Target
    ) async -> DictationRefineHistoryFields {
        guard config.refine else {
            return DictationRefineHistoryFields(finalText: rawText, outcome: .disabled, error: nil, llmUsage: nil)
        }

        markRefining()
        let resolvedModel = DictationRefiner.resolveModel(
            dictationModel: config.model,
            watchersDefaultModel: watchersDefaultModelProvider(),
            config: AppConfig.shared.data.llm,
            availableProviders: LLMClient.shared.availableProviders
        )

        // `docs/design/42-prompt-overrides.md` §7.2: the frontmost-app -> `dictation/apps/<bundle-id>`
        // match happens here (controller side), not inside `DictationContextResolver` -- exact match
        // only (R14), first (and only, ids are unique file names) hit wins.
        let matchedAppBundleID = capturedTarget.bundleId.flatMap { bundleId in
            dictationAppBundleIDsProvider().first { $0 == bundleId }
        }
        let resolvedContext = DictationContextResolver.resolve(
            globalBody: dictationGlobalBodyProvider(),
            appBody: matchedAppBundleID.map(dictationAppBodyProvider),
            glossary: glossaryProvider(),
            glossaryCategories: glossaryCategoriesProvider(),
            glossaryHeader: dictationGlossaryHeaderProvider()
        )
        let refineOutcome = await refiner.refine(
            rawText: rawText,
            resolvedModel: resolvedModel,
            timeoutMs: config.refineTimeoutMs,
            resolvedContext: resolvedContext
        )
        let trimmedRefined = refineOutcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = trimmedRefined.isEmpty ? rawText : trimmedRefined

        guard refineOutcome.succeeded else {
            return DictationRefineHistoryFields(finalText: finalText, outcome: .fallback, error: refineOutcome.failure, llmUsage: nil)
        }

        let llmUsage = refineOutcome.usage.map {
            LLMUsageRecord.make(
                usage: $0,
                respondedModel: refineOutcome.model,
                requestedModel: resolvedModel.model,
                purpose: "dictation",
                timestamp: Date(),
                provider: resolvedModel.provider
            )
        }
        guard trimmedRefined.isEmpty else {
            return DictationRefineHistoryFields(finalText: finalText, outcome: .success, error: nil, llmUsage: llmUsage)
        }
        // §3.2's "empty refinement": the LLM call succeeded but trimmed to the empty string, so
        // `finalText` fell back to `rawText` above -- recorded as `.fallback` (not `.success`,
        // preserving the "success => finalText == refinedText" invariant), with a distinct
        // `refine_error` reason. The call did succeed and cost tokens, so `llmUsage` stays populated.
        return DictationRefineHistoryFields(finalText: finalText, outcome: .fallback, error: "empty refinement", llmUsage: llmUsage)
    }
}
