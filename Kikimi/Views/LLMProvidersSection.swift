import SwiftUI

// MARK: - LLMProvidersSection

/// The "モデル" タブの「プロバイダ」セクション (`docs/design/44-llm-model-config.md` §9): a named list +
/// detail pane, mirroring `GlossarySettingsTab`'s カテゴリ list+detail pattern. Renders inside the
/// shared `Form` as one `Section`, using a fixed-height sidebar+detail `HStack` rather than a
/// `Form`-native row list -- each provider's detail is itself a small sub-form whose fields depend on
/// `kind`, which does not fit a single-row `LabeledContent` the way `Section("バッチ整形")`'s fields do.
///
/// Every mutation here goes through `AppConfig.updateLLM(_:)` (never plain `update {}`), so touching
/// anything in this section promotes a legacy-migrated config to genuine new format immediately (§9's
/// "編集すると新形式で保存される").
struct LLMProvidersSection: View {
    @ObservedObject var appConfig: AppConfig
    @ObservedObject var viewModel: SettingsViewModel

    @State private var selection: String?
    @State private var pendingDeleteProviderName: String?
    /// Set by `addProvider()`; focuses the new provider's name field so it can be renamed
    /// immediately instead of being left as the generated placeholder (mirrors
    /// `GlossarySettingsTab.categoryPendingRename`).
    @State private var providerPendingRename: String?
    @State private var nameDraft = ""
    @State private var renameError: String?
    @FocusState private var isNameFieldFocused: Bool

    private var sortedProviderNames: [String] {
        appConfig.data.llm.providers.keys.sorted()
    }

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 0) {
                sidebar
                    .frame(width: 160)
                Divider()
                detail
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.leading, 8)
            }
            .frame(minHeight: 220, idealHeight: 240, maxHeight: 260)

            Text(
                "接続設定の変更・追加はアプリ再起動後に反映されます"
                    + "（追加したプロバイダが解決・モデル選択の候補に現れるのも再起動後）。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
            Text("プロバイダ")
        }
        .onAppear {
            if selection == nil { selection = sortedProviderNames.first }
        }
        .onChange(of: selection) { oldValue, newValue in
            if let oldValue { viewModel.persistProviderAPIKeyDraftIfChanged(providerName: oldValue) }
            nameDraft = newValue ?? ""
            renameError = nil
        }
        .onChange(of: providerPendingRename) { _, pending in
            guard pending != nil else { return }
            isNameFieldFocused = true
            providerPendingRename = nil
        }
        .onDisappear {
            if let selection { viewModel.persistProviderAPIKeyDraftIfChanged(providerName: selection) }
        }
        .alert(
            "プロバイダを削除しますか？",
            isPresented: Binding(
                get: { pendingDeleteProviderName != nil },
                set: { if !$0 { pendingDeleteProviderName = nil } }
            )
        ) {
            Button("削除", role: .destructive) {
                if let name = pendingDeleteProviderName { deleteProvider(name) }
                pendingDeleteProviderName = nil
            }
            Button("キャンセル", role: .cancel) { pendingDeleteProviderName = nil }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(sortedProviderNames, id: \.self) { name in
                    row(for: name)
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 4) {
                Button(action: addProvider) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("プロバイダを追加")

                Button {
                    if let selection { pendingDeleteProviderName = selection }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                .help("選択中のプロバイダを削除")

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func row(for name: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).lineLimit(1)
            Text(kindLabel(providerKind(for: name)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .tag(name)
        .contentShape(Rectangle())
        .onTapGesture { selection = name }
    }

    private func kindLabel(_ kind: LLMProviderKind) -> String {
        switch kind {
        case .claudeCLI: return "Claude CLI"
        case .openai: return "OpenAI 互換 API"
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let selection, appConfig.data.llm.providers[selection] != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    nameField
                    Picker("種別", selection: kindBinding(for: selection)) {
                        Text("Claude CLI（サブスク認証）").tag(LLMProviderKind.claudeCLI)
                        Text("OpenAI 互換 API").tag(LLMProviderKind.openai)
                    }
                    if providerKind(for: selection) == .claudeCLI {
                        claudeFields(for: selection)
                    } else {
                        openAIFields(for: selection)
                    }
                }
                .padding(.vertical, 4)
            }
            .task(id: selection) { viewModel.loadProviderAPIKeyDraftIfNeeded(providerName: selection) }
        } else {
            VStack {
                Spacer()
                Text("左のリストからプロバイダを選択してください")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("プロバイダ名", text: $nameDraft, onCommit: commitRename)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .focused($isNameFieldFocused)
                .help("config.yaml: llm.providers.<名前>（英数字・ハイフン・アンダースコアのみ）")
            if let renameError {
                Text(renameError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func claudeFields(for name: String) -> some View {
        TextField(
            "claude 実行ファイルパス",
            text: cliPathBinding(for: name),
            prompt: Text("空欄で自動検出")
        )
    }

    @ViewBuilder
    private func openAIFields(for name: String) -> some View {
        TextField("Base URL", text: openAIStringBinding(for: name, \.baseURL))
        SecureField(
            "API キー", text: apiKeyDraftBinding(for: name),
            prompt: Text("暗号化ストレージに保存されます")
        )
        .onSubmit { viewModel.persistProviderAPIKeyDraftIfChanged(providerName: name) }
        TextField(
            "API キー環境変数名", text: openAIStringBinding(for: name, \.apiKeyEnv),
            prompt: Text("任意・フォールバック用")
        )
        TextField(
            "モデル固定", text: openAIStringBinding(for: name, \.model),
            prompt: Text("空欄で無効（Azure デプロイ名向け）")
        )
        TextField(
            "API バージョン", text: openAIStringBinding(for: name, \.apiVersion),
            prompt: Text("空欄で無効（Azure legacy 用）")
        )
        Picker("認証ヘッダ", selection: openAIStringBinding(for: name, \.authHeader)) {
            Text("自動判定").tag("")
            Text("Authorization: Bearer").tag("bearer")
            Text("api-key").tag("api-key")
        }
        Picker("Reasoning Effort（既定）", selection: openAIStringBinding(for: name, \.reasoningEffort)) {
            Text("指定しない").tag("")
            Text("none").tag("none")
            Text("minimal").tag("minimal")
            Text("low").tag("low")
            Text("medium").tag("medium")
            Text("high").tag("high")
            Text("xhigh").tag("xhigh")
        }
        .help("モデル定義の effort が優先されます（未指定時のみここが使われます）")
    }

    // MARK: Model access helpers

    private func providerKind(for name: String) -> LLMProviderKind {
        appConfig.data.llm.providers[name]?.kind ?? .claudeCLI
    }

    private func claudeConfig(for name: String) -> ClaudeBackendConfig {
        if case .claudeCLI(let config) = appConfig.data.llm.providers[name] { return config }
        return .default
    }

    private func openAIConfig(for name: String) -> OpenAIBackendConfig {
        if case .openai(let config) = appConfig.data.llm.providers[name] { return config }
        return .default
    }

    private func kindBinding(for name: String) -> Binding<LLMProviderKind> {
        Binding(
            get: { providerKind(for: name) },
            set: { newKind in
                appConfig.updateLLM { llm in
                    switch newKind {
                    case .claudeCLI: llm.providers[name] = .claudeCLI(.default)
                    case .openai: llm.providers[name] = .openai(.default)
                    }
                }
            }
        )
    }

    private func cliPathBinding(for name: String) -> Binding<String> {
        Binding(
            get: { claudeConfig(for: name).cliPath ?? "" },
            set: { newValue in
                appConfig.updateLLM { llm in
                    var config = claudeConfig(for: name)
                    config.cliPath = newValue.isEmpty ? nil : newValue
                    llm.providers[name] = .claudeCLI(config)
                }
            }
        )
    }

    private func openAIStringBinding(
        for name: String, _ keyPath: WritableKeyPath<OpenAIBackendConfig, String>
    ) -> Binding<String> {
        Binding(
            get: { openAIConfig(for: name)[keyPath: keyPath] },
            set: { newValue in
                appConfig.updateLLM { llm in
                    var config = openAIConfig(for: name)
                    config[keyPath: keyPath] = newValue
                    llm.providers[name] = .openai(config)
                }
            }
        )
    }

    private func apiKeyDraftBinding(for name: String) -> Binding<String> {
        Binding(
            get: { viewModel.providerAPIKeyDrafts[name] ?? "" },
            set: { viewModel.updateProviderAPIKeyDraft(providerName: name, value: $0) }
        )
    }

    // MARK: Actions

    private func addProvider() {
        let name = uniqueProviderName()
        appConfig.updateLLM { $0.providers[name] = .claudeCLI(.default) }
        selection = name
        providerPendingRename = name
    }

    private func uniqueProviderName() -> String {
        var index = appConfig.data.llm.providers.count + 1
        var candidate = "provider-\(index)"
        while appConfig.data.llm.providers[candidate] != nil {
            index += 1
            candidate = "provider-\(index)"
        }
        return candidate
    }

    private func deleteProvider(_ name: String) {
        appConfig.updateLLM { $0.providers.removeValue(forKey: name) }
        viewModel.deleteProviderAPIKeyCredential(providerName: name)
        if selection == name { selection = sortedProviderNames.first }
    }

    /// Renaming rewrites the dictionary key the provider is stored under, so (unlike
    /// `GlossaryCategoryDetailView.categoryNameBinding`, which renames a stable `id`'s `name` field)
    /// this cannot be a live per-keystroke `Binding` -- every intermediate keystroke would otherwise
    /// need to be a momentarily-valid, non-colliding provider name. Committed on Return instead
    /// (`TextField(... onCommit:)`), with `renameError` surfacing §9's "保存拒否 + 説明" inline.
    private func commitRename() {
        renameError = nil
        guard let current = selection, nameDraft != current else { return }
        do {
            let applied = try LLMProviderRename.rename(config: appConfig.data.llm, from: current, to: nameDraft)
            appConfig.updateLLM { $0 = applied.config }
            viewModel.renameProviderAPIKeyCredential(from: current, to: nameDraft)
            selection = nameDraft
        } catch {
            renameError = (error as? LocalizedError)?.errorDescription ?? "名前を変更できませんでした。"
            nameDraft = current
        }
    }

    private func referencingAliasNames(_ providerName: String) -> [String] {
        appConfig.data.llm.models
            .filter { $0.value.provider == providerName }
            .keys
            .sorted()
    }

    private var deleteConfirmationMessage: String {
        guard let name = pendingDeleteProviderName else { return "" }
        let refs = referencingAliasNames(name)
        guard !refs.isEmpty else { return "「\(name)」を削除します。" }
        return "「\(name)」を参照しているモデル定義があります: \(refs.joined(separator: "、"))。"
            + "削除すると、それらのモデル定義は解決時に警告のうえ既定にフォールバックします。"
    }
}
