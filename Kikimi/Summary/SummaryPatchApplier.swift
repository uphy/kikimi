import Foundation
import OSLog

// MARK: - applyPatch

private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SummaryPatchApplier")

/// Folds a `SummaryPatch` into a `SummaryState`, in place. Pure function -- no I/O, no `Date()`,
/// deterministic given its inputs -- so it is the primary unit-test target
/// (`docs/design/04-summary-updater.md` §2.3, kikimi.md 8 章「セクションごとの patch 戦略」).
///
/// Robustness-first (04-summary-updater.md §2.3): LLM output drift (unknown ids passed to
/// modify/complete, duplicate decisions/action items, id collisions on add) is absorbed by
/// "壊さず無視 or リネーム" rather than thrown as an error.
///
/// - Note: This does **not** update `state.lastSummarizedStartMs`; the caller (`SummaryUpdater`,
///   out of scope here) advances that cursor separately once it knows the max `startMs` of the
///   segments that produced this patch (04-summary-updater.md §2.3's closing note).
func applyPatch(_ patch: SummaryPatch, to state: inout SummaryState) {
    applyTitle(patch.title, to: &state)
    applyParticipants(patch.participantsAdd, to: &state)
    applyOverview(patch.overview, to: &state)
    applyDecisions(patch.decisionsAdd, to: &state)
    applyActionItems(patch.actionItems, to: &state)
}

// MARK: - title (cumulative)

private func applyTitle(_ title: String?, to state: inout SummaryState) {
    guard let title, !title.isEmpty else { return }
    state.title = title
}

// MARK: - participants (append_only, de-duplicated)

private func applyParticipants(_ participantsAdd: [String]?, to state: inout SummaryState) {
    guard let participantsAdd else { return }
    var seen = Set(state.participants)
    for participant in participantsAdd where !seen.contains(participant) {
        state.participants.append(participant)
        seen.insert(participant)
    }
}

// MARK: - overview (snapshot)

private func applyOverview(_ overview: String?, to state: inout SummaryState) {
    guard let overview else { return }
    state.overview = overview
}

// MARK: - decisions (append_only, de-duplicated by normalized text)

private func applyDecisions(_ decisionsAdd: [SummaryState.Decision]?, to state: inout SummaryState) {
    guard let decisionsAdd else { return }
    var existingNormalizedTexts = Set(state.decisions.map(normalizedDecisionText))
    for decision in decisionsAdd {
        let normalized = normalizedDecisionText(decision)
        guard !existingNormalizedTexts.contains(normalized) else {
            logger.debug("dropping duplicate decision (already present): \(decision.text, privacy: .public)")
            continue
        }
        state.decisions.append(decision)
        existingNormalizedTexts.insert(normalized)
    }
}

/// Normalizes a decision's `text` for duplicate detection: trims whitespace/newlines and
/// lowercases, so trivial LLM rewording (extra whitespace, case) doesn't re-add the same decision
/// (04-summary-updater.md §2.3: "既存 decisions の text と（正規化した上で）一致するものは重複として捨てる").
private func normalizedDecisionText(_ decision: SummaryState.Decision) -> String {
    decision.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

// MARK: - action items (add / modify / complete)

private func applyActionItems(_ patch: SummaryPatch.ActionItemPatch?, to state: inout SummaryState) {
    guard let patch else { return }
    applyActionItemAdds(patch.add, to: &state)
    applyActionItemModifies(patch.modify, to: &state)
    applyActionItemCompletes(patch.complete, to: &state)
}

/// Appends new action items, renaming on id collision rather than trusting the LLM's own
/// numbering (04-summary-updater.md §2.3: "id 衝突時は Kikimi 側でリネーム（`ai_00N` を採り直す）").
private func applyActionItemAdds(_ adds: [SummaryState.ActionItem]?, to state: inout SummaryState) {
    guard let adds else { return }
    var usedIds = Set(state.actionItems.map(\.id))
    for var item in adds {
        if usedIds.contains(item.id) {
            let renamedId = nextAvailableActionItemId(usedIds: usedIds)
            logger.warning(
                "action item id collision on add: \(item.id, privacy: .public) already exists, renaming to \(renamedId, privacy: .public)"
            )
            item.id = renamedId
        }
        usedIds.insert(item.id)
        state.actionItems.append(item)
    }
}

/// Finds the next unused `ai_00N` id (04-summary-updater.md §2.3), scanning upward from 1 so
/// renames stay deterministic across repeated collisions within the same patch.
private func nextAvailableActionItemId(usedIds: Set<String>) -> String {
    var candidateNumber = 1
    while usedIds.contains(actionItemId(candidateNumber)) {
        candidateNumber += 1
    }
    return actionItemId(candidateNumber)
}

private func actionItemId(_ number: Int) -> String {
    String(format: "ai_%03d", number)
}

/// Overwrites only the non-nil fields of the matching id's action item. Unknown ids are ignored
/// with a warn log (04-summary-updater.md §2.3).
private func applyActionItemModifies(_ modifies: [SummaryPatch.ActionItemPatch.Modify]?, to state: inout SummaryState) {
    guard let modifies else { return }
    for modify in modifies {
        guard let index = state.actionItems.firstIndex(where: { $0.id == modify.id }) else {
            logger.warning("action item modify references unknown id, ignoring: \(modify.id, privacy: .public)")
            continue
        }
        if let task = modify.task { state.actionItems[index].task = task }
        if let assignee = modify.assignee { state.actionItems[index].assignee = assignee }
        if let due = modify.due { state.actionItems[index].due = due }
    }
}

/// Marks the matching id's action item `.done`. Unknown ids are ignored with a warn log
/// (04-summary-updater.md §2.3).
private func applyActionItemCompletes(_ completeIds: [String]?, to state: inout SummaryState) {
    guard let completeIds else { return }
    for id in completeIds {
        guard let index = state.actionItems.firstIndex(where: { $0.id == id }) else {
            logger.warning("action item complete references unknown id, ignoring: \(id, privacy: .public)")
            continue
        }
        state.actionItems[index].status = .done
    }
}
