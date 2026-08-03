import SwiftUI

// MARK: - LLMModelsSection

/// The "モデル" タブの「モデル定義」セクション (`docs/design/44-llm-model-config.md` §9), as a named
/// list + detail pane mirroring `LLMProvidersSection` (and, originally, `GlossarySettingsTab`'s
/// カテゴリ pattern) -- earlier one-row-per-definition layouts crammed every control into a single
/// grouped-Form line and collapsed into an unreadable mess.
///
/// **No reserved names** (§2.1's "予約名は設けない"): every definition is an ordinary, equally-treated
/// alias -- all can be renamed and deleted. `llm.default` is edited exclusively through the
/// "デフォルトにする" toggle in the detail pane (never as a raw text field): turning it on writes the
/// selected definition's name to `llm.default` (at most one row is ever the default), turning it off
/// -- or deleting the default row -- clears `llm.default` back to empty (§9's "デフォルト = 内蔵既定
/// （claude-haiku）").
struct LLMModelsSection: View {
    @ObservedObject var appConfig: AppConfig

    @State private var selection: String?
    @State private var nameDraft = ""
    @State private var renameError: String?
    /// Live-typed model-name draft for the *selected* definition (§9's "モデル名 TextField は空を
    /// 保存拒否 + 説明表示"): the field always reflects what the user is currently typing (so
    /// clearing it to retype is never blocked), but only a non-empty trimmed value is ever written
    /// to `llm.models.<name>.model`.
    @State private var modelDraft = ""
    /// Set by `addDefinition()`; focuses the new definition's name field so it can be renamed
    /// immediately instead of being left as the generated placeholder (mirrors
    /// `LLMProvidersSection.providerPendingRename`).
    @State private var definitionPendingRename: String?
    @FocusState private var isNameFieldFocused: Bool

    private var sortedNames: [String] {
        appConfig.data.llm.models.keys.sorted()
    }
    private var providerNames: [String] { appConfig.data.llm.providers.keys.sorted() }

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
            .frame(minHeight: 200, idealHeight: 220, maxHeight: 240)
        } header: {
            Text("モデル定義")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Effort・Timeout はこのモデルを使う全機能に効きます（Timeout は延長のみ。0 で未設定）。")
                if appConfig.data.llm.defaultAlias.isEmpty {
                    Text("デフォルトが未指定です。内蔵既定（\(ModelResolver.builtinModelName)）が使われます。")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear {
            if selection == nil { selection = sortedNames.first }
            syncDrafts(to: selection)
        }
        .onChange(of: selection) { _, newValue in
            syncDrafts(to: newValue)
        }
        .onChange(of: definitionPendingRename) { _, pending in
            guard pending != nil else { return }
            isNameFieldFocused = true
            definitionPendingRename = nil
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(sortedNames, id: \.self) { name in
                    sidebarRow(for: name)
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 4) {
                Button(action: addDefinition) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("モデル定義を追加")

                Button {
                    if let selection { deleteDefinition(selection) }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                .help("選択中のモデル定義を削除")

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func sidebarRow(for name: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(name).lineLimit(1)
                if appConfig.data.llm.defaultAlias == name {
                    Text("デフォルト")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                }
            }
            Text(summaryLine(for: name))
                .font(.caption2)
                .foregroundStyle(isModelNameEmpty(name) ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .tag(name)
        .contentShape(Rectangle())
        .onTapGesture { selection = name }
    }

    private func summaryLine(for name: String) -> String {
        let definition = definition(for: name)
        let provider = definition.provider ?? ModelResolver.builtinProviderName
        let model = currentModelText(for: name)
        return model.isEmpty ? "\(provider) / モデル名未設定" : "\(provider) / \(model)"
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let selection, appConfig.data.llm.models[selection] != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    nameField
                    if providerNames.isEmpty {
                        LabeledContent("プロバイダ") {
                            Text("先にプロバイダを追加してください")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("プロバイダ", selection: providerBinding(selection)) {
                            ForEach(providerNames, id: \.self) { providerName in
                                Text(providerName).tag(providerName)
                            }
                        }
                    }
                    modelNameField(for: selection)
                    Picker("Effort", selection: effortBinding(selection)) {
                        Text("なし").tag("")
                        Text("none").tag("none")
                        Text("minimal").tag("minimal")
                        Text("low").tag("low")
                        Text("medium").tag("medium")
                        Text("high").tag("high")
                        Text("xhigh").tag("xhigh")
                    }
                    SettingsIntField(
                        label: "Timeout", unit: "秒", value: timeoutBinding(selection), range: 0...1_800, step: 30
                    )
                    Toggle("デフォルトにする", isOn: isDefaultBinding(selection))
                        .toggleStyle(.checkbox)
                }
                .padding(.vertical, 4)
            }
        } else {
            VStack {
                Spacer()
                Text("左のリストからモデル定義を選択してください")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("モデル定義名", text: $nameDraft, onCommit: commitRename)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .focused($isNameFieldFocused)
                .help("config.yaml: llm.models.<名前>。機能別割り当てやモデル選択メニューに出る名前です")
            if let renameError {
                Text(renameError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func modelNameField(for name: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("モデル名", text: modelDraftBinding(name), prompt: Text("例: claude-sonnet-5"))
            if isModelNameEmpty(name) {
                Text("モデル名を入力してください。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: Model access helpers

    private func definition(for name: String) -> ModelAliasConfig {
        appConfig.data.llm.models[name] ?? ModelAliasConfig(provider: nil, model: "")
    }

    /// The selected row's text comes from the live draft (mid-edit emptiness stays visible);
    /// unselected rows read the persisted value.
    private func currentModelText(for name: String) -> String {
        let raw = name == selection ? modelDraft : definition(for: name).model
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isModelNameEmpty(_ name: String) -> Bool {
        currentModelText(for: name).isEmpty
    }

    private func updateDefinition(_ name: String, _ mutate: (inout ModelAliasConfig) -> Void) {
        appConfig.updateLLM { llm in
            var definition = llm.models[name] ?? ModelAliasConfig(provider: nil, model: "")
            mutate(&definition)
            llm.models[name] = definition
        }
    }

    private func providerBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { definition(for: name).provider ?? providerNames.first ?? "" },
            set: { newValue in updateDefinition(name) { $0.provider = newValue } }
        )
    }

    /// See `modelDraft`'s doc comment: `set` only ever forwards a non-empty trimmed value to
    /// `updateDefinition` -- §9's "空を保存拒否".
    private func modelDraftBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { modelDraft },
            set: { newValue in
                modelDraft = newValue
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                updateDefinition(name) { $0.model = trimmed }
            }
        )
    }

    private func effortBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { definition(for: name).effort ?? "" },
            set: { newValue in updateDefinition(name) { $0.effort = newValue.isEmpty ? nil : newValue } }
        )
    }

    private func timeoutBinding(_ name: String) -> Binding<Int> {
        Binding(
            get: { definition(for: name).timeoutSeconds ?? 0 },
            set: { newValue in updateDefinition(name) { $0.timeoutSeconds = newValue == 0 ? nil : newValue } }
        )
    }

    /// "デフォルトにする" toggle (§9): on iff this definition is `llm.default`. Turning it on writes
    /// this name to `llm.default` (implicitly un-marking every other row); turning it off clears
    /// `llm.default` back to empty.
    private func isDefaultBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { appConfig.data.llm.defaultAlias == name },
            set: { newValue in
                appConfig.updateLLM { llm in
                    llm.defaultAlias = newValue ? name : ""
                }
            }
        )
    }

    // MARK: Rename / add / delete

    private func syncDrafts(to name: String?) {
        nameDraft = name ?? ""
        renameError = nil
        modelDraft = name.map { definition(for: $0).model } ?? ""
    }

    private func commitRename() {
        guard let oldName = selection else { return }
        let newName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renameError = nil
        guard newName != oldName else { return }
        guard !newName.isEmpty else {
            renameError = "モデル定義名を入力してください。"
            nameDraft = oldName
            return
        }
        guard appConfig.data.llm.models[newName] == nil else {
            renameError = "「\(newName)」は既に使用されています。"
            nameDraft = oldName
            return
        }
        appConfig.updateLLM { llm in
            guard let definition = llm.models[oldName] else { return }
            llm.models.removeValue(forKey: oldName)
            llm.models[newName] = definition
            // Renaming the current default must carry llm.default along -- otherwise the rename
            // would silently clear the default (§9).
            if llm.defaultAlias == oldName { llm.defaultAlias = newName }
        }
        selection = newName
    }

    private func addDefinition() {
        let name = uniqueDefinitionName()
        let provider = providerNames.first ?? ModelResolver.builtinProviderName
        appConfig.updateLLM { $0.models[name] = ModelAliasConfig(provider: provider, model: "") }
        selection = name
        definitionPendingRename = name
    }

    private func deleteDefinition(_ name: String) {
        appConfig.updateLLM { llm in
            llm.models.removeValue(forKey: name)
            // §9's "デフォルト行を削除したら llm.default を空にし": nothing left to point at, so fall
            // back to the builtin default rather than leaving a dangling reference.
            if llm.defaultAlias == name { llm.defaultAlias = "" }
        }
        if selection == name {
            selection = sortedNames.first
        }
    }

    private func uniqueDefinitionName() -> String {
        var index = 1
        var candidate = "model-\(index)"
        while appConfig.data.llm.models[candidate] != nil {
            index += 1
            candidate = "model-\(index)"
        }
        return candidate
    }
}
