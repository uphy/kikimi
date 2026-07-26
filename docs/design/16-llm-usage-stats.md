# 16. LLM Token 使用統計とコスト記録

kikimi.md 15 章 Open Question「Watcher 実行のコスト計算表示: 会議ごとの累積 API コストを UI に表示するか」への回答。
セッション（会議）単位で全 LLM 呼び出しの token 使用量（cache read/write 含む）を記録し、累積コストを UI に表示する。

## 1. 目的と非目的

- **目的**
  - refinement / summary / title（将来は Watcher も）の全 LLM 呼び出しの usage をセッションフォルダに永続化する
  - prompt cache（read / creation）を区別して記録し、コスト計算に反映する
  - セッションウィンドウのヘッダで累積コストを一目で確認でき、内訳（用途別・token 種別）を popover で見られる
- **非目的**
  - 予算アラート・レート制限

## 2. データモデル: `sessions/<id>/llm_usage.jsonl`

追記専用 JSONL。1 行 = 1 LLM 呼び出し（成功したもののみ。失敗した呼び出しは usage が取得できないため記録しない）。

```json
{
  "timestamp": "2026-07-03T14:32:15Z",
  "purpose": "refinement",
  "model": "claude-haiku-4-5-20251001",
  "input_tokens": 850,
  "output_tokens": 320,
  "cache_read_input_tokens": 2100,
  "cache_creation_input_tokens": 0,
  "reported_cost_usd": 0.0042
}
```

| フィールド | 説明 |
|---|---|
| `purpose` | `LLMRequest.stubKey` を流用（`refinement` / `summary_patch` / `final_title` / …）。stubKey は元々スタブ振り分けキーだが、値が用途そのものなので兼用する。無ければ `"unknown"` |
| `input_tokens` | **uncached input**（cache read / creation を含まない）。Anthropic の usage 意味論に統一する |
| `cache_read_input_tokens` | prompt cache ヒット分 |
| `cache_creation_input_tokens` | prompt cache 書き込み分（OpenAI 互換は常に 0） |
| `reported_cost_usd` | backend が報告したコスト。claude CLI の `total_cost_usd`。OpenAI 互換は報告が無いので `null` |

- エンコーディングは他のセッション JSON と同じ `SessionJSONCoding`（snake_case + ISO8601）
- コストは行に**保存しない**（`reported_cost_usd` を除く）。推定コストは読み出し時に価格表から計算する（価格表を後から修正しても過去分に反映できる）

### OpenAI 互換 backend の正規化

OpenAI の `usage.prompt_tokens` は `cached_tokens` を**含む**（Anthropic の `input_tokens` は含まない）。
`OpenAIChatBackend` 側で `inputTokens = prompt_tokens - cached_tokens` に正規化し、`LLMUsage` の意味論を
「`inputTokens` = uncached input」に統一する。

### `model` フィールドの解決順

`llm_usage.jsonl` / `refined.jsonl` の `model` は、**バックエンドが実際に応答したモデルが分かればそれを優先する**。
Azure OpenAI の legacy デプロイ URL（`.../openai/deployments/<name>`）では、リクエスト body の `model` は
サーバ側で無視され、URL 内のデプロイ名がモデルを決める。そのため `refinement.model` / `summary.model` の
config デフォルト値（例: `claude-haiku-4-5-20251001`）を body にそのまま送っても、実際に応答したモデル
（例: `gpt-5.4-nano`）とは一致しない。これを `llm_usage.jsonl` / `refined.jsonl` にそのまま記録すると
「gpt が使えていないのでは」という誤解を招く。

`OpenAIChatBackend.parseResponse` はレスポンス body 自身の `model` フィールドを読み、
`LLMBackendResponse.respondedModel` → `LLMResult.respondedModel` として `UsageRecordingLLM` /
`RefinementQueue` まで伝播させる。解決順（`OpenAIChatBackend.resolveRespondedModel`）:

1. レスポンス body の `model`（非空なら最優先。実際に応答したモデル）
2. `llm.openai.model`（非空なら。config 側の明示オーバーライド）
3. `base_url` の `/deployments/<name>` から抽出したデプロイ名
4. `request.model`（= `refinement.model` / `summary.model` の config デフォルト。最終フォールバック）

`ClaudeCLIBackend` は実応答モデルを返す手段がない（CLI の JSON envelope に `model` フィールドがない）ため
`respondedModel` は常に `nil` で、`request.model` を記録する既存挙動のまま変わらない。

## 3. 記録経路: `UsageRecordingLLM`（decorator）

`docs/design/12-llm-client.md` §8 の不変条件「`LLMClient` はセッション永続化に触れない」を守るため、
`LLMClient` 本体ではなく `LLMCompleting` の decorator で記録する。

```swift
struct UsageRecordingLLM: LLMCompleting {
    let base: LLMCompleting          // 本番は LLMClient.shared
    let sessionHandle: SessionHandle
    func complete<T>(_ request: LLMRequest) async throws -> LLMResult<T> {
        let result = try await base.complete(request)
        // 記録失敗は warning ログのみ。LLM 呼び出し自体は絶対に失敗させない
        try? await sessionHandle.appendLLMUsageRecord(...)
        NotificationCenter.default.post(name: .kikimiLLMUsageRecorded, ...)
        return result
    }
}
```

- 注入箇所は `MeetingWorkspaceViewModel+Factories.swift` の
  `defaultSummaryUpdaterFactory` / `defaultRefinementQueueFactory`（`LLMClient.shared` を包むだけ）。
  `RefinementQueue` / `SummaryUpdater` 本体は無変更
- スタブモード（`KIKIMI_STUB_LLM=1`）ではゼロ usage の行が記録される。kikimi-verify で記録経路自体を検証できるので許容
- ヘルスチェックは `LLMClient` 直呼びなので記録対象外（セッションに紐付かない）

## 4. コスト計算: `LLMPricing`

行ごとのコスト = `reported_cost_usd`（非 null なら優先）、無ければ価格表から推定:

```
cost = (input × in + output × out + cache_read × cr + cache_creation × cw) / 1_000_000
```

- **内蔵価格表**（USD / 1M tokens、モデル id の前方一致・最長一致）
  - Anthropic 系は cache read = 0.1×input、cache write = 1.25×input（5 分 TTL）
    - `claude-haiku-4-5`: 1.00 / 5.00、`claude-sonnet-4-5` / `-4-6` / `claude-sonnet-5`: 3.00 / 15.00、
      `claude-opus-4-5`〜`-4-8`: 5.00 / 25.00、`claude-fable-5`: 10.00 / 50.00
  - OpenAI / Azure OpenAI 系は cache read = 公表の cached-input 価格、**cache write = input（キャッシュ生成の割増なし）**。
    2026-07 に OpenAI 公式で確認（Azure Global Standard は同一トークン単価）。input / cached / output:
    - `gpt-4.1`: 2.00 / 0.50 / 8.00、`gpt-4.1-mini`: 0.40 / 0.10 / 1.60、`gpt-4.1-nano`: 0.10 / 0.025 / 0.40
    - `gpt-4o`: 2.50 / 1.25 / 10.00、`gpt-4o-mini`: 0.15 / 0.075 / 0.60
    - `o3`: 2.00 / 0.50 / 8.00、`o4-mini`: 1.10 / 0.275 / 4.40、`o3-mini`: 1.10 / 0.55 / 4.40
    - `gpt-5`: 1.25 / 0.125 / 10.00、`gpt-5-mini`: 0.25 / 0.025 / 2.00、`gpt-5-nano`: 0.05 / 0.005 / 0.40
    - `gpt-5.4`: 2.50 / 0.25 / 15.00、`gpt-5.4-mini`: 0.75 / 0.075 / 4.50、`gpt-5.4-nano`: 0.20 / 0.02 / 1.25、`gpt-5.5`: 5.00 / 0.50 / 30.00
  - Azure の legacy-deployments 運用でモデル id がデプロイ名（例 `gpt-4o-xxx`）になっても、実モデル id で始まれば上表で解決される。実モデル id で始まらないデプロイ名は従来どおり `llm.pricing` 上書きが必要
- **config 上書き**: `llm.pricing`（内蔵より優先。Azure OpenAI のデプロイ名運用向け）

```yaml
llm:
  pricing:
    gpt-4o:              # モデル id の前方一致
      input: 2.5         # 必須。USD / 1M tokens
      output: 10.0       # 必須
      cache_read: 1.25   # 省略時 input × 0.1
      cache_write: 2.5   # 省略時 input × 1.25
```

- 価格表に無いモデルで `reported_cost_usd` も無い行はコスト不明として集計から除外し、
  不明件数（`unknownCostCallCount`）を別カウントで UI に出す

## 5. 集計と UI

- `LLMUsageAggregator.summarize(records:configPricing:)` → `LLMUsageSummary`
  （全体 + purpose 別の `LLMUsageTotals`: 呼び出し数 / 各 token 数 / コスト / コスト不明件数）
- セッションウィンドウのヘッダ（録音コントロールの左）に **コストバッジ**（例: `$0.0123`）。
  呼び出しが 1 件以上あるときだけ表示。クリックで popover に内訳
  （用途別コスト、input / output / cache read / cache write token 数、コスト不明件数）
- 更新契機: `UsageRecordingLLM` が記録後に `Notification`（`kikimiLLMUsageRecorded`、userInfo に sessionId）を post →
  `MeetingWorkspaceViewModel` が自セッション宛のみ `llm_usage.jsonl` を再読込して `@Published llmUsageTotals` を更新。
  呼び出し頻度は高々バッチ毎（数秒に 1 回）なので全読みで十分

### セッション横断の全体集計（Session List フッター）

Session List ウィンドウのフッター左端に、**全セッション・全期間合計**のコストバッジを表示する
（月別・セッション別の内訳は持たない。全体の目安が分かれば十分という判断）。

- `SessionStore.readAllLLMUsageRecords()` が `sessions/` 直下の全セッションディレクトリの
  `llm_usage.jsonl` を読み、`LLMUsageAggregator.summarize(records:configPricing:)` で集計する
- **`openSession(_:)` は使わない**: 全セッション分の `SessionHandle` をキャッシュに載せてしまい、
  かつ `ensureTranscriptAndRefinedLogFilesExist()` が今回一度も開いていないセッションにまで空の
  `transcript.jsonl`/`refined.jsonl` を作ってしまう副作用があるため。`SessionStore
  .sessionDirectoryURLs()`（`listSessions()` と同じディレクトリ列挙ロジック）でセッションフォルダを
  直接列挙し、`llm_usage.jsonl` を直接読む
- JSONL のパース（壊れた行のスキップ耐性含む）は `SessionHandle.readLLMUsageRecords()` と同じ
  `LLMUsageJSONLFile.read(from:loggingContext:)` を共有する（`SessionHandle+LLMUsage.swift`）。
  読めないセッションは 1 件スキップしログを出し、残りは集計に含める（`listSessions()` の
  「1 件壊れていても残りは返す」方針と同じ）
- `llm_usage.jsonl` が無いセッション（LLM を一度も呼んでいない）は 0 件として扱う
- 表示は `LLMUsageBadge` をそのまま再利用（`accessibilityLabel` 引数だけ「LLM 使用状況（全体）」に
  変えて、セッションウィンドウ側のヘッダバッジと AX 上区別できるようにする）。呼び出しが 1 件以上
  あるときだけ表示する
- 更新契機はセッションウィンドウ側と同じ `.kikimiLLMUsageRecorded` 通知（`SessionListViewModel
  .startObservingLLMUsage()`）。ただしこちらは全セッション対象なので `sessionId` によるフィルタは
  しない。呼び出し頻度は高々バッチ毎なので全読み・全集計で十分という判断も同じ

## 6. 失敗モード

| 状況 | 挙動 |
|---|---|
| 記録の append 失敗 | warning ログのみ。LLM 結果は正常に返す（整形・サマリに波及させない） |
| LLM 呼び出し失敗 | 記録しない（usage が無い。リトライ成功時にその分だけ記録される） |
| `llm_usage.jsonl` の壊れた行 | transcript.jsonl と同じ「1 行スキップして残りを読む」耐性 |
| 価格不明モデル | コスト集計から除外 + 不明件数として表示 |

## 7. テスト

- `LLMPricing`: 前方一致解決（内蔵 / config 優先）、cache 込みコスト計算、省略フィールドの既定値
- `UsageRecordingLLM`: 成功時に 1 行追記・purpose = stubKey・通知 post、LLM エラー時は記録なし
- `SessionHandle+LLMUsage`: append → read の等価性、壊れた行の耐性
- `LLMUsageAggregator`: reported 優先・推定フォールバック・不明カウント・purpose 別集計
- `SessionStore+LLMUsage`: `readAllLLMUsageRecords()` がセッション横断で全件返すこと・
  `llm_usage.jsonl` が無いセッションは 0 件扱い・壊れた行のスキップ耐性・sessions ルート未存在で
  空配列を返すこと
