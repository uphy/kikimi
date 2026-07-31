import FluidAudio
import Foundation
import OSLog

// MARK: - DiarizationCoordinating (DI seam)

/// Abstraction over `RealtimeDiarizationCoordinator`'s recording-lifecycle surface that
/// `MeetingWorkspaceViewModel` needs (`docs/design/13-speaker-diarization.md` section 5). Mirrors the
/// `RecordingAudioCapturing`/`RecordingTranscriptPipelining` DI pattern (`MeetingWorkspaceTypes.swift`)
/// so unit tests can substitute a fake that produces turns/active-ranges deterministically, instead of
/// depending on a real LS-EEND model/CoreML.
///
/// Every requirement here matches `RealtimeDiarizationCoordinator`'s existing signatures verbatim
/// (including `activeRangesSnapshot()`/`isStopped()`, which that actor declares without an explicit
/// `async` keyword since they're synchronous from *inside* the actor -- Swift lets an actor's
/// isolated synchronous method satisfy an `async` protocol requirement automatically), so
/// `extension RealtimeDiarizationCoordinator: DiarizationCoordinating {}` below needs no extra glue.
protocol DiarizationCoordinating: Sendable {
    func beginSegment(startMsOffset: Int, hasSystemAudio: Bool) async
    /// - Parameter elapsedAtBufferStart: This buffer's capture-clock position, i.e. seconds since
    ///   `AudioCapture.start()` for the recording segment that produced it -- the same value
    ///   `SttEngine.feed(samples:elapsedAtBufferStart:)` receives for the same buffer. The coordinator
    ///   uses it to anchor its turns onto the transcript's timeline (design section 5.1's "実装時の追記
    ///   2026-08-01"); it never derives turn timestamps from the fed-sample count alone.
    func feed(samples: [Float], elapsedAtBufferStart: TimeInterval) async
    func endSegment(reason: DiarizationSegmentEndReason) async
    var newTurns: AsyncStream<DiarizationTurn> { get }
    /// Yields once every time the coordinator writes a new `.auto` assignment to
    /// `speaker_assignments.json` from a successful voiceprint match (design section 5, "R2"). The
    /// only reaction a subscriber needs is "re-read `speaker_assignments.json` and recompute" — see
    /// `startDiarizationAssignmentUpdatesSubscription(coordinator:)` below — the same shape `newTurns`
    /// already has for turns.
    var assignmentUpdates: AsyncStream<Void> { get }
    func activeRangesSnapshot() async -> [DiarizationActiveRange]
    func isStopped() async -> Bool
    /// Replaces the coordinator's participant roster and, if it actually changed, triggers a rematch of
    /// every anonymous slot against it (`docs/design/22-participant-hints.md` section 2.2/3). Owned by
    /// `MeetingWorkspaceViewModel+Participants.swift` (P2): pushed once right after coordinator creation
    /// and again on every roster mutation.
    func updateParticipantHints(_ ids: Set<String>) async
}

extension RealtimeDiarizationCoordinator: DiarizationCoordinating {}

/// Logger for `MeetingWorkspaceViewModel.defaultDiarizationCoordinatorFactory`, a `static` factory
/// function with no `self` to hang an instance logger off of (unlike the rest of this file's methods,
/// which reuse `MeetingWorkspaceViewModel.logger`).
private let diarizationFactoryLogger = Logger(subsystem: "io.github.uphy.Kikimi", category: "MeetingWorkspaceViewModel.Diarization")

// MARK: - MeetingWorkspaceViewModel + Diarization (docs/design/13-speaker-diarization.md section 5/6.1)

/// Split into its own file (alongside `MeetingWorkspaceViewModel.swift`'s other extensions, e.g.
/// `+Summary.swift`/`+AudioInput.swift`) to keep that file under the project's `file_length` lint
/// limit. Owns every read/write of the `diarization*` stored-property group declared in
/// `MeetingWorkspaceViewModel.swift`, plus the whole `speakerLabels` derivation pipeline.
///
/// ## What this file deliberately does not cover (out of this change's scope)
///
/// - **Voiceprint auto-matching / `voiceprints.json`** (design section 4.4, "R2"): the *extraction and
///   matching* now happen entirely inside `RealtimeDiarizationCoordinator`
///   (`Kikimi/Diarization/RealtimeDiarizationCoordinator.swift`), which writes `.auto` assignments to
///   `speaker_assignments.json` directly and signals this ViewModel via `assignmentUpdates`
///   (`startDiarizationAssignmentUpdatesSubscription(coordinator:)` below).
/// - **Rename / segment-override entry points and their free-typed-name normalization**
///   (design section 6.1's popover, `docs/design/20-voiceprint-misassignment-mitigation.md` section 4):
///   `renameSlot(_:displayName:)`, `applyRename(slot:submission:)`,
///   `overrideSegmentSpeaker(segmentId:submission:)`, and `refreshKnownVoiceprintSpeakers()` live in
///   `+Rename.swift`, not here.
/// - **participants reflection** (design section 6.2, "R2 module 4"): the Ended-time moving-average
///   voiceprint update and the `SummaryUpdater.mergeParticipants(_:)`-backed participants merge (both
///   for the Ended transition itself and for any rename arriving after it) live in
///   `+DiarizationEnded.swift`, not here -- `+Rename.swift`'s `renameSlot(_:displayName:)`/
///   `applyRename(slot:submission:)` only ever call into that file's
///   `mergeDiarizationParticipantsIfEnded()`.
/// - **Wiki export realname substitution** (design section 6.3): a `WikiExporter`-side concern that
///   does not exist yet.
/// - **On-demand WAV voiceprint fallback** (design section 4.4, "実装時の追記 2026-07-03"): the actual
///   extraction/registration for a `.localOnly` rename lives in `+VoiceprintWavFallback.swift` --
///   `+Rename.swift`'s `applyRename(slot:submission:)` only ever calls that file's
///   `scheduleVoiceprintWavFallbackEnrollment(slot:displayName:)`.
/// - **UI** (rename popover, seg-id click-to-jump, Wiki export formatting): `Kikimi/Views/` is out of
///   this file's scope; `speakerLabels` is this file's public surface for a later UI change to consume.
extension MeetingWorkspaceViewModel {
    /// Production default for `diarizationCoordinatorFactory`: a real `RealtimeDiarizationCoordinator`
    /// backed by `LSEENDDiarizationBackend`, with `stepSize`/`variant` resolved from
    /// `AppConfig.shared.data.diarization` (design section 7) via
    /// `LSEENDStepSize.fromDiarizationConfig(stepMs:logger:)`/`LSEENDVariant
    /// .fromDiarizationConfig(name:logger:)` (`Kikimi/Diarization/DiarizationBackend.swift`) and the
    /// LS-EEND timeline post-processing group (`onset_threshold`/`offset_threshold`/
    /// `min_duration_on_ms`/`min_duration_off_ms`) forwarded to the same backend, plus the
    /// same config's `min_enroll_speech_ms`/`speaker_match_threshold`/`speaker_match_margin` (design
    /// section 5/7, R2; margin added by `docs/design/20-voiceprint-misassignment-mitigation.md`
    /// section 3.4) wired straight through to the coordinator's voiceprint-matching parameters, and the
    /// production
    /// `VoiceprintExtractor()`/`VoiceprintStore.shared` singletons. Reads `AppConfig.shared` directly
    /// rather than an injected `appConfig` parameter -- this factory is only ever the production
    /// default (never called from a test, which always injects a fake `DiarizationCoordinatorFactory`
    /// instead), so there is no DI seam to preserve here the way `diarizationCoordinatorIfEnabled()`
    /// below preserves one for `appConfig.data.diarization.enabled`.
    static func defaultDiarizationCoordinatorFactory(_ sessionHandle: SessionHandle) -> any DiarizationCoordinating {
        let diarizationConfig = AppConfig.shared.data.diarization
        let stepSize = LSEENDStepSize.fromDiarizationConfig(
            stepMs: diarizationConfig.stepMs,
            logger: diarizationFactoryLogger
        )
        let variant = LSEENDVariant.fromDiarizationConfig(
            name: diarizationConfig.variant,
            logger: diarizationFactoryLogger
        )
        return RealtimeDiarizationCoordinator(
            sessionHandle: sessionHandle,
            backend: LSEENDDiarizationBackend(
                variant: variant,
                stepSize: stepSize,
                onsetThreshold: diarizationConfig.onsetThreshold,
                offsetThreshold: diarizationConfig.offsetThreshold,
                minDurationOnMs: diarizationConfig.minDurationOnMs,
                minDurationOffMs: diarizationConfig.minDurationOffMs
            ),
            voiceprintExtractor: VoiceprintExtractor(),
            voiceprintStore: .shared,
            minEnrollSpeechMs: diarizationConfig.minEnrollSpeechMs,
            speakerMatchThreshold: diarizationConfig.speakerMatchThreshold,
            speakerMatchMargin: diarizationConfig.speakerMatchMargin
        )
    }

    // MARK: - Coordinator lifecycle

    /// Returns this ViewModel instance's `RealtimeDiarizationCoordinator`, creating it (via
    /// `diarizationCoordinatorFactory`) and starting its `newTurns`/`assignmentUpdates` subscriptions
    /// the first time this is called, or `nil` if `AppConfig.shared.data.diarization.enabled == false`
    /// (design section 7: "false で本機能を丸ごと無効化"). Once created, the same instance is reused for
    /// the rest of this ViewModel's lifetime (design section 5: "`MeetingWorkspaceViewModel` がセッション
    /// 単位で保持"), spanning every Paused ⇄ Recording cycle -- only a brand-new
    /// `MeetingWorkspaceViewModel` instance (window reopen, crash-recovery reopen) ever gets a fresh
    /// coordinator.
    ///
    /// `async` (unlike most of this file's other lazy-creation helpers) solely so it can push the
    /// current participant roster to a brand-new coordinator before returning it
    /// (`docs/design/22-participant-hints.md` section 2.2 bullet (a): "coordinator 生成直後...に
    /// updateParticipantHints を push する"). An already-existing coordinator is returned as-is --
    /// its roster is kept current by every `+Participants.swift` mutation instead, not re-pushed here.
    ///
    /// Not `private`: called from `runRecordingSegmentStart` in `MeetingWorkspaceViewModel.swift`.
    func diarizationCoordinatorIfEnabled() async -> (any DiarizationCoordinating)? {
        guard appConfig.data.diarization.enabled else {
            return nil
        }
        if let existing = diarizationCoordinator {
            return existing
        }
        let coordinator = diarizationCoordinatorFactory(sessionHandle)
        diarizationCoordinator = coordinator
        startDiarizationTurnsSubscription(coordinator: coordinator)
        startDiarizationAssignmentUpdatesSubscription(coordinator: coordinator)
        let participants = await sessionHandle.readParticipants()
        await coordinator.updateParticipantHints(Set(participants.participantIds))
        return coordinator
    }

    /// Forwards one buffer of system-audio samples (plus its capture-clock `elapsedAtBufferStart`) to
    /// `diarizationCoordinator.feed(samples:elapsedAtBufferStart:)`, hopping onto `@MainActor` first
    /// (this is invoked from `TranscriptPipeline.onSystemAudio`'s `@Sendable` closure, which runs on
    /// that pipeline's own systemFeedTask, not the main thread). A no-op if no coordinator exists
    /// (defensive; `runRecordingSegmentStart` only ever wires `pipeline.onSystemAudio` when
    /// `diarizationCoordinatorIfEnabled()` returned non-`nil`).
    ///
    /// `elapsedAtBufferStart` is passed straight through, unmodified: it is relative to *this recording
    /// segment's* `AudioCapture.start()`, exactly like `SttEngine`'s own use of it, and the coordinator
    /// adds this segment's `startMsOffset` itself (its `baseOffsetMs`, taken at `beginSegment`).
    ///
    /// Not `private`: called from `runRecordingSegmentStart`'s `pipeline.onSystemAudio` closure in
    /// `MeetingWorkspaceViewModel.swift`.
    func feedDiarization(samples: [Float], elapsedAtBufferStart: TimeInterval) async {
        await diarizationCoordinator?.feed(samples: samples, elapsedAtBufferStart: elapsedAtBufferStart)
    }

    /// Consumes `coordinator.newTurns` for the rest of this ViewModel instance's lifetime (never
    /// cancelled except implicitly by `self` deallocating -- the coordinator itself lives exactly as
    /// long as this ViewModel does, design section 5). Accumulates every turn into `diarizationTurns`
    /// and re-derives `speakerLabels` after each one.
    private func startDiarizationTurnsSubscription(coordinator: any DiarizationCoordinating) {
        diarizationTurnsTask?.cancel()
        diarizationTurnsTask = Task { [weak self] in
            for await turn in coordinator.newTurns {
                guard let self else { return }
                self.diarizationTurns.append(turn)
                self.logger.debug(
                    "received diarization turn \(turn.slot, privacy: .public) [\(turn.startMs)-\(turn.endMs)] (total=\(self.diarizationTurns.count))"
                )
                await self.recomputeSpeakerLabels()
            }
        }
    }

    /// Consumes `coordinator.assignmentUpdates` for the rest of this ViewModel instance's lifetime
    /// (design section 5, "R2": the coordinator's own voiceprint auto-matching now writes `.auto`
    /// assignments to `speaker_assignments.json` directly, from a background `Task` this ViewModel
    /// never awaits). Without this subscription, an auto-match landing mid-Recording would sit on disk
    /// unnoticed until the next unrelated trigger (a new turn, a rename, the grace-period ticker)
    /// happened to call `recomputeSpeakerLabels()` -- this re-reads `speaker_assignments.json`
    /// immediately instead, the same "re-read the whole file, don't smuggle a partial patch through the
    /// stream" shape `renameSlot(_:displayName:)` already uses.
    private func startDiarizationAssignmentUpdatesSubscription(coordinator: any DiarizationCoordinating) {
        diarizationAssignmentUpdatesTask?.cancel()
        diarizationAssignmentUpdatesTask = Task { [weak self] in
            for await _ in coordinator.assignmentUpdates {
                guard let self else { return }
                do {
                    self.diarizationAssignments = try await self.sessionHandle.readSpeakerAssignments()
                } catch {
                    self.logger.error(
                        "Failed to reload speaker_assignments.json after an auto voiceprint match for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                    continue
                }
                await self.recomputeSpeakerLabels()
            }
        }
    }

    // MARK: - Label derivation

    /// Called once per confirmed live segment (`+RecordingInternals.swift`'s
    /// `startLiveSegmentSubscription(pipeline:)`, right after `transcriptRows` gains the new row).
    /// `mic` segments need no time anchor (`selfName` never depends on elapsed time); `system`
    /// segments record their confirmation instant here for `SpeakerLabelResolver`'s
    /// `unattributedGraceMs` rule (design section 5.3 rule 1) before triggering the shared recompute.
    ///
    /// Not `private`: called from `MeetingWorkspaceViewModel+RecordingInternals.swift`.
    func handleSegmentConfirmedForDiarization(segment: TranscriptSegment) async {
        guard appConfig.data.diarization.enabled else {
            return
        }
        if segment.speaker == .system {
            diarizationSegmentConfirmedAt[segment.id] = Date()
        }
        await recomputeSpeakerLabels()
    }

    /// Backfills `diarizationTurns`/`diarizationAssignments` from disk and derives `speakerLabels` for
    /// every already-loaded `transcriptRows` entry -- the reopened-session counterpart to
    /// `handleSegmentConfirmedForDiarization(segment:)`, called once from `onAppear()` after the
    /// transcript backfill.
    ///
    /// **Known limitation**: this ViewModel instance has no historical `DiarizationActiveRange`s to
    /// consult for rows from a *previous* coordinator instance's segments (`activeRanges` are derived
    /// in-memory by `RealtimeDiarizationCoordinator`, never persisted -- design section 5 exposes them
    /// only via `activeRangesSnapshot()`). `currentActiveRanges()` below compensates with a fallback
    /// range covering that whole prefix (`[0, liveRanges.first?.startMs)`) whenever `diarizationTurns`
    /// is non-empty, rather than only the true historical active spans. This can attribute a `system`
    /// row from a period diarization was not actually running in a prior segment (e.g. a segment
    /// recorded with system audio disabled, sandwiched between two segments that had it enabled) -- an
    /// edge case accepted here given `RealtimeDiarizationCoordinator`'s active ranges are explicitly
    /// documented as non-persisted, in-memory-only state. Tracked as a gap for a follow-up change (e.g.
    /// persisting active ranges alongside `diarization.jsonl`) rather than fixed here, since
    /// `Kikimi/Diarization/`'s `RealtimeDiarizationCoordinator` internals are out of this file's scope
    /// to modify.
    ///
    /// Not `private`: called from `onAppear()` in `MeetingWorkspaceViewModel.swift`.
    func initializeSpeakerLabelsFromBackfill() async {
        guard appConfig.data.diarization.enabled else {
            return
        }
        do {
            diarizationTurns = try await sessionHandle.readDiarizationTurns()
            diarizationAssignments = try await sessionHandle.readSpeakerAssignments()
        } catch {
            logger.error(
                "Failed to backfill diarization data for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }

        // Anchors every not-yet-attributed `system` row to `Date.distantPast`, not "now": these rows
        // were confirmed in a *past* recording segment (this call only ever runs against
        // already-loaded `transcriptRows`, i.e. backfilled history), so design section 5.3 rule 1's
        // grace period ("セグメント確定から `unattributed_grace_ms` 経過後...") has necessarily already
        // elapsed by the time this reopened session is looking at them. Anchoring to "now" instead would
        // read as `elapsedMs == 0` on every recompute -- and, critically, a reopened session that is not
        // currently Recording never runs `startDiarizationLabelTicker()` (that ticker only starts from
        // `runRecordingSegmentStart` in `MeetingWorkspaceViewModel.swift`) to ever advance a captured
        // "now" past the grace threshold on its own, so a still-unattributed row would be stuck
        // displaying "(認識中…)" forever instead of falling through to "Speaker ?" -- this was a real
        // review finding, not a hypothetical. `Date.distantPast` makes every such row resolve
        // immediately without waiting on a ticker that may never run; a `DiarizationTurn` that later
        // does attribute the row (from a new turn arriving, or a recompute after resuming Recording)
        // takes priority over this regardless of `confirmedAt`, since `SpeakerLabelResolver.resolve`
        // only ever consults `confirmedAt` in the `.unattributed` branch.
        for row in transcriptRows where row.speaker == .system && diarizationSegmentConfirmedAt[row.id] == nil {
            diarizationSegmentConfirmedAt[row.id] = .distantPast
        }

        await recomputeSpeakerLabels()
    }

    /// Re-derives `speakerLabels` for every row currently in `transcriptRows`, using whichever
    /// `DiarizationActiveRange`s are available right now (`currentActiveRanges()`). Shared by every
    /// trigger design section 5.3/6.1 calls for: a new turn arriving, a segment being confirmed, a
    /// rename, and the periodic grace-period ticker.
    ///
    /// Builds `speakerNames` (`globalSpeakerId -> current name`) from `knownVoiceprintSpeakers` on every
    /// call (`docs/design/23-speaker-settings-rename.md` §2.2/3.2) so a rename made in Settings' 話者
    /// タブ since this list was last refreshed wins over any slot/override's frozen snapshot
    /// `displayName` -- this is what makes reopening a past session (`onAppear()` refreshes
    /// `knownVoiceprintSpeakers` before calling this, see that method's doc comment) show the latest
    /// global name instead of whatever name was current at assignment time.
    ///
    /// Not `private`: called from `MeetingWorkspaceViewModel+RecordingInternals.swift`'s
    /// `startLiveSegmentSubscription(pipeline:)` indirectly via `handleSegmentConfirmedForDiarization
    /// (segment:)` above, and directly wherever a test needs to force a synchronous recompute.
    func recomputeSpeakerLabels() async {
        guard appConfig.data.diarization.enabled else {
            return
        }
        let activeRanges = await currentActiveRanges()
        let now = Date()
        let speakerNames = Dictionary(
            knownVoiceprintSpeakers.map { ($0.id, $0.name) }, uniquingKeysWith: { _, latest in latest }
        )
        var updated = speakerLabels
        for row in transcriptRows {
            switch row.speaker {
            case .mic:
                // Design section 4.5: mic never runs through diarization -- always the configured
                // self-name, regardless of `activeRanges`.
                updated[row.id] = ResolvedSpeakerLabel(label: .named(appConfig.data.diarization.selfName), hasOverlapMarker: false)
            case .system:
                let confirmedAt = diarizationSegmentConfirmedAt[row.id] ?? now
                updated[row.id] = SpeakerLabelResolver.resolve(
                    startMs: row.startMs,
                    endMs: row.endMs,
                    turns: diarizationTurns,
                    activeRanges: activeRanges,
                    assignments: diarizationAssignments,
                    override: diarizationAssignments.segmentOverrides[row.id],
                    confirmedAt: confirmedAt,
                    now: now,
                    speakerNames: speakerNames
                )
            }
        }
        speakerLabels = updated
    }

    /// The `DiarizationActiveRange`s to attribute against right now: this ViewModel instance's live
    /// coordinator snapshot (if any), **merged with** a backfill fallback range covering the prefix of
    /// the timeline that snapshot cannot see.
    ///
    /// `RealtimeDiarizationCoordinator.activeRangesSnapshot()` only knows about generations *this*
    /// coordinator instance itself created (design section 5: `activeRanges` is in-memory, never
    /// persisted). A reopened session's coordinator is always brand-new (design section 5.1's
    /// (re)creation table -- "Paused でウィンドウを閉じ、開き直して再開" is a listed trigger), so its
    /// snapshot only ever covers *this* generation's segment(s) onward; every row confirmed by an
    /// earlier generation (a previous process, before this reopen) has no live range to fall back on.
    /// Without this merge, `recomputeSpeakerLabels()` would find those older rows' `startMs` outside
    /// every returned range the instant a new coordinator calls `beginSegment` (even before any new
    /// turn arrives), tripping section 5.3's "not currently active" precondition and regressing their
    /// label straight to the physical-source "system" fallback -- silently discarding an
    /// already-resolved `Speaker N`/real name. The fix: whenever `diarizationTurns` is non-empty (this
    /// session has ever produced a turn, current generation or not), always contribute a fallback range
    /// `[0, liveRanges.first?.startMs)` -- ending right where the live coordinator's own earliest known
    /// range begins (so it never re-claims ground the live coordinator already reports), or open-ended
    /// (`nil`) if the coordinator hasn't begun any segment yet (no coordinator at all, or one that has
    /// only ever seen system-audio-disabled segments so far) -- matching this method's pre-merge
    /// behavior for that case.
    ///
    /// This is *not* the "恒久策" the design's own review calls out (persisting active ranges alongside
    /// `diarization.jsonl`, section 5.1) -- it is the always-correct fallback because it degrades to
    /// "cover everything the live coordinator doesn't" and never *narrows* coverage the live coordinator
    /// itself is already reporting. It can still over-attribute a genuinely diarizer-inactive prefix
    /// (e.g. a segment recorded with system audio disabled, sandwiched between two segments that had it
    /// enabled) as if diarization ran there — the same accepted edge case
    /// `initializeSpeakerLabelsFromBackfill()`'s doc comment already documents for the backfill-only
    /// case, now also covering the merged case.
    private func currentActiveRanges() async -> [DiarizationActiveRange] {
        let liveRanges: [DiarizationActiveRange]
        if let coordinator = diarizationCoordinator {
            liveRanges = await coordinator.activeRangesSnapshot()
        } else {
            liveRanges = []
        }
        guard !diarizationTurns.isEmpty else {
            return liveRanges
        }
        let fallbackRange = DiarizationActiveRange(startMs: 0, endMs: liveRanges.first?.startMs)
        return [fallbackRange] + liveRanges
    }

    // MARK: - Grace-period ticker (design section 5.3 rule 1)

    /// One-second polling loop re-deriving `speakerLabels` while Recording, so a `.recognizing` row
    /// transitions to `.unknown` once `AttributionTuning.unattributedGraceMs` elapses even if no new
    /// `DiarizationTurn` ever arrives to trigger that recompute on its own (e.g. a BGM/notification
    /// sound with no attributable speech at all). A no-op when diarization is disabled -- there is
    /// nothing to tick.
    ///
    /// Every *other* trigger for `recomputeSpeakerLabels()` (a new turn, a segment confirming, a
    /// rename, an assignment update) already calls it directly -- this tick's only reason to exist is
    /// advancing the grace-period clock for a row still sitting at `.recognizing`. So when nothing is
    /// currently `.recognizing`, this tick is a pure no-op recompute over every row, every second,
    /// for the rest of the recording -- one of the two dominant contributors to a real
    /// CPU-pinning/UI-freeze bug in long meetings (the other being `SegmentAttribution`'s per-row
    /// cost, fixed separately). Skipping the recompute whenever there is nothing pending removes that
    /// entire steady-state cost without changing what a caller ever observes: no `.recognizing` row
    /// means no row's label could possibly change from time passing alone.
    ///
    /// Not `private`: called from `runRecordingSegmentStart` in `MeetingWorkspaceViewModel.swift`.
    func startDiarizationLabelTicker() {
        guard appConfig.data.diarization.enabled else {
            return
        }
        diarizationLabelTickTask?.cancel()
        diarizationLabelTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                guard self.speakerLabels.values.contains(where: { $0.label == .recognizing }) else {
                    continue
                }
                await self.recomputeSpeakerLabels()
            }
        }
    }

    /// Not `private`: called from `finishStoppingCapture()` in `MeetingWorkspaceViewModel.swift`.
    func stopDiarizationLabelTicker() {
        diarizationLabelTickTask?.cancel()
        diarizationLabelTickTask = nil
    }

}

// Rename/segment-override entry points (design section 6.1's rename popover -- both the slot-wide
// `renameSlot(_:displayName:)`/`applyRename(slot:submission:)` and the per-segment
// `overrideSegmentSpeaker(segmentId:submission:)`, plus their shared free-typed-name normalization,
// `docs/design/20-voiceprint-misassignment-mitigation.md` section 4) live in `+Rename.swift`, split
// out for the same `file_length`-lint reason as this file's own split from
// `MeetingWorkspaceViewModel.swift`.

// Ended-time diarization hooks (design section 4.4/6.2, "R2 module 4": Ended-time moving-average
// voiceprint update + participants merge) live in `+DiarizationEnded.swift`, split out for the same
// `file_length`-lint reason as this file's own split from `MeetingWorkspaceViewModel.swift`.
