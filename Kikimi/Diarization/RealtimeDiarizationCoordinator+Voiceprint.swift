import FluidAudio
import Foundation

// MARK: - SlotSampleRange

/// One finalized turn's span in the current generation's raw-sample index space (the same space
/// `RealtimeDiarizationCoordinator.generationSampleBuffer` is indexed in), tagged with the slot it was
/// attributed to. Exists so a slot's enroll audio can exclude stretches another slot was also speaking
/// in (design section 5's "実装時の追記 2026-08-01（enroll 音声からの同時発話区間の除外）").
struct SlotSampleRange: Sendable, Equatable {
    let slot: String
    let range: Range<Int>
}

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
        // A recorded turn range that no longer intersects anything still in the buffer can no longer
        // subtract anything from anyone's enroll audio, so it is pure memory — drop it in lockstep with
        // the samples it described (design section 5's 2026-08-01 overlap-exclusion note).
        generationTurnSampleRanges.removeAll { $0.range.upperBound <= generationBufferBaseSampleIndex }
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

    /// Records one finalized turn's raw-sample span so later `accumulateSlotAudioForVoiceprint(slot:
    /// segment:)` calls can subtract it out of *other* slots' enroll audio (design section 5's "実装時の
    /// 追記 2026-08-01"). Called from `RealtimeDiarizationCoordinator.persist(_:)`'s first pass, for
    /// every segment of the batch, before any of that batch's accumulation runs — so two slots finalized
    /// together (the simultaneous-speech case this exists for) each see the other's range.
    func recordTurnSampleRange(slot: String, segment: DiarizerSegment) {
        let range = Self.sampleRange(of: segment)
        guard !range.isEmpty else {
            return
        }
        generationTurnSampleRanges.append(SlotSampleRange(slot: slot, range: range))
    }

    /// A `DiarizerSegment`'s span in the generation's raw-sample index space. Deliberately **not**
    /// anchor-corrected (`+Anchor.swift`'s `turnMs(fromGenerationTime:)` doc comment): the sample buffer
    /// is filled by the same `feed` calls the backend consumes, so it shares the backend's own frame
    /// cursor and must be addressed with unshifted times.
    static func sampleRange(of segment: DiarizerSegment) -> Range<Int> {
        let startSample = Int((segment.startTime * Float(sampleRateHz)).rounded())
        let endSample = Int((segment.endTime * Float(sampleRateHz)).rounded())
        guard endSample > startSample else {
            return startSample..<startSample
        }
        return startSample..<endSample
    }

    /// Slices this segment's own speech audio out of `generationSampleBuffer` — **excluding** every
    /// stretch another slot's turn also covers — appends it to `pendingSlotAudio[slot]`, and triggers a
    /// voiceprint extraction whenever the slot's cumulative enroll audio reaches the next milestone
    /// (design section 5 and its "実装時の追記 2026-08-01").
    ///
    /// Two behaviors replace the original "slice the turn verbatim, extract exactly once" rule:
    ///
    /// 1. **Overlap exclusion.** LS-EEND reports simultaneous speech as two overlapping turns, and
    ///    slicing each verbatim fed the shared stretch into *both* slots' embeddings, pulling two
    ///    different people's voiceprints toward each other (and toward whoever else was talking). Only
    ///    the parts of this turn no other slot claims are accumulated; a fully-overlapped turn
    ///    contributes nothing.
    /// 2. **Milestone re-extraction.** A slot gets an extraction at `minEnrollSpeechMs × 1`, `× 3` and
    ///    `× 6` of cumulative enroll audio (`Self.enrollMilestoneMultipliers`) instead of one shot at
    ///    `× 1`. The counter is bumped *before* the attempt, so a failing extractor still consumes its
    ///    milestone and can never spin (design section 8, "WeSpeaker 抽出/照合の失敗 → ... その slot は匿名の
    ///    まま"). Everything after the first attempt additionally requires the slot to still be anonymous,
    ///    re-checked against `speaker_assignments.json` inside the extraction task itself.
    ///
    /// Called from `RealtimeDiarizationCoordinator.persist(_:)`'s second pass for every finalized
    /// `DiarizerSegment`, regardless of whether that segment's `diarization.jsonl` append succeeded (see
    /// `persist(_:)`'s own call-site comment).
    func accumulateSlotAudioForVoiceprint(slot: String, segment: DiarizerSegment) async {
        let attempts = slotExtractionAttempts[slot] ?? 0
        guard attempts < Self.enrollMilestoneMultipliers.count else {
            // Every milestone spent: stop paying for slicing/buffering this slot for the rest of the
            // session (the same "never again" shortcut the old `extractedSlots` set provided, just at
            // the end of the milestone budget instead of after the first attempt).
            return
        }

        let ownRange = Self.sampleRange(of: segment)
        let otherSlotRanges = generationTurnSampleRanges.filter { $0.slot != slot }.map(\.range)
        let exclusiveRanges = Self.subtractingOverlaps(from: ownRange, excluding: otherSlotRanges)
        guard !exclusiveRanges.isEmpty else {
            return
        }
        var slice: [Float] = []
        for range in exclusiveRanges {
            slice.append(contentsOf: sliceGenerationBuffer(startSample: range.lowerBound, endSample: range.upperBound))
        }
        guard !slice.isEmpty else {
            return
        }

        slotEnrollSampleCounts[slot, default: 0] += slice.count
        // Capped on every append rather than only at extraction time: this buffer now survives an
        // extraction (milestones 2 and 3 keep accumulating into it), and only its most recent 10s can
        // ever be handed to the extractor anyway. `slotEnrollSampleCounts` above is what actually tracks
        // milestone progress, so capping here loses no bookkeeping.
        var accumulated = pendingSlotAudio[slot] ?? []
        accumulated.append(contentsOf: slice)
        accumulated = Self.capToExtractionWindow(accumulated)
        pendingSlotAudio[slot] = accumulated

        let multiplier = Self.enrollMilestoneMultipliers[attempts]
        let neededSampleCount = Int(
            (Double(minEnrollSpeechMs * multiplier) / 1_000.0 * Double(Self.sampleRateHz)).rounded()
        )
        guard (slotEnrollSampleCounts[slot] ?? 0) >= neededSampleCount else {
            return
        }

        slotExtractionAttempts[slot] = attempts + 1
        if attempts + 1 == Self.enrollMilestoneMultipliers.count {
            // Last milestone spent: the audio can never be needed again.
            pendingSlotAudio.removeValue(forKey: slot)
        }

        // Fire-and-forget: the actual CPU-bound CoreML work happens inside `voiceprintExtractor`'s own
        // actor (a different executor), so this coordinator's executor is free to keep processing
        // `feed(samples:elapsedAtBufferStart:)`/`persist(_:)` calls for other slots/segments while this
        // is in flight (design section 5: "extraction must not block turn processing").
        let isReExtraction = attempts > 0
        Task { [weak self] in
            await self?.extractAndMatchVoiceprint(
                slot: slot,
                samples: accumulated,
                trigger: isReExtraction ? "re-extract" : "live",
                requiresAnonymousSlot: isReExtraction
            )
        }
    }

    /// Returns the parts of `range` that no range in `others` covers, in ascending order (empty if
    /// `others` covers all of it). Pure and `static` so design section 5's overlap-exclusion rule can be
    /// unit-tested directly, without a coordinator/backend/audio at all.
    ///
    /// `others` may be unsorted, may overlap each other, and may extend arbitrarily far outside `range`;
    /// empty inputs are ignored. Both bounds are treated as half-open sample indices, so touching ranges
    /// (`a.upperBound == b.lowerBound`) do not subtract anything from each other.
    static func subtractingOverlaps(from range: Range<Int>, excluding others: [Range<Int>]) -> [Range<Int>] {
        guard !range.isEmpty else {
            return []
        }
        let overlapping = others
            .filter { !$0.isEmpty && $0.overlaps(range) }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard !overlapping.isEmpty else {
            return [range]
        }

        var remaining: [Range<Int>] = []
        var cursor = range.lowerBound
        for other in overlapping {
            if other.lowerBound > cursor {
                remaining.append(cursor..<min(other.lowerBound, range.upperBound))
            }
            cursor = max(cursor, other.upperBound)
            if cursor >= range.upperBound {
                return remaining
            }
        }
        remaining.append(cursor..<range.upperBound)
        return remaining
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
    ///
    /// - Parameters:
    ///   - trigger: Log tag distinguishing the milestone that produced this call (`"live"` for a slot's
    ///     first extraction, `"re-extract"` for milestones 2/3, `"rematch"` for `+Rematch.swift`'s
    ///     embedding-only path), so the distance logs of design section 20 §3.3 stay readable when one
    ///     slot appears several times.
    ///   - requiresAnonymousSlot: `true` for every re-extraction (design section 5's "実装時の追記
    ///     2026-08-01"). Re-reads `speaker_assignments.json` here, inside the extraction task, and
    ///     abandons the whole attempt — *including* the embedding overwrite — if the slot has since been
    ///     named. A named slot has nothing to gain from a fresh embedding and plenty to lose: a `.user`
    ///     assignment's embedding is what a later rename/Ended-time moving-average update enrolls into
    ///     `voiceprints.json` (design section 4.4), so replacing it with audio picked by a purely
    ///     time-based milestone could quietly degrade a registered speaker. The first extraction is
    ///     exempt (`false`) — it must persist an embedding even for a slot the user already named, which
    ///     is exactly what the pre-existing "`.user` name survives, embedding still updates" behavior
    ///     does.
    func extractAndMatchVoiceprint(
        slot: String,
        samples: [Float],
        trigger: String = "live",
        requiresAnonymousSlot: Bool = false
    ) async {
        if requiresAnonymousSlot, await !isSlotStillAnonymous(slot) {
            return
        }

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

        await writeAutoAssignmentIfAllowed(slot: slot, candidate: candidate, embedding: embedding, trigger: trigger)
    }

    /// `true` iff `slot` still has no name at all in `speaker_assignments.json` — neither a `.user`
    /// assignment nor an already-landed `.auto` match (the same two exclusions `+Rematch.swift`'s
    /// `rematchSlot(slot:assignment:)` applies, for the same design section 3 reason: "ユーザー確定は不可侵"
    /// / "実名確定済み。名簿の削除・変更で巻き戻さない").
    ///
    /// A read failure returns `false` (treat as "not eligible"): the only caller is a *re*-extraction,
    /// which is by definition optional extra work, so declining it costs nothing while overwriting a
    /// name/embedding on the strength of an unreadable file could cost real data.
    private func isSlotStillAnonymous(_ slot: String) async -> Bool {
        let assignments: SpeakerAssignments
        do {
            assignments = try await sessionHandle.readSpeakerAssignments()
        } catch {
            logger.warning(
                "failed to read speaker_assignments.json before re-extracting slot \(slot, privacy: .public); skipping the re-extraction: \(String(describing: error), privacy: .public)"
            )
            return false
        }
        guard let assignment = assignments.assignments[slot] else {
            return true
        }
        guard assignment.assignedBy != .user, assignment.displayName == nil else {
            logger.debug(
                "slot \(slot, privacy: .public) is already named; skipping its voiceprint re-extraction (assignedBy=\(String(describing: assignment.assignedBy), privacy: .public))"
            )
            return false
        }
        return true
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
