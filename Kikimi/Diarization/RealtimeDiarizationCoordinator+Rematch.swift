import Foundation

// MARK: - RealtimeDiarizationCoordinator + Rematch (docs/design/22-participant-hints.md section 3)

/// Split into its own file for the same `file_length`-lint reason as `+Voiceprint.swift`. Owns
/// `rematchAnonymousSlots()`: re-running voiceprint matching (no audio re-extraction -- embeddings are
/// already persisted, design section 3's opening bullet: "embedding は speaker_assignments.json に永続化
/// 済みなので音声の再抽出なしで安価にできる") for every slot the roster newly makes eligible, whenever
/// `updateParticipantHints(_:)` (`RealtimeDiarizationCoordinator.swift`) detects the roster actually
/// changed.
///
/// Only needs `RealtimeDiarizationCoordinator`'s already-`internal` surface (`sessionHandle`/
/// `voiceprintStore`/`speakerMatchThreshold`/`speakerMatchMargin`/`participantHintIds`, plus
/// `+Voiceprint.swift`'s `writeAutoAssignmentIfAllowed(slot:candidate:embedding:trigger:)`), not any
/// `private` member of the primary actor declaration.
extension RealtimeDiarizationCoordinator {
    /// Re-matches every eligible anonymous slot in `speaker_assignments.json` against the *current*
    /// `participantHintIds` (design section 3, steps 1-4). Idempotent (design section 3: "再照合はべき等
    /// （同じ名簿で 2 回呼んでも 2 回目は全滅 or 同一結果）") -- a slot this call already resolved now has a
    /// non-`nil` `displayName`, so a second call with the same roster finds no eligible slots left to
    /// touch. Never touches the extraction milestones (`slotExtractionAttempts`) or triggers a new
    /// extraction: this only re-runs the *matching* step against already-persisted embeddings. The two
    /// paths compose — a milestone re-extraction (design section 5's "実装時の追記 2026-08-01") refreshes the
    /// persisted embedding, and a later rematch pass automatically matches against that newer one.
    ///
    /// Called from `updateParticipantHints(_:)` whenever the roster actually changes (live coordinator
    /// path); `MeetingWorkspaceViewModel+Participants.swift`'s §3.2 fallback reimplements this same
    /// selection/write logic for the coordinator-absent case (a reopened Ended/Paused session that
    /// hasn't started recording yet), since there is no coordinator instance to call this on.
    func rematchAnonymousSlots() async {
        let assignments: SpeakerAssignments
        do {
            assignments = try await sessionHandle.readSpeakerAssignments()
        } catch {
            logger.error(
                "rematchAnonymousSlots: failed to read speaker_assignments.json; skipping this rematch pass: \(String(describing: error), privacy: .public)"
            )
            return
        }

        // Sorted by slot id for deterministic iteration/logging order across runs (the dictionary's own
        // order is not stable) -- matters for test assertions on log/write order, not correctness.
        for (slot, assignment) in assignments.assignments.sorted(by: { $0.key < $1.key }) {
            await rematchSlot(slot: slot, assignment: assignment)
        }
    }

    /// One slot's worth of design section 3 step 2 (eligibility) + step 3 (match-and-write). A no-op for
    /// every slot design section 3 excludes:
    /// - `assignedBy == .user` ("ユーザー確定は不可侵" -- the same protection
    ///   `writeAutoAssignmentIfAllowed`'s own `.user` guard would also catch, but checking it here first
    ///   avoids a pointless `findMatchCandidate` call for a slot that could never be written anyway)
    /// - `displayName != nil` ("実名確定済み。名簿の削除・変更で巻き戻さない" -- this is the one exclusion
    ///   `writeAutoAssignmentIfAllowed` does *not* itself enforce, since the live extraction path only
    ///   ever calls it for a slot it just extracted for the first time, which is always still anonymous)
    /// - `embedding` `nil`/empty (nothing to match against -- mirrors `findMatchCandidate`'s own
    ///   `isFinite` exclusion of empty/reset embeddings, just checked earlier here to skip the actor hop)
    private func rematchSlot(slot: String, assignment: SlotAssignment) async {
        guard assignment.assignedBy != .user else { return }
        guard assignment.displayName == nil else { return }
        guard let embedding = assignment.embedding, !embedding.isEmpty else { return }

        guard let candidate = await voiceprintStore.findMatchCandidate(
            embedding: embedding, allowedSpeakerIds: participantHintIds.isEmpty ? nil : participantHintIds
        ) else {
            return
        }

        let decision = VoiceprintMatchPolicy.decide(
            candidate: candidate, threshold: speakerMatchThreshold, margin: speakerMatchMargin
        )
        guard decision == .accepted else {
            return
        }

        await writeAutoAssignmentIfAllowed(slot: slot, candidate: candidate, embedding: embedding, trigger: "rematch")
    }
}
