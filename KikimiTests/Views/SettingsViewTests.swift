import Foundation
import Testing
import Yams

@testable import Kikimi

/// Layer 1 (unit) coverage for the `AppConfig` `Binding` helpers in `Kikimi/Views/SettingsView.swift`
/// (`docs/design/26-settings-ui.md` §4.1's "each tab builds its `Binding`s off `AppConfig.binding`/
/// `optionalStringBinding`" pattern). Per §6's own test-plan note, individual `GeneralSettingsTab`/
/// `ModelSettingsTab`/`WatchersSettingsTab` fields need no per-field tests since the `binding(_:)`
/// helper is generic -- but the helper itself (and its `String?` variant) had no direct coverage
/// anywhere, so it is exercised here instead of only indirectly through the (untestable, SwiftUI)
/// tab views.
@Suite("SettingsView AppConfig binding helpers")
struct SettingsViewBindingTests {
    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsViewTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAppConfig(in directory: URL) -> AppConfig {
        AppConfig(directory: directory, credentialStore: InMemoryCredentialStore())
    }

    private func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("config.yaml")
    }

    // MARK: - binding(_:)

    @Test("binding(_:) get reflects the current AppConfig value")
    func bindingGetReflectsCurrentValue() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appConfig = makeAppConfig(in: dir)

        let binding = appConfig.binding(\.audio.suggestHeadphonesOnBuiltInSpeaker)
        #expect(binding.wrappedValue == appConfig.data.audio.suggestHeadphonesOnBuiltInSpeaker)

        appConfig.update { $0.audio.suggestHeadphonesOnBuiltInSpeaker = false }
        #expect(binding.wrappedValue == false)
    }

    @Test("binding(_:) set writes the new value back through AppConfig.update")
    func bindingSetWritesThroughUpdate() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appConfig = makeAppConfig(in: dir)

        let binding = appConfig.binding(\.refinement.batchSize)
        binding.wrappedValue = 42

        #expect(appConfig.data.refinement.batchSize == 42)
    }

    @Test("binding(_:) set persists to disk (round-trips through a fresh AppConfig instance)")
    func bindingSetPersistsAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appConfig = makeAppConfig(in: dir)

        let binding = appConfig.binding(\.diarization.selfName)
        binding.wrappedValue = "テスト太郎"

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.diarization.selfName == "テスト太郎")
    }

    // MARK: - optionalStringBinding(_:)

    @Test("optionalStringBinding(_:) get surfaces a nil field as an empty string")
    func optionalStringBindingGetSurfacesNilAsEmptyString() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appConfig = makeAppConfig(in: dir)
        #expect(appConfig.data.llm.claude.cliPath == nil)

        let binding = appConfig.optionalStringBinding(\.llm.claude.cliPath)
        #expect(binding.wrappedValue == "")
    }

    @Test("optionalStringBinding(_:) get surfaces a non-nil field as its raw string value")
    func optionalStringBindingGetSurfacesNonNilValue() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appConfig = makeAppConfig(in: dir)
        appConfig.update { $0.llm.claude.cliPath = "/usr/local/bin/claude" }

        let binding = appConfig.optionalStringBinding(\.llm.claude.cliPath)
        #expect(binding.wrappedValue == "/usr/local/bin/claude")
    }

    @Test("optionalStringBinding(_:) set with a non-empty string writes the raw string, not nil")
    func optionalStringBindingSetWritesNonEmptyString() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appConfig = makeAppConfig(in: dir)

        let binding = appConfig.optionalStringBinding(\.llm.claude.cliPath)
        binding.wrappedValue = "/opt/homebrew/bin/claude"

        #expect(appConfig.data.llm.claude.cliPath == "/opt/homebrew/bin/claude")
    }

    @Test("optionalStringBinding(_:) set with an empty string round-trips to nil, not \"\"")
    func optionalStringBindingSetWithEmptyStringRoundTripsToNil() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appConfig = makeAppConfig(in: dir)
        appConfig.update { $0.llm.claude.cliPath = "/usr/local/bin/claude" }

        let binding = appConfig.optionalStringBinding(\.llm.claude.cliPath)
        binding.wrappedValue = ""

        #expect(appConfig.data.llm.claude.cliPath == nil, "an emptied field must round-trip to nil, per the \"空欄で自動検出/無効\" convention")
    }

    // MARK: - updateLLM(_:) (`docs/design/44-llm-model-config.md` §9)

    @Test("updateLLM(_:) applies the mutation block to llm")
    func updateLLMAppliesMutationBlock() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appConfig = makeAppConfig(in: dir)

        appConfig.updateLLM { llm in
            llm.providers["azure"] = .openai(.default)
            llm.models["premium"] = ModelAliasConfig(provider: "azure", model: "gpt-5.4-mini")
        }

        #expect(appConfig.data.llm.providers["azure"] == .openai(.default))
        #expect(appConfig.data.llm.models["premium"]?.model == "gpt-5.4-mini")
    }

    @Test("updateLLM(_:) clears defaultProviderName, promoting a legacy-migrated config to new format immediately")
    func updateLLMClearsLegacySentinel() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appConfig = makeAppConfig(in: dir)
        // A freshly-created config (no config.yaml on disk) starts out as the legacy sentinel
        // (`LLMConfig.default.defaultProviderName == "claude"`, mirroring `init(from:)`'s migration
        // for a config.yaml missing the `llm:` key).
        #expect(appConfig.data.llm.isLegacySentinelDefault)

        // Even a no-op mutation block clears the sentinel -- the promotion happens unconditionally,
        // not only when the block itself touches `providers`/`models`/`defaultAlias`.
        appConfig.updateLLM { _ in }

        #expect(!appConfig.data.llm.isLegacySentinelDefault)
        #expect(appConfig.data.llm.defaultProviderName == nil)
    }

    @Test("updateLLM(_:) persists the new §2.1 shape to disk and stops writing the legacy llm.provider/claude/openai keys")
    func updateLLMPersistsNewFormatOnly() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appConfig = makeAppConfig(in: dir)

        appConfig.updateLLM { llm in
            llm.defaultAlias = "auto"
            llm.models["auto"] = ModelAliasConfig(provider: "claude", model: "claude-haiku-4-5-20251001")
        }

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let llm = root?["llm"] as? [String: Any]
        #expect(llm?.keys.contains("providers") == true)
        #expect(llm?.keys.contains("models") == true)
        #expect(llm?.keys.contains("default") == true)
        #expect(llm?.keys.contains("provider") == false, "legacy llm.provider must stop being written once the new tab has edited this config")
        #expect(llm?.keys.contains("claude") == false)
        #expect(llm?.keys.contains("openai") == false)
    }

    @Test("updateLLM(_:) mutation and the new-format promotion both survive a reload across AppConfig instances")
    func updateLLMPersistsAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appConfig = makeAppConfig(in: dir)

        appConfig.updateLLM { llm in
            llm.providers["azure"] = .openai(.default)
            llm.defaultAlias = "auto"
        }

        let reloaded = makeAppConfig(in: dir)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.llm.providers["azure"] == .openai(.default))
        #expect(reloaded.data.llm.defaultAlias == "auto")
        #expect(!reloaded.data.llm.isLegacySentinelDefault, "a reloaded new-format config must decode via the llm.providers branch, not the legacy migration")
    }
}
