import Foundation
import Testing

@testable import Kikimi

// MARK: - SettingsViewModel

/// Unit test for `SettingsViewModel` (`docs/design/06-ui-panels.md` section 5.5, Phase 1 minimal
/// scope + the `docs/design/19-voiceprint-map.md` speaker-map state). The config-backed Settings
/// sections are still unbuilt, so `isConfigAvailable` must stay hardcoded `false` -- this pins
/// that invariant so a future, unintentional flip fails a test instead of silently unlocking
/// config-backed UI that isn't ready (see the type's doc comment for the full list of features
/// gated behind this flag).
///
/// Every test injects `speakerMatchThreshold` so nothing here ever reads the real
/// `~/.config/kikimi/config.yaml` (design 19 §6).
@Suite("SettingsViewModel")
@MainActor
struct SettingsViewModelTests {
    @Test("isConfigAvailable is false while the config-backed Settings sections remain unbuilt")
    func isConfigAvailableIsFalse() {
        let viewModel = SettingsViewModel(speakerMatchThreshold: { 0.65 })
        #expect(!viewModel.isConfigAvailable)
    }

    /// Creates a `VoiceprintStore` backed by a fresh temporary file, so tests never touch the
    /// production `~/.local/state/kikimi/voiceprints.json` (mirrors the pattern used throughout
    /// `VoiceprintStoreTests`/`RealtimeDiarizationCoordinatorTests`).
    private func makeTempStore() -> VoiceprintStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsViewModelTests-\(UUID().uuidString).json")
        return VoiceprintStore(fileURL: url)
    }

    @Test("voiceprintSpeakers starts empty before any refresh")
    func voiceprintSpeakersStartsEmpty() {
        let viewModel = SettingsViewModel(
            voiceprintStore: makeTempStore(), speakerMatchThreshold: { 0.65 }
        )
        #expect(viewModel.voiceprintSpeakers.isEmpty)
        #expect(viewModel.voiceprintMapPoints.isEmpty)
        #expect(viewModel.voiceprintClosePairs.isEmpty)
    }

    // MARK: - Speaker map state (docs/design/19-voiceprint-map.md §6)

    @Test("refresh publishes map points for every valid speaker")
    func refreshPublishesMapPoints() async throws {
        let store = makeTempStore()
        try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])
        try await store.registerSpeaker(name: "佐藤さん", embedding: [0, 1, 0])
        try await store.registerSpeaker(name: "鈴木さん", embedding: [0.7, 0.7, 0.1])

        let viewModel = SettingsViewModel(voiceprintStore: store, speakerMatchThreshold: { 0.65 })
        await viewModel.refreshVoiceprintSpeakers()

        #expect(viewModel.voiceprintMapPoints.count == 3)
        #expect(
            Set(viewModel.voiceprintMapPoints.map(\.speakerId))
                == Set(viewModel.voiceprintSpeakers.map(\.id))
        )
    }

    @Test("refresh publishes close pairs using the injected threshold")
    func refreshPublishesClosePairsWithInjectedThreshold() async throws {
        let store = makeTempStore()
        let first = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])
        let second = try await store.registerSpeaker(name: "田中さん?", embedding: [0.99, 0.1, 0])
        try await store.registerSpeaker(name: "佐藤さん", embedding: [0, 1, 0])

        let viewModel = SettingsViewModel(voiceprintStore: store, speakerMatchThreshold: { 0.5 })
        await viewModel.refreshVoiceprintSpeakers()

        #expect(viewModel.voiceprintClosePairs.count == 1)
        #expect(
            Set([viewModel.voiceprintClosePairs[0].firstId, viewModel.voiceprintClosePairs[0].secondId])
                == Set([first.id, second.id])
        )

        // A tighter threshold makes the same pair disappear -- proving the injected closure is
        // what is actually consulted.
        let strictViewModel = SettingsViewModel(
            voiceprintStore: store, speakerMatchThreshold: { 0.001 }
        )
        await strictViewModel.refreshVoiceprintSpeakers()
        #expect(strictViewModel.voiceprintClosePairs.isEmpty)
    }

    @Test("deleting the selected speaker clears the selection on refresh")
    func deletingSelectedSpeakerClearsSelection() async throws {
        let store = makeTempStore()
        let target = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])
        try await store.registerSpeaker(name: "佐藤さん", embedding: [0, 1, 0])

        let viewModel = SettingsViewModel(voiceprintStore: store, speakerMatchThreshold: { 0.65 })
        await viewModel.refreshVoiceprintSpeakers()
        viewModel.selectedVoiceprintSpeakerId = target.id

        await viewModel.deleteVoiceprintSpeaker(id: target.id)

        #expect(viewModel.selectedVoiceprintSpeakerId == nil)
        #expect(viewModel.voiceprintMapPoints.count == 1)
    }

    @Test("voiceprintNeighbors returns closest speakers with the close-match flag")
    func voiceprintNeighborsReturnsClosestWithFlag() async throws {
        let store = makeTempStore()
        let target = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])
        let near = try await store.registerSpeaker(name: "田中さん?", embedding: [0.99, 0.1, 0])
        let far = try await store.registerSpeaker(name: "佐藤さん", embedding: [0, 1, 0])

        let viewModel = SettingsViewModel(voiceprintStore: store, speakerMatchThreshold: { 0.5 })
        await viewModel.refreshVoiceprintSpeakers()

        let neighbors = viewModel.voiceprintNeighbors(of: target.id)
        #expect(neighbors.map(\.speaker.id) == [near.id, far.id])
        #expect(neighbors.map(\.isCloseMatch) == [true, false])
    }

    @Test("refreshVoiceprintSpeakers loads every speaker currently in the store")
    func refreshVoiceprintSpeakersLoadsFromStore() async throws {
        let store = makeTempStore()
        try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])
        try await store.registerSpeaker(name: "佐藤さん", embedding: [0, 1, 0])

        let viewModel = SettingsViewModel(voiceprintStore: store, speakerMatchThreshold: { 0.65 })
        await viewModel.refreshVoiceprintSpeakers()

        #expect(viewModel.voiceprintSpeakers.count == 2)
        #expect(Set(viewModel.voiceprintSpeakers.map(\.name)) == ["田中さん", "佐藤さん"])
    }

    @Test("deleteVoiceprintSpeaker removes the speaker from the store and refreshes the list")
    func deleteVoiceprintSpeakerRemovesAndRefreshes() async throws {
        let store = makeTempStore()
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])
        try await store.registerSpeaker(name: "佐藤さん", embedding: [0, 1, 0])

        let viewModel = SettingsViewModel(voiceprintStore: store, speakerMatchThreshold: { 0.65 })
        await viewModel.refreshVoiceprintSpeakers()
        #expect(viewModel.voiceprintSpeakers.count == 2)

        await viewModel.deleteVoiceprintSpeaker(id: registered.id)

        #expect(viewModel.voiceprintSpeakers.count == 1)
        #expect(viewModel.voiceprintSpeakers.first?.name == "佐藤さん")
        // Deletion must be persisted, not just reflected in the local view model state.
        let persisted = await store.listSpeakers()
        #expect(persisted.count == 1)
    }

    @Test("deleteVoiceprintSpeaker with an unknown id is a harmless no-op")
    func deleteVoiceprintSpeakerUnknownIdIsNoOp() async throws {
        let store = makeTempStore()
        try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])

        let viewModel = SettingsViewModel(voiceprintStore: store, speakerMatchThreshold: { 0.65 })
        await viewModel.refreshVoiceprintSpeakers()

        await viewModel.deleteVoiceprintSpeaker(id: "does-not-exist")

        #expect(viewModel.voiceprintSpeakers.count == 1)
    }

    // MARK: - Rename (docs/design/23-speaker-settings-rename.md §2.1)

    @Test("renameVoiceprintSpeaker persists the trimmed name and refreshes the list")
    func renameVoiceprintSpeakerPersistsTrimmedName() async throws {
        let store = makeTempStore()
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])

        let viewModel = SettingsViewModel(voiceprintStore: store, speakerMatchThreshold: { 0.65 })
        await viewModel.refreshVoiceprintSpeakers()

        await viewModel.renameVoiceprintSpeaker(id: registered.id, name: "  田中太郎  ")

        #expect(viewModel.voiceprintSpeakers.first(where: { $0.id == registered.id })?.name == "田中太郎")
        // Persisted, not just reflected in local state.
        let persisted = await store.speaker(id: registered.id)
        #expect(persisted?.name == "田中太郎")
    }

    @Test("renameVoiceprintSpeaker with an empty (post-trim) name is a no-op")
    func renameVoiceprintSpeakerEmptyNameIsNoOp() async throws {
        let store = makeTempStore()
        let registered = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])

        let viewModel = SettingsViewModel(voiceprintStore: store, speakerMatchThreshold: { 0.65 })
        await viewModel.refreshVoiceprintSpeakers()

        await viewModel.renameVoiceprintSpeaker(id: registered.id, name: "   ")

        #expect(viewModel.voiceprintSpeakers.first(where: { $0.id == registered.id })?.name == "田中さん")
    }

    @Test("renameVoiceprintSpeaker with an unknown id is a harmless no-op")
    func renameVoiceprintSpeakerUnknownIdIsNoOp() async throws {
        let store = makeTempStore()
        try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])

        let viewModel = SettingsViewModel(voiceprintStore: store, speakerMatchThreshold: { 0.65 })
        await viewModel.refreshVoiceprintSpeakers()

        await viewModel.renameVoiceprintSpeaker(id: "does-not-exist", name: "誰か")

        #expect(viewModel.voiceprintSpeakers.count == 1)
        #expect(viewModel.voiceprintSpeakers.first?.name == "田中さん")
    }

    // MARK: - Voiceprint reset (design 13 §4.4 / design 19 §7)

    @Test("resetVoiceprintSpeaker clears the embedding and removes the speaker from the map and close pairs")
    func resetVoiceprintSpeakerClearsFromMapAndPairs() async throws {
        let store = makeTempStore()
        let first = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])
        try await store.registerSpeaker(name: "田中さん?", embedding: [0.99, 0.1, 0])

        let viewModel = SettingsViewModel(voiceprintStore: store, speakerMatchThreshold: { 0.5 })
        await viewModel.refreshVoiceprintSpeakers()
        #expect(viewModel.voiceprintClosePairs.count == 1)

        await viewModel.resetVoiceprintSpeaker(id: first.id)

        #expect(viewModel.voiceprintSpeakers.first(where: { $0.id == first.id })?.embedding == [])
        #expect(!viewModel.voiceprintMapPoints.contains(where: { $0.speakerId == first.id }))
        #expect(viewModel.voiceprintClosePairs.isEmpty)

        // Persisted, not just reflected in local state.
        let persisted = await store.speaker(id: first.id)
        #expect(persisted?.embedding == [])
    }

    @Test("a reset speaker's neighbor list is empty (excluded from the map)")
    func resetSpeakerHasNoNeighbors() async throws {
        let store = makeTempStore()
        let target = try await store.registerSpeaker(name: "田中さん", embedding: [1, 0, 0])
        try await store.registerSpeaker(name: "佐藤さん", embedding: [0, 1, 0])

        let viewModel = SettingsViewModel(voiceprintStore: store, speakerMatchThreshold: { 0.65 })
        await viewModel.refreshVoiceprintSpeakers()

        await viewModel.resetVoiceprintSpeaker(id: target.id)

        #expect(viewModel.voiceprintNeighbors(of: target.id).isEmpty)
    }

    // MARK: - Per-provider API key drafts (`docs/design/44-llm-model-config.md` §9, generalizing §4.3)

    @Test("loadProviderAPIKeyDraftIfNeeded is one-shot per provider name and reads from the credential store")
    func loadProviderAPIKeyDraftIfNeededIsOneShotPerProvider() {
        let credentialStore = InMemoryCredentialStore(seeded: [
            CredentialAccount.providerAPIKey(name: "azure"): "sk-azure"
        ])
        let viewModel = SettingsViewModel(speakerMatchThreshold: { 0.65 }, credentialStore: credentialStore)

        viewModel.loadProviderAPIKeyDraftIfNeeded(providerName: "azure")
        #expect(viewModel.providerAPIKeyDrafts["azure"] == "sk-azure")

        // A second provider's draft is independent (never bleeds the first provider's value).
        viewModel.loadProviderAPIKeyDraftIfNeeded(providerName: "openai")
        #expect(viewModel.providerAPIKeyDrafts["openai"] == "")

        // A store mutation after the first load is not picked up again -- confirms the one-shot guard.
        try? credentialStore.write("sk-azure-changed", account: CredentialAccount.providerAPIKey(name: "azure"))
        viewModel.loadProviderAPIKeyDraftIfNeeded(providerName: "azure")
        #expect(viewModel.providerAPIKeyDrafts["azure"] == "sk-azure")
    }

    @Test("updateProviderAPIKeyDraft updates the in-memory draft without writing to the credential store")
    func updateProviderAPIKeyDraftDoesNotWriteImmediately() {
        let credentialStore = InMemoryCredentialStore()
        let viewModel = SettingsViewModel(speakerMatchThreshold: { 0.65 }, credentialStore: credentialStore)

        viewModel.updateProviderAPIKeyDraft(providerName: "azure", value: "sk-typed")

        #expect(viewModel.providerAPIKeyDrafts["azure"] == "sk-typed")
        #expect(credentialStore.read(account: CredentialAccount.providerAPIKey(name: "azure")) == nil)
    }

    @Test("persistProviderAPIKeyDraftIfChanged writes only when the draft actually changed")
    func persistProviderAPIKeyDraftIfChangedWritesOnlyOnChange() {
        let credentialStore = InMemoryCredentialStore()
        let viewModel = SettingsViewModel(speakerMatchThreshold: { 0.65 }, credentialStore: credentialStore)

        viewModel.loadProviderAPIKeyDraftIfNeeded(providerName: "azure")
        viewModel.persistProviderAPIKeyDraftIfChanged(providerName: "azure")
        #expect(credentialStore.read(account: CredentialAccount.providerAPIKey(name: "azure")) == nil, "unchanged empty draft must not write")

        viewModel.updateProviderAPIKeyDraft(providerName: "azure", value: "sk-new")
        viewModel.persistProviderAPIKeyDraftIfChanged(providerName: "azure")
        #expect(credentialStore.read(account: CredentialAccount.providerAPIKey(name: "azure")) == "sk-new")
    }

    @Test("renameProviderAPIKeyCredential moves the stored credential and the in-memory draft to the new name")
    func renameProviderAPIKeyCredentialMovesCredentialAndDraft() {
        let credentialStore = InMemoryCredentialStore(seeded: [
            CredentialAccount.providerAPIKey(name: "old"): "sk-old"
        ])
        let viewModel = SettingsViewModel(speakerMatchThreshold: { 0.65 }, credentialStore: credentialStore)
        viewModel.loadProviderAPIKeyDraftIfNeeded(providerName: "old")

        viewModel.renameProviderAPIKeyCredential(from: "old", to: "new")

        #expect(credentialStore.read(account: CredentialAccount.providerAPIKey(name: "old")) == nil)
        #expect(credentialStore.read(account: CredentialAccount.providerAPIKey(name: "new")) == "sk-old")
        #expect(viewModel.providerAPIKeyDrafts["old"] == nil)
        #expect(viewModel.providerAPIKeyDrafts["new"] == "sk-old")
    }

    @Test("renameProviderAPIKeyCredential is a harmless no-op when nothing was stored under the old name")
    func renameProviderAPIKeyCredentialNoOpWhenNothingStored() {
        let credentialStore = InMemoryCredentialStore()
        let viewModel = SettingsViewModel(speakerMatchThreshold: { 0.65 }, credentialStore: credentialStore)

        viewModel.renameProviderAPIKeyCredential(from: "claude", to: "claude-renamed")

        #expect(credentialStore.read(account: CredentialAccount.providerAPIKey(name: "claude-renamed")) == nil)
    }

    @Test("deleteProviderAPIKeyCredential removes the stored credential and the in-memory draft")
    func deleteProviderAPIKeyCredentialRemovesCredentialAndDraft() {
        let credentialStore = InMemoryCredentialStore(seeded: [
            CredentialAccount.providerAPIKey(name: "azure"): "sk-azure"
        ])
        let viewModel = SettingsViewModel(speakerMatchThreshold: { 0.65 }, credentialStore: credentialStore)
        viewModel.loadProviderAPIKeyDraftIfNeeded(providerName: "azure")

        viewModel.deleteProviderAPIKeyCredential(providerName: "azure")

        #expect(credentialStore.read(account: CredentialAccount.providerAPIKey(name: "azure")) == nil)
        #expect(viewModel.providerAPIKeyDrafts["azure"] == nil)

        // Deleting also clears the one-shot load guard, so re-loading afterwards would re-read
        // (proving no stale state is left behind that would mask a fresh credential later reused
        // under the same provider name).
        try? credentialStore.write("sk-reused", account: CredentialAccount.providerAPIKey(name: "azure"))
        viewModel.loadProviderAPIKeyDraftIfNeeded(providerName: "azure")
        #expect(viewModel.providerAPIKeyDrafts["azure"] == "sk-reused")
    }
}
