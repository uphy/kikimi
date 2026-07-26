import FluidAudio
import Foundation
import OSLog

// MARK: - DiarizationSegmentEndReason

/// Why `RealtimeDiarizationCoordinator.endSegment(reason:)` was called. Both cases are handled
/// identically by the coordinator itself (design section 5.1's drain-then-flush rule applies equally
/// to Paused and Ended); kept as a distinct parameter — rather than a bare `Void` — purely so call
/// sites and future logging/telemetry can distinguish them without the coordinator needing to know
/// about `SessionState` (`SessionStoreTypes.swift`) at all.
enum DiarizationSegmentEndReason: Sendable, Equatable {
    /// Recording → Paused (kikimi.md 4 章 "「停止」と「終了」を分離する"). The session may resume later.
    case paused
    /// Recording/Paused → Ended. `on_session_end` runs at the caller's layer; this coordinator has no
    /// Ended-specific behavior beyond the same drain-then-flush every segment end performs.
    case ended
}

// MARK: - DiarizationActiveRange

/// One span of the cumulative "recording active time" timeline (kikimi.md 6 章) during which the
/// diarizer was actually running. Exposed so the UI can implement design section 5.3's precondition
/// ("そのセグメントの時間範囲で diarization が稼働していたセグメントにのみ本規則を適用する") without needing
/// to know *why* a given range wasn't covered (no system audio that segment, or diarization stopped
/// after a backend error, design section 8).
///
/// `endMs == nil` means the range is still open (the current segment hasn't called `endSegment` yet).
struct DiarizationActiveRange: Sendable, Equatable {
    let startMs: Int
    var endMs: Int?
}

// MARK: - RealtimeDiarizationCoordinator

/// Session-lifetime `actor` owning the realtime speaker-diarization pipeline for one session's system
/// audio (`docs/design/13-speaker-diarization.md` section 5/5.1). `MeetingWorkspaceViewModel` holds
/// exactly one of these per open session (not per recording segment, unlike `TranscriptPipeline` —
/// design section 5's "所有者" note): the diarizer's internal speaker-slot bookkeeping and the
/// session-scoped `spk_N` numbering both need to persist across `beginSegment`/`endSegment` calls
/// within one coordinator lifetime.
///
/// `TranscriptPipeline` (or its caller) forwards system-audio buffers here via `feed(samples:)` — this
/// type never talks to `AudioCapture`/`AVAudioPCMBuffer` directly, mirroring `SttEngine`'s own
/// `[Float]`-only feed surface (`SttEngine.feed(samples:elapsedAtBufferStart:)`).
///
/// ## Lifecycle contract
///
/// ```
/// beginSegment(startMsOffset:hasSystemAudio:)   // once per recording segment, before any feed(_:)
/// feed(samples:)                                // zero or more times while the segment is Recording
/// endSegment(reason:)                           // once, when the segment closes (Paused or Ended)
/// ```
///
/// A new `RealtimeDiarizationCoordinator` instance is constructed once per `MeetingWorkspaceViewModel`
/// session lifetime (i.e. recreated whenever the ViewModel itself is recreated — window reopen, crash
/// recovery reopen — design section 5.1's "（再）作成の契機" table), never once per recording segment.
///
/// ## Every segment is a fresh diarizer generation
///
/// See `LSEENDDiarizationBackend.finalizeSession()`'s doc comment for the full reasoning: because
/// FluidAudio's `finalizeSession()` has no verified-safe "resume" path, `beginSegment` always starts a
/// fresh backend generation (`initialize()` the first time ever, `reset()` every time after) and
/// retakes the base offset from `startMsOffset`. This is a deliberate, documented deviation from
/// design section 5.1's stated "primary path" (same instance surviving an ordinary Paused ⇄ Recording
/// cycle) in favor of the same section's explicitly sanctioned fallback ("区間ごとに意図的に再作成する
/// 運用"), chosen because it never depends on unconfirmed FluidAudio internals. Functionally this only
/// costs a same-person "spk_N" slot split across a pause (already an accepted, UI-correctable outcome
/// per design section 4.3's "同一人物が複数 slot に分裂した場合").
actor RealtimeDiarizationCoordinator {
    /// Kikimi's audio pipeline is fixed at 16 kHz mono end to end (kikimi.md 12 章 `audio.sample_rate`),
    /// so this is a constant, not a config knob. Not `private`: read from
    /// `RealtimeDiarizationCoordinator+Voiceprint.swift` (split out for `file_length`, same rationale
    /// as `MeetingWorkspaceViewModel`'s `+Diarization.swift`/`+Summary.swift` extensions).
    static let sampleRateHz = 16_000

    /// Not `private`: logged through from `+Voiceprint.swift`.
    let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "RealtimeDiarizationCoordinator")

    /// Not `private`: read from `+Voiceprint.swift` to persist embeddings/assignments.
    let sessionHandle: SessionHandle
    private let backend: any DiarizationBackend
    /// This session's WeSpeaker voiceprint extractor (design section 5, "声紋照合（イベント駆動）"). A
    /// separate collaborator from `backend`: LS-EEND (`backend`) has no embedding/clustering step at
    /// all, so voiceprint extraction is a fully independent model/pipeline (`VoiceprintExtractor`'s doc
    /// comment). Not `private`: called from `+Voiceprint.swift`.
    let voiceprintExtractor: any VoiceprintEmbeddingExtracting
    /// The global cross-session voiceprint DB (design section 4.4). Defaults to `VoiceprintStore
    /// .shared`; tests inject a temp-file-backed instance so they never touch the real
    /// `~/.local/state/kikimi/voiceprints.json`. Not `private`: called from `+Voiceprint.swift`.
    let voiceprintStore: VoiceprintStore
    /// `config.yaml`'s `diarization.min_enroll_speech_ms` (design section 5/7): cumulative speech (ms)
    /// a slot needs, summed across every turn attributed to it, before a voiceprint is extracted. Not
    /// `private`: read from `+Voiceprint.swift`.
    let minEnrollSpeechMs: Int
    /// `config.yaml`'s `diarization.speaker_match_threshold` (design section 4.4/7): the cosine
    /// *distance* below which a slot's freshly extracted embedding is considered a match against an
    /// existing `voiceprints.json` entry (`VoiceprintStore.findMatchCandidate(embedding:)` +
    /// `VoiceprintMatchPolicy.decide(candidate:threshold:margin:)`; smaller distance = closer, never
    /// similarity — see `VoiceprintStore.cosineDistance(_:_:)`'s doc comment). Not `private`: read from
    /// `+Voiceprint.swift`.
    let speakerMatchThreshold: Double
    /// `config.yaml`'s `diarization.speaker_match_margin`
    /// (`docs/design/20-voiceprint-misassignment-mitigation.md` section 3/3.4): the minimum cosine-
    /// distance gap the nearest match must keep over the runner-up (a different-named registered
    /// speaker) to be accepted, passed straight through to
    /// `VoiceprintMatchPolicy.decide(candidate:threshold:margin:)`. Not `private`: read from
    /// `+Voiceprint.swift`.
    let speakerMatchMargin: Double

    /// `true` once `backend.initialize()` has succeeded at least once. Later `beginSegment` calls use
    /// `backend.reset()` instead of loading the model again.
    private var isModelInitialized = false
    /// `true` once a backend call has failed (design section 8: "diarizer のクラッシュ/エラー → error ログ
    /// + そのセッションの分離を停止"). Sticky for the rest of this coordinator's lifetime — no
    /// self-healing retry, matching the design's stated failure mode exactly.
    private var isPermanentlyStopped = false
    /// `true` only while the diarizer is actively running for the *current* segment (`false` for a
    /// segment with no system audio, design section 5.1 "入力選択との関係", or once
    /// `isPermanentlyStopped` becomes `true`).
    private var isRunningThisSegment = false

    /// This generation's base offset (design section 5.1 "基点オフセット"): `startMsOffset` from the
    /// most recent `beginSegment` call. Added to every `DiarizerSegment.startTime`/`.endTime` (which
    /// are relative to the current backend generation's own frame cursor) before persisting a turn.
    private var baseOffsetMs = 0
    /// Samples fed to the backend since the current generation started (`beginSegment`). Used only to
    /// compute this generation's active-range `endMs` on `endSegment` (design section 5's "稼働時間範囲");
    /// turn timestamps themselves come from the backend's own frame cursor via `DiarizerSegment`,
    /// never from this counter.
    private var samplesFedThisGeneration = 0

    /// Internal LS-EEND speaker index -> session-scoped slot id, for the *current* generation only.
    /// Cleared at the start of every generation (`beginSegment`) because a fresh/reset backend restarts
    /// its internal indices at 0 (design section 5.1: "（再）作成後は内部 index が 0 から始まるため...").
    private var internalIndexToSlot: [Int: String] = [:]
    /// The highest `spk_N` number allocated so far, across every generation this coordinator has run
    /// (never decreases; design section 5.1 "一度使われた slot 番号は再利用しない"). Restored from disk at
    /// the start of every generation via `restoreSlotCounterFromDisk()` so a brand-new coordinator
    /// instance (window reopened, crash recovery) continues numbering rather than colliding with slots
    /// a previous coordinator instance already persisted.
    private var maxAllocatedSlotNumber = 0

    /// Closed ranges from earlier generations plus (if a segment is currently open) one open-ended
    /// range for the current generation (design section 5, "稼働時間範囲...を公開する"). See
    /// `DiarizationActiveRange`.
    private var activeRanges: [DiarizationActiveRange] = []

    /// Raw 16 kHz mono samples fed to the backend so far **this generation**, used only to slice out a
    /// slot's own speech audio for voiceprint extraction (design section 5) — never consulted for
    /// anything turn-timing-related, which comes entirely from the backend's own `DiarizerSegment`
    /// frame cursor. Trimmed from the front once it exceeds `generationBufferRetentionSampleCount` so a
    /// long recording segment does not retain its entire raw audio in memory; `generationBufferBaseSampleIndex`
    /// tracks how many samples have been trimmed away so `sliceGenerationBuffer(startSample:endSample:)`
    /// can still translate a `DiarizerSegment`'s absolute-within-generation sample range into a valid
    /// index into what remains. Not `private`: read/written from `+Voiceprint.swift`.
    var generationSampleBuffer: [Float] = []
    /// The absolute (within the current generation) sample index that `generationSampleBuffer[0]`
    /// corresponds to. `0` at the start of every generation; increases by however many samples are
    /// trimmed off the front as `feed(samples:)` keeps appending. Not `private`: read/written from
    /// `+Voiceprint.swift`.
    var generationBufferBaseSampleIndex = 0
    /// How many trailing samples of `generationSampleBuffer` to retain (design section 5.1: the
    /// backend's own finalization lag is documented as ~1s at most — "レイテンシは1秒程度まで許容" — so 30s
    /// is a generous safety margin against a turn finalizing later than expected, while still bounding
    /// memory for an hours-long recording segment). Comfortably larger than
    /// `VoiceprintExtractor.maxSampleCount` (10s) so it never itself becomes the bottleneck on how much
    /// audio a single turn can contribute. Not `private`: read from `+Voiceprint.swift`.
    static let generationBufferRetentionSampleCount = sampleRateHz * 30

    /// Per-slot accumulated speech samples, sliced from `generationSampleBuffer` as each of that slot's
    /// turns is persisted (design section 5: "新しい slot の発話が累計 min_enroll_speech_ms に達した時点で").
    /// Removed once the slot crosses `minEnrollSpeechMs` and extraction is triggered — the samples
    /// themselves are handed off to the extraction task at that point, not needed here again
    /// (`extractedSlots` is what actually enforces "never again" for this slot, not this dictionary's
    /// presence/absence). Not `private`: read/written from `+Voiceprint.swift`.
    var pendingSlotAudio: [String: [Float]] = [:]
    /// Slots for which voiceprint extraction has already been triggered — guarantees the "one shot,
    /// never re-extract" contract (design section 5) regardless of whether that extraction ultimately
    /// succeeds or fails. Never cleared (persists for this coordinator's whole lifetime, across every
    /// generation): design section 5.1 already accepts that a pause can split one person across
    /// multiple `spk_N` slots, and each such slot independently earns exactly one extraction attempt.
    /// Not `private`: read/written from `+Voiceprint.swift`.
    var extractedSlots: Set<String> = []

    /// The current session participant roster (`docs/design/22-participant-hints.md` section 1/2.2),
    /// keyed by `VoiceprintSpeaker.id`. Empty means "no roster configured" -- voiceprint matching stays
    /// open-set (design section 2: every registered speaker is a candidate, `findMatchCandidate`'s
    /// pre-P1 behavior). Non-empty switches every subsequent match (`extractAndMatchVoiceprint`,
    /// `+Voiceprint.swift`) and rematch (`rematchAnonymousSlots()`, `+Rematch.swift`) to closed-set:
    /// only speakers whose id is in this set can be matched or even function as a margin runner-up
    /// (`VoiceprintStore.findMatchCandidate(embedding:allowedSpeakerIds:)`'s doc comment).
    ///
    /// Owned entirely by this coordinator -- it never reads `participants.json` itself (design section
    /// 2.2: "coordinator は participants.json を自分では読まない"); `MeetingWorkspaceViewModel` is the sole
    /// pusher via `updateParticipantHints(_:)` below. Not `private`: read from `+Voiceprint.swift`/
    /// `+Rematch.swift`.
    var participantHintIds: Set<String> = []

    private let newTurnsStream: AsyncStream<DiarizationTurn>
    private let newTurnsContinuation: AsyncStream<DiarizationTurn>.Continuation
    private let assignmentUpdatesStream: AsyncStream<Void>
    /// Not `private`: yielded from `+Voiceprint.swift` when an auto voiceprint match lands.
    let assignmentUpdatesContinuation: AsyncStream<Void>.Continuation

    /// - Parameters:
    ///   - sessionHandle: This session's sole `diarization.jsonl`/`speaker_assignments.json` owner
    ///     (`SessionHandle+Diarization.swift`).
    ///   - backend: Defaults to `LSEENDDiarizationBackend()`. Injectable so tests drive this actor's
    ///     state machine with a fake, never a real model/CoreML/network (design section 11).
    ///   - voiceprintExtractor: Defaults to `VoiceprintExtractor()` (a real, lazily-loaded WeSpeaker
    ///     model, design section 5). Injectable so tests never trigger a real CoreML load/network
    ///     download.
    ///   - voiceprintStore: Defaults to `VoiceprintStore.shared`. Injectable so tests never touch the
    ///     real `~/.local/state/kikimi/voiceprints.json` (`VoiceprintStore`'s own DI pattern).
    ///   - minEnrollSpeechMs / speakerMatchThreshold / speakerMatchMargin: `config.yaml`'s
    ///     `diarization.min_enroll_speech_ms` / `.speaker_match_threshold` / `.speaker_match_margin`
    ///     (design section 7; `speaker_match_margin` added by
    ///     `docs/design/20-voiceprint-misassignment-mitigation.md` section 3.4). Defaults mirror
    ///     `DiarizationConfig.default`; the production call site
    ///     (`MeetingWorkspaceViewModel.defaultDiarizationCoordinatorFactory`) always passes the resolved
    ///     `AppConfig.shared` values instead of relying on these defaults.
    init(
        sessionHandle: SessionHandle,
        backend: any DiarizationBackend = LSEENDDiarizationBackend(),
        voiceprintExtractor: any VoiceprintEmbeddingExtracting = VoiceprintExtractor(),
        voiceprintStore: VoiceprintStore = .shared,
        minEnrollSpeechMs: Int = 5_000,
        speakerMatchThreshold: Double = 0.45,
        speakerMatchMargin: Double = 0.05
    ) {
        self.sessionHandle = sessionHandle
        self.backend = backend
        self.voiceprintExtractor = voiceprintExtractor
        self.voiceprintStore = voiceprintStore
        self.minEnrollSpeechMs = minEnrollSpeechMs
        self.speakerMatchThreshold = speakerMatchThreshold
        self.speakerMatchMargin = speakerMatchMargin
        (newTurnsStream, newTurnsContinuation) = AsyncStream.makeStream()
        (assignmentUpdatesStream, assignmentUpdatesContinuation) = AsyncStream.makeStream()
    }

    /// Every `DiarizationTurn` this coordinator successfully appends to `diarization.jsonl`, in the
    /// order it was appended (design section 5: "turn 確定の通知...ViewModel が使う"). Mirrors
    /// `SttEngine.confirmedWindows`'s shape. `nonisolated` because it only vends an immutable,
    /// `Sendable` `AsyncStream` value set once at `init`.
    nonisolated var newTurns: AsyncStream<DiarizationTurn> {
        newTurnsStream
    }

    /// Yields once every time this coordinator writes a new `.auto` assignment to
    /// `speaker_assignments.json` from a successful voiceprint match (design section 5/6.1). The
    /// payload is deliberately `Void` — subscribers (`MeetingWorkspaceViewModel
    /// .startDiarizationAssignmentUpdatesSubscription(coordinator:)`) always react by re-reading the
    /// whole `speaker_assignments.json` file rather than trying to apply a partial in-memory patch, the
    /// same way a UI rename already does (`renameSlot(_:displayName:)`), so there is no reason to smuggle
    /// the slot/assignment through this stream too. `nonisolated` for the same reason as `newTurns`.
    nonisolated var assignmentUpdates: AsyncStream<Void> {
        assignmentUpdatesStream
    }

    // MARK: - Lifecycle

    /// Must be called once per recording segment, before any `feed(samples:)` call for that segment
    /// (design section 5.1's common (re)creation rule; see this type's "Every segment is a fresh
    /// diarizer generation" doc comment for why *every* segment, not only the listed special-case
    /// triggers, starts a fresh generation).
    ///
    /// - Parameters:
    ///   - startMsOffset: This segment's `RecordingSegment.startMsOffset` (kikimi.md 5/6 章) — the
    ///     cumulative "recording active time" position this segment starts at. Becomes the new
    ///     generation's base offset.
    ///   - hasSystemAudio: Whether this recording segment actually captures system audio
    ///     (`docs/design/10-audio-input-selection.md`). `false` means diarization does not run for this
    ///     segment at all (design section 5.1 "入力選択との関係") — `feed(samples:)` becomes a no-op and
    ///     no active range is opened, but `isPermanentlyStopped`/backend state are left untouched so a
    ///     later segment with system audio can still diarize normally.
    func beginSegment(startMsOffset: Int, hasSystemAudio: Bool) async {
        guard hasSystemAudio, !isPermanentlyStopped else {
            isRunningThisSegment = false
            return
        }

        do {
            if isModelInitialized {
                await backend.reset()
            } else {
                try await backend.initialize()
                isModelInitialized = true
            }
        } catch {
            logger.error(
                "diarization backend failed to initialize; disabling diarization for the rest of this session: \(String(describing: error), privacy: .public)"
            )
            isPermanentlyStopped = true
            isRunningThisSegment = false
            return
        }

        await restoreSlotCounterFromDisk()
        internalIndexToSlot.removeAll()
        baseOffsetMs = startMsOffset
        samplesFedThisGeneration = 0
        // A fresh generation always allocates brand-new `spk_N` slot ids (never reused, design section
        // 5.1), so no earlier generation's slot can ever receive more turns/audio once this call
        // returns — `pendingSlotAudio`/`extractedSlots` (keyed by those globally-unique ids) need no
        // equivalent reset here; only the raw audio buffer they are sliced from is generation-scoped.
        generationSampleBuffer.removeAll()
        generationBufferBaseSampleIndex = 0
        isRunningThisSegment = true
        activeRanges.append(DiarizationActiveRange(startMs: startMsOffset, endMs: nil))
    }

    /// Feeds one buffer of 16 kHz mono system-audio samples. Safe to call even when diarization is not
    /// currently running (no system audio this segment, or stopped after a backend error) — becomes a
    /// no-op rather than requiring the caller to track that state itself. Never throws: every backend
    /// failure is caught, logged, and turned into `isPermanentlyStopped = true` here (design section 8,
    /// "本機能のいかなる失敗も録音・書き起こし...をブロックしない"), so callers can invoke this
    /// fire-and-forget (e.g. from an unawaited `Task`) without their own error handling.
    func feed(samples: [Float]) async {
        guard isRunningThisSegment, !samples.isEmpty else {
            return
        }

        do {
            try await backend.addAudio(samples)
            appendToGenerationBuffer(samples)
            samplesFedThisGeneration += samples.count
            if let update = try await backend.process() {
                await persist(update.finalizedSegments)
            }
        } catch {
            logger.error(
                "diarization backend failed while feeding audio; disabling diarization for the rest of this session: \(String(describing: error), privacy: .public)"
            )
            isPermanentlyStopped = true
            isRunningThisSegment = false
            closeCurrentActiveRange()
        }
    }

    /// Must be called once per recording segment, when it closes (Paused or Ended). Drains the
    /// backend's remaining right-context lookahead via `finalizeSession()` so the segment's last
    /// `unattributedGraceMs`-scale tail of speech is not permanently lost (design section 5.1,
    /// "区間終了時のドレインと flush"), persists any turns that flush produced, then closes this
    /// generation's active range.
    ///
    /// Safe to call when diarization was not running this segment (no-op).
    ///
    /// - Important: The caller is responsible for having already drained *its own* forwarding of
    ///   system-audio buffers into `feed(samples:)` before calling this (mirrors
    ///   `TranscriptPipeline.stopAndDrain()`'s contract) — this method only flushes the backend's
    ///   already-fed audio, it does not wait for more to arrive.
    func endSegment(reason: DiarizationSegmentEndReason) async {
        // `newTurnsContinuation` is deliberately NOT finished here, not even for `.ended`: an Ended
        // session can be reopened (`[↩ 再開]`, kikimi.md 10 章) with the *same* window/ViewModel and
        // therefore the same coordinator instance, and a finished `AsyncStream` can never yield
        // again — every turn of the reopened recording would be silently dropped (persisted to
        // diarization.jsonl but invisible to `speakerLabels`, so every row shows "Speaker ?"; this
        // was a real field bug, 2026-07-03). Subscriber-side leak handling is
        // `MeetingWorkspaceViewModel.deinit`'s `diarizationTurnsTask?.cancel()`, which is the one
        // teardown point that actually matches this stream's lifetime (the ViewModel's, design
        // section 5) — there is no session state from which turns are impossible "forever".
        guard isRunningThisSegment else {
            return
        }
        isRunningThisSegment = false

        do {
            if let update = try await backend.finalizeSession() {
                await persist(update.finalizedSegments)
            }
        } catch {
            logger.error(
                """
                diarization backend failed to finalize segment (reason=\(String(describing: reason), privacy: .public)); \
                disabling diarization for the rest of this session: \(String(describing: error), privacy: .public)
                """
            )
            isPermanentlyStopped = true
        }

        closeCurrentActiveRange()
    }

    // MARK: - Introspection

    /// Snapshot of every active range recorded so far, oldest first (design section 5, "稼働時間範囲...
    /// を公開する"). The last element has `endMs == nil` iff a segment is currently open
    /// (`beginSegment` called, `endSegment` not yet called for it).
    func activeRangesSnapshot() -> [DiarizationActiveRange] {
        activeRanges
    }

    /// `true` once a backend failure has permanently disabled diarization for this session (design
    /// section 8). Exposed for UI-side status display and for tests; the coordinator itself already
    /// enforces this internally via `isRunningThisSegment`.
    func isStopped() -> Bool {
        isPermanentlyStopped
    }

    // MARK: - Participant hints (docs/design/22-participant-hints.md section 2.2/3)

    /// Replaces `participantHintIds` with `ids` and, only if the set actually changed, triggers a
    /// re-match of every anonymous slot against the new roster (design section 2.2: "格納後、変化があれば
    /// §3 の再照合を起動する"). The equality check is what makes repeated pushes of an unchanged roster
    /// (e.g. `MeetingWorkspaceViewModel` re-pushing on every `+Participants.swift` mutation regardless of
    /// whether this particular id actually toggled) cheap -- `rematchAnonymousSlots()` re-reads the
    /// whole `speaker_assignments.json`, so skipping it on a no-op push avoids pointless I/O and
    /// re-logging on every unrelated participant-list edit.
    ///
    /// Called by `MeetingWorkspaceViewModel` (this coordinator's sole owner of this state, design
    /// section 2.2: "coordinator は participants.json を自分では読まない") right after coordinator creation
    /// and on every subsequent roster mutation. Awaited to completion (not fire-and-forget) so a test or
    /// caller observing this call's return already sees every rematch write this roster change could
    /// produce -- unlike the live extraction pipeline's own fire-and-forget `Task` (`+Voiceprint.swift`'s
    /// `accumulateSlotAudioForVoiceprint`), there is no ordering requirement here that would benefit from
    /// not blocking the caller.
    func updateParticipantHints(_ ids: Set<String>) async {
        guard ids != participantHintIds else { return }
        participantHintIds = ids
        await rematchAnonymousSlots()
    }

    // MARK: - Turn persistence

    /// Allocates/looks up each finalized `DiarizerSegment`'s session-scoped slot, converts it to a
    /// `DiarizationTurn` on the cumulative timeline, and appends it to `diarization.jsonl`. A failed
    /// append is logged and skipped — mirroring `TranscriptPipeline.appendOrLog`'s "録音は絶対に止めない"
    /// handling — rather than treated as a backend failure: it says nothing about the diarizer's own
    /// health, only about this one write.
    private func persist(_ segments: [DiarizerSegment]) async {
        for segment in segments {
            let slot = allocateSlot(forInternalIndex: segment.speakerIndex)
            let turn = DiarizationTurn(
                slot: slot,
                startMs: baseOffsetMs + Int((segment.startTime * 1_000).rounded()),
                endMs: baseOffsetMs + Int((segment.endTime * 1_000).rounded())
            )
            do {
                try await sessionHandle.appendDiarizationTurn(turn)
                let yieldResult = newTurnsContinuation.yield(turn)
                logger.debug(
                    "persisted turn slot=\(slot, privacy: .public) [\(turn.startMs)-\(turn.endMs)] yield=\(String(describing: yieldResult), privacy: .public)"
                )
            } catch {
                logger.error(
                    "failed to append a diarization turn (slot=\(slot, privacy: .public)): \(String(describing: error), privacy: .public)"
                )
            }

            // Voiceprint accumulation runs regardless of whether the `diarization.jsonl` append above
            // succeeded — a write failure there says nothing about this segment's audio being unusable
            // for voiceprint purposes, and design section 8's best-effort mandate covers this path
            // independently.
            await accumulateSlotAudioForVoiceprint(slot: slot, segment: segment)
        }
    }

    /// Design section 5.1's slot-numbering rule: `internalIndexToSlot[index]` if already assigned this
    /// generation, otherwise the next unused `spk_N` (`maxAllocatedSlotNumber + 1`, never reused).
    private func allocateSlot(forInternalIndex index: Int) -> String {
        if let existing = internalIndexToSlot[index] {
            return existing
        }
        maxAllocatedSlotNumber += 1
        let slot = "spk_\(maxAllocatedSlotNumber)"
        internalIndexToSlot[index] = slot
        return slot
    }

    /// Restores `maxAllocatedSlotNumber` from the higher of `diarization.jsonl`'s and
    /// `speaker_assignments.json`'s highest existing `spk_N` (design section 5.1: "diarization.jsonl と
    /// speaker_assignments.json 両方の最大 slot 番号を復元して続番から採番する"). Only ever raises the
    /// in-memory counter (via `max(...)`), so a mid-lifetime call (every `beginSegment`, not only the
    /// very first) can never regress numbering that this coordinator itself already allocated but has
    /// not yet durably persisted anywhere.
    ///
    /// The two reads are wrapped in **separate** `do`/`catch` blocks, not one shared block: a
    /// `speaker_assignments.json` read failure (e.g. corrupt JSON) must not also discard whatever
    /// `diarization.jsonl` already told us, and vice versa — a single shared `do`/`catch` would abort
    /// the whole function on the first throw, silently dropping the other, still-healthy file's
    /// contribution to `maxAllocatedSlotNumber` and risking a slot-number collision the very next
    /// `allocateSlot(forInternalIndex:)` call. Each failure is logged and otherwise ignored —
    /// best-effort, matching design section 8's "voiceprints.json...破損 → warning + 空 DB として再スタート"
    /// tolerance for sidecar-file corruption.
    private func restoreSlotCounterFromDisk() async {
        var maxFromTurns = 0
        do {
            let turns = try await sessionHandle.readDiarizationTurns()
            maxFromTurns = turns.compactMap { Self.slotNumber(from: $0.slot) }.max() ?? 0
        } catch {
            logger.error("failed to restore the diarization slot counter from diarization.jsonl: \(String(describing: error), privacy: .public)")
        }

        var maxFromAssignments = 0
        do {
            let assignments = try await sessionHandle.readSpeakerAssignments()
            maxFromAssignments = assignments.assignments.keys.compactMap { Self.slotNumber(from: $0) }.max() ?? 0
        } catch {
            logger.error("failed to restore the diarization slot counter from speaker_assignments.json: \(String(describing: error), privacy: .public)")
        }

        maxAllocatedSlotNumber = max(maxAllocatedSlotNumber, maxFromTurns, maxFromAssignments)
    }

    /// Parses the trailing integer out of a `"spk_N"` slot id, or `nil` for anything else
    /// (defensively — every slot this coordinator itself ever writes matches this shape).
    private static func slotNumber(from slot: String) -> Int? {
        guard slot.hasPrefix("spk_") else {
            return nil
        }
        return Int(slot.dropFirst("spk_".count))
    }

    // MARK: - Active range bookkeeping

    /// Closes the current generation's open active range (if any) at this generation's fed-audio
    /// duration, converted via `Self.sampleRateHz` and offset by `baseOffsetMs` — the same timeline
    /// `DiarizationTurn.startMs`/`.endMs` are already on.
    private func closeCurrentActiveRange() {
        guard let lastIndex = activeRanges.indices.last, activeRanges[lastIndex].endMs == nil else {
            return
        }
        let elapsedMs = Int((Double(samplesFedThisGeneration) / Double(Self.sampleRateHz) * 1_000).rounded())
        activeRanges[lastIndex].endMs = baseOffsetMs + elapsedMs
    }
}
