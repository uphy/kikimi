import FluidAudio
import Foundation

// MARK: - RealtimeDiarizationCoordinator + Voiceprint (docs/design/13-speaker-diarization.md section 5/4.3, "R2")

/// Split into its own file (alongside `MeetingWorkspaceViewModel`'s `+Diarization.swift`/`+Summary.swift`
/// extensions) to keep `RealtimeDiarizationCoordinator.swift` under the project's `file_length` lint
/// limit. Owns the entire event-driven voiceprint pipeline built on top of that file's `persist(_:)`
/// call: accumulating each slot's own speech audio out of the per-generation raw sample buffer, and — once
/// a slot crosses `minEnrollSpeechMs` — extracting a WeSpeaker embedding exactly once and matching it
/// against the global `voiceprints.json` DB.
///
/// Only needs `RealtimeDiarizationCoordinator`'s already-`internal` surface (see that file's "Not
/// `private`: ... `+Voiceprint.swift`" doc-comment notes), not any `private` member of the primary
/// actor declaration.
extension RealtimeDiarizationCoordinator {
    // MARK: - Generation audio buffer (voiceprint slicing source)

    /// Appends newly-fed samples to `generationSampleBuffer`, then trims from the front once it exceeds
    /// `generationBufferRetentionSampleCount` (see that constant's doc comment for the memory-bounding
    /// rationale). `generationBufferBaseSampleIndex` is advanced by exactly however much was trimmed so
    /// `sliceGenerationBuffer(startSample:endSample:)` keeps translating absolute sample positions
    /// correctly.
    func appendToGenerationBuffer(_ samples: [Float]) {
        generationSampleBuffer.append(contentsOf: samples)
        let overflow = generationSampleBuffer.count - Self.generationBufferRetentionSampleCount
        guard overflow > 0 else {
            return
        }
        generationSampleBuffer.removeFirst(overflow)
        generationBufferBaseSampleIndex += overflow
    }

    /// Clamps a `DiarizerSegment`'s absolute-within-generation sample range into
    /// `generationSampleBuffer`'s current (possibly already front-trimmed) bounds, returning whatever
    /// portion is still retained. Never throws/crashes on an out-of-range request (e.g. a segment
    /// finalizing later than `generationBufferRetentionSampleCount` allows for) — it simply returns a
    /// shorter, possibly empty, slice, matching this whole feature's best-effort contract (design
    /// section 8): losing part of one slot's voiceprint contribution is invisible to the user, unlike
    /// losing a transcript segment.
    func sliceGenerationBuffer(startSample: Int, endSample: Int) -> [Float] {
        let localStart = startSample - generationBufferBaseSampleIndex
        let localEnd = endSample - generationBufferBaseSampleIndex
        let clampedStart = max(0, min(localStart, generationSampleBuffer.count))
        let clampedEnd = max(clampedStart, min(localEnd, generationSampleBuffer.count))
        guard clampedEnd > clampedStart else {
            return []
        }
        return Array(generationSampleBuffer[clampedStart..<clampedEnd])
    }

    // MARK: - Voiceprint extraction & matching (design section 5, "声紋照合（イベント駆動）")

    /// Slices this segment's own speech audio out of `generationSampleBuffer` and appends it to
    /// `pendingSlotAudio[slot]`, then triggers one-shot voiceprint extraction the moment the slot's
    /// cumulative accumulated audio reaches `minEnrollSpeechMs` (design section 5). A no-op for a slot
    /// that has already had extraction triggered (`extractedSlots`) — this is where the "one shot, never
    /// re-extract" contract is actually enforced.
    ///
    /// Called from `RealtimeDiarizationCoordinator.persist(_:)` for every finalized `DiarizerSegment`,
    /// regardless of whether that segment's `diarization.jsonl` append succeeded (see `persist(_:)`'s
    /// own call-site comment).
    func accumulateSlotAudioForVoiceprint(slot: String, segment: DiarizerSegment) async {
        guard !extractedSlots.contains(slot) else {
            return
        }
        let startSample = Int((segment.startTime * Float(Self.sampleRateHz)).rounded())
        let endSample = Int((segment.endTime * Float(Self.sampleRateHz)).rounded())
        let slice = sliceGenerationBuffer(startSample: startSample, endSample: endSample)
        guard !slice.isEmpty else {
            return
        }
        pendingSlotAudio[slot, default: []].append(contentsOf: slice)

        let neededSampleCount = Int((Double(minEnrollSpeechMs) / 1_000.0 * Double(Self.sampleRateHz)).rounded())
        guard let accumulated = pendingSlotAudio[slot], accumulated.count >= neededSampleCount else {
            return
        }

        // Mark extracted *before* the extraction attempt itself: guarantees the one-shot contract holds
        // even if the extraction below fails (design section 8, "WeSpeaker 抽出/照合の失敗 → ... その slot
        // は匿名のまま").
        extractedSlots.insert(slot)
        pendingSlotAudio.removeValue(forKey: slot)
        let capped = Self.capToExtractionWindow(accumulated)

        // Fire-and-forget: the actual CPU-bound CoreML work happens inside `voiceprintExtractor`'s own
        // actor (a different executor), so this coordinator's executor is free to keep processing
        // `feed(samples:)`/`persist(_:)` calls for other slots/segments while this is in flight (design
        // section 5: "extraction must not block turn processing").
        Task { [weak self] in
            await self?.extractAndMatchVoiceprint(slot: slot, samples: capped)
        }
    }

    /// Caps a slot's accumulated speech to at most `VoiceprintExtractor.maxSampleCount` (10s @ 16kHz),
    /// keeping the most recent samples (spike facts: "most recent or most-central 10 s" — most-recent is
    /// the simpler of the two and avoids biasing toward whichever audio happened to arrive first while
    /// the slot was still below `minEnrollSpeechMs`). Handing over more than this to
    /// `extractEmbedding(from:)` would only be silently truncated by the underlying API anyway (spike
    /// facts), so capping here avoids that wasted copy.
    static func capToExtractionWindow(_ samples: [Float]) -> [Float] {
        guard samples.count > VoiceprintExtractor.maxSampleCount else {
            return samples
        }
        return Array(samples.suffix(VoiceprintExtractor.maxSampleCount))
    }

    /// Extracts a WeSpeaker embedding for `slot`'s accumulated speech, persists it into
    /// `speaker_assignments.json` **before** attempting a global-DB match (design section 4.3:
    /// "embedding ... メモリ保持契約にしない" — the embedding must survive a crash/window-close even if this
    /// method never reaches the matching step below), then writes an `.auto` assignment if
    /// `VoiceprintMatchPolicy.decide(candidate:threshold:margin:)` accepts the nearest candidate
    /// (`docs/design/20-voiceprint-misassignment-mitigation.md` section 3) — never overwriting an
    /// existing `.user` assignment for this slot (design section 4.3 of the base diarization design;
    /// the "writer-side protection" `MeetingWorkspaceViewModel+Rename.swift`'s `renameSlot(_:displayName:)`
    /// doc comment already calls out as this feature's job to enforce).
    ///
    /// Every failure here (model load, extraction, either `speaker_assignments.json` write) is logged
    /// and swallowed — this is the fire-and-forget `Task` `accumulateSlotAudioForVoiceprint(slot:
    /// segment:)` spawns, and design section 8 requires none of this to ever propagate to the
    /// recording/STT path.
    func extractAndMatchVoiceprint(slot: String, samples: [Float]) async {
        let embedding: [Float]
        do {
            embedding = try await voiceprintExtractor.extractEmbedding(from: samples)
        } catch {
            logger.warning(
                "voiceprint extraction failed for slot \(slot, privacy: .public); leaving it anonymous: \(String(describing: error), privacy: .public)"
            )
            return
        }

        do {
            try await sessionHandle.updateSpeakerAssignments { assignments in
                var current = assignments.assignments[slot] ?? SlotAssignment()
                current.embedding = embedding
                assignments.assignments[slot] = current
            }
        } catch {
            logger.error(
                "failed to persist the extracted embedding for slot \(slot, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }

        // Design section 20 §3.3's distance-log table, row "DB 空": no registered speaker has a
        // finite-distance embedding at all (empty DB, every entry reset -- design section 3.2, or, with
        // a non-empty roster, none of the roster's speakers have a finite-distance embedding either --
        // `docs/design/22-participant-hints.md` section 2.1's closed-set filter). This is the normal
        // state of a brand-new/fully-reset voiceprint database, not a mismatch worth an `.info` log, so
        // it stays `.debug` (mirrors the previous `findBestMatch`-based log here).
        guard let candidate = await voiceprintStore.findMatchCandidate(
            embedding: embedding, allowedSpeakerIds: participantHintIds.isEmpty ? nil : participantHintIds
        ) else {
            logger.debug(
                "voiceprint DB has no comparable speaker for slot \(slot, privacy: .public) (\(self.rosterLogFields(), privacy: .public)); leaving it anonymous for now"
            )
            return
        }

        let decision = VoiceprintMatchPolicy.decide(
            candidate: candidate, threshold: speakerMatchThreshold, margin: speakerMatchMargin
        )

        switch decision {
        case .rejectedByThreshold:
            // Design section 20 §3.3 row "rejectedByThreshold".
            logger.info(
                """
                voiceprint match rejectedByThreshold for slot \(slot, privacy: .public): \
                nearest=\(candidate.speaker.name, privacy: .public) distance=\(candidate.distance, privacy: .public) \
                threshold=\(self.speakerMatchThreshold, privacy: .public) \(self.rosterLogFields(), privacy: .public)
                """
            )
            return
        case .rejectedByMargin:
            // Design section 20 §3.3 row "rejectedByMargin".
            logger.info(
                """
                voiceprint match rejectedByMargin for slot \(slot, privacy: .public): \
                nearest=\(candidate.speaker.name, privacy: .public) distance=\(candidate.distance, privacy: .public) \
                \(self.runnerUpLogFields(candidate), privacy: .public) \
                margin=\(self.speakerMatchMargin, privacy: .public) \(self.rosterLogFields(), privacy: .public)
                """
            )
            return
        case .accepted:
            break
        }

        await writeAutoAssignmentIfAllowed(slot: slot, candidate: candidate, embedding: embedding, trigger: "live")
    }

    // MARK: - Shared `.auto` write path (docs/design/22-participant-hints.md section 3/3.1)

    /// Writes an accepted voiceprint match as an `.auto` assignment for `slot`, shared by the live
    /// extraction path above and `rematchAnonymousSlots()` (`+Rematch.swift`) so both go through the
    /// exact same guards. Two independent protections apply, in order:
    ///
    /// 1. **The pre-existing `.user` guard** (design section 4.3: a user assignment must never be
    ///    overwritten by an auto match) -- unchanged from before this method was extracted.
    /// 2. **The section 3.1 roster re-verification guard** -- checked *first*, synchronously, on this
    ///    actor, using whatever `participantHintIds` holds **right now** (not whatever it held when the
    ///    caller's `findMatchCandidate` call was issued). This is deliberate: `findMatchCandidate` is
    ///    itself an `await` (a suspension point), and `extractAndMatchVoiceprint`'s enclosing `Task` is
    ///    fire-and-forget, so a `updateParticipantHints(_:)` call (also `await`-driven, also on this same
    ///    reentrant actor) can slot in between that suspension and this method being reached -- the exact
    ///    interleaving design section 3.1 documents as the reason a filter passed as an argument earlier
    ///    is not sufficient on its own. Re-reading `participantHintIds` here (a synchronous property
    ///    access, not a fresh `await`) closes that window for everything except this method's own
    ///    `updateSpeakerAssignments` suspension, which design section 3.1 explicitly and permanently
    ///    accepts ("残余ウィンドウ").
    ///
    /// - Returns: `true` iff an assignment was actually written (distinct from "accepted, but
    ///   `.user`-guarded away" or "rejected by roster") -- `rematchAnonymousSlots()` does not currently
    ///   consult this, but it is exposed for a future caller/test that wants to count actual writes
    ///   rather than parsing log output.
    @discardableResult
    func writeAutoAssignmentIfAllowed(
        slot: String,
        candidate: VoiceprintStore.VoiceprintMatchCandidate,
        embedding: [Float],
        trigger: String
    ) async -> Bool {
        let match = candidate.speaker

        // §3.1 guard: re-validate against the roster *as it stands right now*, synchronously, before
        // issuing the write. `participantHintIds.isEmpty` means "no roster configured" (open-set),
        // matching `findMatchCandidate`'s own `nil`-means-open-set convention.
        guard participantHintIds.isEmpty || participantHintIds.contains(match.id) else {
            logger.info(
                """
                voiceprint match rejectedByRoster for slot \(slot, privacy: .public): \
                name=\(match.name, privacy: .public) distance=\(candidate.distance, privacy: .public) \
                \(self.rosterLogFields(), privacy: .public) trigger=\(trigger, privacy: .public)
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
                    "slot \(slot, privacy: .public) already has a user assignment; not overwriting it with the auto voiceprint match (trigger=\(trigger, privacy: .public))"
                )
                return false
            }
            let yieldResult = assignmentUpdatesContinuation.yield(())
            // Design section 20 §3.3 row "accepted".
            logger.info(
                """
                voiceprint match accepted for slot \(slot, privacy: .public): \
                name=\(match.name, privacy: .public) distance=\(candidate.distance, privacy: .public) \
                \(self.runnerUpLogFields(candidate), privacy: .public) \
                threshold=\(self.speakerMatchThreshold, privacy: .public) margin=\(self.speakerMatchMargin, privacy: .public) \
                \(self.rosterLogFields(), privacy: .public) trigger=\(trigger, privacy: .public) \
                yield=\(String(describing: yieldResult), privacy: .public)
                """
            )
            return wrote
        } catch {
            logger.error(
                "failed to write the auto voiceprint match for slot \(slot, privacy: .public) (trigger=\(trigger, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// `"runnerUp=<name-or-"-"> runnerUpDistance=<distance-or-"-">"`, shared by both of
    /// `extractAndMatchVoiceprint`'s log sites above (design section 20 §3.3's distance-log table
    /// includes the runner-up on both the `rejectedByMargin` and `accepted` rows).
    private func runnerUpLogFields(_ candidate: VoiceprintStore.VoiceprintMatchCandidate) -> String {
        guard let runnerUp = candidate.runnerUp else {
            return "runnerUp=- runnerUpDistance=-"
        }
        return "runnerUp=\(runnerUp.name) runnerUpDistance=\(runnerUp.distance)"
    }

    /// `"closedSet=<bool> rosterSize=<n>"` (`docs/design/22-participant-hints.md` section 2.2: "距離ログに
    /// closedSet=<bool> rosterSize=<n> を追記する（閾値チューニング時に照合モードを区別できるように）"), shared by
    /// every distance-log site in this file.
    private func rosterLogFields() -> String {
        "closedSet=\(!participantHintIds.isEmpty) rosterSize=\(participantHintIds.count)"
    }
}
