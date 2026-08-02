import Foundation

// MARK: - LLMProviderRenameError

/// Failure modes for `LLMProviderRename.rename(...)` (`docs/design/44-llm-model-config.md` §9's
/// "プロバイダ名は... UI でも検証（不正は保存拒否 + 説明）"). The Settings "プロバイダ" section is
/// expected to surface `localizedDescription` (or an equivalent switch) as the save-rejection
/// explanation.
enum LLMProviderRenameError: Error, Equatable {
    case emptyName
    /// `newName` fails `LLMConfig.isValidProviderName(_:)` (`[A-Za-z0-9_-]+`).
    case invalidCharacters(String)
    /// `newName` already names a different provider (`oldName` renaming to itself is not a
    /// collision -- see `rename(...)`'s doc comment).
    case nameCollision(String)
    case providerNotFound(String)
}

extension LLMProviderRenameError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "プロバイダ名を入力してください。"
        case .invalidCharacters(let name):
            return "プロバイダ名「\(name)」に使用できない文字が含まれています（英数字・ハイフン・アンダースコアのみ）。"
        case .nameCollision(let name):
            return "プロバイダ名「\(name)」は既に使用されています。"
        case .providerNotFound(let name):
            return "プロバイダ「\(name)」が見つかりません。"
        }
    }
}

// MARK: - LLMProviderRename

/// Pure rewrite of `LLMConfig` for a provider rename (`docs/design/44-llm-model-config.md` §9's
/// "rename は「models の参照書き換え + credential move」を1つの update {} で原子的に行う"). This type
/// only produces the *config* half of that atomicity -- the `llm.providers` entry itself, plus every
/// `llm.models` alias that references the old name by provider -- in one pure rewrite the caller
/// applies via a single `AppConfig.updateLLM(_:)` call. The *credential* half (moving the
/// `CredentialAccount.providerAPIKey(name:)` secret) cannot be pure -- it needs a `CredentialStoring`
/// -- so this type only hands back the `from`/`to` account strings (`credentialMove`) for the caller
/// to move in the same user action, immediately before or after the config write.
///
/// Deliberately scoped to `llm.providers`/`llm.models` only, per §9's own wording -- feature-level
/// fields that reference a provider directly (`refinement.model: "azure/gpt-5.4-mini"`, say) are not
/// rewritten. Referencing a provider by name outside a named `llm.models` alias is already an
/// unusual, power-user pattern (the "機能別割り当て" UI only ever writes alias names or leaves a
/// field on an alias); accepting that such a reference goes stale on rename is the same trade-off
/// `docs/design/44-llm-model-config.md` §10 already makes for "レジストリに無いプロバイダ名" in
/// general (warning + fallthrough, never silently corrupted data).
enum LLMProviderRename {
    /// The result of a successful rename: the rewritten config, plus the credential accounts the
    /// caller should move (a no-op if nothing was ever stored under `from`).
    struct Applied: Equatable {
        var config: LLMConfig
        var credentialMove: (from: String, to: String)

        static func == (lhs: Applied, rhs: Applied) -> Bool {
            lhs.config == rhs.config && lhs.credentialMove.from == rhs.credentialMove.from
                && lhs.credentialMove.to == rhs.credentialMove.to
        }
    }

    /// Renames `oldName` to `newName` within `config`. `newName == oldName` is accepted as a no-op
    /// rename (the collision check only fires against a *different* provider already using
    /// `newName`) -- callers that only want to react to real renames should compare `oldName`/
    /// `newName` themselves before calling this.
    static func rename(config: LLMConfig, from oldName: String, to newName: String) throws -> Applied {
        guard !newName.isEmpty else { throw LLMProviderRenameError.emptyName }
        guard LLMConfig.isValidProviderName(newName) else {
            throw LLMProviderRenameError.invalidCharacters(newName)
        }
        guard let providerConfig = config.providers[oldName] else {
            throw LLMProviderRenameError.providerNotFound(oldName)
        }
        if newName != oldName, config.providers[newName] != nil {
            throw LLMProviderRenameError.nameCollision(newName)
        }

        var updatedConfig = config
        updatedConfig.providers.removeValue(forKey: oldName)
        updatedConfig.providers[newName] = providerConfig

        // Rewrites every `llm.models` alias pointing at the renamed provider -- both origin forms
        // (`ModelAliasConfig`'s short-string form and its structured-object form) unify into the
        // same `provider` field once decoded, so a single pass over `updatedConfig.models` covers
        // both without needing to know which form the entry originally came from.
        for (aliasName, definition) in updatedConfig.models where definition.provider == oldName {
            var rewritten = definition
            rewritten.provider = newName
            updatedConfig.models[aliasName] = rewritten
        }

        return Applied(
            config: updatedConfig,
            credentialMove: (
                from: CredentialAccount.providerAPIKey(name: oldName),
                to: CredentialAccount.providerAPIKey(name: newName)
            )
        )
    }
}
