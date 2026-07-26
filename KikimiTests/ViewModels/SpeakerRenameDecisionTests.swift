import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `SpeakerRenameDecision`/`SpeakerAssignments.applyRename(slot:displayName:
/// globalSpeakerId:)` (`Kikimi/ViewModels/SpeakerRenameDecision.swift`,
/// `Kikimi/SessionStore/DiarizationModels.swift`, `docs/design/13-speaker-diarization.md` sections
/// 4.4/6.1). Both are pure/deterministic (no I/O), so every branch is exercised directly here without a
/// `VoiceprintStore`/`SessionHandle` round-trip -- that round-trip (registration/persistence) is covered
/// separately by `MeetingWorkspaceViewModelTests`'s `applyRename(slot:submission:)` tests.
@Suite("SpeakerRenameDecision.decide")
struct SpeakerRenameDecisionTests {
    private static let sampleEmbedding: [Float] = [0.1, 0.2, 0.3]

    @Test("newName with a non-empty slot embedding registers a new global speaker and assigns it")
    func newNameWithEmbeddingRegistersAndAssigns() {
        let action = SpeakerRenameDecision.decide(
            submission: .newName("田中さん"),
            slotEmbedding: Self.sampleEmbedding
        )
        #expect(action == .registerAndAssign(displayName: "田中さん"))
    }

    @Test("newName with a nil slot embedding falls back to a session-local-only display name")
    func newNameWithNilEmbeddingIsLocalOnly() {
        let action = SpeakerRenameDecision.decide(submission: .newName("田中さん"), slotEmbedding: nil)
        #expect(action == .localOnly(displayName: "田中さん"))
    }

    @Test("newName with an empty slot embedding array is treated the same as nil (local-only)")
    func newNameWithEmptyEmbeddingIsLocalOnly() {
        let action = SpeakerRenameDecision.decide(submission: .newName("田中さん"), slotEmbedding: [])
        #expect(action == .localOnly(displayName: "田中さん"))
    }

    @Test("existingSpeaker always assigns-only, regardless of whether the slot has its own embedding")
    func existingSpeakerAlwaysAssignsOnly() {
        let withEmbedding = SpeakerRenameDecision.decide(
            submission: .existingSpeaker(globalSpeakerId: "spk-global-1", name: "佐藤さん"),
            slotEmbedding: Self.sampleEmbedding
        )
        let withoutEmbedding = SpeakerRenameDecision.decide(
            submission: .existingSpeaker(globalSpeakerId: "spk-global-1", name: "佐藤さん"),
            slotEmbedding: nil
        )
        #expect(withEmbedding == .assignExisting(globalSpeakerId: "spk-global-1", displayName: "佐藤さん"))
        #expect(withoutEmbedding == .assignExisting(globalSpeakerId: "spk-global-1", displayName: "佐藤さん"))
    }
}

/// Unit tests for `SpeakerAssignments.slotsSharing(globalSpeakerId:excluding:)`/`.applyRename(slot:
/// displayName:globalSpeakerId:)` (design section 6.1's rename-propagation rule).
@Suite("SpeakerAssignments.applyRename propagation")
struct SpeakerAssignmentsApplyRenameTests {
    @Test("renaming a slot with no globalSpeakerId only ever touches that one slot")
    func noGlobalSpeakerIdTouchesOnlyTargetSlot() {
        var assignments = SpeakerAssignments(assignments: [
            "spk_1": SlotAssignment(displayName: "Speaker 1"),
            "spk_2": SlotAssignment(displayName: "Speaker 2")
        ])
        assignments.applyRename(slot: "spk_1", displayName: "田中さん", globalSpeakerId: nil)

        #expect(assignments.assignments["spk_1"]?.displayName == "田中さん")
        #expect(assignments.assignments["spk_1"]?.globalSpeakerId == nil)
        #expect(assignments.assignments["spk_1"]?.assignedBy == .user)
        // Untouched sibling.
        #expect(assignments.assignments["spk_2"]?.displayName == "Speaker 2")
    }

    @Test("renaming a slot propagates displayName/globalSpeakerId to every other slot already sharing it")
    func propagatesToSiblingsSharingTheSameGlobalSpeakerId() {
        var assignments = SpeakerAssignments(assignments: [
            "spk_1": SlotAssignment(globalSpeakerId: "g1", displayName: "田中さん", assignedBy: .auto),
            "spk_3": SlotAssignment(globalSpeakerId: "g1", displayName: "田中さん", assignedBy: .auto),
            "spk_2": SlotAssignment(globalSpeakerId: "g2", displayName: "佐藤さん", assignedBy: .auto)
        ])

        assignments.applyRename(slot: "spk_1", displayName: "田中太郎さん", globalSpeakerId: "g1")

        #expect(assignments.assignments["spk_1"]?.displayName == "田中太郎さん")
        #expect(assignments.assignments["spk_1"]?.assignedBy == .user)
        #expect(assignments.assignments["spk_3"]?.displayName == "田中太郎さん")
        #expect(assignments.assignments["spk_3"]?.globalSpeakerId == "g1")
        #expect(assignments.assignments["spk_3"]?.assignedBy == .user)
        // A slot referencing a *different* global speaker is never touched.
        #expect(assignments.assignments["spk_2"]?.displayName == "佐藤さん")
        #expect(assignments.assignments["spk_2"]?.assignedBy == .auto)
    }

    @Test("propagation never touches a slot's own captured embedding")
    func propagationNeverTouchesEmbedding() {
        let slot1Embedding: [Float] = [0.1, 0.2]
        let slot3Embedding: [Float] = [0.3, 0.4]
        var assignments = SpeakerAssignments(assignments: [
            "spk_1": SlotAssignment(globalSpeakerId: "g1", displayName: "田中さん", assignedBy: .auto, embedding: slot1Embedding),
            "spk_3": SlotAssignment(globalSpeakerId: "g1", displayName: "田中さん", assignedBy: .auto, embedding: slot3Embedding)
        ])

        assignments.applyRename(slot: "spk_1", displayName: "田中太郎さん", globalSpeakerId: "g1")

        #expect(assignments.assignments["spk_1"]?.embedding == slot1Embedding)
        #expect(assignments.assignments["spk_3"]?.embedding == slot3Embedding)
    }

    @Test("slotsSharing(globalSpeakerId:excluding:) excludes the given slot and unrelated global ids")
    func slotsSharingExcludesSelfAndOtherIds() {
        let assignments = SpeakerAssignments(assignments: [
            "spk_1": SlotAssignment(globalSpeakerId: "g1"),
            "spk_2": SlotAssignment(globalSpeakerId: "g1"),
            "spk_3": SlotAssignment(globalSpeakerId: "g2"),
            "spk_4": SlotAssignment(globalSpeakerId: nil)
        ])
        #expect(assignments.slotsSharing(globalSpeakerId: "g1", excluding: "spk_1") == ["spk_2"])
        #expect(assignments.slotsSharing(globalSpeakerId: "g2", excluding: "spk_3") == [])
        #expect(assignments.slotsSharing(globalSpeakerId: "does-not-exist", excluding: "spk_1") == [])
    }

    @Test("renaming a brand-new slot (not previously present) still creates it with the given values")
    func renamingAPreviouslyUnknownSlotCreatesIt() {
        var assignments = SpeakerAssignments()
        assignments.applyRename(slot: "spk_1", displayName: "田中さん", globalSpeakerId: "g1")
        #expect(assignments.assignments["spk_1"]?.displayName == "田中さん")
        #expect(assignments.assignments["spk_1"]?.globalSpeakerId == "g1")
        #expect(assignments.assignments["spk_1"]?.assignedBy == .user)
    }
}
