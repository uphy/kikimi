import SwiftUI

/// The "モデル" tab (`docs/design/44-llm-model-config.md` §9, Phase 3): four sections --
/// プロバイダ (`LLMProvidersSection`) / モデル定義 (`LLMModelsSection`) / 機能別割り当て
/// (`LLMAssignmentsSection`) / バッチ整形 (below, unchanged from Phase 1). Split across those
/// dedicated files purely to keep each one under the project's `file_length` lint limit (same
/// rationale as `GlossarySettingsTab`'s sidebar/detail split).
///
/// Every プロバイダ/モデル定義 edit reads/writes `llm.providers`/`llm.models`/`llm.default` in
/// `config.yaml`'s new §2.1 shape via `AppConfig.updateLLM(_:)` -- including configs the app is
/// still displaying in their legacy-migrated form (`llm.provider`/`llm.claude`/`llm.openai`, §4):
/// touching anything here promotes them to genuine new format immediately, closing the Phase 1
/// caveat that saving through the (now retired) single-provider UI kept writing the legacy shape.
///
/// Layout follows `docs/design/30-settings-ui-polish.md` §4.2: `.formStyle(.grouped)` (List-backed,
/// scrolls on its own -- no manual `ScrollView` wrapper needed, unlike the old columns-style
/// `Form`), long parenthetical labels decomposed into label + `prompt:` (behavior that matters
/// while the field is empty) or label + `.help` (the config.yaml key, worth a tooltip anytime).
/// Unlike the 一般 tab there is no top-level `DisclosureGroup("詳細")` here: this whole tab is
/// technical-audience territory (モデル定義 rows get their own per-row disclosure instead, §9).
struct ModelSettingsTab: View {
    @ObservedObject private var appConfig = AppConfig.shared

    /// Owns every プロバイダ detail pane's API-key draft and its one-shot credential-store
    /// load/persist -- not `@State` on any of this tab's view structs -- because `SettingsView`'s
    /// `TabView` tears down and reinstantiates non-selected tabs' view structs on every tab switch
    /// (observed in kikimi-verify: reading Keychain from a view's own `init`/`@State` fired the OS
    /// Keychain-access permission prompt on *every* tab switch, not once per window). `viewModel`
    /// is the one instance `SettingsWindowController` creates and keeps alive for the window's
    /// whole lifetime, so its one-shot guard actually holds regardless of how often this struct is
    /// rebuilt. See `SettingsViewModel.providerAPIKeyDrafts`'s doc comment.
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            LLMProvidersSection(appConfig: appConfig, viewModel: viewModel)
            LLMModelsSection(appConfig: appConfig)
            LLMAssignmentsSection(appConfig: appConfig)
            Section("バッチ整形") {
                SettingsIntField(
                    label: "バッチサイズ",
                    value: appConfig.binding(\.refinement.batchSize), range: 1...50
                )
                SettingsIntField(
                    label: "バッチタイムアウト", unit: "ms",
                    value: appConfig.binding(\.refinement.batchTimeoutMs),
                    range: 1_000...30_000, step: 500
                )
                SettingsIntField(
                    label: "コンテキストセグメント数",
                    value: appConfig.binding(\.refinement.contextSegments), range: 0...10
                )
                SettingsIntField(
                    label: "コンテキスト再構築間隔", unit: "バッチ",
                    value: appConfig.binding(\.refinement.contextRefreshBatches), range: 1...50
                )
            }
        }
        .formStyle(.grouped)
    }
}
