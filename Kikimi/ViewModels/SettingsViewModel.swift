import Foundation
import OSLog

/// View model backing the Settings window (`docs/design/06-ui-panels.md` 5.5章 / 8章, Phase 1
/// minimal scope).
///
/// Phase 1 provides only the Settings window's tab shell ("一般"/"モデル"/"Watchers") with
/// placeholder content. `AppConfig.shared` (`config.yaml`) exists now, but the config-backed
/// Settings sections themselves are still unbuilt (06-ui-panels.md 4章/8章), so the following
/// remain **out of scope for this module**:
///   - default `context.md` / `summary_template.md` editing
///   - model selection (`refinement.model` / `summary.model` / `stt.model`)
///   - Watcher preset library management (list / create / edit / delete)
///   - export settings (`export.target_dir` / `export.enabled`)
///
/// The voiceprint speaker section (below) is an exception carved out by
/// `docs/design/13-speaker-diarization.md` section 14 ("R2 では Settings に一覧 + 削除の最小限のみ"):
/// it is backed by `VoiceprintStore`, not `AppConfig.shared`, so it is available starting in R2
/// even though the rest of this view model is still blocked.
@MainActor
final class SettingsViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SettingsViewModel")

    /// Still `false`: `AppConfig.shared` exists now (`Kikimi/Config/AppConfig.swift`), but none of
    /// the config-backed Settings sections listed in the type doc comment have been built yet, so
    /// this switch stays off until they land. Kept as a published property so `SettingsView` (and
    /// any future tab content) has a single, testable switch to flip without changing the view's
    /// structure.
    @Published private(set) var isConfigAvailable = false

    /// Every speaker currently registered in the global voiceprint database, in the order
    /// `VoiceprintStore.listSpeakers()` returns them. Populated by `refreshVoiceprintSpeakers()`;
    /// starts empty so the tab renders its empty state before the first refresh completes.
    @Published private(set) var voiceprintSpeakers: [VoiceprintSpeaker] = []

    /// The speaker map's 2D layout (`docs/design/19-voiceprint-map.md` §3), recomputed on every
    /// `refreshVoiceprintSpeakers()`. The view shows the map only when 2+ points exist (§5).
    @Published private(set) var voiceprintMapPoints: [VoiceprintMapLayout.SpeakerPoint] = []

    /// Same-person-suspect pairs by *true* 256-d cosine distance (§4's invariant — never derived
    /// from the 2D projection), closest first.
    @Published private(set) var voiceprintClosePairs: [VoiceprintMapLayout.ClosePair] = []

    /// The speaker highlighted in both the map and the list (§5). Cleared automatically when the
    /// selected speaker disappears from the database (e.g. deleted).
    @Published var selectedVoiceprintSpeakerId: String?

    /// Injected so tests can point this at a temporary-file-backed store instead of the shared
    /// production database (`~/.local/state/kikimi/voiceprints.json`), matching the pattern every
    /// other R2 module uses (`RealtimeDiarizationCoordinator`, `MeetingWorkspaceViewModel`).
    private let voiceprintStore: VoiceprintStore

    /// Read lazily on each refresh (config is hand-editable while the app runs). Injected as a
    /// closure so view-model tests never depend on the real `~/.config/kikimi/config.yaml`
    /// (design §6); production defaults to `AppConfig.shared`.
    private let speakerMatchThreshold: () -> Double

    /// The Settings "モデル" タブ's プロバイダ detail pane's draft of each `openai`-kind provider's
    /// `CredentialAccount.providerAPIKey(name:)` secret (`docs/design/44-llm-model-config.md` §9,
    /// generalizing the single-provider `llm.openai.api_key` draft `docs/design/26-settings-ui.md`
    /// §4.3 introduced). Keyed by the provider's *current* name in `llm.providers`.
    ///
    /// Owned here -- not as `@State` on the provider detail view itself -- because `SettingsView`'s
    /// `TabView` tears down and reinstantiates non-selected tabs' view structs on every tab switch
    /// (observed in kikimi-verify: reading Keychain from a view's own `init`/`@State` fired the OS
    /// Keychain-access permission prompt on every single tab switch, not once per window). This
    /// class instance, by contrast, is created once by `SettingsWindowController` and lives for the
    /// window's whole lifetime, so `loadedProviderAPIKeyDraftNames` genuinely gates each provider's
    /// credential-store read to once per window open regardless of how many times the view struct
    /// selecting that provider is rebuilt.
    @Published private(set) var providerAPIKeyDrafts: [String: String] = [:]
    private var loadedProviderAPIKeyDraftNames: Set<String> = []
    private let credentialStore: CredentialStoring

    init(
        voiceprintStore: VoiceprintStore = .shared,
        speakerMatchThreshold: (() -> Double)? = nil,
        credentialStore: CredentialStoring = DefaultCredentialStore.shared
    ) {
        self.voiceprintStore = voiceprintStore
        self.speakerMatchThreshold = speakerMatchThreshold
            ?? { AppConfig.shared.data.diarization.speakerMatchThreshold }
        self.credentialStore = credentialStore
    }

    /// One-shot credential-store read for `providerAPIKeyDrafts[providerName]`, safe to call from
    /// the provider detail view's `.task` every time that view struct is rebuilt (see
    /// `providerAPIKeyDrafts`'s doc comment above).
    func loadProviderAPIKeyDraftIfNeeded(providerName: String) {
        guard !loadedProviderAPIKeyDraftNames.contains(providerName) else { return }
        loadedProviderAPIKeyDraftNames.insert(providerName)
        providerAPIKeyDrafts[providerName] = credentialStore.read(
            account: CredentialAccount.providerAPIKey(name: providerName)
        ) ?? ""
    }

    /// Updates the in-memory draft only (no credential-store write) -- called on every keystroke
    /// from the `SecureField` binding. Persisting happens separately via
    /// `persistProviderAPIKeyDraftIfChanged(providerName:)` (design §4.3: not on every keystroke).
    func updateProviderAPIKeyDraft(providerName: String, value: String) {
        providerAPIKeyDrafts[providerName] = value
    }

    /// Writes `providerAPIKeyDrafts[providerName]` to the credential store only when it actually
    /// changed from what's currently stored, avoiding a write (and its own permission-prompt risk
    /// on the Keychain fallback) on every tab switch/window close when the user made no edit
    /// (design §4.3).
    func persistProviderAPIKeyDraftIfChanged(providerName: String) {
        guard let draft = providerAPIKeyDrafts[providerName] else { return }
        let current = credentialStore.read(account: CredentialAccount.providerAPIKey(name: providerName)) ?? ""
        guard draft != current else { return }
        do {
            try credentialStore.write(draft, account: CredentialAccount.providerAPIKey(name: providerName))
        } catch {
            // Best-effort per kikimi.md 8.5章: no UI affordance for this rare failure.
            Self.logger.error(
                "Failed to persist API key for provider \(providerName, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// The credential half of `docs/design/44-llm-model-config.md` §9's "rename は... credential の
    /// move を伴う": moves whatever is stored under `oldName`'s account to `newName`'s (a no-op if
    /// nothing was stored -- e.g. a `claude-cli` provider, which never has an API key at all), then
    /// carries the in-memory draft over too so the detail pane shows the right value immediately
    /// under the new name instead of triggering a fresh (empty, until the next load) read.
    func renameProviderAPIKeyCredential(from oldName: String, to newName: String) {
        let oldAccount = CredentialAccount.providerAPIKey(name: oldName)
        let newAccount = CredentialAccount.providerAPIKey(name: newName)
        if let value = credentialStore.read(account: oldAccount) {
            do {
                try credentialStore.write(value, account: newAccount)
                try credentialStore.delete(account: oldAccount)
            } catch {
                Self.logger.error(
                    "Failed to move API key credential \(oldName, privacy: .public) -> \(newName, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }

        if let draft = providerAPIKeyDrafts.removeValue(forKey: oldName) {
            providerAPIKeyDrafts[newName] = draft
        }
        loadedProviderAPIKeyDraftNames.remove(oldName)
        loadedProviderAPIKeyDraftNames.insert(newName)
    }

    /// Deletes whatever is stored under `providerName`'s account, called when a provider row is
    /// deleted (§9's provider CRUD) so a removed provider never leaves an orphaned, unreachable
    /// secret behind. Best-effort per kikimi.md 8.5章, same swallow-and-log pattern as every other
    /// credential-store write in this type.
    func deleteProviderAPIKeyCredential(providerName: String) {
        do {
            try credentialStore.delete(account: CredentialAccount.providerAPIKey(name: providerName))
        } catch {
            Self.logger.error(
                "Failed to delete API key credential for provider \(providerName, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        providerAPIKeyDrafts.removeValue(forKey: providerName)
        loadedProviderAPIKeyDraftNames.remove(providerName)
    }

    /// Re-reads the full speaker list from `voiceprintStore` and recomputes the map layout and
    /// threshold pairs. Safe to call as often as needed (e.g. on tab appear, after a delete) --
    /// the store read has no side effects and the layout math is instant at this scale.
    func refreshVoiceprintSpeakers() async {
        voiceprintSpeakers = await voiceprintStore.listSpeakers()
        let (points, excluded) = VoiceprintMapLayout.compute(speakers: voiceprintSpeakers)
        voiceprintMapPoints = points
        voiceprintClosePairs = VoiceprintMapLayout.closePairs(
            speakers: voiceprintSpeakers, threshold: speakerMatchThreshold()
        )
        // The layout functions are pure and report exclusions via return value (design §6);
        // logging is this caller's job. `.empty` is skipped deliberately: it covers a speaker
        // that has been through "声紋リセット" (design 13 §4.4 / design 19 §7), which is an
        // intentional, normal state -- not a misconfiguration or data corruption worth a warning.
        for exclusion in excluded where exclusion.reason != .empty {
            Self.logger.warning(
                """
                Speaker \(exclusion.speakerId, privacy: .public) excluded from the voiceprint map: \
                \(exclusion.reason.rawValue, privacy: .public)
                """
            )
        }
        if let selected = selectedVoiceprintSpeakerId,
           !voiceprintSpeakers.contains(where: { $0.id == selected }) {
            selectedVoiceprintSpeakerId = nil
        }
    }

    /// The design §5 proximity list for one speaker: closest voices first with their true cosine
    /// distances, flagged when they fall under the same-person threshold. Computed on demand (it
    /// is only shown for the selected speaker).
    func voiceprintNeighbors(
        of speakerId: String, topN: Int = 3
    ) -> [(speaker: VoiceprintSpeaker, distance: Float, isCloseMatch: Bool)] {
        let threshold = speakerMatchThreshold()
        return VoiceprintMapLayout.neighbors(of: speakerId, in: voiceprintSpeakers, topN: topN)
            .compactMap { neighbor in
                guard let speaker = voiceprintSpeakers.first(where: { $0.id == neighbor.speakerId })
                else { return nil }
                return (speaker, neighbor.distance, Double(neighbor.distance) < threshold)
            }
    }

    /// Deletes a speaker immediately (no confirmation step -- the design doc's "最小限" scope does
    /// not call for one) and refreshes the list from the store so the UI reflects the persisted
    /// state rather than an optimistic local removal. Best-effort per kikimi.md 8.5章: a disk
    /// write failure is logged and swallowed rather than surfaced, consistent with every other
    /// `VoiceprintStore` caller in the app -- Settings has no error-toast affordance to show it
    /// anyway, and the list will simply still show the speaker on the next refresh if the delete
    /// didn't actually persist.
    func deleteVoiceprintSpeaker(id: String) async {
        do {
            try await voiceprintStore.deleteSpeaker(id: id)
        } catch {
            Self.logger.error(
                "Failed to delete voiceprint speaker \(id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        await refreshVoiceprintSpeakers()
    }

    /// Renames a speaker in the global voiceprint database (`docs/design/23-speaker-settings-rename.md`
    /// §2.1). Trims `name` via `SpeakerName.trimmed(_:)` (the same normalization every other "same
    /// name"/rename path in the app uses) and does nothing if the result is empty -- no confirmation
    /// step, no uniqueness check (duplicate display names across speakers are already tolerated
    /// elsewhere, design 20 §4). Best-effort per kikimi.md 8.5章, same pattern as
    /// `deleteVoiceprintSpeaker`/`resetVoiceprintSpeaker`: a persistence failure is logged and
    /// swallowed, then the list is refreshed from the store either way.
    func renameVoiceprintSpeaker(id: String, name: String) async {
        let trimmed = SpeakerName.trimmed(name)
        guard !trimmed.isEmpty else { return }
        do {
            try await voiceprintStore.renameSpeaker(id: id, name: trimmed)
        } catch {
            Self.logger.error(
                "Failed to rename voiceprint speaker \(id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        await refreshVoiceprintSpeakers()
    }

    /// Resets a speaker's voiceprint (`docs/design/13-speaker-diarization.md` section 4.4 "声紋リセット"):
    /// clears the stored embedding while keeping the speaker's id/name/history, taking it out of
    /// automatic matching until a future manual assignment re-enrolls it. No confirmation step,
    /// same best-effort pattern as `deleteVoiceprintSpeaker` -- log and swallow a persistence
    /// failure, then refresh from the store either way so the UI reflects whatever actually
    /// persisted.
    func resetVoiceprintSpeaker(id: String) async {
        do {
            try await voiceprintStore.resetSpeakerEmbedding(id: id)
        } catch {
            Self.logger.error(
                "Failed to reset voiceprint speaker \(id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        await refreshVoiceprintSpeakers()
    }
}
