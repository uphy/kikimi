import FluidAudio
import Foundation
import Testing

@testable import Kikimi

// MARK: - MockDiarizationBackend

/// Fake `DiarizationBackend` (design section 11's layer-1 test seam) driving
/// `RealtimeDiarizationCoordinator`'s state machine deterministically: no real LS-EEND model, no
/// CoreML, no network. An `actor` for the same reason `LSEENDDiarizationBackend` is one (`Sendable`
/// state the coordinator `await`s into across a suspension point).
private actor MockDiarizationBackend: DiarizationBackend {
    private(set) var initializeCallCount = 0
    private(set) var resetCallCount = 0
    private(set) var addAudioCallCount = 0
    private(set) var processCallCount = 0
    private(set) var finalizeSessionCallCount = 0

    private var initializeError: Error?
    private var addAudioError: Error?
    private var processQueue: [DiarizerTimelineUpdate?] = []
    private var finalizeSessionResult: DiarizerTimelineUpdate?
    private var finalizeSessionError: Error?

    func setInitializeError(_ error: Error?) {
        initializeError = error
    }

    func setAddAudioError(_ error: Error?) {
        addAudioError = error
    }

    func enqueueProcessResult(_ update: DiarizerTimelineUpdate?) {
        processQueue.append(update)
    }

    func setFinalizeSessionResult(_ update: DiarizerTimelineUpdate?) {
        finalizeSessionResult = update
    }

    func setFinalizeSessionError(_ error: Error?) {
        finalizeSessionError = error
    }

    func initialize() async throws {
        initializeCallCount += 1
        if let initializeError {
            throw initializeError
        }
    }

    func addAudio(_ samples: [Float]) async throws {
        addAudioCallCount += 1
        if let addAudioError {
            throw addAudioError
        }
    }

    func process() async throws -> DiarizerTimelineUpdate? {
        processCallCount += 1
        guard !processQueue.isEmpty else {
            return nil
        }
        return processQueue.removeFirst()
    }

    func finalizeSession() async throws -> DiarizerTimelineUpdate? {
        finalizeSessionCallCount += 1
        if let finalizeSessionError {
            throw finalizeSessionError
        }
        defer { finalizeSessionResult = nil }
        return finalizeSessionResult
    }

    func reset() async {
        resetCallCount += 1
    }
}

// MARK: - MockDiarizationBackendError

private struct MockDiarizationBackendError: Error, Equatable {}

// MARK: - FakeVoiceprintExtractor

/// Fake `VoiceprintEmbeddingExtracting` (design section 11's layer-1 test seam, extended for R2's
/// voiceprint extraction/matching): drives `RealtimeDiarizationCoordinator`'s accumulate-then-extract
/// pipeline deterministically, with no real WeSpeaker CoreML model. An `actor` for the same reason
/// `MockDiarizationBackend` is one (`Sendable` state awaited across a suspension point, and the
/// coordinator calls this from an unstructured `Task` that could in principle interleave with test
/// assertions).
private actor FakeVoiceprintExtractor: VoiceprintEmbeddingExtracting {
    private(set) var callCount = 0
    private(set) var receivedSamples: [[Float]] = []
    private var embeddingResult: [Float] = [1, 0, 0, 0]
    private var extractionError: Error?
    /// Optional rendezvous point (`docs/design/22-participant-hints.md` section 3.1's actor-reentrancy
    /// regression coverage): when set, `extractEmbedding(from:)` suspends here (after recording the
    /// call) until the test resumes it, giving the test a deterministic window to run another
    /// actor-isolated call (e.g. `RealtimeDiarizationCoordinator.updateParticipantHints(_:)`) while this
    /// extraction is still in flight.
    private var gate: (() async -> Void)?

    func setEmbeddingResult(_ embedding: [Float]) {
        embeddingResult = embedding
    }

    func setExtractionError(_ error: Error?) {
        extractionError = error
    }

    func setGate(_ gate: (() async -> Void)?) {
        self.gate = gate
    }

    func extractEmbedding(from samples: [Float]) async throws -> [Float] {
        callCount += 1
        receivedSamples.append(samples)
        if let gate {
            await gate()
        }
        if let extractionError {
            throw extractionError
        }
        return embeddingResult
    }
}

private struct FakeVoiceprintExtractorError: Error, Equatable {}

// MARK: - RealtimeDiarizationCoordinatorTests

/// Unit tests for `RealtimeDiarizationCoordinator` (`docs/design/13-speaker-diarization.md` sections
/// 5/5.1/8/11). Exercises the state machine entirely against `MockDiarizationBackend` plus a real
/// `SessionHandle` pointed at a temp directory (mirrors `SessionHandleTranscriptTests.swift`'s pattern)
/// so `diarization.jsonl`/`speaker_assignments.json` round-trips are covered end to end without a real
/// model.
@Suite("RealtimeDiarizationCoordinator")
struct RealtimeDiarizationCoordinatorTests {
    // MARK: - Fixtures

    private func makeTempSessionDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealtimeDiarizationCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func baseMeta(id: String = "2026-07-01T14-30-00_a1b2c3d4") -> SessionMeta {
        SessionMeta(
            id: id,
            title: "Test Session",
            titleAutoGenerated: true,
            titleAutoNamedOnce: false,
            titleProposal: nil,
            state: .recording,
            createdAt: Date(timeIntervalSince1970: 1_751_000_000),
            startedAt: Date(timeIntervalSince1970: 1_751_000_010),
            endedAt: nil,
            durationMs: 0,
            basedOnSession: nil,
            segmentCount: 0,
            refinedCount: 0,
            appVersion: "0.1.0"
        )
    }

    /// - Parameter frameDurationSeconds: `.step500ms` in production is 0.5s/frame; kept as a parameter
    ///   (rather than hardcoded) so tests can pick round numbers that avoid the frame<->time rounding
    ///   `DiarizerSegment`'s `startTime`/`endTime` init performs.
    private func makeSegment(
        speakerIndex: Int,
        startFrame: Int,
        endFrame: Int,
        frameDurationSeconds: Float = 0.5
    ) -> DiarizerSegment {
        DiarizerSegment(
            speakerIndex: speakerIndex,
            startFrame: startFrame,
            endFrame: endFrame,
            finalized: true,
            frameDurationSeconds: frameDurationSeconds,
            activity: 1.0
        )
    }

    private func makeUpdate(finalizedSegments: [DiarizerSegment]) -> DiarizerTimelineUpdate {
        DiarizerTimelineUpdate(
            finalizedSegments: finalizedSegments,
            tentativeSegments: [],
            chunkResult: DiarizerChunkResult(finalizedPredictions: [], finalizedFrameCount: 0)
        )
    }

    private func makeSamples(count: Int = 100) -> [Float] {
        Array(repeating: Float(0), count: count)
    }

    /// Fills every sample with a distinct constant `value`, so a test can tell *which* fed chunk ended
    /// up (or didn't) in a sliced/capped buffer just by inspecting its contents.
    private func makeSamples(value: Float, count: Int) -> [Float] {
        Array(repeating: value, count: count)
    }

    private func makeTempVoiceprintStore() -> VoiceprintStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealtimeDiarizationCoordinatorTests-voiceprints-\(UUID().uuidString).json")
        return VoiceprintStore(fileURL: url)
    }

    /// Polls `condition` until it becomes `true` or `timeout` elapses (mirrors
    /// `MeetingWorkspaceViewModelTests.waitUntil`): voiceprint extraction/matching runs on a
    /// fire-and-forget `Task` the coordinator never awaits, so assertions about its outcome cannot rely
    /// on `feed(samples:)` having returned. The timeout is a hang guard only; 10s for the same
    /// reason as that helper.
    private func waitUntil(
        timeout: Duration = .seconds(10),
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition to become true")
    }

    // MARK: - Base offset (design section 5.1)

    @Test("beginSegment's first generation initializes the backend once and uses startMsOffset as the base offset")
    func baseOffsetFirstGeneration() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let coordinator = RealtimeDiarizationCoordinator(sessionHandle: handle, backend: backend)

        await coordinator.beginSegment(startMsOffset: 5_000, hasSystemAudio: true)
        #expect(await backend.initializeCallCount == 1)
        #expect(await backend.resetCallCount == 0)

        // 0.5s/frame: frames [0, 2) -> 0.0s..1.0s -> +5000ms base offset -> 5000ms..6000ms.
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 2)]))
        await coordinator.feed(samples: makeSamples())

        let turns = try await handle.readDiarizationTurns()
        #expect(turns == [DiarizationTurn(slot: "spk_1", startMs: 5_000, endMs: 6_000)])
    }

    @Test("beginSegment's later generations reset (not re-initialize) the backend and retake the base offset")
    func baseOffsetLaterGeneration() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let coordinator = RealtimeDiarizationCoordinator(sessionHandle: handle, backend: backend)

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        // Allocate spk_1 in the first generation, so the second generation's continued numbering
        // (spk_2, not a reused spk_1) is actually exercised below.
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 1)]))
        await coordinator.feed(samples: makeSamples())
        await coordinator.endSegment(reason: .paused)

        await coordinator.beginSegment(startMsOffset: 8_000, hasSystemAudio: true)
        #expect(await backend.initializeCallCount == 1, "the model must only be loaded once, ever")
        #expect(await backend.resetCallCount == 1, "the second generation must reset the already-loaded backend")

        // Internal index 0 restarts fresh in the new generation; frames [0, 1) at 0.5s/frame -> 0.0s..0.5s.
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 1)]))
        await coordinator.feed(samples: makeSamples())

        let turns = try await handle.readDiarizationTurns()
        #expect(turns.contains(DiarizationTurn(slot: "spk_2", startMs: 8_000, endMs: 8_500)))
    }

    // MARK: - Slot numbering (design section 5.1)

    @Test("slot numbering restores the max across both diarization.jsonl and speaker_assignments.json")
    func slotNumberingRestoresFromBothFiles() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())

        // Pre-existing state from an earlier coordinator generation/process lifetime: diarization.jsonl
        // has up to spk_3, speaker_assignments.json (further along, e.g. a rename with no confirmed turn
        // yet -- design section 5.1's "未確定 turn しか持たない slot が assignments にだけ存在するケース") has spk_5.
        try await handle.appendDiarizationTurn(DiarizationTurn(slot: "spk_3", startMs: 0, endMs: 1_000))
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_5"] = SlotAssignment(displayName: "Someone")
        }

        let backend = MockDiarizationBackend()
        let coordinator = RealtimeDiarizationCoordinator(sessionHandle: handle, backend: backend)

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 1)]))
        await coordinator.feed(samples: makeSamples())

        let turns = try await handle.readDiarizationTurns()
        #expect(turns.contains { $0.slot == "spk_6" }, "numbering must continue past the higher of the two files' max (5), not diarization.jsonl's own max (3)")
    }

    /// Regression test for the review finding that `restoreSlotCounterFromDisk()` used a single shared
    /// `do`/`catch` around both file reads: a `speaker_assignments.json` read failure (e.g. corrupt
    /// JSON) must not also discard `diarization.jsonl`'s already-successfully-read max slot number.
    @Test("slot numbering survives a corrupt speaker_assignments.json using diarization.jsonl's max alone")
    func slotNumberingSurvivesCorruptAssignmentsFile() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())

        try await handle.appendDiarizationTurn(DiarizationTurn(slot: "spk_3", startMs: 0, endMs: 1_000))
        // Corrupt speaker_assignments.json directly on disk (not via `updateSpeakerAssignments`, which
        // can only ever write valid JSON) -- simulates on-disk corruption design section 8 already
        // tolerates for other sidecar files ("voiceprints.json...破損 → warning + 空 DB として再スタート").
        let assignmentsURL = directory.appendingPathComponent("speaker_assignments.json")
        try Data("{not valid json".utf8).write(to: assignmentsURL)

        let backend = MockDiarizationBackend()
        let coordinator = RealtimeDiarizationCoordinator(sessionHandle: handle, backend: backend)

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 1)]))
        await coordinator.feed(samples: makeSamples())

        let turns = try await handle.readDiarizationTurns()
        #expect(
            turns.contains { $0.slot == "spk_4" },
            "a corrupt speaker_assignments.json must not discard diarization.jsonl's own max (3); numbering must still continue from it, not collide by restarting from spk_1"
        )
    }

    // MARK: - Segment-end flush (design section 5.1)

    @Test("endSegment flushes finalizeSession's remaining segments before closing the generation")
    func endSegmentFlushesRemainingTurns() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let coordinator = RealtimeDiarizationCoordinator(sessionHandle: handle, backend: backend)

        await coordinator.beginSegment(startMsOffset: 1_000, hasSystemAudio: true)
        // No feed() call at all: this segment's only speech is still buffered in the model's
        // right-context lookahead when the segment closes, the exact tail case design section 5.1's
        // drain-then-flush rule protects against.
        await backend.setFinalizeSessionResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 2)]))
        await coordinator.endSegment(reason: .paused)

        #expect(await backend.finalizeSessionCallCount == 1)
        let turns = try await handle.readDiarizationTurns()
        #expect(turns == [DiarizationTurn(slot: "spk_1", startMs: 1_000, endMs: 2_000)])
    }

    @Test("endSegment is a no-op when the segment never had diarization running")
    func endSegmentNoOpWithoutSystemAudio() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let coordinator = RealtimeDiarizationCoordinator(sessionHandle: handle, backend: backend)

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: false)
        await coordinator.endSegment(reason: .paused)

        #expect(await backend.initializeCallCount == 0)
        #expect(await backend.finalizeSessionCallCount == 0)
        #expect(try await handle.readDiarizationTurns().isEmpty)
    }

    // MARK: - Backend errors (design section 8)

    @Test("a backend error while feeding permanently stops diarization for the rest of the session")
    func backendErrorStopsPermanently() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let coordinator = RealtimeDiarizationCoordinator(sessionHandle: handle, backend: backend)

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        await backend.setAddAudioError(MockDiarizationBackendError())
        await coordinator.feed(samples: makeSamples())

        #expect(await coordinator.isStopped())

        // Further feed() calls this segment must be true no-ops (no additional backend calls at all).
        await coordinator.feed(samples: makeSamples())
        #expect(await backend.addAudioCallCount == 1)

        // A later segment with system audio must not retry the backend either -- the failure is sticky
        // for the rest of this coordinator's (session's) lifetime, not just the current segment.
        await coordinator.endSegment(reason: .paused)
        await coordinator.beginSegment(startMsOffset: 5_000, hasSystemAudio: true)
        await coordinator.feed(samples: makeSamples())

        #expect(await backend.initializeCallCount == 1)
        #expect(await backend.resetCallCount == 0)
        #expect(await backend.addAudioCallCount == 1)
        #expect(await coordinator.isStopped())
    }

    @Test("a model initialization failure stops diarization without ever calling addAudio/process")
    func initializeFailureStopsBeforeFeeding() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        await backend.setInitializeError(MockDiarizationBackendError())
        let coordinator = RealtimeDiarizationCoordinator(sessionHandle: handle, backend: backend)

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        #expect(await coordinator.isStopped())

        await coordinator.feed(samples: makeSamples())
        #expect(await backend.addAudioCallCount == 0)
        #expect(try await handle.readDiarizationTurns().isEmpty)
    }

    // MARK: - Active ranges (design section 5)

    @Test("active ranges stay open until endSegment closes them, and record the fed-audio duration")
    func activeRangesTracked() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let coordinator = RealtimeDiarizationCoordinator(sessionHandle: handle, backend: backend)

        await coordinator.beginSegment(startMsOffset: 1_000, hasSystemAudio: true)
        #expect(await coordinator.activeRangesSnapshot() == [DiarizationActiveRange(startMs: 1_000, endMs: nil)])

        // 16,000 samples @ 16kHz == exactly 1000ms of fed audio.
        await coordinator.feed(samples: makeSamples(count: 16_000))
        #expect(await coordinator.activeRangesSnapshot() == [DiarizationActiveRange(startMs: 1_000, endMs: nil)], "still open until endSegment")

        await coordinator.endSegment(reason: .paused)
        #expect(await coordinator.activeRangesSnapshot() == [DiarizationActiveRange(startMs: 1_000, endMs: 2_000)])

        await coordinator.beginSegment(startMsOffset: 5_000, hasSystemAudio: true)
        #expect(
            await coordinator.activeRangesSnapshot() == [
                DiarizationActiveRange(startMs: 1_000, endMs: 2_000),
                DiarizationActiveRange(startMs: 5_000, endMs: nil),
            ]
        )
    }

    @Test("a segment with no system audio opens no active range")
    func noActiveRangeWithoutSystemAudio() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let coordinator = RealtimeDiarizationCoordinator(sessionHandle: handle, backend: backend)

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: false)
        #expect(await coordinator.activeRangesSnapshot().isEmpty)
    }

    // MARK: - newTurns stream

    @Test("newTurns yields every turn this coordinator successfully appends, in order")
    func newTurnsStreamYieldsAppendedTurns() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let coordinator = RealtimeDiarizationCoordinator(sessionHandle: handle, backend: backend)

        var received: [DiarizationTurn] = []
        let collector = Task {
            for await turn in await coordinator.newTurns {
                received.append(turn)
                if received.count == 2 {
                    break
                }
            }
        }

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        await backend.enqueueProcessResult(
            makeUpdate(finalizedSegments: [
                makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 1),
                makeSegment(speakerIndex: 1, startFrame: 1, endFrame: 2),
            ])
        )
        await coordinator.feed(samples: makeSamples())

        await collector.value
        #expect(received == [
            DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 500),
            DiarizationTurn(slot: "spk_2", startMs: 500, endMs: 1_000),
        ])
    }

    /// Regression test for a real field bug (2026-07-03): `endSegment(reason: .ended)` used to
    /// `finish()` the `newTurns` continuation, permanently terminating the stream. An Ended session
    /// reopened via `[↩ 再開]` (kikimi.md 10 章) keeps the same ViewModel and therefore the same
    /// coordinator, so every turn of the reopened recording was persisted to `diarization.jsonl` but
    /// never reached `speakerLabels` -- every row showed "Speaker ?". The stream must survive
    /// `.ended`; subscriber teardown is `MeetingWorkspaceViewModel.deinit`'s task cancellation, not a
    /// stream finish.
    @Test("endSegment(reason: .ended) does not finish newTurns -- an Ended session can be reopened")
    func endSegmentEndedKeepsNewTurnsStreamOpenForReopen() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let coordinator = RealtimeDiarizationCoordinator(sessionHandle: handle, backend: backend)

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        await coordinator.endSegment(reason: .ended)

        // A turn produced by the reopened generation must still reach a subscriber that started
        // listening before the meeting ended -- proof the stream was never finished by `.ended`.
        let collector = Task { () -> DiarizationTurn? in
            var iterator = await coordinator.newTurns.makeAsyncIterator()
            return await iterator.next()
        }

        await coordinator.beginSegment(startMsOffset: 8_000, hasSystemAudio: true)
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 1)]))
        await coordinator.feed(samples: makeSamples())

        let received = await collector.value
        #expect(received == DiarizationTurn(slot: "spk_1", startMs: 8_000, endMs: 8_500))
    }

    @Test("endSegment(reason: .paused) does not finish newTurns -- the meeting may still resume")
    func endSegmentPausedDoesNotFinishNewTurnsStream() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let coordinator = RealtimeDiarizationCoordinator(sessionHandle: handle, backend: backend)

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        await coordinator.endSegment(reason: .paused)

        // A turn produced by the *next* generation must still reach a subscriber that started
        // listening before this pause -- proof the stream was never finished by `.paused`.
        let collector = Task { () -> DiarizationTurn? in
            var iterator = await coordinator.newTurns.makeAsyncIterator()
            return await iterator.next()
        }

        await coordinator.beginSegment(startMsOffset: 5_000, hasSystemAudio: true)
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 1)]))
        await coordinator.feed(samples: makeSamples())

        let received = await collector.value
        #expect(received == DiarizationTurn(slot: "spk_1", startMs: 5_000, endMs: 5_500))
    }

    // MARK: - Voiceprint extraction & matching (design section 5/4.3, "R2")

    @Test("a slot's speech only triggers extraction once its accumulated audio crosses min_enroll_speech_ms, and never again after that")
    func accumulationThresholdTriggersOneShotExtraction() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let extractor = FakeVoiceprintExtractor()
        let coordinator = RealtimeDiarizationCoordinator(
            sessionHandle: handle,
            backend: backend,
            voiceprintExtractor: extractor,
            voiceprintStore: makeTempVoiceprintStore(),
            minEnrollSpeechMs: 1_000,
            speakerMatchThreshold: 0.5
        )

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)

        // First 0.5s turn: 8,000 samples @16kHz, well under the 16,000-sample (1,000ms) threshold.
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 1)]))
        await coordinator.feed(samples: makeSamples(value: 0, count: 8_000))
        #expect(await extractor.callCount == 0, "must not extract before the threshold is reached")

        // Second 0.5s turn completes the buffer to exactly 16,000 samples (1,000ms) -- crosses the
        // threshold and must trigger extraction exactly once.
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 1, endFrame: 2)]))
        await coordinator.feed(samples: makeSamples(value: 1, count: 8_000))

        try await waitUntil { await extractor.callCount == 1 }
        let receivedCounts = await extractor.receivedSamples.map(\.count)
        #expect(receivedCounts == [16_000])

        // A third turn for the same slot must not trigger a second extraction, ever (one-shot contract).
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 2, endFrame: 3)]))
        await coordinator.feed(samples: makeSamples(value: 2, count: 8_000))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await extractor.callCount == 1, "must never re-extract a slot once it has been extracted")
    }

    @Test("a slot's accumulated audio is capped at 10 seconds (most recent), even if the threshold takes longer to reach")
    func accumulatedAudioIsCappedToTenSecondsMostRecent() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let extractor = FakeVoiceprintExtractor()
        // 11,000ms threshold needs 176,000 samples -- more than `VoiceprintExtractor.maxSampleCount`
        // (160,000 == 10s @16kHz), so the slice handed to the extractor must be capped.
        let coordinator = RealtimeDiarizationCoordinator(
            sessionHandle: handle,
            backend: backend,
            voiceprintExtractor: extractor,
            voiceprintStore: makeTempVoiceprintStore(),
            minEnrollSpeechMs: 11_000,
            speakerMatchThreshold: 0.5
        )

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        // 11 one-second turns (frameDurationSeconds: 1.0 -> 1 frame == 16,000 samples), each filled with
        // a distinct value so the capped result's contents reveal which chunks survived.
        for index in 0..<11 {
            await backend.enqueueProcessResult(
                makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: index, endFrame: index + 1, frameDurationSeconds: 1.0)])
            )
            await coordinator.feed(samples: makeSamples(value: Float(index), count: 16_000))
        }

        try await waitUntil { await extractor.callCount == 1 }
        let received = await extractor.receivedSamples[0]
        #expect(received.count == VoiceprintExtractor.maxSampleCount, "must be capped at exactly 10s of samples")
        #expect(received.first == 1, "the oldest 1s chunk (value 0) must have been dropped, keeping only the most recent 10s")
        #expect(received.last == 10, "the most recent chunk (value 10) must be retained")
    }

    @Test("the extracted embedding is persisted to speaker_assignments.json before any voiceprint match is attempted, even when nothing matches")
    func embeddingPersistedBeforeMatchingEvenWithoutAMatch() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let extractor = FakeVoiceprintExtractor()
        await extractor.setEmbeddingResult([0.5, 0.25, 0.1, 0.05])
        // Empty voiceprint DB: `findMatchCandidate` returns `nil`, so this exercises the "persist first,
        // matching finds nothing" branch in isolation.
        let coordinator = RealtimeDiarizationCoordinator(
            sessionHandle: handle,
            backend: backend,
            voiceprintExtractor: extractor,
            voiceprintStore: makeTempVoiceprintStore(),
            minEnrollSpeechMs: 1_000,
            speakerMatchThreshold: 0.5
        )

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 2, frameDurationSeconds: 0.5)]))
        await coordinator.feed(samples: makeSamples(count: 16_000))

        try await waitUntil {
            let assignments = try? await handle.readSpeakerAssignments()
            return assignments?.assignments["spk_1"]?.embedding != nil
        }
        let assignments = try await handle.readSpeakerAssignments()
        let slot = try #require(assignments.assignments["spk_1"])
        #expect(slot.embedding == [0.5, 0.25, 0.1, 0.05])
        #expect(slot.globalSpeakerId == nil, "no match was possible against an empty voiceprint DB")
        #expect(slot.displayName == nil)
        #expect(slot.assignedBy == nil)
    }

    @Test("a successful voiceprint match writes an auto assignment and signals assignmentUpdates")
    func successfulMatchWritesAutoAssignmentAndSignalsSubscribers() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let extractor = FakeVoiceprintExtractor()
        let matchingEmbedding: [Float] = [1, 0, 0, 0]
        await extractor.setEmbeddingResult(matchingEmbedding)

        let voiceprintStore = makeTempVoiceprintStore()
        let registered = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: matchingEmbedding)

        let coordinator = RealtimeDiarizationCoordinator(
            sessionHandle: handle,
            backend: backend,
            voiceprintExtractor: extractor,
            voiceprintStore: voiceprintStore,
            minEnrollSpeechMs: 1_000,
            speakerMatchThreshold: 0.5
        )

        var assignmentUpdateCount = 0
        let collector = Task {
            for await _ in await coordinator.assignmentUpdates {
                assignmentUpdateCount += 1
                break
            }
        }

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 2, frameDurationSeconds: 0.5)]))
        await coordinator.feed(samples: makeSamples(count: 16_000))

        await collector.value
        #expect(assignmentUpdateCount == 1)

        let assignments = try await handle.readSpeakerAssignments()
        let slot = try #require(assignments.assignments["spk_1"])
        #expect(slot.globalSpeakerId == registered.id)
        #expect(slot.displayName == "田中さん")
        #expect(slot.assignedBy == .auto)
        #expect(slot.embedding == matchingEmbedding)
    }

    @Test("an existing user assignment is never overwritten by an auto voiceprint match, though its embedding is still updated")
    func userAssignmentIsNeverOverwrittenByAnAutoMatch() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let extractor = FakeVoiceprintExtractor()
        let matchingEmbedding: [Float] = [1, 0, 0, 0]
        await extractor.setEmbeddingResult(matchingEmbedding)

        let voiceprintStore = makeTempVoiceprintStore()
        try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: matchingEmbedding)

        let coordinator = RealtimeDiarizationCoordinator(
            sessionHandle: handle,
            backend: backend,
            voiceprintExtractor: extractor,
            voiceprintStore: voiceprintStore,
            minEnrollSpeechMs: 1_000,
            speakerMatchThreshold: 0.5
        )

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        // First (sub-threshold) turn allocates "spk_1" for internal index 0.
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 1)]))
        await coordinator.feed(samples: makeSamples(value: 0, count: 8_000))

        // The user has already renamed "spk_1" by the time it crosses the enrollment threshold.
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(displayName: "佐藤さん", assignedBy: .user)
        }

        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 1, endFrame: 2)]))
        await coordinator.feed(samples: makeSamples(value: 1, count: 8_000))

        try await waitUntil {
            let assignments = try? await handle.readSpeakerAssignments()
            return assignments?.assignments["spk_1"]?.embedding != nil
        }

        let assignments = try await handle.readSpeakerAssignments()
        let slot = try #require(assignments.assignments["spk_1"])
        #expect(slot.displayName == "佐藤さん", "the user's own name must survive an auto match")
        #expect(slot.assignedBy == .user, "assignedBy must stay .user, never regress to .auto")
        #expect(slot.globalSpeakerId == nil, "the auto match's global id must not be written over a user assignment")
        #expect(slot.embedding == matchingEmbedding, "the embedding itself is not assignment-source-protected -- it always reflects the latest extraction")
    }

    @Test("a match rejectedByThreshold (nearest speaker too far away) never writes an auto assignment, even though the embedding is still persisted (design section 20 §3.1/3.3)")
    func rejectedByThresholdNeverWritesAnAutoAssignment() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let extractor = FakeVoiceprintExtractor()
        let extractedEmbedding: [Float] = [1, 0]
        await extractor.setEmbeddingResult(extractedEmbedding)

        // Orthogonal to the extracted embedding: cosineDistance == 1 - 0 == 1.0, far above the threshold.
        let voiceprintStore = makeTempVoiceprintStore()
        try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: [0, 1])

        let coordinator = RealtimeDiarizationCoordinator(
            sessionHandle: handle,
            backend: backend,
            voiceprintExtractor: extractor,
            voiceprintStore: voiceprintStore,
            minEnrollSpeechMs: 1_000,
            speakerMatchThreshold: 0.5,
            speakerMatchMargin: 0.05
        )

        var assignmentUpdateCount = 0
        let collector = Task {
            for await _ in await coordinator.assignmentUpdates {
                assignmentUpdateCount += 1
            }
        }

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 2, frameDurationSeconds: 0.5)]))
        await coordinator.feed(samples: makeSamples(count: 16_000))

        try await waitUntil {
            let assignments = try? await handle.readSpeakerAssignments()
            return assignments?.assignments["spk_1"]?.embedding != nil
        }
        // Give the (rejected) match's own completion a moment to run before asserting the negative.
        try await Task.sleep(for: .milliseconds(100))
        collector.cancel()

        let assignments = try await handle.readSpeakerAssignments()
        let slot = try #require(assignments.assignments["spk_1"])
        #expect(slot.embedding == extractedEmbedding, "the embedding must still be persisted even though the match was rejected")
        #expect(slot.globalSpeakerId == nil, "a rejectedByThreshold match must never write an auto assignment")
        #expect(slot.displayName == nil)
        #expect(slot.assignedBy == nil)
        #expect(assignmentUpdateCount == 0, "a rejected match must never signal assignmentUpdates")
    }

    @Test("a match rejectedByMargin (ambiguous runner-up) never writes an auto assignment, even though the nearest distance alone clears the threshold (design section 20 §3.1/3.3)")
    func rejectedByMarginNeverWritesAnAutoAssignment() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let extractor = FakeVoiceprintExtractor()
        let extractedEmbedding: [Float] = [1, 0]
        await extractor.setEmbeddingResult(extractedEmbedding)

        // "田中さん" is an exact match (distance 0), well under the threshold. "佐藤さん" is a different,
        // differently-named speaker just barely behind it -- close enough that the gap falls short of
        // `speakerMatchMargin`, so the match must be rejected as ambiguous rather than accepted.
        let voiceprintStore = makeTempVoiceprintStore()
        try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: [1, 0])
        try await voiceprintStore.registerSpeaker(name: "佐藤さん", embedding: [1, 0.1])

        let coordinator = RealtimeDiarizationCoordinator(
            sessionHandle: handle,
            backend: backend,
            voiceprintExtractor: extractor,
            voiceprintStore: voiceprintStore,
            minEnrollSpeechMs: 1_000,
            speakerMatchThreshold: 0.5,
            speakerMatchMargin: 0.01
        )

        var assignmentUpdateCount = 0
        let collector = Task {
            for await _ in await coordinator.assignmentUpdates {
                assignmentUpdateCount += 1
            }
        }

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 2, frameDurationSeconds: 0.5)]))
        await coordinator.feed(samples: makeSamples(count: 16_000))

        try await waitUntil {
            let assignments = try? await handle.readSpeakerAssignments()
            return assignments?.assignments["spk_1"]?.embedding != nil
        }
        // Give the (rejected) match's own completion a moment to run before asserting the negative.
        try await Task.sleep(for: .milliseconds(100))
        collector.cancel()

        let assignments = try await handle.readSpeakerAssignments()
        let slot = try #require(assignments.assignments["spk_1"])
        #expect(slot.embedding == extractedEmbedding, "the embedding must still be persisted even though the match was rejected")
        #expect(slot.globalSpeakerId == nil, "a rejectedByMargin match must never write an auto assignment")
        #expect(slot.displayName == nil)
        #expect(slot.assignedBy == nil)
        #expect(assignmentUpdateCount == 0, "a rejected match must never signal assignmentUpdates")
    }

    @Test("a voiceprint extraction failure leaves the slot anonymous without crashing or stopping diarization, and still never re-extracts")
    func extractionFailureLeavesSlotAnonymousWithoutCrashing() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let extractor = FakeVoiceprintExtractor()
        await extractor.setExtractionError(FakeVoiceprintExtractorError())

        let coordinator = RealtimeDiarizationCoordinator(
            sessionHandle: handle,
            backend: backend,
            voiceprintExtractor: extractor,
            voiceprintStore: makeTempVoiceprintStore(),
            minEnrollSpeechMs: 1_000,
            speakerMatchThreshold: 0.5
        )

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 2, frameDurationSeconds: 0.5)]))
        await coordinator.feed(samples: makeSamples(count: 16_000))

        try await waitUntil { await extractor.callCount == 1 }
        // Give the (failed) extraction task a moment to finish its error-handling path before asserting
        // the negative ("nothing was ever written").
        try await Task.sleep(for: .milliseconds(100))

        let assignments = try await handle.readSpeakerAssignments()
        #expect(assignments.assignments["spk_1"]?.embedding == nil, "a failed extraction must never persist a partial/garbage embedding")
        #expect(await coordinator.isStopped() == false, "an extraction failure must not stop diarization itself (design section 8)")

        // Further turns for the same slot must not retry the extraction (still one-shot, even after failure).
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 2, endFrame: 3)]))
        await coordinator.feed(samples: makeSamples(count: 8_000))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await extractor.callCount == 1)
    }

    // MARK: - Participant hints / closed-set matching (docs/design/22-participant-hints.md)

    @Test("closed-set matching in the live extraction path excludes an off-roster speaker, even one closer than any threshold, while still persisting the embedding")
    func closedSetMatchingExcludesOffRosterSpeakerInLiveExtraction() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let extractor = FakeVoiceprintExtractor()
        let extractedEmbedding: [Float] = [1, 0]
        await extractor.setEmbeddingResult(extractedEmbedding)

        // An exact-distance-0 match, which would trivially be accepted under open-set matching.
        let voiceprintStore = makeTempVoiceprintStore()
        let offRoster = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: [1, 0])

        let coordinator = RealtimeDiarizationCoordinator(
            sessionHandle: handle,
            backend: backend,
            voiceprintExtractor: extractor,
            voiceprintStore: voiceprintStore,
            minEnrollSpeechMs: 1_000,
            speakerMatchThreshold: 0.5
        )
        // A roster that does not include the only registered (and otherwise-perfectly-matching) speaker.
        await coordinator.updateParticipantHints(["some-other-speaker-id"])

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 2, frameDurationSeconds: 0.5)]))
        await coordinator.feed(samples: makeSamples(count: 16_000))

        try await waitUntil {
            let assignments = try? await handle.readSpeakerAssignments()
            return assignments?.assignments["spk_1"]?.embedding != nil
        }
        // Give the (rejected-by-closed-set) match's own completion a moment to run.
        try await Task.sleep(for: .milliseconds(100))

        let assignments = try await handle.readSpeakerAssignments()
        let slot = try #require(assignments.assignments["spk_1"])
        #expect(slot.embedding == extractedEmbedding, "the embedding must still be persisted regardless of the roster")
        #expect(slot.globalSpeakerId != offRoster.id, "an off-roster speaker must never be auto-assigned, no matter how close the distance")
        #expect(slot.globalSpeakerId == nil)
        #expect(slot.displayName == nil)
    }

    @Test("closed-set matching in the live extraction path still accepts an on-roster speaker")
    func closedSetMatchingAllowsOnRosterSpeakerInLiveExtraction() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let extractor = FakeVoiceprintExtractor()
        let matchingEmbedding: [Float] = [1, 0]
        await extractor.setEmbeddingResult(matchingEmbedding)

        let voiceprintStore = makeTempVoiceprintStore()
        let onRoster = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: matchingEmbedding)

        let coordinator = RealtimeDiarizationCoordinator(
            sessionHandle: handle,
            backend: backend,
            voiceprintExtractor: extractor,
            voiceprintStore: voiceprintStore,
            minEnrollSpeechMs: 1_000,
            speakerMatchThreshold: 0.5
        )
        await coordinator.updateParticipantHints([onRoster.id])

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 2, frameDurationSeconds: 0.5)]))
        await coordinator.feed(samples: makeSamples(count: 16_000))

        try await waitUntil {
            let assignments = try? await handle.readSpeakerAssignments()
            return assignments?.assignments["spk_1"]?.globalSpeakerId != nil
        }

        let assignments = try await handle.readSpeakerAssignments()
        let slot = try #require(assignments.assignments["spk_1"])
        #expect(slot.globalSpeakerId == onRoster.id)
        #expect(slot.displayName == "田中さん")
        #expect(slot.assignedBy == .auto)
    }

    @Test("updateParticipantHints triggers a rematch only when the roster actually changes, resolving a previously-anonymous eligible slot exactly once")
    func updateParticipantHintsTriggersRematchOnlyOnChange() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let voiceprintStore = makeTempVoiceprintStore()
        let registered = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: [1, 0])

        // A slot whose voiceprint was already extracted (design section 5's event-driven extraction, a
        // prior live-extraction pass) but never matched -- exactly `rematchAnonymousSlots`'s target.
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(embedding: [1, 0])
        }

        let coordinator = RealtimeDiarizationCoordinator(
            sessionHandle: handle,
            backend: backend,
            voiceprintExtractor: FakeVoiceprintExtractor(),
            voiceprintStore: voiceprintStore,
            minEnrollSpeechMs: 1_000,
            speakerMatchThreshold: 0.5
        )

        var updateCount = 0
        let collector = Task {
            for await _ in await coordinator.assignmentUpdates {
                updateCount += 1
            }
        }

        await coordinator.updateParticipantHints([registered.id])
        try await waitUntil {
            let assignments = try? await handle.readSpeakerAssignments()
            return assignments?.assignments["spk_1"]?.globalSpeakerId != nil
        }

        // Same roster again -- must be a true no-op (no re-triggered rematch), not just "produces the
        // same result again".
        await coordinator.updateParticipantHints([registered.id])
        try await Task.sleep(for: .milliseconds(100))
        collector.cancel()

        let assignments = try await handle.readSpeakerAssignments()
        let slot = try #require(assignments.assignments["spk_1"])
        #expect(slot.globalSpeakerId == registered.id)
        #expect(slot.displayName == "田中さん")
        #expect(slot.assignedBy == .auto)
        #expect(updateCount == 1, "an unchanged roster push must not re-trigger rematchAnonymousSlots")
    }

    @Test("rematchAnonymousSlots never touches a .user slot or an already-named .auto slot, even when the roster would otherwise match them")
    func rematchAnonymousSlotsLeavesProtectedSlotsUntouched() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let voiceprintStore = makeTempVoiceprintStore()
        let registered = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: [1, 0])

        try await handle.updateSpeakerAssignments { assignments in
            // A `.user` slot -- never rewritten by any auto path.
            assignments.assignments["spk_1"] = SlotAssignment(
                globalSpeakerId: nil, displayName: "手動さん", assignedBy: .user, embedding: [1, 0]
            )
            // An already-named `.auto` slot -- design section 3's "実名確定済み。名簿の削除・変更で巻き戻さない".
            assignments.assignments["spk_2"] = SlotAssignment(
                globalSpeakerId: "some-other-id", displayName: "別の人", assignedBy: .auto, embedding: [1, 0]
            )
        }

        let coordinator = RealtimeDiarizationCoordinator(
            sessionHandle: handle,
            backend: backend,
            voiceprintExtractor: FakeVoiceprintExtractor(),
            voiceprintStore: voiceprintStore,
            minEnrollSpeechMs: 1_000,
            speakerMatchThreshold: 0.5
        )

        await coordinator.updateParticipantHints([registered.id])
        // rematchAnonymousSlots is awaited to completion inside updateParticipantHints, so there is
        // nothing further to wait for here.

        let assignments = try await handle.readSpeakerAssignments()
        #expect(assignments.assignments["spk_1"]?.displayName == "手動さん")
        #expect(assignments.assignments["spk_1"]?.assignedBy == .user)
        #expect(assignments.assignments["spk_2"]?.displayName == "別の人")
        #expect(assignments.assignments["spk_2"]?.globalSpeakerId == "some-other-id", "an already-named auto slot must not be rolled back onto the new roster's match")
    }

    @Test("rematchAnonymousSlots is idempotent -- a second call with the same roster produces no further writes or signals")
    func rematchAnonymousSlotsIsIdempotent() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let voiceprintStore = makeTempVoiceprintStore()
        let registered = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: [1, 0])

        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(embedding: [1, 0])
        }

        let coordinator = RealtimeDiarizationCoordinator(
            sessionHandle: handle,
            backend: backend,
            voiceprintExtractor: FakeVoiceprintExtractor(),
            voiceprintStore: voiceprintStore,
            minEnrollSpeechMs: 1_000,
            speakerMatchThreshold: 0.5
        )

        // Subscribed *before* either call: `AsyncStream`'s default unbounded buffering policy would
        // otherwise hand a collector that starts subscribing only after the first call its still-
        // buffered yield, misattributing it to the second (supposedly idempotent) call.
        var updateCount = 0
        let collector = Task {
            for await _ in await coordinator.assignmentUpdates {
                updateCount += 1
            }
        }

        await coordinator.updateParticipantHints([registered.id])
        try await waitUntil { updateCount == 1 }
        let afterFirst = try await handle.readSpeakerAssignments()

        // Calling the rematch entry point directly a second time (same roster, already-resolved slot)
        // must not find anything left to touch.
        await coordinator.rematchAnonymousSlots()
        try await Task.sleep(for: .milliseconds(100))
        collector.cancel()

        let afterSecond = try await handle.readSpeakerAssignments()
        #expect(afterSecond == afterFirst)
        #expect(updateCount == 1, "a second rematch pass over an already-resolved slot must not yield again")
    }

    @Test("writeAutoAssignmentIfAllowed's §3.1 roster guard rejects a write for a candidate no longer in the current roster, even though the caller already computed an accepted match (rejectedByRoster)")
    func writeAutoAssignmentRejectsWhenRosterExcludesCandidateAtWriteTime() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let voiceprintStore = makeTempVoiceprintStore()
        let offRoster = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: [1, 0])

        let coordinator = RealtimeDiarizationCoordinator(
            sessionHandle: handle,
            backend: backend,
            voiceprintExtractor: FakeVoiceprintExtractor(),
            voiceprintStore: voiceprintStore,
            minEnrollSpeechMs: 1_000,
            speakerMatchThreshold: 0.5
        )
        // The roster excludes `offRoster` by the time the write is attempted -- simulates the design
        // section 3.1 race directly (a candidate already resolved as `.accepted` against a roster/no
        // roster that has since changed), without depending on exact actor-reentrancy timing.
        await coordinator.updateParticipantHints(["someone-else"])

        let candidate = VoiceprintStore.VoiceprintMatchCandidate(speaker: offRoster, distance: 0, runnerUp: nil)
        let wrote = await coordinator.writeAutoAssignmentIfAllowed(
            slot: "spk_1", candidate: candidate, embedding: [1, 0], trigger: "live"
        )

        #expect(wrote == false)
        let assignments = try await handle.readSpeakerAssignments()
        #expect(assignments.assignments["spk_1"] == nil, "a roster-excluded candidate must never be written, even pre-decided as accepted")
    }

    @Test("an in-flight extraction that started before a roster change never assigns the now-off-roster speaker once it resumes (end-to-end actor-reentrancy coverage, design section 3.1)")
    func rosterChangeDuringInFlightExtractionIsHonoredByTheTimeItWrites() async throws {
        let directory = makeTempSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = SessionHandle(directoryURL: directory, meta: baseMeta())
        let backend = MockDiarizationBackend()
        let extractor = FakeVoiceprintExtractor()
        let matchingEmbedding: [Float] = [1, 0]
        await extractor.setEmbeddingResult(matchingEmbedding)

        let voiceprintStore = makeTempVoiceprintStore()
        let offRosterAfterChange = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: matchingEmbedding)

        let coordinator = RealtimeDiarizationCoordinator(
            sessionHandle: handle,
            backend: backend,
            voiceprintExtractor: extractor,
            voiceprintStore: voiceprintStore,
            minEnrollSpeechMs: 1_000,
            speakerMatchThreshold: 0.5
        )

        // Extraction starts under open-set matching (no roster configured yet) but blocks at the gate
        // before returning its embedding.
        let (gateStream, gateContinuation) = AsyncStream<Void>.makeStream()
        await extractor.setGate {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }

        await coordinator.beginSegment(startMsOffset: 0, hasSystemAudio: true)
        await backend.enqueueProcessResult(makeUpdate(finalizedSegments: [makeSegment(speakerIndex: 0, startFrame: 0, endFrame: 2, frameDurationSeconds: 0.5)]))
        await coordinator.feed(samples: makeSamples(count: 16_000))

        // Wait until the fire-and-forget extraction task is actually blocked at the gate.
        try await waitUntil { await extractor.callCount == 1 }

        // While extraction is still in flight, the roster changes to exclude the only registered
        // speaker -- exercised concurrently with the still-suspended extraction task.
        await coordinator.updateParticipantHints(["someone-else"])

        // Release the extraction; it resumes, persists the embedding, and attempts to match/write.
        gateContinuation.finish()

        try await waitUntil {
            let assignments = try? await handle.readSpeakerAssignments()
            return assignments?.assignments["spk_1"]?.embedding != nil
        }
        try await Task.sleep(for: .milliseconds(100))

        let assignments = try await handle.readSpeakerAssignments()
        let slot = try #require(assignments.assignments["spk_1"])
        #expect(slot.embedding == matchingEmbedding)
        #expect(slot.globalSpeakerId != offRosterAfterChange.id, "the roster change that raced the in-flight extraction must still be honored by the time the write happens")
        #expect(slot.globalSpeakerId == nil)
    }
}
