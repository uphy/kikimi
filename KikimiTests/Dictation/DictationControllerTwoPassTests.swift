import Foundation
import Testing

@testable import Kikimi

// MARK: - FakeBatchTranscriber

/// Deterministic, FluidAudio-free stand-in for `DictationBatchTranscribing`
/// (`docs/design/31-dictation-two-pass-decode.md` §3.1's test seam).
private actor FakeBatchTranscriber: DictationBatchTranscribing {
    private(set) var transcribeCallSampleCounts: [Int] = []
    private var result: Result<String, Error>

    init(text: String) {
        result = .success(text)
    }

    init(error: Error) {
        result = .failure(error)
    }

    func transcribe(samples: [Float]) async throws -> String {
        transcribeCallSampleCounts.append(samples.count)
        return try result.get()
    }
}

// MARK: - FakeTwoPassHistoryStore

/// Mirrors `DictationControllerHistoryTests`' `FakeControllerHistoryStore` (declared separately
/// since that one is `private` to its own file); only the members these tests assert on are tracked.
private actor FakeTwoPassHistoryStore: DictationHistoryStoring {
    private(set) var deletedIds: [String] = []
    private(set) var finalizedEntries: [DictationHistoryEntry] = []

    func beginEntry(startedAt: Date) throws -> DictationHistoryStore.EntryHandle {
        throw TwoPassTestStubError()
    }

    func deleteEntry(id: String) {
        deletedIds.append(id)
    }

    func finalize(handle: DictationHistoryStore.EntryHandle, entry: DictationHistoryEntry, maxEntries: Int) throws {
        finalizedEntries.append(entry)
    }

    func listEntries() -> [DictationHistoryStore.ListItem] { [] }

    func readEntry(id: String) throws -> DictationHistoryEntry {
        throw TwoPassTestStubError()
    }

    func deleteAll() throws {}
}

// MARK: - FakeTwoPassSttBackend

/// Mirrors `DictationControllerHistoryTests`' `FakeControllerSttBackend` (same
/// private-per-file convention); only `finish()` matters here.
private actor FakeTwoPassSttBackend: SttStreamingBackend {
    nonisolated let chunkSampleCount = 1

    private var finishText = ""

    func setFinishText(_ text: String) {
        finishText = text
    }

    func processChunk(_ samples: [Float]) async throws -> String { "" }

    func finish() async throws -> String { finishText }

    func reset() async {}
}

private struct TwoPassTestStubError: Error {}

// MARK: - DictationControllerTwoPassTests

/// `docs/design/31-dictation-two-pass-decode.md` §7's layer-1 "`DictationController` 配線" list:
/// key-up raw selection wiring (TP2/TP7) via `simulateCapturing` + `handleHotkeyUp()`, and the
/// warm/release transitions of `handleConfigChanged(enabled:twoPassDecode:)` (TP5/TP9).
@Suite("DictationController two-pass wiring")
@MainActor
struct DictationControllerTwoPassTests {
    /// One second of silence -- comfortably above `DictationBatchTranscriber.minimumSampleCount`.
    private static let oneSecondOfSamples = [Float](repeating: 0, count: 16_000)

    private func makeConfig(twoPassDecode: Bool = true) -> DictationConfig {
        DictationConfig(
            enabled: true,
            insertMethod: .pasteboard,
            micDeviceUID: "",
            language: "",
            twoPassDecode: twoPassDecode,
            refine: false,
            model: "",
            refineTimeoutMs: 3_000
        )
    }

    private func makeController(
        config: DictationConfig,
        historyStore: any DictationHistoryStoring,
        batchTranscriberFactory: @escaping (String, String) async throws -> any DictationBatchTranscribing = { _, _ in
            throw TwoPassTestStubError()
        }
    ) -> DictationController {
        DictationController(
            dictationConfigProvider: { config },
            sttConfigProvider: { SttConfig.default },
            watchersDefaultModelProvider: { "claude-haiku-4-5-20251001" },
            glossaryProvider: { [] },
            glossaryCategoriesProvider: { [] },
            // `docs/design/42-prompt-overrides.md` §7.2: `makeConfig` always sets `refine: false`
            // above, so `refineForHistory` never actually reaches these -- stubbed anyway (matching
            // every other provider on this type) so a future `refine: true` here can't silently
            // fall through to `PromptStore.shared`'s real `~/.config/kikimi/prompts/` access.
            dictationGlobalBodyProvider: { "" },
            dictationAppBundleIDsProvider: { [] },
            dictationAppBodyProvider: { _ in "" },
            dictationGlossaryHeaderProvider: { GlossaryRenderer.defaultHeader },
            transcriberFactory: { _ in throw TwoPassTestStubError() },
            batchTranscriberFactory: batchTranscriberFactory,
            historyStore: historyStore,
            // `simulateCapturing(...)` materializes the HUD via this factory (design 32 §3.1);
            // a spy keeps these tests window-free rather than creating a real NSPanel.
            liveHUDPanelFactory: { SpyDictationLiveHUD() },
            // Never let `handleHotkeyUp()`'s real insert path fire a `CGEvent` `⌘V`/pasteboard
            // write against whatever app is frontmost while this test suite runs.
            inserterFactory: { SpyDictationInserter() },
            // No trailing-capture wait in tests (word-drop fix 1's default is 280ms in production).
            trailingCaptureDelayMs: 0
        )
    }

    private func waitUntil(timeout: Duration = .seconds(10), predicate: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let finalResult = await predicate()
        #expect(finalResult, "condition did not become true within \(timeout)")
    }

    private func realCapturedTarget() -> FrontmostGuard.Target {
        DictationInserter().captureTarget()
    }

    private func makeHandle(id: String) -> DictationHistoryStore.EntryHandle {
        DictationHistoryStore.EntryHandle(
            id: id,
            directoryURL: URL(fileURLWithPath: "/dev/null/\(id)", isDirectory: true),
            audioFileURL: URL(fileURLWithPath: "/dev/null/\(id)/audio.wav")
        )
    }

    private func driveUtterance(
        controller: DictationController,
        store: FakeTwoPassHistoryStore,
        streamingText: String,
        batchTranscriber: (any DictationBatchTranscribing)?,
        recordedSamples: [Float],
        entryId: String
    ) async throws {
        let backend = FakeTwoPassSttBackend()
        await backend.setFinishText(streamingText)
        controller.simulateCapturing(
            transcriber: DictationTranscriber(backend: backend),
            capturedTarget: realCapturedTarget(),
            historyEntryHandle: makeHandle(id: entryId),
            historyEntryRecordedAt: Date(),
            batchTranscriber: batchTranscriber,
            recordedSamples: recordedSamples
        )

        controller.handleHotkeyUp()

        try await waitUntil {
            let finalized = await store.finalizedEntries
            let deleted = await store.deletedIds
            return !finalized.isEmpty || !deleted.isEmpty
        }
    }

    // MARK: - Key-up raw selection (TP2/TP7)

    @Test("a successful batch decode confirms the batch text and records the streaming diagnostic")
    func batchSuccessConfirmsBatchText() async throws {
        let store = FakeTwoPassHistoryStore()
        let controller = makeController(config: makeConfig(), historyStore: store)
        let batch = FakeBatchTranscriber(text: "今日はレグ環境の構築を行います")

        try await driveUtterance(
            controller: controller,
            store: store,
            streamingText: "はレグ環境の構築を行います",
            batchTranscriber: batch,
            recordedSamples: Self.oneSecondOfSamples,
            entryId: "entry-batch"
        )

        let entry = try #require(await store.finalizedEntries.first)
        #expect(entry.rawText == "今日はレグ環境の構築を行います")
        #expect(entry.rawSource == .batch)
        #expect(entry.streamingText == "はレグ環境の構築を行います")
        #expect(entry.finalText == "今日はレグ環境の構築を行います")
        let sampleCounts = await batch.transcribeCallSampleCounts
        #expect(sampleCounts == [16_000])
    }

    @Test("a batch decode failure falls back to the streaming text with no diagnostic")
    func batchFailureFallsBackToStreaming() async throws {
        let store = FakeTwoPassHistoryStore()
        let controller = makeController(config: makeConfig(), historyStore: store)
        let batch = FakeBatchTranscriber(error: TwoPassTestStubError())

        try await driveUtterance(
            controller: controller,
            store: store,
            streamingText: "ストリーミングの結果",
            batchTranscriber: batch,
            recordedSamples: Self.oneSecondOfSamples,
            entryId: "entry-batch-throw"
        )

        let entry = try #require(await store.finalizedEntries.first)
        #expect(entry.rawText == "ストリーミングの結果")
        #expect(entry.rawSource == .streaming)
        #expect(entry.streamingText == nil)
    }

    @Test("a whitespace-only batch result falls back to the streaming text")
    func emptyBatchResultFallsBackToStreaming() async throws {
        let store = FakeTwoPassHistoryStore()
        let controller = makeController(config: makeConfig(), historyStore: store)
        let batch = FakeBatchTranscriber(text: "   ")

        try await driveUtterance(
            controller: controller,
            store: store,
            streamingText: "ストリーミングの結果",
            batchTranscriber: batch,
            recordedSamples: Self.oneSecondOfSamples,
            entryId: "entry-batch-empty"
        )

        let entry = try #require(await store.finalizedEntries.first)
        #expect(entry.rawText == "ストリーミングの結果")
        #expect(entry.rawSource == .streaming)
    }

    @Test("two_pass_decode == false never calls the batch decoder even when a warm instance lingers (TP9's key-up re-read)")
    func configOffBypassesLingeringWarmInstance() async throws {
        let store = FakeTwoPassHistoryStore()
        let controller = makeController(config: makeConfig(twoPassDecode: false), historyStore: store)
        let batch = FakeBatchTranscriber(text: "呼ばれてはいけないバッチ結果")

        try await driveUtterance(
            controller: controller,
            store: store,
            streamingText: "ストリーミングの結果",
            batchTranscriber: batch,
            recordedSamples: Self.oneSecondOfSamples,
            entryId: "entry-config-off"
        )

        let entry = try #require(await store.finalizedEntries.first)
        #expect(entry.rawText == "ストリーミングの結果")
        #expect(entry.rawSource == .streaming)
        let sampleCounts = await batch.transcribeCallSampleCounts
        #expect(sampleCounts.isEmpty, "the key-up config re-read must gate the batch path, not batchTranscriber's presence")
    }

    @Test("an unwarmed batch decoder (nil) falls back to the streaming text")
    func nilBatchTranscriberFallsBackToStreaming() async throws {
        let store = FakeTwoPassHistoryStore()
        let controller = makeController(config: makeConfig(), historyStore: store)

        try await driveUtterance(
            controller: controller,
            store: store,
            streamingText: "ストリーミングの結果",
            batchTranscriber: nil,
            recordedSamples: Self.oneSecondOfSamples,
            entryId: "entry-not-warm"
        )

        let entry = try #require(await store.finalizedEntries.first)
        #expect(entry.rawText == "ストリーミングの結果")
        #expect(entry.rawSource == .streaming)
    }

    @Test("fewer samples than the model's 0.3s floor skips the batch call and falls back")
    func belowMinimumSamplesSkipsBatchCall() async throws {
        let store = FakeTwoPassHistoryStore()
        let controller = makeController(config: makeConfig(), historyStore: store)
        let batch = FakeBatchTranscriber(text: "呼ばれてはいけないバッチ結果")

        try await driveUtterance(
            controller: controller,
            store: store,
            streamingText: "短い発話",
            batchTranscriber: batch,
            recordedSamples: [Float](repeating: 0, count: 100),
            entryId: "entry-short"
        )

        let entry = try #require(await store.finalizedEntries.first)
        #expect(entry.rawText == "短い発話")
        #expect(entry.rawSource == .streaming)
        let sampleCounts = await batch.transcribeCallSampleCounts
        #expect(sampleCounts.isEmpty)
    }

    @Test("a batch text with an empty streaming text still confirms (batch rescues what streaming missed entirely)")
    func batchRescuesEmptyStreaming() async throws {
        let store = FakeTwoPassHistoryStore()
        let controller = makeController(config: makeConfig(), historyStore: store)
        let batch = FakeBatchTranscriber(text: "バッチだけが認識した")

        try await driveUtterance(
            controller: controller,
            store: store,
            streamingText: "   ",
            batchTranscriber: batch,
            recordedSamples: Self.oneSecondOfSamples,
            entryId: "entry-rescue"
        )

        let entry = try #require(await store.finalizedEntries.first)
        #expect(entry.rawText == "バッチだけが認識した")
        #expect(entry.rawSource == .batch)
        #expect(entry.streamingText == nil)
    }

    @Test("both decoders empty discards the entry (DH10 unchanged)")
    func bothEmptyDiscardsEntry() async throws {
        let store = FakeTwoPassHistoryStore()
        let controller = makeController(config: makeConfig(), historyStore: store)
        let batch = FakeBatchTranscriber(text: " ")

        try await driveUtterance(
            controller: controller,
            store: store,
            streamingText: "  ",
            batchTranscriber: batch,
            recordedSamples: Self.oneSecondOfSamples,
            entryId: "entry-empty"
        )

        let deletedIds = await store.deletedIds
        #expect(deletedIds == ["entry-empty"])
        let finalized = await store.finalizedEntries
        #expect(finalized.isEmpty)
    }

    // MARK: - Warm/release transitions (TP5/TP9, §3.3)

    // Driven through `applyBatchDecodeEnablement(twoPassDecode:)` (and, for the disable path,
    // `handleConfigChanged(enabled: false, ...)`, which returns before the permission request):
    // going through `handleConfigChanged(enabled: true, ...)` would fire a real AX permission
    // prompt inside the test process (see that method's doc comment).

    @Test("enabled + two_pass_decode warms the batch decoder once, resolving the default language to the factory")
    func enabledWithTwoPassWarmsOnce() async throws {
        let store = FakeTwoPassHistoryStore()
        let requestedLanguages = OSAllocatedUnfairLockBox<[String]>(initialState: [])
        let controller = makeController(
            config: makeConfig(),
            historyStore: store,
            batchTranscriberFactory: { language, _ in
                requestedLanguages.withLock { $0.append(language) }
                return FakeBatchTranscriber(text: "warm")
            }
        )

        controller.applyBatchDecodeEnablement(twoPassDecode: true)
        controller.applyBatchDecodeEnablement(twoPassDecode: true)

        try await waitUntil { controller.isBatchDecoderWarm }
        let languages = requestedLanguages.withLock { $0 }
        #expect(languages == ["ja-JP"], "one warm despite repeated config events, with the resolved (not raw) language")
    }

    @Test("two_pass_decode off never calls the batch factory")
    func twoPassOffNeverWarms() async throws {
        let store = FakeTwoPassHistoryStore()
        let factoryCalls = OSAllocatedUnfairLockBox<Int>(initialState: 0)
        let controller = makeController(
            config: makeConfig(twoPassDecode: false),
            historyStore: store,
            batchTranscriberFactory: { _, _ in
                factoryCalls.withLock { $0 += 1 }
                return FakeBatchTranscriber(text: "warm")
            }
        )

        controller.applyBatchDecodeEnablement(twoPassDecode: false)

        try await Task.sleep(for: .milliseconds(50))
        #expect(factoryCalls.withLock { $0 } == 0)
        #expect(!controller.isBatchDecoderWarm)
    }

    @Test("toggling two_pass_decode off releases the warm batch decoder; disabling dictation does too")
    func togglingOffReleasesWarmDecoder() async throws {
        let store = FakeTwoPassHistoryStore()
        let controller = makeController(
            config: makeConfig(),
            historyStore: store,
            batchTranscriberFactory: { _, _ in FakeBatchTranscriber(text: "warm") }
        )

        controller.applyBatchDecodeEnablement(twoPassDecode: true)
        try await waitUntil { controller.isBatchDecoderWarm }

        controller.applyBatchDecodeEnablement(twoPassDecode: false)
        #expect(!controller.isBatchDecoderWarm, "an ON->OFF toggle must release the resident model immediately")

        controller.applyBatchDecodeEnablement(twoPassDecode: true)
        try await waitUntil { controller.isBatchDecoderWarm }

        controller.handleConfigChanged(enabled: false, twoPassDecode: true)
        #expect(!controller.isBatchDecoderWarm, "disabling dictation must release the batch model alongside the streaming one")
    }
}

// MARK: - OSAllocatedUnfairLockBox

/// Tiny `Sendable` call-recording box for the `@Sendable` factory closures above (a plain captured
/// `var` would not be `Sendable`).
private final class OSAllocatedUnfairLockBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(initialState: Value) {
        value = initialState
    }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
