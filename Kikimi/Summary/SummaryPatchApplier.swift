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
/// Apply order (`docs/design/summary-quality-topics-and-final-pass.md` §3.2): title →
/// participants → overview → decisions (add → modify → remove) → topics (add → update) →
/// action_items. `decisionsAdd`/`topicsAdd` run before `decisionsModify`/`topicsUpdate` so a
/// single patch can add and immediately update/modify the same new id.
///
/// - Note: This does **not** update `state.lastSummarizedStartMs`; the caller (`SummaryUpdater`,
///   out of scope here) advances that cursor separately once it knows the max `startMs` of the
///   segments that produced this patch (04-summary-updater.md §2.3's closing note).
func applyPatch(_ patch: SummaryPatch, to state: inout SummaryState) {
    applyTitle(patch.title, to: &state)
    applyParticipants(patch.participantsAdd, to: &state)
    applyOverview(patch.overview, to: &state)
    applyDecisionsAdd(patch.decisionsAdd, to: &state)
    applyDecisionsModify(patch.decisionsModify, to: &state)
    applyDecisionsRemove(patch.decisionsRemove, to: &state)
    applyTopicsAdd(patch.topicsAdd, to: &state)
    applyTopicsUpdate(patch.topicsUpdate, to: &state)
    applyActionItems(patch.actionItems, to: &state)
}

// MARK: - title (cumulative)

private func applyTitle(_ title: String?, to state: inout SummaryState) {
    guard let title, !title.isEmpty else { return }
    state.title = title
}

// MARK: - participants (append_only, de-duplicated, reserved-name filtered)

/// The channel labels a segment line is tagged with (`seg_00350 (system): ...`), which an LLM
/// occasionally misreads as a speaker name (`docs/design/summary-quality-topics-and-final-pass.md`
/// §6.1/§6.2). Matched as trim+lowercased *exact* equality, so `"systema"` or ordinary names still
/// pass through.
private let reservedParticipantNames: Set<String> = Set(AudioSourceKind.allCases.map(\.rawValue))

private func isReservedParticipantName(_ name: String) -> Bool {
    reservedParticipantNames.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
}

private func applyParticipants(_ participantsAdd: [String]?, to state: inout SummaryState) {
    guard let participantsAdd else { return }
    var seen = Set(state.participants)
    for participant in participantsAdd {
        guard !isReservedParticipantName(participant) else {
            logger.debug("skipping reserved audio-channel-label participant name: \(participant, privacy: .public)")
            continue
        }
        guard !seen.contains(participant) else { continue }
        state.participants.append(participant)
        seen.insert(participant)
    }
}

// MARK: - overview (snapshot)

private func applyOverview(_ overview: String?, to state: inout SummaryState) {
    guard let overview else { return }
    state.overview = overview
}

// MARK: - decisions (add / modify / remove)

/// Appends new decisions, de-duplicating by normalized `text` (unchanged from the append-only
/// era) and renaming on `id` collision the same way action item adds do
/// (`docs/design/summary-quality-topics-and-final-pass.md` §3.2's `decisionsAdd` row).
private func applyDecisionsAdd(_ decisionsAdd: [SummaryState.Decision]?, to state: inout SummaryState) {
    guard let decisionsAdd else { return }
    var existingNormalizedTexts = Set(state.decisions.map(normalizedDecisionText))
    var usedIds = Set(state.decisions.map(\.id))
    for var decision in decisionsAdd {
        let normalized = normalizedDecisionText(decision)
        guard !existingNormalizedTexts.contains(normalized) else {
            logger.debug("dropping duplicate decision (already present): \(decision.text, privacy: .public)")
            continue
        }
        if usedIds.contains(decision.id) {
            let renamedId = nextAvailableId(prefix: "dc", usedIds: usedIds)
            logger.warning(
                "decision id collision on add: \(decision.id, privacy: .public) already exists, renaming to \(renamedId, privacy: .public)"
            )
            decision.id = renamedId
        }
        usedIds.insert(decision.id)
        existingNormalizedTexts.insert(normalized)
        state.decisions.append(decision)
    }
}

/// Normalizes a decision's `text` for duplicate detection: trims whitespace/newlines and
/// lowercases, so trivial LLM rewording (extra whitespace, case) doesn't re-add the same decision
/// (04-summary-updater.md §2.3: "既存 decisions の text と（正規化した上で）一致するものは重複として捨てる").
private func normalizedDecisionText(_ decision: SummaryState.Decision) -> String {
    decision.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// Replaces only the non-nil fields of the matching id's decision. `text` replacement is a
/// "言い直し", not a fresh add, so the result is **not** re-checked against
/// `normalizedDecisionText` duplicate detection even if it now matches another decision verbatim
/// (`docs/design/summary-quality-topics-and-final-pass.md` §3.2's `decisionsModify` row). Unknown
/// ids are ignored with a warn log.
private func applyDecisionsModify(_ modifies: [SummaryPatch.DecisionModify]?, to state: inout SummaryState) {
    guard let modifies else { return }
    for modify in modifies {
        guard let index = state.decisions.firstIndex(where: { $0.id == modify.id }) else {
            logger.warning("decision modify references unknown id, ignoring: \(modify.id, privacy: .public)")
            continue
        }
        if let text = modify.text {
            state.decisions[index].text = text
        }
        if let newSegIds = modify.sourceSegIds {
            appendUniqueSegIds(newSegIds, to: &state.decisions[index].sourceSegIds)
        }
    }
}

/// Removes the matching id's decision. Unknown ids are ignored with a warn log
/// (`docs/design/summary-quality-topics-and-final-pass.md` §3.2's `decisionsRemove` row).
private func applyDecisionsRemove(_ removeIds: [String]?, to state: inout SummaryState) {
    guard let removeIds else { return }
    for id in removeIds {
        guard let index = state.decisions.firstIndex(where: { $0.id == id }) else {
            logger.warning("decision remove references unknown id, ignoring: \(id, privacy: .public)")
            continue
        }
        state.decisions.remove(at: index)
    }
}

// MARK: - topics (add / update)

/// Appends new topics to the end of the chronological list, renaming on `id` collision the same
/// way action item / decision adds do
/// (`docs/design/summary-quality-topics-and-final-pass.md` §3.2's `topicsAdd` row).
private func applyTopicsAdd(_ topicsAdd: [SummaryState.Topic]?, to state: inout SummaryState) {
    guard let topicsAdd else { return }
    var usedIds = Set(state.topics.map(\.id))
    for var topic in topicsAdd {
        if usedIds.contains(topic.id) {
            let renamedId = nextAvailableId(prefix: "tp", usedIds: usedIds)
            logger.warning(
                "topic id collision on add: \(topic.id, privacy: .public) already exists, renaming to \(renamedId, privacy: .public)"
            )
            topic.id = renamedId
        }
        usedIds.insert(topic.id)
        state.topics.append(topic)
    }
}

/// Replaces only the non-nil fields of the matching id's topic (`body` is a full-text
/// replacement, not a diff). `sourceSegIds` are appended, de-duplicated against what's already
/// there. Unknown ids are ignored with a warn log
/// (`docs/design/summary-quality-topics-and-final-pass.md` §3.2's `topicsUpdate` row).
private func applyTopicsUpdate(_ updates: [SummaryPatch.TopicUpdate]?, to state: inout SummaryState) {
    guard let updates else { return }
    for update in updates {
        guard let index = state.topics.firstIndex(where: { $0.id == update.id }) else {
            logger.warning("topic update references unknown id, ignoring: \(update.id, privacy: .public)")
            continue
        }
        if let heading = update.heading {
            state.topics[index].heading = heading
        }
        if let body = update.body {
            state.topics[index].body = body
        }
        if let newSegIds = update.sourceSegIds {
            appendUniqueSegIds(newSegIds, to: &state.topics[index].sourceSegIds)
        }
    }
}

// MARK: - shared helpers (id allocation, sourceSegIds append)

/// Finds the next unused `<prefix>_00N` id, scanning upward from 1 so renames stay deterministic
/// across repeated collisions within the same patch. Shared by action item / decision / topic add
/// (id collision) and `sanitizeState` (id backfill) --
/// `docs/design/summary-quality-topics-and-final-pass.md` §2.3/§3.2.
private func nextAvailableId(prefix: String, usedIds: Set<String>) -> String {
    var candidateNumber = 1
    while usedIds.contains(formattedId(prefix: prefix, number: candidateNumber)) {
        candidateNumber += 1
    }
    return formattedId(prefix: prefix, number: candidateNumber)
}

private func formattedId(prefix: String, number: Int) -> String {
    prefix + String(format: "_%03d", number)
}

/// Appends `newIds` to `existing`, skipping any already present (order-preserving, same
/// de-duplication shape as `applyParticipants`). Shared by `decisionsModify.sourceSegIds` and
/// `topicsUpdate.sourceSegIds`, both of which are "追記分" per
/// `docs/design/summary-quality-topics-and-final-pass.md` §3.1.
private func appendUniqueSegIds(_ newIds: [String], to existing: inout [String]) {
    var seen = Set(existing)
    for id in newIds where !seen.contains(id) {
        existing.append(id)
        seen.insert(id)
    }
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
            let renamedId = nextAvailableId(prefix: "ai", usedIds: usedIds)
            logger.warning(
                "action item id collision on add: \(item.id, privacy: .public) already exists, renaming to \(renamedId, privacy: .public)"
            )
            item.id = renamedId
        }
        usedIds.insert(item.id)
        state.actionItems.append(item)
    }
}

/// Overwrites only the fields the patch specifies. Unknown ids are ignored
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

// MARK: - sanitizeState

/// In-place normalization of a freshly-loaded `SummaryState`. Pure, deterministic
/// (`docs/design/summary-quality-topics-and-final-pass.md` §2.3).
///
/// - Backfills `decisions`/`topics` ids left unnumbered (`""`) by `SummaryState`'s
///   backward-compatible decode of pre-existing `summary.state.json` files that predate this
///   schema (`dc_00N`/`tp_00N`, same scan-upward-from-1 convention as action items).
/// - Strips reserved audio-channel-label names (`mic`/`system`) that leaked into `participants`
///   before `applyParticipants`'s filter existed (§6.1's `["furu", "system"]` example).
///
/// Callers wire this into the sole `summary.state.json` read path (`SummaryUpdater`, out of scope
/// here) so existing contaminated state self-heals the next time it's written
/// (`docs/design/summary-quality-topics-and-final-pass.md` §2.3's closing note).
func sanitizeState(_ state: inout SummaryState) {
    numberUnassignedDecisionIds(in: &state)
    numberUnassignedTopicIds(in: &state)
    state.participants.removeAll(where: isReservedParticipantName)
}

private func numberUnassignedDecisionIds(in state: inout SummaryState) {
    var usedIds = Set(state.decisions.map(\.id)).subtracting([""])
    for index in state.decisions.indices where state.decisions[index].id.isEmpty {
        let newId = nextAvailableId(prefix: "dc", usedIds: usedIds)
        state.decisions[index].id = newId
        usedIds.insert(newId)
    }
}

private func numberUnassignedTopicIds(in state: inout SummaryState) {
    var usedIds = Set(state.topics.map(\.id)).subtracting([""])
    for index in state.topics.indices where state.topics[index].id.isEmpty {
        let newId = nextAvailableId(prefix: "tp", usedIds: usedIds)
        state.topics[index].id = newId
        usedIds.insert(newId)
    }
}

// MARK: - applyFinalRevision

/// Wholesale-replaces `overview`/`decisions`/`actionItems` from a session-end
/// `SummaryFinalRevision`, renumbering `dc_00N`/`ai_00N` ids from scratch starting at 1 (the LLM
/// does not return ids for this pass -- `docs/design/summary-quality-topics-and-final-pass.md`
/// §7.2/§7.3). `title`/`participants`/`topics`/`lastSummarizedStartMs` are left untouched (§7.2's
/// scope note -- title comes from the final title proposal, participants from diarization merge,
/// topics are deliberately not rewritten by this pass).
///
/// **Destructive-write guard** (§7.3): if `revision` is effectively empty (empty `overview`, empty
/// `decisions`, empty `actionItems`) while the pre-apply `state` already has content in those same
/// three fields, the revision is **not** applied -- only a warn log is emitted. This absorbs an LLM
/// call that returns a near-empty structured output without silently wiping everything the
/// incremental updates accumulated.
func applyFinalRevision(_ revision: SummaryFinalRevision, to state: inout SummaryState) {
    let revisionIsEmpty = revision.overview.isEmpty && revision.decisions.isEmpty && revision.actionItems.isEmpty
    let stateHasContent = !state.overview.isEmpty || !state.decisions.isEmpty || !state.actionItems.isEmpty
    guard !(revisionIsEmpty && stateHasContent) else {
        logger.warning("final revision is empty but existing summary state has content; skipping apply to avoid wiping it")
        return
    }

    state.overview = revision.overview
    state.decisions = revision.decisions.enumerated().map { offset, decision in
        SummaryState.Decision(
            id: formattedId(prefix: "dc", number: offset + 1),
            text: decision.text,
            sourceSegIds: decision.sourceSegIds
        )
    }
    state.actionItems = revision.actionItems.enumerated().map { offset, item in
        SummaryState.ActionItem(
            id: formattedId(prefix: "ai", number: offset + 1),
            task: item.task,
            assignee: item.assignee,
            due: item.due,
            status: item.status,
            sourceSegIds: item.sourceSegIds
        )
    }
}
