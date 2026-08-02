# 44. LLM モデル設定（名前付きプロバイダ・モデル定義・機能別割り当て）詳細設計

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `docs/design/14-llm-provider.md`（LLMBackend 抽象。本ドキュメントはその発展）、
`docs/design/12-llm-client.md`（LLMClient / LLMRequest）、`docs/design/26-settings-ui.md` §4.3
（ModelSettingsTab）、`docs/design/35-secure-enclave-credentials.md`（credential 保存）、
`summary-quality-topics-and-final-pass.md` §7.5 / §12-3（`finalPass(modelOverride:)` の口と
手動再実行 UI の Open Question）、`kikimi.md` 7・8・9・12 章。

**結論（変更の全体像)**: 「プロバイダはグローバル単一選択・モデルは機能別の素の文字列」という
現行体系を、次の 4 点で「機能別にプロバイダ・モデル・パラメータを選べる」体系に改める。

1. **名前付きプロバイダ**: `llm.provider`（単一選択）を `llm.providers`（名前付き複数定義）に
   拡張し、`LLMClient` を単一 backend からプロバイダ名 → `LLMBackend` のレジストリに変える
2. **モデル定義（alias）**: `llm.models` に用途別の名前付きモデル（`auto` / `premium` +
   自由追加）を定義する。モデル単位パラメータ（`effort` / `timeout_seconds`）はここに持たせる
3. **機能別割り当てと解決規則**: 機能側の `model` フィールドを ModelRef 文字列
   （alias 名 | `provider/model` | 素のモデル名）に拡張し、解決を pure な `ModelResolver` に
   集約する。`summary.final_model` を新設して最終整形パスを分離する
4. **手動 override UI**: サマリ全文再生成・最終整形パス再実行・チャットに、alias 一覧から
   モデルを選んで実行する UI を付ける（`RequestKind.finalPass(modelOverride:)` の口を活かし、
   `regeneration` にも同型の口を追加する）

実装は 3 Phase に分割する（§12）。既存 config.yaml はマイグレーション（§4）により無変更で動く。

## 1. 目的とスコープ

**動機**（ユーザー要件）:

- 自動実行される処理（増分サマリ・refinement・watcher 自動実行・dictation refine）は安価な
  モデルで回し、手動操作（再生成・最終整形の再実行・チャット）は上位モデルを選べるようにする。
  典型ユースケース: 会議中にサマリが壊れてきたら、上位モデル指定で全文再生成する
- 機能ごとにプロバイダ（Claude CLI / OpenAI 互換）とモデルを個別指定できるようにする。
  現行は `llm.provider` がグローバル単一で、さらに `llm.openai.model`（非空なら全呼び出し上書き。
  `Kikimi/LLM/OpenAIChatBackend.swift` の `resolveModel`）が機能別 `model` フィールドを
  実質無効化している

**不変条件（変えないもの）**:

- 消費側 seam（`LLMCompleting` / `LLMResult` / `LLMUsage`）のシグネチャは変えない。
  `LLMRequest` へのフィールド**追加**のみ許す（§5.1。既存フィールドの意味は不変）
- スタブモード（`KIKIMI_STUB_LLM=1`）はプロバイダ選択より前段で分岐する（従来どおり）
- どのエラーでも呼び出し側は「今回の呼び出しをスキップして継続」できる（12 章 §4.1 の思想）
- config.yaml が常に正で、Settings UI はその編集ビュー（`AppConfig.binding` 直書き +
  watchForChanges）という構造（26 章 §4.1）

**スコープ外**:

- 実行中のプロバイダ接続設定の動的反映（14 章 §7 の割り切りを維持。§5.2 参照）
- `llm.pricing` の UI 化・プロバイダ別名前空間化（§13 Open Question）
- Watcher frontmatter `model:` の文法拡張以外の Watcher 仕様変更

## 2. config スキーマ

### 2.1 `llm:` セクション（改訂後）

```yaml
llm:
  providers:                       # 名前付きプロバイダ。キーはユーザーが決める識別子
    claude:
      kind: claude-cli             # claude-cli | openai
      cli_path: null               # claude-cli 固有（現 llm.claude.cli_path と同じ）
    azure:
      kind: openai
      base_url: https://<res>.openai.azure.com/openai/deployments/gpt-5.4-mini
      api_key_env: ""              # API キー本体は credential store（§6）。これは逃げ道
      api_version: "2024-10-21"
      model: gpt-5.4-mini          # 非空ならこのプロバイダ経由の呼び出しのモデルを固定
                                   # （現 llm.openai.model と同義。スコープがプロバイダ内に縮む）
      auth_header: ""
      reasoning_effort: none       # プロバイダ既定の effort。モデル定義の effort が優先（§3.3）

  models:                          # 名前付きモデル定義（alias）。UI のモデル選択候補にもなる
    auto: azure/gpt-5.4-mini       # 文字列短縮形（"provider/model"）
    premium:                       # 構造化形式（パラメータ付き）
      provider: claude
      model: claude-sonnet-5
      effort: high                 # 任意。claude-cli → --effort / openai → reasoning_effort
      timeout_seconds: 300         # 任意。機能側の既定タイムアウトを上書き

  default: auto                    # 機能側が未指定・不正値のときの既定（alias 名）

  pricing: {}                      # 変更なし（モデル名 → 単価。UI 化しない）
```

- `providers` の値は `kind` で判別する tagged 形式。`kind: claude-cli` は `cli_path` のみ、
  `kind: openai` は現 `OpenAIBackendConfig` のフィールド群（`api_key` 直書きフィールドは
  後方互換 decode のみ残し、新規書き込みはしない — 35 章の credential store が正）
- **プロバイダ名は `[A-Za-z0-9_-]+` に制約する**（decode 時に検証。Profiles の id 検証と同じ
  パターン）。理由: 名前は credential account 文字列（§6）に埋まり、
  `CredentialFileLayout.fileName` が非許可文字を `_` に潰すため、無制約だと `my/prov` と
  `my_prov` が同一ファイルに衝突して API キーを共有・上書きし得る。不正名のプロバイダは
  warning + レジストリ除外（未知 `kind` と同じ扱い）
- プロバイダの `model` 固定（`providers.<name>.model` 非空）は alias のモデル指定を打ち消す。
  解決結果のモデル名と食い違う場合は呼び出し時に warning を出す（「premium を選んだのに
  デプロイ固定で別モデルが応答する」を無音にしない。Azure legacy の deployment URL でも
  同種の打ち消しが起きる点を Settings の注記で顕在化する。§9）
- `models` の各値は「文字列（短縮形）」または「オブジェクト」の 2 形式。decode は文字列を先に
  試し、失敗したらオブジェクトとして decode する（`JSONValue` 等と同じ両対応パターン）。
  文字列短縮形は §3.1 の規則 2（`provider/model`）・規則 3（素のモデル名）で解釈する。
  **alias 値は再帰的に alias を参照できない**（規則 1 は適用しない。1 段展開のみ。
  循環を構造的に排除する）
- **予約名は設けない**（当初案の `auto` / `premium` 予約は UI レビューで撤回）。モデル定義は
  すべて対等で、どの行も削除・rename 可。`llm.default` が指す定義が無ければ warning +
  builtin 既定へフォールスルー（§3.2 段 5）するため、削除で壊れることはない
- **`llm.default` は Settings では「デフォルトにする」チェックとして表示する**（§9）。
  チェックされた定義の名前が `llm.default` に書かれる、という UI 糖衣であり schema は変えない。
  UI 上のモデル定義は provider・model とも必須（YAML 手編集では従来どおり lenient）
- 既存セクションと同じ流儀: partial デコード許容、不正値は warning + フォールバック。
  未知の `kind` を持つプロバイダは warning を出して**レジストリから除外**する
  （そのプロバイダを参照する呼び出しは §3.2 のフォールスルーで default に落ちる)

### 2.2 機能別フィールド（改訂後）

| フィールド | 値（ModelRef 文字列） | 変更点 |
|---|---|---|
| `refinement.model` | `auto` 等 | 意味が ModelRef に広がる（後方互換は §3.1） |
| `summary.model` | `auto` 等 | 同上。増分更新・全文再生成・final title が使う |
| `summary.final_model` | `premium` 等 | **新設**。最終整形パス専用。未指定なら `summary.model` |
| `chat.model` | `premium` 等 | 意味が広がるのみ |
| `watchers.default_model` | `auto` 等 | 同上。Watcher frontmatter `model:` も同文法で解釈 |
| `dictation.model` | 空 | **新形式 config のみ**、空のフォールバック先を `watchers.default_model` から `llm.default` に変更。旧形式（sentinel default。§4）は `watchers.default_model` に据え置く（§13-3 の決定） |

### 2.3 config.yaml サンプル全体（kikimi.md 12 章へ反映する差分）

```yaml
llm:
  providers:
    claude:
      kind: claude-cli
      cli_path: null
  models:
    auto: claude/claude-haiku-4-5-20251001
    premium: claude/claude-sonnet-5
  default: auto

refinement:
  model: auto
summary:
  model: auto
  final_model: premium
chat:
  model: premium
watchers:
  default_model: auto
dictation:
  model: ""
```

## 3. ModelRef と解決規則（`ModelResolver`）

### 3.1 文法と正規化

機能側フィールド・Watcher frontmatter・手動 override が持つ ModelRef 文字列は、次の順で解釈する。

1. **alias 名**: `llm.models` のキーに完全一致 → その定義に展開
2. **`provider/model`**: 最初の `/` で分割し、前半が `llm.providers` のキーに一致 →
   そのプロバイダ + 残り全部をモデル名とする（モデル名に `/` を含んでよい）
3. **素のモデル名**: 上記いずれでもない → 「default の解決結果のプロバイダ + この文字列」と
   解釈する（**後方互換の要**: 既存 config の `claude-haiku-4-5-20251001` 等はこの経路で
   従来と同じ動作になる）。default から借りるのは**プロバイダ名のみ**で、default alias が持つ
   params（effort / timeout）は継承しない（後方互換経路のため従来挙動を変えない）

alias 名とプロバイダ名が衝突している場合は alias が勝つ（decode 時に warning を出す）。
builtin 暗黙 `claude` プロバイダ（§3.2 段 5）とユーザー定義の同名プロバイダが衝突した場合は
明示定義が勝つ。

### 3.2 解決の優先順位

解決は pure function に集約する（新規 `Kikimi/LLM/ModelRef.swift`）。

```swift
struct ResolvedModel: Sendable, Equatable {
    var provider: String        // llm.providers のキー
    var model: String           // backend に渡すモデル名
    var params: LLMCallParams
}

enum ModelResolver {
    /// candidates: 優先順の ModelRef 候補列（先頭が最優先）。各候補は nil・空文字列・
    /// 不正（未定義 alias / availableProviders に無いプロバイダ参照）のとき次候補へ落ちる
    /// （nil・空以外の不正には warning を出す）。全候補が尽きたら `llm.default` →
    /// builtin 既定の順で確定する。
    /// availableProviders: LLMClient レジストリの起動時スナップショット由来のプロバイダ名
    /// 集合（builtin 暗黙 `claude` を含む。§5.2）。プロバイダ存在検証は live config の
    /// `llm.providers` ではなく必ずこの集合に対して行う。
    static func resolve(
        candidates: [String?],
        config: LLMConfig,
        availableProviders: Set<String>
    ) -> ResolvedModel
}
```

| 優先 | 段 | 内容 |
|---|---|---|
| 1 | 呼び出し時 override | UI で選んだ `ResolvedModel`（§8。クリック時点で解決済みのため resolver は通らない） |
| 2 | 機能内の特化設定 | `summary.final_model`、Watcher frontmatter `model:`（`candidates` の先頭要素） |
| 3 | 機能別設定 | `refinement.model` / `summary.model` / `chat.model` / `watchers.default_model` / `dictation.model`（`candidates` の後続要素） |
| 4 | `llm.default` | alias 名。未指定・不正なら次段（resolver 内部で処理） |
| 5 | builtin 既定 | `kind: claude-cli` の暗黙プロバイダ + `claude-haiku-4-5-20251001`（同上） |

- 段 2・3 は呼び出し側が**候補列**として渡す（例: finalPass は
  `candidates: [config.finalModel, config.model]`、watcher は
  `[definition.model, watchersDefaultModel]`、特化設定の無い機能は単要素 `[config.model]`）。
  `finalModel ?? model` のような **nil 合体で畳んでから単一値を渡す形は禁止**: nil 合体は
  「未設定」しか扱えず、段 2 が「定義済みだが不正な alias」のとき段 3 を飛ばして段 4 へ
  直行してしまい、この表の意味論（各段は不正値のとき次段へ落ちる）を実装できない。
  不正判定（alias 未定義・プロバイダ不在）は resolver にしかできない（§11 の
  「候補列フォールスルー」テストで担保する）
- プロバイダの存在検証を `availableProviders`（レジストリの起動時スナップショット。§5.2）に
  対して行うのは、resolver が見る `llm.models` / `llm.default` / 機能別フィールドは live
  config なのに backend レジストリは起動時固定、という非対称を吸収するため。
  「Settings でプロバイダ追加 → alias に割り当て → 再起動せず新セッション」という操作では
  該当候補が warning + フォールスルーで処理され、実行時の `unknownProvider`（§5.2）には
  到達しない

各段は「空文字列・未定義 alias・`availableProviders` に無いプロバイダ参照」のとき warning
ログを出して次段へ落ちる。builtin 既定（段 5）は `llm.providers` が空でも成立する（`claude`
という名前の claude-cli プロバイダを暗黙に用意する。既存の「config なしで動く」性質を保つ）。

### 3.3 パラメータ（`LLMCallParams`）の解決

```swift
struct LLMCallParams: Sendable, Equatable {
    var effort: String?         // 検証しないパススルー値（"low"|"medium"|"high" 等）
    var timeoutSeconds: Int?
}
```

- **持ち場所はモデル定義（`llm.models` のオブジェクト形式）に限定する**。機能側の
  `provider/model` 直指定にはパラメータを付けられない — 付けたければ名前付きモデルを定義する
- `effort` の優先順位: モデル定義の `effort` → プロバイダの `reasoning_effort`（openai のみ、
  既存フィールドをプロバイダ既定に降格）→ 指定なし
- `timeout_seconds` は**延長専用**: 実効タイムアウト =
  `max(機能側の明示値または LLMRequest 既定 60 秒, モデル定義の timeout_seconds)`。
  モデル定義が機能側より短くても短縮はしない — 「上位モデルに短い timeout を書いたせいで
  final pass（機能側 300 秒）が必ず `timedOut` する」という、特化設定が一般設定に負ける
  逆転事故を構造的に排除する。延長側（premium 300 秒でチャットも最大 300 秒待つ）は
  「実際に応答が遅いときだけ長く待つ」だけなので許容する

## 4. マイグレーション（旧 config の読み替え）

`LLMConfig` の lenient decoder 内で行う。**config.yaml への書き戻しはしない**（読み替えのみ。
ユーザーが新形式で保存し直した時点で自然に移行する。`AppConfig` の既存方針と同じ）。

| 旧 | 新（読み替え結果） |
|---|---|
| `llm.provider: claude-cli` + `llm.claude` | `providers.claude = {kind: claude-cli, cli_path: ...}`、`default` → `claude` を指す合成 alias |
| `llm.provider: openai` + `llm.openai` | `providers.openai = {kind: openai, ...}`（`reasoning_effort` 含む）、`default` → `openai` を指す合成 alias |
| 機能側の素のモデル名 | §3.1-3 の経路で「default のプロバイダ + そのモデル名」に解決（挙動不変） |
| `llm.openai.model`（全上書き） | `providers.openai.model` として維持（スコープがプロバイダ内に縮む。単一プロバイダ運用なら挙動不変） |
| `dictation.model` 空のフォールバック | **新形式 config のみ** `llm.default` に変更。旧形式（sentinel default）は `watchers.default_model` に据え置く（下記。sentinel はモデル名を持たず段 4 が成立しないため）。Phase 1 完了報告に明記 |

合成 alias の形: 旧形式検出時は `models` に `auto: <旧provider>/<空>` を作らず、
`default` を「旧 provider を指す内部 sentinel」として保持する（素のモデル名解決のためだけに
プロバイダ名が要る。モデル名部分は機能側フィールドが持っているため不要）。実装上は
`LLMConfig.defaultProviderName: String` を decode 結果として持てば足りる。

**sentinel の限界と dictation の例外**: sentinel はプロバイダ名しか持たずモデル名が無いため、
段 4（§3.2）として「モデル名まで確定する」用途には使えない（素のモデル名解決へのプロバイダ供給
専用。alias としては不正扱いで段 5 へ落ちる）。旧形式では機能側フィールドが常にモデル名を持つ
ので、段 4 にモデル名まで要求するのは `dictation.model` 空のケースだけ。ここで段 5 builtin
（claude-cli + haiku）まで落とすと、旧 openai 単独構成の dictation refine が
`watchers.default_model` の gpt 系モデルから claude CLI + haiku に切り替わる regression になる
（CLI 未導入なら毎回失敗）。そこで**旧形式検出時（sentinel default）に限り、dictation の候補列を
`[dictation.model, watchers.default_model]` としてフォールバック先を従来どおり
`watchers.default_model` に据え置く**（新形式 config では `[dictation.model]` → `llm.default`）。
判定は decode 結果の `LLMConfig.isLegacySentinelDefault: Bool`（`defaultProviderName` の有無で
決まる派生値でよい）を `DictationRefiner` 側の候補列構築で参照する。

新旧混在（`providers` と `provider` が両方ある）は新形式を採り、旧キーは無視 + warning。

## 5. LLM 層の変更

### 5.1 `LLMRequest`（フィールド追加のみ）

```swift
struct LLMRequest: Sendable {
    // 既存フィールドは不変（model は「解決済みモデル名」のまま）
    /// 解決済みプロバイダ名（llm.providers のキー）。nil は default プロバイダ。
    /// `= nil` の既定値が後方互換の条件そのもの（既存テスト・スタブ経路を無変更で通す）。
    var provider: String? = nil
    var params: LLMCallParams = .init()
}
```

呼び出し側は `ResolvedModel` から `model` / `provider` / `params` を詰める。ヘルパ
`LLMRequest.init` の便宜 extension（`resolved:` を受ける）を用意してよい。

### 5.2 `LLMClient` のバックエンドレジストリ

`Kikimi/LLM/LLMClient.swift` の単一 `backend` を廃し、レジストリにする。

```swift
actor LLMClient: LLMCompleting {
    private let providerConfigs: [String: LLMProviderConfig]  // 起動時スナップショット
    private var backends: [String: LLMBackend] = [:]          // 遅延構築キャッシュ

    private func backend(for name: String?) throws -> LLMBackend
}
```

- **遅延構築**: プロバイダの backend は初回使用時に構築してキャッシュする。使われない
  プロバイダの backend を作らないためのもの（credential の遅延読み出し自体は既に
  `OpenAIChatBackend` の `LazyAPIKey` が初回呼び出しまで遅延しており、本設計の新規性ではない）
- **起動時スナップショット**: `providerConfigs` は `LLMClient.shared` 構築時の
  `AppConfig.shared.data.llm` から取る。**プロバイダ接続設定の追加・変更の反映は従来どおり
  アプリ再起動**（14 章 §7 の割り切りを維持）。一方 `llm.models` / `llm.default` /
  機能別フィールドの変更は呼び出し側が live な `AppConfig` から解決するため、
  再起動不要（反映粒度は §7 の表）
- **スナップショットのプロバイダ名集合を公開する**:
  `nonisolated let availableProviders: Set<String>`（`providerConfigs` のキー + builtin 暗黙
  `claude`。未知 `kind` で除外されたプロバイダは含まない）。§3.2 の resolver はプロバイダ
  存在検証を live config ではなく必ずこの集合に対して行う。live config とレジストリの
  スナップショットの非対称（Settings でプロバイダ追加 → alias 割り当て → 再起動せず
  新セッション、で resolver だけが新プロバイダを知っている状態）はここで吸収され、解決時の
  warning + フォールスルーに収束する。再起動前に追加したプロバイダは解決候補にも
  UI ピッカー（§8・§9）にも現れない
- 未知のプロバイダ名は新設エラー `LLMClientError.unknownProvider(name: String)`。
  `RefinementQueue+BatchProcessing.isFatal` に追加する（`missingAPIKey` と同じ設定不備分類）。
  resolver が `availableProviders` に対して検証する（上記）ため、正規経路からは到達しない。
  DI の組み立てミスや将来の「resolver を通さない呼び出し」追加漏れに対する最終防衛線として
  のみ残す
- `init(backend:)`（テスト・DI 用）は「default プロバイダとして 1 件登録」に読み替えて維持。
  レジストリ dispatch のテスト seam として `init(backends: [String: LLMBackend])` を追加する
  （§11）。スタブ分岐はレジストリ参照より前段（不変条件）
- `healthCheck(model:)` → `healthCheck(resolved: ResolvedModel)` に改める（後方互換の
  既定引数で現行呼び出しを壊さない）。healthCheck は現状 UI 未配線の primitive
  （`LLMTypes.swift` の doc comment どおり）であり、**配線は本設計でも引き続きスコープ外**。
  将来配線する際は「機能別割り当てが実際に参照しているプロバイダの集合」を probe する
  （未使用プロバイダは叩かない。probe はプロバイダ数ぶんの実呼び出しになる点に注意）

### 5.3 バックエンドのパラメータ写像

- `ClaudeCLIBackend.buildArguments`（`Kikimi/LLM/ClaudeCLIBackend.swift:45`）:
  `request.params.effort` が非 nil のとき `["--effort", value]` を**末尾に追加**する。
  nil なら引数列は現行と 1 バイトも変わらない（「検証済みの CLI 呼び出し形を壊さない」
  14 章 §2 の方針。既存テストのアサーションは不変、effort 付きケースを追加）
- `OpenAIChatBackend`: ボディの `reasoning_effort` を
  「`request.params.effort` → プロバイダ config の `reasoning_effort` → 省略」の順で決める
  （現行のプロバイダ値のみ → 2 段に拡張）
- `timeoutSeconds` は backend に渡る前に `LLMRequest.timeout` へ反映する（呼び出し側 or
  `ResolvedModel` → `LLMRequest` 変換ヘルパの責務。backend は現行どおり `request.timeout` を
  見るだけ）
- 未知・非対応パラメータは warning + 無視（例: claude-cli に対する将来の openai 固有値）。
  古い claude CLI が `--effort` を解さない場合は `processFailed`（非 fatal）に落ちる。
  専用検出はしない（healthCheck が配線されれば起動時に顕在化する。§5.2）

## 6. API キー解決（credential store）

35 章の `EncryptedFileCredentialStore`（account = config キーパス文字列）をプロバイダ別に使う。

- 新 account 形式: `llm.providers.<name>.api_key`
- 解決順（`OpenAIChatBackend` 構築時、プロバイダごと）:
  1. credential store の `llm.providers.<name>.api_key`
  2. **レガシー migration**: 1 が空で、かつ該当プロバイダが §4 の旧形式読み替え由来
     （名前 `openai`）なら、旧 account `llm.openai.api_key`（`CredentialAccount.openAIAPIKey`）
     を読み、非空なら新 account へ書き写して旧を削除する（`EncryptedFileCredentialStore` の
     `migrateFromLegacyStore` と同じ「コピー → 削除、失敗は次回リトライ」パターン）
  3. config の `api_key` 直書き（後方互換フォールバック。新規書き込みはしない）
  4. `api_key_env` の環境変数
  5. すべて空 → `LLMClientError.missingAPIKey`
- `CredentialAccount` に `static func providerAPIKey(name: String) -> String` を追加。
  プロバイダ名は account 文字列に埋まるため、**Settings でのプロバイダ rename は credential の
  move を伴う**（§9）

## 7. 呼び出し側の変更と反映粒度

| 機能 | 現行の model 取得 | 変更 | 設定変更の反映 |
|---|---|---|---|
| refinement | `config.model`（`RefinementQueue+BatchProcessing.swift:28`。session 開始時スナップショット） | Factories（`MeetingWorkspaceViewModel+Factories.swift`）で `ModelResolver.resolve` した `ResolvedModel` をスナップショット | 次セッションから |
| summary 増分 / regeneration / final title | `config.model`（`SummaryUpdater.swift:479` ほか） | 同上（`SummaryConfig` に `resolvedModel` を持たせる） | 次セッションから |
| summary finalPass | `modelOverride ?? config.model`（`+FinalPass.swift:98`） | `modelOverride`（解決済み `ResolvedModel`）があればそのまま使用。無ければ `resolve(candidates: [config.finalModel, config.model])`（nil 合体で畳んでから渡すのは禁止。§3.2）。`SummaryConfig` に `finalModel: String?` 追加 | 次セッションから |
| chat | `config.model`（`ChatRunner.swift:77`） | Factories で解決してスナップショット。手動ピッカー（§8）は呼び出し時解決 | 次セッションから（ピッカーは即時） |
| watcher | `definition.model ?? defaultModel`（`WatcherRunner.swift:273`） | 候補列 `[definition.model, watchersDefaultModel]` として実行時に解決（nil 合体しない。Watcher は preset リロードがあるため実行時解決が自然）。現行は `defaultModel: String` を init でスナップショットしているため、construction を「候補列を解決する closure 注入」に変える | 次回実行から |
| dictation refine | `resolveModel(dictationModel:watchersDefaultModel:)`（`DictationRefiner.swift:133`） | `ModelResolver` 呼び出しに置換。候補列は新形式 config で `[dictation.model]`（空 → `llm.default`）、旧形式（sentinel default）で `[dictation.model, watchers.default_model]`（§4） | 次回 refine から |

いずれの呼び出しも `availableProviders` には `LLMClient.shared.availableProviders`（§5.2）を
渡す（live config の `llm.providers` を渡してはならない。§3.2）。

`RequestKind`（`SummaryUpdater.swift:281`）の変更:

```swift
case regeneration(modelOverride: ResolvedModel?)   // 関連値を追加（finalPass と同型）
case finalPass(modelOverride: ResolvedModel?)      // String? → ResolvedModel? に変更
```

`modelOverride` の型を `String?` から `ResolvedModel?` に変える（呼び出し元は現状すべて nil
なので破壊なし）。coalescing・優先順位（regeneration → finalPass → …）は不変。regeneration の
pending フラグは Bool から payload 付きに変わるが、coalescing 規則は既存 `pendingFinalPass` と
同じ**後勝ち（last-writer-wins）で modelOverride を上書き**する。

usage 記録: `UsageRecordingLLM` / `RefinementQueue` が書く `llm_usage.jsonl` レコードに
`provider` フィールドを追加する（optional。旧レコードは欠落のまま読める。プロバイダ間で
モデル名が衝突しても集計を分けられるようにする）。

## 8. 手動 override UI（Phase 2）

メニュー候補は共通ヘルパ `ModelMenuItems.build(config:)` で生成する:
`デフォルト（機能の割り当て値を表示）` + `llm.models` の全モデル定義（名前順）。
**LLM API のモデル名を直接入力する項目は置かない** — モデルはすべて Settings のモデル定義を
経由させる（定義されていないモデルを一時的に使いたいケースは、定義を 1 行足せば足りる。
入力 UI の重複と検証の分散を避ける）。

| 操作 | UI | 配線 |
|---|---|---|
| サマリ全文再生成 | `SummaryTabView` の再生成ボタンを `Menu` 化（デフォルト / モデル定義名） | `regenerateSummary(modelOverride: ResolvedModel?)` → `regenerateFromScratch(modelOverride:)` → `.regeneration(modelOverride:)` |
| 最終整形パス再実行 | Ended セッションのサマリタブに「最終整形を再実行 ▾」を新設 | transient updater（`+Recording.swift` の Paused→Ended 分岐と同じ factory）を作って `runFinalPass(modelOverride:)`。実行中はボタン disabled + progress。**注**: 再起動後に開いた Ended セッション（live でない）への transient updater 構築と progress 表示は既存に対応物がなく、この行が Phase 2 の実装量の大半を占める見込み |
| チャット | 入力欄脇に小型ピッカー（既定 = `chat.model` の解決結果） | 選択は `MeetingWorkspaceViewModel` のセッション中 state（永続化しない）。`ChatRunner.ask` に `modelOverride` 引数を追加 |

- override の解決は**クリック時点**の live config（`llm.models` / `llm.default`）で行う
  （スナップショットではない）。会議中に Settings で premium の中身を変えたら次のクリックから
  効く。ただしプロバイダ存在検証は §3.2 と同じく `LLMClient.shared.availableProviders`
  （起動時スナップショット）に対して行い、「モデルを指定して実行…」シートのプロバイダ Picker の
  候補もこの集合から出す。再起動前に追加したプロバイダを参照する alias を選んだ場合は
  warning + フォールスルーになる（実行は止まらない）
- メニューの「既定」項目が表示するモデル名は**セッション開始時スナップショットの解決結果**
  （§7 で Factories が固定した値）にする。live config から表示すると、nil override 時に実際に
  使われる値（スナップショット）と表示が乖離し得るため
- watcher 手動実行（今すぐ実行）には付けない（frontmatter `model:` が既に個別の口。
  必要になったら同じメニューを足せる形だけ保つ）

## 9. Settings「モデル」タブ再構成（Phase 3）

現行 3 セクション（プロバイダ / モデル / バッチ整形。`ModelSettingsTab.swift`）を 4 つに再編。

- **プロバイダ**: 名前付き一覧（list + detail。glossary カテゴリ編集と同じパターン）。
  行選択で `kind` に応じた接続フィールドを表示。API キーは既存の draft 方式
  （`SettingsViewModel` 保持・`onSubmit`/`onDisappear` で永続化）をプロバイダ別 account に
  一般化する。**rename は「models の参照書き換え + credential move」を 1 つの `update {}` で
  原子的に行う**。削除時は参照している alias に warning バッジを出す。
  「接続設定の変更・追加はアプリ再起動後に反映（追加したプロバイダが解決・ピッカー候補に
  現れるのも再起動後。§5.2）」の注記を表示
- **モデル定義**: `llm.models` の一覧編集。各行 = 定義名 + プロバイダ Picker（**必須**。
  空選択なし。プロバイダ未定義なら「先にプロバイダを追加」の案内）+ モデル名 TextField
  （**必須**。空は保存拒否 + 説明）+ **「デフォルトにする」チェック**（常に最大 1 行。
  チェックすると `llm.default` をその定義名に書き換え、他の行のチェックは外れる）+
  開閉式の詳細（effort Picker、timeout `SettingsIntField`。timeout には
  「このモデルを使う全機能に効く」注記）。**全行が削除・rename 可**（予約名なし）。
  デフォルト行を削除したら `llm.default` を空にし、「デフォルト = 内蔵既定
  （claude-haiku）」であることを表示する
- **機能別割り当て**: 機能ごとに 1 行の Picker（候補 = **「デフォルト」+ モデル定義名のみ**。
  LLM API のモデル名直指定は UI からは不可）。空値 = 「デフォルト」（初期状態）。
  YAML 手編集で `provider/model` や素のモデル名が入っている場合は後方互換として解決される
  （§3.1）が、Picker には「(直接指定: <値>)」として表示し、選び直すと定義参照に置き換わる。
  対象は 整形 / サマリ / サマリ最終整形 / チャット / Watcher 既定 / ディクテーション。
  反映粒度（次セッションから等。§7 の表）を footer 注記
- **バッチ整形**: 現状維持

UI カバレッジ方針: 運用で触るもの（プロバイダ・モデル定義・割り当て）は UI、`llm.pricing` と
将来の未知パラメータは YAML のみ（頻度が低くエスケープハッチで足りる）。config.yaml が正で
UI は編集ビュー、という既存構造は変えない。

## 10. 失敗モード一覧

| 事象 | 振る舞い |
|---|---|
| 機能側フィールドが未定義 alias / `availableProviders` に無いプロバイダを参照（再起動前に Settings で追加したプロバイダを含む） | warning + 次候補 → `llm.default` → builtin 既定へフォールスルー（§3.2）。呼び出しは止まらない |
| `llm.default` 自体が不正 | warning + builtin 既定（claude-cli + haiku）。旧形式の sentinel default はモデル名を持たないため alias としては常にこの扱い（dictation だけは §4 の据え置きで先に `watchers.default_model` へ落ちる） |
| `providers` が空 / `llm:` セクションなし | builtin 既定で従来どおり動く（config なし起動の性質維持） |
| 未知 `kind` のプロバイダ定義 | decode 時 warning + レジストリ除外。参照はフォールスルー |
| レジストリに無いプロバイダ名が `LLMRequest.provider` に到達 | `unknownProvider`（fatal 分類。設定不備）。resolver が `availableProviders` で検証するため正規経路では到達しない最終防衛線（§5.2） |
| openai プロバイダの API キー未解決 | `missingAPIKey`（既存。fatal 分類のまま） |
| 古い claude CLI に `--effort` | `processFailed`（非 fatal・スキップ継続）。healthCheck で顕在化 |
| alias 名とプロバイダ名の衝突 | alias 優先 + warning（§3.1） |
| プロバイダ名が文字制約（`[A-Za-z0-9_-]+`）違反 | decode 時 warning + レジストリ除外（credential ファイル名衝突の防止。§2.1） |
| プロバイダの `model` 固定が alias の解決結果と食い違う | プロバイダ固定が勝つ（現行仕様の維持）+ 呼び出し時 warning（§2.1） |
| モデル定義の timeout が機能側明示値より短い | 短縮しない（実効値は max。§3.3）。`timedOut` は延長側でのみ起き得る |
| 旧形式 config（`llm.provider` 等） | §4 の読み替えで挙動不変。書き戻しはしない |
| 旧 account の API キー | 初回使用時に新 account へ move（失敗時は値を使いつつ次回リトライ） |
| プロバイダ rename 後の旧 credential | rename 時に move（§9）。move 失敗は warning + 再入力導線 |

## 11. テスト計画（レイヤ 1: swift-testing）

- **`ModelResolver`（pure・中心）**: alias 展開 / `provider/model` 分割（モデル名に `/` を含む
  ケース）/ 素のモデル名 + default プロバイダ / 候補列フォールスルー（先頭候補が
  「定義済みだが不正な alias」のとき次候補に落ちる / 全候補不正で `llm.default` → builtin まで
  落ちる全段）/ `availableProviders` に無いプロバイダ参照が次候補へ落ちる（live config の
  `llm.providers` に存在してもスナップショット集合に無ければ不正扱い）/
  alias・プロバイダ名衝突 / params の effort 優先順位 /
  timeout の max 規則（モデル定義が機能側明示値より短いとき短縮されない）/
  素のモデル名経路が default alias の params を継承しないこと
- **`LLMConfig` decode**: 新形式 / 旧形式マイグレーション（provider 単一 → providers +
  defaultProviderName、reasoning_effort の降格）/ 新旧混在は新優先 / 未知 kind 除外 /
  プロバイダ名の文字制約違反の除外 / models の文字列・オブジェクト両形式 /
  既存 config.yaml（現ユーザー実物相当）が挙動不変
- **`LLMClient`**: レジストリ dispatch（provider 別 backend に届く）/ 遅延構築（未使用
  プロバイダの credential を読まない）/ `availableProviders` の内容（`providerConfigs` の
  キー + builtin 暗黙 `claude`、未知 `kind` 除外分を含まない）/ `unknownProvider` /
  `init(backend:)` 後方互換 / スタブ分岐がレジストリより前段
- **`ClaudeCLIBackend.buildArguments`**: effort なし = 既存アサーション不変、effort あり =
  `--effort` が末尾に付く
- **`OpenAIChatBackend`**: `reasoning_effort` の 2 段解決（params → プロバイダ config）、
  API キー解決順（新 account → レガシー migration → config 直書き → env → missingAPIKey）
- **`SummaryUpdater`**: `.regeneration(modelOverride:)` が発行する `LLMRequest` の
  model/provider/params / finalPass のフォールバック（override → 候補列
  `[finalModel, model]`。**`final_model` が不正 alias のとき `summary.model` に落ちる**ケースを
  含む）/ coalescing・優先順位の既存テスト不変
- **`DictationRefiner`**: 空のフォールバック — 新形式 config で `llm.default` /
  旧形式（sentinel default）で `watchers.default_model` に据え置き（§4）
- **usage 記録**: provider フィールドの追記 / 旧レコード（欠落）の読み込み互換
- **credential migration**: 旧 account → 新 account の move（InMemoryCredentialStore で）

レイヤ 2（kikimi-verify）: スタブモードはプロバイダ非依存の前段分岐のため既存フローのまま。
Phase 2 の再生成メニューは既存の AX クリックシナリオに追随修正が要る場合のみ対応。

## 12. 実装フェーズ分割

| Phase | 内容 | 完了時にできること |
|---|---|---|
| 1. 基盤 | §2 config 改訂 + §4 マイグレーション + §3 ModelResolver + §5 レジストリ・パラメータ写像 + §6 credential + §7 呼び出し側置換 | config.yaml 手編集で機能別プロバイダ・モデル・パラメータ分離が動く。既存 Settings タブは旧 UI のまま（旧フィールドの読み書きは維持） |
| 2. 手動 override | §8（regeneration の口 + 3 箇所の UI） | 「サマリが壊れたら premium で再実行」が UI で完結 |
| 3. Settings 再構成 | §9 | config 手編集なしで全設定が完結 |

Phase 1 完了時の告知事項: dictation フォールバック先の変更（新形式 config のみ。§4）、`llm.openai.model` の
スコープ縮小、旧 config は無変更で動くが Settings（旧 UI）で保存すると旧形式のまま書かれる点
（Phase 3 で解消）。

## 13. kikimi.md への波及と Open Questions

kikimi.md は本設計の実装 Phase 完了時に改訂を提案する: 7 章「モデル」・8 章「モデル」・
9 章 Watcher モデル・12 章 config サンプル（§2.3 の内容。現サンプルに無い `dictation:`
セクションの新設を含む）・15 章 usage 記録（provider 追加）。

Open Questions:

1. **pricing のプロバイダ別名前空間**: `llm.pricing` はモデル名キーのままにした。プロバイダ間で
   同名モデルを別単価にしたくなったら `provider/model` キーを許す拡張で対応（後方互換可能）
2. **プロバイダ接続設定のホットリロード**: 引き続きスコープ外（14 章 §7）。レジストリ化で
   「未使用 backend の遅延構築」までは進んだので、将来やるなら「構築済み backend の破棄 +
   再構築」だけが論点
3. **dictation の空フォールバック先変更**（`watchers.default_model` → `llm.default`）:
   **新形式 config に限って**変更する判断を採った。旧形式の sentinel default はプロバイダ名しか
   持たずモデル名が無いため、旧形式にもこの変更を適用すると段 4 が成立せず段 5 builtin
   （claude-cli + haiku）まで落ち、旧 openai 単独構成で dictation refine が壊れる regression に
   なる（§4）。旧形式は `watchers.default_model` に据え置くことでこれを回避する。
   Phase 1 の完了報告で明示する
4. **チャットのモデル選択の永続化**: セッション中 state に留めた。会議をまたいで既定を変えたい
   要望が出たら `chat.model` を UI から書き換える動線（Settings へのリンク）で足りるか再検討
