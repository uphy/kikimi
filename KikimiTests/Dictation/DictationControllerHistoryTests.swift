import Foundation
import Testing

@testable import Kikimi

// MARK: - FakeControllerHistoryStore

/// Deterministic, file-I/O-free stand-in for `DictationHistoryStore`
/// (`docs/design/29-dictation-history.md` §5.1's "テスト seam"), tracking every call
/// `DictationController`'s history wiring makes so these tests can assert on call counts/arguments
/// without touching disk. Declared separately from `DictationHistoryViewModelTests`' own fake of the
/// same name since that one lives in a different file and never exercises `beginEntry`/`finalize`
/// (only `listEntries`/`readEntry`/`deleteEntry`, which is that type's own concern).
private actor FakeControllerHistoryStore: DictationHistoryStoring {
    private(set) var beginEntryStartedAts: [Date] = []
    private(set) var deletedIds: [String] = []
    private(set) var finalizeCalls: [(handle: DictationHistoryStore.EntryHandle, entry: DictationHistoryEntry, maxEntries: Int)] = []

    var beginEntryError: Error?
    private var nextEntrySeq = 0

    func beginEntry(startedAt: Date) throws -> DictationHistoryStore.EntryHandle {
        beginEntryStartedAts.append(startedAt)
        if let beginEntryError {
            throw beginEntryError
        }
        nextEntrySeq += 1
        let id = "entry-\(nextEntrySeq)"
        return DictationHistoryStore.EntryHandle(
            id: id,
            directoryURL: URL(fileURLWithPath: "/dev/null/\(id)", isDirectory: true),
            audioFileURL: URL(fileURLWithPath: "/dev/null/\(id)/audio.wav")
        )
    }

    func deleteEntry(id: String) {
        deletedIds.append(id)
    }

    func finalize(handle: DictationHistoryStore.EntryHandle, entry: DictationHistoryEntry, maxEntries: Int) throws {
        finalizeCalls.append((handle, entry, maxEntries))
    }

    func listEntries() -> [DictationHistoryStore.ListItem] { [] }

    func readEntry(id: String) throws -> DictationHistoryEntry {
        throw ControllerHistoryTestStubError()
    }

    func deleteAll() throws {}

    func setBeginEntryError(_ error: Error?) {
        beginEntryError = error
    }
}

private struct ControllerHistoryTestStubError: Error {}

// MARK: - FakeControllerLLM

/// Deterministic, network-free stand-in for `LLMCompleting`, mirroring `DictationRefinerTests`'
/// own `FakeLLM` (declared separately since that one is `private` to its own file).
private actor FakeControllerLLM: LLMCompleting {
    var response: String?
    var error: LLMClientError?

    func complete<T: Decodable & Sendable>(_ request: LLMRequest) async throws -> LLMResult<T> {
        if let error {
            throw error
        }
        guard let response, let data = response.data(using: .utf8) else {
            throw LLMClientError.missingStructuredOutput(raw: "no fake response registered")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(T.self, from: data)
        return LLMResult(value: value, usage: .zero, respondedModel: nil)
    }

    func completeRaw(_ request: LLMRequest) async throws -> LLMResult<Data> {
        throw ControllerHistoryTestStubError()
    }

    func setResponse(_ value: String) {
        response = value
    }

    func setError(_ value: LLMClientError) {
        error = value
    }
}

// MARK: - FakeControllerSttBackend

/// Deterministic, network-free stand-in for `SttStreamingBackend`, mirroring
/// `DictationTranscriberTests`' own fake (declared separately since that one is `private` to its
/// own file). Only `finish()`'s return value/error matters for these tests -- `handleHotkeyUp()`
/// never calls `processChunk`/`reset` itself.
private actor FakeControllerSttBackend: SttStreamingBackend {
    nonisolated let chunkSampleCount = 1

    private var finishText = ""
    private var finishError: Error?

    func setFinishText(_ text: String) {
        finishText = text
    }

    func setFinishError(_ error: Error?) {
        finishError = error
    }

    func processChunk(_ samples: [Float]) async throws -> String { "" }

    func finish() async throws -> String {
        if let finishError {
            throw finishError
        }
        return finishText
    }

    func reset() async {}
}

private struct ControllerFinishError: Error, Equatable {}

// MARK: - SpyDictationInserter

/// Call-recording stand-in for `DictationInserter` (`DictationInserter.swift`'s `DictationInserting`
/// seam): mirrors `insert(text:capturedTarget:method:)`'s real `FrontmostGuard.decide` logic so the
/// `abortedAndStashed` vs. `inserted` outcome tests below still exercise that branch, but never
/// synthesizes the real `CGEvent` `⌘V`/pasteboard write -- driving `handleHotkeyUp()` against the
/// production `DictationInserter` would otherwise actually paste each fixture string into whatever
/// app is frontmost on the machine running the test suite. Not `private`: `DictationControllerTwoPass
/// Tests` and `DictationControllerLiveHUDTests` inject it too (mirrors `SpyDictationLiveHUD` above).
@MainActor
final class SpyDictationInserter: DictationInserting {
    private(set) var insertedTexts: [String] = []
    private(set) var insertedMethods: [DictationInsertMethod] = []
    private(set) var performInsertedTexts: [String] = []

    func captureTarget() -> FrontmostGuard.Target {
        DictationInserter().captureTarget()
    }

    func insert(text: String, capturedTarget: FrontmostGuard.Target, method: DictationInsertMethod) -> DictationInsertOutcome {
        guard !text.isEmpty else {
            return .inserted
        }
        switch FrontmostGuard.decide(captured: capturedTarget, current: captureTarget()) {
        case .insert:
            insertedTexts.append(text)
            insertedMethods.append(method)
            return .inserted
        case .abortAndStash:
            return .abortedAndStashed
        }
    }

    func performInsert(_ text: String, method: DictationInsertMethod) {
        performInsertedTexts.append(text)
    }
}

// MARK: - DictationControllerHistoryTests

/// `docs/design/29-dictation-history.md` §9's layer-1 "`DictationController` 配線" test list, using
/// `FakeControllerHistoryStore` in place of `DictationHistoryStore` (§5.1's DI seam). Every test
/// drives `handleHotkeyUp()` directly after `simulateCapturing(...)` rather than going through
/// `handleHotkeyDown()`'s real `DictationAudioInput`/mic dependency (see that method's doc comment,
/// and `DictationAudioInputTests`' identical rationale) -- `beginHistoryEntryIfNeeded(historyEnabled:
/// startedAt:)` is tested separately/directly for the `handleHotkeyDown()` half of the wiring.
@Suite("DictationController history wiring")
@MainActor
struct DictationControllerHistoryTests {
    private func makeConfig(refine: Bool = false, historyEnabled: Bool = true, maxEntries: Int = 100) -> DictationConfig {
        DictationConfig(
            enabled: true,
            insertMethod: .pasteboard,
            micDeviceUID: "",
            language: "",
            refine: refine,
            model: "claude-haiku-4-5-20251001",
            refineTimeoutMs: 3_000,
            context: .default,
            history: DictationHistoryConfig(enabled: historyEnabled, maxEntries: maxEntries)
        )
    }

    private func makeController(
        config: DictationConfig,
        historyStore: any DictationHistoryStoring,
        llm: FakeControllerLLM = FakeControllerLLM(),
        // No trailing-capture wait by default (word-drop fix 1's default is 280ms in production);
        // `trailingCaptureDelayGateTest` below overrides this to assert the wait actually happens.
        trailingCaptureDelayMs: UInt64 = 0
    ) -> DictationController {
        DictationController(
            dictationConfigProvider: { config },
            sttConfigProvider: { SttConfig.default },
            watchersDefaultModelProvider: { "claude-haiku-4-5-20251001" },
            glossaryProvider: { [] },
            glossaryCategoriesProvider: { [] },
            transcriberFactory: { _ in throw ControllerHistoryTestStubError() },
            refiner: DictationRefiner(llm: llm),
            historyStore: historyStore,
            // `simulateCapturing(...)` materializes the HUD via this factory (design 32 §3.1);
            // a spy keeps these tests window-free rather than creating a real NSPanel.
            liveHUDPanelFactory: { SpyDictationLiveHUD() },
            // Never let `handleHotkeyUp()`'s real insert path fire a `CGEvent` `⌘V`/pasteboard
            // write against whatever app is frontmost while this test suite runs.
            inserterFactory: { SpyDictationInserter() },
            trailingCaptureDelayMs: trailingCaptureDelayMs
        )
    }

    /// Polls `predicate` until it becomes `true` or `timeout` elapses (mirrors
    /// `DictationHistoryViewModelTests.waitUntil`) -- used to wait for `handleHotkeyUp()`'s internal
    /// `Task`/the fire-and-forget `finalize` child `Task` to run.
    private func waitUntil(timeout: Duration = .seconds(10), predicate: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let finalResult = await predicate()
        #expect(finalResult, "condition did not become true within \(timeout)")
    }

    /// A `FrontmostGuard.Target` that `DictationInserter.insert(text:capturedTarget:method:)` will
    /// judge as still-focused (`FrontmostGuard.decide` returns `.insert`) when captured "now", by
    /// re-reading the real frontmost app via `DictationInserter().captureTarget()` -- nothing else in
    /// this single-process test run changes the frontmost app between capture and insertion.
    private func realCapturedTarget() -> FrontmostGuard.Target {
        DictationInserter().captureTarget()
    }

    /// A target guaranteed to make `FrontmostGuard.decide` return `.abortAndStash`: `pid` can never
    /// match whatever process is really frontmost during a test run.
    private func mismatchedCapturedTarget() -> FrontmostGuard.Target {
        FrontmostGuard.Target(bundleId: "com.example.stale", pid: -999, element: nil)
    }

    // MARK: - handleHotkeyDown half: beginHistoryEntryIfNeeded (§4.4)

    @Test("beginHistoryEntryIfNeeded does not call beginEntry when history.enabled is false")
    func beginHistoryEntryIfNeededSkipsWhenDisabled() async {
        let store = FakeControllerHistoryStore()
        let controller = makeController(config: makeConfig(historyEnabled: false), historyStore: store)

        let recordingURL = await controller.beginHistoryEntryIfNeeded(historyEnabled: false, startedAt: Date())

        #expect(recordingURL == nil)
        let calls = await store.beginEntryStartedAts
        #expect(calls.isEmpty)
    }

    @Test("beginHistoryEntryIfNeeded calls beginEntry and returns the entry's audioFileURL when enabled")
    func beginHistoryEntryIfNeededCallsBeginEntryWhenEnabled() async {
        let store = FakeControllerHistoryStore()
        let controller = makeController(config: makeConfig(historyEnabled: true), historyStore: store)
        let startedAt = Date(timeIntervalSince1970: 1_000)

        let recordingURL = await controller.beginHistoryEntryIfNeeded(historyEnabled: true, startedAt: startedAt)

        #expect(recordingURL != nil)
        #expect(recordingURL?.lastPathComponent == "audio.wav")
        let calls = await store.beginEntryStartedAts
        #expect(calls == [startedAt])
    }

    @Test("beginHistoryEntryIfNeeded degrades to no history (nil recordingURL) when beginEntry throws")
    func beginHistoryEntryIfNeededDegradesOnBeginEntryFailure() async {
        let store = FakeControllerHistoryStore()
        await store.setBeginEntryError(ControllerHistoryTestStubError())
        let controller = makeController(config: makeConfig(historyEnabled: true), historyStore: store)

        let recordingURL = await controller.beginHistoryEntryIfNeeded(historyEnabled: true, startedAt: Date())

        #expect(recordingURL == nil)
    }

    // MARK: - handleHotkeyUp early returns all funnel into discardActiveHistoryEntry() (DH10)

    @Test("the guard-let transcriber/capturedTarget failure discards the active history entry")
    func guardLetFailureDiscardsHistoryEntry() async throws {
        let store = FakeControllerHistoryStore()
        let controller = makeController(config: makeConfig(), historyStore: store)
        let handle = DictationHistoryStore.EntryHandle(
            id: "entry-1",
            directoryURL: URL(fileURLWithPath: "/dev/null/entry-1", isDirectory: true),
            audioFileURL: URL(fileURLWithPath: "/dev/null/entry-1/audio.wav")
        )
        // `transcriber: nil` while `state == .capturing` reproduces the guard-let failure at the top
        // of `handleHotkeyUp()`'s `Task` (`DictationController.swift`'s "guard let transcriber =
        // self.transcriber, let capturedTarget = self.capturedTarget else" branch).
        controller.simulateCapturing(
            transcriber: nil,
            capturedTarget: realCapturedTarget(),
            historyEntryHandle: handle,
            historyEntryRecordedAt: Date()
        )

        controller.handleHotkeyUp()

        try await waitUntil { controller.state == .idle }
        let deletedIds = await store.deletedIds
        #expect(deletedIds == ["entry-1"])
        let finalizeCalls = await store.finalizeCalls
        #expect(finalizeCalls.isEmpty)
    }

    @Test("a finishUtterance() throw discards the active history entry")
    func finishUtteranceThrowDiscardsHistoryEntry() async throws {
        let store = FakeControllerHistoryStore()
        let controller = makeController(config: makeConfig(), historyStore: store)
        let backend = FakeControllerSttBackend()
        await backend.setFinishError(ControllerFinishError())
        let handle = DictationHistoryStore.EntryHandle(
            id: "entry-2",
            directoryURL: URL(fileURLWithPath: "/dev/null/entry-2", isDirectory: true),
            audioFileURL: URL(fileURLWithPath: "/dev/null/entry-2/audio.wav")
        )
        controller.simulateCapturing(
            transcriber: DictationTranscriber(backend: backend),
            capturedTarget: realCapturedTarget(),
            historyEntryHandle: handle,
            historyEntryRecordedAt: Date()
        )

        controller.handleHotkeyUp()

        try await waitUntil { controller.state == .idle }
        let deletedIds = await store.deletedIds
        #expect(deletedIds == ["entry-2"])
        let finalizeCalls = await store.finalizeCalls
        #expect(finalizeCalls.isEmpty)
    }

    @Test("an empty trimmed raw text (DH10) discards the active history entry")
    func emptyTrimmedRawDiscardsHistoryEntry() async throws {
        let store = FakeControllerHistoryStore()
        let controller = makeController(config: makeConfig(), historyStore: store)
        let backend = FakeControllerSttBackend()
        await backend.setFinishText("   ")
        let handle = DictationHistoryStore.EntryHandle(
            id: "entry-3",
            directoryURL: URL(fileURLWithPath: "/dev/null/entry-3", isDirectory: true),
            audioFileURL: URL(fileURLWithPath: "/dev/null/entry-3/audio.wav")
        )
        controller.simulateCapturing(
            transcriber: DictationTranscriber(backend: backend),
            capturedTarget: realCapturedTarget(),
            historyEntryHandle: handle,
            historyEntryRecordedAt: Date()
        )

        controller.handleHotkeyUp()

        try await waitUntil { controller.state == .idle }
        let deletedIds = await store.deletedIds
        #expect(deletedIds == ["entry-3"])
        let finalizeCalls = await store.finalizeCalls
        #expect(finalizeCalls.isEmpty)
    }

    @Test("history.enabled == false for the whole utterance means no historyEntryHandle, so no discard/finalize call happens")
    func noActiveHandleMeansNoStoreCallsAtAll() async throws {
        let store = FakeControllerHistoryStore()
        let controller = makeController(config: makeConfig(historyEnabled: false), historyStore: store)
        let backend = FakeControllerSttBackend()
        await backend.setFinishText("   ") // empty-after-trim, hits the DH10 early return too
        controller.simulateCapturing(
            transcriber: DictationTranscriber(backend: backend),
            capturedTarget: realCapturedTarget(),
            historyEntryHandle: nil,
            historyEntryRecordedAt: nil
        )

        controller.handleHotkeyUp()

        try await waitUntil { controller.state == .idle }
        let deletedIds = await store.deletedIds
        let finalizeCalls = await store.finalizeCalls
        #expect(deletedIds.isEmpty)
        #expect(finalizeCalls.isEmpty)
    }

    // MARK: - Insert outcome / DH11

    @Test("an aborted-and-stashed insert still finalizes the history entry with insert_outcome == abortedAndStashed")
    func abortedAndStashedStillFinalizes() async throws {
        let store = FakeControllerHistoryStore()
        let controller = makeController(config: makeConfig(refine: false, maxEntries: 42), historyStore: store)
        let backend = FakeControllerSttBackend()
        await backend.setFinishText("次の会議は木曜です")
        let handle = DictationHistoryStore.EntryHandle(
            id: "entry-4",
            directoryURL: URL(fileURLWithPath: "/dev/null/entry-4", isDirectory: true),
            audioFileURL: URL(fileURLWithPath: "/dev/null/entry-4/audio.wav")
        )
        let recordedAt = Date(timeIntervalSince1970: 5_000)
        controller.simulateCapturing(
            transcriber: DictationTranscriber(backend: backend),
            capturedTarget: mismatchedCapturedTarget(),
            historyEntryHandle: handle,
            historyEntryRecordedAt: recordedAt
        )

        controller.handleHotkeyUp()

        try await waitUntil {
            let calls = await store.finalizeCalls
            return !calls.isEmpty
        }
        let calls = await store.finalizeCalls
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.entry.insertOutcome == .abortedAndStashed)
        #expect(call.entry.finalText == "次の会議は木曜です")
        #expect(call.entry.rawText == "次の会議は木曜です")
        #expect(call.entry.refineOutcome == .disabled)
        #expect(call.entry.recordedAt == recordedAt)
        #expect(call.maxEntries == 42)
        #expect(call.handle.id == "entry-4")
        let deletedIds = await store.deletedIds
        #expect(deletedIds.isEmpty, "an aborted-and-stashed insert must finalize, not discard")
    }

    // MARK: - Trailing capture grace period (word-drop fix 1)

    @Test("a non-zero trailingCaptureDelayMs delays the tail (finalize) by at least that long")
    func trailingCaptureDelayDelaysTail() async throws {
        let store = FakeControllerHistoryStore()
        let configuredDelayMs: UInt64 = 150
        let controller = makeController(config: makeConfig(refine: false), historyStore: store, trailingCaptureDelayMs: configuredDelayMs)
        let backend = FakeControllerSttBackend()
        await backend.setFinishText("語尾が切れないことを確認します")
        let handle = DictationHistoryStore.EntryHandle(
            id: "entry-delay",
            directoryURL: URL(fileURLWithPath: "/dev/null/entry-delay", isDirectory: true),
            audioFileURL: URL(fileURLWithPath: "/dev/null/entry-delay/audio.wav")
        )
        controller.simulateCapturing(
            transcriber: DictationTranscriber(backend: backend),
            capturedTarget: realCapturedTarget(),
            historyEntryHandle: handle,
            historyEntryRecordedAt: Date()
        )

        let start = ContinuousClock.now
        controller.handleHotkeyUp()

        try await waitUntil {
            let calls = await store.finalizeCalls
            return !calls.isEmpty
        }
        let elapsed = ContinuousClock.now - start
        // The tail's `Task.sleep(for: .milliseconds(trailingCaptureDelayMs))` runs before
        // `finishUtterance()`/`finalize`, so the wall-clock time to finalize can never be shorter
        // than the configured delay -- proving `handleHotkeyUp()` actually honors it rather than
        // stopping the mic (and racing to finalize) immediately at key-up.
        #expect(elapsed >= .milliseconds(configuredDelayMs))
    }

    // MARK: - Mic device (design 29 §3.2 addendum)

    @Test("the mic device resolved at handleHotkeyDown() time is threaded through to the finalized entry")
    func finalizedEntryCarriesCapturedMicDeviceInfo() async throws {
        let store = FakeControllerHistoryStore()
        let controller = makeController(config: makeConfig(refine: false), historyStore: store)
        let backend = FakeControllerSttBackend()
        await backend.setFinishText("マイクのテスト")
        let handle = DictationHistoryStore.EntryHandle(
            id: "entry-mic",
            directoryURL: URL(fileURLWithPath: "/dev/null/entry-mic", isDirectory: true),
            audioFileURL: URL(fileURLWithPath: "/dev/null/entry-mic/audio.wav")
        )
        controller.simulateCapturing(
            transcriber: DictationTranscriber(backend: backend),
            capturedTarget: realCapturedTarget(),
            historyEntryHandle: handle,
            historyEntryRecordedAt: Date(),
            capturedMicDeviceInfo: DictationMicDeviceResolver.MicDeviceInfo(name: "USB Mic", uid: "usb-mic-uid")
        )

        controller.handleHotkeyUp()

        try await waitUntil {
            let calls = await store.finalizeCalls
            return !calls.isEmpty
        }
        let calls = await store.finalizeCalls
        let call = try #require(calls.first)
        #expect(call.entry.micDeviceName == "USB Mic")
        #expect(call.entry.micDeviceUID == "usb-mic-uid")
    }

    @Test("no captured mic device info (e.g. system default input, no config override) finalizes with both fields nil")
    func finalizedEntryHasNilMicDeviceInfoWhenNoneWasCaptured() async throws {
        let store = FakeControllerHistoryStore()
        let controller = makeController(config: makeConfig(refine: false), historyStore: store)
        let backend = FakeControllerSttBackend()
        await backend.setFinishText("マイクのテスト")
        let handle = DictationHistoryStore.EntryHandle(
            id: "entry-mic-nil",
            directoryURL: URL(fileURLWithPath: "/dev/null/entry-mic-nil", isDirectory: true),
            audioFileURL: URL(fileURLWithPath: "/dev/null/entry-mic-nil/audio.wav")
        )
        controller.simulateCapturing(
            transcriber: DictationTranscriber(backend: backend),
            capturedTarget: realCapturedTarget(),
            historyEntryHandle: handle,
            historyEntryRecordedAt: Date()
        )

        controller.handleHotkeyUp()

        try await waitUntil {
            let calls = await store.finalizeCalls
            return !calls.isEmpty
        }
        let calls = await store.finalizeCalls
        let call = try #require(calls.first)
        #expect(call.entry.micDeviceName == nil)
        #expect(call.entry.micDeviceUID == nil)
    }

    // MARK: - Empty refinement (§3.2)

    @Test("a refine call that succeeds but trims to empty is recorded as fallback + \"empty refinement\", with llmUsage kept")
    func emptyRefinementRecordsFallbackWithUsage() async throws {
        let store = FakeControllerHistoryStore()
        let llm = FakeControllerLLM()
        await llm.setResponse(#"{"refined_text":"   "}"#)
        let controller = makeController(config: makeConfig(refine: true), historyStore: store, llm: llm)
        let backend = FakeControllerSttBackend()
        await backend.setFinishText("次の会議は木曜です")
        let handle = DictationHistoryStore.EntryHandle(
            id: "entry-5",
            directoryURL: URL(fileURLWithPath: "/dev/null/entry-5", isDirectory: true),
            audioFileURL: URL(fileURLWithPath: "/dev/null/entry-5/audio.wav")
        )
        controller.simulateCapturing(
            transcriber: DictationTranscriber(backend: backend),
            capturedTarget: realCapturedTarget(),
            historyEntryHandle: handle,
            historyEntryRecordedAt: Date()
        )

        controller.handleHotkeyUp()

        try await waitUntil {
            let calls = await store.finalizeCalls
            return !calls.isEmpty
        }
        let calls = await store.finalizeCalls
        let call = try #require(calls.first)
        #expect(call.entry.refineOutcome == .fallback)
        #expect(call.entry.refineError == "empty refinement")
        #expect(call.entry.finalText == "次の会議は木曜です", "finalText must fall back to the raw text, unchanged from D2's existing behavior")
        #expect(call.entry.refinedText == nil, "refinedText stays nil outside the .success case")
        #expect(call.entry.llmUsage != nil, "the LLM call did succeed and cost tokens, so usage must still be recorded")
        #expect(call.entry.llmUsage?.purpose == "dictation")
    }

    @Test("a successful refinement is recorded as success with refinedText == finalText")
    func successfulRefinementRecordsSuccess() async throws {
        let store = FakeControllerHistoryStore()
        let llm = FakeControllerLLM()
        await llm.setResponse(#"{"refined_text":"次の会議は木曜日です。"}"#)
        let controller = makeController(config: makeConfig(refine: true), historyStore: store, llm: llm)
        let backend = FakeControllerSttBackend()
        await backend.setFinishText("次の会議は木曜です")
        let handle = DictationHistoryStore.EntryHandle(
            id: "entry-6",
            directoryURL: URL(fileURLWithPath: "/dev/null/entry-6", isDirectory: true),
            audioFileURL: URL(fileURLWithPath: "/dev/null/entry-6/audio.wav")
        )
        controller.simulateCapturing(
            transcriber: DictationTranscriber(backend: backend),
            capturedTarget: realCapturedTarget(),
            historyEntryHandle: handle,
            historyEntryRecordedAt: Date()
        )

        controller.handleHotkeyUp()

        try await waitUntil {
            let calls = await store.finalizeCalls
            return !calls.isEmpty
        }
        let calls = await store.finalizeCalls
        let call = try #require(calls.first)
        #expect(call.entry.refineOutcome == .success)
        #expect(call.entry.refinedText == "次の会議は木曜日です。")
        #expect(call.entry.finalText == "次の会議は木曜日です。")
        #expect(call.entry.llmUsage != nil)
    }

    @Test("refine disabled (D1) is recorded as .disabled with no refinedText/llmUsage")
    func refineDisabledRecordsDisabledOutcome() async throws {
        let store = FakeControllerHistoryStore()
        let controller = makeController(config: makeConfig(refine: false), historyStore: store)
        let backend = FakeControllerSttBackend()
        await backend.setFinishText("そのまま挿入します")
        let handle = DictationHistoryStore.EntryHandle(
            id: "entry-7",
            directoryURL: URL(fileURLWithPath: "/dev/null/entry-7", isDirectory: true),
            audioFileURL: URL(fileURLWithPath: "/dev/null/entry-7/audio.wav")
        )
        controller.simulateCapturing(
            transcriber: DictationTranscriber(backend: backend),
            capturedTarget: realCapturedTarget(),
            historyEntryHandle: handle,
            historyEntryRecordedAt: Date()
        )

        controller.handleHotkeyUp()

        try await waitUntil {
            let calls = await store.finalizeCalls
            return !calls.isEmpty
        }
        let calls = await store.finalizeCalls
        let call = try #require(calls.first)
        #expect(call.entry.refineOutcome == .disabled)
        #expect(call.entry.refinedText == nil)
        #expect(call.entry.llmUsage == nil)
        #expect(call.entry.finalText == "そのまま挿入します")
    }
}
