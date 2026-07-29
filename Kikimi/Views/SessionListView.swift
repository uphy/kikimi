import Foundation
import SwiftUI

// MARK: - SessionListContextMenuAvailability

/// Pure, side-effect-free availability rules for `SessionListView`'s right-click context menu
/// items (`docs/design/06-ui-panels.md` section 7: "副次的に右クリックメニューからも「開く / 複製
/// して新規セッション / 削除」を実行できる（有効条件はフッタのボタンと同一）"). Factored out of
/// `SessionListView.contextMenuItems(for:)` so this mirrored logic is directly unit-testable
/// without instantiating a SwiftUI view — the same pattern `SessionListGrouping`
/// (`SessionListViewModel.swift`) uses for the list's filter/group logic.
enum SessionListContextMenuAvailability {
    /// "開く" / "複製して新規セッション" / "Markdown をコピー" are only enabled when exactly one
    /// session is selected (mirrors the footer's `onlySelectedSessionId`).
    static func canActOnSingleSelection(_ ids: Set<String>) -> Bool {
        ids.count == 1
    }

    /// "削除" is enabled for one or more selected sessions, unless the selection includes the
    /// actively-recording session (mirrors the footer's `selectionIncludesRecordingSession`;
    /// `SessionStore.deleteSession` would otherwise throw `.cannotDeleteActiveRecording` for it).
    static func canDelete(_ ids: Set<String>, recordingSessionId: String?) -> Bool {
        guard !ids.isEmpty else { return false }
        if let recordingSessionId, ids.contains(recordingSessionId) {
            return false
        }
        return true
    }
}

// MARK: - SessionListView

/// SwiftUI content for the Session List window (kikimi.md 10 章; `docs/design/06-ui-panels.md`
/// section 7). Hosted by `SessionListWindowController` via `NSHostingView`.
///
/// Layout follows the kikimi.md 10 章 mockup: a header (search + Draft/Ended filter + "+ 新規"),
/// an optional crash-recovery banner, a month-grouped session list supporting multi-selection
/// (Shift-click range, Command-click toggle), and a footer with "開く" / "複製して新規セッション"
/// (enabled only for a single selection) / "削除" (enabled for one or more) actions.
struct SessionListView: View {
    @ObservedObject var viewModel: SessionListViewModel
    /// Read only for `WindowManager.shared.recordingSessionId` (design doc section 7: "削除ボタンは
    /// `WindowManager.shared.recordingSessionId` と突き合わせて Recording 中の行を disabled にする").
    /// `@ObservedObject` so the footer's delete button reacts live if the selected session starts
    /// recording (from this window or another) while Session List is open.
    @ObservedObject private var windowManager = WindowManager.shared

    /// Backing store for `List(selection:)`. A `Set` (rather than a single optional id) is what
    /// enables `List`'s native Shift-click range / Command-click toggle multi-selection.
    @State private var selectedSessionIds: Set<String> = []
    @State private var toastMessage: String?
    /// Distinguishes overlapping `showToast(_:)` calls so an earlier toast's auto-dismiss timer
    /// can't clear a *later* toast that replaced it before its own 4s window elapsed (e.g. a
    /// thrown-error toast from `runAction` closely followed by a `viewModel.toast` toast).
    @State private var toastGeneration = 0
    @State private var isPerformingAction = false
    /// Session ids pending confirmation for "削除". Non-`nil` (and non-empty) shows the
    /// confirmation dialog; the dialog's title reflects the count for the multi-select case.
    @State private var pendingDeleteSessionIds: Set<String>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !viewModel.incompleteSessionsBanner.isEmpty {
                incompleteSessionsBannerView
                Divider()
            }
            sessionList
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 360)
        .task {
            // `docs/design/16-llm-usage-stats.md` section 5: starts the all-session
            // `.kikimiLLMUsageRecorded` subscription once per window lifetime, alongside the
            // existing session-list reload.
            viewModel.startObservingLLMUsage()
            await viewModel.refresh()
        }
        .onChange(of: viewModel.toast) { _, toast in
            // Surfaces `SessionListViewModel.toast` (e.g. `.cannotDeleteActiveRecording`, a
            // defensive race-window catch since the delete button is already disabled for the
            // recording row — design doc section 5.4/11 failure mode #5) through the same toast
            // UI used for thrown errors.
            guard let toast else { return }
            showToast(toast.message)
            viewModel.toast = nil
        }
        .overlay(alignment: .top) {
            if let toastMessage {
                ToastView(message: toastMessage)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { pendingDeleteSessionIds != nil },
                set: { isPresented in
                    if !isPresented { pendingDeleteSessionIds = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                if let sessionIds = pendingDeleteSessionIds {
                    performDelete(sessionIds)
                }
                pendingDeleteSessionIds = nil
            }
            Button("キャンセル", role: .cancel) {
                pendingDeleteSessionIds = nil
            }
        } message: {
            Text("音声データと書き起こしも含めて完全に削除されます。この操作は取り消せません。")
        }
    }

    /// Confirmation dialog title, pluralized for the multi-select case (`docs/design/06-ui-panels.md`
    /// section 7).
    private var deleteConfirmationTitle: String {
        let count = pendingDeleteSessionIds?.count ?? 0
        return count > 1 ? "\(count)件のセッションを削除しますか？" : "このセッションを削除しますか？"
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Sessions")
                .font(.headline)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("検索", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(width: 110)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

            Picker("", selection: $viewModel.stateFilter) {
                Text("すべて").tag(SessionListViewModel.SessionStateFilter.all)
                Text("Draft").tag(SessionListViewModel.SessionStateFilter.draftOnly)
                Text("Ended").tag(SessionListViewModel.SessionStateFilter.endedOnly)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .labelsHidden()

            Button {
                performCreateNew()
            } label: {
                Label("新規", systemImage: "plus")
            }
            .disabled(isPerformingAction)
        }
        .padding(10)
    }

    // MARK: Crash recovery banner (design doc section 7 "起動時のクラッシュ復旧バナー")

    private var incompleteSessionsBannerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(viewModel.incompleteSessionsBanner, id: \.id) { session in
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("前回のクラッシュにより「\(displayTitle(for: session))」が録音中のまま残っています。")
                        .font(.callout)
                    Spacer()
                    Button("復旧する") {
                        performRecover(session.id)
                    }
                    .disabled(isPerformingAction)
                    Button("後で") {
                        viewModel.dismissIncompleteSessionBanner(session.id)
                    }
                    .disabled(isPerformingAction)
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: Session list

    private var sessionList: some View {
        let groups = viewModel.groupedByMonth()
        return Group {
            if groups.isEmpty {
                VStack {
                    Spacer()
                    Text("セッションがありません")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // NOTE: Do not attach a `TapGesture` (even `.simultaneousGesture`) to a row here to
                // detect double-click. Doing so once regressed single-click selection almost
                // entirely: AppKit's underlying click recognizer has to wait out the double-click
                // interval to decide whether a click is the first tap of a pair, and once *any*
                // `UIGestureRecognizer`/`TapGesture` is attached to the row, that wait ends up
                // swallowing the mouse-down that `List` would otherwise use for its own native
                // single-click selection — so most single clicks silently failed to select while
                // Command+A (which never goes through the per-row recognizer) kept working. The
                // fix is `.contextMenu(forSelectionType:primaryAction:)`: it hooks into AppKit's
                // own double-click ("primary action") handling for the row *without* installing a
                // competing gesture recognizer, so `List`'s native single-click selection (and its
                // Shift-click range / Command-click toggle multi-selection) is completely
                // untouched. `primaryAction` fires with the *currently selected* id set at the
                // moment of the double-click; since double-clicking a row also selects only that
                // row first, this set is always exactly `[session.id]` in practice, but we still
                // guard for exactly one id defensively rather than assuming that.
                List(selection: $selectedSessionIds) {
                    ForEach(groups, id: \.month) { group in
                        Section(group.month) {
                            ForEach(group.sessions, id: \.id) { session in
                                SessionRow(session: session)
                                    .tag(session.id)
                                    .contentShape(Rectangle())
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    contextMenuItems(for: ids)
                } primaryAction: { ids in
                    guard ids.count == 1, let sessionId = ids.first else { return }
                    performOpen(sessionId)
                }
            }
        }
    }

    /// Menu content for `.contextMenu(forSelectionType:primaryAction:)`, invoked with whatever ids
    /// are selected at the time of a right-click (which may differ from `selectedSessionIds` if the
    /// right-click itself changed the selection). Mirrors the footer's "開く" / "複製して新規セッション"
    /// (single-selection only) / "削除" (one or more) actions so the context menu and footer stay
    /// in sync.
    @ViewBuilder
    private func contextMenuItems(for ids: Set<String>) -> some View {
        let onlyId = ids.count == 1 ? ids.first : nil
        let canActOnSingleSelection = SessionListContextMenuAvailability.canActOnSingleSelection(ids)
        Button("開く") {
            if let onlyId { performOpen(onlyId) }
        }
        .disabled(!canActOnSingleSelection)
        Button("複製して新規セッション") {
            if let onlyId { performDuplicate(onlyId) }
        }
        .disabled(!canActOnSingleSelection)
        Button("Markdown をコピー") {
            if let onlyId { performCopyMarkdown(onlyId) }
        }
        .disabled(!canActOnSingleSelection)
        Divider()
        Button("削除", role: .destructive) {
            guard !ids.isEmpty else { return }
            pendingDeleteSessionIds = ids
        }
        .disabled(!SessionListContextMenuAvailability.canDelete(ids, recordingSessionId: windowManager.recordingSessionId))
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            // All-time, all-session LLM cost total (`docs/design/16-llm-usage-stats.md` section 5).
            // Hidden until at least one LLM call has ever been recorded across every session, same
            // gating `MeetingWorkspaceView`'s header badge uses for its single-session total.
            if viewModel.llmUsageSummary.overall.callCount > 0 {
                LLMUsageBadge(summary: viewModel.llmUsageSummary, accessibilityLabel: "LLM 使用状況（全体）")
            }

            Spacer()

            // "開く" / "複製して新規セッション" only make sense for exactly one selected session.
            Button("開く") {
                if let onlySelectedSessionId {
                    performOpen(onlySelectedSessionId)
                }
            }
            .disabled(onlySelectedSessionId == nil || isPerformingAction)

            Button("複製して新規セッション") {
                if let onlySelectedSessionId {
                    performDuplicate(onlySelectedSessionId)
                }
            }
            .disabled(onlySelectedSessionId == nil || isPerformingAction)

            Button("削除") {
                guard !selectedSessionIds.isEmpty else { return }
                pendingDeleteSessionIds = selectedSessionIds
            }
            .disabled(selectedSessionIds.isEmpty || isPerformingAction || selectionIncludesRecordingSession)
        }
        .padding(10)
    }

    /// The single selected session id, or `nil` when zero or multiple sessions are selected
    /// (`docs/design/06-ui-panels.md` section 7: "開く" / "複製して新規セッション" require exactly
    /// one selection).
    private var onlySelectedSessionId: String? {
        selectedSessionIds.count == 1 ? selectedSessionIds.first : nil
    }

    /// Design doc section 7: compares against `WindowManager.shared.recordingSessionId`, not
    /// `session.state`, since that published value is the single source of truth for which session
    /// (if any) is actively recording in this process. Any recording session in the selection blocks
    /// bulk delete.
    private var selectionIncludesRecordingSession: Bool {
        guard let recordingSessionId = windowManager.recordingSessionId else { return false }
        return selectedSessionIds.contains(recordingSessionId)
    }

    private func displayTitle(for session: SessionMeta) -> String {
        session.title.isEmpty ? session.id : session.title
    }

    // MARK: Actions

    private func performOpen(_ sessionId: String) {
        runAction {
            try await viewModel.open(sessionId: sessionId)
        }
    }

    private func performCreateNew() {
        runAction {
            try await viewModel.createNew()
        }
    }

    private func performDuplicate(_ sessionId: String) {
        runAction {
            try await viewModel.duplicate(sessionId: sessionId)
        }
    }

    /// "Markdown をコピー" (`docs/design/37-transcript-markdown-copy.md` §3.3, TC9/TC11): unlike
    /// `runAction`'s operations, `copyMarkdown(sessionId:)` never throws -- it reports success/failure
    /// itself via `viewModel.toast`, which the existing `.onChange(of: viewModel.toast) → showToast(_:)`
    /// wiring already surfaces. No session-list reload is needed since copying doesn't mutate any
    /// session.
    private func performCopyMarkdown(_ sessionId: String) {
        Task {
            await viewModel.copyMarkdown(sessionId: sessionId)
        }
    }

    /// Deletes every session in `sessionIds`, one `viewModel.delete(sessionId:)` call at a time. A
    /// failure for one session is caught per-iteration (rather than via `runAction`'s single
    /// try/catch, which would abort the whole loop on the first error) and surfaced through the
    /// same transient-toast mechanism, so the remaining sessions still get deleted — matching the
    /// design doc's "1 件が失敗しても残りは継続する" bulk-delete requirement. Deleted ids are dropped
    /// from `selectedSessionIds` as they succeed, and `sessions` is reloaded once at the end.
    private func performDelete(_ sessionIds: Set<String>) {
        isPerformingAction = true
        Task {
            defer { isPerformingAction = false }
            for sessionId in sessionIds {
                do {
                    try await viewModel.delete(sessionId: sessionId)
                    selectedSessionIds.remove(sessionId)
                } catch {
                    showToast(error.localizedDescription)
                }
            }
            await viewModel.refresh()
        }
    }

    private func performRecover(_ sessionId: String) {
        runAction {
            try await viewModel.recoverIncompleteSession(sessionId)
        }
    }

    /// Runs an async view-model action, surfacing any thrown error as a transient toast (design
    /// doc section 11, failure modes #5/#6) and always reloading `sessions` afterward so a stale
    /// row (e.g. a session deleted out from under this window) disappears.
    private func runAction(_ operation: @escaping () async throws -> Void) {
        isPerformingAction = true
        Task {
            defer { isPerformingAction = false }
            do {
                try await operation()
            } catch {
                showToast(error.localizedDescription)
                await viewModel.refresh()
            }
        }
    }

    private func showToast(_ message: String) {
        toastGeneration += 1
        let generation = toastGeneration
        withAnimation { toastMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(4))
            // Only the toast that scheduled this dismissal may clear `toastMessage`; otherwise a
            // toast shown while this one was still on screen would get cut short.
            guard generation == toastGeneration else { return }
            withAnimation { toastMessage = nil }
        }
    }
}

// MARK: - SessionRow

private struct SessionRow: View {
    let session: SessionMeta

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.isEmpty ? "(無題)" : session.title)
                Text(SessionListFormatting.timestamp(session.startedAt ?? session.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(trailingLabel)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch session.state {
        case .draft: return "doc.text"
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle.fill"
        case .ended: return "doc.text.fill"
        }
    }

    private var iconColor: Color {
        switch session.state {
        case .recording: return .red
        case .paused: return .orange
        case .draft, .ended: return .secondary
        }
    }

    private var trailingLabel: String {
        switch session.state {
        case .draft: return "Draft"
        case .recording: return "Recording"
        case .paused: return "Paused (\(SessionListFormatting.duration(session.durationMs)))"
        case .ended: return SessionListFormatting.duration(session.durationMs)
        }
    }
}

// MARK: - ToastView

private struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
            .shadow(radius: 4)
    }
}

// MARK: - SessionListFormatting

/// Pure display-formatting helpers, kept free of view state so they stay directly unit-testable
/// (design doc section 12).
enum SessionListFormatting {
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// e.g. `2725000` ms -> `"45m"`, `4500000` ms -> `"1h15m"`.
    static func duration(_ milliseconds: Int) -> String {
        let totalMinutes = max(0, milliseconds) / 60_000
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        guard hours > 0 else { return "\(minutes)m" }
        return String(format: "%dh%02dm", hours, minutes)
    }
}
