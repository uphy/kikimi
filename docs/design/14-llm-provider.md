# 14. LLM プロバイダ切り替え（OpenAI 互換 / Azure OpenAI 対応）詳細設計

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `docs/design/12-llm-client.md`（LLM Client 本体）、`kikimi.md` 12 章（config.yaml）。
消費側: `03-refinement-batch.md` / `04-summary-updater.md` / 将来の `05-watcher-runner.md`。

## 1. 目的とスコープ

現状の LLM 呼び出しは `claude` CLI サブプロセス（Claude Max サブスク課金）のみ。これに加えて
**OpenAI 互換 API（Azure OpenAI を主対象）を HTTP 直接呼び出しでサポート**し、`config.yaml` で
プロバイダを切り替えられるようにする。

**不変条件（変えないもの）**:

- 消費側の seam（`LLMCompleting` / `LLMRequest` / `LLMResult` / `LLMUsage`）は**一切変更しない**。
  `RefinementQueue` / `SummaryUpdater` は無修正で両プロバイダを使える
- スタブモード（`KIKIMI_STUB_LLM=1`）はプロバイダ選択より**前段**で分岐する（従来どおり subprocess も
  HTTP も一切触らない）
- `structured_output` 相当の JSON → `T` デコードは `.convertFromSnakeCase`（12 章 §6.2 のキー戦略）を
  **プロバイダ共通で** 1 箇所に集約する
- どのエラーでも呼び出し側は「今回の更新をスキップして次へ」で継続できる（12 章 §4.1 の思想）

**スコープ外**:

- 実行中のプロバイダ動的切り替え（§7 参照。アプリ再起動で反映）

**この設計時点からの変更**: 「Settings UI からのプロバイダ編集（config.yaml 手編集が導線）」は
当初スコープ外としていたが、`docs/design/26-settings-ui.md` §4.3 の `ModelSettingsTab` で実装済み
（`llm.provider`/`llm.claude.cliPath`/`llm.openai.*` を Settings ウィンドウの「モデル」タブから編集
できる）。上記「実行中のプロバイダ動的切り替え」は変わらずスコープ外のまま — Settings で変更しても
`LLMClient.shared` への反映はアプリ再起動後（§7 のとおり）。

## 2. アーキテクチャ: `LLMBackend` プロトコル

`LLMClient` の「スタブ分岐 + `T` デコード」と「プロバイダ固有のワイヤ処理」を分離する。

```swift
/// One provider-specific completion call. Returns the schema-conformant structured JSON as raw
/// Data plus usage; LLMClient owns the (single, shared) convertFromSnakeCase decode into T.
protocol LLMBackend: Sendable {
    func complete(_ request: LLMRequest) async throws -> LLMBackendResponse
}

struct LLMBackendResponse: Sendable {
    var structuredJSON: Data
    var usage: LLMUsage
}
```

- **`ClaudeCLIBackend`**: 既存実装の移設。`LLMClient.buildArguments` / `decodeResult` のエンベロープ
  解釈（`structured_output` の取り出し・`is_error`/`subtype` の認証エラー分類・usage 変換）と
  `ClaudeCLIProcessRunner` 呼び出しをこの型に移す。**ロジックは移動のみで書き換えない**
  （検証済みの CLI 呼び出し形を壊さない）。`LLMProcessRunner` プロトコルと
  `ClaudeCLIProcessRunner` はそのまま（変更しない）
- **`OpenAIChatBackend`**: 新規。§4 参照
- `LLMClient` は `init(backend: LLMBackend, environment:)` になり、`complete` は
  「スタブ分岐 → `backend.complete` → `structuredJSON` を `.convertFromSnakeCase` で `T` に
  デコード」だけを担う。`decodeFailed` の分類は従来どおり `LLMClient` 側
- `LLMClient.shared` は起動時に `AppConfig.shared.data.llm` を読んでバックエンドを組み立てる
  static factory 経由で生成する（12 章 §8 の「LLMClient 自体は config を読まない」は
  **インスタンスのメソッドが config を読まない**という意味に限定し、shared の組み立てだけは
  config を参照してよいことにする。モデル名は従来どおり呼び出し側が渡す）

## 3. config.yaml の `llm:` セクション

```yaml
llm:
  provider: claude-cli          # claude-cli | openai。既定 claude-cli（後方互換）
  claude:
    cli_path: null              # 任意。claude 実行ファイルの明示パス（12章 §3.1 step 1 の実装化）
  openai:
    base_url: ""                # 必須。例:
                                #   OpenAI:       https://api.openai.com/v1
                                #   Azure v1:     https://<res>.openai.azure.com/openai/v1
                                #   Azure legacy: https://<res>.openai.azure.com/openai/deployments/<dep>
    api_key: ""                 # 直接指定（ローカル個人アプリなので config 直書きを許容）
    api_key_env: ""             # api_key が空のとき、この名前の環境変数から読む
    api_version: ""             # 空以外なら ?api-version=<値> を付与（Azure legacy 形式）
    model: ""                   # 空以外なら全呼び出しの model を上書き（Azure のデプロイ名運用向け）
    auth_header: ""             # "bearer" | "api-key"。空なら api_version 有→api-key / 無→bearer
```

- 既存セクション（`DiarizationConfig`/`RefinementConfig`）と同じ流儀: **partial デコード許容**
  （欠けたフィールドは default で埋める）、不正値は warning ログ + default フォールバック。
  `provider` が未知の値なら warning を出して `claude-cli` に落とす
- **API キー解決順**（`docs/design/26-settings-ui.md` §3.2 で Keychain 化・実装化済み）:
  1. Keychain（`CredentialAccount.openAIAPIKey`）の値（非空なら採用）
  2. config.yaml の `llm.openai.api_key`（後方互換フォールバック。§3.1 のマイグレーションが正常なら
     常に空のはずだが、マイグレーション失敗時・手編集直後のタイミング等で非空になり得る）
  3. `api_key_env` の環境変数（LSUIElement 起動ではユーザーシェルの環境変数を継承しない点は従来注記の
     まま。ターミナル起動・kikimi-verify 用の逃げ道）
  4. すべて空なら `LLMClientError.missingAPIKey`

  Keychain read は `OpenAIChatBackend.init`（バックエンド構築時 = プロセス起動時）に1回だけ行い、
  `complete(_:)` 呼び出しのたびには再読込しない（同§3.2）。
- **モデル解決**: `llm.openai.model` が非空なら `LLMRequest.model` を無視して常にそれを使う。
  空なら `request.model`（= `refinement.model` / `summary.model` の値）をそのまま送る。
  Azure ではデプロイ名がモデル指定なので、単一デプロイ運用では `llm.openai.model` 1 箇所で済む
- `kikimi.md` 12 章の config サンプルにも `llm:` セクションを追記する（1 箇所、上記と同内容の要約）

## 4. `OpenAIChatBackend` 詳細

### 4.1 リクエスト

- エンドポイント: `{base_url}/chat/completions`（base_url 末尾の `/` は正規化）。
  `api_version` 非空なら `?api-version=<値>` を付与
- 認証ヘッダ: `auth_header` の解決値により `Authorization: Bearer <key>` または `api-key: <key>`
- ボディ:

```json
{
  "model": "<解決済みモデル名>",
  "messages": [
    {"role": "system", "content": "<request.system>"},
    {"role": "user", "content": "<request.user>"}
  ],
  "response_format": {
    "type": "json_schema",
    "json_schema": {"name": "response", "strict": false, "schema": <request.schemaをJSONとしてパースしたもの>}
  }
}
```

- `strict: false` を固定にする。既存の consumer schema（refinement / summary）は
  `additionalProperties: false`・全 required という strict 制約を満たす保証がないため。
  schema 不一致は従来どおり `decodeFailed` で安全側に落ちる
- `request.schema` が JSON としてパース不能なら `invalidJSON(raw: schema)`（消費側定数のバグ）
- タイムアウト: `request.timeout` を URLRequest の `timeoutInterval` に設定

### 4.2 レスポンス

- `choices[0].message.content` を JSON 文字列とみなし UTF-8 Data 化して `structuredJSON` に入れる。
  content が欠落/空 → `missingStructuredOutput(raw: <ボディ先頭1KB>)`
- usage 変換: `prompt_tokens` → inputTokens、`completion_tokens` → outputTokens、
  `prompt_tokens_details.cached_tokens` → cacheReadInputTokens、cacheCreationInputTokens = 0、
  totalCostUSD = 0（OpenAI 側は単価不明のため計上しない）。usage 欠落時はゼロ値
- HTTP ステータス分類:
  - 401 / 403 → `notAuthenticated`（既存の fatal 分類に自然に乗る）
  - その他の非 2xx → 新設 `httpFailed(status:body:)`（body は先頭 1KB に切り詰め）
  - URLSession のトランスポートエラー（接続不能・タイムアウト等）→ タイムアウトは
    `timedOut(request.timeout)`、それ以外は新設 `networkFailed(description:)`

### 4.3 テスト容易性

`LLMProcessRunner` と同じパターンで HTTP 層をプロトコルで抽象化する。

```swift
protocol HTTPTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
```

- 本番実装は `URLSession` の薄いラッパ。テストは固定レスポンスを差し込む fake
- URL / ヘッダ / ボディの組み立てと、レスポンス→`LLMBackendResponse` / エラー分類は
  static pure 関数に切り出して直接テストする（`buildArguments` / `decodeResult` と同じ流儀）

## 5. エラー型の拡張

`LLMClientError` に以下を追加する:

```swift
case missingAPIKey                          // openai プロバイダで API キーが解決できない
case httpFailed(status: Int, body: String)  // 非2xx（401/403 は notAuthenticated に分類済み）
case networkFailed(description: String)     // トランスポートエラー
```

- `LocalizedError` の switch に 3 case を追加
- **fatal 分類**: `RefinementQueue+BatchProcessing.isFatal` に `.missingAPIKey` を追加する
  （`cliNotFound`/`notAuthenticated` と同様、リトライしても回復しない設定不備のため）。
  `httpFailed` / `networkFailed` は非 fatal（一時障害としてスキップ・継続）
- `healthCheck(model:)` は `LLMClient` の共通経路（backend 経由）に乗るので、openai プロバイダでも
  そのまま最小 1 呼び出しの疎通確認として機能する。シグネチャ変更なし

## 6. テスト計画（レイヤ 1: swift-testing）

- **Config**: `llm:` セクションの partial デコード（欠落キー→default、未知 provider→warning +
  claude-cli フォールバック）、既存 config.yaml（`llm:` なし）が従来どおり読めること
- **OpenAIChatBackend（pure 関数）**:
  - URL 組み立て（base_url 末尾スラッシュ正規化、api_version の有無）
  - 認証ヘッダ（bearer / api-key / auth_header 明示指定 / api_version からの導出）
  - API キー解決順（api_key → env → missingAPIKey）
  - モデル上書き（llm.openai.model 非空/空）
  - ボディの response_format（strict:false、schema 埋め込み）
  - レスポンスパース: 正常（content → structuredJSON、usage 変換）、content 欠落 →
    missingStructuredOutput、401/403 → notAuthenticated、500 → httpFailed、usage 欠落 → ゼロ値
- **LLMClient**: backend 差し替えで `structuredJSON` → `T` の convertFromSnakeCase デコードが
  従来どおり動くこと（既存テストの移設含む）。既存の `buildArguments` / `decodeResult` テストは
  `ClaudeCLIBackend` のテストとして移設し、**アサーション内容は変えない**
- **RefinementQueue**: `.missingAPIKey` が fatal 扱いになること（既存 fatal テストに 1 ケース追加）

レイヤ 2（kikimi-verify）はスタブモードがプロバイダ非依存の前段分岐なので既存フローのまま。

## 7. 制約・既知の割り切り

- **プロバイダ変更はアプリ再起動で反映**。`AppConfig` は watchForChanges だが、実行中の
  backend 差し替えは in-flight 呼び出しとの整合が複雑になるため MVP では見送る
- prompt caching: OpenAI 側は自動キャッシュ（明示 cache_control なし）。`context_refresh_batches`
  の仕組みはそのまま活きる（system prompt を固定に保つ運用はプロバイダ非依存に有効）
- Azure の content filter で choices が `finish_reason: "content_filter"` になった場合も
  content 欠落 → `missingStructuredOutput` に落ちる（専用分類は実戦で必要になってから）
