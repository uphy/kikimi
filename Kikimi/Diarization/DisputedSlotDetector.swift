import Foundation

// MARK: - DisputedSlotDetector

/// Pure function identifying which `.auto`-assigned slots this session's "この発言だけ" overrides have
/// effectively contradicted (design section 20 §6.1, "M3: 不信任 auto slot の EMA 除外") -- the
/// contamination-loop circuit breaker: a slot the diarizer auto-matched to an existing speaker, but
/// whose own segments the user then corrected to a *different* name, is almost certainly a fresh
/// misattribution rather than that existing speaker's voice, so it must never feed that speaker's
/// Ended-time moving-average update (`MeetingWorkspaceViewModel+OverrideEnrollment.swift`'s stage 1).
/// No I/O -- the caller supplies the already-loaded `SpeakerAssignments`/turns.
enum DisputedSlotDetector {
    /// - Parameters:
    ///   - assignments: This session's `speaker_assignments.json` (slots + `segmentOverrides`).
    ///   - transcriptSegments: Every transcript segment's id/time-range this session currently knows
    ///     about (`MeetingWorkspaceViewModel.transcriptRows`), used to classify each override's segment
    ///     via `SegmentAttribution`. An override whose segment id has no match here (should not happen
    ///     in practice -- overrides only ever target a segment that already exists) is skipped, matching
    ///     the "can't determine, so don't guess" posture the `.mixed`/`.unattributed` exclusions below
    ///     already take.
    ///   - turns: The session's full `diarization.jsonl` (any slot, any order).
    /// - Returns: The set of slot ids that should be excluded from Ended-time `.auto` EMA candidacy this
    ///   session (design section 6.2). Never includes a `.user`-assigned slot (see below) or a slot with
    ///   no assignment at all (an unassigned/anonymous slot has no `assignedBy == .auto`+name to dispute
    ///   in the first place).
    ///
    /// Per-override adoption rule, mirroring `OverrideEnrollmentSampleResolver`'s own segment-adoption
    /// rule exactly (design section 6.1: "5.3 節の M2 サンプル採用規則と同じ基準"):
    /// - Only an override whose segment's `SegmentAttribution.attribute(...)` resolves to `.single(slot)`
    ///   is considered. `.mixed` is excluded even though the override *might* be naming the secondary
    ///   speaker correctly -- disputing the *primary* slot on that basis would wrongly exclude an
    ///   otherwise-healthy slot from EMA (design section 6.1's explicit rationale). `.unattributed` (a
    ///   "Speaker ?" row override) names no slot at all, so there is nothing to dispute.
    /// - That `.single` slot's own assignment must be `assignedBy == .auto` -- a `.user`-assigned slot is
    ///   never disputed (design section 6.1: an explicit slot-wide rename is a *stronger* signal than a
    ///   later per-segment correction; renaming the slot then overriding one of its segments to a third
    ///   name is a normal "slot is right, just this one utterance is someone else" use, not evidence the
    ///   slot itself is wrong).
    /// - The slot's `displayName` and the override's `displayName` must differ, both **trimmed**. An
    ///   override that merely repeats/confirms the slot's current name is not a dispute.
    static func disputedSlots(
        assignments: SpeakerAssignments,
        transcriptSegments: [AttributableSegment],
        turns: [DiarizationTurn]
    ) -> Set<String> {
        guard !assignments.segmentOverrides.isEmpty else {
            return []
        }

        let segmentsById = Dictionary(uniqueKeysWithValues: transcriptSegments.map { ($0.id, $0) })
        var disputed = Set<String>()

        for (segmentId, override) in assignments.segmentOverrides {
            guard let segment = segmentsById[segmentId] else { continue }
            guard let slot = SegmentAttribution.singleDominantSlot(
                startMs: segment.startMs, endMs: segment.endMs, turns: turns
            ) else {
                continue // `.mixed`/`.unattributed`: not a candidate for dispute.
            }
            guard let slotAssignment = assignments.assignments[slot], slotAssignment.assignedBy == .auto else {
                continue // No assignment at all, or a `.user` slot: never disputed.
            }

            guard !SpeakerName.isSame(slotAssignment.displayName ?? "", override.displayName) else { continue }

            disputed.insert(slot)
        }

        return disputed
    }
}
