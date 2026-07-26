import Foundation

// MARK: - MeetingWorkspaceViewModel + Rename (design section 6.1: "リネームはいつでも可能")

/// Split out of `+Diarization.swift` (alongside that file's own split from
/// `MeetingWorkspaceViewModel.swift`, and `+DiarizationEnded.swift`/`+VoiceprintWavFallback.swift`) to
/// keep every one of those files under the project's `file_length` lint limit. Owns every rename/
/// segment-override entry point the popover (`Kikimi/Views/MeetingWorkspace/RenameSpeakerPopoverView.swift`)
/// calls into -- the slot-wide `renameSlot(_:displayName:)`/`applyRename(slot:submission:)` and the
/// per-segment `overrideSegmentSpeaker(segmentId:submission:)` -- plus the free-typed-name
/// normalization (`NormalizedRenameTarget.resolve(name:knownSpeakers:)`,
/// `docs/design/20-voiceprint-misassignment-mitigation.md` section 4) shared by both.
extension MeetingWorkspaceViewModel {
    /// Renames (or clears, `displayName == nil`) a slot's display name in `speaker_assignments.json`,
    /// always as a `.user` assignment (design section 4.3: "`user` 割り当ては `auto` で上書きしない" -- the
    /// protection lives on the *writer* side, i.e. a future voiceprint-match writer would need to check
    /// `assignedBy == .user` before overwriting; this method itself has no competing `.auto` writer to
    /// guard against yet, R2 scope). Every `system` row's label is re-derived immediately afterward so
    /// the rename is reflected without waiting for a new turn (design section 6.1: "同一 slot ... の全
    /// セグメント表示に即時反映される").
    ///
    /// A `SessionHandle.updateSpeakerAssignments(_:)`/`readSpeakerAssignments()` failure is logged and
    /// otherwise swallowed -- `speakerLabels` is left at its previous, already-correct-for-the-old-name
    /// state rather than applying a half-completed rename.
    func renameSlot(_ slot: String, displayName: String?) async {
        do {
            try await sessionHandle.updateSpeakerAssignments { assignments in
                var current = assignments.assignments[slot] ?? SlotAssignment()
                current.displayName = displayName
                current.assignedBy = .user
                assignments.assignments[slot] = current
            }
            diarizationAssignments = try await sessionHandle.readSpeakerAssignments()
        } catch {
            logger.error(
                "Failed to rename slot \(slot, privacy: .public) for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }
        // design section 6.2 "Ended 後のリネーム時": a no-op while not yet Ended.
        await mergeDiarizationParticipantsIfEnded()
        await recomputeSpeakerLabels()
    }

    // MARK: - Segment override (design section 6.1's "この発言だけ", 4.3's `segment_overrides`)

    /// Sets (or clears, `submission == nil`) a per-segment display-name override ("この発言だけ変更",
    /// design section 6.1). Unlike `renameSlot(_:displayName:)` this touches exactly one transcript
    /// row — including rows with no slot at all ("Speaker ?" / "(認識中…)") — and leaves the slot's
    /// own assignment untouched, so clearing the override restores the slot-derived label. Failure
    /// handling mirrors `renameSlot`: log and keep the previous, still-consistent labels.
    ///
    /// `submission` distinguishes "existing speaker picked from the popover" from "new name typed" the
    /// same way `applyRename(slot:submission:)` does (`docs/design/20-voiceprint-misassignment-mitigation.md`
    /// section 5.2): a `.newName` is first normalized (section 4) against `knownVoiceprintSpeakers` --
    /// a trimmed exact match to exactly one known speaker resolves to that speaker's
    /// `globalSpeakerId` (same as if the user had picked it), no match keeps it a brand-new,
    /// not-yet-enrolled name, and a match against more than one (a same-name duplicate in
    /// `voiceprints.json`) saves the display name only, with no `globalSpeakerId` and no enrollment
    /// (section 4's "ambiguous" row; info-logged). This method itself never registers a speaker or
    /// touches `voiceprints.json` directly -- it persists the override, then hands off to
    /// `applyVoiceprintEnrollmentUpdates(assignments:)` (`+OverrideEnrollment.swift`), which learns the
    /// voiceprint from the override segments' own audio and write-backs the resulting `globalSpeakerId`.
    /// That handoff now runs on every override change regardless of state (design section 20 §5.4/§5.5's
    /// 2026-07-07 追記), not only after Ended, so a "この発言だけ" correction learns mid-meeting.
    func overrideSegmentSpeaker(segmentId: String, submission: SpeakerRenameSubmission?) async {
        guard let submission else {
            do {
                try await sessionHandle.updateSpeakerAssignments { assignments in
                    assignments.segmentOverrides.removeValue(forKey: segmentId)
                }
                diarizationAssignments = try await sessionHandle.readSpeakerAssignments()
            } catch {
                logger.error(
                    "Failed to clear the speaker override of segment \(segmentId, privacy: .public) for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                return
            }
            // design section 20 §5.5 "Ended 後の override 変更": a no-op while not yet Ended.
            await mergeDiarizationParticipantsIfEnded()
            await recomputeSpeakerLabels()
            return
        }

        let displayName: String
        var globalSpeakerId: String?

        switch submission {
        case .newName(let name):
            switch NormalizedRenameTarget.resolve(name: name, knownSpeakers: knownVoiceprintSpeakers) {
            case .existing(let id, let resolvedName):
                displayName = resolvedName
                globalSpeakerId = id
            case .new(let trimmedName):
                displayName = trimmedName
            case .ambiguous(let trimmedName):
                displayName = trimmedName
                logger.info(
                    """
                    Segment \(segmentId, privacy: .public) override typed "\(trimmedName, privacy: .public)" \
                    which matches more than one known speaker (duplicate names in voiceprints.json); saving \
                    the display name only and skipping enrollment learning (design section 20 §4).
                    """
                )
            }
        case .existingSpeaker(let id, let name):
            displayName = name
            globalSpeakerId = id
        }

        do {
            try await sessionHandle.updateSpeakerAssignments { assignments in
                assignments.segmentOverrides[segmentId] = SegmentSpeakerOverride(
                    displayName: displayName,
                    globalSpeakerId: globalSpeakerId
                )
            }
            diarizationAssignments = try await sessionHandle.readSpeakerAssignments()
        } catch {
            logger.error(
                "Failed to override the speaker of segment \(segmentId, privacy: .public) for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }
        // design section 20 §5.4/§5.5 (2026-07-07 追記): re-runs enrollment stages 1/2 on **every**
        // override change regardless of state (Recording / Paused / Ended), not only after Ended. A
        // "この発言だけ" correction carries both that segment's own audio and a user-supplied ground-truth
        // label, so it should learn the voiceprint immediately (from the real audio, never an empty
        // embedding) rather than deferring every brand-new name to the meeting-end aggregate. Stage 2's
        // `globalSpeakerId` write-back then adds it to the roster mid-meeting (→ closed-set rematch stops
        // other slots misjudging). The `min_enroll_speech_ms` gate / dedup guard are unchanged: a single
        // very short override still accumulates across corrections before it registers.
        if appConfig.data.diarization.enabled {
            await applyVoiceprintEnrollmentUpdates(assignments: diarizationAssignments)
        }
        await mergeDiarizationParticipantsIfEnded()
        // docs/design/22-participant-hints.md section 4.2: a segment override resolving to an
        // already-known global speaker (existing speaker picked, or a typed name normalized to one)
        // auto-adds it to this session's roster right away. A brand-new name (`globalSpeakerId == nil`)
        // has no id to add yet -- its roster add happens once the enrollment above writes a
        // `globalSpeakerId` back (`writeBackOverrideGlobalSpeakerId` → `autoAddParticipantHint`).
        if let globalSpeakerId {
            await autoAddParticipantHint(globalSpeakerId: globalSpeakerId)
        }
        // 2026-07-07: a per-segment correction that contradicts a clean, single-speaker `.auto` slot's
        // wrong auto-name would otherwise never converge -- the override only fixes that one row, and the
        // closed-set rematch skips already-named slots (design 22 §3). Reopen the disputed slot(s) so the
        // whole slot follows the correction. A no-op unless the roster is now non-empty (a brand-new name
        // whose stage-2 registration hasn't finished yet is instead handled by
        // `writeBackOverrideGlobalSpeakerId`'s own call once it lands on the roster).
        await resetDisputedSlotsAndRematchIfNeeded()
        await recomputeSpeakerLabels()
    }

    // MARK: - Rename popover enrollment paths (design section 4.4/6.1, "R2")

    /// Applies a rename produced by the popover's picker (design section 4.4): `submission == nil` is
    /// "解除" (clear back to anonymous, delegated to `renameSlot(_:displayName:)` unchanged); otherwise
    /// this decides -- via the pure `SpeakerRenameDecision.decide(submission:slotEmbedding:)` -- whether
    /// to register a brand-new global speaker, assign to an already-known one, or save a session-local
    /// display name only, then persists the outcome as a `.user` assignment and propagates it onto
    /// every other slot already sharing the resulting `globalSpeakerId` via `SpeakerAssignments
    /// .applyRename(slot:displayName:globalSpeakerId:)` (design section 6.1: "同じ global_speaker_id を
    /// 持つ全 slot ... 即時反映"). `.registerAndAssign`'s new global speaker is registered with an empty
    /// embedding if the slot somehow has none despite `SpeakerRenameDecision` having chosen this branch
    /// (defensive; not expected in practice since that branch is only chosen when `slotEmbedding` is
    /// non-empty) -- `VoiceprintStore.registerSpeaker` itself has no opinion on embedding length.
    ///
    /// Best-effort per kikimi.md 8.5 章 / design section 8: a `VoiceprintStore.registerSpeaker` failure
    /// is logged and does not block the rest of the rename -- the session-local display name is still
    /// applied (without a `globalSpeakerId`), matching the "slot の embedding が null" carve-out's
    /// spirit of "グローバル登録はスキップするが表示は正しい". A `sessionHandle` persistence failure mirrors
    /// `renameSlot(_:displayName:)`: logged and swallowed, leaving `speakerLabels` at its previous,
    /// still-consistent state.
    ///
    /// Re-reads `speaker_assignments.json` fresh from disk for `slotEmbedding` rather than the cached
    /// `diarizationAssignments` property: a voiceprint-extraction Task the coordinator spawned from its
    /// last `feed`/`persist` calls (`RealtimeDiarizationCoordinator+Voiceprint.swift`'s
    /// `extractAndMatchVoiceprint(slot:samples:)`) is fire-and-forget and persists `SlotAssignment
    /// .embedding` directly to disk even when it finds no global match (so it never yields on
    /// `assignmentUpdates`, design section 5's "the only reaction... is re-read and recompute" note on
    /// that stream applies only to *matches*, not to every persisted embedding) -- the cached property
    /// can therefore lag behind a just-captured embedding for a slot that has never yet been auto-
    /// matched. Falls back to the cached value if the disk read itself fails, so a transient I/O error
    /// degrades to the previous (possibly stale) behavior rather than blocking the rename entirely --
    /// matching this method's existing best-effort posture (`applyDiarizationEndedHooks(updater:)` in
    /// `+DiarizationEnded.swift` uses the same fresh-read pattern for the same reason).
    ///
    /// A `.newName` submission is normalized first (`NormalizedRenameTarget.resolve(name:knownSpeakers:)`,
    /// `docs/design/20-voiceprint-misassignment-mitigation.md` section 4) against `knownVoiceprintSpeakers`:
    /// a trimmed exact match to exactly one known speaker is rewritten into `.existingSpeaker` (so typing
    /// an already-known name never registers a duplicate `VoiceprintSpeaker`), no match proceeds as a
    /// plain (trimmed) `.newName`, and a match against more than one (a same-name duplicate already in
    /// `voiceprints.json`) is diverted to `applyLocalOnlyRename(slot:displayName:)` below -- a
    /// session-local display name only, with **no** `SpeakerRenameDecision`/registration/WAV-fallback
    /// involved at all (unlike the ordinary `.localOnly` action below, which still schedules a WAV
    /// fallback because its reason for skipping registration is a missing embedding, not an ambiguous
    /// name; routing an ambiguous name through that machinery could still end up registering a duplicate
    /// speaker once the fallback extraction succeeds in the background, exactly what section 4 rules out).
    func applyRename(slot: String, submission: SpeakerRenameSubmission?) async {
        guard let submission else {
            await renameSlot(slot, displayName: nil)
            return
        }

        let normalizedSubmission: SpeakerRenameSubmission
        switch submission {
        case .newName(let name):
            switch NormalizedRenameTarget.resolve(name: name, knownSpeakers: knownVoiceprintSpeakers) {
            case .existing(let globalSpeakerId, let resolvedName):
                normalizedSubmission = .existingSpeaker(globalSpeakerId: globalSpeakerId, name: resolvedName)
            case .new(let trimmedName):
                normalizedSubmission = .newName(trimmedName)
            case .ambiguous(let trimmedName):
                logger.info(
                    """
                    Slot \(slot, privacy: .public) rename typed "\(trimmedName, privacy: .public)" which \
                    matches more than one known speaker (duplicate names in voiceprints.json); saving as a \
                    session-local display name only, without registering a new speaker or scheduling \
                    voiceprint learning (design section 20 §4).
                    """
                )
                await applyLocalOnlyRename(slot: slot, displayName: trimmedName)
                return
            }
        case .existingSpeaker:
            normalizedSubmission = submission
        }

        let freshAssignments = (try? await sessionHandle.readSpeakerAssignments()) ?? diarizationAssignments
        let slotEmbedding = freshAssignments.assignments[slot]?.embedding
        let action = SpeakerRenameDecision.decide(submission: normalizedSubmission, slotEmbedding: slotEmbedding)

        let displayName: String
        var globalSpeakerId: String?
        var didRegisterNewSpeaker = false
        var shouldScheduleWavFallback = false

        switch action {
        case .registerAndAssign(let name):
            displayName = name
            do {
                let speaker = try await voiceprintStore.registerSpeaker(name: name, embedding: slotEmbedding ?? [])
                globalSpeakerId = speaker.id
                didRegisterNewSpeaker = true
            } catch {
                logger.error(
                    """
                    Failed to register a new global voiceprint speaker "\(name, privacy: .public)" for slot \
                    \(slot, privacy: .public) in session \(self.sessionId, privacy: .public); saving the \
                    session-local display name only: \(String(describing: error), privacy: .public)
                    """
                )
            }
        case .localOnly(let name):
            displayName = name
            logger.info(
                """
                Slot \(slot, privacy: .public) has no captured voiceprint embedding yet; saving \
                "\(name, privacy: .public)" as a session-local display name only and skipping global \
                registration for now (design section 4.4). A best-effort on-demand WAV extraction is \
                scheduled below in case diarization.jsonl/audio/system_NNN.wav have enough captured \
                speech to enroll after all (design section 4.4, "実装時の追記 2026-07-03").
                """
            )
            shouldScheduleWavFallback = true
        case .assignExisting(let id, let name):
            displayName = name
            globalSpeakerId = id
        }

        do {
            try await sessionHandle.updateSpeakerAssignments { assignments in
                assignments.applyRename(slot: slot, displayName: displayName, globalSpeakerId: globalSpeakerId)
            }
            diarizationAssignments = try await sessionHandle.readSpeakerAssignments()
        } catch {
            logger.error(
                "Failed to persist rename for slot \(slot, privacy: .public) in session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }

        if didRegisterNewSpeaker {
            await refreshKnownVoiceprintSpeakers()
        }
        if shouldScheduleWavFallback {
            scheduleVoiceprintWavFallbackEnrollment(slot: slot, displayName: displayName)
        }
        // docs/design/22-participant-hints.md section 4.2: covers both the "既存話者を選択"
        // (`.assignExisting`) and "新しい名前を入力 + embedding あり" (`.registerAndAssign`, just
        // registered above) hook-table rows -- both leave `globalSpeakerId` non-`nil` here.
        // `.localOnly` (no captured embedding yet) has no id to add yet; its WAV-fallback path adds one
        // itself once/if extraction succeeds (`+VoiceprintWavFallback.swift`).
        if let globalSpeakerId {
            await autoAddParticipantHint(globalSpeakerId: globalSpeakerId)
        }
        // design section 6.2 "Ended 後のリネーム時": a no-op while not yet Ended.
        await mergeDiarizationParticipantsIfEnded()
        await recomputeSpeakerLabels()
    }

    /// Persists `displayName` for `slot` as a plain session-local `.user` assignment -- no
    /// `globalSpeakerId`, no `VoiceprintStore.registerSpeaker` call, no WAV-fallback scheduling.
    /// Used exclusively by `applyRename(slot:submission:)`'s `NormalizedRenameTarget.ambiguous` branch
    /// (`docs/design/20-voiceprint-misassignment-mitigation.md` section 4): unlike the ordinary
    /// `SpeakerRenameAction.localOnly` (missing embedding, not an ambiguous name), an ambiguous name
    /// must never end up registering a new global speaker even in the background, so this bypasses
    /// `SpeakerRenameDecision`/`scheduleVoiceprintWavFallbackEnrollment(slot:displayName:)` entirely
    /// rather than routing through the ordinary `.localOnly` machinery.
    private func applyLocalOnlyRename(slot: String, displayName: String) async {
        do {
            try await sessionHandle.updateSpeakerAssignments { assignments in
                assignments.applyRename(slot: slot, displayName: displayName, globalSpeakerId: nil)
            }
            diarizationAssignments = try await sessionHandle.readSpeakerAssignments()
        } catch {
            logger.error(
                "Failed to persist rename for slot \(slot, privacy: .public) in session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }
        // design section 6.2 "Ended 後のリネーム時": a no-op while not yet Ended.
        await mergeDiarizationParticipantsIfEnded()
        await recomputeSpeakerLabels()
    }

    /// Refreshes `knownVoiceprintSpeakers` from `voiceprintStore.listSpeakers()` (design section 4.4/
    /// 6.1's rename popover picker). Called once from `onAppear()` and again from
    /// `applyRename(slot:submission:)` whenever it registers a brand-new speaker, so the picker offers
    /// it without waiting for the window to be reopened. Diarization being disabled is not a failure --
    /// the popover simply has nothing to render in that case (system rows never resolve to a
    /// renameable slot at all when disabled, design section 5.3's precondition).
    func refreshKnownVoiceprintSpeakers() async {
        guard appConfig.data.diarization.enabled else {
            return
        }
        knownVoiceprintSpeakers = await voiceprintStore.listSpeakers()
    }
}
