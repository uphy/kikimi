import Foundation

// MARK: - ParticipantHintItem

/// One row of the participant roster for UI display (`docs/design/22-participant-hints.md` section
/// 4.1). `name` is resolved from `MeetingWorkspaceViewModel.knownVoiceprintSpeakers` by id at the
/// moment the roster is (re)built -- `nil` means the id no longer resolves to any registered
/// `VoiceprintSpeaker` (deleted from `voiceprints.json` since being added to this roster, design
/// section 6's "不明な話者" row), which is still a valid, removable roster entry.
struct ParticipantHintItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String?
}

// MARK: - MeetingWorkspaceViewModel + Participants (docs/design/22-participant-hints.md section 3.2/4)

/// Split out of `+Diarization.swift` for the same `file_length`-lint reason as `+Rename.swift`/
/// `+VoiceprintWavFallback.swift`/`+OverrideEnrollment.swift`. Owns `participantHints`'s state and every
/// mutation entry point (`addParticipantHint(_:)`/`removeParticipantHint(id:)`/
/// `autoAddParticipantHint(globalSpeakerId:)`), plus the section 3.2 ViewModel-side rematch fallback for
/// sessions with no live `RealtimeDiarizationCoordinator` (a reopened Ended/Paused session that has not
/// (yet) started recording again).
extension MeetingWorkspaceViewModel {
    // MARK: - Hydration

    /// Restores `participantHints` from `sessions/<id>/participants.json` -- called once from
    /// `onAppear()`, at the same point `initializeSpeakerLabelsFromBackfill()` backfills the rest of
    /// this session's diarization state (design section 4.1: "セッションオープン時...に readParticipants()
    /// で復元する"). Does **not** push to `diarizationCoordinator`: at `onAppear()` time no coordinator
    /// exists yet (one is only ever created lazily from `runRecordingSegmentStart`,
    /// `diarizationCoordinatorIfEnabled()`), which is itself the point that pushes the roster it reads
    /// fresh at creation time (design section 2.2 bullet (a)).
    func initializeParticipantHintsFromBackfill() async {
        let participants = await sessionHandle.readParticipants()
        rebuildParticipantHints(from: participants)
    }

    // MARK: - User-facing mutations (design section 4.1)

    /// Suggest-box submission handler. `.existingSpeaker` adds that id outright (a no-op if already on
    /// the roster, `addParticipantIdIfNeeded(_:)`'s contract); `.newName` is first normalized (design
    /// section 4.3 / `docs/design/20-voiceprint-misassignment-mitigation.md` section 4) the same way
    /// `applyRename(slot:submission:)` normalizes a slot rename -- a trimmed exact match to exactly one
    /// known speaker resolves to that speaker's id, no match registers a brand-new speaker with an
    /// **empty embedding** (design section 1's "suggest box で未登録話者を空 embedding のまま新規登録できる"),
    /// and a same-name duplicate match is an `.ambiguous` row the roster cannot resolve mechanically --
    /// nothing is added, and `participantHintError` carries a message the (not-yet-built, P3) suggest
    /// box can surface.
    func addParticipantHint(_ submission: SpeakerRenameSubmission) async {
        participantHintError = nil
        switch submission {
        case .existingSpeaker(let globalSpeakerId, _):
            await addParticipantIdIfNeeded(globalSpeakerId)
        case .newName(let name):
            switch NormalizedRenameTarget.resolve(name: name, knownSpeakers: knownVoiceprintSpeakers) {
            case .existing(let globalSpeakerId, _):
                await addParticipantIdIfNeeded(globalSpeakerId)
            case .new(let trimmedName):
                do {
                    let speaker = try await voiceprintStore.registerSpeaker(name: trimmedName, embedding: [])
                    await refreshKnownVoiceprintSpeakers()
                    await addParticipantIdIfNeeded(speaker.id)
                } catch {
                    logger.error(
                        """
                        Failed to register a new participant-hint speaker "\(trimmedName, privacy: .public)" for \
                        session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)
                        """
                    )
                    participantHintError = "「\(trimmedName)」を参加者として登録できませんでした。"
                }
            case .ambiguous(let trimmedName):
                logger.info(
                    """
                    Participant hint "\(trimmedName, privacy: .public)" matches more than one known speaker \
                    (duplicate names in voiceprints.json) for session \(self.sessionId, privacy: .public); not \
                    adding to the roster (design section 22 §4.1/§4.3).
                    """
                )
                participantHintError = "「\(trimmedName)」と同じ名前の話者が複数登録されています。既存話者一覧から選んでください。"
            }
        }
    }

    /// Moves `id` from `participant_ids` to `removed_participant_ids` (design section 1.1/4.1) --
    /// `SessionParticipants.removeParticipant(_:)` is what actually makes this the auto-add suppression
    /// list `autoAddParticipantHint(globalSpeakerId:)` consults.
    func removeParticipantHint(id: String) async {
        await persistRosterMutationAndRematch { $0.removeParticipant(id) }
    }

    /// The 4 auto-add hooks' shared entry point (design section 4.2): a no-op if `globalSpeakerId` is
    /// already on the roster **or** already in `removed_participant_ids` (design section 4.1's "既収載・
    /// removed_participant_ids 収載なら no-op" -- a manual removal must not be silently undone by the very
    /// next matching utterance). Never called from an auto voiceprint match's own acceptance (design
    /// section 4.2: "auto 照合...の accepted からは追加しない") -- only from the 4 explicit user-action call
    /// sites in `+Rename.swift`/`+VoiceprintWavFallback.swift`/`+OverrideEnrollment.swift`.
    func autoAddParticipantHint(globalSpeakerId: String) async {
        let current = await sessionHandle.readParticipants()
        guard !current.participantIds.contains(globalSpeakerId), !current.removedParticipantIds.contains(globalSpeakerId) else {
            return
        }
        await persistRosterMutationAndRematch { $0.addParticipant(globalSpeakerId) }
    }

    // MARK: - Private: shared persist + rematch path

    /// `id` already on the roster is a no-op (design section 4.1's "既収載なら no-op") -- checked here,
    /// before `persistRosterMutationAndRematch(_:)`, rather than relying solely on
    /// `SessionParticipants.addParticipant(_:)`'s own idempotency, so an already-present id also skips
    /// the coordinator push / ViewModel-side rematch entirely (not just the file write).
    private func addParticipantIdIfNeeded(_ id: String) async {
        let current = await sessionHandle.readParticipants()
        guard !current.participantIds.contains(id) else { return }
        await persistRosterMutationAndRematch { $0.addParticipant(id) }
    }

    /// Design section 4.1's common path, shared by every mutator above: persist via
    /// `sessionHandle.updateParticipants(_:)`, rebuild `participantHints`, then push the roster onward --
    /// to the live coordinator if one exists, otherwise via the section 3.2 ViewModel-side rematch
    /// fallback. A persistence failure is logged and otherwise swallowed (design section 6:
    /// "updateParticipants の書き込み失敗...メモリ上の名簿と coordinator への push は行う"): even if the write
    /// itself failed, `participantHints`/the push still reflect the caller's intent, and the next
    /// mutation gets another chance to persist it.
    private func persistRosterMutationAndRematch(_ mutate: (inout SessionParticipants) -> Void) async {
        do {
            try await sessionHandle.updateParticipants(mutate)
        } catch {
            logger.error(
                "Failed to persist participants.json for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }

        let participants = await sessionHandle.readParticipants()
        rebuildParticipantHints(from: participants)
        let ids = Set(participants.participantIds)
        if let coordinator = diarizationCoordinator {
            await coordinator.updateParticipantHints(ids)
        } else {
            await rematchAnonymousSlotsViaViewModel(allowedSpeakerIds: ids)
        }
    }

    /// Resolves each roster id's display name from `knownVoiceprintSpeakers` (design section 4.1: `name`
    /// is `nil` when the id no longer resolves to any registered speaker -- "不明な話者").
    private func rebuildParticipantHints(from participants: SessionParticipants) {
        let namesById = Dictionary(uniqueKeysWithValues: knownVoiceprintSpeakers.map { ($0.id, $0.name) })
        participantHints = participants.participantIds.map { ParticipantHintItem(id: $0, name: namesById[$0]) }
    }

    // MARK: - Section 3.2: ViewModel-side rematch (coordinator absent)

    /// Re-matches every eligible anonymous slot against `allowedSpeakerIds`, mirroring
    /// `RealtimeDiarizationCoordinator.rematchAnonymousSlots()`/`+Rematch.swift`'s `rematchSlot(slot:
    /// assignment:)` selection criteria exactly (design section 3.2: "手順は §3 と同一"), but writing
    /// through `sessionHandle` directly instead of a coordinator (there is none -- this is only ever
    /// called from `persistRosterMutationAndRematch(_:)`'s `diarizationCoordinator == nil` branch).
    /// Unlike the coordinator's own rematch, no concurrent live extraction can ever race this call
    /// (design section 3.2: "coordinator 不在 = ライブ抽出が存在しないので §3.1 の交錯は原理的に起きない"), so this
    /// reads `speaker_assignments.json` once and writes every accepted slot's match directly, without
    /// re-validating the roster before each individual write the way the coordinator's own
    /// `writeAutoAssignmentIfAllowed(slot:candidate:embedding:trigger:)` must.
    ///
    /// Not `private`: exercised directly by ViewModel-side rematch unit tests.
    func rematchAnonymousSlotsViaViewModel(allowedSpeakerIds: Set<String>) async {
        let assignments: SpeakerAssignments
        do {
            assignments = try await sessionHandle.readSpeakerAssignments()
        } catch {
            logger.error(
                """
                rematchAnonymousSlotsViaViewModel: failed to read speaker_assignments.json for session \
                \(self.sessionId, privacy: .public); skipping this rematch pass: \(String(describing: error), privacy: .public)
                """
            )
            return
        }

        var didWrite = false
        for (slot, assignment) in assignments.assignments.sorted(by: { $0.key < $1.key }) {
            guard assignment.assignedBy != .user else { continue }
            guard assignment.displayName == nil else { continue }
            guard let embedding = assignment.embedding, !embedding.isEmpty else { continue }

            guard let candidate = await voiceprintStore.findMatchCandidate(
                embedding: embedding, allowedSpeakerIds: allowedSpeakerIds.isEmpty ? nil : allowedSpeakerIds
            ) else { continue }

            let decision = VoiceprintMatchPolicy.decide(
                candidate: candidate,
                threshold: appConfig.data.diarization.speakerMatchThreshold,
                margin: appConfig.data.diarization.speakerMatchMargin
            )
            guard decision == .accepted else { continue }

            if await writeViewModelAutoAssignment(slot: slot, candidate: candidate, embedding: embedding) {
                didWrite = true
            }
        }

        guard didWrite else { return }
        do {
            diarizationAssignments = try await sessionHandle.readSpeakerAssignments()
        } catch {
            logger.error(
                """
                rematchAnonymousSlotsViaViewModel: failed to re-read speaker_assignments.json after writing for \
                session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)
                """
            )
            return
        }
        await recomputeSpeakerLabels()
    }

    /// One slot's `.auto` write for `rematchAnonymousSlotsViaViewModel(allowedSpeakerIds:)`, mirroring
    /// `RealtimeDiarizationCoordinator+Voiceprint.swift`'s `writeAutoAssignmentIfAllowed(slot:candidate:
    /// embedding:trigger:)` -- same `.user` guard, same log shape (design section 3's step 4), tagged
    /// `trigger=rematch source=viewmodel` (design section 3.2: "ログは...source=viewmodel を付ける").
    ///
    /// Also carries the section 3.1 roster re-verification guard, immediately before the write
    /// (design section 3.2: "accepted なら .user guard + §3.1 の名簿再検証込みで書き込み"). This method's
    /// caller, `rematchAnonymousSlotsViaViewModel(allowedSpeakerIds:)`, is itself `async` and iterates
    /// every eligible slot across multiple suspension points (`findMatchCandidate`, this method's own
    /// `updateSpeakerAssignments`); a concurrent `removeParticipantHint(id:)`/`addParticipantHint(_:)`
    /// call can persist a different `participants.json` in between the pass's initial
    /// `allowedSpeakerIds` filter and this slot's write. Unlike the coordinator
    /// (`writeAutoAssignmentIfAllowed`), this actor-isolated ViewModel has no synchronously-readable
    /// `participantHintIds` field to re-check, so the guard re-reads `participants.json` fresh right
    /// here instead of trusting the `allowedSpeakerIds` argument the caller already filtered with.
    private func writeViewModelAutoAssignment(
        slot: String, candidate: VoiceprintStore.VoiceprintMatchCandidate, embedding: [Float]
    ) async -> Bool {
        let match = candidate.speaker

        let currentRoster = Set(await sessionHandle.readParticipants().participantIds)
        guard currentRoster.isEmpty || currentRoster.contains(match.id) else {
            logger.info(
                """
                voiceprint match rejectedByRoster for slot \(slot, privacy: .public): \
                name=\(match.name, privacy: .public) distance=\(candidate.distance, privacy: .public) \
                closedSet=\(!currentRoster.isEmpty) rosterSize=\(currentRoster.count) trigger=rematch source=viewmodel
                """
            )
            return false
        }

        do {
            var skippedDueToUserAssignment = false
            var wrote = false
            try await sessionHandle.updateSpeakerAssignments { assignments in
                var current = assignments.assignments[slot] ?? SlotAssignment()
                guard current.assignedBy != .user else {
                    skippedDueToUserAssignment = true
                    return
                }
                current.globalSpeakerId = match.id
                current.displayName = match.name
                current.assignedBy = .auto
                current.embedding = embedding
                assignments.assignments[slot] = current
                wrote = true
            }
            guard !skippedDueToUserAssignment else {
                logger.debug(
                    "slot \(slot, privacy: .public) already has a user assignment; not overwriting it with the ViewModel-side rematch (trigger=rematch source=viewmodel)"
                )
                return false
            }
            logger.info(
                """
                voiceprint match accepted for slot \(slot, privacy: .public): name=\(match.name, privacy: .public) \
                distance=\(candidate.distance, privacy: .public) trigger=rematch source=viewmodel
                """
            )
            return wrote
        } catch {
            logger.error(
                "failed to write the ViewModel-side rematch for slot \(slot, privacy: .public) (trigger=rematch source=viewmodel): \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }
}
