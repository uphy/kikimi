import SwiftUI

/// The "モデル" tab: `llm.provider`/`llm.claude`/`llm.openai` (API キーは `SecureField` 経由で
/// Keychain へ保存、`config.yaml` には平文を残さない) / `refinement` / `summary.model` /
/// `watchers.default_model` (`docs/design/26-settings-ui.md` §4.3). Split out of
/// `SettingsView.swift` purely to keep that file under the project's `file_length` lint limit
/// (same rationale as `DictationAppContextSection`'s file split).
///
/// Layout follows `docs/design/30-settings-ui-polish.md` §4.2: `.formStyle(.grouped)` (List-backed,
/// scrolls on its own -- no manual `ScrollView` wrapper needed, unlike the old columns-style
/// `Form`), long parenthetical labels decomposed into label + `prompt:` (behavior that matters
/// while the field is empty) or label + `.help` (the config.yaml key, worth a tooltip anytime).
/// Unlike the 一般 tab there is no `DisclosureGroup("詳細")` here: this whole tab is
/// technical-audience territory.
struct ModelSettingsTab: View {
    @ObservedObject private var appConfig = AppConfig.shared

    /// Owns the API-key draft and its one-shot Keychain load/persist -- not `@State` on this view
    /// struct -- because `SettingsView`'s `TabView` tears down and reinstantiates non-selected
    /// tabs' view structs on every tab switch (observed in kikimi-verify: reading Keychain from
    /// this view's own `init`/`@State` fired the OS Keychain-access permission prompt on *every*
    /// tab switch, not once per window). `viewModel` is the one instance `SettingsWindowController`
    /// creates and keeps alive for the window's whole lifetime, so its one-shot guard actually
    /// holds regardless of how often this struct is rebuilt. See `SettingsViewModel
    /// .openAIAPIKeyDraft`'s doc comment.
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("プロバイダ") {
                Picker("プロバイダ", selection: appConfig.binding(\.llm.provider)) {
                    Text("Claude CLI（サブスク認証）").tag(LLMProviderKind.claudeCLI)
                    Text("OpenAI 互換 API").tag(LLMProviderKind.openai)
                }
                if appConfig.data.llm.provider == .claudeCLI {
                    TextField(
                        "claude 実行ファイルパス",
                        text: appConfig.optionalStringBinding(\.llm.claude.cliPath),
                        prompt: Text("空欄で自動検出")
                    )
                } else {
                    TextField("Base URL", text: appConfig.binding(\.llm.openai.baseURL))
                    SecureField(
                        "API キー", text: apiKeyDraftBinding,
                        prompt: Text("Keychain に保存されます")
                    )
                    .onSubmit { viewModel.persistOpenAIAPIKeyDraftIfChanged() }
                    TextField(
                        "API キー環境変数名", text: appConfig.binding(\.llm.openai.apiKeyEnv),
                        prompt: Text("任意・フォールバック用")
                    )
                    TextField(
                        "モデル上書き", text: appConfig.binding(\.llm.openai.model),
                        prompt: Text("空欄で無効（Azure デプロイ名向け）")
                    )
                    TextField(
                        "API バージョン", text: appConfig.binding(\.llm.openai.apiVersion),
                        prompt: Text("空欄で無効（Azure legacy 用）")
                    )
                    Picker("認証ヘッダ", selection: appConfig.binding(\.llm.openai.authHeader)) {
                        Text("自動判定").tag("")
                        Text("Authorization: Bearer").tag("bearer")
                        Text("api-key").tag("api-key")
                    }
                    Picker("Reasoning Effort", selection: appConfig.binding(\.llm.openai.reasoningEffort)) {
                        Text("指定しない").tag("")
                        Text("none").tag("none")
                        Text("minimal").tag("minimal")
                        Text("low").tag("low")
                        Text("medium").tag("medium")
                        Text("high").tag("high")
                        Text("xhigh").tag("xhigh")
                    }
                    .help("gpt-5系推論モデルでのみ有効")
                }
            }
            Section("モデル") {
                TextField("整形モデル", text: appConfig.binding(\.refinement.model))
                    .help("config.yaml: refinement.model")
                TextField("サマリモデル", text: appConfig.binding(\.summary.model))
                    .help("config.yaml: summary.model")
                TextField("Watcher 既定モデル", text: appConfig.binding(\.watchers.defaultModel))
                    .help("config.yaml: watchers.default_model")
                // `docs/design/38-session-chat.md` §6: the one chat setting worth surfacing here.
                // The budget/history/timeout values stay config.yaml-only -- they are tuning knobs,
                // not choices anyone makes routinely.
                TextField("チャットモデル", text: appConfig.binding(\.chat.model))
                    .help("config.yaml: chat.model")
            }
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
        // Persist on tab disappear too, so navigating away without pressing Return doesn't drop an edit.
        .onDisappear { viewModel.persistOpenAIAPIKeyDraftIfChanged() }
        .task { viewModel.loadOpenAIAPIKeyDraftIfNeeded() }
    }

    private var apiKeyDraftBinding: Binding<String> {
        Binding(
            get: { viewModel.openAIAPIKeyDraft },
            set: { viewModel.updateOpenAIAPIKeyDraft($0) }
        )
    }
}
