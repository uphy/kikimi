import Foundation

// MARK: - MeetingWorkspaceViewModel + Override-aggregate enrollment
// (`docs/design/20-voiceprint-misassignment-mitigation.md` sections 5.3-5.5, "M2")

/// Split out of `+DiarizationEnded.swift` (itself split out of `MeetingWorkspaceViewModel.swift`) to
/// keep both files under the project's `file_length` lint limit, mirroring `+VoiceprintWavFallback
/// .swift`'s own split. Owns Ended-time enrollment learning from "この発言だけ" overrides
/// (`SegmentSpeakerOverride`): winner selection across `.user` slot / override-aggregate sample --
/// never an unreviewed `.auto` slot (design section 4.4/5.4's stage 1, synchronous), the fire-and-forget
/// extraction + persistence for an override-aggregate winner (stage 2), and the section 5.5 reopen
/// recovery for a stage 2 that never finished.
extension MeetingWorkspaceViewModel {
    /// Production default for `overrideEnrollmentExtractorFactory`: a real `OverrideEnrollmentExtractor`.
    static func defaultOverrideEnrollmentExtractorFactory(_ sessionHandle: SessionHandle) -> any OverrideEnrollmentExtracting {
        OverrideEnrollmentExtractor(sessionHandle: sessionHandle)
    }

    // MARK: - Identity grouping (design section 5.4's "identity の定義")

    /// One enrollment identity this session has any signal for at all: either an already-known global
    /// speaker (a slot's `globalSpeakerId`, or an override that names/normalizes to one), or a
    /// not-yet-registered new name (an override whose typed name matched no known speaker, keyed by its
    /// trimmed form so every override sharing that exact name is treated as one person, design section
    /// 5.4: "同名の override は 1 identity に束ねる").
    enum EnrollmentIdentity: Hashable {
        case existingSpeaker(globalSpeakerId: String)
        case newName(trimmedName: String)
    }

    /// Every candidate this session has for one `EnrollmentIdentity`, gathered from both
    /// `SpeakerAssignments.assignments` (slots) and `.segmentOverrides` before winner selection runs.
    /// A `.newName` identity's `userSlots` is always empty (a brand-new name was never assigned to any
    /// slot -- if it had been, it would already carry a `globalSpeakerId` and resolve to
    /// `.existingSpeaker` instead), so only `overrideSegments` ever applies to it.
    private struct EnrollmentCandidateGroup {
        var userSlots: [(slot: String, assignment: SlotAssignment)] = []
        var overrideSegments: [AttributableSegment] = []

        /// `.auto` slots never enter here: an auto match the user never corrected/confirmed must not
        /// feed back into the voiceprint on its own (design section 4.4's "explicit feedback only"
        /// requirement) -- only a `.user` slot or an override counts as a winner candidate.
        mutating func add(slot: String, assignment: SlotAssignment) {
            guard assignment.assignedBy == .user else { return }
            userSlots.append((slot, assignment))
        }
    }

    // MARK: - Stage 1 (synchronous): winner selection

    /// Design section 5.4's Ended-time winner selection, extended from the pre-M2 `.user`/`.auto`
    /// slot-only version (`+DiarizationEnded.swift`'s old `applyVoiceprintMovingAverageUpdates`) to also
    /// consider override-aggregate samples. An `.auto` slot the user never touched is **never** a
    /// winner candidate -- design section 4.4 requires explicit user feedback (a `.user` slot
    /// assignment or an override) before the voiceprint learns anything at all, so an unreviewed auto
    /// match by itself must leave the stored embedding untouched.
    /// Called from `applyDiarizationEndedHooks(updater:)` (`+DiarizationEnded.swift`) at the Ended
    /// transition, from `overrideSegmentSpeaker(segmentId:submission:)` (`+Rename.swift`) on **every**
    /// override change regardless of state (Recording / Paused / Ended -- design section 5.4/5.5's
    /// 2026-07-07 追記, so a correction learns from that segment's own audio mid-meeting rather than
    /// deferring to Ended), and from `recoverIncompleteOverrideEnrollmentsIfNeeded()` below (section
    /// 5.5's reopen recovery).
    ///
    /// Groups every slot with a `globalSpeakerId` and every `segmentOverrides` entry (resolved to an
    /// identity via its own `globalSpeakerId`, `NormalizedRenameTarget`-based name normalization, or a
    /// brand-new trimmed-name group) by `EnrollmentIdentity`, then picks **at most one winner per
    /// identity per session**, in priority order (design section 5.4/6.2):
    /// 1. A `.user` slot with a captured `embedding` -- applied immediately, `userCorrectionAlpha`.
    /// 2. An override-aggregate sample (`OverrideEnrollmentSampleResolver`) -- handed to stage 2
    ///    (`scheduleOverrideEnrollment(identity:slices:sessionId:)`) if the resolver found enough clean
    ///    speech.
    ///
    /// No candidate at all (no `.user` slot and no usable override) is an info-logged skip, never an
    /// error (design section 8).
    func applyVoiceprintEnrollmentUpdates(assignments: SpeakerAssignments) async {
        let segments = transcriptRows.map { AttributableSegment(id: $0.id, startMs: $0.startMs, endMs: $0.endMs) }
        let turns = diarizationTurns.isEmpty ? ((try? await sessionHandle.readDiarizationTurns()) ?? []) : diarizationTurns
        let recordings = await sessionHandle.meta.recordings

        // Fetched fresh here (not `knownVoiceprintSpeakers`, the `@Published` UI cache) -- this is
        // what makes reopen recovery (`recoverIncompleteOverrideEnrollmentsIfNeeded()` below) resolve
        // correctly: `onAppear()` calls that method before anything has ever populated
        // `knownVoiceprintSpeakers` for this window instance, so relying on the cache here would make
        // `resolveOverrideIdentity` always see `[]` and re-register a duplicate speaker for every
        // un-written-back new-name override on every reopen.
        let knownSpeakers = await voiceprintStore.listSpeakers()

        var groups: [EnrollmentIdentity: EnrollmentCandidateGroup] = [:]
        for (slot, assignment) in assignments.assignments {
            guard let globalSpeakerId = assignment.globalSpeakerId else { continue }
            groups[.existingSpeaker(globalSpeakerId: globalSpeakerId), default: EnrollmentCandidateGroup()]
                .add(slot: slot, assignment: assignment)
        }

        let segmentsById = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        for (segmentId, override) in assignments.segmentOverrides {
            guard let segment = segmentsById[segmentId] else { continue }
            guard let identity = resolveOverrideIdentity(override, segmentId: segmentId, knownSpeakers: knownSpeakers) else { continue }
            groups[identity, default: EnrollmentCandidateGroup()].overrideSegments.append(segment)
        }

        for (identity, group) in groups {
            await resolveWinner(identity: identity, group: group, turns: turns, recordings: recordings)
        }
    }

    /// Design section 5.4's "identity の定義": an override's `globalSpeakerId` if set, else
    /// `NormalizedRenameTarget`-based resolution of its typed name (an exact-match existing speaker, or
    /// a brand-new trimmed-name group), else `nil` for an ambiguous (same-name-duplicate) match, which
    /// design section 4 rules out of both registration and Ended-time learning entirely.
    ///
    /// - Parameter knownSpeakers: The caller's freshly-fetched `voiceprintStore.listSpeakers()` --
    ///   **not** `knownVoiceprintSpeakers` (see `applyVoiceprintEnrollmentUpdates(assignments:)`'s doc
    ///   comment for why the fresh fetch is load-bearing).
    private func resolveOverrideIdentity(
        _ override: SegmentSpeakerOverride, segmentId: String, knownSpeakers: [VoiceprintSpeaker]
    ) -> EnrollmentIdentity? {
        if let globalSpeakerId = override.globalSpeakerId {
            return .existingSpeaker(globalSpeakerId: globalSpeakerId)
        }
        switch NormalizedRenameTarget.resolve(name: override.displayName, knownSpeakers: knownSpeakers) {
        case .existing(let globalSpeakerId, _):
            return .existingSpeaker(globalSpeakerId: globalSpeakerId)
        case .new(let trimmedName):
            return .newName(trimmedName: trimmedName)
        case .ambiguous(let trimmedName):
            logger.info(
                """
                Segment \(segmentId, privacy: .public) override "\(trimmedName, privacy: .public)" matches more \
                than one known speaker; excluding it from Ended-time enrollment (design section 20 §4/§5.4).
                """
            )
            return nil
        }
    }

    private func resolveWinner(
        identity: EnrollmentIdentity,
        group: EnrollmentCandidateGroup,
        turns: [DiarizationTurn],
        recordings: [RecordingSegment]
    ) async {
        if let userWinner = group.userSlots.filter({ $0.assignment.embedding != nil }).min(by: { $0.slot < $1.slot }),
           let embedding = userWinner.assignment.embedding,
           let globalSpeakerId = userWinner.assignment.globalSpeakerId {
            await applySlotEmbeddingWinner(globalSpeakerId: globalSpeakerId, embedding: embedding, alpha: VoiceprintStore.userCorrectionAlpha)
            return
        }

        if !group.overrideSegments.isEmpty {
            let slices = OverrideEnrollmentSampleResolver.resolveSampleSlices(
                segments: group.overrideSegments,
                turns: turns,
                recordings: recordings,
                minEnrollSpeechMs: appConfig.data.diarization.minEnrollSpeechMs
            )
            if let slices {
                scheduleOverrideEnrollment(identity: identity, slices: slices)
                return
            }
            logger.info(
                """
                Override-aggregate sample for \(String(describing: identity), privacy: .public) had too \
                little/impure speech; skipping (design section 4.4/20 §5.4/§8 -- an unreviewed .auto slot \
                is never a fallback candidate).
                """
            )
        }

        logger.info(
            """
            No Ended-time enrollment candidate for \(String(describing: identity), privacy: .public) (no .user \
            slot, no usable override aggregate); skipping (design section 4.4/20 §5.4/§8).
            """
        )
    }

    /// Applies the winning slot-embedding candidate immediately (stage 1). `globalSpeakerId` is
    /// `userWinner`'s own `SlotAssignment.globalSpeakerId` -- always non-nil there by construction
    /// (`EnrollmentCandidateGroup.add(slot:assignment:)` is only ever invoked from
    /// `applyVoiceprintEnrollmentUpdates(assignments:)`'s loop over `assignments.assignments`, which
    /// already `guard let`-filters out any assignment with a `nil` `globalSpeakerId` before adding it to
    /// a group), so this no longer needs its own defensive `EnrollmentIdentity` pattern match.
    private func applySlotEmbeddingWinner(globalSpeakerId: String, embedding: [Float], alpha: Double) async {
        do {
            try await voiceprintStore.applyMovingAverageUpdate(
                speakerId: globalSpeakerId, newEmbedding: embedding, sessionId: sessionId, alpha: alpha
            )
        } catch {
            logger.error(
                """
                Failed to apply the Ended-time moving-average update for speaker \(globalSpeakerId, privacy: .public) \
                in session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)
                """
            )
        }
    }

    // MARK: - Stage 2 (fire-and-forget): extraction + persistence

    /// Design section 5.4's stage 2: extracts an embedding from `slices` in the background (same
    /// fire-and-forget shape as `+VoiceprintWavFallback.swift`'s `scheduleVoiceprintWavFallbackEnrollment
    /// (slot:displayName:)`) and persists it once done. Appended to `overrideEnrollmentTasks` (not
    /// discarded) so tests can await every spawned attempt deterministically.
    ///
    /// Guarded by `pendingOverrideEnrollmentIdentities` (`MeetingWorkspaceViewModel.swift`): a second
    /// `applyVoiceprintEnrollmentUpdates(assignments:)` pass for the *same* `identity` while an earlier
    /// stage 2 attempt is still in flight -- e.g. a post-Ended override edit re-running enrollment while
    /// the first WeSpeaker extraction (tens of seconds on first model download) hasn't finished -- must
    /// not schedule a second concurrent extraction/registration attempt for it. The check-and-insert
    /// below is one synchronous (no `await`) statement on this `@MainActor` type, so two calls racing
    /// through `resolveWinner(identity:group:turns:recordings:)` can never both observe "not yet
    /// pending" for the same identity.
    private func scheduleOverrideEnrollment(identity: EnrollmentIdentity, slices: [EnrollmentSampleSlice]) {
        guard pendingOverrideEnrollmentIdentities.insert(identity).inserted else {
            logger.debug(
                """
                An override-aggregate enrollment for \(String(describing: identity), privacy: .public) is already \
                in flight in session \(self.sessionId, privacy: .public); not scheduling a duplicate attempt.
                """
            )
            return
        }
        let extractor = overrideEnrollmentExtractorFactory(sessionHandle)
        let currentSessionId = sessionId
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.pendingOverrideEnrollmentIdentities.remove(identity) }
            let embedding: [Float]?
            do {
                embedding = try await extractor.extractEmbedding(slices: slices)
            } catch {
                self.logger.warning(
                    """
                    Override-aggregate voiceprint extraction failed for \(String(describing: identity), privacy: .public) \
                    in session \(currentSessionId, privacy: .public); not falling back to a slot embedding \
                    (design section 20 §5.4/§8): \(String(describing: error), privacy: .public)
                    """
                )
                return
            }
            guard let embedding, !embedding.isEmpty else {
                self.logger.info(
                    """
                    Override-aggregate extraction for \(String(describing: identity), privacy: .public) in session \
                    \(currentSessionId, privacy: .public) produced no usable audio; skipping enrollment this session.
                    """
                )
                return
            }
            await self.persistOverrideEnrollment(identity: identity, embedding: embedding, sessionId: currentSessionId)
        }
        overrideEnrollmentTasks.append(task)
    }

    /// Design section 5.4's stage 2, step 2/3: an existing-speaker identity gets a `userCorrectionAlpha`
    /// moving-average update; a new-name identity is registered as a brand-new global speaker and its
    /// `globalSpeakerId` is written back onto every `segmentOverrides` entry still sharing this trimmed
    /// name with no `globalSpeakerId` of its own yet (so a later Ended re-run resolves it directly
    /// instead of via name normalization, and never re-registers a duplicate).
    ///
    /// The `.newName` branch re-checks on-disk state before registering anything (mirrors `+Voiceprint
    /// WavFallback.swift`'s `persistVoiceprintWavFallback(slot:displayName:embedding:)`'s own
    /// re-check-before-persisting pattern): `pendingOverrideEnrollmentIdentities`
    /// (`scheduleOverrideEnrollment(identity:slices:)`) already prevents two *concurrent* attempts for
    /// the same identity within one `MeetingWorkspaceViewModel` instance, but a second, *sequential*
    /// stage 2 run for what normalizes to the same trimmed name (a later Ended re-run, or a reopened
    /// window that's a fresh instance with an empty in-flight set) can still race a still-in-flight
    /// extraction from an earlier run whose task hasn't reached this point yet. Re-checking here closes
    /// that window without needing any additional in-memory bookkeeping.
    private func persistOverrideEnrollment(identity: EnrollmentIdentity, embedding: [Float], sessionId: String) async {
        switch identity {
        case .existingSpeaker(let globalSpeakerId):
            do {
                try await voiceprintStore.applyMovingAverageUpdate(
                    speakerId: globalSpeakerId, newEmbedding: embedding, sessionId: sessionId, alpha: VoiceprintStore.userCorrectionAlpha
                )
            } catch {
                logger.error(
                    """
                    Failed to apply the override-aggregate Ended-time moving-average update for speaker \
                    \(globalSpeakerId, privacy: .public) in session \(sessionId, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """
                )
            }
        case .newName(let trimmedName):
            let freshAssignments: SpeakerAssignments
            do {
                freshAssignments = try await sessionHandle.readSpeakerAssignments()
            } catch {
                logger.error(
                    """
                    Failed to re-read speaker_assignments.json before persisting override-aggregate enrollment for \
                    "\(trimmedName, privacy: .public)" in session \(sessionId, privacy: .public); falling back to the \
                    cached assignments: \(String(describing: error), privacy: .public)
                    """
                )
                freshAssignments = diarizationAssignments
            }

            // A concurrent/earlier stage 2 run for this same trimmed name may have already registered
            // and written back a `globalSpeakerId` while this run's extraction was in flight -- if so,
            // that run already won; registering again here would create a duplicate same-name speaker.
            let alreadyWrittenBack = freshAssignments.segmentOverrides.values.contains {
                $0.globalSpeakerId != nil && SpeakerName.isSame($0.displayName, trimmedName)
            }
            guard !alreadyWrittenBack else {
                logger.debug(
                    """
                    A concurrent/earlier override-aggregate enrollment for "\(trimmedName, privacy: .public)" in \
                    session \(sessionId, privacy: .public) already wrote back a globalSpeakerId; skipping this \
                    duplicate registration.
                    """
                )
                return
            }

            // Also re-resolve the trimmed name against the freshest known-speaker list: a name that was
            // brand-new when stage 1 ran may have since been registered by a different path (e.g. the
            // rename popover, or another identity's own stage 2 for a name that collides once trimmed).
            let freshKnownSpeakers = await voiceprintStore.listSpeakers()
            let matches = freshKnownSpeakers.filter { SpeakerName.isSame($0.name, trimmedName) }
            if matches.count == 1 {
                let existingSpeakerId = matches[0].id
                do {
                    try await voiceprintStore.applyMovingAverageUpdate(
                        speakerId: existingSpeakerId, newEmbedding: embedding, sessionId: sessionId, alpha: VoiceprintStore.userCorrectionAlpha
                    )
                } catch {
                    logger.error(
                        """
                        Failed to apply the override-aggregate Ended-time moving-average update for speaker \
                        \(existingSpeakerId, privacy: .public) (resolved from "\(trimmedName, privacy: .public)") in \
                        session \(sessionId, privacy: .public): \(String(describing: error), privacy: .public)
                        """
                    )
                }
                await writeBackOverrideGlobalSpeakerId(existingSpeakerId, trimmedName: trimmedName, sessionId: sessionId)
                return
            }
            if matches.count > 1 {
                logger.info(
                    """
                    "\(trimmedName, privacy: .public)" now matches more than one known speaker (duplicate names in \
                    voiceprints.json) by the time override-aggregate enrollment in session \
                    \(sessionId, privacy: .public) finished; skipping registration/write-back (design section 20 §4).
                    """
                )
                return
            }

            let registeredSpeakerId: String
            do {
                let speaker = try await voiceprintStore.registerSpeaker(name: trimmedName, embedding: embedding)
                registeredSpeakerId = speaker.id
            } catch {
                logger.error(
                    """
                    Failed to register a new global voiceprint speaker "\(trimmedName, privacy: .public)" from \
                    override-aggregate enrollment in session \(sessionId, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """
                )
                return
            }
            await writeBackOverrideGlobalSpeakerId(registeredSpeakerId, trimmedName: trimmedName, sessionId: sessionId)
        }
    }

    /// Writes `globalSpeakerId` back onto every `segmentOverrides` entry still sharing `trimmedName`
    /// with no `globalSpeakerId` of its own yet -- shared by `persistOverrideEnrollment(identity:
    /// embedding:sessionId:)`'s "brand-new registration" and "resolved to an already-known speaker"
    /// outcomes, which differ only in where `globalSpeakerId` came from.
    private func writeBackOverrideGlobalSpeakerId(_ globalSpeakerId: String, trimmedName: String, sessionId: String) async {
        do {
            try await sessionHandle.updateSpeakerAssignments { assignments in
                for (segmentId, override) in assignments.segmentOverrides {
                    guard override.globalSpeakerId == nil, SpeakerName.isSame(override.displayName, trimmedName) else { continue }
                    assignments.segmentOverrides[segmentId] = SegmentSpeakerOverride(
                        displayName: override.displayName, globalSpeakerId: globalSpeakerId
                    )
                }
            }
            diarizationAssignments = try await sessionHandle.readSpeakerAssignments()
        } catch {
            logger.error(
                """
                Failed to write back the override-aggregate global speaker id for "\(trimmedName, privacy: .public)" \
                in session \(sessionId, privacy: .public): \(String(describing: error), privacy: .public)
                """
            )
            return
        }
        await refreshKnownVoiceprintSpeakers()
        // docs/design/22-participant-hints.md section 4.2's "segment override... Ended 時 enrollment
        // の write-back" row: only meaningful once a `globalSpeakerId` actually lands here.
        await autoAddParticipantHint(globalSpeakerId: globalSpeakerId)
        // 2026-07-07: now that this brand-new name is registered and on the roster, reopen any slot the
        // override contradicted so the whole slot re-matches to it (mirrors `overrideSegmentSpeaker`'s
        // existing-speaker call; a no-op there earlier because this name wasn't on the roster yet).
        await resetDisputedSlotsAndRematchIfNeeded()
        await recomputeSpeakerLabels()
    }

    // MARK: - Section 5.5: reopen recovery

    /// Design section 5.5's "未完了 enrollment の回収": called once from `onAppear()`
    /// (`MeetingWorkspaceViewModel.swift`), right after `initializeSpeakerLabelsFromBackfill()` backfills
    /// `diarizationAssignments`. A no-op unless this session has already reached Ended and still has at
    /// least one `segmentOverrides` entry with no `globalSpeakerId` -- stage 2's fire-and-forget task may
    /// never have finished (write-back included) if the app quit right after `endMeeting()`. Re-running
    /// stage 1/2 here is idempotent even for an override that already *did* finish (it now carries a
    /// `globalSpeakerId`, or resolves via name normalization to the same existing speaker either way),
    /// so no extra bookkeeping is needed to avoid a double-run.
    ///
    /// Reads `state` fresh from `sessionHandle.meta` (the same actor-isolated source
    /// `hydrateFromSessionHandle()` reads from) rather than the `@Published meta` property: `init` seeds
    /// `meta` with a `.draft` placeholder that `hydrateFromSessionHandle()` replaces via an unstructured
    /// `Task` with no ordering guarantee against `onAppear()` (`MeetingWorkspaceViewModel.swift`'s
    /// `init`/`hydrateFromSessionHandle()` doc comments) -- gating on the cached property could read the
    /// placeholder and silently skip recovery for a session that actually is Ended.
    func recoverIncompleteOverrideEnrollmentsIfNeeded() async {
        guard appConfig.data.diarization.enabled else { return }
        let freshState = await sessionHandle.meta.state
        guard freshState == .ended else { return }
        guard diarizationAssignments.segmentOverrides.values.contains(where: { $0.globalSpeakerId == nil }) else { return }
        await applyVoiceprintEnrollmentUpdates(assignments: diarizationAssignments)
    }

    /// Test-only: awaits every `Task` `scheduleOverrideEnrollment(identity:slices:)` has spawned so far,
    /// mirroring how existing tests `await voiceprintWavFallbackTask?.value`. Not `private` for the same
    /// reason as that property.
    func waitForPendingOverrideEnrollmentTasks() async {
        for task in overrideEnrollmentTasks {
            await task.value
        }
    }
}
