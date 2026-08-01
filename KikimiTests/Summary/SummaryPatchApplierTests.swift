import Foundation
import Testing

@testable import Kikimi

/// `applyPatch(_:to:)` full-branch coverage (`docs/design/04-summary-updater.md` §2.3,
/// `docs/design/summary-quality-topics-and-final-pass.md` §3.2/§11, kikimi.md 8 章「セクションごとの
/// patch 戦略」).
@Suite("applyPatch")
struct SummaryPatchApplierTests {
    // MARK: - title (cumulative)

    @Test("replaces title when patch.title is non-nil and non-empty")
    func replacesTitleWhenPresent() {
        var state = SummaryState.empty
        state.title = "旧タイトル"
        var patch = emptyPatch
        patch.title = "新タイトル"

        applyPatch(patch, to: &state)

        #expect(state.title == "新タイトル")
    }

    @Test("leaves title unchanged when patch.title is nil")
    func leavesTitleUnchangedWhenNil() {
        var state = SummaryState.empty
        state.title = "既存タイトル"

        applyPatch(emptyPatch, to: &state)

        #expect(state.title == "既存タイトル")
    }

    @Test("leaves title unchanged when patch.title is an empty string")
    func leavesTitleUnchangedWhenEmpty() {
        var state = SummaryState.empty
        state.title = "既存タイトル"
        var patch = emptyPatch
        patch.title = ""

        applyPatch(patch, to: &state)

        #expect(state.title == "既存タイトル")
    }

    // MARK: - participants (append_only, de-duplicated, order-preserving)

    @Test("appends new participants while de-duplicating already-present ones, preserving order")
    func participantsDeduplicateAndPreserveOrder() {
        var state = SummaryState.empty
        state.participants = ["田中さん"]
        var patch = emptyPatch
        patch.participantsAdd = ["田中さん", "佐藤さん", "佐藤さん"]

        applyPatch(patch, to: &state)

        #expect(state.participants == ["田中さん", "佐藤さん"])
    }

    @Test("participants unchanged when patch.participantsAdd is nil")
    func participantsUnchangedWhenNil() {
        var state = SummaryState.empty
        state.participants = ["田中さん"]

        applyPatch(emptyPatch, to: &state)

        #expect(state.participants == ["田中さん"])
    }

    // MARK: - participants (reserved audio-channel-label filter, §6.2)

    @Test(
        "skips reserved audio-channel-label names (trim+lowercase exact match), letting ordinary names through",
        arguments: ["system", "System", " mic ", "MIC"]
    )
    func participantsFilterRejectsReservedNames(reservedCandidate: String) {
        var state = SummaryState.empty
        var patch = emptyPatch
        patch.participantsAdd = [reservedCandidate]

        applyPatch(patch, to: &state)

        #expect(state.participants.isEmpty)
    }

    @Test("does not reject a participant name that merely contains a reserved word as a substring")
    func participantsFilterAllowsSubstringMatch() {
        var state = SummaryState.empty
        var patch = emptyPatch
        patch.participantsAdd = ["systema", "田中さん"]

        applyPatch(patch, to: &state)

        #expect(state.participants == ["systema", "田中さん"])
    }

    @Test("filters reserved names out of a mixed batch while keeping ordinary names, in order")
    func participantsFilterMixedBatch() {
        var state = SummaryState.empty
        var patch = emptyPatch
        patch.participantsAdd = ["system", "田中さん", "mic", "佐藤さん"]

        applyPatch(patch, to: &state)

        #expect(state.participants == ["田中さん", "佐藤さん"])
    }

    // MARK: - overview (snapshot)

    @Test("replaces overview wholesale when non-nil")
    func overviewSnapshotReplace() {
        var state = SummaryState.empty
        state.overview = "旧概要"
        var patch = emptyPatch
        patch.overview = "新しい概要全文"

        applyPatch(patch, to: &state)

        #expect(state.overview == "新しい概要全文")
    }

    @Test("leaves overview unchanged when patch.overview is nil")
    func overviewUnchangedWhenNil() {
        var state = SummaryState.empty
        state.overview = "既存概要"

        applyPatch(emptyPatch, to: &state)

        #expect(state.overview == "既存概要")
    }

    // MARK: - decisions.add (append, de-duplicate by normalized text, id-collision rename)

    @Test("appends new decisions")
    func decisionsAppend() {
        var state = SummaryState.empty
        var patch = emptyPatch
        patch.decisionsAdd = [makeDecision(id: "dc_001", text: "決定A", sourceSegIds: ["seg_00001"])]

        applyPatch(patch, to: &state)

        #expect(state.decisions == [makeDecision(id: "dc_001", text: "決定A", sourceSegIds: ["seg_00001"])])
    }

    @Test("drops decisions that duplicate an existing one after text normalization")
    func decisionsDropDuplicatesByNormalizedText() {
        var state = SummaryState.empty
        state.decisions = [makeDecision(id: "dc_001", text: "スコープ外とする", sourceSegIds: ["seg_00001"])]
        var patch = emptyPatch
        patch.decisionsAdd = [
            // Same text modulo surrounding whitespace/case -- must be treated as a duplicate.
            makeDecision(id: "dc_002", text: "  スコープ外とする  ", sourceSegIds: ["seg_00099"]),
            makeDecision(id: "dc_003", text: "新しい決定", sourceSegIds: ["seg_00100"])
        ]

        applyPatch(patch, to: &state)

        #expect(state.decisions == [
            makeDecision(id: "dc_001", text: "スコープ外とする", sourceSegIds: ["seg_00001"]),
            makeDecision(id: "dc_003", text: "新しい決定", sourceSegIds: ["seg_00100"])
        ])
    }

    @Test("renames the new decision's id on collision with an existing decision id")
    func decisionsAddRenamesOnCollision() {
        var state = SummaryState.empty
        state.decisions = [makeDecision(id: "dc_001", text: "既存決定")]
        var patch = emptyPatch
        patch.decisionsAdd = [makeDecision(id: "dc_001", text: "衝突した新決定")]

        applyPatch(patch, to: &state)

        #expect(state.decisions.count == 2)
        #expect(state.decisions[0] == makeDecision(id: "dc_001", text: "既存決定"))
        // Renamed to the next available dc_00N id rather than overwriting/discarding.
        #expect(state.decisions[1].id == "dc_002")
        #expect(state.decisions[1].text == "衝突した新決定")
    }

    // MARK: - decisions.modify (replace non-nil fields, append sourceSegIds, ignore unknown id)

    @Test("modify replaces text of the matching decision")
    func decisionsModifyReplacesText() {
        var state = SummaryState.empty
        state.decisions = [makeDecision(id: "dc_001", text: "旧テキスト", sourceSegIds: ["seg_00001"])]
        var patch = emptyPatch
        patch.decisionsModify = [SummaryPatch.DecisionModify(id: "dc_001", text: "書き直したテキスト", sourceSegIds: nil)]

        applyPatch(patch, to: &state)

        #expect(state.decisions == [makeDecision(id: "dc_001", text: "書き直したテキスト", sourceSegIds: ["seg_00001"])])
    }

    @Test("modify appends sourceSegIds, de-duplicated against what's already present")
    func decisionsModifyAppendsSourceSegIdsDeduplicated() {
        var state = SummaryState.empty
        state.decisions = [makeDecision(id: "dc_001", text: "テキスト", sourceSegIds: ["seg_00001"])]
        var patch = emptyPatch
        patch.decisionsModify = [
            SummaryPatch.DecisionModify(id: "dc_001", text: nil, sourceSegIds: ["seg_00001", "seg_00002"])
        ]

        applyPatch(patch, to: &state)

        #expect(state.decisions[0].sourceSegIds == ["seg_00001", "seg_00002"])
    }

    @Test("modify does not drop the result even if its new text now normalizes to match another decision")
    func decisionsModifyDoesNotDeduplicateAgainstOtherDecisions() {
        var state = SummaryState.empty
        state.decisions = [
            makeDecision(id: "dc_001", text: "既存の決定"),
            makeDecision(id: "dc_002", text: "別の決定")
        ]
        var patch = emptyPatch
        // dc_002 is rewritten to duplicate dc_001's text -- must NOT be removed by dedup logic;
        // decisionsModify is a "言い直し", dedup only applies at add time.
        patch.decisionsModify = [SummaryPatch.DecisionModify(id: "dc_002", text: "既存の決定", sourceSegIds: nil)]

        applyPatch(patch, to: &state)

        #expect(state.decisions.count == 2)
        #expect(state.decisions[1].text == "既存の決定")
    }

    @Test("modify referencing an unknown id is ignored, leaving existing decisions untouched")
    func decisionsModifyIgnoresUnknownId() {
        var state = SummaryState.empty
        state.decisions = [makeDecision(id: "dc_001", text: "既存決定")]
        var patch = emptyPatch
        patch.decisionsModify = [SummaryPatch.DecisionModify(id: "dc_999", text: "存在しないIDへの変更", sourceSegIds: nil)]

        applyPatch(patch, to: &state)

        #expect(state.decisions == [makeDecision(id: "dc_001", text: "既存決定")])
    }

    // MARK: - decisions.remove (remove by id, ignore unknown id)

    @Test("remove drops the matching decision")
    func decisionsRemoveDropsMatchingDecision() {
        var state = SummaryState.empty
        state.decisions = [
            makeDecision(id: "dc_001", text: "決定A"),
            makeDecision(id: "dc_002", text: "決定B")
        ]
        var patch = emptyPatch
        patch.decisionsRemove = ["dc_001"]

        applyPatch(patch, to: &state)

        #expect(state.decisions == [makeDecision(id: "dc_002", text: "決定B")])
    }

    @Test("remove referencing an unknown id is ignored, leaving existing decisions untouched")
    func decisionsRemoveIgnoresUnknownId() {
        var state = SummaryState.empty
        state.decisions = [makeDecision(id: "dc_001", text: "決定A")]
        var patch = emptyPatch
        patch.decisionsRemove = ["dc_999"]

        applyPatch(patch, to: &state)

        #expect(state.decisions == [makeDecision(id: "dc_001", text: "決定A")])
    }

    // MARK: - decisions ordering within a single patch

    @Test("add then modify the newly-added decision within the same patch")
    func decisionsAddThenModifySameId() {
        var state = SummaryState.empty
        var patch = emptyPatch
        patch.decisionsAdd = [makeDecision(id: "dc_001", text: "初版テキスト")]
        patch.decisionsModify = [SummaryPatch.DecisionModify(id: "dc_001", text: "改訂テキスト", sourceSegIds: nil)]

        applyPatch(patch, to: &state)

        #expect(state.decisions == [makeDecision(id: "dc_001", text: "改訂テキスト")])
    }

    @Test("when the same id has both a modify and a remove in one patch, remove wins (apply order: modify -> remove)")
    func decisionsModifyThenRemoveSameIdRemoveWins() {
        var state = SummaryState.empty
        state.decisions = [makeDecision(id: "dc_001", text: "旧テキスト")]
        var patch = emptyPatch
        patch.decisionsModify = [SummaryPatch.DecisionModify(id: "dc_001", text: "書き直し", sourceSegIds: nil)]
        patch.decisionsRemove = ["dc_001"]

        applyPatch(patch, to: &state)

        #expect(state.decisions.isEmpty)
    }

    // MARK: - topics.add (append, id-collision rename)

    @Test("appends new topics to the end of the chronological list")
    func topicsAppend() {
        var state = SummaryState.empty
        state.topics = [makeTopic(id: "tp_001", heading: "既存トピック", body: "既存本文")]
        var patch = emptyPatch
        patch.topicsAdd = [makeTopic(id: "tp_002", heading: "新トピック", body: "新本文", sourceSegIds: ["seg_00050"])]

        applyPatch(patch, to: &state)

        #expect(state.topics == [
            makeTopic(id: "tp_001", heading: "既存トピック", body: "既存本文"),
            makeTopic(id: "tp_002", heading: "新トピック", body: "新本文", sourceSegIds: ["seg_00050"])
        ])
    }

    @Test("renames the new topic's id on collision with an existing topic id")
    func topicsAddRenamesOnCollision() {
        var state = SummaryState.empty
        state.topics = [makeTopic(id: "tp_001", heading: "既存トピック", body: "既存本文")]
        var patch = emptyPatch
        patch.topicsAdd = [makeTopic(id: "tp_001", heading: "衝突した新トピック", body: "新本文")]

        applyPatch(patch, to: &state)

        #expect(state.topics.count == 2)
        #expect(state.topics[0].id == "tp_001")
        #expect(state.topics[1].id == "tp_002")
        #expect(state.topics[1].heading == "衝突した新トピック")
    }

    // MARK: - topics.update (replace non-nil fields, append sourceSegIds, ignore unknown id)

    @Test("update replaces body wholesale (full-text snapshot, not a diff)")
    func topicsUpdateReplacesBody() {
        var state = SummaryState.empty
        state.topics = [makeTopic(id: "tp_001", heading: "トピック", body: "旧本文")]
        var patch = emptyPatch
        patch.topicsUpdate = [SummaryPatch.TopicUpdate(id: "tp_001", heading: nil, body: "新本文全文", sourceSegIds: nil)]

        applyPatch(patch, to: &state)

        #expect(state.topics[0].body == "新本文全文")
        #expect(state.topics[0].heading == "トピック")
    }

    @Test("update replaces heading standalone without touching body")
    func topicsUpdateReplacesHeadingOnly() {
        var state = SummaryState.empty
        state.topics = [makeTopic(id: "tp_001", heading: "旧見出し", body: "本文")]
        var patch = emptyPatch
        patch.topicsUpdate = [SummaryPatch.TopicUpdate(id: "tp_001", heading: "新見出し", body: nil, sourceSegIds: nil)]

        applyPatch(patch, to: &state)

        #expect(state.topics[0].heading == "新見出し")
        #expect(state.topics[0].body == "本文")
    }

    @Test("update appends sourceSegIds, de-duplicated against what's already present")
    func topicsUpdateAppendsSourceSegIdsDeduplicated() {
        var state = SummaryState.empty
        state.topics = [makeTopic(id: "tp_001", heading: "トピック", body: "本文", sourceSegIds: ["seg_00001"])]
        var patch = emptyPatch
        patch.topicsUpdate = [
            SummaryPatch.TopicUpdate(id: "tp_001", heading: nil, body: nil, sourceSegIds: ["seg_00001", "seg_00002"])
        ]

        applyPatch(patch, to: &state)

        #expect(state.topics[0].sourceSegIds == ["seg_00001", "seg_00002"])
    }

    @Test("update referencing an unknown id is ignored, leaving existing topics untouched")
    func topicsUpdateIgnoresUnknownId() {
        var state = SummaryState.empty
        state.topics = [makeTopic(id: "tp_001", heading: "トピック", body: "本文")]
        var patch = emptyPatch
        patch.topicsUpdate = [SummaryPatch.TopicUpdate(id: "tp_999", heading: "存在しないID", body: nil, sourceSegIds: nil)]

        applyPatch(patch, to: &state)

        #expect(state.topics == [makeTopic(id: "tp_001", heading: "トピック", body: "本文")])
    }

    @Test("add then update the newly-added topic within the same patch")
    func topicsAddThenUpdateSameId() {
        var state = SummaryState.empty
        var patch = emptyPatch
        patch.topicsAdd = [makeTopic(id: "tp_001", heading: "初版見出し", body: "初版本文")]
        patch.topicsUpdate = [SummaryPatch.TopicUpdate(id: "tp_001", heading: nil, body: "改訂本文", sourceSegIds: nil)]

        applyPatch(patch, to: &state)

        #expect(state.topics == [makeTopic(id: "tp_001", heading: "初版見出し", body: "改訂本文")])
    }

    // MARK: - action_items.add (append, id-collision rename)

    @Test("appends new action items")
    func actionItemsAdd() {
        var state = SummaryState.empty
        var patch = emptyPatch
        patch.actionItems = SummaryPatch.ActionItemPatch(
            add: [makeActionItem(id: "ai_001", task: "タスクA")]
        )

        applyPatch(patch, to: &state)

        #expect(state.actionItems.map(\.id) == ["ai_001"])
        #expect(state.actionItems.map(\.task) == ["タスクA"])
    }

    @Test("renames the new item's id on collision with an existing action item id")
    func actionItemsAddRenamesOnCollision() {
        var state = SummaryState.empty
        state.actionItems = [makeActionItem(id: "ai_001", task: "既存タスク")]
        var patch = emptyPatch
        patch.actionItems = SummaryPatch.ActionItemPatch(
            add: [makeActionItem(id: "ai_001", task: "衝突した新タスク")]
        )

        applyPatch(patch, to: &state)

        #expect(state.actionItems.count == 2)
        #expect(state.actionItems[0].id == "ai_001")
        #expect(state.actionItems[0].task == "既存タスク")
        // Renamed to the next available ai_00N id rather than overwriting/discarding.
        #expect(state.actionItems[1].id == "ai_002")
        #expect(state.actionItems[1].task == "衝突した新タスク")
    }

    @Test("renames multiple colliding adds within the same patch to distinct ids")
    func actionItemsAddRenamesMultipleCollisionsDistinctly() {
        var state = SummaryState.empty
        state.actionItems = [makeActionItem(id: "ai_001", task: "既存タスク")]
        var patch = emptyPatch
        patch.actionItems = SummaryPatch.ActionItemPatch(
            add: [
                makeActionItem(id: "ai_001", task: "新タスク1"),
                makeActionItem(id: "ai_001", task: "新タスク2")
            ]
        )

        applyPatch(patch, to: &state)

        #expect(state.actionItems.map(\.id) == ["ai_001", "ai_002", "ai_003"])
    }

    // MARK: - action_items.modify (overwrite non-nil fields only, ignore unknown id)

    @Test("modify overwrites only the fields patch specifies")
    func actionItemsModifyOverwritesOnlyProvidedFields() {
        var state = SummaryState.empty
        state.actionItems = [
            makeActionItem(id: "ai_001", task: "旧タスク", assignee: "旧担当", due: nil)
        ]
        var patch = emptyPatch
        patch.actionItems = SummaryPatch.ActionItemPatch(
            modify: [SummaryPatch.ActionItemPatch.Modify(id: "ai_001", task: nil, assignee: nil, due: "7月末")]
        )

        applyPatch(patch, to: &state)

        #expect(state.actionItems[0].task == "旧タスク")
        #expect(state.actionItems[0].assignee == "旧担当")
        #expect(state.actionItems[0].due == "7月末")
    }

    @Test("modify referencing an unknown id is ignored, leaving existing items untouched")
    func actionItemsModifyIgnoresUnknownId() {
        var state = SummaryState.empty
        state.actionItems = [makeActionItem(id: "ai_001", task: "既存タスク")]
        var patch = emptyPatch
        patch.actionItems = SummaryPatch.ActionItemPatch(
            modify: [SummaryPatch.ActionItemPatch.Modify(id: "ai_999", task: "存在しない項目への変更", assignee: nil, due: nil)]
        )

        applyPatch(patch, to: &state)

        #expect(state.actionItems.count == 1)
        #expect(state.actionItems[0].task == "既存タスク")
    }

    // MARK: - action_items.complete (status -> .done, ignore unknown id)

    @Test("complete marks the matching action item done")
    func actionItemsCompleteMarksDone() {
        var state = SummaryState.empty
        state.actionItems = [makeActionItem(id: "ai_001", task: "タスク", status: .open)]
        var patch = emptyPatch
        patch.actionItems = SummaryPatch.ActionItemPatch(complete: ["ai_001"])

        applyPatch(patch, to: &state)

        #expect(state.actionItems[0].status == .done)
    }

    @Test("complete referencing an unknown id is ignored")
    func actionItemsCompleteIgnoresUnknownId() {
        var state = SummaryState.empty
        state.actionItems = [makeActionItem(id: "ai_001", task: "タスク", status: .open)]
        var patch = emptyPatch
        patch.actionItems = SummaryPatch.ActionItemPatch(complete: ["ai_999"])

        applyPatch(patch, to: &state)

        #expect(state.actionItems[0].status == .open)
    }

    // MARK: - fully-null patch (no-op)

    @Test("a fully-null patch changes nothing")
    func fullyNullPatchIsNoOp() {
        var state = SummaryState.empty
        state.title = "タイトル"
        state.participants = ["田中さん"]
        state.overview = "概要"
        state.decisions = [makeDecision(id: "dc_001", text: "決定")]
        state.topics = [makeTopic(id: "tp_001", heading: "見出し", body: "本文")]
        state.actionItems = [makeActionItem(id: "ai_001", task: "タスク")]
        let before = state

        applyPatch(emptyPatch, to: &state)

        #expect(state == before)
    }

    // MARK: - Fixtures

    private var emptyPatch: SummaryPatch {
        Self.emptyPatch
    }

    private static let emptyPatch = SummaryPatch(
        title: nil,
        participantsAdd: nil,
        overview: nil,
        decisionsAdd: nil,
        actionItems: nil,
        topicsAdd: nil,
        topicsUpdate: nil,
        decisionsModify: nil,
        decisionsRemove: nil
    )

    private func makeActionItem(
        id: String,
        task: String,
        assignee: String = "担当者",
        due: String? = nil,
        status: SummaryState.ActionItem.Status = .open
    ) -> SummaryState.ActionItem {
        SummaryState.ActionItem(id: id, task: task, assignee: assignee, due: due, status: status, sourceSegIds: [])
    }

    private func makeDecision(id: String, text: String, sourceSegIds: [String] = []) -> SummaryState.Decision {
        SummaryState.Decision(id: id, text: text, sourceSegIds: sourceSegIds)
    }

    private func makeTopic(id: String, heading: String, body: String, sourceSegIds: [String] = []) -> SummaryState.Topic {
        SummaryState.Topic(id: id, heading: heading, body: body, sourceSegIds: sourceSegIds)
    }
}

// MARK: - sanitizeState

/// `sanitizeState(_:)` coverage (`docs/design/summary-quality-topics-and-final-pass.md` §2.3): id
/// backfill for decisions/topics decoded from pre-existing `summary.state.json` files, and
/// reserved audio-channel-label removal from `participants`.
@Suite("sanitizeState")
struct SanitizeStateTests {
    @Test("backfills unnumbered decision ids with dc_00N, scanning upward and skipping ids already in use")
    func backfillsUnnumberedDecisionIds() {
        var state = SummaryState.empty
        state.decisions = [
            SummaryState.Decision(id: "", text: "未採番決定1", sourceSegIds: []),
            SummaryState.Decision(id: "dc_001", text: "既採番決定", sourceSegIds: []),
            SummaryState.Decision(id: "", text: "未採番決定2", sourceSegIds: [])
        ]

        sanitizeState(&state)

        // dc_001 is already taken, so the scan skips it and assigns dc_002 / dc_003 in order.
        #expect(state.decisions.map(\.id) == ["dc_002", "dc_001", "dc_003"])
        #expect(state.decisions.map(\.text) == ["未採番決定1", "既採番決定", "未採番決定2"])
    }

    @Test("backfills unnumbered topic ids with tp_00N, scanning upward and skipping ids already in use")
    func backfillsUnnumberedTopicIds() {
        var state = SummaryState.empty
        state.topics = [
            SummaryState.Topic(id: "", heading: "未採番トピック", body: "", sourceSegIds: []),
            SummaryState.Topic(id: "tp_001", heading: "既採番トピック", body: "", sourceSegIds: [])
        ]

        sanitizeState(&state)

        #expect(state.topics.map(\.id) == ["tp_002", "tp_001"])
    }

    @Test("removes reserved audio-channel-label names from participants")
    func removesReservedParticipantNames() {
        var state = SummaryState.empty
        state.participants = ["furu", "system", "田中さん", " mic "]

        sanitizeState(&state)

        #expect(state.participants == ["furu", "田中さん"])
    }

    @Test("is a no-op on an already-clean state")
    func noOpOnCleanState() {
        var state = SummaryState.empty
        state.decisions = [SummaryState.Decision(id: "dc_001", text: "決定", sourceSegIds: [])]
        state.topics = [SummaryState.Topic(id: "tp_001", heading: "見出し", body: "本文", sourceSegIds: [])]
        state.participants = ["田中さん"]
        let before = state

        sanitizeState(&state)

        #expect(state == before)
    }
}

// MARK: - applyFinalRevision

/// `applyFinalRevision(_:to:)` coverage (`docs/design/summary-quality-topics-and-final-pass.md`
/// §7.3): wholesale replace + id renumbering, untouched fields, and the destructive-write guard.
@Suite("applyFinalRevision")
struct ApplyFinalRevisionTests {
    @Test("replaces overview/decisions/actionItems wholesale, renumbering ids from 001")
    func replacesWholesaleAndRenumbers() {
        var state = SummaryState.empty
        state.overview = "旧概要"
        state.decisions = [SummaryState.Decision(id: "dc_005", text: "旧決定", sourceSegIds: [])]
        state.actionItems = [
            SummaryState.ActionItem(id: "ai_009", task: "旧タスク", assignee: "旧担当", due: nil, status: .open, sourceSegIds: [])
        ]
        let revision = SummaryFinalRevision(
            overview: "新しい概要",
            decisions: [
                SummaryFinalRevision.RevisedDecision(text: "決定1", sourceSegIds: ["seg_00001"]),
                SummaryFinalRevision.RevisedDecision(text: "決定2", sourceSegIds: ["seg_00002"])
            ],
            actionItems: [
                SummaryFinalRevision.RevisedActionItem(
                    task: "タスク1", assignee: "担当A", due: "7月末", status: .done, sourceSegIds: ["seg_00003"]
                )
            ]
        )

        applyFinalRevision(revision, to: &state)

        #expect(state.overview == "新しい概要")
        #expect(state.decisions == [
            SummaryState.Decision(id: "dc_001", text: "決定1", sourceSegIds: ["seg_00001"]),
            SummaryState.Decision(id: "dc_002", text: "決定2", sourceSegIds: ["seg_00002"])
        ])
        #expect(state.actionItems == [
            SummaryState.ActionItem(
                id: "ai_001", task: "タスク1", assignee: "担当A", due: "7月末", status: .done, sourceSegIds: ["seg_00003"]
            )
        ])
    }

    @Test("leaves title/participants/topics/lastSummarizedStartMs untouched")
    func leavesOutOfScopeFieldsUntouched() {
        var state = SummaryState.empty
        state.title = "会議タイトル"
        state.participants = ["田中さん"]
        state.topics = [SummaryState.Topic(id: "tp_001", heading: "見出し", body: "本文", sourceSegIds: [])]
        state.lastSummarizedStartMs = 12_345
        let revision = SummaryFinalRevision(overview: "新概要", decisions: [], actionItems: [])

        applyFinalRevision(revision, to: &state)

        #expect(state.title == "会議タイトル")
        #expect(state.participants == ["田中さん"])
        #expect(state.topics == [SummaryState.Topic(id: "tp_001", heading: "見出し", body: "本文", sourceSegIds: [])])
        #expect(state.lastSummarizedStartMs == 12_345)
    }

    @Test("applies an empty revision when the pre-apply state was already empty (no guard trigger)")
    func appliesEmptyRevisionOntoEmptyState() {
        var state = SummaryState.empty
        let revision = SummaryFinalRevision(overview: "", decisions: [], actionItems: [])

        applyFinalRevision(revision, to: &state)

        #expect(state.overview.isEmpty)
        #expect(state.decisions.isEmpty)
        #expect(state.actionItems.isEmpty)
    }

    @Test("skips applying an empty revision when the pre-apply state has non-empty content (destructive-write guard)")
    func skipsEmptyRevisionWhenStateHasContent() {
        var state = SummaryState.empty
        state.overview = "既存の概要"
        state.decisions = [SummaryState.Decision(id: "dc_001", text: "既存決定", sourceSegIds: [])]
        state.actionItems = [
            SummaryState.ActionItem(id: "ai_001", task: "既存タスク", assignee: "担当", due: nil, status: .open, sourceSegIds: [])
        ]
        let before = state
        let revision = SummaryFinalRevision(overview: "", decisions: [], actionItems: [])

        applyFinalRevision(revision, to: &state)

        #expect(state == before)
    }

    @Test("a revision with only decisions populated is not treated as empty, even with a blank overview")
    func nonEmptyDecisionsAloneIsNotTreatedAsEmptyRevision() {
        var state = SummaryState.empty
        state.overview = "既存の概要"
        let revision = SummaryFinalRevision(
            overview: "",
            decisions: [SummaryFinalRevision.RevisedDecision(text: "新決定", sourceSegIds: [])],
            actionItems: []
        )

        applyFinalRevision(revision, to: &state)

        #expect(state.overview.isEmpty)
        #expect(state.decisions == [SummaryState.Decision(id: "dc_001", text: "新決定", sourceSegIds: [])])
    }
}
