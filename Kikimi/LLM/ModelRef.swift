import Foundation
import OSLog

// MARK: - LLMCallParams

/// Per-call parameters carried by a resolved `ModelRef` (`docs/design/44-llm-model-config.md` §3.3).
/// Only ever populated from a `llm.models` alias definition (`ModelAliasConfig`) -- a bare
/// `provider/model` `ModelRef` or a bare model name can never carry params (§3.3's "持ち場所は
/// モデル定義に限定する... 機能側の provider/model 直指定にはパラメータを付けられない").
struct LLMCallParams: Sendable, Equatable {
    /// Passed through to the backend verbatim, never validated here (§3.3: `"low"`/`"medium"`/
    /// `"high"` etc. for `claude-cli`'s `--effort`, or an OpenAI-style `reasoning_effort` string).
    var effort: String?
    /// Overrides the caller's timeout, but only upward -- see `ModelResolver.resolvedTimeoutSeconds`.
    var timeoutSeconds: Int?

    init(effort: String? = nil, timeoutSeconds: Int? = nil) {
        self.effort = effort
        self.timeoutSeconds = timeoutSeconds
    }
}

// MARK: - ResolvedModel

/// The output of `ModelResolver.resolve(candidates:config:availableProviders:)`
/// (`docs/design/44-llm-model-config.md` §3.2): a fully-settled provider + model + params triple,
/// ready to fill an `LLMRequest`'s `provider`/`model`/`params` fields.
struct ResolvedModel: Sendable, Equatable {
    /// `llm.providers` key (or the builtin implicit `"claude"`, `ModelResolver.builtinProviderName`).
    var provider: String
    /// Model id handed to the backend as-is.
    var model: String
    var params: LLMCallParams

    init(provider: String, model: String, params: LLMCallParams = .init()) {
        self.provider = provider
        self.model = model
        self.params = params
    }
}

// MARK: - ModelResolver

/// Resolves a `ModelRef` string (an `llm.models` alias name, a `"provider/model"` pair, or a bare
/// model name) into a `ResolvedModel`, per `docs/design/44-llm-model-config.md` §3. Pure -- every
/// input is a parameter, nothing is read from `AppConfig.shared` or `LLMClient.shared` directly, so
/// every rule in §3.1/§3.2/§3.3 is independently unit-testable.
enum ModelResolver {
    /// §3.2 step 5's builtin fallback: a `claude-cli` provider named `"claude"`, always considered to
    /// exist even when `llm.providers` (or `availableProviders`) is empty ("`llm.providers` が空でも
    /// 成立する... 既存の「config なしで動く」性質を保つ").
    static let builtinProviderName = "claude"
    static let builtinModelName = "claude-haiku-4-5-20251001"

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "ModelResolver")

    /// - Parameters:
    ///   - candidates: Priority-ordered `ModelRef` candidates (first wins). Each is tried against
    ///     §3.1's three rules in turn; `nil`/empty candidates are skipped silently, any other
    ///     unresolvable candidate (undefined alias, or a provider absent from `availableProviders`)
    ///     logs a warning and falls through to the next one. Once every candidate is exhausted,
    ///     `config.defaultAlias` (`llm.default`) is tried the same way (minus rule 3 -- see
    ///     `resolveCandidate`'s `allowBareModelFallback` doc comment), and finally the builtin default.
    ///   - config: Live `AppConfig.shared.data.llm` (or a snapshot) -- `models`/`default`/
    ///     `defaultProviderName` are read fresh per call so Settings edits apply to the next call.
    ///   - availableProviders: `LLMClient`'s *startup* snapshot of provider names (§3.2/§5.2) --
    ///     deliberately not `config.providers.keys`, so a provider added to `config.yaml` after this
    ///     process started (and thus has no live `LLMBackend` yet) is treated the same as an
    ///     unconfigured one: warning + fallthrough, never a hard failure.
    static func resolve(
        candidates: [String?],
        config: LLMConfig,
        availableProviders: Set<String>
    ) -> ResolvedModel {
        for candidate in candidates {
            if let resolved = resolveCandidate(
                candidate,
                config: config,
                availableProviders: availableProviders,
                allowBareModelFallback: true
            ) {
                return resolved
            }
        }

        // §3.2 step 4: `llm.default`. Rule 3 (bare model name) is deliberately not applied to this
        // candidate itself -- "default の解決結果のプロバイダ" has no meaning when the string being
        // resolved *is* `llm.default`. A legacy sentinel default (`isLegacySentinelDefault`) always
        // fails here too: `defaultAlias` is empty in that case (`LLMConfig.defaultProviderName`'s doc
        // comment), so neither rule 1 nor rule 2 can match, and step 5 always follows.
        if let resolved = resolveCandidate(
            config.defaultAlias,
            config: config,
            availableProviders: availableProviders,
            allowBareModelFallback: false
        ) {
            return resolved
        }
        // §10's "llm.default 自体が不正 → warning + builtin 既定". `resolveCandidate` stays silent
        // on the undefined-alias path (it can't tell `llm.default` from an ordinary candidate), so
        // the design-mandated warning is emitted here -- but only for a *set* default; an empty one
        // (including the legacy sentinel, whose defaultAlias is empty) is the normal builtin path.
        if !config.defaultAlias.isEmpty {
            logger.warning(
                "llm.default \"\(config.defaultAlias, privacy: .public)\" did not resolve; using builtin default"
            )
        }

        // §3.2 step 5.
        return ResolvedModel(provider: builtinProviderName, model: builtinModelName)
    }

    /// §3.3's `effort` priority: an explicit value on the resolved model definition wins; otherwise
    /// fall back to the resolved provider's `reasoning_effort` (`openai` providers only -- `claude-cli`
    /// has no equivalent provider-level default); otherwise no effort at all.
    static func resolvedEffort(params: LLMCallParams, provider: LLMProviderConfig?) -> String? {
        if let effort = params.effort, !effort.isEmpty {
            return effort
        }
        if case .openai(let openAIConfig) = provider, !openAIConfig.reasoningEffort.isEmpty {
            return openAIConfig.reasoningEffort
        }
        return nil
    }

    /// §3.3's timeout rule is extension-only: the effective timeout never goes *below*
    /// `functionDefaultSeconds` (the caller's explicit timeout, or `LLMRequest`'s own 60s default)
    /// even when the resolved model definition's `timeout_seconds` is smaller -- "モデル定義が機能側
    /// より短くても短縮はしない". A larger model-definition value extends the wait; a smaller (or
    /// absent) one changes nothing.
    static func resolvedTimeoutSeconds(functionDefaultSeconds: Int, modelDefinitionSeconds: Int?) -> Int {
        guard let modelDefinitionSeconds else { return functionDefaultSeconds }
        return max(functionDefaultSeconds, modelDefinitionSeconds)
    }

    /// Resolves one `ModelRef` string against §3.1's three rules, in order. Returns `nil` (after
    /// logging a warning, unless the candidate was simply nil/empty) when none apply, so the caller
    /// can fall through to the next candidate.
    ///
    /// - Parameter allowBareModelFallback: `false` only for the `llm.default` step (§3.2 step 4) --
    ///   rule 3 needs "default's provider", which is meaningless when the string being resolved is
    ///   `llm.default` itself.
    private static func resolveCandidate(
        _ candidate: String?,
        config: LLMConfig,
        availableProviders: Set<String>,
        allowBareModelFallback: Bool
    ) -> ResolvedModel? {
        guard let candidate, !candidate.isEmpty else { return nil }

        // Rule 1: alias exact match.
        if let definition = config.models[candidate] {
            // Defense against a definition persisted before its model name was filled in (the
            // Settings add-row flow, or a hand-edited config.yaml): an empty model would otherwise
            // travel all the way into `--model ""` / `"model": ""` on the wire.
            guard !definition.model.isEmpty else {
                logger.warning(
                    "ModelRef \"\(candidate, privacy: .public)\" resolved to a definition with an empty model name; skipping"
                )
                return nil
            }
            let provider = definition.provider ?? resolveDefaultProvider(config: config, availableProviders: availableProviders)
            guard let provider, availableProviders.contains(provider) else {
                logger.warning(
                    "ModelRef \"\(candidate, privacy: .public)\" resolved to alias with an unavailable provider; skipping"
                )
                return nil
            }
            return ResolvedModel(
                provider: provider,
                model: definition.model,
                params: LLMCallParams(effort: definition.effort, timeoutSeconds: definition.timeoutSeconds)
            )
        }

        // Rule 2: "provider/model", split at the first "/" so the model half may itself contain "/".
        if let slashIndex = candidate.firstIndex(of: "/") {
            let providerPart = String(candidate[candidate.startIndex..<slashIndex])
            let modelPart = String(candidate[candidate.index(after: slashIndex)...])
            guard availableProviders.contains(providerPart) else {
                logger.warning(
                    "ModelRef \"\(candidate, privacy: .public)\" references unavailable provider \"\(providerPart, privacy: .public)\"; skipping"
                )
                return nil
            }
            return ResolvedModel(provider: providerPart, model: modelPart)
        }

        // Rule 3: bare model name -- borrow only the default's provider, never its params
        // (`ModelAliasConfig.provider`'s doc comment).
        guard allowBareModelFallback else { return nil }
        guard let provider = resolveDefaultProvider(config: config, availableProviders: availableProviders) else {
            logger.warning(
                "ModelRef \"\(candidate, privacy: .public)\" is a bare model name but the default provider is unavailable; skipping"
            )
            return nil
        }
        return ResolvedModel(provider: provider, model: candidate)
    }

    /// "default's provider" for rule 3 (and, indirectly, for a bare-form `llm.models` alias
    /// definition resolved via rule 1): the provider `llm.default` would resolve to, without ever
    /// applying rule 3 to `llm.default` itself (§3.1's "alias 値は再帰的に alias を参照できない" --
    /// this is exactly that one level of non-recursion, made explicit as its own helper).
    private static func resolveDefaultProvider(config: LLMConfig, availableProviders: Set<String>) -> String? {
        if let sentinel = config.defaultProviderName {
            return availableProviders.contains(sentinel) ? sentinel : nil
        }

        let aliasName = config.defaultAlias
        guard !aliasName.isEmpty else { return nil }

        if let definition = config.models[aliasName] {
            guard let provider = definition.provider, availableProviders.contains(provider) else { return nil }
            return provider
        }

        if let slashIndex = aliasName.firstIndex(of: "/") {
            let providerPart = String(aliasName[aliasName.startIndex..<slashIndex])
            return availableProviders.contains(providerPart) ? providerPart : nil
        }

        return nil
    }
}
