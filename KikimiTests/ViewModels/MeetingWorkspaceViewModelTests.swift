import AVFoundation
import Foundation
import Testing

@testable import Kikimi

// MARK: - Fakes (docs/design/06-ui-panels.md section 12: fake AudioCapture/TranscriptPipeline via DI)

/// Deterministic stand-in for `AudioCapture`, mirroring the `AudioSourceCapturing` fake pattern
/// already used by `01-audio-capture.md`'s own tests. Lets `startRecording()`'s rollback branch be
/// exercised without touching real `AVAudioEngine`/ScreenCaptureKit.
private final class FakeAudioCapture: RecordingAudioCapturing {
    var startError: Error?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    /// Asserted against in `startRecordingSuccessPath` to guard the wiring `startRecording()` must
    /// perform before `start()` (`TranscriptPipeline`'s call-order contract step ④): without it, no
    /// captured buffer would ever reach the STT engines in production.
    weak var delegate: AudioCaptureDelegate?

    func start() async throws {
        startCallCount += 1
        if let startError { throw startError }
    }

    func stop() async {
        stopCallCount += 1
    }
}

/// Deterministic stand-in for `TranscriptPipeline`. Lets `startRecording()`'s rollback branch and
/// `liveSegments` forwarding both be exercised without a real, possibly-not-installed sherpa-onnx
/// model.
private final class FakeTranscriptPipeline: RecordingTranscriptPipelining {
    var prepareError: Error?
    private(set) var prepareCallCount = 0
    private(set) var stopAndDrainCallCount = 0

    /// `docs/design/10-audio-input-selection.md` section 5.2's `RecordingTranscriptPipelining
    /// .onDegrade` DI point. Tests trigger it directly via `simulateDegrade(source:error:)` below,
    /// mirroring how `FakeAudioCapture` doesn't actually invoke real `AudioCaptureDelegate` callbacks
    /// either -- these fakes let tests drive each callback deterministically instead of depending on
    /// a real `AudioCapture`/`SystemAudioSource` to fire it.
    var onDegrade: (@Sendable (AudioSourceKind, AudioCaptureError) -> Void)?

    /// `docs/design/13-speaker-diarization.md` section 5's `RecordingTranscriptPipelining
    /// .onSystemAudio` DI point. Tests trigger it directly via `simulateSystemAudio(_:)` below, same
    /// rationale as `onDegrade` above.
    var onSystemAudio: (@Sendable ([Float], TimeInterval) async -> Void)?

    private let stream: AsyncStream<TranscriptSegment>
    private let continuation: AsyncStream<TranscriptSegment>.Continuation
    private let volatileStream: AsyncStream<SttVolatileTranscript>
    private let volatileContinuation: AsyncStream<SttVolatileTranscript>.Continuation

    var liveSegments: AsyncStream<TranscriptSegment> { stream }
    var volatileTranscripts: AsyncStream<SttVolatileTranscript> { volatileStream }

    init() {
        (stream, continuation) = AsyncStream.makeStream()
        (volatileStream, volatileContinuation) = AsyncStream.makeStream()
    }

    func prepare(downloadProgress: (@Sendable (AudioSourceKind, SttModelDownloadProgress) -> Void)?) async throws {
        prepareCallCount += 1
        if let prepareError { throw prepareError }
    }

    func stopAndDrain() async {
        stopAndDrainCallCount += 1
        continuation.finish()
        volatileContinuation.finish()
    }

    func yield(_ segment: TranscriptSegment) {
        continuation.yield(segment)
    }

    /// Test-only trigger for `volatileTranscripts` (`docs/design/11-streaming-stt.md` section 3.6),
    /// standing in for `SttEngine.processChunkResult(...)` yielding pending-segment text through a real
    /// `TranscriptPipeline`.
    func yieldVolatile(_ volatile: SttVolatileTranscript) {
        volatileContinuation.yield(volatile)
    }

    /// Test-only trigger for `onDegrade`, standing in for `AudioCapture` actually calling
    /// `audioCapture(_:didDegrade:error:)` (which in production would forward here -- see
    /// `TranscriptPipeline.audioCapture(_:didDegrade:error:)`).
    func simulateDegrade(source: AudioSourceKind, error: AudioCaptureError) {
        onDegrade?(source, error)
    }

    /// Test-only trigger for `onSystemAudio`, standing in for `TranscriptPipeline`'s own systemFeedTask
    /// forwarding samples after each `SttEngine.feed(...)` call (`Kikimi/Stt/TranscriptPipeline.swift`).
    func simulateSystemAudio(_ samples: [Float], elapsedAtBufferStart: TimeInterval = 0) async {
        await onSystemAudio?(samples, elapsedAtBufferStart)
    }

    // MARK: AudioCaptureDelegate (required by `RecordingTranscriptPipelining`; unused by these tests,
    // which drive segment delivery directly via `yield(_:)` instead of through a `FakeAudioCapture`
    // actually invoking these callbacks).

    func audioCapture(_ capture: AudioCapture, didCapture buffer: AVAudioPCMBuffer, source: AudioSourceKind, elapsed: TimeInterval) {}
    func audioCapture(_ capture: AudioCapture, didDegrade source: AudioSourceKind, error: AudioCaptureError) {}
    func audioCapture(_ capture: AudioCapture, didUpdateLevel level: Double, source: AudioSourceKind) {}
    func audioCaptureDidStop(_ capture: AudioCapture) {}
}

/// Deterministic stand-in for `RealtimeDiarizationCoordinator` (`docs/design/13-speaker
/// -diarization.md` section 5), the default `diarizationCoordinatorFactory` backing for
/// `makeViewModel(...)` below. Every pre-existing recording-lifecycle test that doesn't care about
/// diarization keeps working unchanged and hermetic: unlike the real `LSEENDDiarizationBackend`
/// (a real CoreML model, downloaded from the network on first `initialize()`), this never touches
/// disk/network and returns instantly, so `beginSegment`/`endSegment` add no wall-clock delay to
/// `startRecording()`/`pauseRecording()`/`endMeeting()`'s elapsed-time assertions.
private actor FakeDiarizationCoordinator: DiarizationCoordinating {
    private(set) var beginSegmentCalls: [(startMsOffset: Int, hasSystemAudio: Bool)] = []
    private(set) var feedCallCount = 0
    private(set) var feedSampleCounts: [Int] = []
    /// Every `elapsedAtBufferStart` this coordinator was fed, in call order (design section 5.1's
    /// "実装時の追記 2026-08-01"): lets a test assert the ViewModel actually forwards `TranscriptPipeline
    /// .onSystemAudio`'s capture-clock anchor instead of silently dropping it.
    private(set) var feedElapsedAtBufferStarts: [TimeInterval] = []
    private(set) var endSegmentCalls: [DiarizationSegmentEndReason] = []
    private var activeRanges: [DiarizationActiveRange] = []
    private var stopped = false
    /// `docs/design/22-participant-hints.md` section 2.2. Recorded (not just applied) so a P2 test can
    /// assert `MeetingWorkspaceViewModel+Participants.swift` actually pushed the roster after a mutation,
    /// the same way `beginSegmentCalls`/`endSegmentCalls` above let existing tests assert lifecycle calls.
    private(set) var participantHintUpdates: [Set<String>] = []
    private(set) var participantHintIds: Set<String> = []

    private let turnsStream: AsyncStream<DiarizationTurn>
    private let turnsContinuation: AsyncStream<DiarizationTurn>.Continuation
    private let assignmentUpdatesStream: AsyncStream<Void>
    private let assignmentUpdatesContinuation: AsyncStream<Void>.Continuation

    init() {
        (turnsStream, turnsContinuation) = AsyncStream.makeStream()
        (assignmentUpdatesStream, assignmentUpdatesContinuation) = AsyncStream.makeStream()
    }

    nonisolated var newTurns: AsyncStream<DiarizationTurn> { turnsStream }
    nonisolated var assignmentUpdates: AsyncStream<Void> { assignmentUpdatesStream }

    func beginSegment(startMsOffset: Int, hasSystemAudio: Bool) async {
        beginSegmentCalls.append((startMsOffset, hasSystemAudio))
        guard hasSystemAudio, !stopped else { return }
        activeRanges.append(DiarizationActiveRange(startMs: startMsOffset, endMs: nil))
    }

    func feed(samples: [Float], elapsedAtBufferStart: TimeInterval) async {
        feedCallCount += 1
        feedSampleCounts.append(samples.count)
        feedElapsedAtBufferStarts.append(elapsedAtBufferStart)
    }

    func endSegment(reason: DiarizationSegmentEndReason) async {
        endSegmentCalls.append(reason)
        guard let lastIndex = activeRanges.indices.last, activeRanges[lastIndex].endMs == nil else { return }
        activeRanges[lastIndex].endMs = activeRanges[lastIndex].startMs
    }

    func activeRangesSnapshot() async -> [DiarizationActiveRange] {
        activeRanges
    }

    func isStopped() async -> Bool {
        stopped
    }

    func updateParticipantHints(_ ids: Set<String>) async {
        participantHintUpdates.append(ids)
        participantHintIds = ids
    }

    /// Test-only trigger for `newTurns`, standing in for `RealtimeDiarizationCoordinator` finalizing a
    /// turn from a real LS-EEND backend.
    func emitTurn(_ turn: DiarizationTurn) {
        turnsContinuation.yield(turn)
    }

    /// Test-only trigger for `assignmentUpdates`, standing in for `RealtimeDiarizationCoordinator`
    /// landing an `.auto` voiceprint match (design section 5, "R2").
    func emitAssignmentUpdate() {
        assignmentUpdatesContinuation.yield(())
    }
}

private struct FakeError: Error, Equatable {}

/// Deterministic stand-in for `VoiceprintWavFallbackExtractor` (`docs/design/13-speaker
/// -diarization.md` section 4.4's "実装時の追記 2026-07-03" on-demand WAV fallback), the default
/// `voiceprintWavFallbackExtractorFactory` backing for `makeViewModel(...)` below. Lets
/// `applyRename(slot:submission:)`'s `.localOnly` scheduling be exercised deterministically without
/// ever touching a real `AVAudioFile`/WeSpeaker CoreML model. An `actor` (not a plain class) since
/// `VoiceprintWavFallbackExtracting` requires `Sendable` and this fake's state
/// (`requestedSlots`/`behavior`) is written from `extractEmbedding(forSlot:)` (called from the
/// ViewModel's own background `Task`) and read from the test's assertions afterward.
private actor FakeVoiceprintWavFallbackExtractor: VoiceprintWavFallbackExtracting {
    enum Behavior {
        case returns([Float]?)
        case throwsError(Error)
    }

    private let behavior: Behavior
    private(set) var requestedSlots: [String] = []

    init(behavior: Behavior = .returns(nil)) {
        self.behavior = behavior
    }

    func extractEmbedding(forSlot slot: String) async throws -> [Float]? {
        requestedSlots.append(slot)
        switch behavior {
        case .returns(let value):
            return value
        case .throwsError(let error):
            throw error
        }
    }
}

/// Deterministic stand-in for `OverrideEnrollmentExtractor` (`docs/design/20-voiceprint
/// -misassignment-mitigation.md` section 5.4's stage 2), the default
/// `overrideEnrollmentExtractorFactory` backing for `makeViewModel(...)` below. Lets
/// `applyVoiceprintEnrollmentUpdates(assignments:)`'s override-aggregate fire-and-forget scheduling be
/// exercised deterministically without ever touching a real `AVAudioFile`/WeSpeaker CoreML model.
private actor FakeOverrideEnrollmentExtractor: OverrideEnrollmentExtracting {
    enum Behavior {
        case returns([Float]?)
        case throwsError(Error)
    }

    private let behavior: Behavior
    private(set) var requestedSliceCounts: [Int] = []

    init(behavior: Behavior = .returns(nil)) {
        self.behavior = behavior
    }

    func extractEmbedding(slices: [EnrollmentSampleSlice]) async throws -> [Float]? {
        requestedSliceCounts.append(slices.count)
        switch behavior {
        case .returns(let value):
            return value
        case .throwsError(let error):
            throw error
        }
    }
}

/// Deterministic, network-free stand-in for `LLMCompleting` (`docs/design/04-summary-updater.md`
/// section 4.1's SWE review C8), mirroring `SummaryUpdaterTests.swift`'s own `FakeLLM` (kept as a
/// separate private type here rather than shared, since that one is file-private to its own test
/// file). Used as the default `summaryUpdaterFactory` backing so every pre-existing recording-
/// lifecycle test keeps exercising the real `SummaryUpdater` wiring without ever touching the real
/// `claude` CLI: a `SummaryUpdater` backed by this fake with no configured responses simply throws
/// `.missingStructuredOutput` on every call, which `SummaryUpdater` already treats as "skip this
/// update" (section 9) -- fast and hermetic by default, and tests that care about summary behavior
/// configure `responses`/`errors` explicitly.
private actor FakeSummaryLLM: LLMCompleting {
    private(set) var callCount = 0
    private(set) var receivedRequests: [LLMRequest] = []
    var responses: [String: String] = [:]
    var errors: [String: LLMClientError] = [:]

    func complete<T: Decodable & Sendable>(_ request: LLMRequest) async throws -> LLMResult<T> {
        let data = try resolveData(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(T.self, from: data)
        return LLMResult(value: value, usage: .zero)
    }

    /// `docs/design/05-watcher-runner.md` §5.1: not exercised by any test in this file, but required
    /// to satisfy `LLMCompleting`.
    func completeRaw(_ request: LLMRequest) async throws -> LLMResult<Data> {
        LLMResult(value: try resolveData(for: request), usage: .zero)
    }

    private func resolveData(for request: LLMRequest) throws -> Data {
        callCount += 1
        receivedRequests.append(request)
        let key = request.stubKey ?? ""
        if let error = errors[key] {
            throw error
        }
        guard let rawJSON = responses[key], let data = rawJSON.data(using: .utf8) else {
            throw LLMClientError.missingStructuredOutput(raw: "no fake response for stubKey=\(key)")
        }
        return data
    }

    func setResponse(_ json: String, for stubKey: String) {
        responses[stubKey] = json
        errors[stubKey] = nil
    }
}

/// Deterministic, network-free stand-in for `LLMCompleting` backing `RefinementQueue`
/// (`docs/design/03-refinement-batch.md`), the default `refinementQueueFactory` backing for
/// `makeViewModel(...)`. Separate from `FakeSummaryLLM` above (rather than shared) so refinement
/// tests can configure a response/error/delay without any risk of colliding with a `SummaryUpdater`
/// call sharing the same fake instance -- every `MeetingWorkspaceViewModel` already wires
/// `SummaryUpdater`/`RefinementQueue` to independent `LLMCompleting` instances in production too
/// (`Kikimi/ViewModels/MeetingWorkspaceViewModel+Factories.swift`'s two separate `LLMClient.shared`-
/// backed factories both happen to share the *client*, but never a test fake).
private actor FakeRefinementLLM: LLMCompleting {
    private(set) var callCount = 0
    var response: String?
    var error: LLMClientError?
    /// Injected delay before this call resolves (success or failure) -- lets a test assert
    /// `endMeeting()`'s `drain()` is truly fire-and-forget (§7) without burning a real multi-second
    /// wait on every other refinement test.
    var delay: Duration = .zero
    /// See `closeGate()`.
    private var isGated = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    func complete<T: Decodable & Sendable>(_ request: LLMRequest) async throws -> LLMResult<T> {
        let data = try await resolveData()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(T.self, from: data)
        return LLMResult(value: value, usage: .zero)
    }

    /// `docs/design/05-watcher-runner.md` §5.1: not exercised by any test in this file, but required
    /// to satisfy `LLMCompleting`.
    func completeRaw(_ request: LLMRequest) async throws -> LLMResult<Data> {
        LLMResult(value: try await resolveData(), usage: .zero)
    }

    /// Blocks every call until `openGate()` releases it.
    ///
    /// Exists so "did not await this" can be asserted without a stopwatch: a test can hold the
    /// refinement call open indefinitely and then check that the code under test returned anyway.
    /// The alternative -- a `setDelay` long enough to out-run the assertion's own ceiling -- measures
    /// machine speed rather than behaviour, and broke on CI in both directions (too tight a ceiling
    /// failed under load; a delay long enough to fix that then out-ran the `waitUntil` polls).
    func closeGate() {
        isGated = true
    }

    func openGate() {
        isGated = false
        let parked = gateWaiters
        gateWaiters = []
        for waiter in parked { waiter.resume() }
    }

    private func resolveData() async throws -> Data {
        callCount += 1
        if isGated {
            await withCheckedContinuation { gateWaiters.append($0) }
        }
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        if let error {
            throw error
        }
        guard let response, let data = response.data(using: .utf8) else {
            throw LLMClientError.missingStructuredOutput(raw: "no fake response configured")
        }
        return data
    }

    func setResponse(_ json: String) {
        response = json
        error = nil
    }

    func setError(_ error: LLMClientError) {
        self.error = error
    }

    func setDelay(_ delay: Duration) {
        self.delay = delay
    }
}

/// Deterministic stand-in for `AudioInputEnumerator` (`docs/design/10-audio-input-selection.md`
/// section 6.1's `inputEnumerator` DI point). Defaults to reporting one input device and zero
/// system-audio apps -- enough for `.default` `AudioInputSelection` to start recording without
/// tripping the "利用できるマイクがありません" guard (section 4 ③/section 8 failure mode #4), while
/// still letting tests override either list to exercise that guard or the resolution rule.
private struct FakeAudioInputEnumerator: AudioInputEnumerating {
    var devices: [AudioDeviceInfo] = [AudioDeviceInfo(uid: "fake-default-mic", name: "Fake Default Mic")]
    var apps: [AudioProcessInfo] = []
    /// `registeredSystemAudioApps()`'s return value (`docs/design/10-audio-input-selection.md`
    /// section 4 ②'s output-unfiltered basis for resolving a `bundleId` at recording start -- see
    /// `AudioInputEnumerator.registeredSystemAudioApps()`'s doc comment). `nil` (the default) falls
    /// back to `apps`, so every pre-existing call site (which only sets `apps`) keeps exercising the
    /// same list at both phases; tests that need the two lists to diverge (e.g. an app registered
    /// with CoreAudio but not yet producing output, so it's absent from `apps` but present here) pass
    /// this explicitly.
    var registeredApps: [AudioProcessInfo]?

    func inputDevices() -> [AudioDeviceInfo] { devices }
    func systemAudioProcesses() -> [AudioProcessInfo] { apps }
    func registeredSystemAudioApps() -> [AudioProcessInfo] { registeredApps ?? apps }
}

/// Deterministic, filesystem-free stand-in for `WikiExporter` (`docs/design/08-wiki-export.md`), the
/// default `wikiExporter` backing for `makeViewModel(...)` below. **Must** stay the default: unlike
/// every other collaborator's real production default (which either no-ops or only touches a
/// caller-provided temp directory), `MeetingWorkspaceViewModel`'s own `defaultWikiExporter()` reads
/// `AppConfig.shared` and resolves `ExportConfig.default.targetDir` to a real path under the user's
/// home directory *regardless* of which `AppConfig` instance is otherwise injected (see
/// `defaultWikiExporter()`'s doc comment) -- so every one of this file's ~30 `endMeeting()` calls
/// would otherwise actually attempt to write into `~/Documents/Kikimi/export/` on
/// whatever machine runs `swift test`. This fake just records what it was asked to export.
private actor FakeWikiExporter: WikiExporting {
    private(set) var exportCallCount = 0
    private(set) var exportedSessionIds: [String] = []
    private var error: Error?
    /// See `closeGate()`.
    private var isGated = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    func export(sessionHandle: SessionHandle) async throws {
        exportCallCount += 1
        exportedSessionIds.append(await sessionHandle.sessionId)
        if isGated {
            await withCheckedContinuation { gateWaiters.append($0) }
        }
        if let error {
            throw error
        }
    }

    func setError(_ error: Error) {
        self.error = error
    }

    /// Blocks every `export(sessionHandle:)` call until `openGate()` releases it -- same mechanism
    /// (and same rationale: no stopwatch, no machine-speed dependency) as `FakeRefinementLLM
    /// .closeGate()` above. Lets a test park `endMeeting()` mid-confirmation-processing and assert
    /// what the UI shows while it is parked. `endMeeting()` calls `export` unconditionally, so this
    /// is the one stage guaranteed to be reached regardless of how much transcript exists.
    func closeGate() {
        isGated = true
    }

    func openGate() {
        isGated = false
        let parked = gateWaiters
        gateWaiters = []
        for waiter in parked { waiter.resume() }
    }
}

// MARK: - MeetingWorkspaceViewModel (recording sequencing, section 6.1/12)

@Suite("MeetingWorkspaceViewModel")
@MainActor
struct MeetingWorkspaceViewModelTests {
    private func makeTemporaryDirectory(prefix: String = "MeetingWorkspaceViewModelTests") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A `SessionStore` rooted entirely under a fresh temp directory, including its default
    /// context/template/watcher-list source files (all deliberately missing, exercising the
    /// documented "fall back to empty/built-in default" path rather than touching any real
    /// `~/.config/kikimi` file), mirroring `SessionStoreIntegrationTests`'s DI pattern.
    private func makeStore(root: URL) -> SessionStore {
        SessionStore(
            sessionsRootDirectory: root.appendingPathComponent("sessions", isDirectory: true),
            defaultContextFileURL: root.appendingPathComponent("missing-context.md"),
            defaultSummaryTemplateFileURL: root.appendingPathComponent("missing-template.md"),
            defaultEnabledWatchersFileURL: root.appendingPathComponent("missing-enabled.yaml"),
            metaFlushInterval: 0.05
        )
    }

    /// - Parameters:
    ///   - inputEnumerator / appState: Injectable seams for `docs/design/10-audio-input-selection.md`
    ///     section 6.1. Defaulted so every pre-existing test (none of which cares about audio input
    ///     selection) keeps working unchanged: `FakeAudioInputEnumerator()`'s default one-device/
    ///     zero-app enumeration lets `.default` `AudioInputSelection` start recording without
    ///     tripping the "no mic available" guard, and each call gets its own fresh temp-directory
    ///     `AppState` so tests never touch the real `~/.local/state/kikimi/state.yaml` or leak state
    ///     between tests (same DI pattern as `MeetingWorkspaceWindowControllerTests`).
    /// - Parameter llm: Backs the default `summaryUpdaterFactory` (`docs/design/04-summary-updater.md`
    ///   section 7). Defaults to a fresh `FakeSummaryLLM` with no configured responses, so every
    ///   pre-existing test that doesn't care about summary behavior stays fast/hermetic (every LLM
    ///   call just skips per section 9's failure-mode table). Tests targeting `SummaryUpdater` wiring
    ///   construct their own `FakeSummaryLLM`, configure its responses, and pass it here.
    /// - Parameters:
    ///   - appConfig: `docs/design/13-speaker-diarization.md` section 7's DI seam. Each call gets its
    ///     own fresh temp-directory `AppConfig` (same rationale as `appState` below) -- defaults to
    ///     `DiarizationConfig.default` (`enabled: true`), so every pre-existing test exercises the
    ///     `diarizationCoordinatorFactory` wiring below rather than silently skipping it.
    ///   - diarizationCoordinatorFactory: Defaults to a fresh `FakeDiarizationCoordinator` per
    ///     recording segment, never the real `RealtimeDiarizationCoordinator`/`LSEENDDiarizationBackend`
    ///     (which would download a real CoreML model over the network on first use) -- see
    ///     `FakeDiarizationCoordinator`'s own doc comment.
    ///   - voiceprintStore: `docs/design/13-speaker-diarization.md` section 4.4/6.1's rename popover
    ///     DI seam. Each call gets its own fresh temp-file-backed `VoiceprintStore` (same rationale as
    ///     `appState`/`appConfig` above), so no test ever touches the real
    ///     `~/.local/state/kikimi/voiceprints.json`.
    ///   - voiceprintWavFallbackExtractorFactory: `docs/design/13-speaker-diarization.md` section 4.4's
    ///     "実装時の追記 2026-07-03" on-demand WAV fallback DI seam. Defaults to a fresh
    ///     `FakeVoiceprintWavFallbackExtractor` that returns `nil` (no fallback embedding found), never
    ///     the real `VoiceprintWavFallbackExtractor` (which would touch real `AVAudioFile`/WeSpeaker
    ///     CoreML) -- see that fake's own doc comment.
    ///   - refinementQueueFactory: `docs/design/03-refinement-batch.md` §3/§7's DI seam. Defaults to a
    ///     fresh, real `RefinementQueue` backed by `refinementLLM`/`refinementConfig` (never the real
    ///     `LLMClient.shared`/`claude` CLI) with `retryDelay: .zero` so a test exercising §5.2's retry
    ///     path never burns real wall-clock time. `batchSize`/`batchTimeoutMs` default large enough
    ///     that no pre-existing (refinement-agnostic) test ever accidentally cuts a batch on its own --
    ///     tests targeting refinement behavior call `flush()` explicitly instead.
    ///   - wikiExporter: `docs/design/08-wiki-export.md`'s `endMeeting()` DI seam. **Must** default to
    ///     a fresh `FakeWikiExporter()`, never the production `defaultWikiExporter()` -- see that
    ///     fake's own doc comment for why every pre-existing `endMeeting()` test would otherwise write
    ///     into the real `~/Documents/Kikimi/export/`.
    private func makeViewModel(
        handle: SessionHandle,
        store: SessionStore,
        capture: FakeAudioCapture,
        pipeline: FakeTranscriptPipeline,
        llm: LLMCompleting = FakeSummaryLLM(),
        summaryConfig: SummaryConfig = SummaryConfig(),
        inputEnumerator: AudioInputEnumerating = FakeAudioInputEnumerator(),
        appState: AppState = AppState(directory: FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingWorkspaceViewModelTests-appstate-\(UUID().uuidString)", isDirectory: true
        )),
        appConfig: AppConfig = AppConfig(directory: FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingWorkspaceViewModelTests-appconfig-\(UUID().uuidString)", isDirectory: true
        )),
        diarizationCoordinatorFactory: @escaping MeetingWorkspaceViewModel.DiarizationCoordinatorFactory = { _ in FakeDiarizationCoordinator() },
        voiceprintStore: VoiceprintStore = VoiceprintStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingWorkspaceViewModelTests-voiceprints-\(UUID().uuidString).json"
        )),
        voiceprintWavFallbackExtractorFactory: @escaping MeetingWorkspaceViewModel.VoiceprintWavFallbackExtractorFactory = { _ in
            FakeVoiceprintWavFallbackExtractor()
        },
        overrideEnrollmentExtractorFactory: @escaping MeetingWorkspaceViewModel.OverrideEnrollmentExtractorFactory = { _ in
            FakeOverrideEnrollmentExtractor()
        },
        refinementLLM: LLMCompleting = FakeSummaryLLM(),
        refinementConfig: RefinementConfig = RefinementConfig(model: "test-model", batchSize: 1_000, batchTimeoutMs: 60_000, contextSegments: 3, contextRefreshBatches: 10),
        refinementQueueFactory: MeetingWorkspaceViewModel.RefinementQueueFactory? = nil,
        wikiExporter: WikiExporting = FakeWikiExporter(),
        now: (@Sendable () -> Date)? = nil
    ) -> MeetingWorkspaceViewModel {
        // Frozen here, before any recording segment exists, so every `recordingButtonState` elapsed
        // -time derivation (`MeetingWorkspaceViewModel+RecordingInternals.swift`'s
        // `cumulativeElapsedSeconds(for:now:)`) is deterministic: a segment opened after this instant
        // is always "0 seconds in" no matter how much real time the suite's parallel load actually
        // burns between the two. Reading the real clock instead made every
        // `== .recording(elapsedSeconds: 0)` assertion below flaky, failing with `1` whenever a run
        // happened to cross a second boundary. Tests that want a *non*-zero elapsed time pass their
        // own `now`; the arithmetic itself is covered directly by the
        // `cumulativeElapsedSeconds`/`initialRecordingButtonState` tests, which feed it explicit dates.
        let frozenNow = Date()
        return MeetingWorkspaceViewModel(
            sessionHandle: handle,
            sessionStore: store,
            audioCaptureFactory: { _, _, _ in capture },
            transcriptPipelineFactory: { _, _ in pipeline },
            summaryUpdaterFactory: { sessionHandle in
                SummaryUpdater(sessionHandle: sessionHandle, llm: llm, config: summaryConfig)
            },
            refinementQueueFactory: refinementQueueFactory ?? { sessionHandle in
                RefinementQueue(sessionHandle: sessionHandle, llm: refinementLLM, config: refinementConfig, retryDelay: .zero)
            },
            inputEnumerator: inputEnumerator,
            appState: appState,
            appConfig: appConfig,
            diarizationCoordinatorFactory: diarizationCoordinatorFactory,
            voiceprintStore: voiceprintStore,
            voiceprintWavFallbackExtractorFactory: voiceprintWavFallbackExtractorFactory,
            overrideEnrollmentExtractorFactory: overrideEnrollmentExtractorFactory,
            wikiExporter: wikiExporter,
            now: now ?? { frozenNow }
        )
    }

    // MARK: init (synchronous construction contract)

    @Test("init is synchronous and immediately exposes sessionId/meta.id without awaiting hydration")
    func initExposesSessionIdSynchronously() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let handle = SessionHandle(directoryURL: sessionDirectory, meta: Self.baseMeta(id: "session-init"))

        // No `await` anywhere on this line: matches `WindowManager.openWorkspace(sessionId:)` and
        // `MeetingWorkspaceWindowController.init`, both of which construct this type synchronously
        // and read `sessionId`/`meta.title` back immediately.
        let viewModel = MeetingWorkspaceViewModel(sessionHandle: handle)

        #expect(viewModel.sessionId == "session-init")
        #expect(viewModel.meta.id == "session-init")
        #expect(viewModel.recordingButtonState == .startRecording)
        #expect(viewModel.activeTab == .prep)
        #expect(viewModel.meetingPaneMode == .both)
        // `docs/design/17-session-window-redesign.md` §4.4: `isDraft` mirrors `meta.state == .draft`
        // -- true here even before `hydrateFromSessionHandle()` replaces the placeholder `meta`,
        // since the placeholder itself is seeded with `state: .draft`.
        #expect(viewModel.isDraft == true)
    }

    // MARK: startRecording() success path

    @Test("startRecording() success path calls prepare()/start(), reloads meta.startedAt, and transitions to .recording")
    func startRecordingSuccessPath() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()

        #expect(viewModel.recordingButtonState == .recording(elapsedSeconds: 0))
        #expect(viewModel.meta.startedAt != nil)
        #expect(pipeline.prepareCallCount == 1)
        #expect(capture.startCallCount == 1)
        #expect(viewModel.banners.isEmpty)
        #expect(
            capture.delegate === pipeline,
            "startRecording() must wire capture.delegate = pipeline before start() (TranscriptPipeline's call-order contract step ④), or no captured buffer would ever reach the STT engines"
        )
        // `docs/design/17-session-window-redesign.md` §4.5: a successful start switches to the 会議
        // tab (Draft's dedicated screen is about to disappear in favor of the 3-tab layout) and
        // flips `isDraft` to false; `meetingPaneMode` is left at whatever it already was.
        #expect(viewModel.activeTab == .meeting)
        #expect(viewModel.isDraft == false)

        let storedRecordingSessionId = await store.recordingSessionId
        #expect(storedRecordingSessionId == created.id)
    }

    @Test("startRecording() leaves activeTab untouched when it fails (rollback to .draft)")
    func startRecordingFailureLeavesActiveTabUntouched() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        capture.startError = FakeError()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)
        viewModel.activeTab = .prep

        await viewModel.startRecording()

        #expect(viewModel.recordingButtonState == .startRecording)
        #expect(viewModel.activeTab == .prep)
        #expect(viewModel.isDraft == true)
    }

    @Test("startRecording() is a no-op when recordingButtonState is not .startRecording")
    func startRecordingNoOpWhenNotStartRecording() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()
        #expect(viewModel.recordingButtonState == .recording(elapsedSeconds: 0))

        // Calling it again while already `.recording` must not re-invoke beginRecording/prepare/start.
        await viewModel.startRecording()
        #expect(pipeline.prepareCallCount == 1)
        #expect(capture.startCallCount == 1)
    }

    // MARK: startRecording() audio input selection (docs/design/10-audio-input-selection.md section 6.2/9)

    @Test("startRecording() persists audioInputSelection to appState.lastAudioInput only once AudioCapture.start() succeeds")
    func startRecordingPersistsLastAudioInputOnlyOnSuccess() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let appState = AppState(directory: makeTemporaryDirectory(prefix: "MeetingWorkspaceViewModelTests-appstate"))
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline, appState: appState)

        // A non-default selection, so the persisted value is unambiguously traceable to this
        // recording's resolved selection rather than coincidentally matching `.default`.
        viewModel.audioInputSelection = AudioInputSelection(
            mic: MicSelection(enabled: true, deviceUid: nil),
            system: SystemAudioSelection(enabled: false, bundleId: nil)
        )

        #expect(appState.data.lastAudioInput == .default, "sanity: nothing has been persisted before startRecording() runs")

        await viewModel.startRecording()

        #expect(viewModel.recordingButtonState == .recording(elapsedSeconds: 0))
        #expect(appState.data.lastAudioInput == AudioInputSelection(
            mic: MicSelection(enabled: true, deviceUid: nil),
            system: SystemAudioSelection(enabled: false, bundleId: nil)
        ))
    }

    @Test("startRecording() does not persist lastAudioInput when AudioCapture.start() fails")
    func startRecordingDoesNotPersistLastAudioInputOnFailure() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        capture.startError = FakeError()
        let pipeline = FakeTranscriptPipeline()
        let appState = AppState(directory: makeTemporaryDirectory(prefix: "MeetingWorkspaceViewModelTests-appstate"))
        let previouslyPersisted = AudioInputSelection(
            mic: MicSelection(enabled: true, deviceUid: nil),
            system: SystemAudioSelection(enabled: false, bundleId: nil)
        )
        appState.update { $0.lastAudioInput = previouslyPersisted }
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline, appState: appState)

        await viewModel.startRecording()

        #expect(viewModel.recordingButtonState == .startRecording)
        #expect(
            appState.data.lastAudioInput == previouslyPersisted,
            "a failed start() must never overwrite the previously-persisted lastAudioInput (section 6.2's step-5 ordering)"
        )
    }

    @Test("startRecording() shows a banner and never calls beginRecording when both mic and system audio are disabled")
    func startRecordingBothSourcesDisabledGuard() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)
        viewModel.audioInputSelection = AudioInputSelection(
            mic: MicSelection(enabled: false, deviceUid: nil),
            system: SystemAudioSelection(enabled: false, bundleId: nil)
        )

        await viewModel.startRecording()

        #expect(viewModel.recordingButtonState == .startRecording)
        #expect(viewModel.banners.contains(where: { if case .recordingStartFailed = $0 { return true }; return false }))
        #expect(pipeline.prepareCallCount == 0, "prepare() must never be reached: the hasEnabledSource guard fires before beginRecording")
        #expect(capture.startCallCount == 0)
        let storedRecordingSessionId = await store.recordingSessionId
        #expect(storedRecordingSessionId == nil, "beginRecording() must never be called once the hasEnabledSource guard has fired")
    }

    @Test("startRecording() shows a 'no microphone available' banner and aborts when mic is enabled but zero devices exist")
    func startRecordingNoMicrophoneAvailableGuard() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(
            handle: handle,
            store: store,
            capture: capture,
            pipeline: pipeline,
            inputEnumerator: FakeAudioInputEnumerator(devices: [], apps: [])
        )

        await viewModel.startRecording()

        #expect(viewModel.recordingButtonState == .startRecording)
        #expect(viewModel.banners.contains(where: {
            if case .recordingStartFailed(let message) = $0 { return message == "利用できるマイクがありません" }
            return false
        }))
        #expect(pipeline.prepareCallCount == 0, "beginRecording()/prepare() must never be reached once the no-mic guard has fired")
        let storedRecordingSessionId = await store.recordingSessionId
        #expect(storedRecordingSessionId == nil)
    }

    // MARK: hydrateFromSessionHandle() audio input resolution (section 4 ①, section 6.1)

    @Test("hydration resolves a stale (disconnected) persisted mic deviceUid to nil, and leaves a stale system bundleId untouched")
    func hydrationResolvesStaleMicUidButNotSystemBundleId() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let appState = AppState(directory: makeTemporaryDirectory(prefix: "MeetingWorkspaceViewModelTests-appstate"))
        appState.update {
            $0.lastAudioInput = AudioInputSelection(
                mic: MicSelection(enabled: true, deviceUid: "unplugged-uid"),
                system: SystemAudioSelection(enabled: true, bundleId: "not.currently.running")
            )
        }

        let viewModel = makeViewModel(
            handle: handle,
            store: store,
            capture: FakeAudioCapture(),
            pipeline: FakeTranscriptPipeline(),
            inputEnumerator: FakeAudioInputEnumerator(devices: [AudioDeviceInfo(uid: "connected-uid", name: "Connected Mic")], apps: []),
            appState: appState
        )

        try await waitUntil { await viewModel.audioInputSelection != .default }

        #expect(viewModel.audioInputSelection.mic.deviceUid == nil, "phase ① must reset a disconnected mic UID to nil (section 4)")
        #expect(
            viewModel.audioInputSelection.system.bundleId == "not.currently.running",
            "phase ① must never validate the system bundle id (section 4: an app not yet producing audio is not \"gone\")"
        )
    }

    // MARK: startRecording() rollback (section 6.1 steps 2-5, section 11 failure modes #1/#2)

    @Test("startRecording() rolls back via cancelRecording (not endRecording) when TranscriptPipeline.prepare() fails")
    func startRecordingRollsBackOnPrepareFailure() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        pipeline.prepareError = FakeError()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()

        #expect(viewModel.recordingButtonState == .startRecording)
        #expect(viewModel.banners.contains(where: { if case .recordingStartFailed = $0 { return true }; return false }))
        #expect(capture.startCallCount == 0, "AudioCapture.start() must never be called once prepare() has already failed")

        // cancelRecording rewinds state to .draft with startedAt == nil; endRecording is never called.
        let refreshedMeta = await handle.meta
        #expect(refreshedMeta.state == .draft)
        #expect(refreshedMeta.startedAt == nil)
        let storedRecordingSessionId = await store.recordingSessionId
        #expect(storedRecordingSessionId == nil)
    }

    @Test("startRecording() rolls back via cancelRecording when AudioCapture.start() fails")
    func startRecordingRollsBackOnAudioCaptureFailure() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        capture.startError = FakeError()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()

        #expect(viewModel.recordingButtonState == .startRecording)
        #expect(viewModel.banners.contains(where: { if case .recordingStartFailed = $0 { return true }; return false }))
        #expect(pipeline.prepareCallCount == 1, "prepare() must still have been attempted before start() failed")

        let refreshedMeta = await handle.meta
        #expect(refreshedMeta.state == .draft)
        #expect(refreshedMeta.startedAt == nil)
    }

    @Test("startRecording() reverts to .startRecording (not .disabledOtherRecording) when another session is already recording")
    func startRecordingAnotherSessionRecordingRace() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        let otherSession = try await store.createDraftSession()
        try await store.beginRecording(otherSession.id)

        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()

        // Section 11 failure mode #4: reverts to .startRecording, not .disabledOtherRecording.
        #expect(viewModel.recordingButtonState == .startRecording)
        #expect(pipeline.prepareCallCount == 0, "prepare() must never be reached once beginRecording itself fails")
        #expect(viewModel.banners.contains(where: { if case .recordingStartFailed = $0 { return true }; return false }))
    }

    // MARK: pauseRecording() / resumeRecording() / endMeeting() / reopenRecording()
    // (kikimi.md 4 章 "「停止」と「終了」を分離する")

    @Test("pauseRecording() success path stops capture/pipeline exactly once and transitions to .paused, releasing exclusivity")
    func pauseRecordingSuccessPath() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()
        await viewModel.pauseRecording()

        #expect(capture.stopCallCount == 1)
        #expect(pipeline.stopAndDrainCallCount == 1)

        let refreshedMeta = await handle.meta
        // A paused session's `elapsedSeconds` comes from the closed segment's persisted
        // `meta.durationMs`, which `SessionStore.pauseRecording(_:)` derives from real wall-clock
        // time -- unlike the `.recording` cases above, `makeViewModel`'s frozen clock cannot pin it,
        // and asserting a literal `0` flaked whenever the suite's parallel load pushed this test past
        // a second boundary. Assert it mirrors the duration actually written to disk instead; the
        // seconds arithmetic itself is covered deterministically by
        // `MeetingWorkspaceViewModelElapsedTimeTests`.
        #expect(viewModel.recordingButtonState == .paused(elapsedSeconds: refreshedMeta.durationMs / 1_000))
        #expect(refreshedMeta.state == .paused)
        #expect(refreshedMeta.recordings.count == 1)
        #expect(refreshedMeta.recordings[0].endedAt != nil)
        // Pausing releases the single shared audio resource (kikimi.md 4 章): a *different* session
        // may now begin recording.
        let storedRecordingSessionId = await store.recordingSessionId
        #expect(storedRecordingSessionId == nil)
    }

    @Test("resumeRecording() opens a second recording segment and returns to .recording")
    func resumeRecordingSuccessPath() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()
        await viewModel.pauseRecording()
        await viewModel.resumeRecording()

        #expect(viewModel.recordingButtonState == .recording(elapsedSeconds: 0))
        #expect(pipeline.prepareCallCount == 2, "a fresh TranscriptPipeline is prepared for every recording segment")
        #expect(capture.startCallCount == 2, "a fresh AudioCapture is started for every recording segment")

        let refreshedMeta = await handle.meta
        #expect(refreshedMeta.state == .recording)
        #expect(refreshedMeta.recordings.count == 2)
        #expect(refreshedMeta.recordings[1].index == 1)
        let storedRecordingSessionId = await store.recordingSessionId
        #expect(storedRecordingSessionId == created.id)
    }

    @Test("endMeeting() from .recording stops capture/pipeline, closes the open segment, and transitions to .ended")
    func endMeetingFromRecordingSuccessPath() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()
        await viewModel.endMeeting()

        #expect(viewModel.recordingButtonState == .ended)
        #expect(capture.stopCallCount == 1)
        #expect(pipeline.stopAndDrainCallCount == 1)
        // `docs/design/17-session-window-redesign.md` §4.5: always surfaces the 会議 tab.
        #expect(viewModel.activeTab == .meeting)
        // Started at the default `.both`, so it's untouched (not `.transcript`) -- see the dedicated
        // pane-mode-promotion tests below for the narrowed-to-transcript-only case.
        #expect(viewModel.meetingPaneMode == .both)

        let refreshedMeta = await handle.meta
        #expect(refreshedMeta.state == .ended)
        #expect(refreshedMeta.endedAt != nil)
        #expect(refreshedMeta.recordings[0].endedAt != nil)
        let storedRecordingSessionId = await store.recordingSessionId
        #expect(storedRecordingSessionId == nil)
    }

    // MARK: Elapsed-time ticker vs. the .pausing/.ending transitional states (`docs/design/06-ui-panels.md` §6.1)

    @Test("endMeeting() holds .ending for the whole confirmation processing -- the 1-second elapsed ticker must not overwrite it back to .recording")
    func endMeetingHoldsEndingWhileConfirmationProcessingRuns() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let exporter = FakeWikiExporter()
        // Parks `endMeeting()` inside its `wikiExporter.export(...)` call (unconditionally reached, so
        // this doesn't depend on how much transcript the session has) for as long as this test needs.
        await exporter.closeGate()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline, wikiExporter: exporter)

        await viewModel.startRecording()
        #expect(viewModel.recordingButtonState == .recording(elapsedSeconds: 0))

        let ending = Task { await viewModel.endMeeting() }
        // Longer than `startElapsedTimer()`'s 1-second period, so at least one tick has had its
        // chance to fire while `endMeeting()` is parked. Before the fix, that tick reassigned
        // `.recording(elapsedSeconds:)` over `.ending`: "終了処理中…" vanished within a second, the
        // meeting clock kept climbing over time nothing was being recorded, and the 一時停止/会議終了
        // buttons came back mid-confirmation (a second `endMeeting()` was one click away).
        try await Task.sleep(for: .milliseconds(1_100))
        #expect(viewModel.recordingButtonState == .ending)

        await exporter.openGate()
        await ending.value
        #expect(viewModel.recordingButtonState == .ended)

        // And nothing revives the ticker afterwards either.
        try await Task.sleep(for: .milliseconds(1_100))
        #expect(viewModel.recordingButtonState == .ended)
    }

    @Test("the elapsed ticker stops writing as soon as recordingButtonState leaves .recording")
    func elapsedTickerStopsOnceStateLeavesRecording() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()
        // Simulates the transitional assignment `pauseRecording()`/`endMeeting()` make on their first
        // line, without running the rest of either -- this is the ticker's own guard under test, the
        // second half of the two-layer defense (the first being their eager `stopElapsedTimer()`).
        viewModel.recordingButtonState = .ending

        try await Task.sleep(for: .milliseconds(1_100))

        #expect(viewModel.recordingButtonState == .ending)
    }

    // MARK: endMeeting() Wiki export (`docs/design/08-wiki-export.md`)

    @Test("endMeeting() calls wikiExporter.export(sessionHandle:) at on_session_end, then again once refinementQueue.drain() completes (TC17)")
    func endMeetingCallsWikiExporterExactlyOnce() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let exporter = FakeWikiExporter()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline, wikiExporter: exporter)

        await viewModel.startRecording()
        await viewModel.endMeeting()

        // `docs/design/37-transcript-markdown-copy.md` §5.1 (TC17): the `on_session_end` export
        // above is synchronous, but the post-`drain()` re-export runs inside the detached,
        // fire-and-forget `Task` `endMeeting()` spins up right after -- poll instead of asserting
        // the count synchronously right after `endMeeting()` returns, since that `Task` isn't
        // awaited by `endMeeting()` itself.
        try await waitUntil { await exporter.exportCallCount == 2 }
        #expect(await exporter.exportedSessionIds == [created.id, created.id])
        // A pause alone (no `endMeeting()`) must never trigger `on_session_end`'s Wiki export
        // (kikimi.md 4 章 "一時停止... on_session_end は走らない").
        let secondCreated = try await store.createDraftSession()
        let secondHandle = try await store.openSession(secondCreated.id)
        let secondCapture = FakeAudioCapture()
        let secondPipeline = FakeTranscriptPipeline()
        let secondViewModel = makeViewModel(
            handle: secondHandle, store: store, capture: secondCapture, pipeline: secondPipeline, wikiExporter: exporter
        )
        await secondViewModel.startRecording()
        await secondViewModel.pauseRecording()
        #expect(await exporter.exportCallCount == 2, "pauseRecording() must not trigger the Wiki export")
    }

    @Test("endMeeting() still reaches .ended even when wikiExporter.export(sessionHandle:) throws")
    func endMeetingSurvivesWikiExporterFailure() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let exporter = FakeWikiExporter()
        await exporter.setError(FakeError())
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline, wikiExporter: exporter)

        await viewModel.startRecording()
        await viewModel.endMeeting() // must not throw/hang despite the Wiki export failure

        #expect(viewModel.recordingButtonState == .ended)
        let refreshedMeta = await handle.meta
        #expect(refreshedMeta.state == .ended)
        // `docs/design/37-transcript-markdown-copy.md` §5.1 (TC17): the post-`drain()` re-export
        // also fails (same fake), is also swallowed (best-effort, `.error` log only) -- poll for
        // it rather than asserting synchronously, since it runs in a detached, unawaited `Task`.
        try await waitUntil { await exporter.exportCallCount == 2 }
    }

    /// The behavioral point of TC17 itself (design 37 §5.1): the synchronous `on_session_end` export
    /// runs *before* `refinementQueue.flush()`, so a trailing under-batch segment is still unrefined
    /// at that point and gets written with `TranscriptMarkdownRenderer.rawFallbackMarker`. Without the
    /// post-`drain()` re-export this file's own `endMeetingCallsWikiExporterExactlyOnce`/
    /// `endMeetingSurvivesWikiExporterFailure` only pin the *call count* -- this test pins the actual
    /// content transition the design doc's TC17 row exists to fix (`*(raw)*` placeholder -> refined
    /// text), using a real `WikiExporter`/`TranscriptMarkdownSource` rooted at a temp export directory
    /// instead of `FakeWikiExporter` (which never renders anything).
    @Test("endMeeting()'s post-drain re-export replaces the *(raw)* placeholder the pre-drain export wrote for a trailing under-batch segment with its refined text (design 37 §5.1, TC17)")
    func endMeetingPostDrainReExportFoldsInTrailingRefinedText() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let exportTargetDir = makeTemporaryDirectory(prefix: "MeetingWorkspaceViewModelTests-export")
        defer { try? FileManager.default.removeItem(at: exportTargetDir) }
        let voiceprintsDir = makeTemporaryDirectory(prefix: "MeetingWorkspaceViewModelTests-voiceprints")
        defer { try? FileManager.default.removeItem(at: voiceprintsDir) }
        let exportConfig = ExportConfig(enabled: true, targetDir: exportTargetDir.path)
        let voiceprintStore = VoiceprintStore(fileURL: voiceprintsDir.appendingPathComponent("voiceprints.json"))
        let diarization = DiarizationConfig(
            enabled: false, selfName: "自分", stepMs: 500, variant: "callhome",
            minEnrollSpeechMs: 5_000, speakerMatchThreshold: 0.45, speakerMatchMargin: 0.05
        )
        let exporter = WikiExporter(
            config: exportConfig, source: TranscriptMarkdownSource(diarization: diarization, voiceprintStore: voiceprintStore)
        )

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let fakeLLM = FakeRefinementLLM()
        // Delayed so the pre-drain assertions below (read right after `endMeeting()` returns) can
        // never race the fire-and-forget `drain()`/re-export -- mirrors
        // `endMeetingDoesNotAwaitRefinementDrain`'s use of `setDelay(_:)` for the same reason.
        await fakeLLM.setDelay(.milliseconds(300))
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: capture, pipeline: pipeline, refinementLLM: fakeLLM, wikiExporter: exporter
        )

        await viewModel.startRecording()
        // `makeViewModel(...)`'s default `RefinementConfig.batchSize: 1_000` keeps this single
        // segment "pending" (never auto-flushed by batch size) until `endMeeting()`'s own
        // `refinementQueue.flush()` cuts it -- the exact "trailing under-batch remainder" TC17 exists
        // for.
        let segment = try await handle.appendTranscriptSegment(
            source: .mic, startMs: 0, endMs: 500, text: "生のテキスト", confidence: 0.9
        )
        pipeline.yield(segment)
        try await waitUntil { await viewModel.transcriptRows.first(where: { $0.id == segment.id })?.state == .refining }
        await fakeLLM.setResponse(#"{"segments":[{"id":"\#(segment.id)","refined_text":"整形済みテキスト"}]}"#)

        await viewModel.endMeeting()

        let meta = await handle.meta
        let exportedFileURL = exportTargetDir.appendingPathComponent(WikiExportRenderer.fileName(for: meta))
        let preDrainContent = try String(contentsOf: exportedFileURL, encoding: .utf8)
        #expect(
            preDrainContent.contains("生のテキスト\(TranscriptMarkdownRenderer.rawFallbackMarker)"),
            "the on_session_end export (before flush()/drain()) must still see this segment as unrefined raw text"
        )
        #expect(!preDrainContent.contains("整形済みテキスト"))

        // `docs/design/37-transcript-markdown-copy.md` §5.1: once `drain()` completes, the detached
        // `Task` re-exports and the file on disk must now show the refined text instead of the raw
        // placeholder -- this is the "trailing raw stuck forever" bug TC17 fixes.
        try await waitUntil(timeout: .seconds(5)) {
            (try? String(contentsOf: exportedFileURL, encoding: .utf8))?.contains("整形済みテキスト") == true
        }
        let postDrainContent = try String(contentsOf: exportedFileURL, encoding: .utf8)
        #expect(
            !postDrainContent.contains(TranscriptMarkdownRenderer.rawFallbackMarker),
            "once refined, the segment must no longer carry the *(raw)* fallback marker"
        )
    }

    /// Design 37 §5.1's own rationale for the re-export shape ("`Task` の中で... キャプチャするのは
    /// `Sendable` な `WikiExporting` と `SessionHandle` だけで、ViewModel は捕まえない") -- the fire-and-forget
    /// `Task` `endMeeting()` spins up must keep running to completion even once nothing else references
    /// the `MeetingWorkspaceViewModel` itself (mirrors `viewModelDeallocationReleasesDiarizationCoordinator`'s
    /// weak-reference pattern, but asserts the opposite outcome: this `Task`, unlike
    /// `diarizationTurnsTask`, is deliberately *not* cancelled by `deinit`).
    @Test("endMeeting()'s post-drain re-export Task keeps running to completion even after the ViewModel itself is deallocated")
    func endMeetingPostDrainReExportOutlivesViewModelDeallocation() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let exporter = FakeWikiExporter()
        let fakeLLM = FakeRefinementLLM()
        await fakeLLM.setResponse(#"{"segments":[]}"#)
        await fakeLLM.setDelay(.milliseconds(300))

        var viewModel: MeetingWorkspaceViewModel? = makeViewModel(
            handle: handle, store: store, capture: capture, pipeline: pipeline, refinementLLM: fakeLLM, wikiExporter: exporter
        )

        await viewModel?.startRecording()
        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)
        try await waitUntil { await viewModel?.transcriptRows.first(where: { $0.id == segment.id })?.state == .refining }

        await viewModel?.endMeeting()
        #expect(await exporter.exportCallCount == 1, "only the synchronous on_session_end export has run at this point")

        // Drop the only strong reference to the ViewModel right after `endMeeting()` returns -- the
        // fire-and-forget `Task` still awaiting `queue.drain()` (it captured `queue`/`exporter`/
        // `handle`/`logger`, never `self`) must not be torn down along with it.
        viewModel = nil

        try await waitUntil(timeout: .seconds(5)) { await exporter.exportCallCount == 2 }
        #expect(await exporter.exportedSessionIds == [created.id, created.id])
    }

    @Test("endMeeting() promotes meetingPaneMode from .transcript to .both, so the final summary is visible")
    func endMeetingPromotesTranscriptOnlyPaneModeToBoth() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()
        viewModel.meetingPaneMode = .transcript

        await viewModel.endMeeting()

        #expect(viewModel.activeTab == .meeting)
        #expect(viewModel.meetingPaneMode == .both)
    }

    @Test("endMeeting() leaves meetingPaneMode == .summary untouched")
    func endMeetingLeavesSummaryOnlyPaneModeUntouched() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()
        viewModel.meetingPaneMode = .summary

        await viewModel.endMeeting()

        #expect(viewModel.meetingPaneMode == .summary)
    }

    @Test("endMeeting() from .paused never touches capture/pipeline again and transitions to .ended")
    func endMeetingFromPausedSuccessPath() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()
        await viewModel.pauseRecording()
        #expect(capture.stopCallCount == 1)

        await viewModel.endMeeting()

        #expect(viewModel.recordingButtonState == .ended)
        #expect(capture.stopCallCount == 1, "already stopped by pauseRecording(); endMeeting() must not stop it again")
        #expect(pipeline.stopAndDrainCallCount == 1)

        let refreshedMeta = await handle.meta
        #expect(refreshedMeta.state == .ended)
    }

    @Test("reopenRecording() from .ended opens a new recording segment and returns to .recording")
    func reopenRecordingSuccessPath() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()
        await viewModel.endMeeting()
        #expect(viewModel.recordingButtonState == .ended)

        await viewModel.reopenRecording()

        #expect(viewModel.recordingButtonState == .recording(elapsedSeconds: 0))
        let refreshedMeta = await handle.meta
        #expect(refreshedMeta.state == .recording)
        #expect(refreshedMeta.endedAt == nil)
        #expect(refreshedMeta.recordings.count == 2)
    }

    @Test("pauseRecording()/endMeeting() are no-ops when recordingButtonState is .startRecording")
    func pauseAndEndMeetingNoOpWhenNotRecording() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.pauseRecording()
        #expect(viewModel.recordingButtonState == .startRecording)

        await viewModel.endMeeting()
        #expect(viewModel.recordingButtonState == .startRecording)

        #expect(capture.stopCallCount == 0)
        #expect(pipeline.stopAndDrainCallCount == 0)
    }

    // MARK: windowMode / onMeetingEnded (`docs/design/18-recording-window-stow-and-compact.md` §3.4/§5.4/R6)
    //
    // The gating decision of whether `onMeetingEnded` firing should actually *reveal* a window
    // (§5.1's "しまってある or コンパクト中のときだけ", excluding the close-confirmation "終了して閉じる"
    // path) belongs entirely to whoever wires the closure -- `MeetingWorkspaceWindowController.init`,
    // which unconditionally forwards to `WindowManager.shared.showWorkspaceWindow(sessionId:)` (§5.1).
    // That wiring is deliberately **not** exercised from this file: `WindowManager` is a hard-wired
    // singleton bound to the real `SessionStore`/`AppState` with no injectable seam (see
    // `WindowManagerTests.swift`'s own doc comment, and `MeetingWorkspaceWindowControllerTests.swift`'s
    // explicit exclusion of `windowWillClose`'s equivalent `WindowManager.shared` interaction) --
    // driving it here would either do nothing observable (the guard in `showWorkspaceWindow` silently
    // no-ops for an unregistered test session id) or risk touching the developer's actual
    // `~/.local/state/kikimi/state.yaml`. The tests below instead cover exactly what this view model
    // itself is responsible for (§5.4): unconditionally resetting `windowMode` and unconditionally
    // notifying `onMeetingEnded`, regardless of what (if anything) is wired to it.

    @Test("endMeeting() unconditionally resets windowMode to .normal, even from .compact")
    func endMeetingResetsWindowModeToNormal() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()
        viewModel.windowMode = .compact
        #expect(viewModel.windowMode == .compact)

        await viewModel.endMeeting()

        #expect(viewModel.windowMode == .normal)
    }

    @Test("endMeeting() calls onMeetingEnded exactly once with this session's id, when wired")
    func endMeetingNotifiesOnMeetingEndedWithSessionId() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        var notifiedSessionIds: [String] = []
        viewModel.onMeetingEnded = { sessionId in notifiedSessionIds.append(sessionId) }

        await viewModel.startRecording()
        await viewModel.endMeeting()

        #expect(notifiedSessionIds == [created.id])
    }

    @Test("endMeeting() calls onMeetingEnded from .paused the same way it does from .recording")
    func endMeetingFromPausedNotifiesOnMeetingEnded() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        var notifiedSessionIds: [String] = []
        viewModel.onMeetingEnded = { sessionId in notifiedSessionIds.append(sessionId) }

        await viewModel.startRecording()
        await viewModel.pauseRecording()
        await viewModel.endMeeting()

        #expect(notifiedSessionIds == [created.id])
    }

    @Test("endMeeting() with onMeetingEnded left unwired (nil, the default) completes with zero crashes/side effects")
    func endMeetingWithUnwiredOnMeetingEndedHasNoSideEffects() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)
        // `onMeetingEnded` is left at its default (nil) -- mirrors every pre-existing `endMeeting()`
        // test in this file, none of which wire it.

        await viewModel.startRecording()
        await viewModel.endMeeting() // must not crash despite the unwired closure

        #expect(viewModel.recordingButtonState == .ended)
        #expect(viewModel.windowMode == .normal)
    }

    // MARK: Live transcript segments (section 6.3)

    @Test("liveSegments delivered during recording are inserted into transcriptRows in start_ms order")
    func liveSegmentsUpdateTranscriptRowsInOrder() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()

        // Yielded out of start_ms order; TranscriptRowList.inserted(_:into:) is responsible for the
        // eventual sort order (already unit-tested in isolation by TranscriptRowListTests).
        pipeline.yield(Self.segment(id: "seg_00002", startMs: 2_000))
        pipeline.yield(Self.segment(id: "seg_00001", startMs: 1_000))

        try await waitUntil { await viewModel.transcriptRows.count == 2 }

        #expect(viewModel.transcriptRows.map(\.id) == ["seg_00001", "seg_00002"])

        await viewModel.endMeeting()
    }

    // MARK: volatileTranscripts subscription (docs/design/11-streaming-stt.md section 3.6)

    @Test("volatileTranscripts delivered during recording are mirrored into mic/systemVolatileText, source-tagged independently")
    func volatileTranscriptsUpdateSourceTaggedProperties() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()

        pipeline.yieldVolatile(SttVolatileTranscript(source: .mic, text: "こんに"))
        pipeline.yieldVolatile(SttVolatileTranscript(source: .system, text: "了解"))

        try await waitUntil { await viewModel.micVolatileText == "こんに" }
        try await waitUntil { await viewModel.systemVolatileText == "了解" }

        // Each source's latest value is tracked independently; a mic update never clobbers system's.
        pipeline.yieldVolatile(SttVolatileTranscript(source: .mic, text: "こんにちは"))
        try await waitUntil { await viewModel.micVolatileText == "こんにちは" }
        #expect(viewModel.systemVolatileText == "了解")

        // An empty-text value is the pipeline's own "clear" signal (SttVolatileTranscript's contract),
        // mirrored verbatim with no extra logic on the view model's side.
        pipeline.yieldVolatile(SttVolatileTranscript(source: .mic, text: ""))
        try await waitUntil { await viewModel.micVolatileText == "" }

        await viewModel.endMeeting()
    }

    @Test("confirmed-but-not-yet-appended text is held in mic/systemConfirmingText until that source's row arrives")
    func confirmingTextBridgesTheRedecodeGap() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()

        pipeline.yieldVolatile(SttVolatileTranscript(source: .mic, text: "こんにちは"))
        try await waitUntil { await viewModel.micVolatileText == "こんにちは" }

        // Confirmation empties the pending text, but the row is still being re-decoded -- the text
        // has to stay on screen, now as confirming text rather than volatile text.
        pipeline.yieldVolatile(SttVolatileTranscript(source: .mic, text: "", confirming: "こんにちは。"))
        try await waitUntil { await viewModel.micConfirmingText == "こんにちは。" }
        #expect(viewModel.micVolatileText.isEmpty)
        // Source-tagged: a mic confirmation leaves system's own buffer alone.
        #expect(viewModel.systemConfirmingText.isEmpty)

        // A second window can confirm while the first is still in flight; both must be shown.
        pipeline.yieldVolatile(SttVolatileTranscript(source: .mic, text: "", confirming: "よろしく。"))
        try await waitUntil { await viewModel.micConfirmingText == "こんにちは。よろしく。" }

        // The row's arrival is what releases the buffer -- that text is now a real row.
        pipeline.yield(Self.segment(id: "seg_00001", startMs: 0))
        try await waitUntil { await viewModel.micConfirmingText.isEmpty }
        #expect(viewModel.transcriptRows.map(\.id) == ["seg_00001"])

        await viewModel.endMeeting()
    }

    @Test("a system row arriving never clears mic's confirming buffer (and vice versa)")
    func confirmingTextIsClearedPerSource() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()

        pipeline.yieldVolatile(SttVolatileTranscript(source: .mic, text: "", confirming: "マイクの発話。"))
        pipeline.yieldVolatile(SttVolatileTranscript(source: .system, text: "", confirming: "システムの発話。"))
        try await waitUntil { await viewModel.micConfirmingText == "マイクの発話。" }
        try await waitUntil { await viewModel.systemConfirmingText == "システムの発話。" }

        pipeline.yield(Self.systemSegment(id: "seg_00001", startMs: 0))
        try await waitUntil { await viewModel.systemConfirmingText.isEmpty }
        // Mic's own segment hasn't finished re-decoding yet, so its text must still be on screen.
        #expect(viewModel.micConfirmingText == "マイクの発話。")

        await viewModel.endMeeting()
    }

    @Test("pauseRecording() clears micVolatileText/systemVolatileText even if the pipeline never sent a clear value")
    func pauseRecordingClearsVolatileText() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline)

        await viewModel.startRecording()

        pipeline.yieldVolatile(SttVolatileTranscript(source: .mic, text: "まだ確定していない発話"))
        try await waitUntil { await viewModel.micVolatileText == "まだ確定していない発話" }
        // Held text is in the same position: there is no pipeline left to deliver the row that would
        // normally release it, so pausing has to drop it too.
        pipeline.yieldVolatile(SttVolatileTranscript(source: .system, text: "", confirming: "確定したが行が未着"))
        try await waitUntil { await viewModel.systemConfirmingText == "確定したが行が未着" }

        await viewModel.pauseRecording()

        #expect(viewModel.micVolatileText.isEmpty)
        #expect(viewModel.systemVolatileText.isEmpty)
        #expect(viewModel.micConfirmingText.isEmpty)
        #expect(viewModel.systemConfirmingText.isEmpty)
    }

    // MARK: onAppear() transcript backfill (section 6.3)

    @Test("onAppear() backfills transcriptRows from readTranscriptSegments(), sorted by start_ms")
    func onAppearBackfillsTranscriptRows() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        try await handle.appendTranscriptSegment(source: .system, startMs: 2_000, endMs: 2_500, text: "second", confidence: 0.9)
        try await handle.appendTranscriptSegment(source: .mic, startMs: 1_000, endMs: 1_500, text: "first", confidence: 0.9)

        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline())

        await viewModel.onAppear()
        defer { viewModel.onDisappear() }

        #expect(viewModel.transcriptRows.map(\.rawText) == ["first", "second"])
        #expect(viewModel.transcriptRows.allSatisfy { $0.state == .raw })
    }

    // MARK: Prep tab

    @Test("saveContext(_:) updates contextText immediately and persists to context.md")
    func saveContextPersists() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline())

        await viewModel.saveContext("新しいコンテキスト")

        #expect(viewModel.contextText == "新しいコンテキスト")
        #expect(await handle.readContext() == "新しいコンテキスト")
    }

    @Test("saveSummaryTemplate(_:) updates summaryTemplateText immediately and persists to summary_template.md")
    func saveSummaryTemplatePersists() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline())

        await viewModel.saveSummaryTemplate("# 新テンプレート")

        #expect(viewModel.summaryTemplateText == "# 新テンプレート")
        #expect(await handle.readSummaryTemplate() == "# 新テンプレート")
    }

    // MARK: Title

    @Test("renameTitle(_:) persists the new title and fixes titleAutoGenerated to false")
    func renameTitlePersists() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        #expect(created.titleAutoGenerated) // sanity: starts out auto-generated
        let handle = try await store.openSession(created.id)
        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline())

        await viewModel.renameTitle("デイリースクラム")

        #expect(viewModel.meta.title == "デイリースクラム")
        #expect(viewModel.meta.titleAutoGenerated == false)
        let refreshedMeta = await handle.meta
        #expect(refreshedMeta.title == "デイリースクラム")
        #expect(refreshedMeta.titleAutoGenerated == false)
    }

    // MARK: Summary wiring (`docs/design/04-summary-updater.md` section 7)

    private let patchJSONWithTitle = """
    {"title":"新タイトル","participants_add":null,"overview":"概要です","decisions_add":null,"action_items":null}
    """
    private let finalTitleJSON = """
    {"title":"最終タイトル案"}
    """

    @Test("confirmed live segments call noteSegmentAppended(), triggering an automatic summary update once the threshold is reached")
    func liveSegmentsTriggerSummaryUpdate() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let llm = FakeSummaryLLM()
        await llm.setResponse(patchJSONWithTitle, for: "summary_patch")
        // A 1-segment threshold makes the very next live segment trigger an update deterministically,
        // without waiting on the (much slower) 180-second time-based trigger.
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: capture, pipeline: pipeline,
            llm: llm, summaryConfig: SummaryConfig(updateTriggerSegments: 1)
        )

        await viewModel.startRecording()
        // `noteSegmentAppended()` only fires off `viewModel.summaryUpdater`'s trigger bookkeeping --
        // `SummaryUpdater` itself reads segments back from `transcript.jsonl`, so the segment must
        // actually be persisted via `appendTranscriptSegment(...)` (mirroring what the real
        // `TranscriptPipeline` does before ever yielding a `liveSegments` value), not merely yielded
        // into the fake pipeline's stream.
        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)

        try await waitUntil { await viewModel.summaryMarkdown != nil }

        #expect(viewModel.summaryMarkdown?.joined.contains("概要です") == true)
        // The automatic-title once-only reflection (kikimi.md 8 章 §3.1) also lands on `meta` via the
        // `metaChanged` event -- this is the same `SummaryUpdateEvent` push this test is really
        // exercising, so assert it landed too.
        try await waitUntil { await viewModel.meta.title == "新タイトル" }

        await viewModel.endMeeting()
    }

    // MARK: summaryHasUnseenUpdate (`docs/design/17-session-window-redesign.md` §4.4/§4.5)

    @Test("a summary update while the Summary pane isn't visible (準備 tab) sets summaryHasUnseenUpdate")
    func summaryUpdateWhilePrepTabSetsUnseenFlag() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let llm = FakeSummaryLLM()
        await llm.setResponse(patchJSONWithTitle, for: "summary_patch")
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: capture, pipeline: pipeline,
            llm: llm, summaryConfig: SummaryConfig(updateTriggerSegments: 1)
        )

        await viewModel.startRecording()
        // Away from the 会議 tab entirely -- `startRecording()` itself always switches to `.meeting`
        // (see `startRecordingSuccessPath` above), so this simulates the user having since navigated
        // to 準備.
        viewModel.activeTab = .prep
        #expect(viewModel.summaryHasUnseenUpdate == false)

        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)

        try await waitUntil { await viewModel.summaryMarkdown != nil }
        #expect(viewModel.summaryHasUnseenUpdate == true)

        await viewModel.endMeeting()
    }

    @Test("a summary update while meetingPaneMode == .transcript sets summaryHasUnseenUpdate, even on the 会議 tab")
    func summaryUpdateWhileTranscriptOnlyPaneModeSetsUnseenFlag() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let llm = FakeSummaryLLM()
        await llm.setResponse(patchJSONWithTitle, for: "summary_patch")
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: capture, pipeline: pipeline,
            llm: llm, summaryConfig: SummaryConfig(updateTriggerSegments: 1)
        )

        await viewModel.startRecording()
        viewModel.meetingPaneMode = .transcript

        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)

        try await waitUntil { await viewModel.summaryMarkdown != nil }
        #expect(viewModel.summaryHasUnseenUpdate == true)

        await viewModel.endMeeting()
    }

    @Test("a summary update while the Summary pane is visible (.both) never sets summaryHasUnseenUpdate")
    func summaryUpdateWhilePaneVisibleDoesNotSetUnseenFlag() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let llm = FakeSummaryLLM()
        await llm.setResponse(patchJSONWithTitle, for: "summary_patch")
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: capture, pipeline: pipeline,
            llm: llm, summaryConfig: SummaryConfig(updateTriggerSegments: 1)
        )

        // `startRecording()` already lands on `.meeting`/`.both` (the defaults), so the Summary pane
        // is visible for the whole test.
        await viewModel.startRecording()

        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)

        try await waitUntil { await viewModel.summaryMarkdown != nil }
        #expect(viewModel.summaryHasUnseenUpdate == false)

        await viewModel.endMeeting()
    }

    @Test("switching to a visible Summary pane clears a pending summaryHasUnseenUpdate")
    func switchingToVisiblePaneClearsUnseenFlag() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let llm = FakeSummaryLLM()
        await llm.setResponse(patchJSONWithTitle, for: "summary_patch")
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: capture, pipeline: pipeline,
            llm: llm, summaryConfig: SummaryConfig(updateTriggerSegments: 1)
        )

        await viewModel.startRecording()
        viewModel.activeTab = .prep

        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)
        try await waitUntil { await viewModel.summaryHasUnseenUpdate == true }

        // Switching back to the 会議 tab (still `.both`, the pane-mode default) makes the Summary
        // pane visible again -- `updateSummaryUnseenVisibility()` (driven by `activeTab`'s `didSet`)
        // must clear the flag.
        viewModel.activeTab = .meeting

        #expect(viewModel.summaryHasUnseenUpdate == false)

        await viewModel.endMeeting()
    }

    @Test("narrowing meetingPaneMode away from .transcript clears a pending summaryHasUnseenUpdate")
    func changingPaneModeAwayFromTranscriptClearsUnseenFlag() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let llm = FakeSummaryLLM()
        await llm.setResponse(patchJSONWithTitle, for: "summary_patch")
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: capture, pipeline: pipeline,
            llm: llm, summaryConfig: SummaryConfig(updateTriggerSegments: 1)
        )

        await viewModel.startRecording()
        viewModel.meetingPaneMode = .transcript

        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)
        try await waitUntil { await viewModel.summaryHasUnseenUpdate == true }

        // `updateSummaryUnseenVisibility()` (driven by `meetingPaneMode`'s `didSet`) must clear the
        // flag the moment the pane mode itself widens back to `.both`.
        viewModel.meetingPaneMode = .both

        #expect(viewModel.summaryHasUnseenUpdate == false)

        await viewModel.endMeeting()
    }

    @Test("onAppear() backfill never calls noteSegmentAppended() (no double count for pre-existing segments)")
    func onAppearBackfillDoesNotCountTowardSummaryTrigger() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "pre-existing", confidence: 0.9)

        let llm = FakeSummaryLLM()
        await llm.setResponse(patchJSONWithTitle, for: "summary_patch")
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            llm: llm, summaryConfig: SummaryConfig(updateTriggerSegments: 1)
        )

        await viewModel.onAppear()
        defer { viewModel.onDisappear() }

        // Backfilled into transcriptRows, but no SummaryUpdater exists yet (Draft, not Recording) and
        // no update was triggered by the backfill.
        #expect(viewModel.transcriptRows.count == 1)
        #expect(viewModel.summaryMarkdown == nil)
        #expect(await llm.callCount == 0)
    }

    @Test("reopening a Paused session hydrates summaryMarkdown from the on-disk summary.md, without ever starting recording or the SummaryUpdater")
    func reopeningPausedSessionHydratesSummaryMarkdownFromDisk() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let llm = FakeSummaryLLM()
        await llm.setResponse(patchJSONWithTitle, for: "summary_patch")
        let firstViewModel = makeViewModel(
            handle: handle, store: store, capture: capture, pipeline: pipeline,
            llm: llm, summaryConfig: SummaryConfig(updateTriggerSegments: 1)
        )

        await firstViewModel.startRecording()
        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)
        try await waitUntil { await firstViewModel.summaryMarkdown != nil }
        await firstViewModel.pauseRecording()

        // A brand-new ViewModel instance for the same (now Paused) session -- e.g. the Session List
        // reopening it in a new window -- must show the already-rendered summary.md immediately, not
        // only once `startSummaryUpdaterIfNeeded()` runs (which only happens on a subsequent
        // startRecording()/resumeRecording()/reopenRecording() call). `hydrateFromSessionHandle()` runs
        // unconditionally from `init`, so no `onAppear()`/recording call is needed here at all.
        let reopenedHandle = try await store.openSession(created.id)
        let reopenedViewModel = makeViewModel(
            handle: reopenedHandle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(), llm: llm
        )

        try await waitUntil { await reopenedViewModel.summaryMarkdown != nil }
        #expect(reopenedViewModel.summaryMarkdown?.joined.contains("概要です") == true)
        // Never started recording on the reopened instance, so no SummaryUpdater was ever created --
        // this is purely `hydrateFromSessionHandle()`'s disk read, not a live update.
        #expect(reopenedViewModel.summaryUpdater == nil)
    }

    @Test("pauseRecording() flushes a final incremental update (.pauseFlush) before tearing down the updater")
    func pauseRecordingFlushesSummaryUpdater() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let llm = FakeSummaryLLM()
        await llm.setResponse(patchJSONWithTitle, for: "summary_patch")
        // A high threshold that's never reached by count/time alone, so the update can only have
        // happened via pauseRecording()'s explicit `.pauseFlush` call.
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: capture, pipeline: pipeline,
            llm: llm, summaryConfig: SummaryConfig(updateTriggerSegments: 999, updateTriggerSeconds: 999)
        )

        await viewModel.startRecording()
        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)
        try await waitUntil { await viewModel.transcriptRows.count == 1 }

        await viewModel.pauseRecording()

        #expect(viewModel.summaryMarkdown?.joined.contains("概要です") == true)
        #expect(await llm.callCount == 1)
    }

    @Test("endMeeting() from .recording flushes, generates a final title proposal once, then tears down the updater")
    func endMeetingFromRecordingGeneratesFinalTitleProposal() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let llm = FakeSummaryLLM()
        await llm.setResponse(patchJSONWithTitle, for: "summary_patch")
        await llm.setResponse(finalTitleJSON, for: "final_title")
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: capture, pipeline: pipeline,
            llm: llm, summaryConfig: SummaryConfig(updateTriggerSegments: 1)
        )

        await viewModel.startRecording()
        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)
        // Let the segment-threshold auto-update land first (and auto-adopt the once-only title), so
        // the final-title call below exercises the *second* proposal path (badge-only, section 3.1).
        try await waitUntil { await viewModel.meta.title == "新タイトル" }

        await viewModel.endMeeting()

        #expect(viewModel.recordingButtonState == .ended)
        #expect(viewModel.meta.titleProposal == "最終タイトル案")
        // Title itself is untouched by the final-title path (section 3.4: proposal only, never
        // auto-reflected) -- still the once-only auto-reflected title from the earlier update.
        #expect(viewModel.meta.title == "新タイトル")
    }

    @Test("endMeeting() from .paused (updater already torn down) still generates a final title proposal via a transient updater")
    func endMeetingFromPausedGeneratesFinalTitleProposal() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let llm = FakeSummaryLLM()
        await llm.setResponse(finalTitleJSON, for: "final_title")
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline, llm: llm)

        await viewModel.startRecording()
        await viewModel.pauseRecording()

        await viewModel.endMeeting()

        #expect(viewModel.recordingButtonState == .ended)
        #expect(viewModel.meta.titleProposal == "最終タイトル案")
    }

    // MARK: endMeeting() session-end final pass
    // (`docs/design/summary-quality-topics-and-final-pass.md` §7.5/§7.6)

    /// The session-end final pass's `SummaryFinalRevision` response (`SummaryJSONSchema
    /// .finalRevisionSchemaJSON`'s shape). Distinct markers from `patchJSONWithTitle`/
    /// `patchJSONWithDecisionForFinalPass` below so a test can tell whether the *incremental* patch's
    /// content or the *final pass*'s wholesale-replacement content ended up in `summary.md`.
    private let finalRevisionJSON = """
    {
      "overview": "最終版の概要です",
      "decisions": [{"text": "最終決定", "source_seg_ids": ["seg_00000"]}],
      "action_items": [
        {"task": "最終タスク", "assignee": "田中", "due": null, "status": "open", "source_seg_ids": ["seg_00000"]}
      ]
    }
    """
    /// Same title as `patchJSONWithTitle` but also seeds a decision, so the final-pass test below can
    /// prove the pre-final-pass decision is gone (wholesale replacement, not append) once the final
    /// pass has run.
    private let patchJSONWithDecisionForFinalPass = """
    {"title":"新タイトル","participants_add":null,"overview":"初期概要","decisions_add":[{"id":"dc_001","text":"初期決定","source_seg_ids":["seg_00000"]}],"action_items":null}
    """

    @Test("endMeeting() from .recording runs the session-end final pass, wholesale-replacing overview/decisions/action_items in summary.md ahead of the final title call")
    func endMeetingFromRecordingRunsFinalPass() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let llm = FakeSummaryLLM()
        await llm.setResponse(patchJSONWithDecisionForFinalPass, for: "summary_patch")
        await llm.setResponse(finalRevisionJSON, for: "summary_final")
        await llm.setResponse(finalTitleJSON, for: "final_title")
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: capture, pipeline: pipeline,
            llm: llm, summaryConfig: SummaryConfig(updateTriggerSegments: 1)
        )

        await viewModel.startRecording()
        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)
        // Let the incremental patch land first, so the assertions below can tell its content apart
        // from the final pass's wholesale replacement.
        try await waitUntil { await viewModel.summaryMarkdown?.joined.contains("初期決定") == true }

        await viewModel.endMeeting()

        #expect(viewModel.recordingButtonState == .ended)
        let markdown = try #require(viewModel.summaryMarkdown).joined
        #expect(markdown.contains("最終版の概要です"))
        #expect(markdown.contains("最終決定"))
        #expect(markdown.contains("最終タスク"))
        // §7.3: wholesale replacement, not an append -- the pre-final-pass overview/decision must be gone.
        #expect(!markdown.contains("初期概要"))
        #expect(!markdown.contains("初期決定"))

        let state = try #require(try await handle.readJSON(.summaryState, as: SummaryState.self))
        #expect(state.decisions == [SummaryState.Decision(id: "dc_001", text: "最終決定", sourceSegIds: ["seg_00000"])])
        #expect(state.actionItems.map(\.id) == ["ai_001"])
        #expect(state.actionItems.first?.task == "最終タスク")
        // §7.6: final pass runs ahead of the final-title call, whose proposal is generated from this
        // already-improved state.
        #expect(viewModel.meta.titleProposal == "最終タイトル案")
    }

    @Test("endMeeting() from .paused (updater already torn down) still runs the session-end final pass via a transient updater")
    func endMeetingFromPausedRunsFinalPass() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let llm = FakeSummaryLLM()
        await llm.setResponse(patchJSONWithDecisionForFinalPass, for: "summary_patch")
        await llm.setResponse(finalRevisionJSON, for: "summary_final")
        await llm.setResponse(finalTitleJSON, for: "final_title")
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: capture, pipeline: pipeline,
            llm: llm, summaryConfig: SummaryConfig(updateTriggerSegments: 1)
        )

        await viewModel.startRecording()
        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)
        try await waitUntil { await viewModel.summaryMarkdown?.joined.contains("初期決定") == true }

        // Recording -> Paused tears down the live updater; `endMeeting()` must spin up a transient
        // one that still runs the final pass (`docs/design/summary-quality-topics-and-final-pass.md`
        // §7.6's "Paused から Ended" branch).
        await viewModel.pauseRecording()
        await viewModel.endMeeting()

        #expect(viewModel.recordingButtonState == .ended)
        // The transient updater's events are never subscribed to, so read summary.md straight from
        // disk (mirrors `regenerateSummary()`'s own re-read-from-disk shape for the transient case).
        let markdown = try #require(try await handle.readText(.summaryMarkdown))
        #expect(markdown.contains("最終版の概要です"))
        #expect(markdown.contains("最終決定"))
        #expect(!markdown.contains("初期決定"))

        let state = try #require(try await handle.readJSON(.summaryState, as: SummaryState.self))
        #expect(state.decisions == [SummaryState.Decision(id: "dc_001", text: "最終決定", sourceSegIds: ["seg_00000"])])
    }

    @Test("adoptTitleProposal() replaces meta.title with the pending proposal and clears it, keeping titleAutoGenerated true")
    func adoptTitleProposalReplacesTitle() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        try await handle.updateMeta { meta in
            meta.title = "旧タイトル"
            meta.titleAutoNamedOnce = true
            meta.titleProposal = "新提案タイトル"
        }
        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline())
        await viewModel.onAppear()
        defer { viewModel.onDisappear() }
        try await waitUntil { await viewModel.meta.titleProposal == "新提案タイトル" }

        await viewModel.adoptTitleProposal()

        #expect(viewModel.meta.title == "新提案タイトル")
        #expect(viewModel.meta.titleProposal == nil)
        #expect(viewModel.meta.titleAutoGenerated == true)
        let refreshedMeta = await handle.meta
        #expect(refreshedMeta.title == "新提案タイトル")
        #expect(refreshedMeta.titleProposal == nil)
    }

    @Test("requestSummaryUpdateNow() is a silent no-op when no SummaryUpdater is live (not Recording)")
    func requestSummaryUpdateNowNoOpWhenNotRecording() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let llm = FakeSummaryLLM()
        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(), llm: llm)

        await viewModel.requestSummaryUpdateNow() // Must not hang or crash.

        #expect(await llm.callCount == 0)
    }

    @Test("regenerateSummary() works after Ended by spinning up a transient updater, and refreshes summaryMarkdown/meta")
    func regenerateSummaryAfterEnded() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let llm = FakeSummaryLLM()
        await llm.setResponse(patchJSONWithTitle, for: "summary_patch")
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline, llm: llm)

        await viewModel.startRecording()
        await viewModel.endMeeting()
        #expect(viewModel.recordingButtonState == .ended)

        await viewModel.regenerateSummary()

        #expect(viewModel.summaryMarkdown?.joined.contains("概要です") == true)
        #expect(try await handle.readText(.summaryMarkdown) != nil)
        // `docs/design/47-summary-split-pane.md` §2.1: this used to re-read the rendered `summary.md`,
        // which can only ever produce a single pane -- and on an Ended session, with the updater torn
        // down and no `events` left to correct it, that collapse would be permanent.
        #expect(viewModel.summaryMarkdown?.topics != nil)
    }

    // MARK: Manual model override (`docs/design/44-llm-model-config.md` §8)

    @Test("regenerateSummary(modelOverride:) forwards the override into the LLMRequest .regeneration builds")
    func regenerateSummaryForwardsModelOverride() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)

        let llm = FakeSummaryLLM()
        await llm.setResponse(patchJSONWithTitle, for: "summary_patch")
        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(), llm: llm)

        await viewModel.regenerateSummary(
            modelOverride: ResolvedModel(provider: "azure", model: "picker-selected-model", params: LLMCallParams(effort: "high"))
        )

        let request = try #require(await llm.receivedRequests.last)
        #expect(request.stubKey == "summary_patch")
        #expect(request.model == "picker-selected-model")
        #expect(request.provider == "azure")
        #expect(request.params.effort == "high")
    }

    @Test("a nil regenerateSummary(modelOverride:) (既定で実行) keeps using SummaryUpdater's own resolvedModel")
    func regenerateSummaryNilModelOverrideKeepsResolvedModel() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)

        let llm = FakeSummaryLLM()
        await llm.setResponse(patchJSONWithTitle, for: "summary_patch")
        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(), llm: llm)

        // §8's "既定" menu item must display exactly what a `nil` override is about to use.
        #expect(viewModel.summaryDefaultModelLabel == ModelResolver.builtinModelName)

        await viewModel.regenerateSummary(modelOverride: nil)

        let request = try #require(await llm.receivedRequests.last)
        #expect(request.model == ModelResolver.builtinModelName)
        #expect(request.provider == ModelResolver.builtinProviderName)
    }

    @Test("rerunFinalPass(modelOverride:) forwards the override into the LLMRequest .finalPass builds")
    func rerunFinalPassForwardsModelOverride() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)

        let llm = FakeSummaryLLM()
        await llm.setResponse(finalRevisionJSON, for: "summary_final")
        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(), llm: llm)

        await viewModel.rerunFinalPass(
            modelOverride: ResolvedModel(provider: "azure", model: "picker-selected-model", params: LLMCallParams(effort: "high"))
        )

        let request = try #require(await llm.receivedRequests.last)
        #expect(request.stubKey == "summary_final")
        #expect(request.model == "picker-selected-model")
        #expect(request.provider == "azure")
        #expect(request.params.effort == "high")
    }

    @Test("rerunFinalPass() works for an Ended session with no live SummaryUpdater ever constructed by this ViewModel instance -- the reopened-after-restart case (§8's largest implementation item)")
    func rerunFinalPassOnReopenedEndedSessionUsesTransientUpdater() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        // Simulates a session already Ended by a prior process run -- unlike
        // `endMeetingFromPausedRunsFinalPass()`/`endMeetingFromRecordingRunsFinalPass()` above, this
        // writes `meta.state` directly rather than driving it through `startRecording()`/
        // `pauseRecording()`/`endMeeting()`, precisely so this `viewModel` instance never builds a
        // live `SummaryUpdater` at any point in its lifetime.
        try await handle.updateMeta { meta in meta.state = .ended }

        let llm = FakeSummaryLLM()
        await llm.setResponse(finalRevisionJSON, for: "summary_final")
        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(), llm: llm)

        // The "既定" label must resolve even before any transient updater has actually run --
        // `summaryUpdater` is nil the whole time, so this builds (and discards) one throwaway
        // instance purely to read `resolvedFinalModel` (`SummaryUpdater.init` does no I/O).
        #expect(viewModel.summaryFinalPassDefaultModelLabel == ModelResolver.builtinModelName)

        await viewModel.rerunFinalPass()

        #expect(await llm.callCount == 1)
        let markdown = try #require(try await handle.readText(.summaryMarkdown))
        #expect(markdown.contains("最終版の概要です"))
        #expect(viewModel.summaryMarkdown?.joined.contains("最終版の概要です") == true)
        // Same regression guard as `regenerateSummaryAfterEnded()` (design 47 §2.1), on the path
        // where it matters most: an Ended session has no live updater to push a corrected value.
        #expect(viewModel.summaryMarkdown?.topics != nil)
    }

    @Test("rerunFinalPass() failure keeps the existing summary.md untouched (§8's 'failed 警告 + 既存サマリ維持')")
    func rerunFinalPassFailureKeepsExistingSummary() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        try await handle.writeText("# 既存のサマリ\n", to: .summaryMarkdown)
        try await handle.updateMeta { meta in meta.state = .ended }

        // No `summary_final` response configured -- `FakeSummaryLLM` throws `.missingStructuredOutput`,
        // which `performFinalPass(modelOverride:)` treats as "warn and skip" (§10's failure mode table).
        let llm = FakeSummaryLLM()
        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(), llm: llm)

        await viewModel.rerunFinalPass()

        // No `summary.state.json` was ever written here, so `reloadSummaryMarkdownFromDisk()` falls
        // back to the rendered file as a single pane (`docs/design/47-summary-split-pane.md` §2.3).
        #expect(viewModel.summaryMarkdown?.joined == "# 既存のサマリ\n")
        #expect(viewModel.summaryMarkdown?.topics == nil)
        #expect(try await handle.readText(.summaryMarkdown) == "# 既存のサマリ\n")
    }

    // MARK: flushSessionHandle()

    @Test("flushSessionHandle() completes without throwing even with no pending writes")
    func flushSessionHandleIsSafeWhenIdle() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline())

        await viewModel.flushSessionHandle() // Must not hang or crash.
    }

    // MARK: - Diarization (docs/design/13-speaker-diarization.md section 5/6.1)

    @Test("startRecording() calls beginSegment(hasSystemAudio: true) when system audio is enabled for this recording")
    func startRecordingBeginsDiarizationSegmentWithSystemAudioEnabled() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let coordinator = FakeDiarizationCoordinator()
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            diarizationCoordinatorFactory: { _ in coordinator }
        )
        // `.default` already has both mic/system enabled; set explicitly for clarity at the call site.
        viewModel.audioInputSelection = AudioInputSelection(
            mic: MicSelection(enabled: true, deviceUid: nil),
            system: SystemAudioSelection(enabled: true, bundleId: nil)
        )

        await viewModel.startRecording()

        let calls = await coordinator.beginSegmentCalls
        #expect(calls.count == 1)
        #expect(calls.first?.startMsOffset == 0)
        #expect(calls.first?.hasSystemAudio == true)
    }

    @Test("startRecording() calls beginSegment(hasSystemAudio: false) when system audio is disabled for this recording")
    func startRecordingBeginsDiarizationSegmentWithSystemAudioDisabled() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let coordinator = FakeDiarizationCoordinator()
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            diarizationCoordinatorFactory: { _ in coordinator }
        )
        viewModel.audioInputSelection = AudioInputSelection(
            mic: MicSelection(enabled: true, deviceUid: nil),
            system: SystemAudioSelection(enabled: false, bundleId: nil)
        )

        await viewModel.startRecording()

        let calls = await coordinator.beginSegmentCalls
        #expect(calls.first?.hasSystemAudio == false)
    }

    @Test("pauseRecording() calls endSegment(.paused); a later endMeeting() calls endSegment(.ended)")
    func pauseAndEndCallEndSegmentWithTheCorrectReason() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let coordinator = FakeDiarizationCoordinator()
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            diarizationCoordinatorFactory: { _ in coordinator }
        )

        await viewModel.startRecording()
        await viewModel.pauseRecording()
        #expect(await coordinator.endSegmentCalls == [.paused])

        await viewModel.resumeRecording()
        await viewModel.endMeeting()
        #expect(await coordinator.endSegmentCalls == [.paused, .ended])
    }

    @Test("diarization.enabled == false never creates a coordinator, and speakerLabels stays empty for every segment")
    func diarizationDisabledNeverCreatesACoordinatorOrLabels() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let appConfig = AppConfig(directory: makeTemporaryDirectory(prefix: "MeetingWorkspaceViewModelTests-appconfig"))
        appConfig.update { $0.diarization.enabled = false }

        final class FactoryCallCounter {
            var callCount = 0
        }
        let counter = FactoryCallCounter()

        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: pipeline,
            appConfig: appConfig,
            diarizationCoordinatorFactory: { _ in
                counter.callCount += 1
                return FakeDiarizationCoordinator()
            }
        )

        await viewModel.startRecording()
        pipeline.yield(Self.segment(id: "seg_00001", startMs: 0))
        pipeline.yield(Self.systemSegment(id: "seg_00002", startMs: 1_000))
        try await waitUntil { await viewModel.transcriptRows.count == 2 }
        await viewModel.pauseRecording()
        await viewModel.endMeeting()

        #expect(counter.callCount == 0, "diarizationCoordinatorFactory must never be invoked while diarization is disabled")
        #expect(viewModel.speakerLabels.isEmpty, "speakerLabels must stay empty (never populated) while diarization is disabled")
    }

    @Test("mic segments always resolve to .named(diarization.selfName), independent of any turn/assignment")
    func micSegmentsResolveToConfiguredSelfName() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let appConfig = AppConfig(directory: makeTemporaryDirectory(prefix: "MeetingWorkspaceViewModelTests-appconfig"))
        appConfig.update { $0.diarization.selfName = "自分（テスト）" }

        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: pipeline, appConfig: appConfig
        )

        await viewModel.startRecording()
        pipeline.yield(Self.segment(id: "seg_00001", startMs: 0))

        try await waitUntil { await viewModel.speakerLabels["seg_00001"]?.label == .named("自分（テスト）") }
    }

    @Test("system segments start .recognizing and resolve to .anonymous(slotNumber:) once a turn covering them arrives")
    func systemSegmentsResolveOnceATurnArrives() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let coordinator = FakeDiarizationCoordinator()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: pipeline,
            diarizationCoordinatorFactory: { _ in coordinator }
        )

        await viewModel.startRecording()
        pipeline.yield(Self.systemSegment(id: "seg_00001", startMs: 0, endMs: 1_000))

        try await waitUntil { await viewModel.speakerLabels["seg_00001"] != nil }
        #expect(viewModel.speakerLabels["seg_00001"]?.label == .recognizing)

        await coordinator.emitTurn(DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1_000))

        try await waitUntil { await viewModel.speakerLabels["seg_00001"]?.label == .anonymous(slotNumber: 1) }
    }

    @Test("renameSlot(_:displayName:) persists a user assignment and immediately updates speakerLabels")
    func renameSlotPersistsAndRefreshesLabels() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let coordinator = FakeDiarizationCoordinator()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: pipeline,
            diarizationCoordinatorFactory: { _ in coordinator }
        )

        await viewModel.startRecording()
        pipeline.yield(Self.systemSegment(id: "seg_00001", startMs: 0, endMs: 1_000))
        await coordinator.emitTurn(DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1_000))
        try await waitUntil { await viewModel.speakerLabels["seg_00001"]?.label == .anonymous(slotNumber: 1) }

        await viewModel.renameSlot("spk_1", displayName: "田中さん")

        #expect(viewModel.speakerLabels["seg_00001"]?.label == .named("田中さん"))
        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.assignments["spk_1"]?.displayName == "田中さん")
        #expect(persisted.assignments["spk_1"]?.assignedBy == .user)
    }

    // MARK: - overrideSegmentSpeaker(segmentId:submission:) (design section 6.1's "この発言だけ",
    // `docs/design/20-voiceprint-misassignment-mitigation.md` section 5)

    @Test("overrideSegmentSpeaker(.existingSpeaker:) saves both displayName and globalSpeakerId")
    func overrideSegmentSpeakerExistingSpeakerSavesGlobalSpeakerId() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline()
        )

        await viewModel.overrideSegmentSpeaker(
            segmentId: "seg_00042",
            submission: .existingSpeaker(globalSpeakerId: "g1", name: "佐藤さん")
        )

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.segmentOverrides["seg_00042"] == SegmentSpeakerOverride(displayName: "佐藤さん", globalSpeakerId: "g1"))
    }

    @Test("overrideSegmentSpeaker(.newName:) matching exactly one known speaker resolves and saves that speaker's globalSpeakerId")
    func overrideSegmentSpeakerNewNameMatchingOneKnownSpeakerResolvesToExisting() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let existing = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: [0.1, 0.2])
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )
        viewModel.knownVoiceprintSpeakers = [existing]

        await viewModel.overrideSegmentSpeaker(segmentId: "seg_00042", submission: .newName("田中さん"))

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.segmentOverrides["seg_00042"] == SegmentSpeakerOverride(displayName: "田中さん", globalSpeakerId: existing.id))
    }

    @Test("overrideSegmentSpeaker(.newName:) matching no known speaker saves a plain new display name with no globalSpeakerId")
    func overrideSegmentSpeakerNewNameWithNoMatchSavesPlainName() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline()
        )

        await viewModel.overrideSegmentSpeaker(segmentId: "seg_00042", submission: .newName("  鈴木さん  "))

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.segmentOverrides["seg_00042"] == SegmentSpeakerOverride(displayName: "鈴木さん", globalSpeakerId: nil))
    }

    @Test("overrideSegmentSpeaker(.newName:) matching more than one known speaker saves the display name only, with no globalSpeakerId")
    func overrideSegmentSpeakerNewNameMatchingMultipleKnownSpeakersIsAmbiguous() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let duplicate1 = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: [0.1, 0.2])
        let duplicate2 = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: [0.5, 0.6])
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )
        viewModel.knownVoiceprintSpeakers = [duplicate1, duplicate2]

        await viewModel.overrideSegmentSpeaker(segmentId: "seg_00042", submission: .newName("田中さん"))

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.segmentOverrides["seg_00042"] == SegmentSpeakerOverride(displayName: "田中さん", globalSpeakerId: nil))
    }

    @Test("overrideSegmentSpeaker(nil:) clears a previously-applied override")
    func overrideSegmentSpeakerNilClearsOverride() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline()
        )
        await viewModel.overrideSegmentSpeaker(segmentId: "seg_00042", submission: .newName("鈴木さん"))

        await viewModel.overrideSegmentSpeaker(segmentId: "seg_00042", submission: nil)

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.segmentOverrides["seg_00042"] == nil)
    }

    // MARK: - applyRename(slot:submission:) (design section 4.4/6.1's rename popover enrollment paths)

    @Test("applyRename(.newName:) with a captured slot embedding registers a new global speaker and assigns it")
    func applyRenameNewNameWithEmbeddingRegistersAndAssigns() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )

        let capturedEmbedding: [Float] = [0.1, 0.2, 0.3]
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(embedding: capturedEmbedding)
        }
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()

        await viewModel.applyRename(slot: "spk_1", submission: .newName("田中さん"))

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.assignments["spk_1"]?.displayName == "田中さん")
        #expect(persisted.assignments["spk_1"]?.assignedBy == .user)
        #expect(persisted.assignments["spk_1"]?.embedding == capturedEmbedding)
        let registeredId = try #require(persisted.assignments["spk_1"]?.globalSpeakerId)

        let known = await voiceprintStore.listSpeakers()
        #expect(known.count == 1)
        #expect(known.first?.id == registeredId)
        #expect(known.first?.name == "田中さん")
        #expect(known.first?.embedding == capturedEmbedding)

        // The picker's backing list is refreshed immediately, without waiting for a window reopen.
        #expect(viewModel.knownVoiceprintSpeakers.map(\.id) == [registeredId])
    }

    @Test("applyRename(.newName:) registers and assigns a global speaker even when the cached diarizationAssignments property is stale (embedding persisted straight to disk by a fire-and-forget voiceprint extraction Task that never refreshed the cache)")
    func applyRenameUsesFreshDiskReadNotStaleCachedEmbedding() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )

        // Simulates `RealtimeDiarizationCoordinator+Voiceprint.swift`'s fire-and-forget extraction
        // Task persisting a captured embedding directly to `speaker_assignments.json` for a slot that
        // found no global match -- `assignmentUpdates` only yields on a successful *match* (design
        // section 5), so the ViewModel's cached `diarizationAssignments` is never refreshed and
        // deliberately stays at its stale (pre-extraction) value here, unlike every other `applyRename`
        // test above which manually refreshes it right after writing.
        let capturedEmbedding: [Float] = [0.1, 0.2, 0.3]
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(embedding: capturedEmbedding)
        }
        #expect(viewModel.diarizationAssignments.assignments["spk_1"] == nil)

        await viewModel.applyRename(slot: "spk_1", submission: .newName("田中さん"))

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.assignments["spk_1"]?.displayName == "田中さん")
        #expect(persisted.assignments["spk_1"]?.embedding == capturedEmbedding)
        let registeredId = try #require(persisted.assignments["spk_1"]?.globalSpeakerId)

        // The whole point of the fix: registration must still happen from the fresh-from-disk
        // embedding, not silently skip to `.localOnly` because the cached property looked empty.
        let known = await voiceprintStore.listSpeakers()
        #expect(known.count == 1)
        #expect(known.first?.id == registeredId)
        #expect(known.first?.embedding == capturedEmbedding)
    }

    @Test("applyRename(.newName:) with no captured slot embedding saves a session-local display name only, skipping global registration")
    func applyRenameNewNameWithoutEmbeddingIsLocalOnly() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )

        // `diarizationAssignments`/disk both start out with no embedding captured for "spk_2" yet
        // (design section 4.4: "slot の embedding が null の場合").
        await viewModel.applyRename(slot: "spk_2", submission: .newName("佐藤さん"))
        // The default `FakeVoiceprintWavFallbackExtractor` (returns `nil`, design section 4.4's
        // 2026-07-03 fallback) is still scheduled; wait for it so this test's assertions below can't
        // race its completion.
        await viewModel.voiceprintWavFallbackTask?.value

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.assignments["spk_2"]?.displayName == "佐藤さん")
        #expect(persisted.assignments["spk_2"]?.assignedBy == .user)
        #expect(persisted.assignments["spk_2"]?.globalSpeakerId == nil)

        let known = await voiceprintStore.listSpeakers()
        #expect(known.isEmpty, "no global speaker should ever be registered without a captured embedding")
        #expect(viewModel.knownVoiceprintSpeakers.isEmpty)
    }

    // MARK: - applyRename(.newName:) free-typed-name normalization (design section 20 §4)

    @Test("applyRename(.newName:) whose trimmed text matches exactly one known speaker assigns that speaker instead of registering a duplicate")
    func applyRenameNewNameMatchingOneKnownSpeakerResolvesToExisting() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let existing = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: [0.1, 0.2])

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )
        viewModel.knownVoiceprintSpeakers = [existing]

        // A slot with its own captured embedding, so an un-normalized `.newName` would otherwise take
        // the `.registerAndAssign` branch (`SpeakerRenameDecisionTests` covers that branch in
        // isolation) -- this test's whole point is that normalization intercepts it first.
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(embedding: [0.3, 0.4])
        }
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()

        await viewModel.applyRename(slot: "spk_1", submission: .newName("田中さん"))

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.assignments["spk_1"]?.displayName == "田中さん")
        #expect(persisted.assignments["spk_1"]?.globalSpeakerId == existing.id)
        #expect(persisted.assignments["spk_1"]?.assignedBy == .user)

        // No duplicate speaker was ever registered.
        let known = await voiceprintStore.listSpeakers()
        #expect(known.count == 1)
        #expect(known.first?.id == existing.id)
    }

    @Test("applyRename(.newName:) whose trimmed text matches more than one known speaker (duplicate names) saves a session-local display name only, with no registration and no WAV fallback scheduled")
    func applyRenameNewNameMatchingMultipleKnownSpeakersIsLocalOnlyWithoutFallback() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let duplicate1 = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: [0.1, 0.2])
        let duplicate2 = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: [0.5, 0.6])
        let fallbackExtractor = FakeVoiceprintWavFallbackExtractor(behavior: .returns([0.7, 0.8]))

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore,
            voiceprintWavFallbackExtractorFactory: { _ in fallbackExtractor }
        )
        viewModel.knownVoiceprintSpeakers = [duplicate1, duplicate2]

        // A slot with its own captured embedding, so an un-normalized `.newName` would otherwise take
        // the `.registerAndAssign` branch -- the ambiguity must intercept it before that ever runs.
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(embedding: [0.3, 0.4])
        }
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()

        await viewModel.applyRename(slot: "spk_1", submission: .newName("田中さん"))

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.assignments["spk_1"]?.displayName == "田中さん")
        #expect(persisted.assignments["spk_1"]?.globalSpeakerId == nil)
        #expect(persisted.assignments["spk_1"]?.assignedBy == .user)
        // The slot's own captured embedding is left untouched (never registered as a new speaker).
        #expect(persisted.assignments["spk_1"]?.embedding == [0.3, 0.4])

        // No duplicate/new speaker was ever registered, and the ambiguous branch must never fall back
        // to the WAV-fallback machinery either (unlike the ordinary `.localOnly` branch).
        let known = await voiceprintStore.listSpeakers()
        #expect(known.count == 2)
        #expect(viewModel.voiceprintWavFallbackTask == nil)
        let requestedSlots = await fallbackExtractor.requestedSlots
        #expect(requestedSlots.isEmpty)
    }

    // MARK: - On-demand WAV voiceprint fallback (design section 4.4, "実装時の追記 2026-07-03")

    @Test("applyRename(.newName:) with no captured embedding schedules a WAV fallback that registers a new global speaker when extraction succeeds")
    func applyRenameSchedulesWavFallbackThatRegistersOnSuccess() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let fallbackEmbedding: [Float] = [0.4, 0.5, 0.6]
        let fallbackExtractor = FakeVoiceprintWavFallbackExtractor(behavior: .returns(fallbackEmbedding))

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore,
            voiceprintWavFallbackExtractorFactory: { _ in fallbackExtractor }
        )

        await viewModel.applyRename(slot: "spk_2", submission: .newName("佐藤さん"))
        // `applyRename(slot:submission:)` never awaits the fallback Task itself (design section 4.4:
        // it must not block the rename UI) -- tests wait for it explicitly via the stored task.
        await viewModel.voiceprintWavFallbackTask?.value

        let requestedSlots = await fallbackExtractor.requestedSlots
        #expect(requestedSlots == ["spk_2"])

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.assignments["spk_2"]?.displayName == "佐藤さん")
        #expect(persisted.assignments["spk_2"]?.embedding == fallbackEmbedding)
        let registeredId = try #require(persisted.assignments["spk_2"]?.globalSpeakerId)

        let known = await voiceprintStore.listSpeakers()
        #expect(known.count == 1)
        #expect(known.first?.id == registeredId)
        #expect(known.first?.name == "佐藤さん")
        #expect(known.first?.embedding == fallbackEmbedding)

        // The picker's backing list is refreshed once the fallback registration completes, without
        // waiting for a window reopen (mirrors the live-embedding `.registerAndAssign` path above).
        #expect(viewModel.knownVoiceprintSpeakers.map(\.id) == [registeredId])
    }

    @Test("applyRename(.newName:) leaves the session-local display name in place, with no global registration, when the WAV fallback finds nothing to extract")
    func applyRenameWavFallbackInsufficientSpeechSkipsRegistration() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        // `nil` mirrors `VoiceprintWavFallbackExtractor.extractEmbedding(forSlot:)`'s contract for
        // "not enough attributed speech" (below `min_enroll_speech_ms`) or "no readable audio".
        let fallbackExtractor = FakeVoiceprintWavFallbackExtractor(behavior: .returns(nil))

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore,
            voiceprintWavFallbackExtractorFactory: { _ in fallbackExtractor }
        )

        await viewModel.applyRename(slot: "spk_2", submission: .newName("佐藤さん"))
        await viewModel.voiceprintWavFallbackTask?.value

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.assignments["spk_2"]?.displayName == "佐藤さん")
        #expect(persisted.assignments["spk_2"]?.embedding == nil)
        #expect(persisted.assignments["spk_2"]?.globalSpeakerId == nil)

        let known = await voiceprintStore.listSpeakers()
        #expect(known.isEmpty)
        #expect(viewModel.knownVoiceprintSpeakers.isEmpty)
    }

    @Test("applyRename(.newName:) leaves the session-local display name in place when the WAV fallback extraction throws")
    func applyRenameWavFallbackExtractionFailureLeavesDisplayNameIntact() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let fallbackExtractor = FakeVoiceprintWavFallbackExtractor(behavior: .throwsError(FakeError()))

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore,
            voiceprintWavFallbackExtractorFactory: { _ in fallbackExtractor }
        )

        await viewModel.applyRename(slot: "spk_2", submission: .newName("佐藤さん"))
        await viewModel.voiceprintWavFallbackTask?.value

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.assignments["spk_2"]?.displayName == "佐藤さん")
        #expect(persisted.assignments["spk_2"]?.assignedBy == .user)
        #expect(persisted.assignments["spk_2"]?.embedding == nil)
        #expect(persisted.assignments["spk_2"]?.globalSpeakerId == nil)

        let known = await voiceprintStore.listSpeakers()
        #expect(known.isEmpty)
        #expect(viewModel.knownVoiceprintSpeakers.isEmpty)
    }

    @Test("applyRename(.newName:) with an already-captured embedding does not schedule the WAV fallback")
    func applyRenameWithEmbeddingDoesNotScheduleWavFallback() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let fallbackExtractor = FakeVoiceprintWavFallbackExtractor(behavior: .returns([9.9]))

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore,
            voiceprintWavFallbackExtractorFactory: { _ in fallbackExtractor }
        )

        let capturedEmbedding: [Float] = [0.1, 0.2, 0.3]
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(embedding: capturedEmbedding)
        }
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()

        await viewModel.applyRename(slot: "spk_1", submission: .newName("田中さん"))

        #expect(viewModel.voiceprintWavFallbackTask == nil)
        let requestedSlots = await fallbackExtractor.requestedSlots
        #expect(requestedSlots.isEmpty)
    }

    @Test("applyRename(.existingSpeaker:) does not schedule the WAV fallback")
    func applyRenameExistingSpeakerDoesNotScheduleWavFallback() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let existingSpeaker = try await voiceprintStore.registerSpeaker(name: "鈴木さん", embedding: [0.9, 0.8])
        let fallbackExtractor = FakeVoiceprintWavFallbackExtractor(behavior: .returns([9.9]))

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore,
            voiceprintWavFallbackExtractorFactory: { _ in fallbackExtractor }
        )

        await viewModel.applyRename(
            slot: "spk_2",
            submission: .existingSpeaker(globalSpeakerId: existingSpeaker.id, name: existingSpeaker.name)
        )

        #expect(viewModel.voiceprintWavFallbackTask == nil)
        let requestedSlots = await fallbackExtractor.requestedSlots
        #expect(requestedSlots.isEmpty)
    }

    @Test("applyRename(.existingSpeaker:) assigns the picked speaker without touching any embedding")
    func applyRenameExistingSpeakerAssignsWithoutTouchingEmbedding() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let existingSpeaker = try await voiceprintStore.registerSpeaker(name: "鈴木さん", embedding: [0.9, 0.8])

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )

        let slotEmbedding: [Float] = [0.1, 0.2]
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(embedding: slotEmbedding)
        }
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()

        await viewModel.applyRename(
            slot: "spk_1",
            submission: .existingSpeaker(globalSpeakerId: existingSpeaker.id, name: existingSpeaker.name)
        )

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.assignments["spk_1"]?.displayName == "鈴木さん")
        #expect(persisted.assignments["spk_1"]?.globalSpeakerId == existingSpeaker.id)
        #expect(persisted.assignments["spk_1"]?.assignedBy == .user)
        // The slot's own embedding is left exactly as it was.
        #expect(persisted.assignments["spk_1"]?.embedding == slotEmbedding)

        // Picking an existing speaker never registers/mutates anything in the global DB.
        let known = await voiceprintStore.listSpeakers()
        #expect(known.count == 1)
        #expect(known.first?.embedding == [0.9, 0.8])
    }

    @Test("applyRename(_:submission:) propagates the rename to every other slot already sharing the same globalSpeakerId")
    func applyRenamePropagatesToSiblingSlots() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )

        // Two slots (e.g. split across a Paused/resume boundary, design section 5.1) already
        // auto-matched to the same global speaker.
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(globalSpeakerId: "g1", displayName: "田中さん", assignedBy: .auto)
            assignments.assignments["spk_3"] = SlotAssignment(globalSpeakerId: "g1", displayName: "田中さん", assignedBy: .auto)
        }
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()

        await viewModel.applyRename(slot: "spk_1", submission: .existingSpeaker(globalSpeakerId: "g1", name: "田中太郎さん"))

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.assignments["spk_1"]?.displayName == "田中太郎さん")
        #expect(persisted.assignments["spk_3"]?.displayName == "田中太郎さん")
        #expect(persisted.assignments["spk_3"]?.assignedBy == .user)
    }

    // MARK: - Ended-time diarization hooks (docs/design/13-speaker-diarization.md sections 4.4/6.2, "R2 module 4")

    @Test("endMeeting() leaves an auto-only slot's speaker untouched, and applies userCorrectionAlpha for a user-only slot")
    func endMeetingAppliesMovingAverageWeightedByAssignmentSource() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))

        let autoOldEmbedding: [Float] = [1, 0]
        let autoSlotEmbedding: [Float] = [0, 1]
        let autoSpeaker = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: autoOldEmbedding)

        let userOldEmbedding: [Float] = [1, 0]
        let userSlotEmbedding: [Float] = [0, 1]
        let userSpeaker = try await voiceprintStore.registerSpeaker(name: "佐藤さん", embedding: userOldEmbedding)

        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(
                globalSpeakerId: autoSpeaker.id, displayName: "田中さん", assignedBy: .auto, embedding: autoSlotEmbedding
            )
            assignments.assignments["spk_2"] = SlotAssignment(
                globalSpeakerId: userSpeaker.id, displayName: "佐藤さん", assignedBy: .user, embedding: userSlotEmbedding
            )
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )

        await viewModel.startRecording()
        await viewModel.endMeeting()

        // An unreviewed .auto-only slot is never an Ended-time enrollment candidate (design section
        // 4.4: explicit user feedback is required before the voiceprint learns anything), so this
        // speaker's embedding/lastMatchedSessionId are left exactly as registered.
        let updatedAuto = await voiceprintStore.speaker(id: autoSpeaker.id)
        #expect(updatedAuto?.embedding == autoOldEmbedding)
        #expect(updatedAuto?.lastMatchedSessionId == nil)

        // A .user-assigned slot is still a valid Ended-time sample -- the user's explicit pick is
        // applied at the higher userCorrectionAlpha (design section 4.4).
        let userAlpha = Float(VoiceprintStore.userCorrectionAlpha)
        let expectedUserEmbedding = zip(userOldEmbedding, userSlotEmbedding).map { (1 - userAlpha) * $0 + userAlpha * $1 }
        let updatedUser = await voiceprintStore.speaker(id: userSpeaker.id)
        #expect(updatedUser?.embedding == expectedUserEmbedding)
        #expect(updatedUser?.lastMatchedSessionId == created.id)
    }

    @Test("when a speaker's slots split across .auto and .user assignments, the .user slot's embedding wins and applies at userCorrectionAlpha")
    func endMeetingPrefersUserSlotOverAutoSlotForSameSpeaker() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))

        let oldEmbedding: [Float] = [1, 0]
        let autoSlotEmbedding: [Float] = [0, 1]
        let userSlotEmbedding: [Float] = [0.5, 0.5]
        let speaker = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: oldEmbedding)

        // A slot split (design section 5.1: diarizer (re)creation at a Paused/resume boundary): the
        // same person as spk_1 (auto-matched) re-appears as spk_2, and the user corrects spk_2 to the
        // same speaker (assignedBy becomes .user).
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(
                globalSpeakerId: speaker.id, displayName: "田中さん", assignedBy: .auto, embedding: autoSlotEmbedding
            )
            assignments.assignments["spk_2"] = SlotAssignment(
                globalSpeakerId: speaker.id, displayName: "田中さん", assignedBy: .user, embedding: userSlotEmbedding
            )
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )

        await viewModel.startRecording()
        await viewModel.endMeeting()

        let alpha = Float(VoiceprintStore.userCorrectionAlpha)
        let expectedEmbedding = zip(oldEmbedding, userSlotEmbedding).map { (1 - alpha) * $0 + alpha * $1 }
        let updated = await voiceprintStore.speaker(id: speaker.id)
        #expect(updated?.embedding == expectedEmbedding)
        #expect(updated?.lastMatchedSessionId == created.id)
    }

    @Test("when the winning .user slot for a speaker has no captured embedding, the speaker is left unchanged (no fallback to a sibling .auto slot)")
    func endMeetingFallsBackToAutoSlotWhenUserSlotEmbeddingIsNull() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))

        let oldEmbedding: [Float] = [1, 0]
        let autoSlotEmbedding: [Float] = [0, 1]
        let speaker = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: oldEmbedding)

        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(
                globalSpeakerId: speaker.id, displayName: "田中さん", assignedBy: .auto, embedding: autoSlotEmbedding
            )
            // A .user correction with too little speech to have captured a voiceprint yet
            // (design section 4.4's `.localOnly`/null-embedding carve-out).
            assignments.assignments["spk_2"] = SlotAssignment(
                globalSpeakerId: speaker.id, displayName: "田中さん", assignedBy: .user, embedding: nil
            )
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )

        await viewModel.startRecording()
        await viewModel.endMeeting()

        // The .user slot ranks higher but is not a valid candidate without an embedding. An unreviewed
        // .auto slot is never a fallback candidate (design section 4.4), so this speaker is skipped
        // entirely and left exactly as registered.
        let updated = await voiceprintStore.speaker(id: speaker.id)
        #expect(updated?.embedding == oldEmbedding)
        #expect(updated?.lastMatchedSessionId == nil)
    }

    @Test("the moving-average update's own dedup guard prevents double-application across an Ended -> Recording -> Ended reopen")
    func endMeetingMovingAverageDedupAcrossReopen() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))

        let oldEmbedding: [Float] = [1, 0]
        let slotEmbedding: [Float] = [0, 1]
        let speaker = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: oldEmbedding)
        try await handle.updateSpeakerAssignments { assignments in
            // A .user slot (not .auto, which is never an Ended-time candidate at all -- design section
            // 4.4) so this test still exercises the dedup guard on a real, applying update.
            assignments.assignments["spk_1"] = SlotAssignment(
                globalSpeakerId: speaker.id, displayName: "田中さん", assignedBy: .user, embedding: slotEmbedding
            )
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )

        await viewModel.startRecording()
        await viewModel.endMeeting()
        let afterFirstEnd = await voiceprintStore.speaker(id: speaker.id)

        // reopen (Ended -> Recording) and end again (kikimi.md 4 章 "Ended も可逆"): the assignment on
        // disk is unchanged (no new voiceprint extraction happens in this fake-coordinator test), so a
        // second unconditional moving-average application would visibly move the embedding again.
        await viewModel.reopenRecording()
        await viewModel.endMeeting()
        let afterSecondEnd = await voiceprintStore.speaker(id: speaker.id)

        #expect(afterSecondEnd?.embedding == afterFirstEnd?.embedding)
        #expect(afterSecondEnd?.lastMatchedSessionId == created.id)
    }

    @Test("endMeeting() skips (without crashing) the moving-average update for an auto-assigned slot whose embedding is null")
    func endMeetingSkipsMovingAverageWhenEmbeddingIsNull() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))

        let speaker = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: [1, 0])
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(
                globalSpeakerId: speaker.id, displayName: "田中さん", assignedBy: .auto, embedding: nil
            )
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )

        await viewModel.startRecording()
        await viewModel.endMeeting() // must not crash/throw despite the null embedding

        #expect(viewModel.recordingButtonState == .ended)
        let unchanged = await voiceprintStore.speaker(id: speaker.id)
        #expect(unchanged?.embedding == [1, 0])
        #expect(unchanged?.lastMatchedSessionId == nil)
    }

    @Test("endMeeting() merges every slot's non-nil displayName into summary.state.json's participants via SummaryUpdater")
    func endMeetingMergesParticipantsIntoSummaryState() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(globalSpeakerId: "g1", displayName: "田中さん", assignedBy: .auto, embedding: [1, 0])
            assignments.assignments["spk_2"] = SlotAssignment(globalSpeakerId: nil, displayName: "佐藤さん", assignedBy: .user, embedding: nil)
            assignments.assignments["spk_3"] = SlotAssignment() // still anonymous -- must not add anything
        }

        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline())

        await viewModel.startRecording()
        await viewModel.endMeeting()

        let state = try #require(try await handle.readJSON(.summaryState, as: SummaryState.self))
        #expect(Set(state.participants) == Set(["田中さん", "佐藤さん"]))
    }

    @Test("endMeeting()'s initial Ended-transition participants merge also includes segment-override displayNames, deduped against an identical slot name (design section 20 §5.6)")
    func endMeetingMergesOverrideDisplayNamesIntoParticipantsAlongsideSlotNames() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(globalSpeakerId: "g1", displayName: "田中さん", assignedBy: .auto, embedding: [1, 0])
            // Exact-match dedup against the slot's own name (design 6.2 "重複排除: 完全一致のみ").
            assignments.segmentOverrides["seg_00001"] = SegmentSpeakerOverride(displayName: "田中さん", globalSpeakerId: "g1")
            // A distinct override-only name, never assigned to any slot.
            assignments.segmentOverrides["seg_00002"] = SegmentSpeakerOverride(displayName: "山田さん", globalSpeakerId: nil)
        }

        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline())

        await viewModel.startRecording()
        await viewModel.endMeeting()

        let state = try #require(try await handle.readJSON(.summaryState, as: SummaryState.self))
        #expect(Set(state.participants) == Set(["田中さん", "山田さん"]))
    }

    @Test("renaming a slot after Ended merges the new displayName into summary.state.json's participants (design 6.2 'Ended 後のリネーム時')")
    func renameAfterEndedMergesParticipants() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline())

        await viewModel.startRecording()
        await viewModel.endMeeting()
        #expect(viewModel.recordingButtonState == .ended)

        // No slots were named before Ended, so the Ended-transition merge itself had nothing to add.
        let stateBeforeRename = try await handle.readJSON(.summaryState, as: SummaryState.self)
        #expect(stateBeforeRename?.participants.isEmpty != false)

        await viewModel.renameSlot("spk_1", displayName: "田中さん")

        let state = try #require(try await handle.readJSON(.summaryState, as: SummaryState.self))
        #expect(state.participants.contains("田中さん"))
    }

    @Test("renaming a slot while still Recording does not merge into summary.state.json's participants (design 6.2 'Recording 中は反映しない')")
    func renameWhileRecordingDoesNotMergeParticipants() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline())

        await viewModel.startRecording()
        await viewModel.renameSlot("spk_1", displayName: "田中さん")

        let state = try await handle.readJSON(.summaryState, as: SummaryState.self)
        #expect(state == nil, "no summary.state.json write should be triggered by a Recording-time rename")

        await viewModel.endMeeting()
    }

    // MARK: - Override-aggregate enrollment (docs/design/20-voiceprint-misassignment-mitigation.md
    // sections 5.3-5.5, "M2")

    private func makeAppConfig(minEnrollSpeechMs: Int) -> AppConfig {
        let appConfig = AppConfig(directory: FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingWorkspaceViewModelTests-appconfig-\(UUID().uuidString)", isDirectory: true
        ))
        appConfig.update { $0.diarization.minEnrollSpeechMs = minEnrollSpeechMs }
        return appConfig
    }

    @Test("a new-name override-aggregate winner registers a new global speaker, writes its id back onto the override, and a later reopen -> Ended does not register a duplicate")
    func overrideAggregateNewNameRegistersAndWritesBackWithoutDuplicating() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let extractor = FakeOverrideEnrollmentExtractor(behavior: .returns([0.5, 0.5]))

        try await handle.updateSpeakerAssignments { assignments in
            assignments.segmentOverrides["seg_00001"] = SegmentSpeakerOverride(displayName: "山田さん", globalSpeakerId: nil)
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            appConfig: makeAppConfig(minEnrollSpeechMs: 1_000),
            voiceprintStore: voiceprintStore,
            overrideEnrollmentExtractorFactory: { _ in extractor }
        )
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 8_000, speaker: .system, rawText: "hi", state: .raw)
        ]
        // No slot assignment for "spk_9" at all -- a pure override-only identity, the segment still
        // resolves to `.single("spk_9")` since `SegmentAttribution` only ever looks at turns.
        viewModel.diarizationTurns = [DiarizationTurn(slot: "spk_9", startMs: 0, endMs: 8_000)]
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()

        await viewModel.startRecording()
        await viewModel.endMeeting()
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        let speakers = await voiceprintStore.listSpeakers()
        #expect(speakers.count == 1)
        #expect(speakers.first?.name == "山田さん")
        #expect(speakers.first?.embedding == [0.5, 0.5])

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.segmentOverrides["seg_00001"]?.globalSpeakerId == speakers.first?.id)
        #expect(await viewModel.knownVoiceprintSpeakers.contains { $0.id == speakers.first?.id } != false)

        // reopen (Ended -> Recording) and end again (kikimi.md 4 章 "Ended も可逆"): the override already
        // carries the written-back globalSpeakerId, so this identity now resolves via `.existingSpeaker`
        // and must not register a second "山田さん".
        await viewModel.reopenRecording()
        await viewModel.endMeeting()
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        let speakersAfterReopen = await voiceprintStore.listSpeakers()
        #expect(speakersAfterReopen.count == 1)
    }

    @Test("a new-name override while still Recording (not yet Ended) learns the voiceprint from that segment's audio immediately and auto-adds the registered speaker to the roster (design 20 §5.4 2026-07-07 追記)")
    func overrideWhileRecordingEnrollsAndAddsRosterImmediately() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let extractor = FakeOverrideEnrollmentExtractor(behavior: .returns([0.3, 0.7]))

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            appConfig: makeAppConfig(minEnrollSpeechMs: 1_000),
            voiceprintStore: voiceprintStore,
            overrideEnrollmentExtractorFactory: { _ in extractor }
        )
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 8_000, speaker: .system, rawText: "hi", state: .raw)
        ]
        viewModel.diarizationTurns = [DiarizationTurn(slot: "spk_9", startMs: 0, endMs: 8_000)]

        await viewModel.startRecording()
        // The correction happens mid-meeting -- endMeeting() is never called before the assertions.
        await viewModel.overrideSegmentSpeaker(segmentId: "seg_00001", submission: .newName("山田さん"))
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        let refreshedState = await handle.meta.state
        #expect(refreshedState == .recording, "the session must still be Recording -- enrollment ran without waiting for Ended")

        let speakers = await voiceprintStore.listSpeakers()
        #expect(speakers.count == 1)
        #expect(speakers.first?.name == "山田さん")
        #expect(speakers.first?.embedding == [0.3, 0.7], "the voiceprint is learned from the segment's real audio, not an empty embedding")

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.segmentOverrides["seg_00001"]?.globalSpeakerId == speakers.first?.id)

        let roster = try await handle.readParticipants()
        #expect(roster.participantIds.contains(where: { $0 == speakers.first?.id }), "the registered speaker is auto-added to the participant roster mid-meeting")
        #expect(viewModel.participantHints.contains { $0.id == speakers.first?.id })
    }

    @Test("overriding one segment of a clean single-speaker slot that was auto-mis-named converges the WHOLE slot: the disputed .auto slot is reset and re-matches to the corrected speaker (design 20 §6 / 22 §3, 2026-07-07)")
    func overrideResetsDisputedSlotAndRematchesWholeSlot() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        // "Y" is the wrong speaker the diarizer auto-matched; "C" is who the slot actually is. The slot's
        // stored embedding is C's voice ([0, 1]) -- it should have matched C, and will once C is on the
        // closed-set roster and the disputed slot is reopened.
        let wrongY = try await voiceprintStore.registerSpeaker(name: "Y", embedding: [1, 0])
        let correctC = try await voiceprintStore.registerSpeaker(name: "C", embedding: [0, 1])

        try await handle.updateSpeakerAssignments { assignments in
            var slot = SlotAssignment()
            slot.displayName = "Y"
            slot.globalSpeakerId = wrongY.id
            slot.assignedBy = .auto
            slot.embedding = [0, 1]
            assignments.assignments["spk_1"] = slot
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            appConfig: makeAppConfig(minEnrollSpeechMs: 1_000),
            voiceprintStore: voiceprintStore
        )
        viewModel.knownVoiceprintSpeakers = [wrongY, correctC]
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 8_000, speaker: .system, rawText: "hi", state: .raw)
        ]
        viewModel.diarizationTurns = [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 8_000)]
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()

        // User corrects just one segment to the real speaker C ("この発言だけ").
        await viewModel.overrideSegmentSpeaker(segmentId: "seg_00001", submission: .existingSpeaker(globalSpeakerId: correctC.id, name: "C"))
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        let persisted = try await handle.readSpeakerAssignments()
        // The whole slot -- not just the one overridden row -- now resolves to C.
        #expect(persisted.assignments["spk_1"]?.displayName == "C", "the disputed slot must re-match to the corrected speaker, converging every segment in it")
        #expect(persisted.assignments["spk_1"]?.globalSpeakerId == correctC.id)
        #expect(persisted.assignments["spk_1"]?.assignedBy == .auto)
        #expect(persisted.segmentOverrides["seg_00001"]?.globalSpeakerId == correctC.id)

        let roster = await handle.readParticipants()
        #expect(roster.participantIds == [correctC.id])
    }

    @Test("a disputed slot is NOT reset while the roster is still empty (open-set would just re-match the same wrong speaker -- no churn)")
    func disputedSlotNotResetWithEmptyRoster() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let wrongY = try await voiceprintStore.registerSpeaker(name: "Y", embedding: [1, 0])

        try await handle.updateSpeakerAssignments { assignments in
            var slot = SlotAssignment()
            slot.displayName = "Y"
            slot.globalSpeakerId = wrongY.id
            slot.assignedBy = .auto
            slot.embedding = [0, 1]
            assignments.assignments["spk_1"] = slot
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            appConfig: makeAppConfig(minEnrollSpeechMs: 1_000),
            voiceprintStore: voiceprintStore
        )
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 8_000, speaker: .system, rawText: "hi", state: .raw)
        ]
        viewModel.diarizationTurns = [DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 8_000)]
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()

        // A brand-new name whose stage-2 registration produces nothing (no real audio) never reaches the
        // roster, so the disputed slot must stay as-is rather than churn back through an open-set rematch.
        await viewModel.overrideSegmentSpeaker(segmentId: "seg_00001", submission: .newName("Zoe"))
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.assignments["spk_1"]?.displayName == "Y", "with an empty roster the disputed slot is left untouched (no open-set churn)")
        let roster = await handle.readParticipants()
        #expect(roster.participantIds.isEmpty)
    }

    @Test("an override-aggregate winner for an already-known speaker (identity via override.globalSpeakerId) applies the userCorrectionAlpha moving-average update")
    func overrideAggregateExistingSpeakerAppliesUserCorrectionAlpha() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let oldEmbedding: [Float] = [1, 0]
        let speaker = try await voiceprintStore.registerSpeaker(name: "鈴木さん", embedding: oldEmbedding)
        let extractedEmbedding: [Float] = [0, 1]
        let extractor = FakeOverrideEnrollmentExtractor(behavior: .returns(extractedEmbedding))

        try await handle.updateSpeakerAssignments { assignments in
            assignments.segmentOverrides["seg_00001"] = SegmentSpeakerOverride(displayName: "鈴木さん", globalSpeakerId: speaker.id)
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            appConfig: makeAppConfig(minEnrollSpeechMs: 1_000),
            voiceprintStore: voiceprintStore,
            overrideEnrollmentExtractorFactory: { _ in extractor }
        )
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 8_000, speaker: .system, rawText: "hi", state: .raw)
        ]
        viewModel.diarizationTurns = [DiarizationTurn(slot: "spk_9", startMs: 0, endMs: 8_000)]
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()

        await viewModel.startRecording()
        await viewModel.endMeeting()
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        let alpha = Float(VoiceprintStore.userCorrectionAlpha)
        let expected = zip(oldEmbedding, extractedEmbedding).map { (1 - alpha) * $0 + alpha * $1 }
        let updated = await voiceprintStore.speaker(id: speaker.id)
        #expect(updated?.embedding == expected)
        #expect(updated?.lastMatchedSessionId == created.id)
    }

    @Test("a .user slot beats an override-aggregate sample for the same speaker: no stage 2 task is scheduled at all")
    func userSlotBeatsOverrideAggregate() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let oldEmbedding: [Float] = [1, 0]
        let speaker = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: oldEmbedding)
        let userSlotEmbedding: [Float] = [9, 9]
        let extractor = FakeOverrideEnrollmentExtractor(behavior: .returns([42, 42]))

        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(
                globalSpeakerId: speaker.id, displayName: "田中さん", assignedBy: .user, embedding: userSlotEmbedding
            )
            assignments.segmentOverrides["seg_00001"] = SegmentSpeakerOverride(displayName: "田中さん", globalSpeakerId: speaker.id)
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            appConfig: makeAppConfig(minEnrollSpeechMs: 1_000),
            voiceprintStore: voiceprintStore,
            overrideEnrollmentExtractorFactory: { _ in extractor }
        )
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 8_000, speaker: .system, rawText: "hi", state: .raw)
        ]
        viewModel.diarizationTurns = [DiarizationTurn(slot: "spk_9", startMs: 0, endMs: 8_000)]
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()

        await viewModel.startRecording()
        await viewModel.endMeeting()
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        #expect(await extractor.requestedSliceCounts.isEmpty, "the override-aggregate extractor must never be invoked once a .user slot already wins")

        let alpha = Float(VoiceprintStore.userCorrectionAlpha)
        let expected = zip(oldEmbedding, userSlotEmbedding).map { (1 - alpha) * $0 + alpha * $1 }
        let updated = await voiceprintStore.speaker(id: speaker.id)
        #expect(updated?.embedding == expected)
    }

    @Test("an override-aggregate winner beats a non-disputed .auto slot for the same speaker: the .auto slot's embedding never applies")
    func overrideAggregateBeatsNonDisputedAutoSlot() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let oldEmbedding: [Float] = [1, 0]
        let speaker = try await voiceprintStore.registerSpeaker(name: "佐藤さん", embedding: oldEmbedding)
        let autoSlotEmbedding: [Float] = [5, 5]
        let extractedEmbedding: [Float] = [2, 2]
        let extractor = FakeOverrideEnrollmentExtractor(behavior: .returns(extractedEmbedding))

        try await handle.updateSpeakerAssignments { assignments in
            // spk_2's own segment is never overridden, so it is not disputed -- it is still a healthy
            // fallback candidate that must nonetheless lose to the override-aggregate sample.
            assignments.assignments["spk_2"] = SlotAssignment(
                globalSpeakerId: speaker.id, displayName: "佐藤さん", assignedBy: .auto, embedding: autoSlotEmbedding
            )
            assignments.segmentOverrides["seg_00002"] = SegmentSpeakerOverride(displayName: "佐藤さん", globalSpeakerId: speaker.id)
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            appConfig: makeAppConfig(minEnrollSpeechMs: 1_000),
            voiceprintStore: voiceprintStore,
            overrideEnrollmentExtractorFactory: { _ in extractor }
        )
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00002", startMs: 10_000, endMs: 18_000, speaker: .system, rawText: "hi", state: .raw)
        ]
        viewModel.diarizationTurns = [DiarizationTurn(slot: "spk_9", startMs: 10_000, endMs: 18_000)]
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()

        await viewModel.startRecording()
        await viewModel.endMeeting()
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        // Alpha for the override path (userCorrectionAlpha, 0.3) yields [1.3, 0.6]; the .auto path
        // (defaultMovingAverageAlpha, 0.1) would instead yield [1.4, 0.5] -- distinct enough to prove
        // which candidate actually won.
        let alpha = Float(VoiceprintStore.userCorrectionAlpha)
        let expected = zip(oldEmbedding, extractedEmbedding).map { (1 - alpha) * $0 + alpha * $1 }
        let updated = await voiceprintStore.speaker(id: speaker.id)
        #expect(updated?.embedding == expected)
    }

    @Test("when the override-aggregate resolver finds too little speech, the speaker is skipped (no fallback to a non-disputed .auto slot)")
    func overrideAggregateNilFallsBackToAutoSlot() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let oldEmbedding: [Float] = [1, 0]
        let speaker = try await voiceprintStore.registerSpeaker(name: "佐藤さん", embedding: oldEmbedding)
        let autoSlotEmbedding: [Float] = [5, 5]
        let extractor = FakeOverrideEnrollmentExtractor(behavior: .returns([2, 2]))

        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_2"] = SlotAssignment(
                globalSpeakerId: speaker.id, displayName: "佐藤さん", assignedBy: .auto, embedding: autoSlotEmbedding
            )
            assignments.segmentOverrides["seg_00002"] = SegmentSpeakerOverride(displayName: "佐藤さん", globalSpeakerId: speaker.id)
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            // A high gate the override's tiny 500ms segment cannot clear.
            appConfig: makeAppConfig(minEnrollSpeechMs: 5_000),
            voiceprintStore: voiceprintStore,
            overrideEnrollmentExtractorFactory: { _ in extractor }
        )
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00002", startMs: 0, endMs: 500, speaker: .system, rawText: "hi", state: .raw)
        ]
        viewModel.diarizationTurns = [DiarizationTurn(slot: "spk_9", startMs: 0, endMs: 500)]
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()

        await viewModel.startRecording()
        await viewModel.endMeeting()
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        #expect(await extractor.requestedSliceCounts.isEmpty, "the resolver returning nil must never schedule stage 2 at all")

        // An unreviewed .auto slot is never a fallback candidate (design section 4.4), so with no
        // usable override aggregate this speaker is skipped entirely and left as registered.
        let updated = await voiceprintStore.speaker(id: speaker.id)
        #expect(updated?.embedding == oldEmbedding)
    }

    @Test("a disputed .auto slot is excluded from EMA candidacy; with no other candidate for that speaker, it is skipped entirely (unchanged)")
    func disputedAutoSlotIsExcludedAndSpeakerIsSkippedWithNoOtherCandidate() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let oldEmbedding: [Float] = [1, 1]
        let speaker = try await voiceprintStore.registerSpeaker(name: "鈴木さん", embedding: oldEmbedding)

        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_3"] = SlotAssignment(
                globalSpeakerId: speaker.id, displayName: "鈴木さん", assignedBy: .auto, embedding: [7, 7]
            )
            // Overrides spk_3's own segment with a different name -- disputes spk_3, and (since the
            // name resolves to no known speaker) also seeds a brand-new "違う人" identity group.
            assignments.segmentOverrides["seg_00004"] = SegmentSpeakerOverride(displayName: "違う人", globalSpeakerId: nil)
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            appConfig: makeAppConfig(minEnrollSpeechMs: 1_000),
            voiceprintStore: voiceprintStore,
            overrideEnrollmentExtractorFactory: { _ in FakeOverrideEnrollmentExtractor(behavior: .returns([3, 3])) }
        )
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00004", startMs: 0, endMs: 8_000, speaker: .system, rawText: "hi", state: .raw)
        ]
        viewModel.diarizationTurns = [DiarizationTurn(slot: "spk_3", startMs: 0, endMs: 8_000)]
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()

        await viewModel.startRecording()
        await viewModel.endMeeting()
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        // spk_3 is disputed, and no other candidate (no .user slot, no override targeting speaker.id
        // directly) exists for 鈴木さん -- the EMA update must be skipped entirely.
        let unchanged = await voiceprintStore.speaker(id: speaker.id)
        #expect(unchanged?.embedding == oldEmbedding)
        #expect(unchanged?.lastMatchedSessionId == nil)

        // Meanwhile the dispute correctly rerouted learning toward the override's own new name.
        let allSpeakers = await voiceprintStore.listSpeakers()
        #expect(allSpeakers.contains { $0.name == "違う人" })
    }

    @Test("a stage 2 extraction failure never falls back to a slot embedding; the speaker is left unchanged")
    func stage2ExtractionFailureDoesNotFallBackToSlotEmbedding() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let oldEmbedding: [Float] = [1, 0]
        let speaker = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: oldEmbedding)
        let extractor = FakeOverrideEnrollmentExtractor(behavior: .throwsError(FakeError()))

        try await handle.updateSpeakerAssignments { assignments in
            assignments.segmentOverrides["seg_00001"] = SegmentSpeakerOverride(displayName: "田中さん", globalSpeakerId: speaker.id)
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            appConfig: makeAppConfig(minEnrollSpeechMs: 1_000),
            voiceprintStore: voiceprintStore,
            overrideEnrollmentExtractorFactory: { _ in extractor }
        )
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 8_000, speaker: .system, rawText: "hi", state: .raw)
        ]
        viewModel.diarizationTurns = [DiarizationTurn(slot: "spk_9", startMs: 0, endMs: 8_000)]
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()

        await viewModel.startRecording()
        await viewModel.endMeeting() // must not crash despite the stage 2 extraction throwing
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        let unchanged = await voiceprintStore.speaker(id: speaker.id)
        #expect(unchanged?.embedding == oldEmbedding)
        #expect(unchanged?.lastMatchedSessionId == nil)
    }

    @Test("overrideSegmentSpeaker(_:submission:) after Ended merges the new displayName into summary.state.json's participants (design section 20 §5.5)")
    func overrideSegmentSpeakerAfterEndedMergesParticipants() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline())

        await viewModel.startRecording()
        await viewModel.endMeeting()
        #expect(viewModel.recordingButtonState == .ended)

        await viewModel.overrideSegmentSpeaker(segmentId: "seg_00001", submission: .newName("愛子さん"))
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        let state = try #require(try await handle.readJSON(.summaryState, as: SummaryState.self))
        #expect(state.participants.contains("愛子さん"))
    }

    @Test("recoverIncompleteOverrideEnrollmentsIfNeeded() re-runs stages 1/2 for an Ended session's un-written-back new-name override, and is a no-op once it succeeds")
    func recoverIncompleteOverrideEnrollmentsIfNeededRecoversAndThenNoOps() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let extractor = FakeOverrideEnrollmentExtractor(behavior: .returns([0.5, 0.5]))

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            appConfig: makeAppConfig(minEnrollSpeechMs: 1_000),
            voiceprintStore: voiceprintStore,
            overrideEnrollmentExtractorFactory: { _ in extractor }
        )

        await viewModel.startRecording()
        await viewModel.endMeeting()

        // Simulates a `globalSpeakerId`-less new-name override left on disk as if the fire-and-forget
        // stage 2 task never got a chance to complete before the app last quit (design section 5.5).
        try await handle.updateSpeakerAssignments { assignments in
            assignments.segmentOverrides["seg_00001"] = SegmentSpeakerOverride(displayName: "花子さん", globalSpeakerId: nil)
        }
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 8_000, speaker: .system, rawText: "hi", state: .raw)
        ]
        viewModel.diarizationTurns = [DiarizationTurn(slot: "spk_9", startMs: 0, endMs: 8_000)]

        await viewModel.recoverIncompleteOverrideEnrollmentsIfNeeded()
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        let speakers = await voiceprintStore.listSpeakers()
        #expect(speakers.count == 1)
        #expect(speakers.first?.name == "花子さん")
        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.segmentOverrides["seg_00001"]?.globalSpeakerId == speakers.first?.id)
        viewModel.diarizationAssignments = persisted

        // A second recovery pass (a later re-open of the same Ended session) is a no-op: the override
        // now carries a globalSpeakerId, so the guard condition no longer holds.
        await viewModel.recoverIncompleteOverrideEnrollmentsIfNeeded()
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        let speakersAfterSecondRecovery = await voiceprintStore.listSpeakers()
        #expect(speakersAfterSecondRecovery.count == 1)
    }

    // MARK: - Review-fix regressions (code review of design section 20's M2 implementation)

    @Test("recoverIncompleteOverrideEnrollmentsIfNeeded() resolves an override name to an already-registered global speaker instead of registering a duplicate, even when knownVoiceprintSpeakers was never refreshed")
    func recoveryResolvesToAlreadyRegisteredSpeakerWithoutRefreshingCache() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let existingSpeaker = try await voiceprintStore.registerSpeaker(name: "花子さん", embedding: [1, 0])
        let extractor = FakeOverrideEnrollmentExtractor(behavior: .returns([0, 1]))

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            appConfig: makeAppConfig(minEnrollSpeechMs: 1_000),
            voiceprintStore: voiceprintStore,
            overrideEnrollmentExtractorFactory: { _ in extractor }
        )

        await viewModel.startRecording()
        await viewModel.endMeeting()

        // Simulates an override left un-written-back (design section 5.5) whose displayName names an
        // *already-registered* speaker -- but, unlike `recoveryRecoversAndThenNoOps` above, this
        // instance's `knownVoiceprintSpeakers` cache is never refreshed at all (reproducing a
        // freshly-reopened window whose `onAppear()` hasn't populated it yet, or a race between
        // `refreshKnownVoiceprintSpeakers()` and this recovery call). Before the fix, `resolveOverride
        // Identity` resolved against that empty cache and would register a duplicate "花子さん"; the fix
        // fetches `voiceprintStore.listSpeakers()` fresh instead.
        try await handle.updateSpeakerAssignments { assignments in
            assignments.segmentOverrides["seg_00001"] = SegmentSpeakerOverride(displayName: "花子さん", globalSpeakerId: nil)
        }
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 8_000, speaker: .system, rawText: "hi", state: .raw)
        ]
        viewModel.diarizationTurns = [DiarizationTurn(slot: "spk_9", startMs: 0, endMs: 8_000)]
        #expect(viewModel.knownVoiceprintSpeakers.isEmpty, "precondition: the picker cache must never have been populated for this instance")

        await viewModel.recoverIncompleteOverrideEnrollmentsIfNeeded()
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        // `resolveOverrideIdentity` resolves this straight to `.existingSpeaker(existingSpeaker.id)`
        // (design section 5.4's "identity の定義"), so stage 2 applies a moving-average update to that
        // same speaker instead of registering a new one -- there is deliberately no write-back onto the
        // override itself for this branch (only a brand-new registration writes back a globalSpeakerId,
        // per `persistOverrideEnrollment`'s doc comment): every future run resolves via this same fresh
        // name normalization, which is exactly what must never see an empty (unrefreshed) cache.
        let speakers = await voiceprintStore.listSpeakers()
        #expect(speakers.count == 1, "must resolve to the already-registered 花子さん, never register a duplicate")
        #expect(speakers.first?.id == existingSpeaker.id)

        let alpha = Float(VoiceprintStore.userCorrectionAlpha)
        let expected = zip([Float(1), 0], [Float(0), 1]).map { (1 - alpha) * $0 + alpha * $1 }
        #expect(speakers.first?.embedding == expected)
    }

    @Test("persistOverrideEnrollment skips registering a new speaker once a same-name override has already had a globalSpeakerId written back on disk (design section 20 §5.4/§8's re-entrancy guard)")
    func stage2SkipsRegistrationWhenSameNameAlreadyWonOnDisk() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let extractor = FakeOverrideEnrollmentExtractor(behavior: .returns([0.2, 0.2]))

        // seg_00099's override already carries a globalSpeakerId under the same trimmed name -- as if a
        // concurrent/earlier stage 2 run already won and wrote back before this run's own re-check runs
        // (design section 5.4/8). There is no controllable gate on `FakeOverrideEnrollmentExtractor` to
        // hold one extraction open while a second one completes first, so this drives the on-disk
        // re-check through the closest available seam instead: seg_00099 is never given a matching
        // `transcriptRows`/`diarizationTurns` entry, so `resolveWinner`/`scheduleOverrideEnrollment`
        // never itself processes it this run -- only `persistOverrideEnrollment`'s fresh
        // `sessionHandle.readSpeakerAssignments()` re-read ever observes it, exactly the disk state a
        // genuinely-concurrent winner would have left behind.
        try await handle.updateSpeakerAssignments { assignments in
            assignments.segmentOverrides["seg_00099"] = SegmentSpeakerOverride(displayName: "花子さん", globalSpeakerId: "already-won-speaker-id")
            assignments.segmentOverrides["seg_00001"] = SegmentSpeakerOverride(displayName: "花子さん", globalSpeakerId: nil)
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            appConfig: makeAppConfig(minEnrollSpeechMs: 1_000),
            voiceprintStore: voiceprintStore,
            overrideEnrollmentExtractorFactory: { _ in extractor }
        )
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 8_000, speaker: .system, rawText: "hi", state: .raw)
        ]
        viewModel.diarizationTurns = [DiarizationTurn(slot: "spk_9", startMs: 0, endMs: 8_000)]
        viewModel.diarizationAssignments = try await handle.readSpeakerAssignments()

        await viewModel.startRecording()
        await viewModel.endMeeting()
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        // seg_00001 resolves to a `.newName("花子さん")` identity (no globalSpeakerId of its own, and
        // "花子さん" isn't registered in voiceprintStore yet) -- its stage 2 must detect seg_00099's
        // already-written-back globalSpeakerId for the same trimmed name and skip registering a
        // duplicate speaker entirely.
        let speakers = await voiceprintStore.listSpeakers()
        #expect(speakers.isEmpty, "must not register a new speaker once a same-name override already won on disk")

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.segmentOverrides["seg_00001"]?.globalSpeakerId == nil, "the skipped attempt must not overwrite seg_00001")
    }

    @Test("two concurrent applyVoiceprintEnrollmentUpdates() calls for the same override-aggregate identity schedule only one stage 2 extraction (in-flight re-entrancy guard)")
    func concurrentApplyVoiceprintEnrollmentUpdatesCallsScheduleOnlyOneTaskPerIdentity() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let extractor = FakeOverrideEnrollmentExtractor(behavior: .returns([0.5, 0.5]))

        try await handle.updateSpeakerAssignments { assignments in
            assignments.segmentOverrides["seg_00001"] = SegmentSpeakerOverride(displayName: "太郎さん", globalSpeakerId: nil)
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            appConfig: makeAppConfig(minEnrollSpeechMs: 1_000),
            voiceprintStore: voiceprintStore,
            overrideEnrollmentExtractorFactory: { _ in extractor }
        )
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 8_000, speaker: .system, rawText: "hi", state: .raw)
        ]
        viewModel.diarizationTurns = [DiarizationTurn(slot: "spk_9", startMs: 0, endMs: 8_000)]
        let assignments = try await handle.readSpeakerAssignments()
        viewModel.diarizationAssignments = assignments

        // `OverrideEnrollmentSampleResolver.resolveSampleSlices(...)` requires at least one recording
        // segment to slice into (`SessionMeta.recordings`) -- start (but don't need to end) recording so
        // that exists, mirroring what `endMeeting()` would have already produced in the real Ended-time
        // caller this test's race is modeled on.
        await viewModel.startRecording()

        // Two calls racing each other for the exact same identity -- e.g. a post-Ended override edit
        // re-running enrollment while an earlier run's stage 2 extraction (tens of seconds on first
        // WeSpeaker model download) hasn't finished yet. Driven concurrently via `async let` (both
        // MainActor-isolated, but `applyVoiceprintEnrollmentUpdates(assignments:)` awaits
        // `sessionHandle.meta.recordings`/`voiceprintStore.listSpeakers()` along the way, so the two
        // calls genuinely interleave rather than running strictly one after the other).
        async let first: Void = viewModel.applyVoiceprintEnrollmentUpdates(assignments: assignments)
        async let second: Void = viewModel.applyVoiceprintEnrollmentUpdates(assignments: assignments)
        _ = await (first, second)
        await viewModel.waitForPendingOverrideEnrollmentTasks()

        #expect(await extractor.requestedSliceCounts.count == 1, "only one of the two racing calls may schedule a stage 2 extraction for this identity")
        #expect(await voiceprintStore.listSpeakers().count == 1)
    }

    // MARK: - Diarization regressions (review fixes, design section 5.1)

    /// Regression test for the review finding that reopening a Paused session and resuming into a
    /// brand-new `RealtimeDiarizationCoordinator` generation used to regress every already-resolved
    /// `system` row's label to `.systemFallback`, because `currentActiveRanges()` returned *only* the
    /// live coordinator's own snapshot (which structurally cannot cover ground from before that
    /// generation existed) instead of merging it with the backfill fallback range. Exercises
    /// `recomputeSpeakerLabels()`/`currentActiveRanges()` directly (bypassing the full
    /// onAppear()/resumeRecording() flow) since only the "old row + fresh coordinator generation"
    /// shape matters here, not how each side got populated.
    @Test("recomputeSpeakerLabels() keeps a pre-existing row's resolved label once a fresh coordinator generation begins a later segment")
    func recomputeSpeakerLabelsSurvivesAFreshCoordinatorGeneration() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline())

        // A row/turn/assignment already resolved before this coordinator generation ever existed
        // (e.g. backfilled via `initializeSpeakerLabelsFromBackfill()` after reopening a Paused
        // session's window, or produced by an earlier generation within the same coordinator).
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 500, endMs: 1_000, speaker: .system, rawText: "hi", state: .raw)
        ]
        viewModel.diarizationTurns = [DiarizationTurn(slot: "spk_1", startMs: 500, endMs: 1_000)]
        viewModel.diarizationAssignments = SpeakerAssignments(assignments: [
            "spk_1": SlotAssignment(displayName: "田中さん", assignedBy: .auto)
        ])
        viewModel.diarizationSegmentConfirmedAt["seg_00001"] = Date().addingTimeInterval(-10)

        await viewModel.recomputeSpeakerLabels()
        #expect(
            viewModel.speakerLabels["seg_00001"]?.label == .named("田中さん"),
            "sanity: resolves correctly before any coordinator exists this instance's lifetime"
        )

        // A brand-new coordinator opens a segment far later on the timeline -- exactly what
        // `resumeRecording()`'s `beginSegment(startMsOffset:hasSystemAudio:)` does once a Paused
        // window is reopened (design section 5.1's coordinator-recreation table).
        let coordinator = FakeDiarizationCoordinator()
        viewModel.diarizationCoordinator = coordinator
        await coordinator.beginSegment(startMsOffset: 5_000, hasSystemAudio: true)

        await viewModel.recomputeSpeakerLabels()

        #expect(
            viewModel.speakerLabels["seg_00001"]?.label == .named("田中さん"),
            "must not regress to .systemFallback just because the new coordinator generation's own active range (which only covers startMs 5_000 onward) doesn't -- and structurally cannot -- cover a row from before it existed"
        )
    }

    /// Regression test for the review finding that `initializeSpeakerLabelsFromBackfill()` anchored
    /// every not-yet-attributed `system` row's `confirmedAt` to "now". A reopened session that is not
    /// currently Recording never starts `startDiarizationLabelTicker()` (that only runs from
    /// `runRecordingSegmentStart`), so nothing would ever re-`recomputeSpeakerLabels()` later to let
    /// "now" age past `AttributionTuning.unattributedGraceMs` -- such a row stayed stuck displaying
    /// "(認識中…)" (`.recognizing`) forever instead of falling through to design section 5.3 rule 1's
    /// "Speaker ?" (`.unknown`). Anchoring to `Date.distantPast` instead makes it resolve immediately.
    @Test("initializeSpeakerLabelsFromBackfill() resolves a still-unattributed system row straight to .unknown, not stuck at .recognizing")
    func initializeSpeakerLabelsFromBackfillResolvesUnattributedRowsImmediately() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline())

        // A turn far outside this row's time range, persisted on disk -- just enough for
        // `currentActiveRanges()`'s "diarization ever ran this session" fallback to open an active range
        // covering the whole timeline, without itself attributing seg_00001 (keeping it `.unattributed`
        // so this test actually exercises the `confirmedAt`/grace-period branch, not the active-range
        // precondition).
        try await handle.appendDiarizationTurn(DiarizationTurn(slot: "spk_1", startMs: 5_000, endMs: 5_500))

        // A backfilled row from a past recording segment with no attributing turn -- e.g. a
        // BGM/notification sound, or simply a row diarization has not yet caught up to.
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 1_000, speaker: .system, rawText: "hi", state: .raw)
        ]

        await viewModel.initializeSpeakerLabelsFromBackfill()

        #expect(
            viewModel.speakerLabels["seg_00001"]?.label == .unknown,
            "a backfilled, still-unattributed row must resolve past the grace period immediately -- there is no live ticker (Recording-only) to ever advance a 'confirmedAt = now' anchor past it on its own"
        )
    }

    // MARK: - Speaker rename reflected in a reopened session (docs/design/23-speaker-settings-rename.md)

    /// End-to-end check for design 23's core requirement: a rename made in Settings' 話者 tab (which
    /// only ever touches `voiceprints.json`, never any session's `speaker_assignments.json`) must show
    /// up the next time a past session is reopened, even though that session's own
    /// `speaker_assignments.json` still has the display name it was assigned under.
    @Test("onAppear() resolves a past session's speaker label using the speaker's current name, not the frozen speaker_assignments.json snapshot")
    func onAppearReflectsARenameMadeInSettingsAfterTheMeetingEnded() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let speaker = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])

        // A past (already-Ended) meeting's persisted state: a system row attributed to a slot linked
        // to this global speaker, with the display name snapshot frozen at whatever it was named when
        // the assignment was written.
        try await handle.appendTranscriptSegment(source: .system, startMs: 0, endMs: 1_000, text: "hi", confidence: 0.9)
        try await handle.appendDiarizationTurn(DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1_000))
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(
                globalSpeakerId: speaker.id, displayName: "田中さん", assignedBy: .user
            )
        }

        // Renamed from Settings' 話者 tab sometime after this meeting ended -- no session file is
        // touched by this call, only `voiceprints.json`.
        try await voiceprintStore.renameSpeaker(id: speaker.id, name: "田中太郎")

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )
        await viewModel.onAppear()
        defer { viewModel.onDisappear() }

        #expect(
            viewModel.speakerLabels["seg_00001"]?.label == .named("田中太郎"),
            "reopening the session must resolve the current global name via knownVoiceprintSpeakers, not the stale displayName written into speaker_assignments.json at assignment time"
        )
    }

    /// Regression test for the review finding that a failed recording-segment start (`TranscriptPipeline
    /// .prepare()`/`AudioCapture.start()` throwing) left the diarization coordinator's active range
    /// open forever, since `rollbackFailedSegmentStart` never called `endSegment(reason:)` to close what
    /// `beginSegment` had already opened.
    @Test("rollbackFailedSegmentStart closes the diarization coordinator's open active range on an AudioCapture.start() failure")
    func rollbackFailedSegmentStartClosesDiarizationActiveRangeOnCaptureFailure() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let coordinator = FakeDiarizationCoordinator()
        let capture = FakeAudioCapture()
        capture.startError = FakeError()
        let pipeline = FakeTranscriptPipeline()
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: capture, pipeline: pipeline,
            diarizationCoordinatorFactory: { _ in coordinator }
        )

        await viewModel.startRecording()

        #expect(viewModel.recordingButtonState == .startRecording)
        #expect(
            await coordinator.endSegmentCalls == [.paused],
            "a failed AudioCapture.start() must close the active range beginSegment() already opened, mirroring a genuine pause -- otherwise a retried beginSegment appends a second open range, violating the 'only the last range is open' invariant"
        )
        let ranges = await coordinator.activeRangesSnapshot()
        #expect(ranges.last?.endMs != nil, "the range beginSegment() opened for the failed attempt must be closed, not left open")
    }

    /// Same regression as above, exercised via the other failure site (`TranscriptPipeline.prepare()`
    /// throwing, before `AudioCapture.start()` is ever called).
    @Test("rollbackFailedSegmentStart closes the diarization coordinator's open active range on a TranscriptPipeline.prepare() failure")
    func rollbackFailedSegmentStartClosesDiarizationActiveRangeOnPrepareFailure() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let coordinator = FakeDiarizationCoordinator()
        let pipeline = FakeTranscriptPipeline()
        pipeline.prepareError = FakeError()
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: pipeline,
            diarizationCoordinatorFactory: { _ in coordinator }
        )

        await viewModel.startRecording()

        #expect(viewModel.recordingButtonState == .startRecording)
        #expect(await coordinator.endSegmentCalls == [.paused])
    }

    /// Regression test for the review finding that `MeetingWorkspaceViewModel`'s diarization coordinator
    /// (and the `Task` subscribed to its `newTurns`) leaked on every window close: dropping the last
    /// strong reference to a `Task` value does not cancel the work it represents, so
    /// `startDiarizationTurnsSubscription(coordinator:)`'s unstructured `Task` -- which strong-captures
    /// `coordinator` and loops `for await turn in coordinator.newTurns` for as long as that stream stays
    /// open -- kept the coordinator (and its loaded models, in production) alive forever once nothing
    /// else referenced the `MeetingWorkspaceViewModel` itself.
    @Test("deallocating the ViewModel releases its diarization coordinator instead of leaking it")
    func viewModelDeallocationReleasesDiarizationCoordinator() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        weak var weakCoordinator: FakeDiarizationCoordinator?

        // Scoped to a closure so the only strong references left once it returns are `viewModel`'s own
        // (`diarizationCoordinator`/the subscription `Task`'s captured local) -- never an outer `let`
        // artificially keeping the coordinator alive for this test.
        var viewModel: MeetingWorkspaceViewModel? = {
            let coordinator = FakeDiarizationCoordinator()
            weakCoordinator = coordinator
            return makeViewModel(
                handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
                diarizationCoordinatorFactory: { _ in coordinator }
            )
        }()

        // Recording then pausing (never ending) mirrors kikimi.md 10 章's main "close a Paused window"
        // path -- the coordinator subscription is created by `startRecording()`, and closing the window
        // afterward is exactly what must not leak it.
        await viewModel?.startRecording()
        await viewModel?.pauseRecording()
        viewModel = nil

        // `Task.cancel()` is cooperative, not synchronous -- give the cancelled `for await` loop a beat
        // to actually unwind and release its captured `coordinator`.
        for _ in 0..<50 where weakCoordinator != nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(
            weakCoordinator == nil,
            "MeetingWorkspaceViewModel.deinit must cancel diarizationTurnsTask so the coordinator (and, in production, its loaded LS-EEND/WeSpeaker models) doesn't outlive the closed window"
        )
    }

    // MARK: - RefinementQueue wiring (docs/design/03-refinement-batch.md §3.3/§6/§7)

    private func makeRefinedSegment(
        id: String,
        startMs: Int = 0,
        endMs: Int = 500,
        refinedText: String?,
        error: String? = nil
    ) -> RefinedSegment {
        RefinedSegment(
            id: id,
            startMs: startMs,
            endMs: endMs,
            speaker: .mic,
            rawText: "raw-\(id)",
            refinedText: refinedText,
            error: error,
            refinedAt: Date(timeIntervalSince1970: 1_751_000_000),
            model: "test-model",
            batchId: "batch_00001"
        )
    }

    @Test("mergeRefinedState(_:into:) sets .refined/.refinedFailed by id, leaves unmatched rows at .raw")
    func mergeRefinedStatePureHelper() {
        let matchedSuccess = TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 500, speaker: .mic, rawText: "raw-1", state: .raw)
        let matchedFailure = TranscriptRowViewModel(id: "seg_00002", startMs: 500, endMs: 1_000, speaker: .mic, rawText: "raw-2", state: .refining)
        let unmatched = TranscriptRowViewModel(id: "seg_00003", startMs: 1_000, endMs: 1_500, speaker: .mic, rawText: "raw-3", state: .raw)

        let refined = [
            makeRefinedSegment(id: "seg_00001", refinedText: "整形済みテキスト"),
            makeRefinedSegment(id: "seg_00002", startMs: 500, endMs: 1_000, refinedText: nil, error: "missing from LLM response")
        ]

        let merged = MeetingWorkspaceViewModel.mergeRefinedState(refined, into: [matchedSuccess, matchedFailure, unmatched])

        #expect(merged[0].state == .refined("整形済みテキスト"))
        #expect(merged[1].state == .refinedFailed("missing from LLM response"))
        #expect(merged[2].state == .raw)
    }

    @Test("mergeRefinedState(_:into:) sets the leader row to .refined with the merged endMs, and covered rows to .mergedInto (§15.2.6)")
    func mergeRefinedStateHandlesMergedUnits() {
        let leaderRow = TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 500, speaker: .mic, rawText: "raw-1", state: .raw)
        let coveredRow = TranscriptRowViewModel(id: "seg_00002", startMs: 500, endMs: 900, speaker: .mic, rawText: "raw-2", state: .raw)
        let standaloneRow = TranscriptRowViewModel(id: "seg_00003", startMs: 1_000, endMs: 1_500, speaker: .mic, rawText: "raw-3", state: .raw)

        let mergedUnit = RefinedSegment(
            id: "seg_00001",
            startMs: 0,
            endMs: 1_000,
            speaker: .mic,
            rawText: "raw-1raw-2",
            refinedText: "整形済み結合テキスト",
            error: nil,
            refinedAt: Date(timeIntervalSince1970: 1_751_000_000),
            model: "test-model",
            batchId: "batch_00001",
            sourceSegIds: ["seg_00001", "seg_00002"]
        )

        let merged = MeetingWorkspaceViewModel.mergeRefinedState([mergedUnit], into: [leaderRow, coveredRow, standaloneRow])

        #expect(merged[0].state == .refined("整形済み結合テキスト"))
        #expect(merged[0].endMs == 1_000, "the leader row must adopt the merged unit's full endMs")
        #expect(merged[1].state == .mergedInto(leaderId: "seg_00001"))
        #expect(merged[1].endMs == 900, "endMs is untouched on the covered row (only the leader row's is updated)")
        #expect(merged[2].state == .raw)
    }

    @Test("mergeRefinedState(_:into:) is a pure passthrough when refinedSegments is empty")
    func mergeRefinedStateEmptyIsNoOp() {
        let rows = [TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 500, speaker: .mic, rawText: "raw-1", state: .raw)]
        #expect(MeetingWorkspaceViewModel.mergeRefinedState([], into: rows) == rows)
    }

    @Test("onAppear() merges refined.jsonl into transcriptRows' initial state (§6)")
    func onAppearMergesRefinedSegments() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "raw-1", confidence: 0.9)
        try await handle.appendTranscriptSegment(source: .mic, startMs: 500, endMs: 1_000, text: "raw-2", confidence: 0.9)
        try await handle.appendTranscriptSegment(source: .mic, startMs: 1_000, endMs: 1_500, text: "raw-3", confidence: 0.9)
        try await handle.appendRefinedSegment(makeRefinedSegment(id: "seg_00001", refinedText: "整形済み1"))
        try await handle.appendRefinedSegment(makeRefinedSegment(id: "seg_00002", startMs: 500, endMs: 1_000, refinedText: nil, error: "boom"))

        let viewModel = makeViewModel(handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline())
        await viewModel.onAppear()
        defer { viewModel.onDisappear() }

        #expect(viewModel.transcriptRows.first { $0.id == "seg_00001" }?.state == .refined("整形済み1"))
        #expect(viewModel.transcriptRows.first { $0.id == "seg_00002" }?.state == .refinedFailed("boom"))
        #expect(viewModel.transcriptRows.first { $0.id == "seg_00003" }?.state == .raw)
    }

    @Test("refinementQueueFactory is invoked at most once per ViewModel instance, reused across pause/resume/end")
    func refinementQueueFactoryInvokedOnce() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let fakeLLM = FakeRefinementLLM()
        var factoryCallCount = 0
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: capture, pipeline: pipeline,
            refinementQueueFactory: { sessionHandle in
                factoryCallCount += 1
                return RefinementQueue(sessionHandle: sessionHandle, llm: fakeLLM, config: .default, retryDelay: .zero)
            }
        )

        await viewModel.startRecording()
        await viewModel.pauseRecording()
        await viewModel.resumeRecording()
        await viewModel.endMeeting()

        #expect(factoryCallCount == 1, "runRecordingSegmentStart must reuse the same RefinementQueue instance across every Paused ⇄ Recording cycle (§7)")
    }

    @Test("a confirmed live segment is enqueued into the RefinementQueue and its row becomes .refining immediately (§3.3)")
    func liveSegmentEnqueuedIntoRefinementQueue() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let fakeLLM = FakeRefinementLLM()
        // Default `refinementConfig` in `makeViewModel(...)` has a 1000-segment batch size, so this
        // single segment stays `.refining` (queued, not yet batched) for the assertion below.
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline, refinementLLM: fakeLLM)

        await viewModel.startRecording()
        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)

        try await waitUntil { await viewModel.transcriptRows.first(where: { $0.id == segment.id })?.state == .refining }
        #expect(await fakeLLM.callCount == 0)

        await viewModel.endMeeting()
    }

    @Test("a completed refinement batch sets the matching row to .refined(text) via RefinementQueue.events")
    func batchCompletedSetsRefinedState() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let fakeLLM = FakeRefinementLLM()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline, refinementLLM: fakeLLM)

        await viewModel.startRecording()
        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)
        try await waitUntil { await viewModel.transcriptRows.first(where: { $0.id == segment.id })?.state == .refining }

        await fakeLLM.setResponse(#"{"segments":[{"id":"\#(segment.id)","refined_text":"整形済みテキスト"}]}"#)
        await viewModel.refinementQueue?.flush()

        try await waitUntil { await viewModel.transcriptRows.first(where: { $0.id == segment.id })?.state == .refined("整形済みテキスト") }

        await viewModel.endMeeting()
    }

    @Test("a joins_next=true merge sets the leader row to .refined(mergedText) with the unit's full endMs, and the covered row to .mergedInto (§15.2.6)")
    func batchCompletedMergeSetsLeaderAndCoveredRowStates() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let fakeLLM = FakeRefinementLLM()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline, refinementLLM: fakeLLM)

        await viewModel.startRecording()
        let first = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "そうですね次のスプリントで", confidence: 0.9)
        let second = try await handle.appendTranscriptSegment(source: .mic, startMs: 500, endMs: 1_000, text: "対応します", confidence: 0.9)
        pipeline.yield(first)
        pipeline.yield(second)
        try await waitUntil { await viewModel.transcriptRows.first(where: { $0.id == second.id })?.state == .refining }

        await fakeLLM.setResponse(
            """
            {"segments":[
              {"id":"\(first.id)","refined_text":"そうですね次のスプリントで","joins_next":true},
              {"id":"\(second.id)","refined_text":"対応します。","joins_next":false}
            ]}
            """
        )
        await viewModel.refinementQueue?.flush()

        try await waitUntil { await viewModel.transcriptRows.first(where: { $0.id == first.id })?.state == .refined("そうですね次のスプリントで対応します。") }

        let leaderRow = try #require(await viewModel.transcriptRows.first { $0.id == first.id })
        #expect(leaderRow.endMs == 1_000, "the leader row must adopt the merged unit's full endMs for playback (§15.2.6)")

        let coveredRow = try #require(await viewModel.transcriptRows.first { $0.id == second.id })
        #expect(coveredRow.state == .mergedInto(leaderId: first.id))

        let refined = try await handle.readRefinedSegments()
        #expect(refined.count == 1, "the two segments must collapse into a single derived unit in refined.jsonl")
        #expect(refined[0].sourceSegIds == [first.id, second.id])

        await viewModel.endMeeting()
    }

    /// Regression test for the review finding that a `joins_next=true` merge widening the leader
    /// row's `endMs` never re-ran `recomputeSpeakerLabels()`, leaving `speakerLabels[leaderId]
    /// ?.attributedSlots` (the rename popup's target list, `MeetingWorkspaceView.swift`'s
    /// `renameTargets`) stuck reflecting the narrower pre-merge range until some unrelated
    /// diarization trigger (a new turn, a rename, the grace-period ticker) happened to fire next.
    /// Here nothing else ever fires one: both rows are already resolved (`.mixed`, not
    /// `.recognizing`), so `startDiarizationLabelTicker()`'s per-second tick is a no-op the whole
    /// time. Without `applyRefinedUnit(_:)` recomputing labels itself, `attributedSlots` would stay
    /// `["spk_1"]` forever after the merge instead of widening to also cover `spk_2`.
    @Test("a joins_next=true merge on system rows immediately widens the leader's attributedSlots to cover the merged range, with no other diarization trigger")
    func batchCompletedMergeImmediatelyWidensAttributedSlots() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let fakeLLM = FakeRefinementLLM()
        let coordinator = FakeDiarizationCoordinator()
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: capture, pipeline: pipeline,
            diarizationCoordinatorFactory: { _ in coordinator },
            refinementLLM: fakeLLM
        )

        await viewModel.startRecording()
        let first = try await handle.appendTranscriptSegment(source: .system, startMs: 0, endMs: 500, text: "そうですね次のスプリントで", confidence: 0.9)
        let second = try await handle.appendTranscriptSegment(source: .system, startMs: 500, endMs: 1_000, text: "対応します", confidence: 0.9)
        pipeline.yield(first)
        pipeline.yield(second)
        try await waitUntil { await viewModel.transcriptRows.first(where: { $0.id == second.id })?.state == .refining }

        // Two evenly split slots, one per pre-merge segment -- `secondSpeakerMixedThreshold` (0.3)
        // makes a 50/50 split resolve to `.mixed`, so `attributedSlots` carries both ids once the
        // leader's range widens to cover both turns.
        await coordinator.emitTurn(DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 500))
        await coordinator.emitTurn(DiarizationTurn(slot: "spk_2", startMs: 500, endMs: 1_000))
        try await waitUntil { await viewModel.speakerLabels[first.id]?.attributedSlots == ["spk_1"] }

        await fakeLLM.setResponse(
            """
            {"segments":[
              {"id":"\(first.id)","refined_text":"そうですね次のスプリントで","joins_next":true},
              {"id":"\(second.id)","refined_text":"対応します。","joins_next":false}
            ]}
            """
        )
        await viewModel.refinementQueue?.flush()

        try await waitUntil { await viewModel.transcriptRows.first(where: { $0.id == first.id })?.endMs == 1_000 }

        try await waitUntil { await viewModel.speakerLabels[first.id]?.attributedSlots.sorted() == ["spk_1", "spk_2"] }

        await viewModel.endMeeting()
    }

    @Test("a refinement response missing the segment's id sets the matching row to .refinedFailed")
    func batchCompletedMissingIdSetsRefinedFailedState() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let fakeLLM = FakeRefinementLLM()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline, refinementLLM: fakeLLM)

        await viewModel.startRecording()
        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)
        try await waitUntil { await viewModel.transcriptRows.first(where: { $0.id == segment.id })?.state == .refining }

        await fakeLLM.setResponse(#"{"segments":[]}"#)
        await viewModel.refinementQueue?.flush()

        try await waitUntil { await viewModel.transcriptRows.first(where: { $0.id == segment.id })?.state == .refinedFailed("missing from LLM response") }

        await viewModel.endMeeting()
    }

    @Test("a fatal LLM failure emits .disabled and reverts .refining rows back to .raw (§5.2)")
    func fatalFailureRevertsRefiningRowsToRaw() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let fakeLLM = FakeRefinementLLM()
        await fakeLLM.setError(.cliNotFound(searchedPaths: []))
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline, refinementLLM: fakeLLM)

        await viewModel.startRecording()
        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)
        try await waitUntil { await viewModel.transcriptRows.first(where: { $0.id == segment.id })?.state == .refining }

        await viewModel.refinementQueue?.flush()

        try await waitUntil { await viewModel.transcriptRows.first(where: { $0.id == segment.id })?.state == .raw }

        await viewModel.endMeeting()
    }

    @Test("endMeeting() flushes the RefinementQueue and starts drain() fire-and-forget, never blocking on_session_end (§7)")
    func endMeetingDoesNotAwaitRefinementDrain() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)

        let capture = FakeAudioCapture()
        let pipeline = FakeTranscriptPipeline()
        let fakeLLM = FakeRefinementLLM()
        await fakeLLM.setResponse(#"{"segments":[]}"#)
        // Hold the refinement call open for the whole test instead of making it slow: what is under
        // test is that `endMeeting()` does not await it, and a gate states that directly. The
        // previous version slept 1.5s and asserted the call returned in under 1s -- a race between
        // two wall-clock durations that CI load decided.
        await fakeLLM.closeGate()
        let viewModel = makeViewModel(handle: handle, store: store, capture: capture, pipeline: pipeline, refinementLLM: fakeLLM)

        await viewModel.startRecording()
        let segment = try await handle.appendTranscriptSegment(source: .mic, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        pipeline.yield(segment)
        try await waitUntil { await viewModel.transcriptRows.first(where: { $0.id == segment.id })?.state == .refining }

        let start = ContinuousClock.now
        await viewModel.endMeeting()
        let elapsed = ContinuousClock.now - start

        // The gate is still shut, so `drain()` *cannot* have completed. Reaching this line at all is
        // therefore the proof: had `endMeeting()` awaited the drain, it would still be suspended and
        // this test would hang rather than fail. No duration is being judged.
        let refinedAfterEnd = try await handle.readRefinedSegments()
        #expect(
            refinedAfterEnd.isEmpty,
            "endMeeting() must not await RefinementQueue.drain() -- a slow/backlogged Haiku call must never delay on_session_end (kikimi.md 8.5 章)"
        )
        #expect(elapsed < .seconds(30), "hang guard, not a latency budget")
        #expect(viewModel.recordingButtonState == .ended)

        // Release the parked call so nothing is left suspended on a continuation after the test.
        await fakeLLM.openGate()

        // The queue itself is left alive (not discarded) so the slow batch still lands eventually.
        try await waitUntil(timeout: .seconds(5)) { await viewModel.transcriptRows.first(where: { $0.id == segment.id })?.state != .refining }
        #expect(await fakeLLM.callCount == 1)
    }

    // MARK: - Participant hints (docs/design/22-participant-hints.md, P2)

    @Test("addParticipantHint(.existingSpeaker:) adds the id to the roster, persists it, and resolves its name")
    func addParticipantHintExistingSpeakerAddsToRoster() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let alice = try await voiceprintStore.registerSpeaker(name: "Alice", embedding: [1, 0, 0])

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )
        await viewModel.onAppear()

        await viewModel.addParticipantHint(.existingSpeaker(globalSpeakerId: alice.id, name: "Alice"))

        #expect(viewModel.participantHints == [ParticipantHintItem(id: alice.id, name: "Alice")])
        let persisted = await handle.readParticipants()
        #expect(persisted.participantIds == [alice.id])
        #expect(persisted.removedParticipantIds.isEmpty)
    }

    @Test("addParticipantHint(.existingSpeaker:) already on the roster is a no-op (no duplicate persist/coordinator push)")
    func addParticipantHintExistingSpeakerAlreadyOnRosterIsNoOp() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        try await handle.updateParticipants { $0.addParticipant("alice-1") }

        let coordinator = FakeDiarizationCoordinator()
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            diarizationCoordinatorFactory: { _ in coordinator }
        )
        await viewModel.onAppear()
        #expect(viewModel.participantHints.map(\.id) == ["alice-1"])

        await viewModel.startRecording()
        let pushesAfterStart = await coordinator.participantHintUpdates.count
        #expect(pushesAfterStart == 1, "coordinator creation must push the roster exactly once")

        await viewModel.addParticipantHint(.existingSpeaker(globalSpeakerId: "alice-1", name: "Alice"))
        let pushesAfterAdd = await coordinator.participantHintUpdates.count
        #expect(pushesAfterAdd == pushesAfterStart, "an already-on-roster add must not push to the coordinator again")

        let persisted = await handle.readParticipants()
        #expect(persisted.participantIds == ["alice-1"])
    }

    @Test("addParticipantHint(.newName:) with no match registers a new speaker with an empty embedding and adds it")
    func addParticipantHintNewNameRegistersEmptyEmbeddingSpeaker() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )
        await viewModel.onAppear()

        await viewModel.addParticipantHint(.newName("新しい人"))

        let known = await voiceprintStore.listSpeakers()
        #expect(known.count == 1)
        #expect(known.first?.name == "新しい人")
        #expect(known.first?.embedding == [])

        let registeredId = try #require(known.first?.id)
        let persisted = await handle.readParticipants()
        #expect(persisted.participantIds == [registeredId])
        #expect(viewModel.participantHints == [ParticipantHintItem(id: registeredId, name: "新しい人")])
        #expect(viewModel.knownVoiceprintSpeakers.map(\.id) == [registeredId])
    }

    @Test("addParticipantHint(.newName:) whose trimmed text matches exactly one known speaker adds that speaker instead of registering a duplicate")
    func addParticipantHintNewNameResolvesToExistingSpeaker() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let tanaka = try await voiceprintStore.registerSpeaker(name: "田中さん", embedding: [1, 0])

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )
        await viewModel.onAppear()

        await viewModel.addParticipantHint(.newName(" 田中さん "))

        let known = await voiceprintStore.listSpeakers()
        #expect(known.count == 1, "must not register a duplicate speaker for a name that already resolves to exactly one known speaker")
        let persisted = await handle.readParticipants()
        #expect(persisted.participantIds == [tanaka.id])
    }

    @Test("addParticipantHint(.newName:) matching more than one known speaker is not added and sets participantHintError")
    func addParticipantHintNewNameAmbiguousIsNotAdded() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        _ = try await voiceprintStore.registerSpeaker(name: "同じ名前", embedding: [1, 0])
        _ = try await voiceprintStore.registerSpeaker(name: "同じ名前", embedding: [0, 1])

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )
        await viewModel.onAppear()

        await viewModel.addParticipantHint(.newName("同じ名前"))

        #expect(viewModel.participantHints.isEmpty)
        #expect(viewModel.participantHintError != nil)
        let persisted = await handle.readParticipants()
        #expect(persisted.participantIds.isEmpty)
        let known = await voiceprintStore.listSpeakers()
        #expect(known.count == 2, "an ambiguous name must never register a third duplicate speaker")
    }

    @Test("removeParticipantHint(id:) suppresses autoAddParticipantHint for the same id until a manual re-add")
    func removeParticipantHintSuppressesAutoAddUntilManualReAdd() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let alice = try await voiceprintStore.registerSpeaker(name: "Alice", embedding: [1, 0])

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )
        await viewModel.onAppear()
        await viewModel.addParticipantHint(.existingSpeaker(globalSpeakerId: alice.id, name: "Alice"))

        await viewModel.removeParticipantHint(id: alice.id)
        var persisted = await handle.readParticipants()
        #expect(persisted.participantIds.isEmpty)
        #expect(persisted.removedParticipantIds == [alice.id])
        #expect(viewModel.participantHints.isEmpty)

        await viewModel.autoAddParticipantHint(globalSpeakerId: alice.id)
        persisted = await handle.readParticipants()
        #expect(persisted.participantIds.isEmpty, "a removed id must not be silently re-added by an auto-add hook")
        #expect(persisted.removedParticipantIds == [alice.id])

        // The suggest box's own manual re-add still moves it back (design section 4.1's "手動再追加").
        await viewModel.addParticipantHint(.existingSpeaker(globalSpeakerId: alice.id, name: "Alice"))
        persisted = await handle.readParticipants()
        #expect(persisted.participantIds == [alice.id])
        #expect(persisted.removedParticipantIds.isEmpty)
    }

    @Test("applyRename(.existingSpeaker:) auto-adds the picked speaker to the participant roster")
    func applyRenameExistingSpeakerAutoAddsParticipant() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let dave = try await voiceprintStore.registerSpeaker(name: "Dave", embedding: [1, 0])

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )
        await viewModel.onAppear()

        await viewModel.applyRename(slot: "spk_1", submission: .existingSpeaker(globalSpeakerId: dave.id, name: "Dave"))

        let persisted = await handle.readParticipants()
        #expect(persisted.participantIds == [dave.id])
        #expect(viewModel.participantHints == [ParticipantHintItem(id: dave.id, name: "Dave")])
    }

    @Test("applyRename(.newName:) with a captured slot embedding auto-adds the newly-registered speaker to the roster")
    func applyRenameRegisterAndAssignAutoAddsParticipant() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(embedding: [0.1, 0.2, 0.3])
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )
        await viewModel.onAppear()

        await viewModel.applyRename(slot: "spk_1", submission: .newName("Eve"))

        let persistedAssignments = try await handle.readSpeakerAssignments()
        let registeredId = try #require(persistedAssignments.assignments["spk_1"]?.globalSpeakerId)
        let persistedParticipants = await handle.readParticipants()
        #expect(persistedParticipants.participantIds == [registeredId])
    }

    @Test("applyRename(.newName:)'s on-demand WAV fallback auto-adds the newly-registered speaker only once extraction succeeds")
    func applyRenameWavFallbackAutoAddsParticipantOnSuccess() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let fallbackEmbedding: [Float] = [0.4, 0.5, 0.6]
        let fallbackExtractor = FakeVoiceprintWavFallbackExtractor(behavior: .returns(fallbackEmbedding))

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore,
            voiceprintWavFallbackExtractorFactory: { _ in fallbackExtractor }
        )
        await viewModel.onAppear()

        await viewModel.applyRename(slot: "spk_2", submission: .newName("佐藤さん"))
        // No captured embedding at rename time -- `.localOnly` never auto-adds on its own.
        var participants = await handle.readParticipants()
        #expect(participants.participantIds.isEmpty)

        await viewModel.voiceprintWavFallbackTask?.value

        let persistedAssignments = try await handle.readSpeakerAssignments()
        let registeredId = try #require(persistedAssignments.assignments["spk_2"]?.globalSpeakerId)
        participants = await handle.readParticipants()
        #expect(participants.participantIds == [registeredId])
    }

    @Test("overrideSegmentSpeaker(.existingSpeaker:) auto-adds the picked speaker to the participant roster")
    func overrideSegmentSpeakerExistingSpeakerAutoAddsParticipant() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let frank = try await voiceprintStore.registerSpeaker(name: "Frank", embedding: [1, 0])

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )
        await viewModel.onAppear()

        await viewModel.overrideSegmentSpeaker(segmentId: "seg_00001", submission: .existingSpeaker(globalSpeakerId: frank.id, name: "Frank"))

        let persisted = await handle.readParticipants()
        #expect(persisted.participantIds == [frank.id])
    }

    @Test("an accepted auto voiceprint match (assignmentUpdates) never auto-adds to the participant roster")
    func autoVoiceprintMatchNeverAutoAddsParticipant() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))
        let grace = try await voiceprintStore.registerSpeaker(name: "Grace", embedding: [1, 0])

        let coordinator = FakeDiarizationCoordinator()
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            diarizationCoordinatorFactory: { _ in coordinator },
            voiceprintStore: voiceprintStore
        )
        await viewModel.startRecording()

        // Simulates the coordinator's own live extraction having just written an accepted `.auto`
        // match directly to disk (this fake never touches the filesystem itself), then signaling it
        // the same way `RealtimeDiarizationCoordinator` does via `assignmentUpdates`.
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(
                globalSpeakerId: grace.id, displayName: "Grace", assignedBy: .auto, embedding: [1, 0]
            )
        }
        await coordinator.emitAssignmentUpdate()
        try await waitUntil { await viewModel.diarizationAssignments.assignments["spk_1"]?.displayName == "Grace" }

        #expect(viewModel.participantHints.isEmpty, "an auto voiceprint match must never auto-add to the roster on its own (design section 4.2)")
        let persisted = await handle.readParticipants()
        #expect(persisted.participantIds.isEmpty)
    }

    @Test("diarizationCoordinatorIfEnabled() pushes the existing roster at creation time, and again on every subsequent roster mutation")
    func coordinatorReceivesRosterPushAtCreationAndOnMutation() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        try await handle.updateParticipants { $0.addParticipant("pre-existing-id") }
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))

        let coordinator = FakeDiarizationCoordinator()
        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            diarizationCoordinatorFactory: { _ in coordinator },
            voiceprintStore: voiceprintStore
        )

        await viewModel.startRecording()
        var pushes = await coordinator.participantHintUpdates
        #expect(pushes == [["pre-existing-id"]])

        let alice = try await voiceprintStore.registerSpeaker(name: "Alice", embedding: [1, 0])
        await viewModel.addParticipantHint(.existingSpeaker(globalSpeakerId: alice.id, name: "Alice"))

        pushes = await coordinator.participantHintUpdates
        #expect(pushes.last == Set(["pre-existing-id", alice.id]))
    }

    @Test(
        """
        addParticipantHint(_:) with no live coordinator runs the ViewModel-side rematch (design section 3.2): \
        an eligible anonymous slot becomes accepted, .user/already-named/off-roster slots stay untouched, \
        and speakerLabels reflects the change
        """
    )
    func addParticipantHintRunsViewModelSideRematchWhenCoordinatorAbsent() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))

        let aliceEmbedding: [Float] = [1, 0, 0]
        let bobEmbedding: [Float] = [0, 1, 0]
        let alice = try await voiceprintStore.registerSpeaker(name: "Alice", embedding: aliceEmbedding)
        _ = try await voiceprintStore.registerSpeaker(name: "Bob", embedding: bobEmbedding)

        let segment = try await handle.appendTranscriptSegment(source: .system, startMs: 0, endMs: 500, text: "hello", confidence: 0.9)
        try await handle.appendDiarizationTurn(DiarizationTurn(slot: "spk_1", startMs: 0, endMs: 1_000))
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(embedding: aliceEmbedding)
            assignments.assignments["spk_2"] = SlotAssignment(
                globalSpeakerId: "some-other-id", displayName: "Charlie", assignedBy: .user, embedding: aliceEmbedding
            )
            assignments.assignments["spk_3"] = SlotAssignment(
                globalSpeakerId: alice.id, displayName: "Existing", assignedBy: .auto, embedding: aliceEmbedding
            )
            assignments.assignments["spk_4"] = SlotAssignment(embedding: bobEmbedding)
        }

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )
        await viewModel.onAppear()

        #expect(viewModel.speakerLabels[segment.id]?.label == .anonymous(slotNumber: 1))
        #expect(viewModel.diarizationCoordinator == nil, "coordinator must not exist before recording starts")

        await viewModel.addParticipantHint(.existingSpeaker(globalSpeakerId: alice.id, name: "Alice"))

        #expect(viewModel.diarizationCoordinator == nil, "the ViewModel-side rematch fallback must not create a coordinator")
        #expect(viewModel.speakerLabels[segment.id]?.label == .named("Alice"))

        let persisted = try await handle.readSpeakerAssignments()
        #expect(persisted.assignments["spk_1"]?.displayName == "Alice")
        #expect(persisted.assignments["spk_1"]?.globalSpeakerId == alice.id)
        #expect(persisted.assignments["spk_1"]?.assignedBy == .auto)
        #expect(persisted.assignments["spk_2"]?.displayName == "Charlie", ".user slot must never be overwritten by the ViewModel-side rematch")
        #expect(persisted.assignments["spk_2"]?.assignedBy == .user)
        #expect(persisted.assignments["spk_3"]?.displayName == "Existing", "an already-named slot must not be rewound by rematch")
        #expect(persisted.assignments["spk_4"]?.displayName == nil, "a slot matching an off-roster speaker must stay anonymous (closed-set)")
    }

    @Test(
        """
        rematchAnonymousSlotsViaViewModel(allowedSpeakerIds:) re-reads participants.json immediately \
        before each write instead of trusting its own `allowedSpeakerIds` argument (design section 3.1's \
        write-time roster re-verification guard, applied to the section 3.2 ViewModel-side rematch \
        fallback): a speaker removed from the roster after the pass's filtering argument was computed \
        must not be written, even though `allowedSpeakerIds` still names it (rejectedByRoster)
        """
    )
    func viewModelRematchRejectsWriteWhenRosterChangedAfterFilterArgumentWasComputed() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let voiceprintStore = VoiceprintStore(fileURL: makeTemporaryDirectory().appendingPathComponent("voiceprints.json"))

        let aliceEmbedding: [Float] = [1, 0, 0]
        let bobEmbedding: [Float] = [0, 1, 0]
        let alice = try await voiceprintStore.registerSpeaker(name: "Alice", embedding: aliceEmbedding)
        let bob = try await voiceprintStore.registerSpeaker(name: "Bob", embedding: bobEmbedding)

        // An eligible anonymous slot: extracted embedding, never named, never `.user`-assigned.
        try await handle.updateSpeakerAssignments { assignments in
            assignments.assignments["spk_1"] = SlotAssignment(embedding: aliceEmbedding)
        }

        // Simulate the roster having already swapped Alice out for Bob by the time this rematch pass's
        // write is about to happen -- e.g. `removeParticipantHint(id:)` ran concurrently with an
        // in-flight rematch pass that had already computed its `allowedSpeakerIds` argument from the old
        // roster. The roster stays non-empty (still closed-set) throughout, so this isn't the "last
        // participant removed -> falls back to open-set" case design section 3 explicitly allows.
        try await handle.updateParticipants { $0.addParticipant(alice.id) }
        try await handle.updateParticipants {
            $0.removeParticipant(alice.id)
            $0.addParticipant(bob.id)
        }
        #expect(await handle.readParticipants().participantIds == [bob.id])

        let viewModel = makeViewModel(
            handle: handle, store: store, capture: FakeAudioCapture(), pipeline: FakeTranscriptPipeline(),
            voiceprintStore: voiceprintStore
        )
        await viewModel.onAppear()

        // Pass the *stale* roster (still containing Alice) as the filtering argument -- exactly what a
        // caller that read `allowedSpeakerIds` before the concurrent removal above would have computed.
        // `findMatchCandidate`/`VoiceprintMatchPolicy.decide` will accept this candidate; the write-time
        // guard must still reject it because `participants.json` no longer contains Alice.
        await viewModel.rematchAnonymousSlotsViaViewModel(allowedSpeakerIds: [alice.id])

        let persisted = try await handle.readSpeakerAssignments()
        #expect(
            persisted.assignments["spk_1"]?.displayName == nil,
            "a candidate no longer in the freshly-read roster must not be written, even though the caller's allowedSpeakerIds argument still named it"
        )
        #expect(persisted.assignments["spk_1"]?.assignedBy != .auto)
    }

    // MARK: - Test helpers

    private static func baseMeta(id: String) -> SessionMeta {
        SessionMeta(
            id: id,
            title: "",
            titleAutoGenerated: true,
            titleAutoNamedOnce: false,
            titleProposal: nil,
            state: .draft,
            createdAt: Date(timeIntervalSince1970: 1_751_000_000),
            startedAt: nil,
            endedAt: nil,
            durationMs: 0,
            basedOnSession: nil,
            segmentCount: 0,
            refinedCount: 0,
            appVersion: "0.1.0"
        )
    }

    private static func segment(id: String, startMs: Int) -> TranscriptSegment {
        TranscriptSegment(id: id, startMs: startMs, endMs: startMs + 500, speaker: .mic, text: "text-\(id)", confidence: 0.9)
    }

    /// `docs/design/13-speaker-diarization.md` section 5's counterpart to `segment(id:startMs:)`: a
    /// `system`-source segment, the only speaker kind diarization ever attributes.
    private static func systemSegment(id: String, startMs: Int, endMs: Int? = nil) -> TranscriptSegment {
        TranscriptSegment(id: id, startMs: startMs, endMs: endMs ?? startMs + 500, speaker: .system, text: "text-\(id)", confidence: 0.9)
    }

    /// Polls `condition` on the main actor until it becomes `true` or `timeout` elapses. Used instead
    /// of a fixed `Task.sleep` for the `liveSegments` forwarding test, since the forwarding `Task`
    /// (`startLiveSegmentSubscription`) processes the yielded segments asynchronously.
    ///
    /// The timeout is a hang guard only -- the poll returns as soon as the condition holds, so a
    /// generous ceiling costs a passing test nothing. It is 10s rather than 2s because a runner
    /// sharing few cores with ~1,900 parallel tests overran the tighter bound (same cause as
    /// `1cea520`'s window-suite polls).
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
}

// MARK: - MeetingWorkspaceViewModel.nextRecordingButtonState (pure, section 10.1/12)

@Suite("MeetingWorkspaceViewModel.nextRecordingButtonState")
struct NextRecordingButtonStateTests {
    @Test("startRecording -> disabledOtherRecording when a different session starts recording")
    func transitionsToDisabledOtherRecording() {
        let next = MeetingWorkspaceViewModel.nextRecordingButtonState(
            current: .startRecording,
            selfSessionId: "self",
            activeSessionId: "other"
        )
        #expect(next == .disabledOtherRecording(otherSessionId: "other"))
    }

    @Test("disabledOtherRecording -> startRecording once no session is recording")
    func transitionsBackToStartRecordingWhenNilActiveSessionId() {
        let next = MeetingWorkspaceViewModel.nextRecordingButtonState(
            current: .disabledOtherRecording(otherSessionId: "other"),
            selfSessionId: "self",
            activeSessionId: nil
        )
        #expect(next == .startRecording)
    }

    @Test("disabledOtherRecording -> disabledOtherRecording(otherSessionId:) updates when a different other session takes over")
    func updatesOtherSessionIdWhileStillDisabled() {
        let next = MeetingWorkspaceViewModel.nextRecordingButtonState(
            current: .disabledOtherRecording(otherSessionId: "other-1"),
            selfSessionId: "self",
            activeSessionId: "other-2"
        )
        #expect(next == .disabledOtherRecording(otherSessionId: "other-2"))
    }

    @Test("activeSessionId matching self never produces disabledOtherRecording against itself")
    func selfSessionIdDoesNotDisableSelf() {
        let next = MeetingWorkspaceViewModel.nextRecordingButtonState(
            current: .startRecording,
            selfSessionId: "self",
            activeSessionId: "self"
        )
        #expect(next == .startRecording)
    }

    @Test("self-driven states (.starting/.recording/.pausing/.resuming/.ending/.ended) are left untouched by external notifications")
    func selfDrivenStatesUnaffected() {
        #expect(
            MeetingWorkspaceViewModel.nextRecordingButtonState(current: .starting, selfSessionId: "self", activeSessionId: "other")
                == .starting
        )
        #expect(
            MeetingWorkspaceViewModel.nextRecordingButtonState(
                current: .recording(elapsedSeconds: 5),
                selfSessionId: "self",
                activeSessionId: "other"
            ) == .recording(elapsedSeconds: 5)
        )
        #expect(
            MeetingWorkspaceViewModel.nextRecordingButtonState(current: .pausing, selfSessionId: "self", activeSessionId: "other")
                == .pausing
        )
        #expect(
            MeetingWorkspaceViewModel.nextRecordingButtonState(current: .resuming, selfSessionId: "self", activeSessionId: "other")
                == .resuming
        )
        #expect(
            MeetingWorkspaceViewModel.nextRecordingButtonState(current: .ending, selfSessionId: "self", activeSessionId: "other")
                == .ending
        )
        #expect(
            MeetingWorkspaceViewModel.nextRecordingButtonState(current: .ended, selfSessionId: "self", activeSessionId: "other")
                == .ended
        )
    }

    @Test("paused -> pausedDisabledOtherRecording when a different session starts recording, and back once it clears")
    func pausedTransitionsToPausedDisabledOtherRecording() {
        let disabled = MeetingWorkspaceViewModel.nextRecordingButtonState(
            current: .paused(elapsedSeconds: 42),
            selfSessionId: "self",
            activeSessionId: "other"
        )
        #expect(disabled == .pausedDisabledOtherRecording(elapsedSeconds: 42, otherSessionId: "other"))

        let reenabled = MeetingWorkspaceViewModel.nextRecordingButtonState(
            current: disabled,
            selfSessionId: "self",
            activeSessionId: nil
        )
        #expect(reenabled == .paused(elapsedSeconds: 42))
    }

    @Test("pausedDisabledOtherRecording's otherSessionId updates when a different other session takes over, preserving elapsedSeconds")
    func pausedDisabledOtherRecordingUpdatesOtherSessionId() {
        let next = MeetingWorkspaceViewModel.nextRecordingButtonState(
            current: .pausedDisabledOtherRecording(elapsedSeconds: 42, otherSessionId: "other-1"),
            selfSessionId: "self",
            activeSessionId: "other-2"
        )
        #expect(next == .pausedDisabledOtherRecording(elapsedSeconds: 42, otherSessionId: "other-2"))
    }
}

// MARK: - MeetingWorkspaceViewModel.cumulativeElapsedSeconds / initialRecordingButtonState
//
// Both take an explicit `now:`, so these cover the elapsed-time arithmetic deterministically -- the
// coverage the flaky-fix deliberately moved *out* of the recording-lifecycle tests above, whose
// `makeViewModel` now freezes the clock (see its `frozenNow` comment) and can therefore only ever
// observe `elapsedSeconds: 0`.

@Suite("MeetingWorkspaceViewModel elapsed-time arithmetic")
@MainActor
struct MeetingWorkspaceViewModelElapsedTimeTests {
    private static let sessionStart = Date(timeIntervalSince1970: 1_751_000_000)

    private static func meta(
        state: SessionState,
        durationMs: Int,
        recordings: [RecordingSegment]
    ) -> SessionMeta {
        SessionMeta(
            id: "session-elapsed",
            title: "",
            titleAutoGenerated: true,
            titleAutoNamedOnce: false,
            titleProposal: nil,
            state: state,
            createdAt: sessionStart,
            startedAt: sessionStart,
            endedAt: nil,
            durationMs: durationMs,
            recordings: recordings,
            basedOnSession: nil,
            segmentCount: 0,
            refinedCount: 0,
            appVersion: "0.1.0"
        )
    }

    private static func closedSegment(index: Int, startOffsetSeconds: Int, lengthSeconds: Int) -> RecordingSegment {
        RecordingSegment(
            index: index,
            startedAt: sessionStart.addingTimeInterval(Double(startOffsetSeconds)),
            endedAt: sessionStart.addingTimeInterval(Double(startOffsetSeconds + lengthSeconds)),
            startMsOffset: 0
        )
    }

    private static func openSegment(index: Int, startOffsetSeconds: Int) -> RecordingSegment {
        RecordingSegment(
            index: index,
            startedAt: sessionStart.addingTimeInterval(Double(startOffsetSeconds)),
            endedAt: nil,
            startMsOffset: 0
        )
    }

    @Test("with no recording segments at all, elapsed falls back to meta.durationMs")
    func noSegmentsUsesDurationMs() {
        let elapsed = MeetingWorkspaceViewModel.cumulativeElapsedSeconds(
            for: Self.meta(state: .paused, durationMs: 90_000, recordings: []),
            now: Self.sessionStart.addingTimeInterval(10_000)
        )
        #expect(elapsed == 90)
    }

    @Test("with every segment closed, elapsed is meta.durationMs alone -- `now` never enters the sum")
    func closedSegmentsIgnoreNow() {
        let meta = Self.meta(
            state: .paused,
            durationMs: 125_000,
            recordings: [Self.closedSegment(index: 0, startOffsetSeconds: 0, lengthSeconds: 125)]
        )
        // Two wildly different `now`s, same answer: a paused session's clock does not keep running.
        #expect(MeetingWorkspaceViewModel.cumulativeElapsedSeconds(for: meta, now: Self.sessionStart) == 125)
        #expect(
            MeetingWorkspaceViewModel.cumulativeElapsedSeconds(
                for: meta, now: Self.sessionStart.addingTimeInterval(9_999)
            ) == 125
        )
    }

    @Test("with an open segment, elapsed is prior segments' durationMs plus time since that segment started")
    func openSegmentAddsTimeSinceItStarted() {
        let meta = Self.meta(
            state: .recording,
            durationMs: 60_000,
            recordings: [
                Self.closedSegment(index: 0, startOffsetSeconds: 0, lengthSeconds: 60),
                Self.openSegment(index: 1, startOffsetSeconds: 300)
            ]
        )
        // 60s of closed segment + 7s into the open one.
        let elapsed = MeetingWorkspaceViewModel.cumulativeElapsedSeconds(
            for: meta, now: Self.sessionStart.addingTimeInterval(307)
        )
        #expect(elapsed == 67)
    }

    @Test("a `now` before the open segment even started clamps to 0 rather than going negative")
    func nowBeforeSegmentStartClampsToZero() {
        let meta = Self.meta(
            state: .recording,
            durationMs: 0,
            recordings: [Self.openSegment(index: 0, startOffsetSeconds: 300)]
        )
        let elapsed = MeetingWorkspaceViewModel.cumulativeElapsedSeconds(
            for: meta, now: Self.sessionStart.addingTimeInterval(120)
        )
        #expect(elapsed == 0)
    }

    @Test("initialRecordingButtonState maps each hydrated meta.state, carrying the elapsed seconds it derives")
    func initialRecordingButtonStatePerSessionState() {
        let openRecordings = [Self.openSegment(index: 0, startOffsetSeconds: 0)]
        let now = Self.sessionStart.addingTimeInterval(42)

        #expect(
            MeetingWorkspaceViewModel.initialRecordingButtonState(
                for: Self.meta(state: .draft, durationMs: 0, recordings: []), now: now
            ) == .startRecording
        )
        #expect(
            MeetingWorkspaceViewModel.initialRecordingButtonState(
                for: Self.meta(state: .recording, durationMs: 0, recordings: openRecordings), now: now
            ) == .recording(elapsedSeconds: 42)
        )
        #expect(
            MeetingWorkspaceViewModel.initialRecordingButtonState(
                for: Self.meta(
                    state: .paused,
                    durationMs: 30_000,
                    recordings: [Self.closedSegment(index: 0, startOffsetSeconds: 0, lengthSeconds: 30)]
                ),
                now: now
            ) == .paused(elapsedSeconds: 30)
        )
        #expect(
            MeetingWorkspaceViewModel.initialRecordingButtonState(
                for: Self.meta(state: .ended, durationMs: 30_000, recordings: []), now: now
            ) == .ended
        )
    }
}
