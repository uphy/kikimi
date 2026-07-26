import Foundation

// MARK: - SpeakerRenameSubmission

/// What the rename popover's picker submits (`docs/design/13-speaker-diarization.md` section 4.4/6.1):
/// either a brand-new free-typed name, or one of the known global speakers picked from
/// `VoiceprintStore.listSpeakers()`. Distinct from a plain "解除" (clear), which stays a `nil`
/// submission at the call site (`MeetingWorkspaceViewModel.applyRename(slot:submission:)`) rather than
/// a case here -- clearing has no enrollment decision to make.
enum SpeakerRenameSubmission: Equatable, Sendable {
    /// The user typed a name that is not one of the already-known global speakers (design section 4.4
    /// bullet 1, "リネームで新しい名前を入力").
    case newName(String)
    /// The user picked an already-known global speaker from the picker (design section 4.4 bullet 2,
    /// "リネームで既存話者を選択"). `name` is that speaker's current `VoiceprintSpeaker.name` at pick time.
    case existingSpeaker(globalSpeakerId: String, name: String)
}

// MARK: - SpeakerRenameAction

/// What `MeetingWorkspaceViewModel.applyRename(slot:submission:)` should actually do with a
/// `SpeakerRenameSubmission`, given whether the target slot has a captured voiceprint `embedding`
/// yet (`SlotAssignment.embedding`, design section 4.3). Kept as a separate pure result type (rather
/// than inlining the `if`/`else` at the call site) so the enrollment-path decision itself --
/// design section 4.4's three bullets -- is unit-testable without a `VoiceprintStore`/`SessionHandle`
/// round-trip.
enum SpeakerRenameAction: Equatable, Sendable {
    /// "新しい名前を入力" with a captured `embedding`: register a brand-new global speaker with that
    /// embedding, then assign the slot to the newly-registered id (design section 4.4 bullet 1's main
    /// path).
    case registerAndAssign(displayName: String)
    /// "新しい名前を入力" with **no** captured `embedding` yet (slot hasn't accumulated
    /// `min_enroll_speech_ms` of speech, or extraction failed): session-local display name only, no
    /// global registration (design section 4.4 bullet 1's carve-out -- "slot の embedding が null の場合は
    /// セッション内の display_name 保存のみ行い、グローバル登録はスキップする").
    case localOnly(displayName: String)
    /// "既存話者を選択": assign the slot to the picked speaker. Does not touch any embedding *itself*
    /// (design section 4.4 bullet 2) -- neither the slot's own nor the picked speaker's stored
    /// voiceprint. The slot's already-captured `embedding` (if any) is left in place, though, so this
    /// action -- indistinguishable from a correction at this layer -- still becomes that speaker's
    /// Ended-time moving-average sample later (design section 4.4's EMA paragraph), now at the higher
    /// `VoiceprintStore.userCorrectionAlpha` since `assignedBy` is set to `.user` here.
    case assignExisting(globalSpeakerId: String, displayName: String)
}

// MARK: - SpeakerRenameDecision

/// Pure decision function for the rename popover's enrollment paths (design section 4.4). No I/O: the
/// caller (`MeetingWorkspaceViewModel.applyRename(slot:submission:)`) is responsible for actually
/// registering with `VoiceprintStore`/persisting to `speaker_assignments.json` based on the
/// `SpeakerRenameAction` this returns.
enum SpeakerRenameDecision {
    /// - Parameters:
    ///   - submission: What the popover submitted.
    ///   - slotEmbedding: The target slot's captured `SlotAssignment.embedding`, if any (design section
    ///     4.3). Only consulted for `.newName` -- `.existingSpeaker` never depends on it (design section
    ///     4.4 bullet 2 always assigns-only, embedding untouched, regardless of whether the slot itself
    ///     has a captured embedding).
    static func decide(submission: SpeakerRenameSubmission, slotEmbedding: [Float]?) -> SpeakerRenameAction {
        switch submission {
        case .newName(let name):
            if let slotEmbedding, !slotEmbedding.isEmpty {
                return .registerAndAssign(displayName: name)
            }
            return .localOnly(displayName: name)
        case .existingSpeaker(let globalSpeakerId, let name):
            return .assignExisting(globalSpeakerId: globalSpeakerId, displayName: name)
        }
    }
}
