import Foundation
import OSLog

// MARK: - LLMProviderKind

/// `llm.provider` (`docs/design/14-llm-provider.md` section 3). Selects which `LLMBackend`
/// `LLMClient.shared` is built from (`LLMClient.makeBackend(from:)`).
enum LLMProviderKind: String, Codable, Equatable, Sendable {
    case claudeCLI = "claude-cli"
    case openai
}

// MARK: - ClaudeBackendConfig

/// `llm.claude:` section (`docs/design/14-llm-provider.md` section 3). Wires
/// `ClaudeCLIProcessRunner(claudePathOverride:)`'s already-existing parameter
/// (`Kikimi/LLM/LLMProcessRunner.swift`'s "12 章 §3.1 step 1 の実装化" note).
struct ClaudeBackendConfig: Codable, Equatable, Sendable {
    /// Explicit `claude` executable path. `nil`/absent falls through to `ClaudeCLIProcessRunner`'s
    /// own `which`/known-candidate-path resolution (`docs/design/12-llm-client.md` section 3.1).
    var cliPath: String?

    enum CodingKeys: String, CodingKey {
        case cliPath = "cli_path"
    }

    static let `default` = ClaudeBackendConfig(cliPath: nil)

    init(cliPath: String?) {
        self.cliPath = cliPath
    }

    /// Custom decoder mirroring `DiarizationConfig.init(from:)`: a partial (or absent) `llm.claude:`
    /// section fills the missing field from `.default` instead of failing the whole `config.yaml`
    /// decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cliPath = try container.decodeIfPresent(String.self, forKey: .cliPath) ?? Self.default.cliPath
    }
}

// MARK: - OpenAIBackendConfig

/// `llm.openai:` section (`docs/design/14-llm-provider.md` section 3). Drives `OpenAIChatBackend`'s
/// request assembly (URL, auth header, model override, API key resolution).
struct OpenAIBackendConfig: Codable, Equatable, Sendable {
    /// Required for the `openai` provider to function; empty is a valid (if unusable) default so a
    /// partial section still decodes. Examples (section 3): OpenAI `https://api.openai.com/v1`,
    /// Azure v1 `https://<res>.openai.azure.com/openai/v1`, Azure legacy
    /// `https://<res>.openai.azure.com/openai/deployments/<dep>`.
    var baseURL: String
    /// Direct API key. Config-file-plaintext is accepted (kikimi.md 12 章: local personal app).
    var apiKey: String
    /// Environment variable name to read the API key from when `apiKey` is empty (section 3's "API
    /// キー解決順").
    var apiKeyEnv: String
    /// Non-empty appends `?api-version=<value>` (Azure legacy form, section 4.1).
    var apiVersion: String
    /// Non-empty overrides every call's `model` (Azure deployment-name workflow, section 3's "モデル解決").
    var model: String
    /// `"bearer"` | `"api-key"` | `""` (derived from `apiVersion`'s presence when empty, section 3).
    var authHeader: String
    /// Non-empty sends `reasoning_effort` on every call (gpt-5-series reasoning models' `"none"`/
    /// `"minimal"`/.../`"xhigh"`); empty omits the field entirely, since non-reasoning models reject it.
    var reasoningEffort: String

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case apiKey = "api_key"
        case apiKeyEnv = "api_key_env"
        case apiVersion = "api_version"
        case model
        case authHeader = "auth_header"
        case reasoningEffort = "reasoning_effort"
    }

    static let `default` = OpenAIBackendConfig(baseURL: "", apiKey: "", apiKeyEnv: "", apiVersion: "", model: "", authHeader: "", reasoningEffort: "")

    init(baseURL: String, apiKey: String, apiKeyEnv: String, apiVersion: String, model: String, authHeader: String, reasoningEffort: String = "") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiKeyEnv = apiKeyEnv
        self.apiVersion = apiVersion
        self.model = model
        self.authHeader = authHeader
        self.reasoningEffort = reasoningEffort
    }

    /// Custom decoder mirroring `DiarizationConfig.init(from:)`: a partial (or absent) `llm.openai:`
    /// section fills every missing field from `.default` instead of failing the whole `config.yaml`
    /// decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.default.baseURL
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? Self.default.apiKey
        apiKeyEnv = try container.decodeIfPresent(String.self, forKey: .apiKeyEnv) ?? Self.default.apiKeyEnv
        apiVersion = try container.decodeIfPresent(String.self, forKey: .apiVersion) ?? Self.default.apiVersion
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.default.model
        authHeader = try container.decodeIfPresent(String.self, forKey: .authHeader) ?? Self.default.authHeader
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? Self.default.reasoningEffort
    }
}

// MARK: - LLMConfig

/// `llm:` section of `config.yaml` (`docs/design/14-llm-provider.md` section 3). Selects and
/// configures the `LLMBackend` `LLMClient.shared` is built from.
struct LLMConfig: Codable, Equatable, Sendable {
    var provider: LLMProviderKind
    var claude: ClaudeBackendConfig
    var openai: OpenAIBackendConfig
    /// `llm.pricing` (`docs/design/16-llm-usage-stats.md` section 4): per-model USD/1M-token
    /// overrides, keyed by model id prefix. Takes priority over `LLMPricing.builtIn` when both
    /// tables have a matching prefix (`LLMPricing.resolve(model:configPricing:)`'s job, not this
    /// struct's) -- primarily for the Azure OpenAI deployment-name workflow, where the model id
    /// itself carries no pricing information at all.
    var pricing: [String: LLMModelPricing]

    enum CodingKeys: String, CodingKey {
        case provider
        case claude
        case openai
        case pricing
    }

    /// `provider: claude-cli` (back-compat default, section 3). `pricing` defaults to empty --
    /// `LLMPricing.builtIn` alone covers every Anthropic model kikimi.md 12 章 documents.
    static let `default` = LLMConfig(provider: .claudeCLI, claude: .default, openai: .default, pricing: [:])

    init(
        provider: LLMProviderKind,
        claude: ClaudeBackendConfig,
        openai: OpenAIBackendConfig,
        pricing: [String: LLMModelPricing] = [:]
    ) {
        self.provider = provider
        self.claude = claude
        self.openai = openai
        self.pricing = pricing
    }

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "LLMConfig")

    /// Custom decoder mirroring `DiarizationConfig.init(from:)`: a partial (or absent) `llm:` section
    /// fills every missing field from `.default`. An unrecognized `provider` value is logged as a
    /// warning and falls back to `.claudeCLI` (section 3's "未知 provider は warning + claude-cli
    /// フォールバック") rather than failing the whole `config.yaml` decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let providerRaw = try container.decodeIfPresent(String.self, forKey: .provider) {
            if let resolved = LLMProviderKind(rawValue: providerRaw) {
                provider = resolved
            } else {
                Self.logger.warning(
                    "llm.provider=\(providerRaw, privacy: .public) is unknown; falling back to \(LLMProviderKind.claudeCLI.rawValue, privacy: .public)"
                )
                provider = .claudeCLI
            }
        } else {
            provider = Self.default.provider
        }

        claude = try container.decodeIfPresent(ClaudeBackendConfig.self, forKey: .claude) ?? .default
        openai = try container.decodeIfPresent(OpenAIBackendConfig.self, forKey: .openai) ?? .default
        pricing = try container.decodeIfPresent([String: LLMModelPricing].self, forKey: .pricing) ?? [:]
    }
}

// MARK: - SttConfig

/// `stt:` section of `config.yaml` (`docs/design/11-streaming-stt.md` section 3.9 / kikimi.md 12 章).
/// Feeds `SttEngineConfig.language`/`chunkMs`/`segmentIdleTimeout`/`maxSegmentCharacters`
/// (`Kikimi/Stt/SttTypes.swift`) via `MeetingWorkspaceViewModel.defaultTranscriptPipelineFactory`
/// (`MeetingWorkspaceViewModel+Factories.swift`), which constructs a fresh `SttEngineConfig` per
/// recording segment from this section rather than `SttEngineConfig`'s own struct-literal defaults.
struct SttConfig: Codable, Equatable, Sendable {
    /// Engine selector, currently a fixed single value (design section 3.9: "将来のエンジン差し替え口として
    /// 名前を残す"). Any value other than `"nemotron-streaming"` is logged as a warning and replaced
    /// with the default rather than retained -- there is no alternate engine implementation to select
    /// yet, so an unrecognized value can only be a typo.
    var engine: String
    /// FluidAudio language conditioning code (e.g. `"ja-JP"`), or `"auto"` (design section 3.9).
    /// Not validated against a fixed set here -- resolution to FluidAudio's locale dictionary is left
    /// to `StreamingNemotronMultilingualAsrManager.setLanguage(_:)` (`SttTypes.swift`'s doc comment on
    /// `SttEngineConfig.language`).
    var language: String
    /// Streaming chunk tier in milliseconds. Must be one of `SttEngineConfig.validChunkMsTiers`
    /// (560/1120/2240/4480); any other value is logged as a warning and falls back to the default
    /// (design section 3.9's "未知の値は `.warning` ログの上で既定値にフォールバック").
    var chunkMs: Int
    /// Seconds of no new text growth after which a pending segment is force-confirmed (design section
    /// 3.3 route 2). Must be positive; any value `<= 0` is logged as a warning and falls back to the
    /// default, mirroring `chunkMs`'s validation style.
    var segmentIdleTimeout: TimeInterval
    /// Character count above which a pending segment is force-confirmed regardless of punctuation
    /// (design section 3.3 route 3, a runaway guard). Must be at least 1; any value `< 1` is logged as
    /// a warning and falls back to the default.
    var maxSegmentCharacters: Int
    /// `docs/design/33-meeting-two-pass-decode.md` §4/MT10: whether a confirmed segment's `text` is
    /// replaced by a batch re-decode of its audio window (Parakeet TDT), rather than kept as the
    /// streaming (Nemotron 3.5 Streaming) confirmation. `true` by default -- same rationale as
    /// `DictationConfig.twoPassDecode` (design 31 TP9): the motivating defect is a silent word drop
    /// the user cannot notice, so an opt-in default would leave it unfixed. `false` restores the
    /// pre-design-33 streaming-only confirmation path unchanged (MT9/MT10).
    var twoPassDecode: Bool

    enum CodingKeys: String, CodingKey {
        case engine
        case language
        case chunkMs = "chunk_ms"
        case segmentIdleTimeout = "segment_idle_timeout"
        case maxSegmentCharacters = "max_segment_characters"
        case twoPassDecode = "two_pass_decode"
    }

    /// The exact defaults documented in design section 3.9's `config.yaml` sample. `segmentIdleTimeout`/
    /// `maxSegmentCharacters` intentionally match `SttEngineConfig`'s own struct-literal defaults
    /// (`Kikimi/Stt/SttTypes.swift`) so the two never drift out of sync.
    static let `default` = SttConfig(
        engine: "nemotron-streaming",
        language: "ja-JP",
        chunkMs: 2_240,
        segmentIdleTimeout: 2.0,
        maxSegmentCharacters: 120,
        twoPassDecode: true
    )

    init(
        engine: String,
        language: String,
        chunkMs: Int,
        segmentIdleTimeout: TimeInterval,
        maxSegmentCharacters: Int,
        twoPassDecode: Bool = true
    ) {
        self.engine = engine
        self.language = language
        self.chunkMs = chunkMs
        self.segmentIdleTimeout = segmentIdleTimeout
        self.maxSegmentCharacters = maxSegmentCharacters
        self.twoPassDecode = twoPassDecode
    }

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SttConfig")

    /// Custom decoder mirroring `DiarizationConfig.init(from:)`: a partial (or absent) `stt:` section
    /// fills every missing field from `.default` instead of failing the whole `config.yaml` decode.
    /// `engine`/`chunk_ms` are additionally validated with a `.warning` log + default fallback
    /// (design section 3.9), and an empty `language` falls back to the default `"ja-JP"` rather than
    /// being passed through as an empty string.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedEngine = try container.decodeIfPresent(String.self, forKey: .engine) ?? Self.default.engine
        if decodedEngine != Self.default.engine {
            Self.logger.warning(
                "stt.engine=\(decodedEngine, privacy: .public) is unknown; falling back to \(Self.default.engine, privacy: .public)"
            )
            engine = Self.default.engine
        } else {
            engine = decodedEngine
        }

        let decodedLanguage = try container.decodeIfPresent(String.self, forKey: .language) ?? Self.default.language
        if decodedLanguage.isEmpty {
            Self.logger.warning(
                "stt.language is empty; falling back to \(Self.default.language, privacy: .public)"
            )
            language = Self.default.language
        } else {
            language = decodedLanguage
        }

        let decodedChunkMs = try container.decodeIfPresent(Int.self, forKey: .chunkMs) ?? Self.default.chunkMs
        if !SttEngineConfig.validChunkMsTiers.contains(decodedChunkMs) {
            Self.logger.warning(
                """
                stt.chunk_ms=\(decodedChunkMs, privacy: .public) is not one of \
                \(SttEngineConfig.validChunkMsTiers.sorted(), privacy: .public); falling back to \
                \(Self.default.chunkMs, privacy: .public)
                """
            )
            chunkMs = Self.default.chunkMs
        } else {
            chunkMs = decodedChunkMs
        }

        let decodedSegmentIdleTimeout = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .segmentIdleTimeout
        ) ?? Self.default.segmentIdleTimeout
        if decodedSegmentIdleTimeout <= 0 {
            Self.logger.warning(
                """
                stt.segment_idle_timeout=\(decodedSegmentIdleTimeout, privacy: .public) must be positive; \
                falling back to \(Self.default.segmentIdleTimeout, privacy: .public)
                """
            )
            segmentIdleTimeout = Self.default.segmentIdleTimeout
        } else {
            segmentIdleTimeout = decodedSegmentIdleTimeout
        }

        let decodedMaxSegmentCharacters = try container.decodeIfPresent(
            Int.self,
            forKey: .maxSegmentCharacters
        ) ?? Self.default.maxSegmentCharacters
        if decodedMaxSegmentCharacters < 1 {
            Self.logger.warning(
                """
                stt.max_segment_characters=\(decodedMaxSegmentCharacters, privacy: .public) must be at least 1; \
                falling back to \(Self.default.maxSegmentCharacters, privacy: .public)
                """
            )
            maxSegmentCharacters = Self.default.maxSegmentCharacters
        } else {
            maxSegmentCharacters = decodedMaxSegmentCharacters
        }

        twoPassDecode = try container.decodeIfPresent(Bool.self, forKey: .twoPassDecode) ?? Self.default.twoPassDecode
    }
}

// MARK: - WatchersConfig

/// `watchers:` section of `config.yaml` (kikimi.md 12 章 / `docs/design/05-watcher-runner.md`
/// §11). Drives `WatcherLibrary`'s preset directory and `WatcherRunner`'s default model, and
/// `SessionStore`'s default-enabled-watchers file for new sessions (§3.1). Path fields are
/// `~`-rooted strings, resolved via `FileManager.expandingTildePath(_:)` (§3.2) by whoever consumes
/// them -- this struct itself only stores the raw config-file string, mirroring how `ClaudeBackend
/// Config.cliPath` is left unexpanded here too.
struct WatchersConfig: Codable, Equatable, Sendable {
    /// `watchers.presets_dir`.
    var presetsDir: String
    /// `watchers.default_enabled_file`.
    var defaultEnabledFile: String
    /// `watchers.default_model`.
    var defaultModel: String

    enum CodingKeys: String, CodingKey {
        case presetsDir = "presets_dir"
        case defaultEnabledFile = "default_enabled_file"
        case defaultModel = "default_model"
    }

    /// The exact defaults documented in kikimi.md 12 章's `config.yaml` sample.
    static let `default` = WatchersConfig(
        presetsDir: "~/.config/kikimi/watchers/",
        defaultEnabledFile: "~/.config/kikimi/default_watchers.yaml",
        defaultModel: "claude-haiku-4-5-20251001"
    )

    init(presetsDir: String, defaultEnabledFile: String, defaultModel: String) {
        self.presetsDir = presetsDir
        self.defaultEnabledFile = defaultEnabledFile
        self.defaultModel = defaultModel
    }

    /// Custom decoder mirroring `DiarizationConfig.init(from:)`: a partial (or absent) `watchers:`
    /// section fills every missing field from `.default` instead of failing the whole `config.yaml`
    /// decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presetsDir = try container.decodeIfPresent(String.self, forKey: .presetsDir) ?? Self.default.presetsDir
        defaultEnabledFile = try container.decodeIfPresent(String.self, forKey: .defaultEnabledFile) ?? Self.default.defaultEnabledFile
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? Self.default.defaultModel
    }
}

// MARK: - KikimiConfigData

/// The full contents of `~/.config/kikimi/config.yaml` (kikimi.md 12 章). Only `diarization`,
/// `refinement`, `llm`, `stt`, `summary`, `watchers`, `export`, `audio`, `dictation`, `defaults`,
/// `profiles`, and `glossary` are modeled so far -- see `DiarizationConfig`'s, `RefinementConfig`'s,
/// `LLMConfig`'s, `SttConfig`'s, `SummaryConfig`'s (`Kikimi/Summary/SummaryUpdater.swift`),
/// `WatchersConfig`'s, `ExportConfig`'s, `AudioConfig`'s (`Kikimi/Config/AudioConfig.swift`),
/// `DictationConfig`'s (`Kikimi/Config/DictationConfig.swift`), `DefaultsConfig`'s, `ProfilesConfig`'s
/// (`docs/design/41-meeting-profiles.md` §2.4), and `GlossaryEntry`'s
/// (`Kikimi/Config/GlossaryConfig.swift`) doc comments.
///
/// `glossary` is a top-level, feature-independent section (`docs/design/28-glossary.md` §2): it used
/// to live under `dictation.context.glossary` (`docs/design/25-dictation-mode.md` §15/R19), but was
/// promoted out to here once meeting-transcript refinement started consuming it too
/// (`RefinementPromptBuilder.buildSystemPrompt(context:glossaryBlock:dedupSystemLeakSegments:)`), so
/// it no longer makes sense to model it as dictation-specific. `glossaryCategories`
/// (`glossary_categories:`) groups those entries and gives each group its own prompt instruction --
/// see `GlossaryCategory`.
struct KikimiConfigData: Codable, Equatable, Sendable {
    var diarization: DiarizationConfig
    var refinement: RefinementConfig
    var llm: LLMConfig
    var stt: SttConfig
    var summary: SummaryConfig
    var watchers: WatchersConfig
    var export: ExportConfig
    var audio: AudioConfig
    var dictation: DictationConfig
    /// `docs/design/38-session-chat.md` §6: the session chat tab's model/budget/timeout.
    var chat: ChatConfig
    var defaults: DefaultsConfig
    /// `docs/design/41-meeting-profiles.md` §2.4: the meeting profile library's directory reference.
    var profiles: ProfilesConfig
    var glossary: [GlossaryEntry]
    var glossaryCategories: [GlossaryCategory]

    /// Every other field's Swift name already matches its `config.yaml` key verbatim, so this type had
    /// no `CodingKeys` at all until `glossaryCategories` -- the first one needing a snake_case mapping.
    enum CodingKeys: String, CodingKey {
        case diarization, refinement, llm, stt, summary, watchers, export, audio, dictation, chat, defaults, profiles, glossary
        case glossaryCategories = "glossary_categories"
    }

    init(
        diarization: DiarizationConfig = .default,
        refinement: RefinementConfig = .default,
        llm: LLMConfig = .default,
        stt: SttConfig = .default,
        summary: SummaryConfig = .default,
        watchers: WatchersConfig = .default,
        export: ExportConfig = .default,
        audio: AudioConfig = .default,
        dictation: DictationConfig = .default,
        chat: ChatConfig = .default,
        defaults: DefaultsConfig = .default,
        profiles: ProfilesConfig = .default,
        glossary: [GlossaryEntry] = [],
        glossaryCategories: [GlossaryCategory] = []
    ) {
        self.diarization = diarization
        self.refinement = refinement
        self.llm = llm
        self.stt = stt
        self.summary = summary
        self.watchers = watchers
        self.export = export
        self.audio = audio
        self.dictation = dictation
        self.chat = chat
        self.defaults = defaults
        self.profiles = profiles
        self.glossary = glossary
        self.glossaryCategories = glossaryCategories
    }

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "KikimiConfigData")

    /// Custom decoder so a `config.yaml` predating any of these sections (or simply missing a
    /// section's key) still decodes successfully with each section's `.default`, rather than failing
    /// the whole decode and permanently setting `YAMLStore.loadFailed` (mirrors `AppState`'s
    /// `KikimiStateData.init(from:)` leniency for `last_audio_input`, `Kikimi/Config/AppState.swift`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        diarization = try container.decodeIfPresent(DiarizationConfig.self, forKey: .diarization) ?? .default
        refinement = try container.decodeIfPresent(RefinementConfig.self, forKey: .refinement) ?? .default
        llm = try container.decodeIfPresent(LLMConfig.self, forKey: .llm) ?? .default
        stt = try container.decodeIfPresent(SttConfig.self, forKey: .stt) ?? .default
        summary = try container.decodeIfPresent(SummaryConfig.self, forKey: .summary) ?? .default
        watchers = try container.decodeIfPresent(WatchersConfig.self, forKey: .watchers) ?? .default
        export = try container.decodeIfPresent(ExportConfig.self, forKey: .export) ?? .default
        audio = try container.decodeIfPresent(AudioConfig.self, forKey: .audio) ?? .default
        dictation = try container.decodeIfPresent(DictationConfig.self, forKey: .dictation) ?? .default
        chat = try container.decodeIfPresent(ChatConfig.self, forKey: .chat) ?? .default
        defaults = try container.decodeIfPresent(DefaultsConfig.self, forKey: .defaults) ?? .default
        profiles = try container.decodeIfPresent(ProfilesConfig.self, forKey: .profiles) ?? .default

        // Mirrors `DictationContextConfig.init(from:)`'s glossary-array handling (now superseded by
        // this top-level section): a single malformed entry throws for the whole array, so the whole
        // list falls back to empty with a warning rather than failing this entire config.yaml decode.
        do {
            glossary = try container.decodeIfPresent([GlossaryEntry].self, forKey: .glossary) ?? []
        } catch {
            Self.logger.warning(
                "glossary failed to decode (\(String(describing: error), privacy: .public)); falling back to an empty list"
            )
            glossary = []
        }

        do {
            let decoded = try container.decodeIfPresent([GlossaryCategory].self, forKey: .glossaryCategories) ?? []
            glossaryCategories = Self.deduplicatedCategories(decoded)
        } catch {
            Self.logger.warning(
                "glossary_categories failed to decode (\(String(describing: error), privacy: .public)); falling back to an empty list"
            )
            glossaryCategories = []
        }

        // Deliberately no cross-validation of `glossary[].category` against these ids: a dangling
        // reference is preserved verbatim and resolves to "uncategorized" at the point of use, via
        // `GlossaryCategorization` (see `GlossaryEntry.category`'s doc comment).
    }

    /// Drops later categories sharing an earlier one's `id`, keeping the first occurrence so
    /// `GlossaryRenderer`'s section order still follows `glossary_categories:`'s own order.
    ///
    /// Unlike a structurally malformed category (missing `id`/`name`), which fails the whole array, a
    /// duplicate id is a repairable inconsistency reachable only by hand-editing `config.yaml` --
    /// discarding every category over one typo would be a wildly disproportionate response, and the
    /// entries pointing at the surviving id keep working either way.
    private static func deduplicatedCategories(_ categories: [GlossaryCategory]) -> [GlossaryCategory] {
        var seenIds: Set<String> = []
        return categories.filter { category in
            guard seenIds.insert(category.id).inserted else {
                Self.logger.warning(
                    "glossary_categories has a duplicate id=\(category.id, privacy: .public); keeping only the first occurrence"
                )
                return false
            }
            return true
        }
    }
}

// MARK: - AppConfig

/// Reads and writes `~/.config/kikimi/config.yaml` (kikimi.md 12 章). Mirrors `AppState`'s
/// `YAMLStore` subclass shape (`Kikimi/Config/AppState.swift`) exactly, including the DI-friendly
/// designated `init(directory:)` tests use to avoid ever touching the real `~/.config/kikimi`.
///
/// Unlike `AppState.shared` (`state.yaml`, written only by this process's own `WindowManager`),
/// `config.yaml` is expected to be hand-edited by the user (kikimi.md 12 章's sample, XDG-style
/// dotfiles workflow) -- so `watchForChanges: true`, picking up external edits automatically like
/// Chirami's own `AppConfig` (`docs/references/chirami-map.md` 4 章).
///
/// Overrides `YAMLStore.load()` to run `migrateAPIKeyToKeychainIfNeeded()` after every load --
/// both the initial load in `init` and every external-edit reload `watchForChanges: true` triggers
/// (`docs/design/26-settings-ui.md` §3.1) -- rather than calling the migration once from `init`
/// alone, so a hand-edited config.yaml that re-adds a plaintext `llm.openai.api_key` is migrated
/// again on its next reload.
final class AppConfig: YAMLStore<KikimiConfigData> {
    static let shared = AppConfig()
    static let defaultConfigDirectory = FileManager.realHomeDirectory
        .appendingPathComponent(".config/kikimi", isDirectory: true)

    private let credentialStore: CredentialStoring
    private let migrationLogger = Logger(subsystem: "io.github.uphy.Kikimi", category: "AppConfig")

    private convenience init() {
        self.init(directory: Self.defaultConfigDirectory, credentialStore: DefaultCredentialStore.shared)
    }

    /// Designated initializer. Tests must pass a temporary directory so the real
    /// `~/.config/kikimi` is never touched (same DI pattern as `AppState.init(directory:)`), and
    /// should pass an `InMemoryCredentialStore()` so the real Keychain is never touched either
    /// (`docs/design/26-settings-ui.md` §3.1/§6).
    init(directory: URL, credentialStore: CredentialStoring = DefaultCredentialStore.shared) {
        self.credentialStore = credentialStore
        super.init(directory: directory, fileName: "config.yaml", label: "Config",
                    defaultValue: KikimiConfigData(), watchForChanges: true)
    }

    /// `credentialStore` is assigned before `super.init(...)` is called (Swift's two-phase init
    /// rule), so it is already valid by the time `super.init` internally calls `self.load()` --
    /// meaning this override's migration runs on the very first load, not just later reloads.
    override func load() {
        super.load()
        migrateAPIKeyToKeychainIfNeeded()
    }

    /// Runs once per `load()` (both the initial load and every external-edit reload via
    /// `watchForChanges`). Idempotent: if `llm.openai.api_key` is already empty, this is a no-op.
    /// A hand-edited config.yaml that re-adds a plaintext key (e.g. pasted back in by the user) is
    /// migrated again on the next reload -- this is intentional, not a bug: plaintext-on-disk is the
    /// state we always want to close as soon as it's observed (`docs/design/26-settings-ui.md` §3.1).
    private func migrateAPIKeyToKeychainIfNeeded() {
        let plaintext = data.llm.openai.apiKey
        guard !plaintext.isEmpty else { return }
        do {
            try credentialStore.write(plaintext, account: CredentialAccount.openAIAPIKey)
            update { $0.llm.openai.apiKey = "" }
        } catch {
            migrationLogger.error(
                "Failed to migrate llm.openai.api_key to Keychain; leaving config.yaml value in place: \(error, privacy: .public)"
            )
            // apiKey stays non-empty in memory and on disk; OpenAIChatBackend's resolution order
            // (§3.2) still finds it via the plaintext fallback, and migration retries on next load().
        }
    }
}
