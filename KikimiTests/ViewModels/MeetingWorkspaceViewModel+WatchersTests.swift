import Foundation
import Testing

@testable import Kikimi

// MARK: - FakeWatcherPanelLLM

/// Deterministic, network-free stand-in for `LLMCompleting` (mirrors `WatcherRunnerTests
/// .FakeWatcherLLM`, kept as its own private copy here since that one is file-private to its own
/// test file). `runWatcherNow(id:)`'s tests only ever go through `completeRaw(_:)`.
private actor FakeWatcherPanelLLM: LLMCompleting {
    var responses: [String: String] = [:]
    var errors: [String: LLMClientError] = [:]

    func setResponse(_ json: String, for key: String) {
        responses[key] = json
        errors[key] = nil
    }

    func setError(_ error: LLMClientError, for key: String) {
        errors[key] = error
    }

    func complete<T: Decodable & Sendable>(_ request: LLMRequest) async throws -> LLMResult<T> {
        let data = try resolveData(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return LLMResult(value: try decoder.decode(T.self, from: data), usage: .zero)
    }

    func completeRaw(_ request: LLMRequest) async throws -> LLMResult<Data> {
        LLMResult(value: try resolveData(for: request), usage: .zero)
    }

    private func resolveData(for request: LLMRequest) throws -> Data {
        let key = request.stubKey ?? ""
        if let error = errors[key] {
            throw error
        }
        guard let json = responses[key], let data = json.data(using: .utf8) else {
            throw LLMClientError.missingStructuredOutput(raw: "no fake response for stubKey=\(key)")
        }
        return data
    }
}

// MARK: - SimpleWatcherIdSequence

/// A scripted `simpleWatcherIdGeneratorOverride` sequence for the id-collision-retry test: returns
/// each value in `values` in order, then `fallback` forever. A lock-guarded class (not a plain local
/// `var` captured by the override closure) because the closure is `@Sendable` -- it's called from
/// inside `generateUniqueSimpleWatcherId()`'s loop under the `@TaskLocal`'s task, and Swift's
/// concurrency checker requires anything a `@Sendable` closure mutates to itself be safe to share.
private final class SimpleWatcherIdSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [String]
    private let fallback: String

    init(_ values: [String], fallback: String) {
        remaining = values
        self.fallback = fallback
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !remaining.isEmpty else { return fallback }
        return remaining.removeFirst()
    }

    var isExhausted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return remaining.isEmpty
    }
}

// MARK: - Test suite

@Suite("MeetingWorkspaceViewModel+Watchers")
@MainActor
struct MeetingWorkspaceViewModelWatchersTests {
    private func makeTemporaryDirectory(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

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
    ///   - presetsDirectory: Backs both `watcherLibrary` and the `watcherRunnerFactory`'s own library,
    ///     mirroring production's "both constructed from the same directory" wiring
    ///     (`docs/design/05-watcher-runner.md` §3.2).
    ///   - llm: Backs the `WatcherRunner` this view model's `watcherRunner` uses -- defaults to a
    ///     fresh `FakeWatcherPanelLLM` with no configured responses, so tests that never call
    ///     `runWatcherNow(id:)` stay hermetic.
    private func makeViewModel(
        handle: SessionHandle,
        store: SessionStore,
        presetsDirectory: URL,
        llm: LLMCompleting = FakeWatcherPanelLLM()
    ) -> MeetingWorkspaceViewModel {
        let library = WatcherLibrary(presetsDirectory: presetsDirectory)
        return MeetingWorkspaceViewModel(
            sessionHandle: handle,
            sessionStore: store,
            appState: AppState(directory: makeTemporaryDirectory(prefix: "MeetingWorkspaceViewModelWatchersTests-appstate")),
            appConfig: AppConfig(directory: makeTemporaryDirectory(prefix: "MeetingWorkspaceViewModelWatchersTests-appconfig")),
            voiceprintStore: VoiceprintStore(fileURL: makeTemporaryDirectory(prefix: "MeetingWorkspaceViewModelWatchersTests-vp")
                .appendingPathComponent("voiceprints.json")),
            watcherLibrary: library,
            watcherRunnerFactory: { sessionHandle in
                WatcherRunner(sessionHandle: sessionHandle, llm: llm, library: library, resolveModel: { _ in ResolvedModel(provider: ModelResolver.builtinProviderName, model: "test-model") })
            }
        )
    }

    /// A minimal, always-valid Watcher definition (mirrors `WatcherRunnerTests.definitionText(id:)`).
    private func definitionText(
        id: String,
        name: String = "Test Watcher",
        trigger: String = "on_manual",
        inputScope: String = "summary",
        initialState: String? = nil
    ) -> String {
        // Rendered as a YAML block scalar, or collapsed to a blank line (harmless in YAML) when the
        // caller wants no `initial_state` at all.
        let initialStateLines = initialState.map { "initial_state: |\n  \($0)" } ?? ""
        return """
        ---
        id: \(id)
        name: \(name)
        trigger: \(trigger)
        state_mode: cumulative
        input_scope: \(inputScope)
        schema:
          note: string
        \(initialStateLines)
        view: |
          {{note}}
        ---

        # System

        system prompt

        # User

        {{state}}
        """
    }

    /// Polls `predicate` until it becomes `true` or `timeout` elapses (mirrors
    /// `WatcherRunnerTests.waitUntil`/`SummaryUpdaterTests.waitUntil`) -- used for assertions on
    /// state written by a fire-and-forget `Task` (`setWatcherEnabled(id:enabled:)`, `runWatcherNow(id:)`).
    private func waitUntil(timeout: Duration = .seconds(10), predicate: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate(), "condition did not become true within \(timeout)")
    }

    // MARK: - Items construction (§10.1)

    @Test("onAppear() builds watcherItems in enabled.yaml order, resolving name/origin from each definition")
    func onAppearBuildsWatcherItemsInEnabledOrder() async throws {
        let root = makeTemporaryDirectory(prefix: "onAppearBuildsWatcherItemsInEnabledOrder")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "onAppearBuildsWatcherItemsInEnabledOrder-presets")

        try await handle.writeText(definitionText(id: "watcher-a", name: "Alpha"), to: .watcherDefinition(id: "watcher-a"))
        try definitionText(id: "watcher-b", name: "Beta").write(
            to: presetsDirectory.appendingPathComponent("watcher-b.md"), atomically: true, encoding: .utf8
        )
        try await handle.writeEnabledWatchers(["watcher-a", "watcher-b"])

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        await viewModel.onAppear()

        #expect(viewModel.watcherItems.map(\.id) == ["watcher-a", "watcher-b"])
        #expect(viewModel.watcherItems.map(\.name) == ["Alpha", "Beta"])
        #expect(viewModel.watcherItems.map(\.origin) == [.sessionLocal, .preset])
        #expect(viewModel.selectedWatcherId == "watcher-a")
    }

    @Test("an enabled id with no resolvable definition becomes origin: .missing with an .error status")
    func missingDefinitionBecomesMissingBadge() async throws {
        let root = makeTemporaryDirectory(prefix: "missingDefinitionBecomesMissingBadge")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "missingDefinitionBecomesMissingBadge-presets")

        try await handle.writeEnabledWatchers(["ghost-watcher"])

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        await viewModel.onAppear()

        #expect(viewModel.watcherItems.count == 1)
        #expect(viewModel.watcherItems.first?.origin == .missing)
        if case .error = viewModel.watcherItems.first?.status {
            // expected
        } else {
            Issue.record("Expected .error status for a missing definition, got \(String(describing: viewModel.watcherItems.first?.status))")
        }
    }

    // MARK: - Enable toggle (§10.3)

    @Test("setWatcherEnabled(id:enabled: false) removes the item from watcherItems once enabled.yaml is rewritten")
    func setWatcherEnabledFalseRemovesItem() async throws {
        let root = makeTemporaryDirectory(prefix: "setWatcherEnabledFalseRemovesItem")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "setWatcherEnabledFalseRemovesItem-presets")

        try await handle.writeText(definitionText(id: "watcher-a"), to: .watcherDefinition(id: "watcher-a"))
        try await handle.writeEnabledWatchers(["watcher-a"])

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        await viewModel.onAppear()
        #expect(viewModel.watcherItems.map(\.id) == ["watcher-a"])

        viewModel.setWatcherEnabled(id: "watcher-a", enabled: false)
        try await waitUntil { viewModel.watcherItems.isEmpty }

        let enabledAfter = try await handle.readEnabledWatchers()
        #expect(enabledAfter.isEmpty)
    }

    @Test("setWatcherEnabled(id:enabled: true) for a preset id adds it to watcherItems without forking a file")
    func setWatcherEnabledTrueAddsPresetById() async throws {
        let root = makeTemporaryDirectory(prefix: "setWatcherEnabledTrueAddsPresetById")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "setWatcherEnabledTrueAddsPresetById-presets")
        try definitionText(id: "preset-a", name: "Preset A").write(
            to: presetsDirectory.appendingPathComponent("preset-a.md"), atomically: true, encoding: .utf8
        )

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        await viewModel.onAppear()
        #expect(viewModel.watcherItems.isEmpty)

        viewModel.setWatcherEnabled(id: "preset-a", enabled: true)
        try await waitUntil { viewModel.watcherItems.map(\.id) == ["preset-a"] }

        #expect(viewModel.watcherItems.first?.origin == .preset)
        let sessionLocalText = try await handle.readText(.watcherDefinition(id: "preset-a"))
        #expect(sessionLocalText == nil, "Enabling a preset by id must not fork it into a session-local copy")
    }

    // MARK: - seg jump (§10.4)

    @Test("jumpToTranscriptSegment(_:) sets pendingTranscriptScrollTarget and switches to the 会議 tab when the id exists")
    func jumpToTranscriptSegmentSucceedsForExistingRow() async throws {
        let root = makeTemporaryDirectory(prefix: "jumpToTranscriptSegmentSucceedsForExistingRow")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "jumpToTranscriptSegmentSucceedsForExistingRow-presets")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 1_000, speaker: .mic, rawText: "hello", state: .raw)
        ]
        viewModel.activeTab = .prep

        viewModel.jumpToTranscriptSegment("seg_00001")

        #expect(viewModel.activeTab == .meeting)
        #expect(viewModel.pendingTranscriptScrollTarget == "seg_00001")
        // Unlike the scroll request, the marker is not consumed on arrival -- it is what still answers
        // "which row did the Watcher cite?" after the arrival flash has faded.
        #expect(viewModel.jumpHighlightedSegmentId == "seg_00001")
    }

    @Test("a second jump moves jumpHighlightedSegmentId to the new segment")
    func jumpToTranscriptSegmentReplacesPreviousHighlight() async throws {
        let root = makeTemporaryDirectory(prefix: "jumpToTranscriptSegmentReplacesPreviousHighlight")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "jumpToTranscriptSegmentReplacesPreviousHighlight-presets")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 1_000, speaker: .mic, rawText: "hello", state: .raw),
            TranscriptRowViewModel(id: "seg_00002", startMs: 1_000, endMs: 2_000, speaker: .mic, rawText: "world", state: .raw)
        ]

        viewModel.jumpToTranscriptSegment("seg_00001")
        viewModel.jumpToTranscriptSegment("seg_00002")

        #expect(viewModel.jumpHighlightedSegmentId == "seg_00002", "Only the most recent citation is marked")
    }

    @Test("jumpToTranscriptSegment(_:) widens meetingPaneMode from .summary to .both so the transcript pane is visible")
    func jumpToTranscriptSegmentWidensSummaryOnlyPaneMode() async throws {
        let root = makeTemporaryDirectory(prefix: "jumpToTranscriptSegmentWidensSummaryOnlyPaneMode")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "jumpToTranscriptSegmentWidensSummaryOnlyPaneMode-presets")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 1_000, speaker: .mic, rawText: "hello", state: .raw)
        ]
        viewModel.meetingPaneMode = .summary

        viewModel.jumpToTranscriptSegment("seg_00001")

        #expect(viewModel.activeTab == .meeting)
        #expect(viewModel.meetingPaneMode == .both)
    }

    @Test("jumpToTranscriptSegment(_:) leaves meetingPaneMode == .transcript untouched")
    func jumpToTranscriptSegmentLeavesTranscriptOnlyPaneModeUntouched() async throws {
        let root = makeTemporaryDirectory(prefix: "jumpToTranscriptSegmentLeavesTranscriptOnlyPaneModeUntouched")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(
            prefix: "jumpToTranscriptSegmentLeavesTranscriptOnlyPaneModeUntouched-presets"
        )

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        viewModel.transcriptRows = [
            TranscriptRowViewModel(id: "seg_00001", startMs: 0, endMs: 1_000, speaker: .mic, rawText: "hello", state: .raw)
        ]
        viewModel.meetingPaneMode = .transcript

        viewModel.jumpToTranscriptSegment("seg_00001")

        #expect(viewModel.meetingPaneMode == .transcript)
    }

    @Test("jumpToTranscriptSegment(_:) is a no-op when the id has no matching row")
    func jumpToTranscriptSegmentIgnoresUnknownId() async throws {
        let root = makeTemporaryDirectory(prefix: "jumpToTranscriptSegmentIgnoresUnknownId")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "jumpToTranscriptSegmentIgnoresUnknownId-presets")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        viewModel.transcriptRows = []
        viewModel.activeTab = .prep

        viewModel.jumpToTranscriptSegment("seg_00099")

        #expect(viewModel.activeTab == .prep)
        #expect(viewModel.pendingTranscriptScrollTarget == nil)
        #expect(viewModel.jumpHighlightedSegmentId == nil, "An ignored jump must not mark any row")
    }

    // MARK: - Event reflection (§9/§10.1)

    @Test("runWatcherNow(id:) reflects a .finished WatcherEvent into the matching watcherItems entry")
    func runWatcherNowReflectsFinishedEvent() async throws {
        let root = makeTemporaryDirectory(prefix: "runWatcherNowReflectsFinishedEvent")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "runWatcherNowReflectsFinishedEvent-presets")

        try await handle.writeText(definitionText(id: "watcher-a"), to: .watcherDefinition(id: "watcher-a"))
        try await handle.writeEnabledWatchers(["watcher-a"])

        let llm = FakeWatcherPanelLLM()
        await llm.setResponse("{\"note\":\"hello from watcher\"}", for: "watcher_watcher-a")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory, llm: llm)
        await viewModel.onAppear()
        #expect(viewModel.watcherItems.first?.renderedMarkdown == nil)

        viewModel.runWatcherNow(id: "watcher-a")

        try await waitUntil { viewModel.watcherItems.first?.renderedMarkdown != nil }

        let item = try #require(viewModel.watcherItems.first)
        #expect(item.renderedMarkdown == "hello from watcher")
        #expect(item.status == .idle)
        #expect(item.lastRunAt != nil)
    }

    @Test("runWatcherNow(id:) reflects a .failed WatcherEvent as an .error status")
    func runWatcherNowReflectsFailedEvent() async throws {
        let root = makeTemporaryDirectory(prefix: "runWatcherNowReflectsFailedEvent")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "runWatcherNowReflectsFailedEvent-presets")

        try await handle.writeText(definitionText(id: "watcher-a"), to: .watcherDefinition(id: "watcher-a"))
        try await handle.writeEnabledWatchers(["watcher-a"])

        let llm = FakeWatcherPanelLLM()
        await llm.setError(.timedOut(.seconds(1)), for: "watcher_watcher-a")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory, llm: llm)
        await viewModel.onAppear()

        viewModel.runWatcherNow(id: "watcher-a")

        try await waitUntil {
            if case .error = viewModel.watcherItems.first?.status { return true }
            return false
        }
    }

    // MARK: - Prep tab management (§10.3)

    @Test("createLocalWatcher(id:) writes a parseable scaffold and enables it")
    func createLocalWatcherWritesScaffoldAndEnables() async throws {
        let root = makeTemporaryDirectory(prefix: "createLocalWatcherWritesScaffoldAndEnables")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "createLocalWatcherWritesScaffoldAndEnables-presets")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        try await viewModel.createLocalWatcher(id: "my-watcher")

        let enabled = try await handle.readEnabledWatchers()
        #expect(enabled == ["my-watcher"])
        let text = try await handle.readText(.watcherDefinition(id: "my-watcher"))
        let definition = try WatcherDefinitionParser.parse(text: try #require(text), expectedId: "my-watcher")
        #expect(definition.id == "my-watcher")
        #expect(viewModel.watcherItems.map(\.id) == ["my-watcher"])
    }

    @Test("createLocalWatcher(id:) throws for an invalid id and for an id that already has a session-local definition")
    func createLocalWatcherRejectsInvalidOrDuplicateId() async throws {
        let root = makeTemporaryDirectory(prefix: "createLocalWatcherRejectsInvalidOrDuplicateId")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "createLocalWatcherRejectsInvalidOrDuplicateId-presets")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)

        await #expect(throws: LocalWatcherCreationError.invalidId("bad id!")) {
            try await viewModel.createLocalWatcher(id: "bad id!")
        }

        try await viewModel.createLocalWatcher(id: "dup-watcher")
        await #expect(throws: LocalWatcherCreationError.alreadyExists("dup-watcher")) {
            try await viewModel.createLocalWatcher(id: "dup-watcher")
        }
    }

    @Test("deleteLocalWatcher(id:) removes the definition, state, and run record, and drops the id from enabled.yaml")
    func deleteLocalWatcherRemovesFilesAndEnabledEntry() async throws {
        let root = makeTemporaryDirectory(prefix: "deleteLocalWatcherRemovesFilesAndEnabledEntry")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "deleteLocalWatcherRemovesFilesAndEnabledEntry-presets")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        try await viewModel.createLocalWatcher(id: "throwaway")
        try await handle.writeText("{\"note\":\"x\"}", to: .watcherState(id: "throwaway"))
        try await handle.writeJSON(
            WatcherRunRecord(finishedAt: Date(timeIntervalSince1970: 1_700_000_000), inputScope: .summary),
            to: .watcherRunRecord(id: "throwaway")
        )

        await viewModel.deleteLocalWatcher(id: "throwaway")

        let enabled = try await handle.readEnabledWatchers()
        #expect(enabled.isEmpty)
        let definitionText = try await handle.readText(.watcherDefinition(id: "throwaway"))
        #expect(definitionText == nil)
        let stateText = try await handle.readText(.watcherState(id: "throwaway"))
        #expect(stateText == nil)
        // A leftover run record would later be picked up by a *newly created* Watcher reusing the
        // same id, labelling its first render with a timestamp/scope from the deleted one.
        let runRecord = try await handle.readJSON(.watcherRunRecord(id: "throwaway"), as: WatcherRunRecord.self)
        #expect(runRecord == nil)
        #expect(viewModel.watcherItems.isEmpty)
    }

    @Test("forkPresetWatcher(id:) copies the preset into session-local, flipping origin on the next refresh")
    func forkPresetWatcherCopiesIntoSessionLocal() async throws {
        let root = makeTemporaryDirectory(prefix: "forkPresetWatcherCopiesIntoSessionLocal")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "forkPresetWatcherCopiesIntoSessionLocal-presets")
        try definitionText(id: "preset-a", name: "Preset A").write(
            to: presetsDirectory.appendingPathComponent("preset-a.md"), atomically: true, encoding: .utf8
        )
        try await handle.writeEnabledWatchers(["preset-a"])

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        await viewModel.onAppear()
        #expect(viewModel.watcherItems.first?.origin == .preset)

        await viewModel.forkPresetWatcher(id: "preset-a")

        let sessionLocalText = try await handle.readText(.watcherDefinition(id: "preset-a"))
        #expect(sessionLocalText != nil)
        #expect(viewModel.watcherItems.first?.origin == .sessionLocal)
    }

    @Test("promoteWatcherToPreset(id:) writes the session-local definition out to the preset library")
    func promoteWatcherToPresetWritesPresetFile() async throws {
        let root = makeTemporaryDirectory(prefix: "promoteWatcherToPresetWritesPresetFile")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "promoteWatcherToPresetWritesPresetFile-presets")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        try await viewModel.createLocalWatcher(id: "promote-me")
        #expect(viewModel.presetExists(id: "promote-me") == false)

        await viewModel.promoteWatcherToPreset(id: "promote-me")

        #expect(viewModel.presetExists(id: "promote-me"))
        let presetText = try? String(contentsOf: presetsDirectory.appendingPathComponent("promote-me.md"), encoding: .utf8)
        let sessionLocalText = try await handle.readText(.watcherDefinition(id: "promote-me"))
        #expect(presetText == sessionLocalText)
    }

    @Test("saveLocalWatcherText(id:text:) always persists, returning nil for a clean parse and a message otherwise")
    func saveLocalWatcherTextPersistsRegardlessOfParseResult() async throws {
        let root = makeTemporaryDirectory(prefix: "saveLocalWatcherTextPersistsRegardlessOfParseResult")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "saveLocalWatcherTextPersistsRegardlessOfParseResult-presets")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        try await viewModel.createLocalWatcher(id: "editable")

        let validText = definitionText(id: "editable", name: "Renamed")
        let warningForValid = await viewModel.saveLocalWatcherText(id: "editable", text: validText)
        #expect(warningForValid == nil)
        #expect(viewModel.watcherItems.first?.name == "Renamed")

        let brokenText = "not a valid watcher definition"
        let warningForBroken = await viewModel.saveLocalWatcherText(id: "editable", text: brokenText)
        #expect(warningForBroken != nil)
        let persisted = try await handle.readText(.watcherDefinition(id: "editable"))
        #expect(persisted == brokenText, "saveLocalWatcherText must persist even text that fails to parse (§10.3 '保存自体は許す')")
    }

    // MARK: - Simple Watcher CRUD (`docs/design/34-simple-watchers.md` §6.3, §7)

    /// A minimal, always-valid `kind: simple` definition (mirrors `definitionText(id:name:trigger:)`
    /// for the simple format, §2).
    private func simpleDefinitionText(
        id: String,
        name: String = "Simple Watcher",
        trigger: String = "on_manual",
        model: String? = nil,
        prompt: String = "会議の脱線がないか見張ってください。"
    ) -> String {
        let modelLine = model.map { "model: \($0)\n" } ?? ""
        return """
        ---
        kind: simple
        id: \(id)
        name: \(name)
        \(modelLine)trigger: \(trigger)
        input_scope: summary
        ---

        \(prompt)
        """
    }

    @Test("refreshWatcherItems() sets isSimple from definition.simpleSpec, false for a full definition and for .missing")
    func refreshWatcherItemsSetsIsSimple() async throws {
        let root = makeTemporaryDirectory(prefix: "refreshWatcherItemsSetsIsSimple")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "refreshWatcherItemsSetsIsSimple-presets")

        try await handle.writeText(simpleDefinitionText(id: "simple-a"), to: .watcherDefinition(id: "simple-a"))
        try await handle.writeText(definitionText(id: "full-a"), to: .watcherDefinition(id: "full-a"))
        try await handle.writeEnabledWatchers(["simple-a", "full-a", "ghost-a"])

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        await viewModel.onAppear()

        let byId = Dictionary(uniqueKeysWithValues: viewModel.watcherItems.map { ($0.id, $0) })
        #expect(byId["simple-a"]?.isSimple == true)
        #expect(byId["full-a"]?.isSimple == false)
        #expect(byId["ghost-a"]?.isSimple == false)
        #expect(byId["ghost-a"]?.origin == .missing)
    }

    /// Backs the Watchers-tab footer's `input_scope` badge (`WatchersTabView.inputScopeLabel(_:)`):
    /// every resolvable definition -- simple or full -- has to carry its scope through to the panel
    /// item, and a `.missing` id has to leave it `nil` rather than inheriting a stale value.
    @Test("refreshWatcherItems() carries each definition's input_scope into the panel item, nil for .missing")
    func refreshWatcherItemsSetsInputScope() async throws {
        let root = makeTemporaryDirectory(prefix: "refreshWatcherItemsSetsInputScope")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "refreshWatcherItemsSetsInputScope-presets")

        try await handle.writeText(
            definitionText(id: "recent-a", inputScope: "summary_and_recent:12"), to: .watcherDefinition(id: "recent-a")
        )
        try await handle.writeText(
            definitionText(id: "full-a", inputScope: "full_refined"), to: .watcherDefinition(id: "full-a")
        )
        try await handle.writeText(simpleDefinitionText(id: "simple-a"), to: .watcherDefinition(id: "simple-a"))
        try await handle.writeEnabledWatchers(["recent-a", "full-a", "simple-a", "ghost-a"])

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        await viewModel.onAppear()

        let byId = Dictionary(uniqueKeysWithValues: viewModel.watcherItems.map { ($0.id, $0) })
        #expect(byId["recent-a"]?.inputScope == .summaryAndRecent(count: 12))
        #expect(byId["full-a"]?.inputScope == .fullRefined)
        #expect(byId["simple-a"]?.inputScope == .summary)
        #expect(byId["ghost-a"]?.inputScope == nil)
    }

    @Test("createSimpleWatcher(_:) generates a simple-<6 hex> id, writes a kind: simple definition, and enables it")
    func createSimpleWatcherGeneratesIdAndEnables() async throws {
        let root = makeTemporaryDirectory(prefix: "createSimpleWatcherGeneratesIdAndEnables")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "createSimpleWatcherGeneratesIdAndEnables-presets")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        let draft = SimpleWatcherSpecDraft(
            name: "論点整理", model: nil, prompt: "論点を3つ以内で整理してください。", trigger: .onSummaryUpdate, inputScope: .summary
        )
        try await viewModel.createSimpleWatcher(draft)

        let enabled = try await handle.readEnabledWatchers()
        #expect(enabled.count == 1)
        let id = try #require(enabled.first)
        #expect(id.hasPrefix("simple-"))
        #expect(id.count == "simple-".count + 6)

        let spec = try #require(await viewModel.simpleWatcherSpec(id: id))
        #expect(spec.name == "論点整理")
        #expect(spec.prompt == "論点を3つ以内で整理してください。")
        #expect(spec.model == nil)
        #expect(spec.trigger == .onSummaryUpdate)
        #expect(spec.inputScope == .summary)

        #expect(viewModel.watcherItems.map(\.id) == [id])
        #expect(viewModel.watcherItems.first?.isSimple == true)
    }

    @Test("createSimpleWatcher(_:) retries id generation when the candidate collides with a session-local id or a preset id")
    func createSimpleWatcherRetriesOnIdCollision() async throws {
        let root = makeTemporaryDirectory(prefix: "createSimpleWatcherRetriesOnIdCollision")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "createSimpleWatcherRetriesOnIdCollision-presets")

        // "simple-aaaaaa" collides with a preset, "simple-bbbbbb" collides with a session-local
        // definition -- both must be skipped before "simple-cccccc" is accepted (§6.2's "preset の
        // 暗黙 shadow を防ぐ" collision check).
        try definitionText(id: "simple-aaaaaa").write(
            to: presetsDirectory.appendingPathComponent("simple-aaaaaa.md"), atomically: true, encoding: .utf8
        )
        try await handle.writeText(definitionText(id: "simple-bbbbbb"), to: .watcherDefinition(id: "simple-bbbbbb"))

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)

        let sequence = SimpleWatcherIdSequence(["simple-aaaaaa", "simple-bbbbbb", "simple-cccccc"], fallback: "simple-ffffff")
        let draft = SimpleWatcherSpecDraft(name: "N", model: nil, prompt: "P", trigger: .onManual, inputScope: .summary)
        // `@TaskLocal` (not a mutable global), so this override is only visible within this test's
        // own `Task` tree -- concurrently-running sibling `@Test`s never see it (see
        // `MeetingWorkspaceViewModel.simpleWatcherIdGeneratorOverride`'s doc comment).
        try await MeetingWorkspaceViewModel.$simpleWatcherIdGeneratorOverride.withValue({ sequence.next() }) {
            try await viewModel.createSimpleWatcher(draft)
        }

        let enabled = try await handle.readEnabledWatchers()
        #expect(enabled == ["simple-cccccc"])
        #expect(sequence.isExhausted, "the generator should have been called exactly 3 times")
    }

    @Test("createSimpleWatcher(_:) throws when the generated id fails to write, and does not enable it")
    func createSimpleWatcherThrowsOnWriteFailure() async throws {
        let root = makeTemporaryDirectory(prefix: "createSimpleWatcherThrowsOnWriteFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "createSimpleWatcherThrowsOnWriteFailure-presets")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        let draft = SimpleWatcherSpecDraft(name: "N", model: nil, prompt: "P", trigger: .onManual, inputScope: .summary)
        // Not a valid `SessionFile`/`WatcherLibrary` watcher id (contains spaces), so the write
        // itself fails -- exercising §6.3's "変更系 3 API はすべて... throw する" for a genuine I/O failure.
        await #expect(throws: SessionFileError.invalidWatcherId("simple invalid id")) {
            try await MeetingWorkspaceViewModel.$simpleWatcherIdGeneratorOverride.withValue({ "simple invalid id" }) {
                try await viewModel.createSimpleWatcher(draft)
            }
        }

        let enabled = try await handle.readEnabledWatchers()
        #expect(enabled.isEmpty)
    }

    @Test("updateSimpleWatcher(id:_:) throws when the write fails, leaving enabled.yaml untouched")
    func updateSimpleWatcherThrowsOnWriteFailure() async throws {
        let root = makeTemporaryDirectory(prefix: "updateSimpleWatcherThrowsOnWriteFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "updateSimpleWatcherThrowsOnWriteFailure-presets")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        let draft = SimpleWatcherSpecDraft(name: "N", model: nil, prompt: "P", trigger: .onManual, inputScope: .summary)
        await #expect(throws: SessionFileError.invalidWatcherId("bad id!")) {
            try await viewModel.updateSimpleWatcher(id: "bad id!", draft)
        }
    }

    @Test("simpleWatcherSpec(id:) -> draft -> updateSimpleWatcher(id:_:) preserves a hand-authored model")
    func updateSimpleWatcherPreservesModel() async throws {
        let root = makeTemporaryDirectory(prefix: "updateSimpleWatcherPreservesModel")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "updateSimpleWatcherPreservesModel-presets")

        try await handle.writeText(
            simpleDefinitionText(id: "simple-x", name: "変更前", model: "claude-haiku-custom"),
            to: .watcherDefinition(id: "simple-x")
        )
        try await handle.writeEnabledWatchers(["simple-x"])

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        await viewModel.onAppear()

        // Mirrors the form's own flow (§6.3): read the existing spec first, then carry its `model`
        // (never shown in the form) into the draft the form itself edits.
        let existing = try #require(await viewModel.simpleWatcherSpec(id: "simple-x"))
        #expect(existing.model == "claude-haiku-custom")

        let draft = SimpleWatcherSpecDraft(
            name: "変更後", model: existing.model, prompt: existing.prompt, trigger: existing.trigger, inputScope: existing.inputScope
        )
        try await viewModel.updateSimpleWatcher(id: "simple-x", draft)

        let after = try #require(await viewModel.simpleWatcherSpec(id: "simple-x"))
        #expect(after.name == "変更後")
        #expect(after.model == "claude-haiku-custom", "editing via the form must not silently drop a hand-authored model")
    }

    @Test("convertSimpleWatcherToFull(id:) overwrites the definition with full-format text on success")
    func convertSimpleWatcherToFullSucceeds() async throws {
        let root = makeTemporaryDirectory(prefix: "convertSimpleWatcherToFullSucceeds")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "convertSimpleWatcherToFullSucceeds-presets")

        try await handle.writeText(simpleDefinitionText(id: "simple-z"), to: .watcherDefinition(id: "simple-z"))
        try await handle.writeEnabledWatchers(["simple-z"])

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        await viewModel.onAppear()
        #expect(viewModel.watcherItems.first?.isSimple == true)

        try await viewModel.convertSimpleWatcherToFull(id: "simple-z")

        let text = try #require(try await handle.readText(.watcherDefinition(id: "simple-z")))
        let definition = try WatcherDefinitionParser.parse(text: text, expectedId: "simple-z")
        #expect(definition.simpleSpec == nil)
        #expect(viewModel.watcherItems.first?.isSimple == false)
    }

    @Test("convertSimpleWatcherToFull(id:) throws roundTripMismatch and leaves the file untouched for a prompt with a \"# \" line")
    func convertSimpleWatcherToFullThrowsRoundTripMismatchForHashLine() async throws {
        let root = makeTemporaryDirectory(prefix: "convertSimpleWatcherToFullThrowsRoundTripMismatchForHashLine")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(
            prefix: "convertSimpleWatcherToFullThrowsRoundTripMismatchForHashLine-presets"
        )

        let originalText = simpleDefinitionText(id: "simple-y", prompt: "# 見出し\n本文です。")
        try await handle.writeText(originalText, to: .watcherDefinition(id: "simple-y"))
        try await handle.writeEnabledWatchers(["simple-y"])

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        await viewModel.onAppear()

        await #expect(throws: SimpleWatcherConversionError.self) {
            try await viewModel.convertSimpleWatcherToFull(id: "simple-y")
        }

        let after = try await handle.readText(.watcherDefinition(id: "simple-y"))
        #expect(after == originalText, "a round-trip mismatch must not overwrite the original definition")
    }

    @Test("availablePresets() excludes ids already enabled for this session")
    func availablePresetsExcludesEnabledIds() async throws {
        let root = makeTemporaryDirectory(prefix: "availablePresetsExcludesEnabledIds")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "availablePresetsExcludesEnabledIds-presets")
        try definitionText(id: "preset-a").write(to: presetsDirectory.appendingPathComponent("preset-a.md"), atomically: true, encoding: .utf8)
        try definitionText(id: "preset-b").write(to: presetsDirectory.appendingPathComponent("preset-b.md"), atomically: true, encoding: .utf8)
        try await handle.writeEnabledWatchers(["preset-a"])

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        await viewModel.onAppear()

        #expect(viewModel.availablePresets() == ["preset-b"])
    }

    // MARK: - watcherDefinitionText(id:) (§10.3 edit sheet's initial content)

    @Test("watcherDefinitionText(id:) returns the session-local text when a session-local definition exists")
    func watcherDefinitionTextReturnsSessionLocalText() async throws {
        let root = makeTemporaryDirectory(prefix: "watcherDefinitionTextReturnsSessionLocalText")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "watcherDefinitionTextReturnsSessionLocalText-presets")

        let text = definitionText(id: "watcher-a", name: "Session Local")
        try await handle.writeText(text, to: .watcherDefinition(id: "watcher-a"))

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)

        #expect(await viewModel.watcherDefinitionText(id: "watcher-a") == text)
    }

    @Test("watcherDefinitionText(id:) falls back to the preset text when there's no session-local override")
    func watcherDefinitionTextFallsBackToPresetText() async throws {
        let root = makeTemporaryDirectory(prefix: "watcherDefinitionTextFallsBackToPresetText")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "watcherDefinitionTextFallsBackToPresetText-presets")

        let text = definitionText(id: "preset-a", name: "Preset A")
        try text.write(to: presetsDirectory.appendingPathComponent("preset-a.md"), atomically: true, encoding: .utf8)

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)

        #expect(await viewModel.watcherDefinitionText(id: "preset-a") == text)
    }

    @Test("watcherDefinitionText(id:) returns nil when neither a session-local nor a preset definition exists")
    func watcherDefinitionTextReturnsNilForUnknownId() async throws {
        let root = makeTemporaryDirectory(prefix: "watcherDefinitionTextReturnsNilForUnknownId")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "watcherDefinitionTextReturnsNilForUnknownId-presets")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)

        #expect(await viewModel.watcherDefinitionText(id: "ghost") == nil)
    }

    // MARK: - fork/promote error paths (§10.3, no throw on failure -- just logged)

    @Test("forkPresetWatcher(id:) for a nonexistent preset id logs and leaves state untouched")
    func forkPresetWatcherForMissingPresetLeavesStateUntouched() async throws {
        let root = makeTemporaryDirectory(prefix: "forkPresetWatcherForMissingPresetLeavesStateUntouched")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "forkPresetWatcherForMissingPresetLeavesStateUntouched-presets")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        await viewModel.onAppear()
        #expect(viewModel.watcherItems.isEmpty)

        await viewModel.forkPresetWatcher(id: "no-such-preset")

        #expect(viewModel.watcherItems.isEmpty)
        let sessionLocalText = try await handle.readText(.watcherDefinition(id: "no-such-preset"))
        #expect(sessionLocalText == nil, "a failed fork must not create a session-local file")
    }

    @Test("promoteWatcherToPreset(id:) for an id with no session-local definition logs and creates no preset file")
    func promoteWatcherToPresetForMissingLocalCreatesNoPresetFile() async throws {
        let root = makeTemporaryDirectory(prefix: "promoteWatcherToPresetForMissingLocalCreatesNoPresetFile")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "promoteWatcherToPresetForMissingLocalCreatesNoPresetFile-presets")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)

        await viewModel.promoteWatcherToPreset(id: "no-such-local")

        #expect(viewModel.presetExists(id: "no-such-local") == false)
        let presetFile = presetsDirectory.appendingPathComponent("no-such-local.md")
        #expect(FileManager.default.fileExists(atPath: presetFile.path) == false)
    }

    // MARK: - Initial LLM-free render (§10.1)

    @Test("onAppear() renders renderedMarkdown from an already-persisted state.json without calling the LLM")
    func onAppearRendersFromPersistedStateWithoutCallingLLM() async throws {
        let root = makeTemporaryDirectory(prefix: "onAppearRendersFromPersistedStateWithoutCallingLLM")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "onAppearRendersFromPersistedStateWithoutCallingLLM-presets")

        try await handle.writeText(definitionText(id: "watcher-a"), to: .watcherDefinition(id: "watcher-a"))
        try await handle.writeEnabledWatchers(["watcher-a"])
        try await handle.writeText("{\"note\":\"persisted note\"}", to: .watcherState(id: "watcher-a"))

        // No responses configured -- if this path ever called through to the LLM, `resolveData(for:)`
        // would throw and the item would surface an `.error` status instead of the expected render.
        let llm = FakeWatcherPanelLLM()
        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory, llm: llm)

        await viewModel.onAppear()

        #expect(viewModel.watcherItems.first?.renderedMarkdown == "persisted note")
        #expect(viewModel.watcherItems.first?.status == .idle)
    }

    // MARK: - lastRunAt / lastRunInputScope recovery on reopen (§7.2)

    /// A reopened session (every Ended meeting, and any window opened from the session list) used to
    /// render a real result under a "未実行" footer, because `lastRunAt` only ever came from a live
    /// `WatcherEvent.finished` this process had observed itself.
    @Test("onAppear() recovers lastRunAt and lastRunInputScope from watchers/<id>.run.json")
    func onAppearRecoversLastRunFromRunRecord() async throws {
        let root = makeTemporaryDirectory(prefix: "onAppearRecoversLastRunFromRunRecord")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "onAppearRecoversLastRunFromRunRecord-presets")

        try await handle.writeText(
            definitionText(id: "watcher-a", inputScope: "full_refined"), to: .watcherDefinition(id: "watcher-a")
        )
        try await handle.writeEnabledWatchers(["watcher-a"])
        try await handle.writeText("{\"note\":\"persisted note\"}", to: .watcherState(id: "watcher-a"))
        let finishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        // A scope that differs from the definition's current `full_refined`, i.e. the definition was
        // edited after this run -- the case the footer renders as "X（次回: Y）".
        try await handle.writeJSON(
            WatcherRunRecord(finishedAt: finishedAt, inputScope: .summaryAndRecent(count: 30)),
            to: .watcherRunRecord(id: "watcher-a")
        )

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        await viewModel.onAppear()

        #expect(viewModel.watcherItems.first?.lastRunAt == finishedAt)
        #expect(viewModel.watcherItems.first?.lastRunInputScope == .summaryAndRecent(count: 30))
        #expect(viewModel.watcherItems.first?.inputScope == .fullRefined)
    }

    /// The pre-`run.json` compatibility path: sessions recorded before that file existed still have
    /// a `state.json`, whose mtime is a faithful proxy for the run's completion time (it is written
    /// exactly once per successful run).
    @Test("onAppear() falls back to state.json's mtime when no run.json exists, leaving the scope nil")
    func onAppearFallsBackToStateMtimeWithoutRunRecord() async throws {
        let root = makeTemporaryDirectory(prefix: "onAppearFallsBackToStateMtimeWithoutRunRecord")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "onAppearFallsBackToStateMtimeWithoutRunRecord-presets")

        try await handle.writeText(definitionText(id: "watcher-a"), to: .watcherDefinition(id: "watcher-a"))
        try await handle.writeEnabledWatchers(["watcher-a"])
        let beforeWrite = Date()
        try await handle.writeText("{\"note\":\"persisted note\"}", to: .watcherState(id: "watcher-a"))

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        await viewModel.onAppear()

        let item = try #require(viewModel.watcherItems.first)
        let lastRunAt = try #require(item.lastRunAt, "the footer would say 未実行 under a rendered result")
        #expect(lastRunAt >= beforeWrite.addingTimeInterval(-1))
        #expect(item.lastRunInputScope == nil)
    }

    /// `initial_state` is not a run: rendering it must leave the footer honestly saying 未実行.
    @Test("onAppear() leaves lastRunAt nil when the render came from initial_state, not a real run")
    func onAppearLeavesLastRunAtNilForInitialStateRender() async throws {
        let root = makeTemporaryDirectory(prefix: "onAppearLeavesLastRunAtNilForInitialStateRender")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "onAppearLeavesLastRunAtNilForInitialStateRender-presets")

        try await handle.writeText(
            definitionText(id: "watcher-a", initialState: "{\"note\": \"initial note\"}"),
            to: .watcherDefinition(id: "watcher-a")
        )
        try await handle.writeEnabledWatchers(["watcher-a"])

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)
        await viewModel.onAppear()

        #expect(viewModel.watcherItems.first?.renderedMarkdown == "initial note")
        #expect(viewModel.watcherItems.first?.lastRunAt == nil)
        #expect(viewModel.watcherItems.first?.lastRunInputScope == nil)
    }

    @Test("onAppear() falls back to the definition's initial_state when no state.json is persisted yet")
    func onAppearFallsBackToInitialStateWhenNoPersistedState() async throws {
        let root = makeTemporaryDirectory(prefix: "onAppearFallsBackToInitialStateWhenNoPersistedState")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "onAppearFallsBackToInitialStateWhenNoPersistedState-presets")

        let text = """
        ---
        id: watcher-a
        name: Test Watcher
        trigger: on_manual
        state_mode: cumulative
        input_scope: summary
        schema:
          note: string
        initial_state: |
          {"note": "initial note"}
        view: |
          {{note}}
        ---

        # System

        system prompt

        # User

        {{state}}
        """
        try await handle.writeText(text, to: .watcherDefinition(id: "watcher-a"))
        try await handle.writeEnabledWatchers(["watcher-a"])

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)

        await viewModel.onAppear()

        #expect(viewModel.watcherItems.first?.renderedMarkdown == "initial note")
    }

    // MARK: - simpleWatcherSpec(id:)/convertSimpleWatcherToFull(id:) edge cases (§6.3, §7)

    @Test("simpleWatcherSpec(id:) returns nil for a full (non-simple) definition")
    func simpleWatcherSpecReturnsNilForFullDefinition() async throws {
        let root = makeTemporaryDirectory(prefix: "simpleWatcherSpecReturnsNilForFullDefinition")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "simpleWatcherSpecReturnsNilForFullDefinition-presets")

        try await handle.writeText(definitionText(id: "full-x"), to: .watcherDefinition(id: "full-x"))

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)

        #expect(await viewModel.simpleWatcherSpec(id: "full-x") == nil)
    }

    @Test("simpleWatcherSpec(id:) returns nil for an id with no resolvable definition")
    func simpleWatcherSpecReturnsNilForMissingId() async throws {
        let root = makeTemporaryDirectory(prefix: "simpleWatcherSpecReturnsNilForMissingId")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let created = try await store.createDraftSession()
        let handle = try await store.openSession(created.id)
        let presetsDirectory = makeTemporaryDirectory(prefix: "simpleWatcherSpecReturnsNilForMissingId-presets")

        let viewModel = makeViewModel(handle: handle, store: store, presetsDirectory: presetsDirectory)

        #expect(await viewModel.simpleWatcherSpec(id: "ghost") == nil)
    }

    // Note: `convertSimpleWatcherToFull(id:) throws .parseFailed for a non-simple definition` is
    // already covered above by `convertSimpleWatcherToFullThrowsParseFailedForNonSimpleId`.
}
