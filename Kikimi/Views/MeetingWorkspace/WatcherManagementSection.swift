import SwiftUI

// MARK: - WatcherManagementSection

/// The Watcher management UI (enable/disable, edit, fork, delete, promote to preset) —
/// extracted out of the old `PrepTabView.watchersSection`/`watcherRow` into its own, standalone
/// view (`docs/design/17-session-window-redesign.md` §5.4, R5: "Watchers の管理 UI ... を Watchers
/// タブに集約し、準備画面からセクションを撤去").
///
/// Has **no compile-time dependency on `MeetingWorkspaceViewModel`** (same decoupling as
/// `PrepContentView`/`WatchersTabView`/`TranscriptTabView`): every operation is a plain closure the
/// caller wires to the matching `MeetingWorkspaceViewModel+Watchers.swift` method. Embedded by two
/// call sites: `PrepContentView`'s Draft-only "Watchers" `DisclosureGroup` (§3.1/§5.2) and
/// `WatchersTabView` (its empty-state body directly, its non-empty-state "管理" `DisclosureGroup`,
/// §5.4).
///
/// `docs/design/34-simple-watchers.md` section 6.1/6.3/7: "新規作成" now defaults to the simple
/// form (`SimpleWatcherFormSheet`), with a link inside it into the pre-existing full-form
/// `NewLocalWatcherSheet` path. Editing routes by `WatcherPanelItem.isSimple`/`.origin` (section
/// 6.3's table): simple + session-local -> editable simple form; simple + preset -> read-only
/// simple form; full -> the pre-existing `WatcherEditSheet` text editor; `.missing` keeps the "編集"
/// button disabled (unchanged). A session-local simple row also gets a one-way "詳細形式に変換…"
/// action (section 7) that, on success, hands off straight into `WatcherEditSheet` on the
/// freshly-converted text.
struct WatcherManagementSection: View {
    /// Enabled Watchers for this session, in `enabled.yaml` order (`MeetingWorkspaceViewModel
    /// .watcherItems` verbatim).
    var watcherItems: [WatcherPanelItem] = []
    var onSetWatcherEnabled: (_ id: String, _ enabled: Bool) -> Void = { _, _ in }
    var onForkPresetWatcher: (_ id: String) async -> Void = { _ in }
    var presetExists: (_ id: String) -> Bool = { _ in false }
    var onPromoteWatcherToPreset: (_ id: String) async -> Void = { _ in }
    var onCreateLocalWatcher: (_ id: String) async throws -> Void = { _ in }
    var onDeleteLocalWatcher: (_ id: String) async -> Void = { _ in }
    var availablePresets: () -> [String] = { [] }
    var loadWatcherDefinitionText: (_ id: String) async -> String? = { _ in nil }
    var onSaveLocalWatcherText: (_ id: String, _ text: String) async -> String? = { _, _ in nil }

    // MARK: Simple Watcher (docs/design/34-simple-watchers.md section 6.3/7), forwarded verbatim to
    // the matching MeetingWorkspaceViewModel+Watchers.swift method.

    /// `SimpleWatcherFormSheet`'s prefill source for an existing `kind: simple` row
    /// (`MeetingWorkspaceViewModel.simpleWatcherSpec(id:)`). Never called for the create flow.
    var loadSimpleWatcherSpec: (_ id: String) async -> SimpleWatcherSpec? = { _ in nil }
    /// The simple form's "作成" action (`createSimpleWatcher(_:)`) -- id-less; the ViewModel
    /// generates and enables a fresh id.
    var onCreateSimpleWatcher: (_ draft: SimpleWatcherSpecDraft) async throws -> Void = { _ in }
    /// The simple form's "保存" action for an existing `id` (`updateSimpleWatcher(id:_:)`).
    var onUpdateSimpleWatcher: (_ id: String, _ draft: SimpleWatcherSpecDraft) async throws -> Void = { _, _ in }
    /// "詳細形式に変換…" (`convertSimpleWatcherToFull(id:)`, section 7). Throws without touching disk
    /// on failure (parse/round-trip mismatch) -- this view surfaces that as an alert rather than
    /// opening the text editor.
    var onConvertSimpleWatcherToFull: (_ id: String) async throws -> Void = { _ in }

    @State private var isPresentingNewWatcherSheet = false
    @State private var isPresentingAddPresetSheet = false
    @State private var editingWatcherId: String?
    @State private var simpleFormMode: SimpleFormMode?
    @State private var pendingDeleteWatcherId: String?
    @State private var pendingPromoteWatcherId: String?
    @State private var pendingConvertWatcherId: String?
    @State private var conversionErrorMessage: String?

    /// Identifies which `SimpleWatcherFormSheet` presentation is active (section 6.1/6.3): a
    /// brand-new Watcher (no id yet), or an existing simple row being edited/viewed. Kept as one
    /// `Optional` (rather than two separate booleans/ids like the full-form sheets below) so
    /// `.sheet(item:)` naturally guarantees at most one simple-form presentation at a time.
    private enum SimpleFormMode: Identifiable, Equatable {
        case create
        case edit(id: String, isReadOnly: Bool)

        var id: String {
            switch self {
            case .create: return "__new_simple_watcher__"
            case .edit(let id, _): return id
            }
        }

        var editingId: String? {
            if case .edit(let id, _) = self { return id }
            return nil
        }

        var isReadOnly: Bool {
            if case .edit(_, let isReadOnly) = self { return isReadOnly }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if watcherItems.isEmpty {
                Text("有効な Watcher がありません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(watcherItems) { item in
                            watcherRow(item)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            HStack {
                // `docs/design/17-session-window-redesign.md` §6: plainer button labels than the old
                // "+ 新規 local watcher"/"+ preset から追加" (internal-jargon wording).
                // `docs/design/34-simple-watchers.md` §6.1: the default "新規作成" entry point is now
                // the simple form; full-form creation is reached from a link inside it.
                Button("新規作成") { simpleFormMode = .create }
                Button("プリセットから追加") { isPresentingAddPresetSheet = true }
                Spacer()
            }
            .padding(8)
        }
        .sheet(isPresented: $isPresentingNewWatcherSheet) {
            NewLocalWatcherSheet(onCreate: onCreateLocalWatcher)
        }
        .sheet(isPresented: $isPresentingAddPresetSheet) {
            AddPresetWatcherSheet(
                availablePresets: availablePresets,
                onAdd: { id in onSetWatcherEnabled(id, true) }
            )
        }
        .sheet(item: $simpleFormMode) { mode in
            SimpleWatcherFormSheet(
                editingId: mode.editingId,
                isReadOnly: mode.isReadOnly,
                loadSpec: {
                    guard let editingId = mode.editingId else { return nil }
                    return await loadSimpleWatcherSpec(editingId)
                },
                onSave: { draft in
                    if let editingId = mode.editingId {
                        try await onUpdateSimpleWatcher(editingId, draft)
                    } else {
                        try await onCreateSimpleWatcher(draft)
                    }
                },
                // `docs/design/34-simple-watchers.md` §6.1: offered only while creating -- tapping it
                // dismisses this sheet (`SimpleWatcherFormSheet` itself calls `dismiss()` first) and
                // hands off to the pre-existing full-form `NewLocalWatcherSheet` path.
                onOpenFullCreate: mode == .create ? { isPresentingNewWatcherSheet = true } : nil
            )
        }
        .sheet(isPresented: Binding(
            get: { editingWatcherId != nil },
            set: { isPresented in if !isPresented { editingWatcherId = nil } }
        )) {
            if let id = editingWatcherId, let item = watcherItems.first(where: { $0.id == id }) {
                WatcherEditSheet(
                    id: item.id,
                    name: item.name,
                    isReadOnly: item.origin == .preset,
                    loadText: { await loadWatcherDefinitionText(id) },
                    onSave: { text in await onSaveLocalWatcherText(id, text) }
                )
            }
        }
        .alert(
            "詳細形式に変換しますか？",
            isPresented: Binding(
                get: { pendingConvertWatcherId != nil },
                set: { isPresented in if !isPresented { pendingConvertWatcherId = nil } }
            )
        ) {
            Button("変換", role: .destructive) {
                if let id = pendingConvertWatcherId {
                    Task { await convertSimpleWatcherToFullAndEdit(id: id) }
                }
                pendingConvertWatcherId = nil
            }
            Button("キャンセル", role: .cancel) { pendingConvertWatcherId = nil }
        } message: {
            Text("変換すると簡易フォームでは編集できなくなります。")
        }
        .alert(
            "詳細形式への変換に失敗しました",
            isPresented: Binding(
                get: { conversionErrorMessage != nil },
                set: { isPresented in if !isPresented { conversionErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { conversionErrorMessage = nil }
        } message: {
            Text(conversionErrorMessage ?? "")
        }
        .alert(
            "Watcher を削除しますか？",
            isPresented: Binding(
                get: { pendingDeleteWatcherId != nil },
                set: { isPresented in if !isPresented { pendingDeleteWatcherId = nil } }
            )
        ) {
            Button("削除", role: .destructive) {
                if let id = pendingDeleteWatcherId {
                    Task { await onDeleteLocalWatcher(id) }
                }
                pendingDeleteWatcherId = nil
            }
            Button("キャンセル", role: .cancel) { pendingDeleteWatcherId = nil }
        } message: {
            Text("この操作は取り消せません。")
        }
        .alert(
            "同名のプリセットを上書きしますか？",
            isPresented: Binding(
                get: { pendingPromoteWatcherId != nil },
                set: { isPresented in if !isPresented { pendingPromoteWatcherId = nil } }
            )
        ) {
            Button("上書き", role: .destructive) {
                if let id = pendingPromoteWatcherId {
                    Task { await onPromoteWatcherToPreset(id) }
                }
                pendingPromoteWatcherId = nil
            }
            Button("キャンセル", role: .cancel) { pendingPromoteWatcherId = nil }
        } message: {
            Text("既存の同名プリセットは上書きされます。")
        }
    }

    private func watcherRow(_ item: WatcherPanelItem) -> some View {
        HStack(spacing: 8) {
            // Every row in `watcherItems` is, by construction, currently listed in `enabled.yaml`
            // (`refreshWatcherItems()` builds this list from it) -- including `.missing` ones (an
            // enabled id whose definition can't be resolved). So this checkbox is always checked;
            // unchecking it is what actually removes `item.id` from `enabled.yaml`.
            Toggle(
                "",
                isOn: Binding(
                    get: { true },
                    set: { newValue in onSetWatcherEnabled(item.id, newValue) }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                Text(Self.originLabel(item.origin))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("編集") { beginEditing(item) }
                .disabled(item.origin == .missing)

            watcherRowTrailingActions(item)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func watcherRowTrailingActions(_ item: WatcherPanelItem) -> some View {
        switch item.origin {
        case .preset:
            Button("fork") {
                Task { await onForkPresetWatcher(item.id) }
            }
        case .sessionLocal:
            Button("削除") { pendingDeleteWatcherId = item.id }
            // `docs/design/34-simple-watchers.md` §7: only a session-local *simple* row can be
            // ejected to full format -- a full row already is full format, and a preset row isn't
            // editable here at all (fork it first).
            if item.isSimple {
                Button("詳細形式に変換…") { pendingConvertWatcherId = item.id }
            }
            Button("プリセットとして保存") {
                if presetExists(item.id) {
                    pendingPromoteWatcherId = item.id
                } else {
                    Task { await onPromoteWatcherToPreset(item.id) }
                }
            }
        case .missing:
            EmptyView()
        }
    }

    /// "編集" routing (`docs/design/34-simple-watchers.md` §6.3's table): a simple row opens
    /// `SimpleWatcherFormSheet` (read-only for a preset, editable for session-local); a full row
    /// keeps the pre-existing `WatcherEditSheet` text editor. `.missing` never reaches here -- the
    /// button is disabled for that origin (`watcherRow(_:)`).
    private func beginEditing(_ item: WatcherPanelItem) {
        if item.isSimple {
            simpleFormMode = .edit(id: item.id, isReadOnly: item.origin == .preset)
        } else {
            editingWatcherId = item.id
        }
    }

    /// "詳細形式に変換…"'s confirmed action (`docs/design/34-simple-watchers.md` §7): converts `id` to
    /// full format and, only on success, opens the full-format `WatcherEditSheet` on it. A failure
    /// (parse error / round-trip mismatch) leaves the file untouched and surfaces
    /// `conversionErrorMessage` instead -- the row stays a simple Watcher.
    private func convertSimpleWatcherToFullAndEdit(id: String) async {
        do {
            try await onConvertSimpleWatcherToFull(id)
            editingWatcherId = id
        } catch {
            conversionErrorMessage = (error as? LocalizedError)?.errorDescription ?? "詳細形式への変換に失敗しました。"
        }
    }

    /// `docs/design/17-session-window-redesign.md` §6: `(preset)`/`(local)` renamed to plain-language
    /// `共通`/`この会議のみ`. `(見つかりません)` is unchanged.
    private static func originLabel(_ origin: WatcherOrigin) -> String {
        switch origin {
        case .preset: return "共通"
        case .sessionLocal: return "この会議のみ"
        case .missing: return "(見つかりません)"
        }
    }
}
