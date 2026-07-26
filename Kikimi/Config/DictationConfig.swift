import Foundation
import OSLog

// MARK: - DictationInsertMethod

/// `dictation.insert_method` (`docs/design/25-dictation-mode.md` R6/§9). Deliberately only two
/// cases -- no `auto`: IME interaction depends on the input source's state, not the destination
/// app, so there is nothing meaningful to switch on at runtime (R6's rationale).
enum DictationInsertMethod: String, Codable, Equatable, Sendable {
    /// Stashes the pasteboard, writes the text, posts a synthesized `⌘V`, then restores the
    /// pasteboard after a short delay. The default (R6): Japanese IME interaction with the
    /// unicode method below is unverified in this environment, so this is the safe choice.
    case pasteboard
    /// `CGEvent` unicode direct-type. Never touches the pasteboard, but its interaction with a
    /// Japanese IME's in-progress composition is unverified (`docs/design/25-dictation-mode.md`
    /// §7's known gap) -- select this explicitly only once that has been confirmed by hand.
    case unicode
}

// MARK: - DictationAppContext

/// A single `dictation.context.apps[]` entry (`docs/design/25-dictation-mode.md` §14.2/R12): an
/// append-only context snippet applied only when the hotkey's `keyDown`-time frontmost app matches
/// `bundleID` exactly (R14 -- no wildcard/parent-bundle matching).
struct DictationAppContext: Codable, Equatable, Sendable {
    var bundleID: String
    var context: String

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case context
    }
}

// MARK: - DictationContextConfig

/// `dictation.context` section (`docs/design/25-dictation-mode.md` §14.2/R12): the "global" context
/// applied to every dictation call, plus a list of per-app additions. Resolved at call time by
/// `DictationContextResolver.resolve(bundleID:config:glossary:)` -- this type only models the config
/// data, it never decides what to inject.
///
/// Note: `glossary` (§15/R19) used to live here as `dictation.context.glossary`, but was promoted to
/// a top-level, feature-independent `glossary:` section (`KikimiConfigData.glossary`,
/// `docs/design/28-glossary.md` §2) once meeting-transcript refinement started using it too -- it is
/// no longer specific to dictation. `init(from:)` below simply lets a lingering
/// `dictation.context.glossary` key in an old `config.yaml` decode without error (unrecognized keys
/// are ignored, not migrated); see that design doc's §2 for the back-compat rationale.
struct DictationContextConfig: Codable, Equatable, Sendable {
    /// Applied to every dictation refinement call regardless of the focused app (R12). Any string is
    /// accepted, including empty (R17's escape hatch for a user who wants no injected context at
    /// all) -- this field is deliberately not validated.
    var global: String
    /// Per-app additions, matched by exact bundle identifier (R14). Append-only in spirit: the
    /// resolver never lets an app entry replace or suppress `global`.
    var apps: [DictationAppContext]

    enum CodingKeys: String, CodingKey {
        case global
        case apps
    }

    /// R17: `global`'s default is the filler-removal/punctuation/grammatical-gap-filling rule body
    /// that used to be hardcoded into `DictationRefiner.systemPrompt`, promoted here so it round-trips
    /// through `config.yaml` and is directly editable from Settings (§14.5) instead of being a hidden
    /// literal.
    static let `default` = DictationContextConfig(
        global: """
        【前提】
        - 入力は音声認識（ASR）の書き起こし結果である
        - 漢字変換・カタカナ表記・アルファベット表記は認識エンジンによる推測に過ぎず、誤っていることがある
        - 正しいのは「読み（発音）」であり、表記は前後の文脈から最も自然なものに再決定してよい

        【整形ルール】
        - フィラー（「えーと」「あの」など）を除去する
        - 句読点を補い、自然な日本語にする
        - 表記の置換は「読みが同じ・近い範囲」に限り自由に行ってよい。読みから離れた書き換えや新しい情報の追加は禁止する（ただし、アプリ向けの追加指示がある場合はそちらを優先する）
        - 同音・近音の誤変換は積極的に正しい表記へ修正する（例:「駅存」→「既存」、「支持」→「指示」）
        - 技術用語は文脈から判断できる場合、正式な表記に直す（例:「エルエルエム」→「LLM」、「ピーディエフ」→「PDF」）
        - 良い例:「駅存の実装」→「既存の実装」（読みが近く、文脈上「既存」が妥当）。悪い例:「ピーディf」→「prデータ」（読みが一致しない、ただの推測でしてはいけない）
        - 音声認識により助詞や単語が部分的に欠落し、文法的に不自然な箇所がある場合は、前後の文脈から自然に補って文法的に整った文章にする（例:「明日 会議 資料」→「明日の会議の資料」）
        - 欠落補完はあくまで文法的な穴埋めに留め、話者が言っていない新しい情報や結論を創作しない
        - 確信が持てない箇所（表記の候補に自信が持てない、または欠落補完で文意が推測できない場合など）は元の表現を残す
        """,
        apps: []
    )

    init(global: String, apps: [DictationAppContext]) {
        self.global = global
        self.apps = apps
    }

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "DictationContextConfig")

    /// Custom decoder mirroring `DictationConfig.init(from:)`'s "壊れていたら warning + 既定値" style.
    /// `global` accepts any string verbatim (no validation, R12/§14.2). `apps` is all-or-nothing: if
    /// decoding the array throws at all (a single malformed entry is enough, since
    /// `[DictationAppContext]` decodes as one JSON/YAML array), the *whole* array falls back to empty
    /// rather than attempting a per-entry partial recovery -- §14.2's rationale is that this list is
    /// short and Settings-UI-authored, not hand-edited, so the extra partial-recovery complexity is
    /// not worth it. A `glossary` key present in this container (from an old `config.yaml` predating
    /// its promotion to the top level, see this type's doc comment) is simply not looked up here and
    /// is therefore ignored, not an error.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        global = try container.decodeIfPresent(String.self, forKey: .global) ?? Self.default.global

        do {
            apps = try container.decodeIfPresent([DictationAppContext].self, forKey: .apps) ?? Self.default.apps
        } catch {
            Self.logger.warning(
                "dictation.context.apps failed to decode (\(String(describing: error), privacy: .public)); falling back to an empty list"
            )
            apps = []
        }
    }
}

// MARK: - DictationHistoryConfig

/// `dictation.history` section (`docs/design/29-dictation-history.md` §7.1, DH1/DH7): whether each
/// utterance's audio/text/refinement result is persisted to
/// `~/.local/state/kikimi/dictation/history/`, and how many entries are retained.
struct DictationHistoryConfig: Codable, Equatable, Sendable {
    /// DH1. `true` by default: history is opt-out, not opt-in, because the feature's whole
    /// motivation is "refine silently failing went unnoticed" -- an opt-in default would let the
    /// same failure mode recur unnoticed. Setting this to `false` restores the fully stateless
    /// behavior dictation had before this feature existed.
    var enabled: Bool
    /// DH7. Maximum number of retained entries; whenever a new entry is finalized, the oldest
    /// entries beyond this count are pruned. Must be `>= 1` -- the pruning pure function
    /// (`docs/design/29-dictation-history.md` §5.2) assumes this invariant, so `init(from:)` below
    /// never lets an invalid value reach it.
    var maxEntries: Int

    enum CodingKeys: String, CodingKey {
        case enabled
        case maxEntries = "max_entries"
    }

    /// The defaults documented in `docs/design/29-dictation-history.md` §7.1's `config.yaml` sample.
    static let `default` = DictationHistoryConfig(enabled: true, maxEntries: 100)

    init(enabled: Bool, maxEntries: Int) {
        self.enabled = enabled
        self.maxEntries = maxEntries
    }

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "DictationHistoryConfig")

    /// Mirrors `DictationConfig.init(from:)`'s "欠落時は `.default` フォールバック + 不正値は warning
    /// ログ + 既定値フォールバック" style (`docs/design/29-dictation-history.md` §7.1): a missing
    /// `max_entries` falls back to `.default.maxEntries`, and an invalid one -- either `< 1` or not
    /// decodable as an `Int` at all (e.g. a string) -- is logged as a warning and also falls back to
    /// `.default.maxEntries`, rather than being clamped. That section is explicit that normalization
    /// responsibility belongs entirely to config decoding, not to the pruning logic downstream.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self.default.enabled

        do {
            if let decodedMaxEntries = try container.decodeIfPresent(Int.self, forKey: .maxEntries) {
                if decodedMaxEntries < 1 {
                    Self.logger.warning(
                        "dictation.history.max_entries=\(decodedMaxEntries, privacy: .public) must be >= 1; falling back to \(Self.default.maxEntries, privacy: .public)"
                    )
                    maxEntries = Self.default.maxEntries
                } else {
                    maxEntries = decodedMaxEntries
                }
            } else {
                maxEntries = Self.default.maxEntries
            }
        } catch {
            Self.logger.warning(
                "dictation.history.max_entries failed to decode (\(String(describing: error), privacy: .public)); falling back to \(Self.default.maxEntries, privacy: .public)"
            )
            maxEntries = Self.default.maxEntries
        }
    }
}

// MARK: - DictationConfig

/// `dictation:` section of `config.yaml` (`docs/design/25-dictation-mode.md` R10/§9). Drives
/// `DictationController`'s enablement, `DictationInserter`'s insertion method, and
/// `DictationTranscriber`'s mic device/language selection.
///
/// The hotkey itself is **not** modeled here (R7/§5): its source of truth is
/// `KeyboardShortcuts`' own `UserDefaults` storage, a deliberate exception to config.yaml being
/// the source of truth for settings (see that section's rationale -- avoiding an echo loop with
/// `AppConfig`'s `watchForChanges: true`, and the hotkey being a machine-local preference).
struct DictationConfig: Codable, Equatable, Sendable {
    /// `false` (default): `DictationController` never warms the STT backend or requests AX/mic
    /// permission (R3/R8). Flipping this on is what triggers the first warm + permission request.
    var enabled: Bool
    /// R6. `.pasteboard` by default -- see `DictationInsertMethod.pasteboard`'s doc comment.
    var insertMethod: DictationInsertMethod
    /// CoreAudio device UID to capture from, or empty for the system default input device (R2,
    /// mirrors `MicrophoneSource.deviceUID`'s own `nil`-means-default contract).
    var micDeviceUID: String
    /// FluidAudio language conditioning code, or empty to fall back to `stt.language` (R3, so
    /// dictation shares the same model tier as the meeting pipeline when left unset).
    var language: String
    /// `docs/design/31-dictation-two-pass-decode.md` TP9: whether the utterance is re-decoded as a
    /// whole by the batch model at key-up, replacing the streaming text as the confirmed raw.
    /// `true` by default -- the feature exists because the streaming model silently drops words,
    /// which an opt-in would leave unfixed for exactly the users it affects. `false` restores the
    /// streaming-only confirmation path (and releases the ~600MB resident batch model).
    var twoPassDecode: Bool
    /// D2 scope: LLM post-processing toggle. Always effectively `false` in D1 (no `DictationRefiner`
    /// exists yet), kept here so `config.yaml` round-trips the full section from day one.
    var refine: Bool
    /// D2 scope: model override for `DictationRefiner`, independent of `refinement.model`/
    /// `summary.model`. Empty falls back to `watchers.default_model` (R9, revised after D2 shipped --
    /// see `DictationRefiner.resolveModel(dictationModel:watchersDefaultModel:)`'s doc comment).
    var model: String
    /// D2 scope: single-shot refinement call timeout in milliseconds. Exceeding it (or any
    /// error/offline condition) falls back to inserting the raw STT text unchanged.
    var refineTimeoutMs: Int
    /// R12/§14: the global + per-app context injected into `DictationRefiner`'s system prompt,
    /// resolved at call time by `DictationContextResolver.resolve(bundleID:config:)`.
    var context: DictationContextConfig
    /// DH1/DH7 (`docs/design/29-dictation-history.md` §7.1): whether per-utterance history is
    /// persisted, and how many entries are retained.
    var history: DictationHistoryConfig

    enum CodingKeys: String, CodingKey {
        case enabled
        case insertMethod = "insert_method"
        case micDeviceUID = "mic_device_uid"
        case language
        case twoPassDecode = "two_pass_decode"
        case refine
        case model
        case refineTimeoutMs = "refine_timeout_ms"
        case context
        case history
    }

    /// The exact defaults documented in `docs/design/25-dictation-mode.md` §9's `config.yaml`
    /// sample.
    static let `default` = DictationConfig(
        enabled: false,
        insertMethod: .pasteboard,
        micDeviceUID: "",
        language: "",
        refine: false,
        model: "",
        refineTimeoutMs: 3_000,
        context: .default,
        history: .default
    )

    init(
        enabled: Bool,
        insertMethod: DictationInsertMethod,
        micDeviceUID: String,
        language: String,
        twoPassDecode: Bool = true,
        refine: Bool,
        model: String,
        refineTimeoutMs: Int,
        context: DictationContextConfig = .default,
        history: DictationHistoryConfig = .default
    ) {
        self.enabled = enabled
        self.insertMethod = insertMethod
        self.micDeviceUID = micDeviceUID
        self.language = language
        self.twoPassDecode = twoPassDecode
        self.refine = refine
        self.model = model
        self.refineTimeoutMs = refineTimeoutMs
        self.context = context
        self.history = history
    }

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "DictationConfig")

    /// Custom decoder mirroring `DiarizationConfig.init(from:)`: a partial (or absent) `dictation:`
    /// section fills every missing field from `.default` instead of failing the whole `config.yaml`
    /// decode. An unrecognized `insert_method` is logged as a warning and falls back to
    /// `.pasteboard` (mirroring `SttConfig`/`LLMConfig`'s "未知の値は warning + 既定値" style), and a
    /// negative `refine_timeout_ms` falls back to the default rather than being retained.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self.default.enabled

        if let insertMethodRaw = try container.decodeIfPresent(String.self, forKey: .insertMethod) {
            if let resolved = DictationInsertMethod(rawValue: insertMethodRaw) {
                insertMethod = resolved
            } else {
                Self.logger.warning(
                    "dictation.insert_method=\(insertMethodRaw, privacy: .public) is unknown; falling back to \(DictationInsertMethod.pasteboard.rawValue, privacy: .public)"
                )
                insertMethod = .pasteboard
            }
        } else {
            insertMethod = Self.default.insertMethod
        }

        micDeviceUID = try container.decodeIfPresent(String.self, forKey: .micDeviceUID) ?? Self.default.micDeviceUID
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? Self.default.language
        twoPassDecode = try container.decodeIfPresent(Bool.self, forKey: .twoPassDecode) ?? Self.default.twoPassDecode
        refine = try container.decodeIfPresent(Bool.self, forKey: .refine) ?? Self.default.refine
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.default.model

        let decodedRefineTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .refineTimeoutMs) ?? Self.default.refineTimeoutMs
        if decodedRefineTimeoutMs < 0 {
            Self.logger.warning(
                "dictation.refine_timeout_ms=\(decodedRefineTimeoutMs, privacy: .public) must be >= 0; falling back to \(Self.default.refineTimeoutMs, privacy: .public)"
            )
            refineTimeoutMs = Self.default.refineTimeoutMs
        } else {
            refineTimeoutMs = decodedRefineTimeoutMs
        }

        context = try container.decodeIfPresent(DictationContextConfig.self, forKey: .context) ?? Self.default.context
        history = try container.decodeIfPresent(DictationHistoryConfig.self, forKey: .history) ?? Self.default.history
    }
}
