import Foundation

// MARK: - MeetingWorkspaceViewModel + Diarization Ended-time hooks (docs/design/13-speaker
// -diarization.md sections 4.4/6.2, "R2 module 4")

/// Split out of `+Diarization.swift` (which itself was split out of `MeetingWorkspaceViewModel.swift`)
/// to keep both files under the project's `file_length` lint limit. Owns the two Ended-only diarization
/// side effects design sections 4.4/6.2 describe:
///
/// 1. **Moving-average voiceprint update** (section 4.4): nudges a global speaker's stored embedding
///    toward this session's captured one, once per speaker, using whichever single slot best
///    represents that speaker this session -- a `.user`-confirmed/corrected slot (α =
///    `VoiceprintStore.userCorrectionAlpha`) when one exists, else the `.auto`-matched slot (α =
///    `VoiceprintStore.defaultMovingAverageAlpha`). A user's explicit pick is a stronger signal than an
///    unreviewed auto-match, so it wins and is weighted more heavily when both exist for the same
///    speaker (e.g. after a correction, or a slot split across a Paused/resume boundary).
/// 2. **participants merge** (section 6.2): merges every named slot's `displayName` into
///    `summary.state.json`'s `participants`, always through `SummaryUpdater.mergeParticipants(_:)` --
///    never a direct read-modify-write of `summary.state.json` (design 6.2's explicit "しない").
///
/// Both are called once from `endMeeting()` (`MeetingWorkspaceViewModel.swift`); the participants
/// merge alone is also re-run for any rename arriving strictly after that Ended transition (design 6.2
/// "Ended 後のリネーム時"), from `+Diarization.swift`'s `renameSlot(_:displayName:)`/`applyRename(slot:
/// submission:)` via `mergeDiarizationParticipantsIfEnded()` below.
extension MeetingWorkspaceViewModel {
    /// Runs both of design section 4.4/6.2's Ended-only diarization side effects, called once from
    /// `endMeeting()` (`MeetingWorkspaceViewModel.swift`) right alongside the existing final-title-
    /// proposal call, using whichever `SummaryUpdater` that call itself used (the still-live
    /// Recording-scoped instance, or a transient one when `endMeeting()` was reached from `.paused`
    /// with no live updater) -- see `endMeeting()`'s own doc comment for why that distinction exists.
    ///
    /// `VoiceprintStore.applyMovingAverageUpdate`'s own `lastMatchedSessionId` dedup guard is what
    /// actually makes step 1 below safe to call again on an `Ended -> Recording -> Ended` reopen
    /// (`reopenRecording()`/a second `endMeeting()`) -- this method has no dedup logic of its own and
    /// relies entirely on that guard.
    ///
    /// Re-reads `speaker_assignments.json` fresh from disk rather than the cached
    /// `diarizationAssignments` property: a voiceprint-extraction/match `Task` the coordinator spawned
    /// from its last `feed`/`persist` calls (`RealtimeDiarizationCoordinator
    /// +Voiceprint.swift`'s `extractAndMatchVoiceprint(slot:samples:)`) is fire-and-forget and may
    /// still be in flight when `endMeeting()` reaches this point, so the cached snapshot could be
    /// stale by the time of the very session-end it's meant to finalize.
    ///
    /// Best-effort throughout (kikimi.md 8.5 章 / design section 8): a read failure here is logged and
    /// skips both steps below entirely, never blocking the rest of `endMeeting()`'s Ended
    /// finalization (title proposal, `recordingButtonState = .ended`).
    ///
    /// Not `private`: called from `endMeeting()` in `MeetingWorkspaceViewModel.swift`.
    func applyDiarizationEndedHooks(updater: SummaryUpdater) async {
        guard appConfig.data.diarization.enabled else {
            return
        }

        let assignments: SpeakerAssignments
        do {
            assignments = try await sessionHandle.readSpeakerAssignments()
        } catch {
            logger.error(
                """
                Failed to read speaker_assignments.json for Ended-time diarization hooks in session \
                \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)
                """
            )
            return
        }

        // `docs/design/20-voiceprint-misassignment-mitigation.md` section 5.4/6.2 ("M2"/"M3"):
        // extends the pre-M2 slot-only moving-average update with override-aggregate samples and
        // disputed-slot exclusion. Lives in `+OverrideEnrollment.swift`, split out for `file_length`.
        await applyVoiceprintEnrollmentUpdates(assignments: assignments)
        await mergeDiarizationParticipants(assignments: assignments, updater: updater)
    }

    /// Design section 6.2's participants merge step, shared by `applyDiarizationEndedHooks(updater:)`
    /// (the Ended transition itself) and `mergeDiarizationParticipantsIfEnded()` below (a rename
    /// arriving after Ended). Collects every slot's non-`nil` `displayName` -- regardless of
    /// `assignedBy` (`.auto` or `.user`; unlike the moving-average step, a user rename is just as
    /// trustworthy a name) -- plus every `segmentOverrides` entry's `displayName`
    /// (`docs/design/20-voiceprint-misassignment-mitigation.md` section 5.6), and hands them all to
    /// `updater.mergeParticipants(_:)`, which owns the exact-match dedup itself (design 6.2: "重複排除:
    /// 完全一致のみ"). A no-op when there is nothing named yet (`mergeParticipants([])` would itself
    /// no-op, but skipping the actor hop entirely here avoids a pointless `summary.state.json` read on
    /// every Ended transition of an anonymous-only session).
    private func mergeDiarizationParticipants(assignments: SpeakerAssignments, updater: SummaryUpdater) async {
        let slotNames = assignments.assignments.values.compactMap(\.displayName)
        let overrideNames = assignments.segmentOverrides.values.map(\.displayName)
        let names = slotNames + overrideNames
        guard !names.isEmpty else { return }
        await updater.mergeParticipants(names)
    }

    /// Design section 6.2 "Ended 後のリネーム時": once a session has reached Ended, `renameSlot(_:
    /// displayName:)`/`applyRename(slot:submission:)` naming a slot should reflect into
    /// `summary.state.json`'s `participants` immediately -- unlike `applyDiarizationEndedHooks(
    /// updater:)`, which only ever runs from the one-shot `endMeeting()` transition, this covers every
    /// rename after that point (there is no live `SummaryUpdater` left to reuse by then, so this
    /// always constructs a transient one via `summaryUpdaterFactory`, the same pattern `endMeeting()`
    /// itself uses when reached from `.paused`). A no-op while `meta.state != .ended` (Recording/Paused/
    /// Draft): design 6.2 "Recording 中は反映しない" -- Recording-time `participants` stays the LLM
    /// patch's job alone (kikimi.md 8 章), and `applyDiarizationEndedHooks(updater:)` above is the one
    /// and only path for the Ended transition itself, so this only ever needs to cover renames
    /// strictly *after* that transition already happened.
    ///
    /// Reads the freshly-refreshed `diarizationAssignments` cached property rather than re-reading
    /// from disk: every call site in `+Diarization.swift` refreshes it (`try await sessionHandle
    /// .readSpeakerAssignments()`) immediately before calling this, so it is already current.
    ///
    /// Not `private`: called from `renameSlot(_:displayName:)`/`applyRename(slot:submission:)` in
    /// `+Diarization.swift`.
    func mergeDiarizationParticipantsIfEnded() async {
        guard meta.state == .ended else { return }
        let transientUpdater = summaryUpdaterFactory(sessionHandle)
        await mergeDiarizationParticipants(assignments: diarizationAssignments, updater: transientUpdater)
    }
}
