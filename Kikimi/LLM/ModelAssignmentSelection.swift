import Foundation

/// A feature's `model` `config.yaml` field (`refinement.model`/`summary.model`/`summary.final_model`/
/// `chat.model`/`watchers.default_model`/`dictation.model`), split into what the Settings "モデル"
/// タブ's 機能別割り当て `Picker` can represent (`docs/design/44-llm-model-config.md` §9): "デフォルト"
/// (empty field -- every field's empty value means デフォルト now, not just the two that used to opt in
/// via `allowsUnset`), one of `llm.models`' alias names, or a raw値（`provider/model` ペア・素のモデル名・
/// もう存在しないエイリアス名）that YAML 手編集で入った "(直接指定: <値>)" 表示。 Kept free of SwiftUI so
/// the value <-> raw-string conversion is directly unit-testable, per this module's test plan.
enum ModelAssignmentSelection: Equatable {
    /// The persisted field is empty -- "デフォルト"（§9 の統一仕様。以前フィールドごとに違った
    /// `allowsUnset` 分岐は廃止し、全フィールドで空 = デフォルトに統一した）。
    case unset
    /// The persisted field exactly matches one of `knownAliasNames` (`ModelMenuItems.aliasNames(config:)`
    /// order -- every `llm.models` alias, name-sorted; no reserved names, §2.1).
    case alias(String)
    /// Anything else, non-empty: a `"provider/model"` pair, a bare model name, or an alias name that no
    /// longer exists in `llm.models` -- the Picker cannot (and per §3.1 does not need to) distinguish
    /// those three from each other. Rendered as a read-only "(直接指定: <値>)" item; picking a different
    /// item replaces it (§9's "選び直すと定義参照に置き換わる").
    case direct(String)

    /// Parses `raw` (the field's current `config.yaml` value) against `knownAliasNames`.
    static func parse(_ raw: String, knownAliasNames: [String]) -> ModelAssignmentSelection {
        if raw.isEmpty {
            return .unset
        }
        if knownAliasNames.contains(raw) {
            return .alias(raw)
        }
        return .direct(raw)
    }

    /// The exact string this selection should be persisted back to `config.yaml` as.
    var rawValue: String {
        switch self {
        case .unset: return ""
        case .alias(let name): return name
        case .direct(let value): return value
        }
    }
}
