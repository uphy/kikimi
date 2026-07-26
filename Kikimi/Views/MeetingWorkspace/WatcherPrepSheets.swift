import SwiftUI

// MARK: - WatcherPrepSheets
//
// Split out of `PrepTabView.swift` (alongside its existing `DuplicateFromSessionSheet`) to keep that
// file under the project's `file_length` lint limit -- these three sheets back `PrepTabView`'s
// Watchers section (`docs/design/05-watcher-runner.md` §10.3) exclusively and have no other caller.

// MARK: - NewLocalWatcherSheet

/// "[+ 新規 local watcher]" (`docs/design/05-watcher-runner.md` §10.3): prompts for an id, then calls
/// `onCreate(_:)` (`MeetingWorkspaceViewModel.createLocalWatcher(id:)`), which writes a minimal
/// scaffold and enables it. Surfaces `LocalWatcherCreationError`'s message inline rather than closing
/// the sheet on failure, so the user can fix the id and retry without re-opening it.
struct NewLocalWatcherSheet: View {
    let onCreate: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var idDraft = ""
    @State private var errorMessage: String?
    @State private var isCreating = false

    private var trimmedId: String { idDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新規 Local Watcher")
                .font(.headline)
            TextField("Watcher ID（英数字とハイフン）", text: $idDraft)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if isCreating {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("作成") {
                    isCreating = true
                    Task {
                        do {
                            try await onCreate(trimmedId)
                            isCreating = false
                            dismiss()
                        } catch {
                            errorMessage = (error as? LocalizedError)?.errorDescription ?? "作成に失敗しました。"
                            isCreating = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedId.isEmpty || isCreating)
            }
        }
        .padding()
        .frame(width: 360)
    }
}

// MARK: - AddPresetWatcherSheet

/// "[+ preset から追加]" (`docs/design/05-watcher-runner.md` §10.3): lists every preset not already
/// enabled for this session (`availablePresets()`) and, on confirmation, enables the selected one via
/// `onAdd(_:)` (`MeetingWorkspaceViewModel.setWatcherEnabled(id:enabled:)`) -- no file copy, since
/// definition resolution already prefers session-local over preset for the same id (kikimi.md 9 章).
struct AddPresetWatcherSheet: View {
    let availablePresets: () -> [String]
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var presets: [String] = []
    @State private var selectedId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preset から追加")
                .font(.headline)

            if presets.isEmpty {
                Text("追加できる preset がありません。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(presets, id: \.self, selection: $selectedId) { id in
                    Text(id)
                }
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("追加") {
                    guard let selectedId else { return }
                    onAdd(selectedId)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedId == nil)
            }
        }
        .padding()
        .frame(width: 360, height: 360)
        .onAppear { presets = availablePresets() }
    }
}

// MARK: - WatcherEditSheet

/// "[編集]" (`docs/design/05-watcher-runner.md` §10.3): a preset opens read-only (`isReadOnly == true`,
/// via `PlainTextEditor.isEditable`); a session-local Watcher is editable, and "保存" calls
/// `onSave(_:)` (`MeetingWorkspaceViewModel.saveLocalWatcherText(id:text:)`), which always persists
/// the text and returns a parse-warning message to show inline (`nil` on a clean parse). A returned
/// warning keeps the sheet open (§10.3 "保存自体は許す" -- the edit isn't lost, just flagged) instead of
/// dismissing; only a clean save auto-dismisses.
struct WatcherEditSheet: View {
    let id: String
    let name: String
    let isReadOnly: Bool
    let loadText: () async -> String?
    let onSave: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var warningMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isReadOnly ? "\(name)（プリセット・読み取り専用）" : "\(name) を編集")
                .font(.headline)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PlainTextEditor(text: $text, isEditable: !isReadOnly)
                    .frame(minHeight: 320)
            }

            if let warningMessage {
                Text(warningMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                if isSaving {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(isReadOnly ? "閉じる" : "キャンセル") { dismiss() }
                if !isReadOnly {
                    Button("保存") {
                        isSaving = true
                        Task {
                            let warning = await onSave(text)
                            isSaving = false
                            if let warning {
                                warningMessage = warning
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
                }
            }
        }
        .padding()
        .frame(width: 560, height: 480)
        .task {
            text = await loadText() ?? ""
            isLoading = false
        }
    }
}
