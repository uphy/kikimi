import AppKit
import SwiftUI

// MARK: - ProfilesSettingsTab

/// The "プロファイル" Settings tab (`docs/design/41-meeting-profiles.md` §6.4): the minimal
/// management surface for saved meeting profiles (`~/.config/kikimi/profiles/<id>/`) -- a list plus
/// rename / delete / "Finder で表示". There is deliberately no "+ 新規" here: the only creation path
/// is "プロファイルとして保存…" from a session's prep tab (§5), which is the sole place profile
/// *content* (context.md / summary_template.md / watchers / participants) can be authored, so an
/// empty profile created from Settings would have nothing to edit it with (§6.4's own rationale).
///
/// Unlike `GeneralSettingsTab`/`ModelSettingsTab`/`WatchersSettingsTab`, this tab does **not** bind
/// to `@ObservedObject AppConfig.shared`: a profile isn't a `config.yaml` field, it is a directory
/// under `profiles.dir` (`ProfilesConfig.dir`). So this holds a plain `@State [MeetingProfile]`
/// loaded from `MeetingProfileStore.shared.list()` when the tab appears, and reloaded after every
/// mutating action -- the same "filesystem is the single source of truth, no caching" idiom
/// `MeetingProfileStore` itself uses (§3.2).
///
/// rename / delete additionally call `WindowManager.shared.refreshProfileMenu()` (§6.2/§6.4) so the
/// menu bar's "新規セッション" submenu cache does not go stale relative to what this tab just did.
struct ProfilesSettingsTab: View {
    @State private var profiles: [MeetingProfile] = []

    /// Non-nil while the delete confirmation dialog for this profile is up.
    @State private var pendingDeleteProfile: MeetingProfile?
    /// Set on a failed rename/delete (`MeetingProfileStoreError`, §3.2). Save failures are handled
    /// entirely in the "プロファイルとして保存…" sheet (§5) and never reach this tab.
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if profiles.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(profiles) { profile in
                        ProfileRow(
                            profile: profile,
                            onRename: { newName in rename(profile, to: newName) },
                            onRevealInFinder: { revealInFinder(profile) },
                            onDelete: { pendingDeleteProfile = profile }
                        )
                    }
                }
            }
        }
        .padding()
        // TabView keeps every tab's content view alive for the Settings window's whole lifetime
        // (`SettingsWindowController` builds `SettingsView` exactly once, doc comment there), but
        // AppKit still adds/removes the selected tab's hosted view from the window each time the
        // user switches tabs -- so `.onAppear` fires on every switch *into* this tab, matching §6.4's
        // "タブ表示時に読む". This mirrors `VoiceprintSpeakersTab`'s equivalent disk-refresh need,
        // which instead re-fetches from `SettingsWindowController.show()` because it is driven by a
        // shared `SettingsViewModel`; this tab has no such view model to hang a refresh off of, so it
        // refreshes itself directly.
        .onAppear { Task { await refresh() } }
        .confirmationDialog(
            "プロファイルを削除しますか？",
            isPresented: Binding(
                get: { pendingDeleteProfile != nil },
                set: { isPresented in if !isPresented { pendingDeleteProfile = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                if let profile = pendingDeleteProfile { delete(profile) }
                pendingDeleteProfile = nil
            }
            Button("キャンセル", role: .cancel) { pendingDeleteProfile = nil }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .alert(
            "操作に失敗しました",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in if !isPresented { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("保存されたプロファイルはまだありません")
                .foregroundStyle(.secondary)
            Text("セッションの準備タブから「プロファイルとして保存…」で作成できます")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deleteConfirmationMessage: String {
        guard let profile = pendingDeleteProfile else { return "" }
        // meta.profile_id references keep the id after deletion (provenance-only, §2.3), so the
        // message only needs to warn about the profile itself, not about existing sessions.
        // Empty name falls back to the id (§8 #10), same as the other render sites.
        let name = profile.name.isEmpty ? profile.id : profile.name
        return "「\(name)」を削除します。この操作は取り消せません。"
    }

    // MARK: Actions

    private func refresh() async {
        profiles = await MeetingProfileStore.shared.list()
    }

    private func rename(_ profile: MeetingProfile, to newName: String) {
        Task {
            do {
                try await MeetingProfileStore.shared.rename(id: profile.id, newName: newName)
                await refresh()
                WindowManager.shared.refreshProfileMenu()
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func delete(_ profile: MeetingProfile) {
        Task {
            do {
                try await MeetingProfileStore.shared.delete(id: profile.id)
                await refresh()
                WindowManager.shared.refreshProfileMenu()
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    /// "Finder で表示" (§6.4): the tab itself resolves `profiles.dir` + the profile's directory-name
    /// id rather than adding a directory-URL accessor to `MeetingProfileStore`'s API (§3.2 lists no
    /// such method) -- same "config keeps the path, filesystem is the source of truth" resolution
    /// `SessionStore`'s `defaultContextFileURL` etc. already use via `FileManager
    /// .expandingTildePath(_:)`.
    private func revealInFinder(_ profile: MeetingProfile) {
        let directory = FileManager.expandingTildePath(AppConfig.shared.data.profiles.dir)
            .appendingPathComponent(profile.id, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}

// MARK: - ProfileRow

/// One row: display name (inline-editable, mirrors `VoiceprintSpeakerRow`'s pencil-button pattern in
/// `SettingsView.swift`) + description, then a caption line with the id and presence badges for
/// context / summary template / watchers / participants (§6.4). "Finder で表示" and delete sit at the
/// trailing edge.
private struct ProfileRow: View {
    let profile: MeetingProfile
    /// Called with the trimmed, non-empty, actually-changed new name (mirrors
    /// `VoiceprintSpeakerRow.onRename`'s contract).
    let onRename: (String) -> Void
    let onRevealInFinder: () -> Void
    let onDelete: () -> Void

    @State private var isEditingName = false
    @State private var draftName = ""

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                nameField
                if let description = profile.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(profile.id)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospaced()
                    ProfileBadge(label: "context", isPresent: profile.hasContext)
                    ProfileBadge(label: "テンプレート", isPresent: profile.hasSummaryTemplate)
                    ProfileBadge(label: "Watchers", isPresent: !(profile.enabledWatchers ?? []).isEmpty)
                    ProfileBadge(label: "参加者", isPresent: !(profile.participantIds ?? []).isEmpty)
                }
            }
            Spacer()
            Button("Finder で表示", action: onRevealInFinder)
                .buttonStyle(.borderless)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("このプロファイルを削除")
        }
        .padding(.vertical, 3)
    }

    /// Toggles between a plain name label with a pencil button and an inline `TextField`, so renaming
    /// never needs a separate sheet (same rationale as `VoiceprintSpeakerRow.nameField`).
    @ViewBuilder
    private var nameField: some View {
        if isEditingName {
            TextField("表示名", text: $draftName, onCommit: commitRename)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .onExitCommand { isEditingName = false }
        } else {
            HStack(spacing: 4) {
                // Empty name falls back to the id (§8 #10); editing still starts from the raw name.
                Text(profile.name.isEmpty ? profile.id : profile.name)
                    .font(.body)
                Button {
                    draftName = profile.name
                    isEditingName = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("表示名を変更")
            }
        }
    }

    /// Exits edit mode unconditionally, then submits the trimmed name -- but only if it is non-empty
    /// and actually changed (mirrors `VoiceprintSpeakerRow.commitRename`).
    private func commitRename() {
        isEditingName = false
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != profile.name else { return }
        onRename(trimmed)
    }
}

// MARK: - ProfileBadge

/// A small presence pill for one of `ProfileRow`'s four badges (§6.4: "context / template /
/// watchers / 参加者の有無バッジ"). Accent-tinted when present, muted when absent -- absent badges
/// stay visible (not hidden) so the row's badge set has a stable shape to scan across profiles.
private struct ProfileBadge: View {
    let label: String
    let isPresent: Bool

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isPresent ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
            .foregroundStyle(isPresent ? Color.accentColor : .secondary)
            .clipShape(Capsule())
    }
}
