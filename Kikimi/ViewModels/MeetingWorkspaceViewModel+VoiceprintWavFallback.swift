import Foundation

// MARK: - MeetingWorkspaceViewModel + On-demand WAV voiceprint fallback
// (docs/design/13-speaker-diarization.md section 4.4, "実装時の追記 2026-07-03")

/// Split out of `+Diarization.swift` (itself split out of `MeetingWorkspaceViewModel.swift`) to keep
/// both files under the project's `file_length` lint limit. Owns the on-demand WAV voiceprint
/// fallback: when `+Diarization.swift`'s `applyRename(slot:submission:)` takes the `.localOnly`
/// carve-out (a `.newName` rename whose slot has no captured `SlotAssignment.embedding` yet -- either
/// recorded before R2 shipped, or one whose live extraction simply never crossed
/// `min_enroll_speech_ms` before the user renamed it), this file tries to extract one anyway from
/// this session's own `diarization.jsonl` turns + `audio/system_NNN.wav` files
/// (`VoiceprintWavFallbackExtractor`, `Kikimi/Diarization/VoiceprintWavFallbackExtractor.swift`), so
/// the slot can still register globally instead of being stuck session-local forever.
extension MeetingWorkspaceViewModel {
    /// Production default for `voiceprintWavFallbackExtractorFactory`: a real
    /// `VoiceprintWavFallbackExtractor`, with `minEnrollSpeechMs` resolved from the same
    /// `AppConfig.shared.data.diarization.minEnrollSpeechMs` the live coordinator's own voiceprint gate
    /// uses (design section 4.4's "実装時の追記 2026-07-03" fallback reuses the same threshold, not a
    /// separate config knob). Reads `AppConfig.shared` directly rather than an injected `appConfig`
    /// parameter for the same reason as `defaultDiarizationCoordinatorFactory`
    /// (`+Diarization.swift`): this factory is only ever the production default, never called from a
    /// test.
    static func defaultVoiceprintWavFallbackExtractorFactory(_ sessionHandle: SessionHandle) -> any VoiceprintWavFallbackExtracting {
        VoiceprintWavFallbackExtractor(
            sessionHandle: sessionHandle,
            minEnrollSpeechMs: AppConfig.shared.data.diarization.minEnrollSpeechMs
        )
    }

    /// Kicks off a best-effort, fire-and-forget attempt to extract a voiceprint for `slot` on demand
    /// from this session's own `diarization.jsonl` turns + `audio/system_NNN.wav` files, for the
    /// `.localOnly` carve-out `applyRename(slot:submission:)` (`+Diarization.swift`) just took.
    ///
    /// Never awaited by `applyRename(slot:submission:)`, which has already returned by the time this
    /// finishes: the WeSpeaker model may need a first-run download taking tens of seconds (`Voiceprint
    /// Extractor`'s doc comment), and none of that may block the rename UI or recording/STT (kikimi.md
    /// 8.5 章 / design section 8). Stored in `voiceprintWavFallbackTask` (not `private`) rather than
    /// discarded so `MeetingWorkspaceViewModelTests` can `await` its `.value` for deterministic
    /// assertions -- unlike `diarizationTurnsTask`, this is a single one-shot attempt expected to
    /// finish on its own, so `deinit` needs no equivalent cancellation for it.
    ///
    /// Not `private`: called from `applyRename(slot:submission:)` in `+Diarization.swift`.
    func scheduleVoiceprintWavFallbackEnrollment(slot: String, displayName: String) {
        let extractor = voiceprintWavFallbackExtractorFactory(sessionHandle)
        let currentSessionId = sessionId
        voiceprintWavFallbackTask = Task { [weak self] in
            guard let self else { return }
            self.logger.info(
                """
                Attempting on-demand voiceprint extraction from WAV for slot \(slot, privacy: .public) in \
                session \(currentSessionId, privacy: .public) (first use may download the WeSpeaker model, \
                which can take tens of seconds; this never blocks the UI or recording).
                """
            )

            let embedding: [Float]?
            do {
                embedding = try await extractor.extractEmbedding(forSlot: slot)
            } catch {
                self.logger.warning(
                    """
                    On-demand WAV voiceprint extraction failed for slot \(slot, privacy: .public) in session \
                    \(currentSessionId, privacy: .public); leaving "\(displayName, privacy: .public)" as a \
                    session-local display name only: \(String(describing: error), privacy: .public)
                    """
                )
                return
            }

            guard let embedding, !embedding.isEmpty else {
                self.logger.info(
                    """
                    Not enough attributed speech (or no readable audio) to extract a fallback voiceprint for \
                    slot \(slot, privacy: .public) in session \(currentSessionId, privacy: .public); leaving \
                    "\(displayName, privacy: .public)" as a session-local display name only.
                    """
                )
                return
            }

            await self.persistVoiceprintWavFallback(slot: slot, displayName: displayName, embedding: embedding)
        }
    }

    /// Persists a fallback-extracted embedding, registers it as a brand-new global speaker, and writes
    /// the resulting `globalSpeakerId` back onto `slot` -- called only from
    /// `scheduleVoiceprintWavFallbackEnrollment(slot:displayName:)`'s spawned `Task`, after a non-empty
    /// embedding was actually extracted.
    ///
    /// Guards against clobbering anything that changed while extraction was in flight (a first-run
    /// model download can take tens of seconds): if `slot`'s freshly-read assignment already has *any*
    /// embedding, already has a `globalSpeakerId`, or its `displayName` no longer matches what this
    /// fallback was enrolling (a concurrent live-coordinator extraction, or a second rename, beat this
    /// fallback to it), this defers entirely to whatever is already on disk rather than overwriting it
    /// -- the fallback's whole point is "fill in what's missing", never "overwrite what's already
    /// there or apply a stale name".
    private func persistVoiceprintWavFallback(slot: String, displayName: String, embedding: [Float]) async {
        var slotChangedUnderneathUs = false
        do {
            try await sessionHandle.updateSpeakerAssignments { assignments in
                var current = assignments.assignments[slot] ?? SlotAssignment()
                guard current.embedding == nil, current.globalSpeakerId == nil, current.displayName == displayName else {
                    slotChangedUnderneathUs = true
                    return
                }
                current.embedding = embedding
                assignments.assignments[slot] = current
            }
        } catch {
            logger.error(
                "Failed to persist the WAV-fallback embedding for slot \(slot, privacy: .public) in session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }
        guard !slotChangedUnderneathUs else {
            logger.debug(
                "Slot \(slot, privacy: .public) was already resolved (or renamed again) by the time the WAV voiceprint fallback finished; discarding the fallback embedding."
            )
            return
        }

        let registeredSpeakerId: String
        do {
            let speaker = try await voiceprintStore.registerSpeaker(name: displayName, embedding: embedding)
            registeredSpeakerId = speaker.id
        } catch {
            logger.error(
                """
                Failed to register a new global voiceprint speaker "\(displayName, privacy: .public)" from the \
                WAV fallback for slot \(slot, privacy: .public) in session \(self.sessionId, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """
            )
            return
        }

        do {
            try await sessionHandle.updateSpeakerAssignments { assignments in
                assignments.applyRename(slot: slot, displayName: displayName, globalSpeakerId: registeredSpeakerId)
            }
            diarizationAssignments = try await sessionHandle.readSpeakerAssignments()
        } catch {
            logger.error(
                """
                Failed to write back the WAV-fallback global speaker id for slot \(slot, privacy: .public) in \
                session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)
                """
            )
            return
        }

        await refreshKnownVoiceprintSpeakers()
        // docs/design/22-participant-hints.md section 4.2's "slot リネーム（新規名 + embedding なし →
        // WAV フォールバック）" row: the id only exists once this on-demand extraction/registration
        // succeeds, so the auto-add happens here rather than at the `.localOnly` rename itself.
        await autoAddParticipantHint(globalSpeakerId: registeredSpeakerId)
        await recomputeSpeakerLabels()
    }
}
