import Foundation
import Testing

@testable import Kikimi

/// `applyPatch(_:to:)` full-branch coverage (`docs/design/04-summary-updater.md` §2.3, kikimi.md
/// 8 章「セクションごとの patch 戦略」).
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

    // MARK: - decisions (append_only, de-duplicated by normalized text)

    @Test("appends new decisions")
    func decisionsAppend() {
        var state = SummaryState.empty
        var patch = emptyPatch
        patch.decisionsAdd = [
            SummaryState.Decision(text: "決定A", sourceSegIds: ["seg_00001"])
        ]

        applyPatch(patch, to: &state)

        #expect(state.decisions == [SummaryState.Decision(text: "決定A", sourceSegIds: ["seg_00001"])])
    }

    @Test("drops decisions that duplicate an existing one after text normalization")
    func decisionsDropDuplicatesByNormalizedText() {
        var state = SummaryState.empty
        state.decisions = [SummaryState.Decision(text: "スコープ外とする", sourceSegIds: ["seg_00001"])]
        var patch = emptyPatch
        patch.decisionsAdd = [
            // Same text modulo surrounding whitespace/case -- must be treated as a duplicate.
            SummaryState.Decision(text: "  スコープ外とする  ", sourceSegIds: ["seg_00099"]),
            SummaryState.Decision(text: "新しい決定", sourceSegIds: ["seg_00100"])
        ]

        applyPatch(patch, to: &state)

        #expect(state.decisions == [
            SummaryState.Decision(text: "スコープ外とする", sourceSegIds: ["seg_00001"]),
            SummaryState.Decision(text: "新しい決定", sourceSegIds: ["seg_00100"])
        ])
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
        state.decisions = [SummaryState.Decision(text: "決定", sourceSegIds: [])]
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
        title: nil, participantsAdd: nil, overview: nil, decisionsAdd: nil, actionItems: nil
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
}
