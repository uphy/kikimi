import Combine
import Foundation
import OSLog

// MARK: - DictationHistoryViewModel

/// View model backing the dictation history window (`docs/design/29-dictation-history.md`
/// section 6). Owns the loaded list, the currently selected entry's full detail, playback state,
/// and the footer's retained-entries cost summary (section 6.3).
///
/// Talks only to `DictationHistoryStoring`/`DictationHistoryStore` (`docs/design/29-dictation-
/// history.md` section 5) -- never `FileManager`/`URL` directly, mirroring `SessionListViewModel`'s
/// separation from `SessionStore`. Tests inject a stub `DictationHistoryStoring` conformer via the
/// `historyStore:` initializer parameter rather than the real, file-backed `DictationHistoryStore
/// .shared`. `.kikimiDictationHistoryRecorded` (section 5.1's list-refresh notification) is declared
/// by `DictationHistoryStore` itself, the same way `.kikimiLLMUsageRecorded` is declared by its
/// producer `UsageRecordingLLM` rather than by a consumer (`UsageRecordingLLM.swift:11`).
@MainActor
final class DictationHistoryViewModel: ObservableObject {
    /// Loaded via `DictationHistoryStore.listEntries()`, newest first (that method's own contract).
    @Published private(set) var items: [DictationHistoryStore.ListItem] = []
    /// Backing store for the list's single selection (`docs/design/29-dictation-history.md` section
    /// 6.2 describes a single selected entry driving the detail pane, unlike Session List's
    /// multi-select).
    @Published var selectedId: String?
    /// The full record for `selectedId`, loaded on demand via `readEntry(id:)` since `ListItem`
    /// deliberately omits `rawText`/`refinedText`/`targetBundleId`/etc. (section 5.1: `ListItem`
    /// "carries `llmUsage` so the footer summary can be aggregated ... without re-reading entry.json
    /// files" -- everything else stays out of the list-loading path).
    @Published private(set) var selectedEntry: DictationHistoryEntry?
    /// Aggregated cost/tokens over every *retained* entry's `llmUsage` (section 6.3) -- not an
    /// all-time total. Entries dropped by `DictationHistoryStore.finalize`'s max-entries rotation
    /// (`DictationHistoryPruning.entriesToDelete`) drop out of this sum along with everything else
    /// about them.
    @Published private(set) var retainedSummary: LLMUsageSummary = .empty
    /// The `id` of the entry currently playing back, or `nil`. Mirrors `MeetingWorkspaceViewModel
    /// .playingSegmentId`'s wiring to `SegmentAudioPlayer.onPlayingSegmentChanged`.
    @Published private(set) var playingId: String?

    /// `docs/design/29-dictation-history.md` section 6.2 (DH9): playback reuses `SegmentAudioPlayer`
    /// as-is with `localStartMs: 0` -- a dictation utterance is a single, un-segmented recording, so
    /// `SegmentPlaybackResolver`'s multi-recording-timeline concept doesn't apply.
    let segmentAudioPlayer = SegmentAudioPlayer()

    private let historyStore: any DictationHistoryStoring
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "DictationHistoryViewModel")
    private var historyRecordedObservation: AnyCancellable?

    init(historyStore: any DictationHistoryStoring = DictationHistoryStore.shared) {
        self.historyStore = historyStore
        segmentAudioPlayer.onPlayingSegmentChanged = { [weak self] id in
            self?.playingId = id
        }
    }

    /// Reloads `items` from `DictationHistoryStore.listEntries()` and re-aggregates
    /// `retainedSummary`. Keeps the current selection if it still exists in the reloaded list
    /// (reselecting/reloading its detail so an in-place edit -- e.g. a live
    /// `.kikimiDictationHistoryRecorded` refresh -- doesn't silently clear what the user is looking
    /// at); otherwise falls back to the newest entry, matching Session List's "first row selected by
    /// default" feel.
    func refresh() async {
        items = await historyStore.listEntries()
        retainedSummary = LLMUsageAggregator.summarize(
            records: items.compactMap(\.llmUsage),
            configPricing: AppConfig.shared.data.llm.pricing
        )
        if selectedId == nil || !items.contains(where: { $0.id == selectedId }) {
            selectedId = items.first?.id
        }
        await loadSelectedEntry()
    }

    /// Starts observing `.kikimiDictationHistoryRecorded` (posted by `DictationHistoryStore
    /// .finalize`, section 5.1) so a newly finalized utterance shows up in the list live while the
    /// window is open. Call once from the view's `.task`, mirroring `SessionListViewModel
    /// .startObservingLLMUsage()`'s subscription lifetime.
    func startObservingHistoryRecorded() {
        historyRecordedObservation = NotificationCenter.default.publisher(for: .kikimiDictationHistoryRecorded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refresh() }
            }
    }

    /// Loads the full `DictationHistoryEntry` for `selectedId` into `selectedEntry`. Called from
    /// `refresh()` and again whenever the view observes `selectedId` change (row click). A `nil`
    /// selection or a read failure (deleted out from under the window mid-session, corrupt
    /// `entry.json`) both clear `selectedEntry` rather than surfacing an error -- the detail pane
    /// just shows its own "no selection" placeholder either way.
    func loadSelectedEntry() async {
        guard let selectedId else {
            selectedEntry = nil
            return
        }
        do {
            selectedEntry = try await historyStore.readEntry(id: selectedId)
        } catch {
            logger.warning(
                "Failed to read dictation history entry \(selectedId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            selectedEntry = nil
        }
    }

    /// Context-menu "削除" (section 6.2). Stops playback first if the deleted entry happened to be
    /// playing, clears the selection if it was the one deleted, then reloads.
    func delete(id: String) {
        if playingId == id {
            segmentAudioPlayer.stop()
        }
        Task {
            await historyStore.deleteEntry(id: id)
            if selectedId == id {
                selectedId = nil
            }
            await refresh()
        }
    }

    /// Play/stop toggle for the detail pane's playback button (DH9). Tapping the currently-playing
    /// entry's button stops it; tapping any other entry (or the same one after it stopped) starts
    /// playback from the beginning of `audio.wav`, mirroring `MeetingWorkspaceViewModel
    /// .toggleSegmentPlayback(_:)`'s toggle behavior.
    func togglePlayback(id: String, fileURL: URL, durationMs: Int) {
        if playingId == id {
            segmentAudioPlayer.stop()
            return
        }
        segmentAudioPlayer.play(segmentId: id, fileURL: fileURL, localStartMs: 0, durationMs: durationMs)
    }

    /// `selectedEntry`'s single-call estimated cost (section 6.2's detail pane cost/token
    /// breakdown), computed from `llm_usage` via `LLMPricing.estimatedCostUSD` -- `nil` when there is
    /// no selection, no `llmUsage` (refine disabled, or a failed/fallback call), or `model` resolves
    /// to no pricing entry in either table. Unlike `retainedSummary` (which prefers a backend-
    /// reported `reportedCostUSD` per `LLMUsageAggregator`'s own resolution rule), the detail pane
    /// shows the estimate specifically, since design section 6.2 calls for the token breakdown
    /// alongside it and the two must be computed from the same formula to stay consistent on screen.
    var selectedEntryEstimatedCostUSD: Double? {
        guard let usage = selectedEntry?.llmUsage else { return nil }
        return Self.estimatedCostUSD(for: usage, configPricing: AppConfig.shared.data.llm.pricing)
    }

    /// Pure helper factored out of `selectedEntryEstimatedCostUSD` so it is directly unit-testable
    /// without constructing a whole view model.
    static func estimatedCostUSD(for usage: LLMUsageRecord, configPricing: [String: LLMModelPricing]) -> Double? {
        LLMPricing.estimatedCostUSD(
            model: usage.model,
            configPricing: configPricing,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadInputTokens: usage.cacheReadInputTokens,
            cacheCreationInputTokens: usage.cacheCreationInputTokens
        )
    }
}
