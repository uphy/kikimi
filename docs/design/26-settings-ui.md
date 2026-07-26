# 26. Settings UI 全設定化 + Credential Keychain 化 詳細設計

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `kikimi.md` 12 章（config.yaml）、`docs/design/14-llm-provider.md` §3（API キー解決順、
「Keychain への API キー保存（将来検討）」の実装化）、`docs/design/25-dictation-mode.md` §6
（`DictationSettingsTab` — `AppConfig.shared` 直バインドの先例）。
消費側: `Kikimi/Views/SettingsView.swift`、`Kikimi/Config/AppConfig.swift`、`Kikimi/LLM/OpenAIChatBackend.swift`、
`Kikimi/SessionStore/SessionStore.swift`（§4.2 の `defaults` 配線）。

方針決定の経緯: opus subagent によるレビュー（本セッション内）で「暗号化対象は
`llm.openai.api_key` の1フィールドのみに絞る」「Keychain 実体化 + config.yaml は参照を残さない」
「YAML 書き戻しでのコメント消失は許容する（ユーザー合意済み）」の3点が確定している。本設計は
その確定方針の実装仕様。

## 1. 目的とスコープ

`~/.config/kikimi/config.yaml` の設定項目を Settings ウィンドウの UI から編集可能にする。現状
「一般」「モデル」「Watchers」の3タブは `SettingsPlaceholderTab`（「設定機能は準備中です」）のみで、
`AppConfig.shared` への読み書きが未接続。「話者」「入力」タブは既に実装済み（後者が
`AppConfig.shared` 直バインドの先例）。

あわせて `llm.openai.api_key` を macOS Keychain に保存し、config.yaml に平文で永続化しない。

**不変条件（変えないもの）**:

- `~/.config/kikimi/config.yaml` の YAML 形式・パス・XDG 準拠の位置づけは変えない。非機密項目は
  引き続き手編集可能な単一の設定ファイルであり続ける
- `AppConfig` / `KikimiConfigData` の partial デコード + warning フォールバックという既存の流儀
  （`DiarizationConfig.init(from:)` 等）は変更しない。新規 UI はこの上に薄く乗るだけ
- `provider: claude-cli`（既定）の経路は本設計の影響を受けない。Keychain 操作は
  `llm.openai.api_key` にのみ関与する
- `OpenAIBackendConfig.apiKey` フィールド自体は `KikimiConfigData` の型として残す（config.yaml の
  構造・後方互換性を壊さない）。実体の格納場所が変わるだけ

**スコープ外（今回は着手しない）**:

- YAML の手書きコメント・整形（インデント・空行等）のラウンドトリップ保持。`YAMLStore.save()` は
  既に全体再シリアライズで書き戻しており（`DictationSettingsTab` が既にこの挙動を持つ）、UI 経由の
  保存でコメントが消えることをユーザーは許容済み。新規に対処しない
- `storage.session_dir` の UI 編集。既存セッションのパスと直結するため変更のリスクが高い。
  config 手編集のままとする
- `llm.pricing`（モデル別単価オーバーライドの map）。使用頻度が低く UI 化コストに見合わない。
  config 手編集のままとする
- Watcher **preset の .md 本体**（schema/view/prompt）の作成・編集・削除 UI。これは kikimi.md 9 章の
  セッションウィンドウ内「Watchers タブ」管理 UI の担当領域であり、Settings 側は
  `watchers:` セクションの config 値（§4.3）のみを扱う
- 実行中のプロバイダ動的切り替え（`docs/design/14-llm-provider.md` §7 と同じ制約を維持。反映は
  アプリ再起動後）
- config.yaml 以外の secure storage 汎用化（今回は `llm.openai.api_key` 専用の最小実装）

## 2. Credential Store

新規ファイル `Kikimi/Config/CredentialStore.swift`。

> **注**: 保管先はその後 Keychain から Secure Enclave 暗号化ファイルへ移行した。
> 経緯・現行の構成は [`35-secure-enclave-credentials.md`](35-secure-enclave-credentials.md) を正とする。
> 本節の protocol seam（`CredentialStoring` / `InMemoryCredentialStore` / `CredentialAccount`）は変わらない。

```swift
/// Abstraction over a single-value secure credential store, keyed by an opaque account string.
/// Exists so `AppConfig`/UI code never touches the storage backend directly and so tests can
/// inject an in-memory fake (mirrors `HTTPTransporting`/`LLMProcessRunner`'s protocol-seam pattern).
protocol CredentialStoring: Sendable {
    func read(account: String) -> String?
    /// Writes (or overwrites) the value for `account`. Empty string is a valid write (clears the
    /// stored secret while leaving the entry present with an empty value) — callers that
    /// want to remove the entry entirely use `delete(account:)` instead.
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
}

enum CredentialStoreError: Error {
    case unhandledStatus(OSStatus)
    case invalidEncoding
    case malformedCiphertext
}

/// Production implementation. Ciphertexts under `~/.local/state/kikimi/credentials/`, encrypted with
/// a Secure Enclave P-256 key (design 35). `DefaultCredentialStore.shared` composes it and falls
/// back to `KeychainCredentialStore` where the Secure Enclave is unavailable.
final class EncryptedFileCredentialStore: CredentialStoring { /* design 35 §3 */ }

/// Legacy store, kept as the migration source and the Secure Enclave fallback (design 35 §3.4/§3.5).
/// Service is fixed to the app's bundle id so items are namespaced away from any other app's
/// Keychain entries.
final class KeychainCredentialStore: CredentialStoring {
    static let shared = KeychainCredentialStore()
    private let service = "io.github.uphy.Kikimi"

    func read(account: String) -> String? { /* SecItemCopyMatching */ }
    func write(_ value: String, account: String) throws { /* SecItemAdd, or SecItemUpdate on duplicate */ }
    func delete(account: String) throws { /* SecItemDelete; errSecItemNotFound is not an error */ }
}

/// Test double: an in-memory dictionary, no Keychain and no Secure Enclave access. Used by every test
/// that touches `AppConfig`'s API-key migration/resolution so no real credential storage is written
/// to during `swift test` (mirrors `AppConfig.init(directory:)`'s existing temp-directory DI pattern).
final class InMemoryCredentialStore: CredentialStoring {
    private var storage: [String: String] = [:]
    // read/write/delete operate on `storage`, thread-safety via a lock (Sendable requirement)
}

enum CredentialAccount {
    static let openAIAPIKey = "llm.openai.api_key"
}
```

- `account` 文字列は config.yaml のキーパスをそのまま使う（`"llm.openai.api_key"`）。将来 credential
  が増えても命名が衝突しない
- `write`/`delete` の失敗（`errSecAuthFailed` 等、実運用ではほぼ発生しない）は呼び出し側で
  warning ログ + 呼び出し元の状態を変更しない（config.yaml 側の値は変更前のまま残る＝次回起動時に
  再度マイグレーションを試みられる、§3 参照）

## 3. config.yaml と Keychain の統合

### 3.1 マイグレーション（起動時・自動・後方互換）

`AppConfig` に `credentialStore: CredentialStoring` を注入可能にする（デフォルト
`KeychainCredentialStore.shared`、テストは `InMemoryCredentialStore`）。

```swift
final class AppConfig: YAMLStore<KikimiConfigData> {
    static let shared = AppConfig()
    private let credentialStore: CredentialStoring

    private convenience init() {
        self.init(directory: Self.defaultConfigDirectory, credentialStore: KeychainCredentialStore.shared)
    }

    init(directory: URL, credentialStore: CredentialStoring = KeychainCredentialStore.shared) {
        self.credentialStore = credentialStore
        super.init(directory: directory, fileName: "config.yaml", label: "Config",
                    defaultValue: KikimiConfigData(), watchForChanges: true)
        migrateAPIKeyToKeychainIfNeeded()
    }

    /// Runs once per `load()` (both the initial load and every external-edit reload via
    /// `watchForChanges`). Idempotent: if `llm.openai.api_key` is already empty, this is a no-op.
    /// A hand-edited config.yaml that re-adds a plaintext key (e.g. pasted back in by the user) is
    /// migrated again on the next reload — this is intentional, not a bug: plaintext-on-disk is the
    /// state we always want to close as soon as it's observed.
    private func migrateAPIKeyToKeychainIfNeeded() {
        let plaintext = data.llm.openai.apiKey
        guard !plaintext.isEmpty else { return }
        do {
            try credentialStore.write(plaintext, account: CredentialAccount.openAIAPIKey)
            update { $0.llm.openai.apiKey = "" }
        } catch {
            logger.error("Failed to migrate llm.openai.api_key to Keychain; leaving config.yaml value in place: \(error)")
            // apiKey stays non-empty in memory and on disk; LLMClient's resolution order (§3.2)
            // still finds it via the plaintext fallback, and migration retries on next load().
        }
    }
}
```

- `FileWatcher`（`watchForChanges: true`）経由の外部編集リロードでも `load()` 後にこのフックが
  走る設計にする（`YAMLStore.load()` 自体は変更せず、`AppConfig` が `load()` をオーバーライドして
  `super.load()` の後にマイグレーションを呼ぶ、または `load()` 呼び出し箇所を `AppConfig` 側で
  ラップする）
- `update { $0.llm.openai.apiKey = "" }` は `YAMLStore.save()` を呼ぶので、この時点で config.yaml の
  当該行は空文字列に書き戻される（＝ 3.1 の目的である「平文を disk に残さない」が起動直後に成立する）

### 3.2 API キー解決順（`docs/design/14-llm-provider.md` §3 の改訂）

`14-llm-provider.md` の以下の記述を更新する:
- §1「スコープ外」の "Keychain への API キー保存（将来検討）" の行を削除（今回で着手済みに変わる）
- §3 の「API キー解決順」箇条書きを以下に置き換える

```
1. Keychain（CredentialAccount.openAIAPIKey）の値（非空なら採用）
2. config.yaml の `llm.openai.api_key`（後方互換フォールバック。§3.1 のマイグレーションが正常なら
   常に空のはずだが、マイグレーション失敗時・手編集直後のタイミング等で非空になり得る）
3. `api_key_env` の環境変数（LSUIElement 起動ではユーザーシェルの環境変数を継承しない点は従来注記のまま）
4. すべて空なら `LLMClientError.missingAPIKey`
```

**キャッシュ場所とタイミング（review 指摘の反映: 既存コードとの矛盾を解消する）**

既存コード `OpenAIChatBackend.complete(_:)`（`Kikimi/LLM/OpenAIChatBackend.swift:54-56`）は
`resolveAPIKey` を `complete()` の**呼び出しのたび**（＝ refinement バッチ・summary 更新・Watcher
実行のたび）に呼んでいる。前段落の不変条件（「Keychain read はプロセス起動時に1回だけ」）を成立させる
には、呼び出し箇所を **`OpenAIChatBackend.init` 側へ移し、解決結果をインスタンスにキャッシュする**
構造変更が必要（design のこれまでの版はこの呼び出し箇所の移動に触れていなかった）。

`LLMClient.makeBackend(from:)`（`Kikimi/LLM/LLMClient.swift:41-48`）は `static func makeBackend(from
config: LLMConfig) -> LLMBackend`という**非 throwing** の factory で、`LLMClient.shared` の
`static let` 初期化式から直接呼ばれる（同ファイル 20 行目）。この経路には「構築時に
`LLMClientError.missingAPIKey` を投げる」余地が存在しない。したがって解決関数は **`throws` ではなく
`Optional` を返す**形に変え、`nil`（＝どの優先順位でも解決できなかった）というキャッシュ結果を
`complete(_:)` 呼び出し時に判定して初めて `LLMClientError.missingAPIKey` を投げる、という2段構えにする:

```swift
struct OpenAIChatBackend: LLMBackend {
    private let config: OpenAIBackendConfig
    private let transport: HTTPTransporting
    /// Resolved once in `init` (this invariant's whole point); `nil` means no key resolved anywhere
    /// in the precedence chain below. `complete(_:)` throws `.missingAPIKey` off this cached `nil`
    /// without re-touching Keychain/env on every call.
    private let resolvedAPIKey: String?

    init(
        config: OpenAIBackendConfig,
        transport: HTTPTransporting = URLSessionHTTPTransport(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        credentialStore: CredentialStoring = KeychainCredentialStore.shared
    ) {
        self.config = config
        self.transport = transport
        self.resolvedAPIKey = Self.resolveAPIKey(config: config, environment: environment, credentialStore: credentialStore)
    }

    func complete(_ request: LLMRequest) async throws -> LLMBackendResponse {
        guard let apiKey = resolvedAPIKey else { throw LLMClientError.missingAPIKey }
        let urlRequest = try Self.buildURLRequest(request: request, config: config, apiKey: apiKey)
        // ...(unchanged: transport.send / parseResponse)
    }

    /// Pure precedence chain (Keychain -> config.yaml plaintext -> `api_key_env` -> `nil`). Signature
    /// keeps `config`/`environment` (minimal churn from the existing
    /// `resolveAPIKey(config:environment:) throws -> String`) and adds `credentialStore` so the
    /// Keychain lookup stays fake-able in tests, mirroring `HTTPTransporting`'s DI seam. `throws` is
    /// dropped in favor of `Optional` for the reason above (`makeBackend(from:)` cannot propagate a
    /// thrown error at construction time); the `.missingAPIKey` throw stays exactly where callers
    /// already expect it — `complete(_:)` — just fed from the cached result instead of a fresh call.
    static func resolveAPIKey(
        config: OpenAIBackendConfig,
        environment: [String: String],
        credentialStore: CredentialStoring
    ) -> String? {
        if let keychainValue = credentialStore.read(account: CredentialAccount.openAIAPIKey), !keychainValue.isEmpty {
            return keychainValue
        }
        if !config.apiKey.isEmpty {
            return config.apiKey
        }
        if !config.apiKeyEnv.isEmpty, let envValue = environment[config.apiKeyEnv], !envValue.isEmpty {
            return envValue
        }
        return nil
    }
}
```

- `LLMClient.makeBackend(from:)` の `.openai` ケース（`return OpenAIChatBackend(config:
  config.openai)`）は**シグネチャ変更不要**。新しい `credentialStore` パラメータは既定値
  `KeychainCredentialStore.shared` を持つため、本番経路（`LLMClient.shared` の起動時 factory）は
  暗黙に実 Keychain を読む。テストから注入する場合のみ明示的に渡す（§6）
- `RefinementQueue+BatchProcessing.isFatal`（`Kikimi/Refinement/RefinementQueue+BatchProcessing.swift:187-194`）
  が前提とする「`.missingAPIKey` は fatal（リトライせず即座に queue を止める）」という契約は不変。
  `complete(_:)` は従来どおり `LLMClientError.missingAPIKey` を**投げる**ままなので、呼び出し側の
  型・挙動は無変更のまま成立する
- Keychain の read はプロセス起動時（backend 構築時 = `init` の1回のみ）に行う。呼び出しごとの
  再読込はしない（§7「プロバイダ変更はアプリ再起動で反映」という既存制約と整合する）

## 4. Settings UI 設計

**注**: 本節の UI コードスケッチのうち見た目（Form スタイル・Stepper・ラベル文言）は
`docs/design/30-settings-ui-polish.md` で更新済み。binding 方式・タブ構成・Keychain 連携は
本節が引き続き正。

### 4.1 タブ構成の全体像

`SettingsView.swift` の既存5タブのうち、以下3タブを実装する（「話者」「入力」は変更なし）。

| タブ | 内容 |
|------|------|
| 一般 | `stt` / `diarization` / `audio` / `defaults` / `export` / `summary`（トリガ系） |
| モデル | `llm`（provider・claude・openai・APIキー）/ `refinement` / `summary.model` / `watchers.default_model` |
| Watchers | `watchers.presets_dir` / `watchers.default_enabled_file`（プリセット .md 本体の管理 UI はスコープ外、§1 参照） |

各タブは `DictationSettingsTab` と同じ実装パターンを踏襲する: `@ObservedObject private var appConfig
= AppConfig.shared` を直接持ち、`Binding` を `appConfig.data.xxx` の get + `appConfig.update { $0.xxx
= newValue }` の set で組み立てる。`SettingsViewModel` を経由しない（`DictationSettingsTab` のドキュ
メントコメントにある理由と同じ: 値は config.yaml の素の読み書きで、導出状態を持たないため）。

### 4.2 一般タブ

```swift
private struct GeneralSettingsTab: View {
    @ObservedObject private var appConfig = AppConfig.shared

    var body: some View {
        Form {
            Section("音声認識 (STT)") {
                TextField("言語コード（例: ja-JP, auto）", text: binding(\.stt.language))
                Picker("チャンク長 (ms)", selection: binding(\.stt.chunkMs)) {
                    ForEach(SttEngineConfig.validChunkMsTiers.sorted(), id: \.self) { Text("\($0)").tag($0) }
                }
                Stepper("セグメント確定タイムアウト: \(appConfig.data.stt.segmentIdleTimeout, specifier: "%.1f")秒",
                        value: binding(\.stt.segmentIdleTimeout), in: 0.5...10.0, step: 0.5)
                Stepper("セグメント文字数上限: \(appConfig.data.stt.maxSegmentCharacters)",
                        value: binding(\.stt.maxSegmentCharacters), in: 20...400, step: 10)
            }
            Section("話者分離") {
                Toggle("話者分離を有効にする", isOn: binding(\.diarization.enabled))
                if appConfig.data.diarization.enabled {
                    TextField("自分の表示名", text: binding(\.diarization.selfName))
                    Picker("LS-EEND ステップ幅 (ms)", selection: binding(\.diarization.stepMs)) {
                        Text("100").tag(100); Text("500").tag(500)
                    }
                    Picker("モデルバリアント", selection: binding(\.diarization.variant)) {
                        ForEach(["callhome", "dihard3", "dihard2", "ami"], id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("同一人物判定の距離閾値: \(appConfig.data.diarization.speakerMatchThreshold, specifier: "%.2f")",
                            value: binding(\.diarization.speakerMatchThreshold), in: 0.0...1.0, step: 0.01)
                    Stepper("判定マージン: \(appConfig.data.diarization.speakerMatchMargin, specifier: "%.2f")",
                            value: binding(\.diarization.speakerMatchMargin), in: 0.0...0.5, step: 0.01)
                }
            }
            Section("音声") {
                Toggle("内蔵スピーカー利用時にヘッドホンを提案する", isOn: binding(\.audio.suggestHeadphonesOnBuiltInSpeaker))
            }
            Section("既定テンプレート") {
                TextField("既定 context.md のパス", text: binding(\.defaults.contextFile))
                TextField("既定 summary_template.md のパス", text: binding(\.defaults.summaryTemplateFile))
            }
            Section("サマリ更新") {
                Stepper("更新トリガ: \(appConfig.data.summary.updateTriggerSegments) セグメント",
                        value: binding(\.summary.updateTriggerSegments), in: 5...100, step: 5)
                Stepper("更新トリガ: \(appConfig.data.summary.updateTriggerSeconds) 秒",
                        value: binding(\.summary.updateTriggerSeconds), in: 30...600, step: 30)
                Toggle("タイトル自動命名", isOn: binding(\.summary.autoNaming))
            }
            Section("Wiki Export") {
                Toggle("セッション終了時に自動 export する", isOn: binding(\.export.enabled))
                if appConfig.data.export.enabled {
                    TextField("Export 先ディレクトリ", text: binding(\.export.targetDir))
                }
            }
        }
        .padding()
    }

    /// Generic `KikimiConfigData` field binding, mirroring `DictationSettingsTab`'s per-field
    /// bindings but written once via KeyPath to avoid ~15 near-identical Binding boilerplates.
    private func binding<Value>(_ keyPath: WritableKeyPath<KikimiConfigData, Value>) -> Binding<Value> {
        Binding(
            get: { appConfig.data[keyPath: keyPath] },
            set: { newValue in appConfig.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}
```

- `defaults`（`context_file`/`summary_template_file`）は `KikimiConfigData` 未モデル化のセクション
  （現状 `AppConfig.swift` のコメントに「まだ実装コンポーネントが無いので読まれていない」旨の記載が
  ある）。本設計で **新規に `DefaultsConfig` 構造体を追加してモデル化する**必要がある
  （`DiarizationConfig.init(from:)` と同じ partial デコード方式。デフォルト値は kikimi.md 12 章の
  サンプルと同じ `~/.config/kikimi/context/common.md` / `~/.config/kikimi/templates/summary.md`）

- **`SessionStore.shared` の配線変更（新規・実装必須。review 指摘の反映）**: `DefaultsConfig` を
  `KikimiConfigData` に追加するだけでは Settings UI の変更が新規セッションに反映されない。
  実際の消費者は `SessionStore.shared`（`Kikimi/SessionStore/SessionStore.swift:20-23`）であり、
  そのイニシャライザは `defaultContextFileURL`/`defaultSummaryTemplateFileURL` に
  `AppConfig.shared.data.defaults` を渡さず、ハードコードされた XDG パスの `static var`
  （同ファイル 74-80 行目の `SessionStore.defaultContextFileURL` / `defaultSummaryTemplateFileURL`）
  にフォールバックしたままである。`watchers.default_enabled_file` が既に
  `defaultEnabledWatchersFileURL: FileManager.expandingTildePath(AppConfig.shared.data.watchers.defaultEnabledFile)`
  として config 配線されている（同ファイル 22 行目）のと**全く同じパターン**で、`context_file`/
  `summary_template_file` の2つも config 配線する:

  ```swift
  actor SessionStore {
      static let shared = SessionStore(
          sessionsRootDirectory: SessionStore.defaultSessionsRootDirectory,
          defaultContextFileURL: FileManager.expandingTildePath(AppConfig.shared.data.defaults.contextFile),
          defaultSummaryTemplateFileURL: FileManager.expandingTildePath(AppConfig.shared.data.defaults.summaryTemplateFile),
          defaultEnabledWatchersFileURL: FileManager.expandingTildePath(AppConfig.shared.data.watchers.defaultEnabledFile)
      )
      // ...(init(sessionsRootDirectory:defaultContextFileURL:defaultSummaryTemplateFileURL:
      //     defaultEnabledWatchersFileURL:metaFlushInterval:fileManager:) is unchanged — the DI
      //     initializer already accepts these two URLs as parameters with `SessionStore.defaultContextFileURL`/
      //     `defaultSummaryTemplateFileURL` as their existing static-path defaults, so only the
      //     `static let shared` construction call changes, exactly like `defaultEnabledWatchersFileURL` did.)
  }
  ```

  - `SessionStore.defaultContextFileURL` / `defaultSummaryTemplateFileURL`（静的な `.config/kikimi/...`
    パス、74-80 行目）はそのまま `init(...)` の引数デフォルト値として残す（テスト用 DI と、
    `DefaultsConfig` 自体のデフォルト値がこの2つの静的パスと一致していることの後ろ盾として。
    §4.2 の `DefaultsConfig.default` が指す値と `SessionStore.defaultContextFileURL` は常に同じ
    文字列であるべきという不変条件をコメントに明記する）
  - `SessionStore.swift:16-18` のクラスコメント（「`watchers.default_enabled_file` だけが config
    配線済みで、他の default は1つずつ config 化していく」の記述）を、本変更後は「`sessionsRootDirectory`
    のみが未 config 化（`storage.session_dir` は §1 スコープ外）」に更新する
  - この配線がないと、Settings で `defaults.context_file` を変更しても config.yaml には書き込まれる
    ものの新規 Draft セッションの初期値には一切反映されない「動くように見えて動かない」UI になる
    （review 指摘の core）。したがって本項目は §6 のテスト計画にも Layer 1 のテストケースを追加する
    （後述）
- `storage` セクションは前述のとおり UI 化しない（§1 スコープ外）ため `KikimiConfigData` に追加しない
- 各 `Stepper` の range は暴走防止の穏当な UI 制約であり、config decoder 側の既存バリデーション
  （`SttConfig.init(from:)` 等の warning + fallback）とは独立。UI 制約を外れる値を config.yaml に
  手書きした場合の挙動は従来どおり decoder 側のバリデーションに従う

### 4.3 モデルタブ

```swift
private struct ModelSettingsTab: View {
    @ObservedObject private var appConfig = AppConfig.shared
    @State private var apiKeyDraft: String = KeychainCredentialStore.shared.read(account: CredentialAccount.openAIAPIKey) ?? ""

    var body: some View {
        Form {
            Section("プロバイダ") {
                Picker("プロバイダ", selection: binding(\.llm.provider)) {
                    Text("Claude CLI（サブスク認証）").tag(LLMProviderKind.claudeCLI)
                    Text("OpenAI 互換 API").tag(LLMProviderKind.openai)
                }
                if appConfig.data.llm.provider == .claudeCLI {
                    TextField("claude 実行ファイルパス（空欄で自動検出）",
                              text: optionalBinding(\.llm.claude.cliPath))
                } else {
                    TextField("Base URL", text: binding(\.llm.openai.baseURL))
                    SecureField("API キー（Keychain に保存されます）", text: $apiKeyDraft)
                        .onSubmit { persistAPIKey() }
                    TextField("API キー環境変数名（任意・フォールバック用）", text: binding(\.llm.openai.apiKeyEnv))
                    TextField("モデル上書き（Azure デプロイ名運用向け・空欄で無効）", text: binding(\.llm.openai.model))
                    TextField("API バージョン（Azure legacy 用・空欄で無効）", text: binding(\.llm.openai.apiVersion))
                    Picker("認証ヘッダ", selection: binding(\.llm.openai.authHeader)) {
                        Text("自動判定").tag("")
                        Text("Authorization: Bearer").tag("bearer")
                        Text("api-key").tag("api-key")
                    }
                }
            }
            Section("モデル") {
                TextField("整形モデル (refinement.model)", text: binding(\.refinement.model))
                TextField("サマリモデル (summary.model)", text: binding(\.summary.model))
                TextField("Watcher 既定モデル (watchers.default_model)", text: binding(\.watchers.defaultModel))
            }
            Section("バッチ整形") {
                Stepper("バッチサイズ: \(appConfig.data.refinement.batchSize)",
                        value: binding(\.refinement.batchSize), in: 1...50)
                Stepper("バッチタイムアウト: \(appConfig.data.refinement.batchTimeoutMs) ms",
                        value: binding(\.refinement.batchTimeoutMs), in: 1000...30000, step: 500)
                Stepper("コンテキストセグメント数: \(appConfig.data.refinement.contextSegments)",
                        value: binding(\.refinement.contextSegments), in: 0...10)
                Stepper("コンテキスト再構築間隔: \(appConfig.data.refinement.contextRefreshBatches) バッチ",
                        value: binding(\.refinement.contextRefreshBatches), in: 1...50)
            }
        }
        .padding()
        // Persist on tab disappear too, so navigating away without pressing Return doesn't drop an edit.
        .onDisappear { persistAPIKey() }
    }

    /// Writes `apiKeyDraft` to Keychain only when it actually changed from what's currently stored,
    /// avoiding a Keychain write on every tab open/close when the user made no edit.
    private func persistAPIKey() {
        let current = KeychainCredentialStore.shared.read(account: CredentialAccount.openAIAPIKey) ?? ""
        guard apiKeyDraft != current else { return }
        do {
            try KeychainCredentialStore.shared.write(apiKeyDraft, account: CredentialAccount.openAIAPIKey)
        } catch {
            // logged inside KeychainCredentialStore; no UI affordance for this rare failure (kikimi.md 8.5章 style)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<KikimiConfigData, Value>) -> Binding<Value> { /* 4.2と同じ */ }
    /// `String?` フィールド（`cliPath`）用: 空文字を `nil` として書き戻す。
    private func optionalBinding(_ keyPath: WritableKeyPath<KikimiConfigData, String?>) -> Binding<String> { /* ... */ }
}
```

- **API キーはキー入力のたびに Keychain へ書き込まない**（`SecureField` の `text` バインディングは
  `@State` のローカル draft に閉じる）。`onSubmit`（Return キー確定）と `onDisappear`（タブ切替・
  ウィンドウを閉じる）の2箇所でのみ永続化する。これは「今の設定ファイルはそのまま」の精神を
  Keychain 側にも延長したもの — 無意味な書き込みで Keychain の変更時刻等を汚さない
- 初期値読み込み（`@State` の初期化式で `KeychainCredentialStore.shared.read(...)`）は
  `ModelSettingsTab` の body が最初に評価される時点で1回だけ走る。タブが再表示されるたびに
  読み直したい場合は `.task` での明示リフレッシュを追加する（Phase 1 では初期値のみで十分）
- `llm.pricing`（`[String: LLMModelPricing]`）は UI 化しない（§1）

### 4.4 Watchers タブ

```swift
private struct WatchersSettingsTab: View {
    @ObservedObject private var appConfig = AppConfig.shared

    var body: some View {
        Form {
            Section("プリセットライブラリ") {
                TextField("プリセットディレクトリ", text: binding(\.watchers.presetsDir))
                TextField("既定有効化リストファイル", text: binding(\.watchers.defaultEnabledFile))
            }
        }
        .padding()
        // Preset .md 本体の一覧・作成・編集・削除は kikimi.md 9章のセッションウィンドウ内
        // Watchers タブの管轄（このタブでは扱わない、§1 スコープ外）。
    }
    private func binding<Value>(_ keyPath: WritableKeyPath<KikimiConfigData, Value>) -> Binding<Value> { /* 同上 */ }
}
```

- `watchers.defaultModel` は §4.3 のモデルタブに置く（他の3モデル指定と並べることで一貫した UX に
  なるため）。Watchers タブには残さない
- プリセット .md の管理 UI（一覧・fork・プリセット昇格等）は将来の別設計とする

## 5. エラー・失敗モードの扱い

- Keychain read/write/delete の失敗は `kikimi.md` 8.5 章の best-effort 方針を踏襲: ログに残し、
  UI 上のエラートースト等は用意しない（既存の `VoiceprintStore` 呼び出しパターンと同じ）
- `migrateAPIKeyToKeychainIfNeeded()` が失敗し続ける環境（Keychain アクセス不可等）では、
  `llm.openai.api_key` が config.yaml に平文で残り続ける。これは §3.2 の解決順フォールバックで
  機能上は問題なく動作し続ける（劣化はするが機能停止しない）
- UI 側の `Stepper`/`Picker` は SwiftUI の型で選択肢を制約するため、decoder 側の warning ログが
  UI 経由の入力で発生することは通常ない（起こり得るのは config.yaml 手編集時のみ、既存挙動のまま）

## 6. テスト計画（レイヤ1: swift-testing）

- **CredentialStore**: `InMemoryCredentialStore` の read/write/delete の基本動作。
  `KeychainCredentialStore` は実 Keychain に触れるため CI では skip 可能な統合テスト扱いにするか、
  テスト用に専用の Keychain access group を使う（要検討事項として実装時に判断。最低限
  `InMemoryCredentialStore` 側のテストは必須）
- **AppConfig マイグレーション**: `InMemoryCredentialStore` を注入した `AppConfig(directory:
  credentialStore:)` で、(a) config.yaml に平文 `api_key` がある状態で読み込むと Keychain に移送され
  config.yaml 側が空になること、(b) 既に空なら何も書き込まれない（no-op）こと、(c) Keychain 書き込み
  失敗時は config.yaml の値がそのまま残ること
- **API キー解決順**: `resolveAPIKey(config:environment:credentialStore:) -> String?`（§3.2）の
  pure 関数テスト — Keychain 優先、Keychain 空で `config.apiKey` フォールバック、両方空で
  `config.apiKeyEnv` の環境変数フォールバック、全部空で `nil`
- **DefaultsConfig**（新設）: partial デコード（欠落キー→default）が他の Config 構造体と同じ流儀で
  動くこと
- **`SessionStore.shared` の `defaults` 配線**（新規・§4.2）: `SessionStore(sessionsRootDirectory:
  defaultContextFileURL: FileManager.expandingTildePath(...), ...)` を `AppConfig` 由来の値で構築した
  ときに `createDraftSession()` の初期 `context.md`/`summary_template.md` が期待どおりコピーされる
  こと（`SessionStoreTests` の既存 `defaultEnabledWatchersFileURL` DI テストと同じパターンで、
  `AppConfig.shared` を経由せず一時ディレクトリの `context.md`/`summary_template.md` を直接
  `defaultContextFileURL`/`defaultSummaryTemplateFileURL` に渡して検証する）
- **GeneralSettingsTab / ModelSettingsTab / WatchersSettingsTab の binding ロジック**: KeyPath
  ベースの `binding(_:)` ヘルパー自体はジェネリックなので個別フィールドごとのテストは不要。
  `AppConfig.update` 呼び出しが実際に `save()` を経由することは既存の `AppConfig`/`YAMLStore` テストで
  担保済み

### 6.1 既存テストの改修（review 指摘の反映）

`resolveAPIKey` のシグネチャ変更と `AppConfig` への `credentialStore` 注入は、実装フェーズで以下の
既存テストを**明示的に**改修する必要がある（放置すると即座にコンパイルエラーまたはアサーション失敗
になる）。

- **`KikimiTests/LLM/OpenAIChatBackendTests.swift`**:
  - `resolveAPIKeyPrefersDirectKey` / `resolveAPIKeyFallsBackToEnv` / `resolveAPIKeyThrowsMissingAPIKey`
    / `resolveAPIKeyThrowsMissingAPIKeyForUnsetEnv`（139-165行目）は新シグネチャに合わせて改修する:
    `try`/`#expect(throws:)` を外し、`credentialStore: InMemoryCredentialStore()`（空のまま）を渡し、
    戻り値を `String?` として比較する（後者2つは `nil` であることの確認に変わる）
  - `completeSendsRequestAndReturnsParsedResponse` / `completeThrowsMissingAPIKeyWithoutSendingRequest`
    / 他2件（439-478行目、`OpenAIChatBackend(config:transport:environment:)` の直接呼び出し4箇所）は、
    テストファイル冒頭に追加する以下のヘルパー経由に置き換える:
    ```swift
    private func makeBackend(
        config: OpenAIBackendConfig,
        transport: HTTPTransporting,
        environment: [String: String] = [:],
        credentialStore: CredentialStoring = InMemoryCredentialStore()
    ) -> OpenAIChatBackend {
        OpenAIChatBackend(config: config, transport: transport, environment: environment, credentialStore: credentialStore)
    }
    ```
    デフォルト引数は呼び出しごとに新しい空 `InMemoryCredentialStore` を生成するため、既存4テストは
    呼び出し箇所を `makeBackend(...)` に置き換えるだけで無改修のまま実 Keychain に一切触れなくなる
- **`KikimiTests/Config/AppConfigTests.swift`**:
  - `makeAppConfig(in:)`（20-22行目）を以下のシグネチャに変更する:
    ```swift
    private func makeAppConfig(in directory: URL, credentialStore: CredentialStoring = InMemoryCredentialStore()) -> AppConfig {
        AppConfig(directory: directory, credentialStore: credentialStore)
    }
    ```
    デフォルト引数は呼び出しごとに評価される（Swift のデフォルト引数はコールサイトごとに新規生成）
    ため、1つの `AppConfig` インスタンスしか作らない既存テスト（大多数）はこの1行の改修だけで
    無改修のまま実 Keychain アクセスがなくなる
  - **`llmSettingsPersistAcrossInstances`（670-699行目）は挙動そのものを見直す**必要がある。
    このテストは `apiKey: "sk-test"` を書き込んだ後、別インスタンス化（`reload`）して
    `reloaded.data.llm.openai.apiKey == "sk-test"` を期待しているが、§3.1 のマイグレーションが
    入ると `reloaded` の `init` → `load()` が "sk-test" を Keychain へ移送し config.yaml 側を空へ
    書き戻すため、この期待値はそのままでは成立しない。加えて `makeAppConfig(in:)` の既定
    `InMemoryCredentialStore()` は呼び出しごとに別インスタンスになるため、1回目と2回目の
    `AppConfig` が別々の「空の Keychain」を見てしまい、マイグレーションの永続化そのものを
    検証できない。**1つの `InMemoryCredentialStore` を明示的に生成し、2回の `makeAppConfig` 呼び
    出し双方に同じインスタンスを渡す**（実機で1つの物理 Keychain を2回のプロセス起動が共有する
    のと同じ状況を再現する）よう改修する:
    ```swift
    @Test("update() writes and persists llm settings across a fresh AppConfig instance")
    func llmSettingsPersistAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let credentialStore = InMemoryCredentialStore()

        let appConfig = makeAppConfig(in: dir, credentialStore: credentialStore)
        appConfig.update { config in
            config.llm = LLMConfig(
                provider: .openai,
                claude: ClaudeBackendConfig(cliPath: "/usr/local/bin/claude"),
                openai: OpenAIBackendConfig(
                    baseURL: "https://api.openai.com/v1",
                    apiKey: "sk-test",
                    apiKeyEnv: "",
                    apiVersion: "",
                    model: "gpt-4o-mini",
                    authHeader: "bearer"
                )
            )
        }

        // A fresh `AppConfig` over the same directory + Keychain: its `init` -> `load()` reads
        // "sk-test" off disk and immediately migrates it (§3.1), so config.yaml's `apiKey` is
        // rewritten to "" and the plaintext moves into `credentialStore`.
        let reloaded = makeAppConfig(in: dir, credentialStore: credentialStore)
        #expect(!reloaded.loadFailed)
        #expect(reloaded.data.llm.provider == .openai)
        #expect(reloaded.data.llm.claude.cliPath == "/usr/local/bin/claude")
        #expect(reloaded.data.llm.openai.baseURL == "https://api.openai.com/v1")
        #expect(reloaded.data.llm.openai.apiKey == "", "migrated to Keychain on load; config.yaml no longer holds the plaintext")
        #expect(credentialStore.read(account: CredentialAccount.openAIAPIKey) == "sk-test")
        #expect(reloaded.data.llm.openai.model == "gpt-4o-mini")
        #expect(reloaded.data.llm.openai.authHeader == "bearer")
    }
    ```
  - 同じ理由で、`apiKey` を非空値にしてから別インスタンスで reload している他の既存テスト
    （実装時に `grep -n 'apiKey: "sk-test"' KikimiTests/Config/AppConfigTests.swift` 等で洗い出す）
    も同様の改修が要る。`apiKey` を書き込まない、または同一インスタンス内でしか読み返さないテストは
    影響を受けない
  - この改修により、既存 1400 行超のテストスイートは `mise run signing-identity` 未実行環境や CI の
    `swift test`（cdhash が安定しない ad-hoc 署名バイナリ）でも実 Keychain の権限ダイアログ・
    `errSecInteractionNotAllowed` 等に一切触れずに完走する。`KeychainCredentialStore` 自体の統合
    テストのみ、§6 冒頭の記述どおり実 Keychain 必須の別枠（CI では skip 可）として残す

レイヤ2（`kikimi-verify` skill）: 「一般」「モデル」「Watchers」タブを開いて値を変更 →
`~/.config/kikimi/config.yaml` に反映されていることを確認するシナリオを追加。「一般」タブの
`defaults.context_file`/`summary_template_file` を変更した後に新規 Draft セッションを作成し、
コピーされる `context.md`/`summary_template.md` の初期値が変更後のパスの内容になっていることまで
確認する（§4.2 の `SessionStore.shared` 配線が実際に効いていることの動作確認）。API キーについては
「Keychain に書き込まれ、config.yaml には平文が残らないこと」を `security find-generic-password`
相当のコマンドで確認する（テスト用の一時 API キー文字列を使い、確認後に delete する）。

## 7. 制約・既知の割り切り

- コメント・整形を含む YAML ラウンドトリップは非対応（§1 で確定済み）
- `storage.session_dir` と `llm.pricing` は UI 化しない。config 手編集のフォールバックを維持
- Keychain の namespace はアプリ単位（service = bundle id）。複数の OpenAI 互換エンドポイントを
  同時に使い分ける、といった multi-credential 対応は今回のスコープ外（`llm.openai.api_key` は
  常に単一の値という前提を維持する既存の `OpenAIBackendConfig` の設計をそのまま引き継ぐ）
- `KeychainCredentialStore` の実装（`SecItemAdd`/`SecItemUpdate`/`SecItemCopyMatching`/
  `SecItemDelete` の具体的なクエリ辞書組み立て）は本設計では型シグネチャのみ規定し、実装フェーズで
  詳細化する（Chirami に先例がないため、実装時に Apple の Keychain Services API を直接参照する）
