import Foundation
import Testing

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
}
