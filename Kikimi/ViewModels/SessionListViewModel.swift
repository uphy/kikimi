import Combine
import Foundation
import OSLog

// MARK: - SessionListToast

/// A one-shot, defensive user notification surfaced by `SessionListViewModel`. Distinct from
/// `WorkspaceBanner` (`MeetingWorkspaceTypes.swift`), which is a persistent Session Window
/// header banner: toasts here exist purely for races the UI already guards against (e.g. the
/// delete button should already be disabled for a recording session), so they are transient and
/// dismiss on their own once shown. See `docs/design/06-ui-panels.md` section 5.4/11 (failure
/// mode #5).
enum SessionListToast: Equatable, Identifiable {
    /// `SessionListViewModel.delete(sessionId:)` was called for a session that is currently
    /// recording. The delete action itself is expected to already be disabled for that row
    /// (`docs/design/06-ui-panels.md` section 7), so reaching this case means two near-simultaneous
    /// clicks raced the disabled-state update.
    case cannotDeleteActiveRecording(sessionId: String)

    /// Stable per *case* (not per associated value), unlike `Equatable`'s synthesized
    /// implementation, which does compare `sessionId` (see `SessionListToastTests`). SwiftUI only
    /// ever holds a single `SessionListViewModel.toast` at a time (not an array keyed by id), so
    /// `id` exists purely to satisfy `Identifiable`, not to disambiguate concurrently-displayed
    /// toasts -- keeping it independent of `sessionId` avoids id churn if this enum grows more
    /// cases that carry other incidental identifying data.
    var id: String {
        switch self {
        case .cannotDeleteActiveRecording:
            return "cannotDeleteActiveRecording"
        }
    }

    /// User-facing message (`docs/design/06-ui-panels.md` section 11 failure mode #5).
    var message: String {
        switch self {
        case .cannotDeleteActiveRecording:
            return "録音中のセッションは削除できません"
        }
    }
}

// MARK: - SessionListGrouping

/// Pure, side-effect-free search/filter/grouping logic for the Session List window. Factored out
/// of `SessionListViewModel` so it is directly unit-testable against fixture `SessionMeta` arrays,
/// without needing to reach into the view model's `private(set)` `sessions` storage or spin up
/// `SessionStore`/`WindowManager` (`docs/design/06-ui-panels.md` section 5.4/12, mirroring the
/// `TranscriptRowList` pattern in `TranscriptRowList.swift`).
enum SessionListGrouping {
    /// Applies `stateFilter` then `searchText` (case-insensitive substring match against `title`)
    /// to `sessions`. `stateFilter == .all` intentionally still includes `recording` sessions
    /// (kikimi.md 10 章: "Draft / Recording / Ended の全状態を並べる（Draft のみ / Ended のみ の
    /// 絞り込みトグルあり）" — there is no dedicated "recording only" filter, so `.recording`
    /// sessions only ever show up under `.all`).
    static func filtered(
        _ sessions: [SessionMeta],
        searchText: String,
        stateFilter: SessionListViewModel.SessionStateFilter
    ) -> [SessionMeta] {
        var result = sessions
        switch stateFilter {
        case .all:
            break
        case .draftOnly:
            result = result.filter { $0.state == .draft }
        case .endedOnly:
            result = result.filter { $0.state == .ended }
        }

        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return result }
        return result.filter { $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    /// Groups `filtered(_:searchText:stateFilter:)`'s output by `createdAt`'s calendar month
    /// (`"yyyy-MM"`), most-recent month first, with sessions within a month sorted by `createdAt`
    /// descending — matching kikimi.md 10 章's Session List mockup ("▼ 2026-07" before "▼ 2026-06",
    /// newest session listed first within a month).
    static func groupedByMonth(
        _ sessions: [SessionMeta],
        searchText: String,
        stateFilter: SessionListViewModel.SessionStateFilter,
        calendar: Calendar = .current
    ) -> [(month: String, sessions: [SessionMeta])] {
        let sortedSessions = filtered(sessions, searchText: searchText, stateFilter: stateFilter)
            .sorted { $0.createdAt > $1.createdAt }

        var monthOrder: [String] = []
        var buckets: [String: [SessionMeta]] = [:]
        for session in sortedSessions {
            let month = monthKey(for: session.createdAt, calendar: calendar)
            if buckets[month] == nil {
                buckets[month] = []
                monthOrder.append(month)
            }
            buckets[month, default: []].append(session)
        }

        return monthOrder.map { (month: $0, sessions: buckets[$0] ?? []) }
    }

    /// `"yyyy-MM"` label for `date`'s calendar month, e.g. `"2026-07"`.
    private static func monthKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else {
            // `year`/`month` are only ever `nil` for calendars/dates that cannot be represented at
            // all (not expected for the Gregorian calendar this app always uses); fall back to a
            // single, stable bucket rather than crashing.
            return "unknown"
        }
        return String(format: "%04d-%02d", year, month)
    }
}

// MARK: - SessionListViewModel

/// View model backing the Session List window (`docs/design/06-ui-panels.md` section 5.4/7,
/// kikimi.md 10 章). Owns the search/filter UI state and the loaded session list; every mutating
/// operation delegates the actual work to `SessionStore`/`WindowManager` so this type never
/// touches `FileManager`/`URL` directly (section 1: "UI 層が `FileManager`/`URL` を直接操作する
/// ことはない").
///
/// `WindowManager.shared` (`docs/design/06-ui-panels.md` section 5.2) is not implemented yet as of
/// this module; this type is written directly against its documented API (mirrors the same
/// forward-reference pattern already used by `Kikimi/Window/SettingsWindowController.swift`) and
/// will compile once `WindowManager` lands.
@MainActor
final class SessionListViewModel: ObservableObject {
    /// Filter applied on top of `searchText` when building `groupedByMonth()`'s output. See
    /// `SessionListGrouping.filtered(_:searchText:stateFilter:)`.
    ///
    /// `Equatable`/`Hashable` beyond the design doc's minimal `CaseIterable` declaration (section
    /// 5.4) so SwiftUI can drive a `Picker`/segmented control off `allCases` (`id: \.self`) and so
    /// this is directly comparable in tests.
    enum SessionStateFilter: CaseIterable, Equatable, Hashable {
        case all
        case draftOnly
        case endedOnly
    }

    /// All sessions currently loaded from `SessionStore.listSessions()` (already sorted by
    /// `createdAt` descending), unfiltered. Use `groupedByMonth()` for the filtered/grouped view
    /// the UI actually renders.
    @Published private(set) var sessions: [SessionMeta] = []
    @Published var searchText: String = ""
    @Published var stateFilter: SessionStateFilter = .all
    /// Sessions `WindowManager.launch()` found via `SessionStore.detectIncompleteSessions()`
    /// (`docs/design/06-ui-panels.md` section 7/9). Written by `WindowManager`, not by this type —
    /// hence not `private(set)`.
    @Published var incompleteSessionsBanner: [SessionMeta] = []
    /// The most recent one-shot toast to show, if any (section 11 failure mode #5). The view is
    /// expected to clear this back to `nil` once it has been presented.
    @Published var toast: SessionListToast?
    /// All-time, all-session LLM usage total shown by the footer's cost badge
    /// (`docs/design/16-llm-usage-stats.md` section 5). Unlike `MeetingWorkspaceViewModel
    /// .llmUsageSummary` (one session), this aggregates every session's `llm_usage.jsonl` via
    /// `SessionStore.readAllLLMUsageRecords()` — there is no per-session/month breakdown, matching
    /// the design doc's "全期間合計のみ" scope.
    @Published private(set) var llmUsageSummary: LLMUsageSummary = .empty

    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SessionListViewModel")
    /// `.kikimiLLMUsageRecorded` subscription started by `startObservingLLMUsage()`, called once
    /// from `SessionListView`'s `.task` (mirrors `MeetingWorkspaceViewModel`'s
    /// `llmUsageObservation`/`startObservingLLMUsage()` pair in `+LLMUsage.swift`).
    private var llmUsageObservation: AnyCancellable?

    /// Reloads `sessions` from `SessionStore.listSessions()` and re-aggregates `llmUsageSummary`.
    func refresh() async {
        sessions = await SessionStore.shared.listSessions()
        await refreshLLMUsage()
    }

    /// Starts observing `.kikimiLLMUsageRecorded` for **every** session (no `sessionId` filter,
    /// unlike `MeetingWorkspaceViewModel.startObservingLLMUsage()` — this view aggregates across
    /// the whole Session List), triggering a full re-aggregate on each notification. Call once from
    /// the view's `.task`; a second call simply replaces the previous subscription.
    func startObservingLLMUsage() {
        llmUsageObservation = NotificationCenter.default.publisher(for: .kikimiLLMUsageRecorded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refreshLLMUsage() }
            }
    }

    /// Re-reads every session's `llm_usage.jsonl` (`SessionStore.readAllLLMUsageRecords()`, which
    /// deliberately avoids `openSession(_:)` — see that method's doc comment) and re-aggregates
    /// `llmUsageSummary` against `AppConfig.shared.data.llm.pricing`. Called from `refresh()` and
    /// again from `startObservingLLMUsage()`'s notification sink; usage records arrive at most a
    /// few times a minute, so a full re-read/re-aggregate each time is cheap enough
    /// (`docs/design/16-llm-usage-stats.md` section 5).
    func refreshLLMUsage() async {
        let records = await SessionStore.shared.readAllLLMUsageRecords()
        llmUsageSummary = LLMUsageAggregator.summarize(records: records, configPricing: AppConfig.shared.data.llm.pricing)
    }

    /// "開く" (section 7): opens (or brings to front) the Session Window for `sessionId`. Errors
    /// (e.g. `.sessionNotFound` when the folder was deleted out from under the list, failure mode
    /// #6) are left to the caller/UI to catch and present.
    func open(sessionId: String) async throws {
        try await WindowManager.shared.openWorkspace(sessionId: sessionId)
    }

    /// "+ 新規" (section 7): opens a fresh Draft workspace with no source session, then reloads
    /// `sessions` so the new Draft shows up immediately.
    func createNew() async throws {
        try await WindowManager.shared.createDraftWorkspace()
        await refresh()
    }

    /// "複製して新規セッション" (section 7): opens a Draft workspace seeded from `sessionId`'s
    /// `context.md`/`summary_template.md`, then reloads `sessions`.
    func duplicate(sessionId: String) async throws {
        try await WindowManager.shared.createDraftWorkspace(basedOn: sessionId)
        await refresh()
    }

    /// "削除" (section 5.4/7/11 failure mode #5). Deletes the session via `SessionStore`, then asks
    /// `WindowManager` to close its workspace window (if open) and drop its `AppState` entry, and
    /// finally reloads `sessions`.
    ///
    /// If `sessionId` is currently recording, `SessionStore.deleteSession(_:)` throws
    /// `.cannotDeleteActiveRecording`. The UI is expected to already disable the delete action for
    /// the recording row, so this is a defensive catch for the race window between two
    /// near-simultaneous clicks: it is logged and surfaced via `toast` rather than rethrown, since
    /// there is nothing further for a caller to do beyond what the UI already prevents.
    func delete(sessionId: String) async throws {
        do {
            try await SessionStore.shared.deleteSession(sessionId)
        } catch SessionStoreError.cannotDeleteActiveRecording {
            logger.warning("Ignored delete request for the actively recording session \(sessionId, privacy: .public)")
            toast = .cannotDeleteActiveRecording(sessionId: sessionId)
            return
        }
        WindowManager.shared.handleSessionDeleted(sessionId: sessionId)
        // A crashed session surfaced by the crash-recovery banner (`state: recording` on disk from a
        // previous run, so not `recordingSessionId` — the delete above succeeds) must also drop out
        // of `incompleteSessionsBanner`, otherwise the banner keeps naming a session that no longer
        // exists until the next launch.
        incompleteSessionsBanner.removeAll { $0.id == sessionId }
        await refresh()
    }

    // MARK: Crash recovery banner (design doc section 7 "起動時のクラッシュ復旧バナー")

    /// "復旧する": finalizes the crashed session (`meta.state` becomes `.ended`) and removes it
    /// from the banner.
    func recoverIncompleteSession(_ sessionId: String) async throws {
        try await SessionStore.shared.finalizeCrashedSession(sessionId)
        incompleteSessionsBanner.removeAll { $0.id == sessionId }
        await refresh()
    }

    /// "後で": dismisses the banner entry only. The session stays `state: recording` on disk
    /// (design doc section 7) until the user recovers it from a later banner or another launch.
    func dismissIncompleteSessionBanner(_ sessionId: String) {
        incompleteSessionsBanner.removeAll { $0.id == sessionId }
    }

    /// Grouped-by-month, filtered view of `sessions` (section 5.4/12). A thin wrapper around the
    /// pure `SessionListGrouping.groupedByMonth(_:searchText:stateFilter:)`, kept as an instance
    /// method with no parameters to match the design doc's public API (section 5.4) exactly.
    func groupedByMonth() -> [(month: String, sessions: [SessionMeta])] {
        SessionListGrouping.groupedByMonth(sessions, searchText: searchText, stateFilter: stateFilter)
    }
}
