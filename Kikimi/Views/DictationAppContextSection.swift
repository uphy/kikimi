import AppKit
import SwiftUI

// MARK: - DictationAppContextSection

/// "アプリ別コンテキスト" section of the "入力" Settings tab (`docs/design/25-dictation-mode.md`
/// §14.5): `dictation.context.global`'s editor, the registered per-app list, and the
/// add/edit/reset flows around it. Split out of `SettingsView.swift`'s `DictationSettingsTab` into
/// its own file purely to keep that file under the project's `file_length` lint limit (same
/// rationale as `DiarizationConfig`'s doc comment for its own file split).
///
/// Binds directly to `AppConfig.shared`, mirroring `DictationSettingsTab`'s own binding style --
/// this section has no derived state beyond what `config.yaml` already holds.
struct DictationAppContextSection: View {
    /// A single `item:`-driven sheet identity so at most one of "add" / "edit" is ever presented at
    /// once. Deliberately *not* two separate `@State` bools + two `.sheet(isPresented:)` modifiers on
    /// this view: switching `editingBundleID` from nil to non-nil in the same action that calls the
    /// add sheet's `dismiss()` raced two sheet presentations attached to the same view identity, which
    /// is a known SwiftUI failure mode (the second sheet can silently fail to present), defeating R16's
    /// "選択するとその bundle id で空コンテキストのエントリが追加され、続けてテキスト編集に入る" requirement.
    private enum ActiveSheet: Identifiable {
        case add
        case edit(bundleID: String)

        var id: String {
            switch self {
            case .add: "add"
            case let .edit(bundleID): "edit-\(bundleID)"
            }
        }
    }

    @ObservedObject private var appConfig = AppConfig.shared

    @State private var activeSheet: ActiveSheet?

    var body: some View {
        Section("アプリ別コンテキスト") {
            VStack(alignment: .leading, spacing: 4) {
                Text("グローバルコンテキスト（全アプリ共通）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // R17: this starts pre-filled with the default rule body (not a placeholder-hidden
                // empty field) so the user can always see exactly what is being sent to the LLM.
                TextEditor(text: globalBinding)
                    .font(.body.monospaced())
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Button("既定に戻す") {
                    appConfig.update { $0.dictation.context.global = DictationContextConfig.default.global }
                }
            }
            .padding(.vertical, 4)

            appList

            Button("+ アプリを追加") { activeSheet = .add }
                // Attached to this row, not the enclosing `Section`: a modifier on `Section`
                // itself stops the grouped `Form` (List-backed) from recognizing it as a real
                // section, which broke inter-section spacing -- the next section's "履歴" header
                // rendered overlapping this section's last row.
                .sheet(item: $activeSheet) { sheet in
                    switch sheet {
                    case .add:
                        DictationAddAppContextSheet(
                            existingBundleIDs: Set(appConfig.data.dictation.context.apps.map(\.bundleID)),
                            onAdd: { bundleID in
                                appConfig.update {
                                    $0.dictation.context.apps.append(DictationAppContext(bundleID: bundleID, context: ""))
                                }
                                activeSheet = .edit(bundleID: bundleID)
                            }
                        )
                    case let .edit(bundleID):
                        if let app = appConfig.data.dictation.context.apps.first(where: { $0.bundleID == bundleID }) {
                            DictationEditAppContextSheet(
                                app: app,
                                onSave: { text in
                                    appConfig.update { config in
                                        guard let index = config.dictation.context.apps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
                                        config.dictation.context.apps[index].context = text
                                    }
                                }
                            )
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var appList: some View {
        if appConfig.data.dictation.context.apps.isEmpty {
            Text("登録済みのアプリはありません。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(appConfig.data.dictation.context.apps, id: \.bundleID) { app in
                DictationAppContextRow(
                    app: app,
                    onEdit: { activeSheet = .edit(bundleID: app.bundleID) },
                    onDelete: {
                        appConfig.update { $0.dictation.context.apps.removeAll { $0.bundleID == app.bundleID } }
                    }
                )
            }
        }
    }

    private var globalBinding: Binding<String> {
        Binding(
            get: { appConfig.data.dictation.context.global },
            set: { newValue in appConfig.update { $0.dictation.context.global = newValue } }
        )
    }
}

// MARK: - DictationAppContextRow

/// One registered app: icon (if the app happens to be running -- `NSWorkspace.shared
/// .runningApplications` has no "look up by bundle id, running or not" API) + display name + the
/// context's first line as a preview + `[編集]`/`[削除]` (§14.5).
private struct DictationAppContextRow: View {
    let app: DictationAppContext
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let icon = Self.runningIcon(for: app.bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.displayName(for: app.bundleID))
                Text(Self.firstLinePreview(app.context))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("編集", action: onEdit)
            Button("削除", role: .destructive, action: onDelete)
        }
        .padding(.vertical, 2)
    }

    /// Falls back to the raw bundle id when the app isn't currently running (§14.5's documented
    /// fallback for a previously-registered-but-now-quit app).
    private static func displayName(for bundleID: String) -> String {
        runningApplication(for: bundleID)?.localizedName ?? bundleID
    }

    private static func runningIcon(for bundleID: String) -> NSImage? {
        runningApplication(for: bundleID)?.icon
    }

    private static func runningApplication(for bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }

    private static func firstLinePreview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "（コンテキスト未設定）" }
        return trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
    }
}

// MARK: - DictationAddAppContextSheet

/// "+ アプリを追加" (§14.5/R16): lists every currently-running regular-activation-policy app that
/// isn't already registered, so the user never hand-types a bundle id (R16's rationale). Selecting
/// a row adds an empty-context entry and immediately opens it for editing (`onAdd`'s caller sets
/// `activeSheet = .edit(bundleID:)`).
private struct DictationAddAppContextSheet: View {
    let existingBundleIDs: Set<String>
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedBundleID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("アプリを追加")
                .font(.headline)

            if candidates.isEmpty {
                Text("追加できる起動中のアプリがありません。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(candidates, id: \.bundleIdentifier, selection: $selectedBundleID) { app in
                    HStack {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 20, height: 20)
                        }
                        Text(app.localizedName ?? app.bundleIdentifier ?? "")
                    }
                    .tag(app.bundleIdentifier)
                }
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("追加") {
                    // Deliberately does *not* also call the environment `dismiss()` here: `onAdd`
                    // already reassigns the parent's `activeSheet` to `.edit(bundleID:)` (so this
                    // sheet's content switches straight to the editor, R16's "続けてテキスト編集に
                    // 入る"). Calling `dismiss()` afterward would set that same `item:` binding back
                    // to nil in the same synchronous action, clobbering the reassignment above and
                    // closing the whole sheet instead of transitioning it.
                    guard let selectedBundleID else { return }
                    onAdd(selectedBundleID)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedBundleID == nil)
            }
        }
        .padding()
        .frame(width: 360, height: 360)
    }

    /// `.activationPolicy == .regular` (R16/§14.5): excludes background/agent processes that would
    /// be meaningless as a dictation target-app match. Already-registered bundle ids are filtered
    /// out so the same app can't be added twice (R14's "UI 側は同一 bundle id の重複登録自体を防ぐ").
    private var candidates: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && app.bundleIdentifier != nil
                && !existingBundleIDs.contains(app.bundleIdentifier!)
        }
    }
}

// MARK: - DictationEditAppContextSheet

/// `[編集]` (§14.5): a plain multi-line editor for one app's context addition (e.g. "Slack 向け:
/// 絵文字は使わない"). Saves on "保存" only -- unlike the global editor's live-binding `TextEditor`,
/// this is a draft so cancelling a half-written edit doesn't leave a partial string persisted.
private struct DictationEditAppContextSheet: View {
    let app: DictationAppContext
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(app: DictationAppContext, onSave: @escaping (String) -> Void) {
        self.app = app
        self.onSave = onSave
        _draft = State(initialValue: app.context)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(app.bundleID)
                .font(.headline)
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .frame(minWidth: 360, minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}
