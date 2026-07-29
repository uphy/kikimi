# 12. LLM Client 詳細設計

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `kikimi.md` 7章（LLM 整形パイプライン）, 8章（サマリ更新 / 自動タイトル）, 9章（Watchers）,
12章（`config.yaml` の `refinement.model` / `summary.model` / `watchers.default_model`）, 15章（API キー管理）。
消費側: `docs/design/04-summary-updater.md`（サマリ patch / 自動タイトル）、将来の `03-refinement-batch.md`
（Haiku バッチ整形）、`05-watcher-runner.md`（Watcher 実行）。

---

## 1. 目的とスコープ

Kikimi の**すべての LLM 呼び出しの単一の窓口**。整形・サマリ・タイトル・Watcher の各コンポーネントは
自前で HTTP や subprocess を組み立てず、必ず `LLMClient` 経由で LLM を呼ぶ。

このコンポーネントが担うのは以下だけ:

- system prompt / user prompt / JSON Schema / モデル名を受け取り、**構造化出力（`Decodable`）を返す**単一 API
- Claude Max サブスクリプションでの認証（API キー課金を使わない。3章参照）
- 呼び出しの失敗（プロセス異常終了・タイムアウト・JSON 破損・スキーマ不一致）を型付きエラーとして返す
- スタブモード（`KIKIMI_STUB_LLM=1`）での決定論的応答（`kikimi-verify` / 単体テスト向け）

**スコープ外**（消費側の責務）:

| 関心事 | 担当 |
|---|---|
| バッチ化・トリガ判定・キュー管理・バックプレッシャ | `03-refinement-batch.md` / `04-summary-updater.md` |
| prompt の中身（system prompt の文面・事前知識の組み立て・patch schema） | 各消費側 |
| patch の state への適用・view レンダリング | `04-summary-updater.md` / `05-watcher-runner.md` |
| モデル名の決定（config からの解決） | 呼び出し側が `AppConfig` から解決して渡す |

---

## 2. なぜ subprocess（`claude` CLI）方式か

kikimi.md 15章の Open Question「Claude API キー管理」に対する結論。**Anthropic API キー課金ではなく、
ユーザーの Claude Max サブスクリプションを使う**方針をユーザーが選択した（本フェーズの合意事項）。

Swift アプリから Max サブスクを使う現実解は、**認証済みの `claude` CLI をヘッドレス（`--print`）で
subprocess 起動する**こと。CLI が Keychain の OAuth 資格情報（`Claude Code-credentials`）を使って
サブスク課金枠で実行する。公式 Swift SDK は存在せず、OAuth トークンを直接 API に投げるのは ToS 上避けたいので、
CLI を Agent SDK ランタイムとして利用する。

### 2.1 検証済みの呼び出し形（このフェーズで実機確認済み）

```
claude -p \
  --system-prompt "<固定システムプロンプト>" \
  --tools \                                    # 空指定でツール無効化（余計なトークンを載せない）
  --exclude-dynamic-system-prompt-sections \   # 環境依存の動的セクションを除去
  --setting-sources "" \                        # ユーザー settings を読み込まない（再現性）
  --output-format json \
  --json-schema "<JSON Schema 文字列>" \
  --model "<model id>"
  # stdin にユーザープロンプトを渡す
```

- 応答は 1 行の JSON。`.structured_output`（`--json-schema` 指定時）にスキーマ準拠のオブジェクトが入る。
  `.result` にも同じ内容が文字列で入るが、**`.structured_output` を正とする**
- `.is_error` / `.subtype` で成否を判定。`.usage` にトークン数、`.total_cost_usd` にサブスク換算コスト
- 実測: 上記フラグ無し（既定 Claude Code system prompt + 全ツール）だと 1 呼び出しあたり ~58k キャッシュ
  トークン・約 $0.12 相当。フラグありだと input ~1k・約 $0.003 相当まで低減。**必ずフラグ付きで呼ぶ**

### 2.2 prompt caching に関する注意

- `--system-prompt` で上書きした小さめ（< 1024 トークン）の system prompt は cache_creation されない
  （実測 cache_creation=0）。サマリ・タイトルは system prompt が小さいので caching の恩恵はほぼ無く、問題ない
- 将来 `03-refinement-batch.md`（Haiku 整形）で 1024〜4096 トークンの事前知識を載せる場合、CLI 経由で
  prompt caching が効くかは**その時点で実測して判断**する（このドキュメントの責務外）。効かない場合は
  refinement 側の設計で吸収する

---

## 3. 認証

- `claude` CLI が Keychain（`Claude Code-credentials`）の OAuth 資格情報を自動で使う。Kikimi 側は
  **API キーを一切保持しない**（Keychain アクセスも CLI に委譲）
- 前提: ユーザー環境で `claude` CLI がインストール済み・ログイン済み（Max/Pro サブスク）であること
- **起動時ヘルスチェック**: アプリ起動時（または最初の LLM 呼び出し前）に `claude --version` 相当の疎通確認を
  行い、CLI 不在・未ログインを検出したら UI に warning を出す（サマリ/タイトルが動かない旨）。録音・書き起こしは
  LLM 非依存なので継続できる（kikimi.md「録音は絶対に止めない」）

### 3.1 `claude` 実行ファイルの解決

- `PATH` から `claude` を探索。GUI アプリ（LSUIElement）は Finder 起動だとログインシェルの `PATH` を
  継承しないため、以下の順で解決する:
  1. `AppConfig` の `llm.claude_path`（明示指定、あれば最優先）
  2. `which claude` 相当（`/usr/bin/env claude` をログインシェル経由で）
  3. 既知の候補パス（`/opt/homebrew/bin/claude`, `~/.local/bin/claude`, `/usr/local/bin/claude` など）
- 解決できなければ CLI 不在として warning（3章のヘルスチェックと同経路）

---

## 4. 公開 API

```swift
/// The seam consumers depend on (SummaryUpdater, future refinement/watcher runners). Kept as a
/// narrow protocol — not the concrete `LLMClient` — so consumers can inject a hand-written fake in
/// unit tests without going through the CLI-output-decoding path at all (SWE review C8).
protocol LLMCompleting: Sendable {
    func complete<T: Decodable & Sendable>(_ request: LLMRequest) async throws -> LLMResult<T>
}

/// One structured-output call. `schema` is a JSON Schema string the consumer holds as a constant;
/// its shape must match `T` (verified by a unit test that decodes a sample into `T`).
struct LLMRequest: Sendable {
    var system: String        // fixed system prompt, kept small (section 2.2)
    var user: String          // per-call prompt, passed on stdin (messages 非 nil なら最新ターンのみ)
    /// 過去の会話ターン（古い順、最新の質問は含まない）。セッションチャット以外は nil
    /// （design 38 §8.1(b)）。平坦化はバックエンドの責務: OpenAI 互換は配列のまま送り、
    /// Claude CLI は `Q:` / `A:` の 1 本のテキストに畳む。
    var messages: [LLMMessage]?
    var schema: String        // handed to --json-schema
    var model: String         // resolved model id (caller resolves from AppConfig)
    /// 既定 60 秒は「バッチ／直近セグメント単位の小さいプロンプト」を送る既存の呼び出し元に
    /// 合わせた値で、入力規模が 1 桁違う呼び出し元は明示的に上書きする
    /// （`DictationRefiner` の `dictation.refine_timeout_ms`、`ChatRunner` の
    /// `chat.timeout_seconds` = design 38 CH19）。
    var timeout: Duration = .seconds(60)
    /// Stub-mode dispatch key (section 5); ignored in production.
    var stubKey: String? = nil
}

/// `LLMRequest.messages` の 1 要素。`system` ロールは持たない（system prompt は
/// `LLMRequest.system` で、各バックエンドが自分の流儀で置く）。
struct LLMMessage: Sendable, Equatable {
    enum Role: String, Sendable, Equatable { case user, assistant }
    var role: Role
    var text: String
}

/// `value` plus the usage/cost the CLI reported, so callers that want per-session cost accounting
/// (section 9, kikimi.md 15章) get it without a later breaking signature change (SWE review C5).
/// Callers that don't care just read `.value`.
struct LLMResult<T: Sendable>: Sendable {
    var value: T
    var usage: LLMUsage
}

struct LLMUsage: Sendable, Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadInputTokens: Int
    var cacheCreationInputTokens: Int
    var totalCostUSD: Double
}

/// Production implementation. Actor-isolated so its in-flight bookkeeping is race-free; note this
/// does NOT by itself serialize consumers to a single CLI process (see below).
actor LLMClient: LLMCompleting {
    static let shared = LLMClient(...)
    init(runner: LLMProcessRunner = ClaudeCLIProcessRunner(), ...)
    func complete<T: Decodable & Sendable>(_ request: LLMRequest) async throws -> LLMResult<T>
}
```

- **構造化出力のみを公開する**。自由文字列を返す API は用意しない（Kikimi の LLM 用途はすべて schema 付き）
- `schema` は文字列（消費側が定数として持つ）。`T` との整合は消費側の責任。将来 `T` から JSON Schema を
  自動生成する余地はあるが MVP では手書きスキーマ文字列で足りる
- **並行度**: `complete` の `await` は subprocess 完了まで長時間 suspend し得る。actor は await 境界で再入する
  ため、`LLMClient` actor 自体は「同時に走る CLI プロセスを 1 本に絞る」保証を**しない**。同時起動プロセス数の
  上限が要るなら `AsyncSemaphore` 相当で明示的に絞る（MVP は SummaryUpdater 側が直列化するので LLMClient は
  絞らない。将来 refinement と同時に走らせるときに上限を入れる）

### 4.1 エラー型

```swift
enum LLMClientError: Error, Equatable {
    case cliNotFound(searchedPaths: [String])   // claude 実行ファイルが見つからない
    case notAuthenticated                        // 認証エラー（判定は下記）
    case processFailed(exitCode: Int32, stderr: String)
    case timedOut(Duration)
    case invalidJSON(raw: String)                // CLI 出力が JSON として壊れている
    case missingStructuredOutput(raw: String)    // structured_output が無い / is_error=true
    case decodeFailed(underlying: String)        // structured_output → T のデコード失敗
}
```

- どのエラーでも**呼び出し側は「今回の LLM 更新をスキップして次へ」で継続できる**設計（kikimi.md 8.5
  バックプレッシャ／整形失敗フォールバックと同じ思想）。LLMClient は絶対に録音・保存を巻き込まない
- **`notAuthenticated` の判定は構造化フィールド優先**（SWE review C4）: CLI 応答 JSON の `.subtype` /
  `.api_error_status` 等の機械可読フィールドで判定し、人間可読メッセージの文字列一致には依存しない（CLI の文言・
  ロケール変更で壊れないため）。判定できない場合も `processFailed`/`missingStructuredOutput` に落ちて安全側
  （更新スキップ）に倒れる。実装時に実際の未認証 CLI 応答の JSON 形を確認してフィールドを確定する

---

## 5. スタブモード（`KIKIMI_STUB_LLM=1`）

`kikimi-verify` skill / 単体統合テストで API を叩かず決定論的に検証するため。

- 環境変数 `KIKIMI_STUB_LLM=1` のとき、`complete` は subprocess を起動せず**固定のスタブ応答**を返す
- スタブ応答は「呼び出し種別」ごとに固定 JSON を返す。種別の識別は `system` prompt の内容ではなく、
  `LLMRequest.stubKey`（4章のフィールド）で行い、スタブ辞書のキーにする（本番では無視）。または環境変数
  `KIKIMI_STUB_LLM_FILE` で JSON マップを差し込める（こちらが常に優先）。`usage` はゼロ値の `LLMUsage`
  を返す
- スタブは `T` にデコード可能な JSON でなければならない（消費側テストが期待する形）
- 目的は「LLM を叩かずに、SummaryUpdater / タイトル機構 / UI のロジックを end-to-end で回す」こと
- **`refinement` stubKey だけは組み込みで動的な id echo スタブを持つ**（`docs/design/03-refinement-batch.md`
  9章）: `LLMStubProvider` がリクエストの user prompt から 【今回整形する対象】ブロックの
  `id`/rawText を自前でパースし、各セグメントを `{"id": <id>, "refined_text": "[stub] " + rawText}`
  として返す。ただし rawText に「えーと」を含む場合、または trim 後が空文字の場合は
  `refined_text: ""`（DROP マーカー。`RefinementValidator` の意図的削除パス）を返す。これにより
  毎バッチ固定で「id が応答にない」扱い（raw フォールバック一択）になっていた旧挙動と異なり、
  `kikimi-verify` / 統合テストで SUCCESS パスと DROP パスの両方を決定的に踏める。`KIKIMI_STUB_LLM_FILE`
  に `refinement` キーを明示登録すれば、この動的スタブより優先されて完全に上書きできる（旧来の固定
  `{"segments": []}` 応答を再現したいテストはこちらを使う）

---

## 6. subprocess 実装メモ（`ClaudeCLIProcessRunner`）

subprocess の起動・待機・タイムアウトは runner に閉じ込める（7章の `LLMProcessRunner`）。**同期ブロッキング
（`waitUntilExit()` / `readDataToEndOfFile()`）を actor の実行文脈で直接呼ばない**（SWE review B1）。理由:

- `waitUntilExit()` / `readDataToEndOfFile()` は同期ブロッキングで、Swift concurrency の cooperative thread
  pool を占有する（最悪プール枯渇）
- 「stdout を全読みしてから wait」の順序は、子プロセスの stdout が pipe バッファ（64KB 程度）を超えると
  **子が write でブロック・親が read 前の wait でブロック**する古典的デッドロックになる。stdout は wait と
  **並行に**吸い出す必要がある

### 6.1 非ブロッキング実装方針

- `Process.terminationHandler` + `withCheckedThrowingContinuation` でプロセス終了を待つ（ブロッキング wait を
  使わない）
- stdout / stderr の `Pipe` は `readabilityHandler`（または専用の読み取り Task）で**終了待ちと並行に**逐次
  読み出し、バッファに追記する。これで pipe デッドロックを回避
- プロセス起動 → **stdin への書き込みと close は専用の detached Task に出し、その完了を待たずに**
  タイムアウトの race に入る → 終了 handler で continuation を resume → 蓄積した stdout を返す
  （design 38 §8.1(a) / CH20）。macOS の pipe バッファは最大 64KB なので、同期 write のままだと
  それを超えるプロンプト（チャットの `max_context_chars: 120000` は日本語で約 360KB）で
  **タイムアウトが張られる前にブロック**し、子が stdin を読まずに固まると永久に返らない。
  write は `write(contentsOf:)` を使い、EPIPE を Swift エラーとして受ける（ObjC 例外だとアプリが落ちる）。
  あわせて**プロセス起動前に一度だけ `SIGPIPE` を `SIG_IGN` にする** — 子が stdin を読まずに終了した
  瞬間にシグナルでプロセスごと死ぬのを防ぐ
- **タイムアウト**: `Task.sleep(timeout)` を並行に走らせ、超過したら `process.terminate()`（SIGTERM）→ 短い
  猶予後になお生きていれば `interrupt`/kill。**必ず子プロセスを reap し、両 `Pipe` の FD を close してから**
  `timedOut` を投げる（プロセス／FD リーク防止, SWE review C3）。正常終了経路でも `readabilityHandler` を
  外して FD を確実に閉じる
- **タイムアウトの所有は runner が正**（`LLMRequest.timeout` を runner が enforce）。`LLMClient` 側は二重に
  タイムアウトを張らない（責務の一本化, SWE review C3）

### 6.2 出力パース

- stdout は 1 行 JSON を想定するが、CLI が warning を stdout に混ぜる可能性に備え、**最後の非空行を JSON として
  パース**する（保険）。パース不能なら `invalidJSON`
- `.structured_output` を取り出して `T` にデコード（無ければ `missingStructuredOutput`）。`.usage`/
  `.total_cost_usd` を `LLMUsage` に詰めて `LLMResult` で返す
- **キー戦略（重要・実装で確定）**: エンベロープ（`is_error`/`usage`/`total_cost_usd` 等）は**プレーンデコーダ＋
  明示 `CodingKeys`** で読む。一方 **`structured_output` → `T` のデコードは別デコーダで `.convertFromSnakeCase`
  を適用**する。これにより:
  - 全 schema は snake_case（`source_seg_ids` 等。kikimi.md の慣習・JSON Schema と一致）で LLM に返させつつ、
    消費側の型（`SummaryPatch` / `SummaryState` など）は**明示 `CodingKeys` を持たない素の camelCase プロパティ**で
    書ける
  - 同じネスト型が `structured_output`（LLM ワイヤ）経由でも `summary.state.json`（`SessionJSONCoding` の
    convert 経由）経由でも同一の解釈でデコードできる。**明示 snake_case キーを付けると `SessionJSONCoding` の
    `.convertFromSnakeCase` と二重変換で衝突する**ため、キー戦略を convert に統一するのが唯一整合する解
  - 実装は `structured_output` を一旦 raw JSON として取り出し、convert デコーダで `T` に再デコードする（エンベ
    ロープのプレーン解釈と混ざらないよう分離）。スタブ（`LLMStubProvider`）・テストのフェイク（`FakeLLM`）も
    同じ convert 挙動に揃える
- `--setting-sources ""` / `--tools`（空）/ `--exclude-dynamic-system-prompt-sections` は固定で常に付与
- 文字エンコーディングは UTF-8 固定
- `Process.arguments` に配列で渡す（シェル経由しない）ので、prompt 内の特殊文字エスケープ不要（stdin 経由の
  ユーザープロンプトも同様に注入リスクなし）

---

## 7. テスト容易性

### レイヤ1（単体テスト, swift-testing）

- subprocess を直接叩くと非決定的なので、**CLI 起動部分をプロトコルで抽象化**する:

  ```swift
  protocol LLMProcessRunner: Sendable {
      func run(arguments: [String], stdin: String, timeout: Duration) async throws -> String  // stdout
  }
  ```

  `LLMClient` はこの runner を注入で受け取る。本番は `ClaudeCLIProcessRunner`、テストは stdout 文字列を
  差し込む `FakeProcessRunner`。これで以下を実 CLI 無しで検証できる:
  - 正常な CLI JSON → `structured_output` を `T` にデコードできる
  - `is_error: true` → `missingStructuredOutput`
  - 壊れた JSON → `invalidJSON`
  - `structured_output` が `T` と食い違う → `decodeFailed`
  - runner が投げるタイムアウト → `timedOut`
- CLI 引数の組み立て（フラグが必ず付くか、model / schema が正しく渡るか）を pure に検証
- CLI パス解決ロジック（候補順・不在時 `cliNotFound`）を pure に検証
- スタブモードの分岐（`KIKIMI_STUB_LLM=1` で runner を呼ばず固定応答）

### レイヤ2（`kikimi-verify` / 統合）

- `KIKIMI_STUB_LLM=1` で end-to-end（実 CLI 不要）
- 実 CLI 疎通テストは任意（サブスク枠を消費するのでデフォルト実行しない。手動タグ付き）

---

## 8. 他ドキュメントとの境界（インターフェース契約）

| 相手 | 契約 |
|---|---|
| `04-summary-updater.md` | `complete(system:user:schema:model:)` を呼んでサマリ patch / タイトルの構造化出力を得る。エラー時はサマリ更新をスキップ |
| 将来 `03-refinement-batch.md` | 同 API。事前知識入り system prompt の caching は refinement 側で実測・吸収 |
| 将来 `05-watcher-runner.md` | 同 API。Watcher schema を JSON Schema 文字列にして渡す |
| `AppConfig`（要実装） | `llm.claude_path`（任意）とモデル既定値を提供。LLMClient 自体は config を読まず、model 名を引数で受ける |

---

## 9.5. raw 経路（`completeRaw`, `docs/design/05-watcher-runner.md` §5.1）

`complete<T>` の共有デコードは `structured_output` を `.convertFromSnakeCase` デコーダに通す（6.2 章）。
これは固定 schema の消費側（`SummaryPatch` 等）には正しいが、**動的 schema**（Watcher の `schema:`
frontmatter はユーザー定義、`JSONValue` としてしか表現できない）には壊れた挙動になる:
ユーザー定義キー（`source_seg_id` 等）が `sourceSegId` に変換され、view template の変数参照が壊れる。

このため `LLMCompleting` に `completeRaw(_:) async throws -> LLMResult<Data>` を追加した。
`complete<T>` と同じ CLI/HTTP 呼び出し・stub 分岐を通るが、**キー変換を一切行わず**
`structured_output` の生バイト列をそのまま返す。消費側（`WatcherRunner`）が
`JSONValue.parse(data:)`（`JSONSerialization` ベース、key strategy 無し）でパースする。

- `LLMClient.completeRaw`: stub モードでは `LLMStubProvider.stubRawResult(for:)`
  （`stubResult(for:)` と同じ `stubKey`/`overrides`/`"refinement"` echo 解決を共有し、`T` へのデコードだけ
  省略する）。本番モードでは `backend.complete(request)` の `structuredJSON`/`usage` をそのまま
  `LLMResult<Data>` に包んで返す（デコード無し）
- `UsageRecordingLLM.completeRaw`: `complete<T>` と同じく `base.completeRaw` に委譲し、成功時に
  `llm_usage.jsonl` へ記録 + `.kikimiLLMUsageRecorded` を通知する（`WatcherRunner` はこのデコレータの
  存在を意識しない）
- 既存の `FakeLLM`/`FakeCompletingLLM` 系フェイクにも `completeRaw` の実装を追加し、コンパイルを通す

---

## 9.6. Open Questions

- **並行度**: サマリと refinement が同時に走るとき CLI プロセスを何本まで許すか。MVP は単一 actor 直列。
  実戦（Phase 4）で遅延が問題なら緩める
- **CLI バージョン差**: `--json-schema` / `--exclude-dynamic-system-prompt-sections` / `--tools`（空）は
  比較的新しいフラグ。起動時ヘルスチェックは CLI の**存在**だけでなく、これらフラグを付けた最小 dry-run が
  受理されるか（未知フラグでエラーにならないか）まで見て、非対応なら warning にとどめる（機能縮退、
  クラッシュしない, SWE review nit）
- **コスト表示**: `.total_cost_usd` を UI に累積表示するか（kikimi.md 15章 Open Question）。本ドキュメントでは
  値を返せるようにしておくに留め、表示は UI 側の判断
