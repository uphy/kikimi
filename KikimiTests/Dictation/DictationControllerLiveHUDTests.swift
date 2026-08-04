import Foundation
import Testing

@testable import Kikimi

// MARK: - SpyDictationLiveHUD

/// Call-recording stand-in for `DictationLiveHUDPanelController`
/// (`docs/design/32-dictation-hud-refining-visibility.md` §3.1's test seam), so these tests can
/// assert the show/beginProcessing/hide wiring without creating an `NSPanel`. Not `private`:
/// `DictationControllerHistoryTests`' `makeController` injects it too, keeping every
/// `simulateCapturing(...)`-driven test window-free.
@MainActor
final class SpyDictationLiveHUD: DictationLiveHUDPresenting {
    private(set) var showCount = 0
    private(set) var markCapturingCount = 0
    private(set) var beginProcessingCount = 0
    private(set) var hideCount = 0
    private(set) var updatedTexts: [String] = []
    private(set) var updatedLevels: [Float] = []

    func show() {
        showCount += 1
    }

    func markCapturing() {
        markCapturingCount += 1
    }

    func updateLevel(_ rms: Float) {
        updatedLevels.append(rms)
    }

    func beginProcessing() {
        beginProcessingCount += 1
    }

    func updateText(_ text: String) {
        updatedTexts.append(text)
    }

    func hide() {
        hideCount += 1
    }
}

// MARK: - FakeHUDSttBackend

/// Mirrors `DictationControllerHistoryTests`' own `FakeControllerSttBackend` (declared separately
/// since that one is `private` to its file): only `finish()`'s return value/error matters here.
private actor FakeHUDSttBackend: SttStreamingBackend {
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

private struct HUDTestStubError: Error {}

// MARK: - DictationControllerLiveHUDTests

/// `docs/design/32-dictation-hud-refining-visibility.md` §5's layer-1 test list: the HUD's key-up
/// behavior (refine on -> `beginProcessing()` and a tail-end `hide()`, refine off -> immediate
/// `hide()`) and the HR4 guarantee that every tail exit path hides it. Driven through
/// `simulateCapturing(...)` + `handleHotkeyUp()` like `DictationControllerHistoryTests`; the
/// setup-owned `show()` call from `simulateCapturing` is a precondition, so assertions only cover
/// what key-up and the tail add on top of it.
@Suite("DictationController live-HUD wiring")
@MainActor
struct DictationControllerLiveHUDTests {
    private func makeConfig(refine: Bool) -> DictationConfig {
        DictationConfig(
            enabled: true,
            insertMethod: .pasteboard,
            micDeviceUID: "",
            language: "",
            refine: refine,
            model: "claude-haiku-4-5-20251001",
            refineTimeoutMs: 3_000,
            context: .default,
            history: DictationHistoryConfig(enabled: false, maxEntries: 100)
        )
    }

    private func makeController(config: DictationConfig, hud: SpyDictationLiveHUD) -> DictationController {
        DictationController(
            dictationConfigProvider: { config },
            sttConfigProvider: { SttConfig.default },
            watchersDefaultModelProvider: { "claude-haiku-4-5-20251001" },
            glossaryProvider: { [] },
            glossaryCategoriesProvider: { [] },
            // `docs/design/42-prompt-overrides.md` §7.2: these default to `PromptStore.shared`,
            // which would otherwise touch the real `~/.config/kikimi/prompts/`/`AppConfig.shared`/
            // `AppState.shared` the first time a `refine: true` test above reaches `refineForHistory`.
            // Stubbed out the same way every other provider on this type already is.
            dictationGlobalBodyProvider: { "" },
            dictationAppBundleIDsProvider: { [] },
            dictationAppBodyProvider: { _ in "" },
            dictationGlossaryHeaderProvider: { GlossaryRenderer.defaultHeader },
            transcriberFactory: { _ in throw HUDTestStubError() },
            refiner: DictationRefiner(llm: FailingHUDLLM()),
            liveHUDPanelFactory: { hud },
            // Never let `handleHotkeyUp()`'s real insert path fire a `CGEvent` `⌘V`/pasteboard
            // write against whatever app is frontmost while this test suite runs.
            inserterFactory: { SpyDictationInserter() },
            // No trailing-capture wait in tests (word-drop fix 1's default is 280ms in production).
            trailingCaptureDelayMs: 0
        )
    }

    /// Mirrors `DictationControllerHistoryTests.waitUntil`.
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

    private func mismatchedCapturedTarget() -> FrontmostGuard.Target {
        FrontmostGuard.Target(bundleId: "com.example.stale", pid: -999, element: nil)
    }

    private func transcriber(finishing text: String) async -> DictationTranscriber {
        let backend = FakeHUDSttBackend()
        await backend.setFinishText(text)
        return DictationTranscriber(backend: backend)
    }

    @Test("simulateCapturing materializes the injected HUD via the factory and shows it")
    func simulateCapturingShowsInjectedHUD() async {
        let hud = SpyDictationLiveHUD()
        let controller = makeController(config: makeConfig(refine: true), hud: hud)

        controller.simulateCapturing(transcriber: await transcriber(finishing: "テスト"), capturedTarget: realCapturedTarget())

        #expect(hud.showCount == 1)
        #expect(hud.hideCount == 0)
    }

    @Test("refine on: key-up switches to processing (no hide yet), the tail end hides exactly once")
    func refineOnKeepsHUDThroughTail() async throws {
        let hud = SpyDictationLiveHUD()
        let controller = makeController(config: makeConfig(refine: true), hud: hud)
        controller.simulateCapturing(transcriber: await transcriber(finishing: "次の会議は木曜です"), capturedTarget: realCapturedTarget())

        controller.handleHotkeyUp()

        // The processing switch happens in key-up's synchronous part, before the tail even starts.
        #expect(hud.beginProcessingCount == 1)
        #expect(hud.hideCount == 0)
        try await waitUntil { controller.state == .idle }
        #expect(hud.hideCount == 1)
    }

    @Test("refine off: key-up hides immediately and never enters processing")
    func refineOffHidesImmediately() async throws {
        let hud = SpyDictationLiveHUD()
        let controller = makeController(config: makeConfig(refine: false), hud: hud)
        controller.simulateCapturing(transcriber: await transcriber(finishing: "そのまま挿入します"), capturedTarget: realCapturedTarget())

        controller.handleHotkeyUp()

        // Synchronous immediate hide (design 25 H1's preserved behavior)...
        #expect(hud.hideCount == 1)
        #expect(hud.beginProcessingCount == 0)
        try await waitUntil { controller.state == .idle }
        // ...plus the tail's unconditional (idempotent) end-of-path hide (design 32 HR4).
        #expect(hud.hideCount == 2)
        #expect(hud.beginProcessingCount == 0)
    }

    @Test("refine on + empty utterance (both decoders whitespace-only) still hides at the tail end")
    func emptyUtteranceHidesHUD() async throws {
        let hud = SpyDictationLiveHUD()
        let controller = makeController(config: makeConfig(refine: true), hud: hud)
        controller.simulateCapturing(transcriber: await transcriber(finishing: "   "), capturedTarget: realCapturedTarget())

        controller.handleHotkeyUp()

        #expect(hud.beginProcessingCount == 1)
        try await waitUntil { controller.state == .idle }
        #expect(hud.hideCount == 1)
    }

    @Test("refine on + finishUtterance() throw still hides at the tail end")
    func finishThrowHidesHUD() async throws {
        let hud = SpyDictationLiveHUD()
        let backend = FakeHUDSttBackend()
        await backend.setFinishError(HUDTestStubError())
        let controller = makeController(config: makeConfig(refine: true), hud: hud)
        controller.simulateCapturing(transcriber: DictationTranscriber(backend: backend), capturedTarget: realCapturedTarget())

        controller.handleHotkeyUp()

        #expect(hud.beginProcessingCount == 1)
        try await waitUntil { controller.state == .idle }
        #expect(hud.hideCount == 1)
    }

    @Test("capturing: mic buffers feed the level meter and never the text (design 49 HS1)")
    func capturingFeedsLevelNotText() async {
        let hud = SpyDictationLiveHUD()
        let controller = makeController(config: makeConfig(refine: true), hud: hud)
        controller.simulateCapturing(transcriber: await transcriber(finishing: "テスト"), capturedTarget: realCapturedTarget())

        await controller.handleCapturedSamples([0.2, -0.2, 0.2, -0.2], level: 0.2)
        await controller.handleCapturedSamples([0.5, -0.5], level: 0.5)

        #expect(hud.updatedLevels == [0.2, 0.5])
        // The regression this guards: the first-pass transcript used to be pushed here on every
        // chunk boundary, and it is not what ends up being inserted.
        #expect(hud.updatedTexts.isEmpty)
        #expect(hud.markCapturingCount == 2)
    }

    @Test("a mic buffer arriving after key-up is ignored (state is no longer .capturing)")
    func lateMicBufferIsIgnored() async {
        let hud = SpyDictationLiveHUD()
        let controller = makeController(config: makeConfig(refine: true), hud: hud)
        controller.simulateCapturing(transcriber: await transcriber(finishing: "テスト"), capturedTarget: realCapturedTarget())

        controller.handleHotkeyUp()
        await controller.handleCapturedSamples([0.9, -0.9], level: 0.9)

        #expect(hud.updatedLevels.isEmpty)
        #expect(hud.markCapturingCount == 0)
    }

    @Test("refine on: the selected raw text is pushed to the HUD before refinement")
    func selectedRawTextReachesHUD() async throws {
        let hud = SpyDictationLiveHUD()
        let controller = makeController(config: makeConfig(refine: true), hud: hud)
        controller.simulateCapturing(transcriber: await transcriber(finishing: "  次の会議は木曜です  "), capturedTarget: realCapturedTarget())

        controller.handleHotkeyUp()

        try await waitUntil { controller.state == .idle }
        #expect(hud.updatedTexts == ["次の会議は木曜です"])
    }

    @Test("refine on + aborted-and-stashed insert still hides at the tail end (HR6's hide precedes the overlay by code order)")
    func abortedInsertHidesHUD() async throws {
        let hud = SpyDictationLiveHUD()
        let controller = makeController(config: makeConfig(refine: true), hud: hud)
        controller.simulateCapturing(transcriber: await transcriber(finishing: "退避されるテキスト"), capturedTarget: mismatchedCapturedTarget())

        controller.handleHotkeyUp()

        try await waitUntil { controller.state == .idle }
        #expect(hud.hideCount == 1)
    }

    @Test("disabling dictation hides the HUD (HR5's stuck-HUD path)")
    func disableHidesHUD() async {
        let hud = SpyDictationLiveHUD()
        let controller = makeController(config: makeConfig(refine: true), hud: hud)
        controller.simulateCapturing(transcriber: await transcriber(finishing: "テスト"), capturedTarget: realCapturedTarget())

        controller.handleConfigChanged(enabled: false, twoPassDecode: false)

        #expect(hud.hideCount == 1)
        #expect(controller.state == .disabled)
    }
}

// MARK: - FailingHUDLLM

/// An `LLMCompleting` whose every call fails fast, so refine-enabled tests exercise the
/// fallback-to-raw path without a network dependency or a timeout wait.
private actor FailingHUDLLM: LLMCompleting {
    func complete<T: Decodable & Sendable>(_ request: LLMRequest) async throws -> LLMResult<T> {
        throw LLMClientError.missingStructuredOutput(raw: "no fake response registered")
    }

    func completeRaw(_ request: LLMRequest) async throws -> LLMResult<Data> {
        throw LLMClientError.missingStructuredOutput(raw: "no fake response registered")
    }
}
