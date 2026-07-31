import SwiftUI

// MARK: - ProfileSaveSheet

/// "プロファイルとして保存…" sheet (`docs/design/41-meeting-profiles.md` §5), opened from
/// `PrepContentView`'s footer alongside "他セッションから複製…". Gathers the current session's prep
/// state into a `MeetingProfileDraft` (via `ProfileSaveComposer.compose(...)`) and hands it to
/// `onSave`.
///
/// Has **no compile-time dependency on `MeetingWorkspaceViewModel`** -- same decoupling as
/// `PrepContentView`'s other sheet (`DuplicateFromSessionSheet`): every I/O is a plain closure the
/// caller wires to `MeetingWorkspaceViewModel+Profiles.swift`.
struct ProfileSaveSheet: View {
    /// Snapshot of this session's current prep state (§5's four save-target rows), read fresh from
    /// disk once when the sheet appears. Callers wire this to
    /// `MeetingWorkspaceViewModel.profileSaveSourceSession()`.
    var loadSourceSession: () async -> ProfileSaveComposer.SourceSession = {
        ProfileSaveComposer.SourceSession(
            context: "", summaryTemplate: "", enabledWatcherIds: [], presetWatcherIds: [], participantIds: []
        )
    }
    /// Existing profile ids, for the id-collision overwrite confirmation (§5's #7). Callers wire this
    /// to `MeetingWorkspaceViewModel.existingProfileIds()`.
    var loadExistingProfileIds: () async -> [String] = { [] }
    /// The "保存" action. Callers wire this to `MeetingWorkspaceViewModel.saveMeetingProfile
    /// (_:overwrite:)`. Throwing here leaves this sheet open with `errorMessage` set (§5/§8 #8) --
    /// this view never dismisses on failure, only on success.
    var onSave: (_ draft: MeetingProfileDraft, _ overwrite: Bool) async throws -> Void = { _, _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var source: ProfileSaveComposer.SourceSession?
    @State private var existingProfileIds: [String] = []

    @State private var idDraft = ""
    @State private var nameDraft = ""
    // §5: "既定は全 ON" -- these start `true` and are only ever forced to `false` once `source` has
    // loaded and a given row's underlying content turns out to be empty/absent (the `.task` below),
    // matching that same row's `Toggle` becoming `disabled` at the same moment (§5: "対象が空/不在なら
    // disabled").
    @State private var includeContext = true
    @State private var includeSummaryTemplate = true
    @State private var includeWatchers = true
    @State private var includeParticipants = true

    @State private var isPendingOverwriteConfirmation = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var trimmedId: String { idDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedName: String { nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var idIsValid: Bool { MeetingProfileIdValidation.validate(trimmedId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("プロファイルとして保存")
                .font(.headline)

            idField
            nameField

            Divider()

            if let source {
                saveTargetsSection(source: source)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            footerControls
        }
        .padding()
        .frame(width: 420)
        .task {
            async let loadedSource = loadSourceSession()
            async let loadedIds = loadExistingProfileIds()
            let (resolvedSource, resolvedIds) = await (loadedSource, loadedIds)
            existingProfileIds = resolvedIds
            // §5: a row starts disabled+off the moment its underlying content turns out to be
            // empty/absent -- overridden here, once, right after the first (and only) load.
            includeContext = hasContent(resolvedSource.context)
            includeSummaryTemplate = hasContent(resolvedSource.summaryTemplate)
            includeWatchers = !resolvedSource.enabledWatcherIds.isEmpty
            includeParticipants = !resolvedSource.participantIds.isEmpty
            source = resolvedSource
        }
        .alert(
            "同名のプロファイルを上書きしますか？",
            isPresented: $isPendingOverwriteConfirmation
        ) {
            Button("上書き", role: .destructive) {
                if let source {
                    Task { await performSave(source: source, overwrite: true) }
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("既存の同名プロファイルは上書きされます。")
        }
    }

    // MARK: - id / name

    private var idField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("プロファイル ID（英数字とハイフン）", text: $idDraft)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            if !trimmedId.isEmpty, !idIsValid {
                Text("IDに使用できるのは英数字とハイフンのみです。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var nameField: some View {
        TextField("表示名", text: $nameDraft)
            .textFieldStyle(.roundedBorder)
    }

    // MARK: - Save targets (§5's 4 checkboxes)

    @ViewBuilder
    private func saveTargetsSection(source: ProfileSaveComposer.SourceSession) -> some View {
        let excludedWatcherIds = watcherExclusionPreview(source: source)

        VStack(alignment: .leading, spacing: 6) {
            Toggle("事前メモ（context.md）", isOn: $includeContext)
                .disabled(!hasContent(source.context))
            Toggle("サマリの構成（summary_template.md）", isOn: $includeSummaryTemplate)
                .disabled(!hasContent(source.summaryTemplate))
            Toggle("有効な Watcher", isOn: $includeWatchers)
                .disabled(source.enabledWatcherIds.isEmpty)
            // Shown independent of `includeWatchers` -- this is a statement about what saving this
            // row *would* drop, not about the row's current on/off state (§5: "黙って落とさない").
            if !excludedWatcherIds.isEmpty {
                Text(exclusionNoteText(excludedWatcherIds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("参加者名簿", isOn: $includeParticipants)
                .disabled(source.participantIds.isEmpty)
        }
    }

    /// `source.enabledWatcherIds` minus every id `source.presetWatcherIds` doesn't cover, deduplicated
    /// in original order -- the exact rule `ProfileSaveComposer.compose(...)` applies when
    /// `includeWatchers` is on, computed here independent of that toggle purely for this note's
    /// display (§5: the note is informational, not itself an inclusion decision).
    private func watcherExclusionPreview(source: ProfileSaveComposer.SourceSession) -> [String] {
        var seenIds = Set<String>()
        var excluded: [String] = []
        for watcherId in source.enabledWatcherIds where seenIds.insert(watcherId).inserted {
            if !source.presetWatcherIds.contains(watcherId) {
                excluded.append(watcherId)
            }
        }
        return excluded
    }

    private func exclusionNoteText(_ ids: [String]) -> String {
        let quotedIds = ids.map { "`\($0)`" }.joined(separator: "、")
        return "\(quotedIds) はこの会議専用のため保存されません。プリセットに昇格してから保存してください。"
    }

    private func hasContent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Footer / save

    private var footerControls: some View {
        HStack {
            if isSaving {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("キャンセル") { dismiss() }
            Button("保存") { beginSave() }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedId.isEmpty || !idIsValid || source == nil || isSaving)
        }
    }

    private func beginSave() {
        guard idIsValid, let source else { return }
        if existingProfileIds.contains(trimmedId) {
            isPendingOverwriteConfirmation = true
        } else {
            Task { await performSave(source: source, overwrite: false) }
        }
    }

    /// Builds the draft via `ProfileSaveComposer.compose(...)` from the current checkbox selection,
    /// then calls `onSave`. On failure, `errorMessage` is set and the sheet stays open (§5/§8 #8) --
    /// on success, it dismisses.
    private func performSave(source: ProfileSaveComposer.SourceSession, overwrite: Bool) async {
        isSaving = true
        errorMessage = nil

        let selection = ProfileSaveComposer.Selection(
            includeContext: includeContext,
            includeSummaryTemplate: includeSummaryTemplate,
            includeWatchers: includeWatchers,
            includeParticipants: includeParticipants
        )
        let result = ProfileSaveComposer.compose(
            id: trimmedId,
            name: trimmedName,
            description: nil,
            source: source,
            selection: selection
        )

        do {
            try await onSave(result.draft, overwrite)
            isSaving = false
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "プロファイルの保存に失敗しました。"
            isSaving = false
        }
    }
}
