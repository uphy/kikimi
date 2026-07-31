import Foundation

// MARK: - MeetingWorkspaceViewModel + Disputed-slot reset
// (docs/design/20-voiceprint-misassignment-mitigation.md §6 "M3" / docs/design/22-participant-hints.md
// §3, 2026-07-07 追記: making a repeated "この発言だけ" correction actually converge the whole slot)

/// Split out of the diarization ViewModel extensions to keep each file under the `file_length` lint.
/// Owns `resetDisputedSlotsAndRematchIfNeeded()`: the piece that makes a per-segment override
/// ("この発言だけ") on a **clean, single-speaker** slot converge the entire slot instead of only the one
/// corrected row.
///
/// Why this is needed on top of the existing machinery: `overrideSegmentSpeaker(segmentId:submission:)`
/// (`+Rename.swift`) only rewrites that one segment's `segment_overrides` entry -- it never touches the
/// slot's own `.auto` assignment -- and the closed-set rematch (`docs/design/22-participant-hints.md`
/// §3) deliberately skips any slot that already carries a `displayName` ("実名確定済み `.auto` slot は
/// 巻き戻さない"). So a slot the diarizer mis-auto-named keeps feeding its wrong name to every *new*
/// segment that lands in it, and correcting them one by one never converges. This reopens exactly the
/// slots the user has demonstrably contradicted (via `DisputedSlotDetector`, the M3 detector that was
/// otherwise unused after the EMA-exclusion path was removed) so the rematch can re-decide them against
/// the now-corrected roster.
extension MeetingWorkspaceViewModel {
    /// Resets every `.auto` slot this session's overrides have *disputed* (an override on a `.single`
    /// segment naming a different person than the slot, `DisputedSlotDetector`) back to anonymous
    /// (`displayName`/`globalSpeakerId` cleared, `embedding` and `assignedBy == .auto` kept), then
    /// re-matches those freshly-anonymized slots against the current roster.
    ///
    /// **Only runs while the roster is non-empty (closed-set matching active).** That guard is
    /// load-bearing, not a mere optimization: with an empty roster the rematch is open-set, so a reset
    /// slot would just re-match to the *same* wrong nearest speaker it had before -- a pointless display
    /// flicker with no convergence. A non-empty roster (which the correcting override's own enrollment
    /// write-back has just populated with the *correct* speaker -- `overrideSegmentSpeaker` /
    /// `writeBackOverrideGlobalSpeakerId`) makes the known-wrong speaker ineligible (it is not on the
    /// roster), so the reset slot re-matches to the corrected speaker instead. This is the scoped
    /// relaxation of design 22 §3's "実名確定 slot は巻き戻さない": we rewind a named slot only when the
    /// user has explicitly contradicted it *and* a closed-set roster guarantees the rewind lands on the
    /// corrected speaker rather than churning back to the wrong one.
    ///
    /// Idempotent and self-limiting: once a reset slot re-matches to the corrected speaker, its
    /// `displayName` now equals the override's name, so `DisputedSlotDetector` no longer reports it as
    /// disputed and a later call leaves it alone. A genuinely mixed slot (`.mixed` attribution) is never
    /// disputed by the detector, so this never rewinds a slot that legitimately holds two speakers
    /// (design 20 §5.3/§6.1's merged-slot carve-out; the residual risk of a merged slot mis-classified as
    /// `.single` degrades to "re-matches to anonymous or one of the two", never worse than the wrong
    /// name it already showed).
    ///
    /// Called from `overrideSegmentSpeaker(segmentId:submission:)` (`+Rename.swift`, the
    /// existing-speaker / already-populated-roster case) and from `writeBackOverrideGlobalSpeakerId(_:
    /// trimmedName:sessionId:)` (`+OverrideEnrollment.swift`, after a brand-new name's stage-2
    /// registration has put it on the roster). Both call it right after `autoAddParticipantHint(...)`, so
    /// the corrected speaker is already on the roster by the time the guard is evaluated.
    func resetDisputedSlotsAndRematchIfNeeded() async {
        guard appConfig.data.diarization.enabled else { return }

        let roster = Set(await sessionHandle.readParticipants().participantIds)
        guard !roster.isEmpty else { return }

        let assignments: SpeakerAssignments
        do {
            assignments = try await sessionHandle.readSpeakerAssignments()
        } catch {
            logger.error(
                """
                resetDisputedSlotsAndRematchIfNeeded: failed to read speaker_assignments.json for session \
                \(self.sessionId, privacy: .public); skipping disputed-slot reset: \(String(describing: error), privacy: .public)
                """
            )
            return
        }

        let segments = transcriptRows.map { AttributableSegment(id: $0.id, startMs: $0.startMs, endMs: $0.endMs) }
        let turns = diarizationTurns.isEmpty ? ((try? await sessionHandle.readDiarizationTurns()) ?? []) : diarizationTurns

        let disputed = DisputedSlotDetector.disputedSlots(
            assignments: assignments, transcriptSegments: segments, turns: turns
        )
        guard !disputed.isEmpty else { return }

        var resetSlots: [String] = []
        do {
            try await sessionHandle.updateSpeakerAssignments { assignments in
                for slot in disputed.sorted() {
                    // Re-check `.auto` inside the write: a slot the user has since renamed slot-wide
                    // (`.user`) must never be rewound (design 22 §3's "ユーザー確定は不可侵").
                    guard var current = assignments.assignments[slot], current.assignedBy == .auto,
                          current.displayName != nil else { continue }
                    current.displayName = nil
                    current.globalSpeakerId = nil
                    assignments.assignments[slot] = current
                    resetSlots.append(slot)
                }
            }
            diarizationAssignments = try await sessionHandle.readSpeakerAssignments()
        } catch {
            logger.error(
                """
                resetDisputedSlotsAndRematchIfNeeded: failed to reset disputed slots for session \
                \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)
                """
            )
            return
        }

        guard !resetSlots.isEmpty else { return }
        logger.info(
            """
            Reset \(resetSlots.count, privacy: .public) disputed .auto slot(s) to anonymous for re-match \
            against the corrected closed-set roster (rosterSize=\(roster.count, privacy: .public)) in session \
            \(self.sessionId, privacy: .public): \(resetSlots.sorted().joined(separator: ","), privacy: .public)
            """
        )

        // Re-match the freshly-anonymized slots via the §3.2 ViewModel-side rematch (which re-reads
        // assignments and recomputes labels). Used even when a live coordinator exists: the coordinator's
        // own `rematchAnonymousSlots()` is not on the `DiarizationCoordinating` protocol (it only fires
        // internally on an actual roster change, and the roster is unchanged here), and the ViewModel-side
        // path is explicitly safe alongside a coordinator -- both write through the same actor-serialized
        // `updateSpeakerAssignments` with the same roster re-verification guard (design 22 §3.2). The
        // The reset leaves those slots anonymous (`displayName == nil`, still `.auto`), which is exactly
        // the state design 13's milestone re-extraction (2026-08-01) requires: if such a slot later
        // crosses its next `min_enroll_speech_ms` milestone the coordinator may re-extract and re-match
        // it too, independently of this pass. That is desirable here (a fresher embedding from more
        // speech is precisely what a disputed slot needs) and order-independent -- both paths write
        // through the same actor-serialized `updateSpeakerAssignments` and the same roster guard.
        await rematchAnonymousSlotsViaViewModel(allowedSpeakerIds: roster)
    }
}
