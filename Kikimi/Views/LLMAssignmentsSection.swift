import SwiftUI

// MARK: - ModelAssignmentPicker

/// One 機能別割り当て row (`docs/design/44-llm-model-config.md` §9): a `Picker` over "デフォルト" +
/// `aliasNames` only -- no free-text "カスタム…" entry (removed; direct model-id entry belongs to
/// モデル定義 now, not here). Backed by `ModelAssignmentSelection`'s pure value<->raw-string
/// conversion. When the persisted value is a YAML-hand-edited `provider/model` pair, a bare model
/// name, or a stale alias name, an extra read-only "(直接指定: <値>)" item is appended so the current
/// value stays visible; picking any other item replaces it (§9's "選び直すと定義参照に置き換わる").
struct ModelAssignmentPicker: View {
    let label: String
    @Binding var value: String
    let aliasNames: [String]
    /// Parenthetical appended to the "デフォルト" item's label for fields whose fallback-beyond-
    /// `llm.default` behavior is worth surfacing inline (e.g. `summary.final_model`'s "サマリと同じ
    /// モデル"). Empty for the ordinary case, which just reads "デフォルト".
    var defaultHint = ""

    private enum Tag: Hashable {
        case unset
        case alias(String)
        case direct(String)
    }

    private var selection: ModelAssignmentSelection {
        ModelAssignmentSelection.parse(value, knownAliasNames: aliasNames)
    }

    private var defaultLabel: String {
        defaultHint.isEmpty ? "デフォルト" : "デフォルト（\(defaultHint)）"
    }

    var body: some View {
        Picker(label, selection: tagBinding) {
            Text(defaultLabel).tag(Tag.unset)
            ForEach(aliasNames, id: \.self) { name in
                Text(name).tag(Tag.alias(name))
            }
            if case .direct(let raw) = selection {
                Text("(直接指定: \(raw))").tag(Tag.direct(raw))
            }
        }
    }

    private var tagBinding: Binding<Tag> {
        Binding(
            get: {
                switch selection {
                case .unset: return .unset
                case .alias(let name): return .alias(name)
                case .direct(let raw): return .direct(raw)
                }
            },
            set: { newTag in
                switch newTag {
                case .unset: value = ModelAssignmentSelection.unset.rawValue
                case .alias(let name): value = ModelAssignmentSelection.alias(name).rawValue
                case .direct: break // read-only placeholder for the already-selected raw value
                }
            }
        )
    }
}

// MARK: - LLMAssignmentsSection

/// The "モデル" タブの「機能別割り当て」セクション (`docs/design/44-llm-model-config.md` §9): one
/// `ModelAssignmentPicker` row per feature. Candidates are `ModelMenuItems.aliasNames(config:)`
/// (name-sorted, no reserved names, §2.1) -- "デフォルト" is prepended by `ModelAssignmentPicker`
/// itself, and there is no free-text entry.
struct LLMAssignmentsSection: View {
    @ObservedObject var appConfig: AppConfig

    private var aliasNames: [String] { ModelMenuItems.aliasNames(config: appConfig.data.llm) }

    var body: some View {
        Section {
            ModelAssignmentPicker(label: "整形", value: appConfig.binding(\.refinement.model), aliasNames: aliasNames)
                .help("config.yaml: refinement.model")
            ModelAssignmentPicker(label: "サマリ", value: appConfig.binding(\.summary.model), aliasNames: aliasNames)
                .help("config.yaml: summary.model")
            ModelAssignmentPicker(
                label: "サマリ最終整形", value: appConfig.optionalStringBinding(\.summary.finalModel),
                aliasNames: aliasNames, defaultHint: "サマリと同じモデル"
            )
            .help("config.yaml: summary.final_model")
            ModelAssignmentPicker(label: "チャット", value: appConfig.binding(\.chat.model), aliasNames: aliasNames)
                .help("config.yaml: chat.model")
            ModelAssignmentPicker(
                label: "Watcher 既定", value: appConfig.binding(\.watchers.defaultModel), aliasNames: aliasNames
            )
            .help("config.yaml: watchers.default_model")
            ModelAssignmentPicker(
                label: "ディクテーション", value: appConfig.binding(\.dictation.model),
                aliasNames: aliasNames,
                // Legacy (un-migrated) configs keep dictation's historical empty-value fallback to
                // watchers.default_model (§4's regression guard); a new-format config falls back to
                // llm.default like every other row, so no hint is needed there.
                defaultHint: appConfig.data.llm.isLegacySentinelDefault ? "Watcher 既定と同じモデル" : ""
            )
            .help("config.yaml: dictation.model")
        } header: {
            Text("機能別割り当て")
        } footer: {
            Text(
                "反映タイミング: 整形・サマリ・サマリ最終整形・チャットは次セッションから、"
                    + "Watcher 既定は次回実行から、ディクテーションは次回変換から反映されます。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
