import AppKit
import OSLog
import SwiftUI

// MARK: - DictationAppContextSection

/// "アプリ別コンテキスト" section of the "入力" Settings tab (`docs/design/25-dictation-mode.md`
/// §14.5, rewired onto `PromptStore` by `docs/design/42-prompt-overrides.md` §7.3): the
/// `prompts/dictation.md` global editor, the registered per-app list (`prompts/dictation/apps/*.md`),
/// and the add/edit/reset flows around it. Split out of `SettingsView.swift`'s `DictationSettingsTab`
/// into its own file purely to keep that file under the project's `file_length` lint limit (same
/// rationale as `DiarizationConfig`'s doc comment for its own file split).
///
/// Binds directly to `PromptStore.shared`, mirroring `DictationSettingsTab`'s own `AppConfig.shared`
/// binding style -- this section has no derived state beyond what the store already holds. Unlike
/// the pre-42 `AppConfig`-backed version, every write here goes through `PromptStore`'s throwing
/// `writeOverride`/`removeOverride` (file I/O), so failures can now occur where they couldn't before.
/// They are logged rather than surfaced via an `.alert` (unlike e.g. `ProfilesSettingsTab`'s
/// rename/delete or this same tab's `deleteAllHistory`): the global editor's `TextEditor` writes
/// through on *every keystroke* (`globalBinding`'s `set`), so wiring the same helper to an
/// error-message `@State` would pop an alert per keystroke on a sustained I/O failure. Discrete
/// actions (reset/add/edit/delete below) share this same silent-log helper for simplicity; rare I/O
/// failures there are a knowingly-accepted gap versus the alert-based sibling pattern.
struct DictationAppContextSection: View {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "DictationAppContextSection")

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

    @ObservedObject private var promptStore = PromptStore.shared

    @State private var activeSheet: ActiveSheet?

    var body: some View {
        Section("アプリ別コンテキスト") {
            VStack(alignment: .leading, spacing: 4) {
                Text("グローバルコンテキスト（全アプリ共通）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // R17: this always shows the currently-effective body -- override if
                // `prompts/dictation.md` is active, otherwise the built-in default -- so the user
                // can always see exactly what is being sent to the LLM (§7.3's "送っている内容が
                // 常に見える" carry-over).
                TextEditor(text: globalBinding)
                    .font(.body.monospaced())
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Button("既定に戻す") {
                    // §7.3: "既定に戻す" removes the override file entirely (default restored),
                    // which is *not* the same as writing an empty-body override (that means "inject
                    // no context", the R17 escape hatch below).
                    removeOverride(.builtin(.dictation))
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
                            existingBundleIDs: Set(promptStore.dictationAppBundleIDs()),
                            onAdd: { bundleID in
                                // "追加" = an empty-body override file (§7.3: "追加シートは空本文
                                // ファイルを作成"), immediately followed by the edit sheet (R16).
                                // Validated construction, not `.dictationApp(bundleID:)` directly:
                                // `NSRunningApplication.bundleIdentifier` is not guaranteed to fit
                                // `[A-Za-z0-9._-]+`, and an out-of-charset id would write a file that
                                // `discoverDictationAppBundleIDs` then silently ignores.
                                guard let ref = PromptRef(dictationAppBundleID: bundleID) else {
                                    Self.logger.warning("Ignoring add for invalid bundle id: \(bundleID, privacy: .public)")
                                    return
                                }
                                writeOverride(ref, body: "")
                                activeSheet = .edit(bundleID: bundleID)
                            }
                        )
                    case let .edit(bundleID):
                        DictationEditAppContextSheet(
                            bundleID: bundleID,
                            initialBody: promptStore.policyBody(for: .dictationApp(bundleID: bundleID)),
                            onSave: { text in
                                writeOverride(.dictationApp(bundleID: bundleID), body: text)
                            }
                        )
                    }
                }
        }
    }

    @ViewBuilder
    private var appList: some View {
        let bundleIDs = promptStore.dictationAppBundleIDs()
        if bundleIDs.isEmpty {
            Text("登録済みのアプリはありません。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(bundleIDs, id: \.self) { bundleID in
                DictationAppContextRow(
                    bundleID: bundleID,
                    context: promptStore.policyBody(for: .dictationApp(bundleID: bundleID)),
                    onEdit: { activeSheet = .edit(bundleID: bundleID) },
                    onDelete: {
                        // "削除" = deleting `prompts/dictation/apps/<bundle-id>.md` (§7.3), which
                        // both removes the entry from `dictationAppBundleIDs()` and drops any
                        // context this app was injecting.
                        removeOverride(.dictationApp(bundleID: bundleID))
                    }
                )
            }
        }
    }

    private var globalBinding: Binding<String> {
        Binding(
            get: { promptStore.policyBody(for: .builtin(.dictation)) },
            // §7.3: an empty save writes an empty-body override (dictation's R17 escape hatch --
            // "文脈を注入しない" -- `PromptStore` accepts this only for dictation refs), it does
            // *not* map to `removeOverride` (that would flip the meaning back to "use default").
            set: { newValue in writeOverride(.builtin(.dictation), body: newValue) }
        )
    }

    private func writeOverride(_ ref: PromptRef, body: String) {
        do {
            try promptStore.writeOverride(ref, body: body)
        } catch {
            Self.logger.error(
                "Failed to write prompt override for \(String(describing: ref), privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func removeOverride(_ ref: PromptRef) {
        do {
            try promptStore.removeOverride(ref)
        } catch {
            Self.logger.error(
                "Failed to remove prompt override for \(String(describing: ref), privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}

// MARK: - DictationAppContextRow

/// One registered app: icon (if the app happens to be running -- `NSWorkspace.shared
/// .runningApplications` has no "look up by bundle id, running or not" API) + display name + the
/// context's first line as a preview + `[編集]`/`[削除]` (§14.5).
private struct DictationAppContextRow: View {
    let bundleID: String
    let context: String
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let icon = Self.runningIcon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.displayName(for: bundleID))
                Text(Self.firstLinePreview(context))
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
    let bundleID: String
    let initialBody: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(bundleID: String, initialBody: String, onSave: @escaping (String) -> Void) {
        self.bundleID = bundleID
        self.initialBody = initialBody
        self.onSave = onSave
        _draft = State(initialValue: initialBody)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(bundleID)
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
