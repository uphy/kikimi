import Foundation
import Testing

@testable import Kikimi

// MARK: - FakeDictationHistoryStore

/// Deterministic, file-I/O-free stand-in for `DictationHistoryStore`
/// (`docs/design/29-dictation-history.md` section 5.1's "テスト seam"). `beginEntry`/`finalize` are
/// implemented trivially since `DictationHistoryViewModel` never calls them (that's
/// `DictationController`'s concern) -- only `listEntries`/`readEntry`/`deleteEntry` are exercised
/// here.
private actor FakeDictationHistoryStore: DictationHistoryStoring {
    private var items: [DictationHistoryStore.ListItem]
    private var entriesById: [String: DictationHistoryEntry]
    private(set) var deletedIds: [String] = []
    private var readEntryError: Error?

    init(items: [DictationHistoryStore.ListItem] = [], entriesById: [String: DictationHistoryEntry] = [:]) {
        self.items = items
        self.entriesById = entriesById
    }

    func setItems(_ items: [DictationHistoryStore.ListItem]) {
        self.items = items
    }

    func setEntry(_ entry: DictationHistoryEntry, forId id: String) {
        entriesById[id] = entry
    }

    func setReadEntryError(_ error: Error?) {
        readEntryError = error
    }

    func beginEntry(startedAt: Date) throws -> DictationHistoryStore.EntryHandle {
        DictationHistoryStore.EntryHandle(
            id: "unused",
            directoryURL: URL(fileURLWithPath: "/dev/null"),
            audioFileURL: URL(fileURLWithPath: "/dev/null")
        )
    }

    func deleteEntry(id: String) {
        deletedIds.append(id)
        items.removeAll { $0.id == id }
        entriesById[id] = nil
    }

    func finalize(handle: DictationHistoryStore.EntryHandle, entry: DictationHistoryEntry, maxEntries: Int) throws {}

    func listEntries() -> [DictationHistoryStore.ListItem] {
        items
    }

    func readEntry(id: String) throws -> DictationHistoryEntry {
        if let readEntryError {
            throw readEntryError
        }
        guard let entry = entriesById[id] else {
            throw FakeDictationHistoryStoreError.notFound(id)
        }
        return entry
    }

    func deleteAll() throws {
        items = []
        entriesById = [:]
    }
}

private enum FakeDictationHistoryStoreError: Error, Equatable {
    case notFound(String)
    case boom
}

// MARK: - Test suite

@Suite("DictationHistoryViewModel")
@MainActor
struct DictationHistoryViewModelTests {
    // MARK: Fixtures

    private func listItem(
        id: String,
        recordedAt: Date = Date(timeIntervalSince1970: 1_751_000_000),
        finalText: String = "final text",
        durationMs: Int = 4_210,
        refineOutcome: String = "success",
        insertOutcome: String = "inserted",
        llmUsage: LLMUsageRecord? = nil
    ) -> DictationHistoryStore.ListItem {
        DictationHistoryStore.ListItem(
            id: id,
            recordedAt: recordedAt,
            finalText: finalText,
            durationMs: durationMs,
            refineOutcome: refineOutcome,
            insertOutcome: insertOutcome,
            llmUsage: llmUsage
        )
    }

    private func usageRecord(
        model: String = "claude-haiku-4-5-20251001",
        inputTokens: Int = 100,
        outputTokens: Int = 10,
        cacheReadInputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        reportedCostUSD: Double? = nil
    ) -> LLMUsageRecord {
        LLMUsageRecord(
            timestamp: Date(timeIntervalSince1970: 1_751_000_000),
            purpose: "dictation",
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            reportedCostUSD: reportedCostUSD
        )
    }

    private func entry(
        recordedAt: Date = Date(timeIntervalSince1970: 1_751_000_000),
        durationMs: Int = 4_210,
        targetBundleId: String? = "com.google.Chrome",
        rawText: String = "raw",
        refinedText: String? = "refined",
        finalText: String = "refined",
        refineOutcome: DictationHistoryRefineOutcome = .success,
        refineError: String? = nil,
        insertOutcome: DictationHistoryInsertOutcome = .inserted,
        llmUsage: LLMUsageRecord? = nil
    ) -> DictationHistoryEntry {
        DictationHistoryEntry(
            recordedAt: recordedAt,
            durationMs: durationMs,
            targetBundleId: targetBundleId,
            rawText: rawText,
            refinedText: refinedText,
            finalText: finalText,
            refineOutcome: refineOutcome,
            refineError: refineError,
            insertOutcome: insertOutcome,
            llmUsage: llmUsage
        )
    }

    /// Writes a short, valid mono 16kHz 16-bit PCM WAV file to a fresh temporary location so
    /// `togglePlayback(id:fileURL:durationMs:)` tests can exercise the real `SegmentAudioPlayer`
    /// (backed by an actual `AVAudioPlayer`) instead of a stub -- `DictationHistoryViewModel` does
    /// not inject a playback seam (`segmentAudioPlayer` is a concrete `SegmentAudioPlayer`, unlike
    /// `historyStore`'s `DictationHistoryStoring` protocol), so this is the only way to observe
    /// `playingId` transitions end-to-end. One second of silence at 16kHz is plenty of headroom
    /// for the short `durationMs` values used below.
    private func makeSilentWavFile() -> URL {
        let sampleRate: UInt32 = 16_000
        let sampleCount = Int(sampleRate) // 1 second
        let header = WavHeader(
            sampleRate: sampleRate,
            channels: 1,
            bitsPerSample: 16,
            dataByteCount: UInt32(sampleCount * 2)
        )
        var data = header.encode()
        data.append(Data(count: sampleCount * 2))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationHistoryViewModelTests-\(UUID().uuidString).wav")
        try? data.write(to: url)
        return url
    }

    /// Polls `predicate` until it becomes `true` or `timeout` elapses (mirrors
    /// `MeetingWorkspaceViewModelWatchersTests.waitUntil`) -- used for assertions on state written by
    /// `DictationHistoryViewModel.delete(id:)`'s fire-and-forget `Task` and by the
    /// `.kikimiDictationHistoryRecorded`-triggered reload.
    private func waitUntil(timeout: Duration = .seconds(5), predicate: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate(), "condition did not become true within \(timeout)")
    }

    // MARK: - refresh() list loading

    @Test("refresh() loads items from the store, newest first per the store's own ordering")
    func refreshLoadsItemsFromStore() async {
        let store = FakeDictationHistoryStore(items: [
            listItem(id: "b", recordedAt: Date(timeIntervalSince1970: 200)),
            listItem(id: "a", recordedAt: Date(timeIntervalSince1970: 100))
        ])
        let viewModel = DictationHistoryViewModel(historyStore: store)

        await viewModel.refresh()

        #expect(viewModel.items.map(\.id) == ["b", "a"])
    }

    @Test("refresh() against an empty store produces an empty list and .empty summary")
    func refreshWithNoEntriesProducesEmptyState() async {
        let store = FakeDictationHistoryStore()
        let viewModel = DictationHistoryViewModel(historyStore: store)

        await viewModel.refresh()

        #expect(viewModel.items.isEmpty)
        #expect(viewModel.retainedSummary == .empty)
        #expect(viewModel.selectedId == nil)
    }

    // MARK: - refresh() footer aggregation (section 6.3)

    @Test("refresh() aggregates only entries carrying llmUsage into retainedSummary, ignoring usage-less entries")
    func refreshAggregatesLlmUsageAcrossItems() async {
        let store = FakeDictationHistoryStore(items: [
            listItem(id: "a", llmUsage: usageRecord(inputTokens: 100, outputTokens: 10)),
            listItem(id: "b", llmUsage: usageRecord(inputTokens: 200, outputTokens: 20)),
            // disabled refinement (DH12): no llmUsage at all -- must not affect the sums below.
            listItem(id: "c", refineOutcome: "disabled", llmUsage: nil)
        ])
        let viewModel = DictationHistoryViewModel(historyStore: store)

        await viewModel.refresh()

        #expect(viewModel.retainedSummary.overall.callCount == 2)
        #expect(viewModel.retainedSummary.overall.inputTokens == 300)
        #expect(viewModel.retainedSummary.overall.outputTokens == 30)
    }

    @Test("refresh() recomputes retainedSummary from scratch each call (prune drops out of the total, section 6.3)")
    func refreshRecomputesSummaryFromCurrentItemsOnly() async {
        let store = FakeDictationHistoryStore(items: [
            listItem(id: "a", llmUsage: usageRecord(inputTokens: 100, outputTokens: 10))
        ])
        let viewModel = DictationHistoryViewModel(historyStore: store)
        await viewModel.refresh()
        #expect(viewModel.retainedSummary.overall.callCount == 1)

        // Simulate the entry falling out of the retained set (e.g. DH7 prune, or deletion).
        await store.setItems([])
        await viewModel.refresh()

        #expect(viewModel.retainedSummary == .empty)
    }

    // MARK: - Selection / detail loading

    @Test("loadSelectedEntry() reads the full entry for selectedId via the store")
    func loadSelectedEntryReadsFullDetail() async {
        let store = FakeDictationHistoryStore()
        await store.setEntry(entry(rawText: "きき身の履歴機能について"), forId: "a")
        let viewModel = DictationHistoryViewModel(historyStore: store)
        viewModel.selectedId = "a"

        await viewModel.loadSelectedEntry()

        #expect(viewModel.selectedEntry?.rawText == "きき身の履歴機能について")
    }

    @Test("loadSelectedEntry() clears selectedEntry when selectedId is nil")
    func loadSelectedEntryClearsWhenNoSelection() async {
        let store = FakeDictationHistoryStore()
        await store.setEntry(entry(), forId: "a")
        let viewModel = DictationHistoryViewModel(historyStore: store)
        viewModel.selectedId = "a"
        await viewModel.loadSelectedEntry()
        #expect(viewModel.selectedEntry != nil)

        viewModel.selectedId = nil
        await viewModel.loadSelectedEntry()

        #expect(viewModel.selectedEntry == nil)
    }

    @Test("loadSelectedEntry() clears selectedEntry (rather than throwing) when the store read fails")
    func loadSelectedEntryClearsOnReadFailure() async {
        let store = FakeDictationHistoryStore()
        await store.setReadEntryError(FakeDictationHistoryStoreError.boom)
        let viewModel = DictationHistoryViewModel(historyStore: store)
        viewModel.selectedId = "missing"

        await viewModel.loadSelectedEntry()

        #expect(viewModel.selectedEntry == nil)
    }

    @Test("refresh() keeps the current selection when it still exists in the reloaded list")
    func refreshKeepsSelectionWhenStillPresent() async {
        let store = FakeDictationHistoryStore(items: [
            listItem(id: "a", recordedAt: Date(timeIntervalSince1970: 100)),
            listItem(id: "b", recordedAt: Date(timeIntervalSince1970: 200))
        ])
        await store.setEntry(entry(rawText: "a's text"), forId: "a")
        await store.setEntry(entry(rawText: "b's text"), forId: "b")
        let viewModel = DictationHistoryViewModel(historyStore: store)
        await viewModel.refresh()
        viewModel.selectedId = "a"
        await viewModel.loadSelectedEntry()

        await viewModel.refresh()

        #expect(viewModel.selectedId == "a")
        #expect(viewModel.selectedEntry?.rawText == "a's text")
    }

    @Test("refresh() falls back to the newest entry when the previous selection no longer exists")
    func refreshFallsBackToNewestWhenSelectionRemoved() async {
        let store = FakeDictationHistoryStore(items: [
            listItem(id: "a", recordedAt: Date(timeIntervalSince1970: 100))
        ])
        let viewModel = DictationHistoryViewModel(historyStore: store)
        await viewModel.refresh()
        #expect(viewModel.selectedId == "a")

        await store.setItems([listItem(id: "b", recordedAt: Date(timeIntervalSince1970: 200))])
        await viewModel.refresh()

        #expect(viewModel.selectedId == "b")
    }

    // MARK: - delete(id:)

    @Test("delete(id:) removes the entry via the store and reloads the list")
    func deleteRemovesEntryAndReloads() async throws {
        let store = FakeDictationHistoryStore(items: [
            listItem(id: "a", recordedAt: Date(timeIntervalSince1970: 100)),
            listItem(id: "b", recordedAt: Date(timeIntervalSince1970: 200))
        ])
        let viewModel = DictationHistoryViewModel(historyStore: store)
        await viewModel.refresh()

        viewModel.delete(id: "b")

        try await waitUntil { viewModel.items.map(\.id) == ["a"] }
        let deletedIds = await store.deletedIds
        #expect(deletedIds == ["b"])
    }

    @Test("delete(id:) clears the selection when the deleted row was the one selected")
    func deleteClearsSelectionWhenSelected() async throws {
        let store = FakeDictationHistoryStore(items: [
            listItem(id: "a", recordedAt: Date(timeIntervalSince1970: 100))
        ])
        let viewModel = DictationHistoryViewModel(historyStore: store)
        await viewModel.refresh()
        #expect(viewModel.selectedId == "a")

        viewModel.delete(id: "a")

        try await waitUntil { viewModel.items.isEmpty }
        #expect(viewModel.selectedId == nil)
    }

    @Test("delete(id:) stops playback first when the deleted row is the one currently playing")
    func deleteStopsPlaybackWhenDeletedRowIsPlaying() async throws {
        let store = FakeDictationHistoryStore(items: [
            listItem(id: "a", recordedAt: Date(timeIntervalSince1970: 100))
        ])
        let viewModel = DictationHistoryViewModel(historyStore: store)
        await viewModel.refresh()
        let wavURL = makeSilentWavFile()
        defer { try? FileManager.default.removeItem(at: wavURL) }
        viewModel.togglePlayback(id: "a", fileURL: wavURL, durationMs: 500)
        #expect(viewModel.playingId == "a")

        viewModel.delete(id: "a")

        try await waitUntil { viewModel.playingId == nil }
    }

    // MARK: - togglePlayback(id:fileURL:durationMs:) (DH9)

    @Test("togglePlayback(id:fileURL:durationMs:) starts playback and sets playingId to the entry's id")
    func togglePlaybackStartsPlayback() {
        let store = FakeDictationHistoryStore()
        let viewModel = DictationHistoryViewModel(historyStore: store)
        let wavURL = makeSilentWavFile()
        defer { try? FileManager.default.removeItem(at: wavURL) }

        viewModel.togglePlayback(id: "a", fileURL: wavURL, durationMs: 500)

        #expect(viewModel.playingId == "a")
    }

    @Test("togglePlayback(id:fileURL:durationMs:) called again for the currently-playing id stops it")
    func togglePlaybackStopsCurrentlyPlayingEntry() {
        let store = FakeDictationHistoryStore()
        let viewModel = DictationHistoryViewModel(historyStore: store)
        let wavURL = makeSilentWavFile()
        defer { try? FileManager.default.removeItem(at: wavURL) }
        viewModel.togglePlayback(id: "a", fileURL: wavURL, durationMs: 500)
        #expect(viewModel.playingId == "a")

        viewModel.togglePlayback(id: "a", fileURL: wavURL, durationMs: 500)

        #expect(viewModel.playingId == nil)
    }

    @Test("togglePlayback(id:fileURL:durationMs:) for a different id switches playback to the new entry")
    func togglePlaybackSwitchesToNewEntry() {
        let store = FakeDictationHistoryStore()
        let viewModel = DictationHistoryViewModel(historyStore: store)
        let wavURL = makeSilentWavFile()
        defer { try? FileManager.default.removeItem(at: wavURL) }
        viewModel.togglePlayback(id: "a", fileURL: wavURL, durationMs: 500)
        #expect(viewModel.playingId == "a")

        viewModel.togglePlayback(id: "b", fileURL: wavURL, durationMs: 500)

        #expect(viewModel.playingId == "b")
    }

    // MARK: - .kikimiDictationHistoryRecorded notification reload

    @Test("startObservingHistoryRecorded() reloads the list when .kikimiDictationHistoryRecorded is posted")
    func observesHistoryRecordedNotificationAndReloads() async throws {
        let store = FakeDictationHistoryStore()
        let viewModel = DictationHistoryViewModel(historyStore: store)
        await viewModel.refresh()
        #expect(viewModel.items.isEmpty)

        viewModel.startObservingHistoryRecorded()
        await store.setItems([listItem(id: "new-entry")])
        NotificationCenter.default.post(name: .kikimiDictationHistoryRecorded, object: nil)

        try await waitUntil { viewModel.items.map(\.id) == ["new-entry"] }
    }

    // MARK: - selectedEntryEstimatedCostUSD / estimatedCostUSD(for:configPricing:)

    @Test("estimatedCostUSD(for:configPricing:) computes cost via LLMPricing.estimatedCostUSD, config pricing wins over built-in")
    func estimatedCostUsesConfigPricingFirst() {
        let usage = usageRecord(model: "claude-haiku-4-5-20251001", inputTokens: 1_000_000, outputTokens: 1_000_000)
        let configPricing = ["claude-haiku-4-5": LLMModelPricing(inputUSDPerMTok: 2, outputUSDPerMTok: 4)]

        let cost = DictationHistoryViewModel.estimatedCostUSD(for: usage, configPricing: configPricing)

        #expect(cost == 6)
    }

    @Test("estimatedCostUSD(for:configPricing:) returns nil when the model resolves to no pricing entry")
    func estimatedCostReturnsNilForUnknownModel() {
        let usage = usageRecord(model: "totally-unknown-model-xyz")

        let cost = DictationHistoryViewModel.estimatedCostUSD(for: usage, configPricing: [:])

        #expect(cost == nil)
    }

    @Test("selectedEntryEstimatedCostUSD is nil when there is no selected entry")
    func selectedEntryEstimatedCostIsNilWithoutSelection() async {
        let store = FakeDictationHistoryStore()
        let viewModel = DictationHistoryViewModel(historyStore: store)
        await viewModel.refresh()

        #expect(viewModel.selectedEntry == nil)
        #expect(viewModel.selectedEntryEstimatedCostUSD == nil)
    }

    @Test("selectedEntryEstimatedCostUSD is nil when the selected entry has no llmUsage")
    func selectedEntryEstimatedCostIsNilWithoutUsage() async {
        let store = FakeDictationHistoryStore(items: [listItem(id: "a", llmUsage: nil)])
        await store.setEntry(entry(rawText: "no usage here", llmUsage: nil), forId: "a")
        let viewModel = DictationHistoryViewModel(historyStore: store)
        await viewModel.refresh()

        #expect(viewModel.selectedEntry?.rawText == "no usage here")
        #expect(viewModel.selectedEntryEstimatedCostUSD == nil)
    }

    @Test("selectedEntryEstimatedCostUSD matches estimatedCostUSD(for:configPricing:) for the selected entry's llmUsage")
    func selectedEntryEstimatedCostMatchesStaticHelper() async {
        let usage = usageRecord(model: "claude-haiku-4-5-20251001", inputTokens: 1_000_000, outputTokens: 1_000_000)
        let store = FakeDictationHistoryStore(items: [listItem(id: "a", llmUsage: usage)])
        await store.setEntry(entry(llmUsage: usage), forId: "a")
        let viewModel = DictationHistoryViewModel(historyStore: store)
        await viewModel.refresh()

        let expected = DictationHistoryViewModel.estimatedCostUSD(
            for: usage,
            configPricing: AppConfig.shared.data.llm.pricing
        )

        #expect(viewModel.selectedEntryEstimatedCostUSD == expected)
        #expect(expected != nil)
    }
}
