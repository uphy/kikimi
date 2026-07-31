import Foundation

// MARK: - MeetingWorkspaceViewModel + Profiles (`docs/design/41-meeting-profiles.md` §5, §6.3)

/// Split into its own file (alongside `MeetingWorkspaceViewModel.swift`'s other extensions, e.g.
/// `+Prep.swift`/`+Watchers.swift`) to keep that file under the project's `file_length` lint limit.
/// Owns the Prep tab's two profile-facing surfaces:
///
/// - The "プロファイルとして保存…" sheet (`ProfileSaveSheet`)'s data gathering
///   (`profileSaveSourceSession()`/`existingProfileIds()`) and persistence (`saveMeetingProfile
///   (_:overwrite:)`) -- the sheet itself stays free of any `MeetingWorkspaceViewModel`/
///   `SessionHandle`/`MeetingProfileStore` dependency (same decoupling `PrepContentView` uses),
///   wired entirely through the plain closures `MeetingWorkspaceView` passes it.
/// - The header-adjacent provenance label (`profileProvenanceLabel()`, §6.3).
///
/// No stored properties: unlike `+Watchers.swift`'s `watcherItems`/`selectedWatcherId` (which are
/// live, `@Published`, and read on every render), a session's profile provenance and the sheet's
/// save-time data are each read fresh, once, at the moment they're needed (`PrepContentView`'s own
/// `.task`s) -- there is nothing here that needs to survive across renders or be observed.
extension MeetingWorkspaceViewModel {
    // MARK: - "プロファイルとして保存…" (§5)

    /// Existing profile ids, read fresh every time the save sheet opens (§5: "既存 id と衝突する場合は
    /// 上書き確認"). No caching -- mirrors `MeetingProfileStore.list()`'s own "every call re-reads"
    /// contract (§3.2); this is a one-shot read for a modal sheet, not a live subscription like
    /// `WindowManager.profileMenuItems` (§6.2).
    func existingProfileIds() async -> [String] {
        await MeetingProfileStore.shared.list().map(\.id)
    }

    /// Gathers this session's current prep state into a `ProfileSaveComposer.SourceSession` (§5):
    /// fresh reads of `context.md`/`summary_template.md`/`enabled.yaml`/`participants.json` (not the
    /// `@Published` `contextText`/`summaryTemplateText`/`watcherItems`/`participantHints` mirrors --
    /// this only ever runs once per sheet-open, so there's no reason to trust in-memory state over
    /// disk), plus every preset id (`WatcherLibrary.listPresetIds()`) `ProfileSaveComposer.compose
    /// (...)` needs to decide which enabled Watcher ids survive into the profile (§5's exclusion
    /// rule -- see that method's own doc comment for why it's checked against presets, not
    /// `WatcherOrigin`).
    func profileSaveSourceSession() async -> ProfileSaveComposer.SourceSession {
        let enabledWatcherIds = (try? await sessionHandle.readEnabledWatchers()) ?? []
        let participants = await sessionHandle.readParticipants()
        return ProfileSaveComposer.SourceSession(
            context: await sessionHandle.readContext(),
            summaryTemplate: await sessionHandle.readSummaryTemplate(),
            enabledWatcherIds: enabledWatcherIds,
            presetWatcherIds: Set(watcherLibrary.listPresetIds()),
            participantIds: participants.participantIds
        )
    }

    /// "プロファイルとして保存…"'s "保存" action: writes `draft` via
    /// `MeetingProfileStore.save(_:overwrite:)`, then refreshes the menu bar's cached profile list
    /// (§6.2's 3 defined refresh points -- this is the "保存シート完了後" one). This session's own
    /// `meta.profileId` is deliberately left untouched (§5: "保存後、そのセッションの `meta.profile_id`
    /// は書き換えない").
    ///
    /// A write failure is logged at `.error` and rethrown for the sheet to display inline without
    /// dismissing (§5/§8 #8) -- `MeetingProfileStore.save` itself never leaves a half-written profile
    /// on failure (temp-dir + swap), so every existing profile is untouched either way.
    func saveMeetingProfile(_ draft: MeetingProfileDraft, overwrite: Bool) async throws {
        do {
            try await MeetingProfileStore.shared.save(draft, overwrite: overwrite)
        } catch {
            logger.error(
                """
                Failed to save meeting profile \(draft.id, privacy: .public) (overwrite=\(overwrite, privacy: .public)) \
                from session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)
                """
            )
            throw error
        }
        WindowManager.shared.refreshProfileMenu()
    }

    // MARK: - Provenance display (§6.3)

    /// The Prep tab's provenance line: "プロファイル: <name>" while `meta.profileId` still resolves to
    /// an existing profile, "プロファイル: <id>（削除済みプロファイル）" once it no longer does (§2.3: a
    /// deleted/renamed profile never rewrites `meta.profile_id`, so a stale id just fails to resolve
    /// here), or `nil` when this session's Draft was not seeded from a profile at all. Display-only --
    /// never influences any other behavior, and never re-resolved automatically after the Prep tab's
    /// initial load (same tolerance for a stale snapshot `WindowManager.profileMenuItems` accepts,
    /// §6.2's "古い項目を選んでも...最悪でもソフトフォールバックに落ちるだけ").
    func profileProvenanceLabel() async -> String? {
        guard let profileId = meta.profileId else { return nil }
        guard let profile = await MeetingProfileStore.shared.read(id: profileId) else {
            return "プロファイル: \(profileId)（削除済みプロファイル）"
        }
        let displayName = profile.name.isEmpty ? profile.id : profile.name
        return "プロファイル: \(displayName)"
    }
}
