import Foundation

// MARK: - KnownSpeakerSort

/// Pure sort for the rename popover's known-speaker picker (`docs/design/13-speaker-diarization.md`
/// section 6.1): orders `VoiceprintStore.listSpeakers()`'s raw (insertion-order) list so the voice
/// closest to the target slot surfaces first, instead of leaving the user to scan a list ordered by
/// nothing more meaningful than registration order.
///
/// No I/O -- the caller (`RenameSpeakerPopoverView`'s `SlotRenameFieldView`) supplies both the
/// already-fetched speaker list (`MeetingWorkspaceViewModel.knownVoiceprintSpeakers`) and the target
/// slot's own captured voiceprint (`SlotAssignment.embedding`, design section 4.3), and this type does
/// nothing but reorder them. Kept next to `SpeakerRenameDecision.swift` (this popover's other pure
/// decision helper) rather than inside `VoiceprintStore.swift`, since this is a *view* concern (how to
/// present speakers), not a store concern (which stays scoped to persistence/matching).
enum KnownSpeakerSort {
    /// Sorts `speakers` for display against a single slot's `slotEmbedding`.
    ///
    /// - When `slotEmbedding` is non-`nil` and non-empty: every speaker is ordered by ascending
    ///   `VoiceprintStore.cosineDistance(slotEmbedding:embedding:)` (closest voice first). A speaker
    ///   whose stored `embedding` can't actually be compared against `slotEmbedding` -- empty, a
    ///   different length, or containing NaN on either side -- has `cosineDistance` already fall back
    ///   to `Float.infinity` for exactly that reason (see `VoiceprintStore.cosineDistance`'s doc
    ///   comment), and a real cosine distance is always finite (`1 - similarity`, similarity clamped to
    ///   `[-1, 1]`, so the range is `[0, 2]`). That guarantees every unmatchable speaker sorts after
    ///   every matchable one without this function needing its own duplicate validity check.
    /// - When `slotEmbedding` is `nil` or empty (slot hasn't captured a voiceprint yet): there is
    ///   nothing to compare against, so every speaker falls back to descending `updatedAt` (most
    ///   recently seen/renamed speaker first) -- the same tie-break used below, so the two branches
    ///   agree on how to order speakers that are otherwise indistinguishable.
    /// - Ties (equal distance, most commonly two entries that both fell back to `.infinity`) are broken
    ///   by descending `updatedAt` so the ordering is always deterministic rather than depending on
    ///   `speakers`' incoming (insertion) order.
    static func sorted(speakers: [VoiceprintSpeaker], slotEmbedding: [Float]?) -> [VoiceprintSpeaker] {
        guard let slotEmbedding, !slotEmbedding.isEmpty else {
            return speakers.sorted { $0.updatedAt > $1.updatedAt }
        }
        return speakers
            .map { speaker in
                (speaker: speaker, distance: VoiceprintStore.cosineDistance(slotEmbedding, speaker.embedding))
            }
            .sorted { lhs, rhs in
                if lhs.distance != rhs.distance {
                    return lhs.distance < rhs.distance
                }
                return lhs.speaker.updatedAt > rhs.speaker.updatedAt
            }
            .map(\.speaker)
    }
}
