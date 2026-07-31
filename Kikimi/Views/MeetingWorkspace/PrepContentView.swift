import SwiftUI

// MARK: - PrepContentView

/// The Session Window's preparation content (`docs/design/17-session-window-redesign.md` §3/§5.2;
/// supersedes `docs/design/06-ui-panels.md` section 6.2's Prep tab). Renamed from `PrepTabView`
/// (`git mv`) and re-laid-out as a single scrolling column instead of a `VSplitView` — this same view
/// now backs **two** call sites (`MeetingWorkspaceView`):
///
/// - The Draft-only dedicated preparation screen (no tab bar at all, `showsWatchersSection: true`).
/// - The "準備" tab shown once Recording/Paused/Ended (`showsWatchersSection: false`, since a
///   dedicated Watchers tab exists there instead, R5).
///
/// This view has **no compile-time dependency on `MeetingWorkspaceViewModel`** (which does not
/// (re)define it): it exposes the exact surface that view model provides (`contextText`/
/// `summaryTemplateText` bindings, `saveContext(_:)`/`saveSummaryTemplate(_:)`-shaped closures,
/// `duplicatePrepFiles(from:scope:)`, and — only consulted while `showsWatchersSection == true` —
/// the same `MeetingWorkspaceViewModel+Watchers.swift` closures `WatcherManagementSection` needs) as
/// plain parameters, mirroring how `PlainTextEditor` (which the "事前メモ" editor wraps) already
/// decouples itself from any concrete view model.
struct PrepContentView: View {
    /// The session this Prep content belongs to. Used only to keep the "他セッションから複製…" source
    /// picker from listing the current session as a copy source (kikimi.md 10 章 "他セッションから
    /// 複製").
    let sessionId: String

    @Binding var contextText: String
    @Binding var summaryTemplateText: String

    /// Debounced persistence hooks. `PlainTextEditor` (which each editor below wraps) already
    /// performs the 500ms debounce (section 6.2 "textDidChange をデバウンス（例: 500ms）した上で
    /// saveContext(_:)/saveSummaryTemplate(_:) を呼ぶ"); these closures are invoked with the
    /// debounced text. Callers wire these to `MeetingWorkspaceViewModel.saveContext(_:)`/
    /// `saveSummaryTemplate(_:)`. Default to no-ops so previews/tests that only care about the live
    /// bindings don't have to supply persistence.
    var onContextChange: (String) -> Void = { _ in }
    var onSummaryTemplateChange: (String) -> Void = { _ in }

    /// Invoked when the user confirms a source session + scope in the duplicate sheet. Callers wire
    /// this to `MeetingWorkspaceViewModel.duplicatePrepFiles(from:scope:)`, which calls
    /// `SessionHandle.copyPrepFiles(from:scope:)` (`docs/design/07-session-store.md` section 8) and
    /// then refreshes `contextText`/`summaryTemplateText` from disk so this view reflects the copied
    /// content.
    var duplicatePrepFiles: (_ sourceSessionId: String, _ scope: PrepCopyScope) async -> Void

    // MARK: Participant roster (`docs/design/22-participant-hints.md` §5), only ever consulted for the
    // "参加者" section below -- forwarded verbatim from `MeetingWorkspaceViewModel`'s
    // `+Participants.swift` surface without this view ever importing that view model type.

    /// The current roster, in add order (design section 4.1's `ParticipantHintItem`). Rendered as one
    /// row per entry; `name == nil` renders as "不明な話者" (the id no longer resolves to any registered
    /// `VoiceprintSpeaker`, design section 6).
    var participantHints: [ParticipantHintItem] = []
    /// Suggest-box candidates (design section 4.3), already refreshed by the caller
    /// (`viewModel.refreshKnownVoiceprintSpeakers()`) -- this view never fetches them itself.
    var knownSpeakers: [VoiceprintSpeaker] = []
    /// Set by `MeetingWorkspaceViewModel.addParticipantHint(_:)` when a submission couldn't be resolved
    /// (design section 4.1's `.ambiguous` branch, or a registration failure) -- surfaced here as a red
    /// caption rather than silently dropped.
    var participantHintError: String?
    /// Suggest-box submission handler. Callers wire this to
    /// `Task { await viewModel.addParticipantHint(submission) }` (design section 4.1) -- this view stays
    /// synchronous/non-`async` like every other closure it exposes.
    var onAddParticipant: (_ submission: SpeakerRenameSubmission) -> Void = { _ in }
    /// Callers wire this to `Task { await viewModel.removeParticipantHint(id: id) }`.
    var onRemoveParticipant: (_ id: String) -> Void = { _ in }

    /// Supplies the candidate sessions for the "他セッションから複製…" sheet (section 6.2: "ソース
    /// 選択 UI は Session List のセッション選択 UI を軽量に再利用する（別ウィンドウを開かず、シート/
    /// ポップオーバーで完結させる想定）"). Defaults to `SessionStore.shared.listSessions()`
    /// (already newest-first); overridable for previews/tests.
    var loadAvailableSessions: () async -> [SessionMeta] = { await SessionStore.shared.listSessions() }

    // MARK: "プロファイルとして保存…" (`docs/design/41-meeting-profiles.md` §5, §6.3), forwarded verbatim
    // to `ProfileSaveSheet` / wired by callers to `MeetingWorkspaceViewModel+Profiles.swift`.

    /// `ProfileSaveSheet`'s save-target snapshot. Wired to `MeetingWorkspaceViewModel
    /// .profileSaveSourceSession()`.
    var loadProfileSaveSourceSession: () async -> ProfileSaveComposer.SourceSession = {
        ProfileSaveComposer.SourceSession(
            context: "", summaryTemplate: "", enabledWatcherIds: [], presetWatcherIds: [], participantIds: []
        )
    }
    /// Wired to `MeetingWorkspaceViewModel.existingProfileIds()`.
    var loadExistingProfileIds: () async -> [String] = { [] }
    /// Wired to `MeetingWorkspaceViewModel.saveMeetingProfile(_:overwrite:)`.
    var onSaveProfile: (_ draft: MeetingProfileDraft, _ overwrite: Bool) async throws -> Void = { _, _ in }
    /// The header-adjacent provenance line (§6.3: "プロファイル: <name>" / "<id>（削除済みプロファイル）").
    /// `nil` (the default) renders nothing -- matches a session whose Draft was never seeded from a
    /// profile. Wired to `MeetingWorkspaceViewModel.profileProvenanceLabel()`.
    var loadProfileProvenanceLabel: () async -> String? = { nil }

    /// `docs/design/17-session-window-redesign.md` §5.2 B-2: the persistence-lag hint below the
    /// "事前メモ" editor is shown only while this session is actively Recording/Paused. Wired by the
    /// caller from `viewModel.recordingButtonState.blocksWindowClose` — the one existing property
    /// that already answers exactly "is this session currently Recording/Paused (including its
    /// transient in-flight sub-states)", the same question `MeetingWorkspaceWindowController
    /// .windowShouldClose` asks it for (see that property's own doc comment).
    var isRecordingActive: Bool = false

    /// `docs/design/17-session-window-redesign.md` §3.1/§5.1/R5: only the Draft-only dedicated screen
    /// embeds the Watchers management section inline — a dedicated Watchers tab exists once tabs are
    /// shown, so the "準備" tab itself no longer repeats it.
    var showsWatchersSection: Bool = false

    // MARK: Watchers management (`docs/design/05-watcher-runner.md` §10.3), only consulted while
    // `showsWatchersSection == true` -- forwarded verbatim to `WatcherManagementSection`.

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

    // MARK: Simple Watcher (`docs/design/34-simple-watchers.md` section 6.3/7), forwarded verbatim
    // to `WatcherManagementSection`.

    var loadSimpleWatcherSpec: (_ id: String) async -> SimpleWatcherSpec? = { _ in nil }
    var onCreateSimpleWatcher: (_ draft: SimpleWatcherSpecDraft) async throws -> Void = { _ in }
    var onUpdateSimpleWatcher: (_ id: String, _ draft: SimpleWatcherSpecDraft) async throws -> Void = { _, _ in }
    var onConvertSimpleWatcherToFull: (_ id: String) async throws -> Void = { _ in }

    @State private var isPresentingDuplicateSheet = false
    @State private var isPresentingProfileSaveSheet = false
    /// Set from `loadProfileProvenanceLabel()` by the `.task` below, once, when this view first
    /// appears (`docs/design/41-meeting-profiles.md` §6.3). Not re-resolved on every render -- see
    /// `MeetingWorkspaceViewModel.profileProvenanceLabel()`'s own doc comment on why a stale snapshot
    /// is acceptable here.
    @State private var profileProvenanceLabel: String?

    /// kikimi.md 7 章: "ファイルサイズ上限は 32KB". Mirrors `SessionHandle.contextSizeLimitBytes`
    /// (`SessionHandle+Prep.swift`), which is `private` to that file; kept as a separate constant
    /// here rather than exposing that one, since this view only needs it for the byte-count
    /// indicator, never for actually enforcing the limit (`SessionHandle` still saves oversized
    /// content in full and only logs a warning, section 6.2).
    private static let contextByteLimit = 32 * 1_024
    /// kikimi.md 8 章: "ファイルサイズ上限 16KB". See `contextByteLimit`'s note above.
    private static let summaryTemplateByteLimit = 16 * 1_024

    private static let contextPlaceholder =
        "参加者・アジェンダ・専門用語を書いておくと、書き起こしの整形とサマリの精度が上がります"
    private static let recordingHint =
        "ここの変更は次のサマリ更新から反映されます。書き起こしの整形には少し遅れて反映されます。"
    private static let summaryTemplateVariablesHint =
        "使用できる変数: {{title}} {{overview}} {{decisions}} {{action_items}} {{participants}}"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // §6.3: displayed only once this session's provenance actually resolves to
                // something -- a session never seeded from a profile shows nothing here at all.
                if let profileProvenanceLabel {
                    Text(profileProvenanceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                contextSection

                ParticipantsSectionView(
                    participantHints: participantHints,
                    knownSpeakers: knownSpeakers,
                    participantHintError: participantHintError,
                    onAddParticipant: onAddParticipant,
                    onRemoveParticipant: onRemoveParticipant
                )

                DisclosureGroup("サマリの構成をカスタマイズ") {
                    summaryTemplateSection
                        .padding(.top, 8)
                }

                if showsWatchersSection {
                    DisclosureGroup("Watchers") {
                        WatcherManagementSection(
                            watcherItems: watcherItems,
                            onSetWatcherEnabled: onSetWatcherEnabled,
                            onForkPresetWatcher: onForkPresetWatcher,
                            presetExists: presetExists,
                            onPromoteWatcherToPreset: onPromoteWatcherToPreset,
                            onCreateLocalWatcher: onCreateLocalWatcher,
                            onDeleteLocalWatcher: onDeleteLocalWatcher,
                            availablePresets: availablePresets,
                            loadWatcherDefinitionText: loadWatcherDefinitionText,
                            onSaveLocalWatcherText: onSaveLocalWatcherText,
                            loadSimpleWatcherSpec: loadSimpleWatcherSpec,
                            onCreateSimpleWatcher: onCreateSimpleWatcher,
                            onUpdateSimpleWatcher: onUpdateSimpleWatcher,
                            onConvertSimpleWatcherToFull: onConvertSimpleWatcherToFull
                        )
                        .padding(.top, 8)
                    }
                }
            }
            .padding(12)
        }
        .safeAreaInset(edge: .bottom) {
            footerControls
        }
        .sheet(isPresented: $isPresentingDuplicateSheet) {
            DuplicateFromSessionSheet(
                currentSessionId: sessionId,
                loadAvailableSessions: loadAvailableSessions,
                onApply: duplicatePrepFiles
            )
        }
        .sheet(isPresented: $isPresentingProfileSaveSheet) {
            ProfileSaveSheet(
                loadSourceSession: loadProfileSaveSourceSession,
                loadExistingProfileIds: loadExistingProfileIds,
                onSave: onSaveProfile
            )
        }
        .task {
            profileProvenanceLabel = await loadProfileProvenanceLabel()
        }
    }

    // MARK: - 事前メモ (B-1: renamed from "Context", now the visual centerpiece)

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("事前メモ")
                    .font(.headline)
                Spacer()
                ByteCountLabel(text: contextText, limitBytes: Self.contextByteLimit)
            }

            PlainTextEditor(
                text: $contextText,
                placeholder: Self.contextPlaceholder,
                onDebouncedChange: onContextChange
            )
            .frame(minHeight: 200)

            // B-2: shown only while Recording/Paused, in place of the old always-on, jargon-heavy hint.
            if isRecordingActive {
                Text(Self.recordingHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - サマリの構成をカスタマイズ (Summary Template, now collapsed by default)

    private var summaryTemplateSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Summary Template")
                    .font(.subheadline)
                Spacer()
                ByteCountLabel(text: summaryTemplateText, limitBytes: Self.summaryTemplateByteLimit)
            }

            PlainTextEditor(text: $summaryTemplateText, onDebouncedChange: onSummaryTemplateChange)
                .frame(minHeight: 160)

            Text(Self.summaryTemplateVariablesHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footerControls: some View {
        HStack {
            // B-4: the old always-disabled "初期値に戻す" button is removed entirely (no
            // `AppConfig.shared`-backed settings feature exists yet to revert to) rather than kept
            // as permanently-disabled chrome.
            Spacer()

            // `docs/design/41-meeting-profiles.md` §6.3: added alongside "他セッションから複製…" --
            // the reverse direction (session -> named preset instead of session -> session).
            Button("プロファイルとして保存…") {
                isPresentingProfileSaveSheet = true
            }

            Button("他セッションから複製…") {
                isPresentingDuplicateSheet = true
            }
        }
        .padding(8)
        .background(.bar)
    }
}

// MARK: - ParticipantsSectionView

/// The "参加者" section (`docs/design/22-participant-hints.md` §5): the current roster plus a suggest
/// box to add to it. Split out of `PrepContentView.body` for the same reason `ByteCountLabel`/
/// `DuplicateFromSessionSheet` below are their own types -- it owns `draft`, the suggest box's own
/// transient `@State`, which has no business living on `PrepContentView` itself (which owns only the
/// two `@Binding` text editors the caller's view model actually persists).
///
/// Deliberately **not** a `.popover`/`NSPopover`-backed picker, unlike the rename flow's
/// `KnownSpeakerPickerView` (`RenameSpeakerPopoverView.swift`) -- design section 5 calls this out
/// explicitly ("NSPopover / .popover は使わない... kikimi-verify で検出不能なため避ける"): the candidate list
/// below is a plain inline `VStack` that appears/disappears with the draft text, not a floating panel.
private struct ParticipantsSectionView: View {
    let participantHints: [ParticipantHintItem]
    let knownSpeakers: [VoiceprintSpeaker]
    let participantHintError: String?
    let onAddParticipant: (_ submission: SpeakerRenameSubmission) -> Void
    let onRemoveParticipant: (_ id: String) -> Void

    @State private var draft = ""

    private static let caption =
        "入力すると、話者の自動認識をこの参加者に絞り込みます。未入力ならすべての登録話者から照合します"
    private static let noVoiceprintCaption =
        "声紋未登録 — 会議中に一度発言へ割り当てると学習されます"

    private var trimmedDraft: String { SpeakerName.trimmed(draft) }

    /// design section 4.3: substring-filtered against `knownSpeakers`, with already-rostered speakers
    /// excluded from the candidate list (they have nothing left to add).
    private var suggestions: [VoiceprintSpeaker] {
        guard !trimmedDraft.isEmpty else { return [] }
        let rosterIds = Set(participantHints.map(\.id))
        return knownSpeakers.filter {
            !rosterIds.contains($0.id) && $0.name.localizedCaseInsensitiveContains(trimmedDraft)
        }
    }

    /// design section 4.3: the "新しい話者として登録" row appears only when *no* known speaker (rostered or
    /// not -- registering a duplicate of an already-rostered name makes no more sense than registering a
    /// duplicate of an unrostered one) trimmed-exact-matches the draft.
    private var showsRegisterNewRow: Bool {
        !trimmedDraft.isEmpty && !knownSpeakers.contains { SpeakerName.isSame($0.name, trimmedDraft) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("参加者")
                .font(.headline)

            ForEach(participantHints) { hint in
                participantRow(hint)
            }

            suggestBox

            Text(Self.caption)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let participantHintError {
                Text(participantHintError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func participantRow(_ hint: ParticipantHintItem) -> some View {
        let label = hint.name ?? "不明な話者"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label)
                Spacer()
                Button {
                    onRemoveParticipant(hint.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("削除")
                .accessibilityLabel("削除")
                .accessibilityIdentifier("participant-remove-\(label)")
            }
            .accessibilityIdentifier("participant-row-\(label)")

            // design section 5's empty-embedding caption: only shown when the id still resolves to a
            // known speaker (`hint.name != nil` implies this) whose captured voiceprint is empty (design
            // section 1's "空 embedding のまま新規登録できる").
            if let embedding = knownSpeakers.first(where: { $0.id == hint.id })?.embedding, embedding.isEmpty {
                Text(Self.noVoiceprintCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var suggestBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("参加者を追加", text: $draft, onCommit: submitDraftAsNewName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("participant-add-field")

            if !trimmedDraft.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions) { speaker in
                        Button {
                            submit(.existingSpeaker(globalSpeakerId: speaker.id, name: speaker.name))
                        } label: {
                            Text(speaker.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("participant-suggest-\(speaker.name)")
                    }

                    if showsRegisterNewRow {
                        Button {
                            submit(.newName(trimmedDraft))
                        } label: {
                            Text("「\(trimmedDraft)」を新しい話者として登録")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("participant-register-new")
                    }
                }
                .padding(6)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
            }
        }
    }

    private func submitDraftAsNewName() {
        guard !trimmedDraft.isEmpty else { return }
        submit(.newName(trimmedDraft))
    }

    private func submit(_ submission: SpeakerRenameSubmission) {
        onAddParticipant(submission)
        draft = ""
    }
}

// MARK: - ByteCountLabel

/// Renders a Prep content editor's current size against its limit, e.g. `"18.2KB / 32KB"`
/// (`docs/design/06-ui-panels.md` section 6.2). B-3
/// (`docs/design/17-session-window-redesign.md` §5.2/§8): hidden entirely until usage crosses 80% of
/// the limit, instead of always-on chrome; still turns red once the limit is actually exceeded.
private struct ByteCountLabel: View {
    let text: String
    let limitBytes: Int

    private var byteCount: Int { text.utf8.count }
    private var isOverLimit: Bool { byteCount > limitBytes }
    private var isNearLimit: Bool { Double(byteCount) >= Double(limitBytes) * 0.8 }

    var body: some View {
        if isNearLimit {
            Text("\(Self.formatKB(byteCount)) / \(Self.formatKB(limitBytes))")
                .font(.caption)
                .foregroundStyle(isOverLimit ? .red : .secondary)
        }
    }

    private static func formatKB(_ bytes: Int) -> String {
        let kilobytes = Double(bytes) / 1_024
        return String(format: "%.1fKB", locale: Locale(identifier: "en_US_POSIX"), kilobytes)
    }
}

// MARK: - DuplicateFromSessionSheet

/// "他セッションから複製…" sheet: pick a source session and which Prep file(s) to overwrite from it
/// (`docs/design/06-ui-panels.md` section 6.2; kikimi.md 10 章 "「他セッションから複製」で Session
/// List を絞り込み表示 → context だけ / template だけ / 両方 を明示的に選んで上書き").
private struct DuplicateFromSessionSheet: View {
    let currentSessionId: String
    let loadAvailableSessions: () async -> [SessionMeta]
    let onApply: (_ sourceSessionId: String, _ scope: PrepCopyScope) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SessionMeta] = []
    @State private var isLoading = true
    @State private var selectedSessionId: String?
    @State private var scope: PrepCopyScope = .both
    @State private var isApplying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("他セッションから複製")
                .font(.headline)

            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sessions.isEmpty {
                    Text("複製元にできるセッションがありません")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    sessionList
                }
            }
            .frame(minHeight: 220)

            Picker("複製対象", selection: $scope) {
                Text("Context のみ").tag(PrepCopyScope.contextOnly)
                Text("Summary Template のみ").tag(PrepCopyScope.templateOnly)
                Text("両方").tag(PrepCopyScope.both)
            }
            .pickerStyle(.radioGroup)
            .disabled(sessions.isEmpty)

            HStack {
                if isApplying {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("適用") {
                    guard let selectedSessionId else { return }
                    isApplying = true
                    Task {
                        await onApply(selectedSessionId, scope)
                        isApplying = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSessionId == nil || isApplying)
            }
        }
        .padding()
        .frame(width: 420, height: 420)
        .task {
            let loaded = await loadAvailableSessions()
            sessions = loaded.filter { $0.id != currentSessionId }
            isLoading = false
        }
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sessions, id: \.id) { session in
                    sessionRow(session)
                }
            }
        }
        .border(Color.secondary.opacity(0.3))
    }

    private func sessionRow(_ session: SessionMeta) -> some View {
        let isSelected = selectedSessionId == session.id
        return Button {
            selectedSessionId = session.id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title.isEmpty ? session.id : session.title)
                        .fontWeight(.medium)
                    Text(session.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

// MARK: - PrepCopyScope + Hashable

/// `PrepCopyScope` (`Kikimi/SessionStore/SessionStoreTypes.swift`) only declares `Sendable`
/// conformance, but the scope `Picker` above needs its selection type to be `Hashable`. Adding it
/// here (rather than at the original declaration) keeps this UI-only requirement local to the view
/// that needs it; it's safe because `PrepCopyScope` has no associated values, so the compiler
/// synthesizes the conformance for free.
extension PrepCopyScope: Hashable {}
