# 04. Summary Updater 詳細設計

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `kikimi.md` 5章（`summary.state.json`/`summary.md`）, 7章（context のサマリ即時反映）,
8章（サマリ更新戦略 / patch / 自動タイトル命名 / 全文再生成）, 10章（UI ヘッダの提案バッジ・Summary タブ）,
12章（`config.yaml` の `summary.*`）。
依存: `docs/design/12-llm-client.md`（`LLMClient`）, `docs/design/07-session-store.md` 11章
（`summary.state.json`/`summary.md` の永続化プリミティブ）, `06-ui-panels.md` 6.4章（Summary タブ）。

---

## 1. 目的とスコープ

このドキュメントが担当するのは **`SummaryUpdater` コンポーネント**、および **kikimi.md 8章「自動タイトル命名」の
機構全体**。すなわち:

- サマリ更新トリガの判定（20 セグメント追加 or 3分経過 or 手動）
- 未反映の transcript セグメントと現在の `summary.state.json` から LLM 用 prompt を組み立てる
- `LLMClient` で **patch（構造化出力）** を取得し、`SummaryState` に決定論的に適用する
- 更新後の state を `summary.state.json` に書き、view template（Mustache）で `summary.md` をレンダリング
- **自動タイトル命名**: patch の `title` を 8章のルール（once-only 自動反映 + 提案バッジ + session-end 最終案）で
  `meta.json` に反映する
- 全文再生成（全 transcript/refined から state を作り直す救済パス）

**このフェーズでのスコープ限定（refinement を後回しにする都合）**:

- サマリの入力セグメントは **refined があれば refined、無ければ raw transcript**（kikimi.md 8.5「整形失敗は
  raw_text にフォールバック」と同じ思想）。本フェーズでは `03-refinement-batch.md` が未実装なので実質 raw を使う。
  refinement 実装後もこのフォールバックはそのまま活きる

**スコープ外**（他ドキュメントに委譲）:

| 関心事 | 担当 |
|---|---|
| LLM の起動・認証・構造化出力デコード | `12-llm-client.md` |
| `summary.state.json`/`summary.md` の atomic 書き込み・読み出し | `07-session-store.md` 11章（`readJSON`/`writeJSON`/`readText`/`writeText`） |
| `meta.json` の読み書き（`updateMeta`） | `07-session-store.md`（`SessionHandle.updateMeta`） |
| セグメント整形バッチ（Haiku refinement） | 将来 `03-refinement-batch.md` |
| Watcher 実行 | 将来 `05-watcher-runner.md`（本ドキュメントの Mustache レンダラを再利用） |
| ヘッダ・Summary タブの SwiftUI 実装 | `06-ui-panels.md`（本ドキュメントは ViewModel が公開する状態と操作の契約だけ定義） |

---

## 2. データモデル

### 2.1 `SummaryState`（`summary.state.json`）

kikimi.md 8章「内部 state の schema」を Swift 型に落とす。**MVP はアプリ内蔵固定 schema**（session ごとに
書き換える口は用意しない）。

```swift
struct SummaryState: Codable, Sendable, Equatable {
    var title: String?
    var participants: [String]
    var overview: String
    var decisions: [Decision]
    var actionItems: [ActionItem]

    /// Cursor: the highest `TranscriptSegment.startMs` already fed into a summary update.
    /// Segments with `startMs > lastSummarizedStartMs` are the "未反映分" for the next update
    /// (kikimi.md 8章 user prompt「前回サマリ更新以降の未反映分」). `nil` before the first update.
    /// See section 4.2 for the reordering caveat.
    var lastSummarizedStartMs: Int?

    struct Decision: Codable, Sendable, Equatable {
        var text: String
        var sourceSegIds: [String]
    }

    struct ActionItem: Codable, Sendable, Equatable {
        var id: String                 // "ai_001" 形式。LLM が採番、Kikimi が一意性を担保
        var task: String
        var assignee: String
        var due: String?
        var status: Status
        var sourceSegIds: [String]
        enum Status: String, Codable, Sendable { case open, done }
    }

    static let empty = SummaryState(
        title: nil, participants: [], overview: "", decisions: [], actionItems: [],
        lastSummarizedStartMs: nil
    )
}
```

- JSON 変換は `SessionJSONCoding`（snake_case + ISO8601）を使う（`sourceSegIds` → `source_seg_ids` 等）
- **キー戦略（重要・実装で確定）**: `SummaryState`/`SummaryPatch` とそのネスト型（`Decision`/`ActionItem`/
  `ActionItemPatch` 等）は**明示 `CodingKeys` を持たせない**。snake↔camel は両経路の convert に任せる:
  ディスク（`summary.state.json`）は `SessionJSONCoding` の `.convertFromSnakeCase`、LLM ワイヤ
  （`structured_output`）は `LLMClient` の `.convertFromSnakeCase`（`12-llm-client.md` §6.2）。**明示 snake_case
  キーを付けると `SessionJSONCoding` の convert と二重変換で衝突する**（同じネスト型を両経路で共用するため）。
  スタブ／フェイク LLM も convert 挙動に揃える
- **note**: `lastSummarizedStartMs` は kikimi.md 8章の schema には無い Kikimi 内部フィールド。view template には
  露出しない（8章「template が参照できる変数は schema で定義された field のみ」）

### 2.2 `SummaryPatch`（LLM が返す構造化出力）

kikimi.md 8章「セクションごとの patch 戦略」に対応。**全フィールド optional**（何も変更が無ければ全 null）。

```swift
struct SummaryPatch: Codable, Sendable, Equatable {
    var title: String?                       // cumulative: 変更があれば新値、なければ null
    var participantsAdd: [String]?           // append_only: 追加された人だけ
    var overview: String?                    // snapshot: 全文（変更時のみ）
    var decisionsAdd: [SummaryState.Decision]?   // append_only: 新規のみ
    var actionItems: ActionItemPatch?        // add / modify / complete

    struct ActionItemPatch: Codable, Sendable, Equatable {
        var add: [SummaryState.ActionItem]?
        var modify: [Modify]?
        var complete: [String]?              // 完了にする action item の id 群
        struct Modify: Codable, Sendable, Equatable {
            var id: String
            var task: String?
            var assignee: String?
            var due: String?
        }
    }
}
```

#### JSON Schema 文字列（`--json-schema` に渡す）

`LLMClient.complete` の `schema` 引数に渡す定数。`SummaryPatch` と 1:1 に対応させる。全フィールド optional
（`required` を空に）し、`additionalProperties:false`。実装時に `SummaryPromptBuilder.patchSchemaJSON` として
文字列定数で持つ（`SummaryPatch` のデコードが通ることを単体テストで担保する）。

### 2.3 patch 適用ルール（pure function・決定論的）

`applyPatch(_ patch: SummaryPatch, to state: inout SummaryState)` は副作用のない純関数として実装し、単体テストの
主対象にする（kikimi.md 8章の表を機械的に実装）:

| セクション | 適用 |
|---|---|
| `title` | `patch.title` が非 nil かつ非空なら `state.title` を置換（自動タイトル反映は別レイヤ。3章） |
| `participants` | `participantsAdd` の各要素を、既存に無い場合のみ末尾追加（重複排除、順序保持） |
| `overview` | `overview` が非 nil なら丸ごと置換（snapshot） |
| `decisions` | `decisionsAdd` を末尾に append。ただし既存 `decisions` の `text` と（正規化した上で）一致するものは**重複として捨てる**（LLM が state を見つつ同一決定を再提案しても積み上がらないように, SWE review C7） |
| `actionItems.add` | 末尾に append。**id 衝突時は Kikimi 側でリネーム**（`ai_00N` を採り直す。LLM 採番を信用しすぎない） |
| `actionItems.modify` | 一致する `id` の item の `task`/`assignee`/`due` を、patch で非 nil のフィールドだけ上書き。該当 id 不在なら無視（warn ログ） |
| `actionItems.complete` | 一致する `id` の item の `status` を `.done` に。不在なら無視 |

- **堅牢性優先**: 未知 id の modify/complete、重複 add などの LLM の乱れは「壊さず無視 or リネーム」で吸収する
  （kikimi.md 8.5 と同じ「LLM の出力ブレで表示を壊さない」思想）
- `lastSummarizedStartMs` は patch には無い。適用後に「今回入力した最大 startMs」で更新する（4.2）

---

## 3. 自動タイトル命名（kikimi.md 8章）

**チラつき防止のため「1回命名 + 提案バッジ」方式**。この機構は SummaryUpdater が `meta.json` を更新する形で実装する
（`SessionHandle.updateMeta`）。`SummaryState.title` とは別に、`meta.title`/`titleAutoGenerated`/
`titleAutoNamedOnce`/`titleProposal`（既に `SessionMeta` に存在）を操作する。

### 3.1 Recording 中の反映ルール

サマリ更新で patch の `title`（= 提案タイトル）が得られたとき、以下の判定と書き込みを **`updateMeta { inout meta
in ... }` の同一クロージャ内で atomic に**行う（SWE review B4）。判定と書き込みを別の read → write に分けると、
その隙に走った手動リネーム（`renameTitle` が `titleAutoGenerated=false` を書く）を古い判定で上書きし得る:

```
sessionHandle.updateMeta { meta in
    guard config.autoNaming else { return }          # auto_naming=false は全抑止（§8）
    guard let proposal, !proposal.isEmpty else { return }
    guard meta.titleAutoGenerated else { return }    # 手動編集済み → 何もしない（バッジも出さない）
    if meta.titleAutoNamedOnce == false {
        meta.title = proposal                        # 初回だけ自動反映
        meta.titleAutoNamedOnce = true
        meta.titleProposal = nil
    } else if proposal != meta.title {
        meta.titleProposal = proposal                # 2回目以降は提案バッジのみ（自動反映しない）
    }
}
```

- patch の `title` が nil/空なら何もしない
- 提案が現在の `meta.title` と同一なら `titleProposal` はセットしない（無意味なバッジを出さない）
- クロージャ完了後に `meta` を再読込して push（4.1 の `events`, `metaChanged: true`）

### 3.2 採用操作（UI → ViewModel）

ユーザーがヘッダの「新しいタイトル案: XX [採用]」バッジの `[採用]` を押したら:

```
meta.title = meta.titleProposal
meta.titleProposal = nil
# titleAutoGenerated は true のまま（自動命名の系譜を維持）
```

### 3.3 手動リネームとの関係

- 既存の `MeetingWorkspaceViewModel.renameTitle(_:)` が `titleAutoGenerated = false` に固定する（実装済み）。
  以降 3.1 の分岐で「何もしない」に入るので、提案バッジも自動反映も止まる（8章の仕様通り）

### 3.4 session-end 最終タイトル案（`on_session_end`）

会議終了（Ended）時に、**全 refined（無ければ全 transcript）から最終タイトル案を 1 回生成**し、`titleProposal` に
載せる（同じ提案バッジで通知）。**自動反映はしない**（手動採用まで待つ）。ただし 3.1 と同様、`config.autoNaming`
かつ `titleAutoGenerated == true` のときだけ動き、書き込みは `updateMeta` クロージャ内で atomic に行う。

- これは専用の軽量 LLM 呼び出し（title だけを返す小さな schema）。サマリ patch とは別呼び出しにして prompt を短く
  保つ（SWE review C9）。専用の型と schema 定数を本ドキュメントで定義する:

  ```swift
  struct TitleOnly: Codable, Sendable { var title: String }
  // patchSchemaJSON と別に titleSchemaJSON = {"type":"object",
  //   "properties":{"title":{"type":"string"}},"required":["title"],"additionalProperties":false}
  // stubKey は "final_title"（12章 §5 のスタブ辞書キー）
  ```
- 長時間会議で全 refined が大きい場合は、全文を渡さず**先頭+末尾の要約的サンプリング**または全文再生成後の
  `state.overview`/`decisions` を材料にする（prompt を膨らませない）。MVP は state を主材料にする方針
- `on_session_end` の他処理（Wiki export 等）は本フェーズ未実装。ここではタイトル最終案だけを担う

---

## 4. `SummaryUpdater` コンポーネント

### 4.1 責務と所有

- **セッション単位**の actor。`MeetingWorkspaceViewModel` が Recording 開始時に生成し、Paused/Ended で停止する
  （録音パイプラインと同じライフサイクル）
- `SessionHandle` を受け取り、そこ経由で state/meta/transcript を読み書きする（自分で `FileManager` に触らない）
- `LLMClient`（12章）を注入で受け取る

```swift
actor SummaryUpdater {
    /// `llm` is the narrow `LLMCompleting` seam (12章 §4), not the concrete `LLMClient`, so unit
    /// tests inject a fake directly (SWE review C8).
    init(sessionHandle: SessionHandle, llm: LLMCompleting, config: SummaryConfig)

    /// A new transcript segment was appended. Increments the since-last-update counter and,
    /// if the trigger threshold is reached, enqueues a summary update (non-blocking).
    func noteSegmentAppended() async

    /// Manual "更新" button, or the Recording→Paused/Ended transition's final flush.
    /// Awaitable so the caller can react on completion.
    func updateNow(reason: UpdateReason) async

    /// on_session_end final title proposal (section 3.4). Awaitable.
    func generateFinalTitleProposal() async

    /// Full regeneration from all segments (救済パス, section 6). Awaitable.
    func regenerateFromScratch() async

    /// Push channel for update outcomes → the @MainActor ViewModel (SWE review B2). Every completed
    /// update/regeneration/title-proposal — whether auto-triggered or user-triggered — yields an
    /// event here so the ViewModel can refresh `summaryMarkdown`/`meta`(`titleProposal`) live. The
    /// auto-trigger path does NOT go through the ViewModel, so without this channel auto-updates
    /// would never reach the UI.
    var events: AsyncStream<SummaryUpdateEvent> { get }
}

enum UpdateReason { case segmentThreshold, timeThreshold, manual, pauseFlush }

struct SummaryUpdateEvent: Sendable {
    var summaryMarkdown: String?   // latest rendered summary.md (nil if unchanged this event)
    var metaChanged: Bool          // meta.json was updated (title/proposal) → ViewModel reloads meta
}
```

### 4.1.1 全入口を覆う直列化（SWE review B3）

`noteSegmentAppended` 由来の自動更新だけでなく、`updateNow` / `regenerateFromScratch` /
`generateFinalTitleProposal` も ViewModel から独立に `await` される。各々が「state 読み → LLM `await` →
state 書き」を持ち、actor は `await` 境界で再入するため、無防備だと read-modify-write が交錯して lost update /
patch 二重適用が起きる。

- **単一の in-flight ガード**をすべての入口に被せる（直列化キュー）。実行中は他の要求を「保留中」フラグに畳み込み
  （coalescing）、完了後に 1 回だけ後続を回す
- state の読み込みは**必ず実行の直前**に行い（保留中に他経路が state を書いた可能性があるため）、`await` を挟んで
  古い state を書き戻さない
- `regenerateFromScratch` は特別: 実行中の増分更新と混ざらないよう、開始時に増分トリガを一時停止し、完了後に
  cursor を最新に揃えてから再開する

### 4.2 トリガと未反映分の決定

- **カウンタ**: `noteSegmentAppended()` で「前回更新以降のセグメント数」を数え、`update_trigger_segments`
  （既定 20）に達したら更新。同時に、前回更新からの経過時間タイマ（`update_trigger_seconds` 既定 180）でも更新。
  どちらか早い方（kikimi.md 8章）
- **未反映分**: `state.lastSummarizedStartMs` を高水位（high-water mark）とし、`startMs > cursor` の
  セグメントを `startMs` 昇順で入力にする。適用後 `cursor = 今回入力した最大 startMs` に更新
  - **reordering caveat**: 2 ストリームのセグメントは投入順（id）と `startMs` がズレ得るため、cursor 確定後に
    到着した「cursor より小さい startMs」の遅延セグメントは次回更新で拾えない（取りこぼす）。MVP では許容し、
    Phase 4 実戦で影響を確認する。厳密化が必要なら「投入済み seg id の集合」方式へ切り替える（Open Question）
  - **等値 startMs の境界**（SWE review C10）: strict `>` を使うため、mic と system が**同一 startMs** を持つ
    2 セグメントのうち片方だけを cursor が既に含んでいると、もう片方（同値）が落ちる。同一 startMs は reorder
    ではなく同値衝突なので別問題として認識しておく。seg id 集合方式に移ればどちらも解消する。移行の判断材料として
    テストで再現ケースを持つ
- 更新は actor 内で**直列**（同時に複数の LLM 呼び出しを走らせない）。更新中に閾値を再度超えたら「更新待ち」フラグを
  立て、完了後にもう一度回す（coalescing。多重起動を防ぐ）

### 4.3 1 回の更新フロー

```
1. transcript（refined 優先、無ければ raw）を読み、startMs 昇順にマージ
2. 未反映分（startMs > cursor）を取り出す。空なら何もしない（manual/pauseFlush でも早期 return）
3. 現在の summary.state.json を読む（無ければ SummaryState.empty）
4. SummaryPromptBuilder で user prompt を組む（現 state の JSON + 未反映セグメント + 現在時刻）
   - context.md をサマリ system/user に**即時反映**してよい（kikimi.md 7章「summary は毎回組み立て直すので即時」）
5. llm.complete(LLMRequest(system: 固定, user, schema: patchSchemaJSON, model: config.summaryModel,
   stubKey: "summary_patch")) → LLMResult<SummaryPatch>
   - 失敗（LLMClientError）→ この更新をスキップしてログ。state/cursor は変更しない（次回リトライ相当）
   - result.usage は（表示するなら）ここで累積
6. applyPatch でローカルに state を更新、cursor を更新
7. writeJSON(state, to: .summaryState)
8. Mustache で summary_template を state にレンダリング → writeText(md, to: .summaryMarkdown)
9. events に SummaryUpdateEvent(summaryMarkdown: md, metaChanged: ...) を yield（Summary タブへ通知, B2）
10. 自動タイトル命名（3.1）を updateMeta 経由で atomic 適用。meta が変われば metaChanged=true で push
```

- **5 で失敗しても録音・transcript には一切影響しない**（LLM 障害はサマリ更新のスキップに閉じる）
- **性能注記**（SWE review C6）: step 1 は毎トリガで全 transcript を再読込・再ソートする（20 セグごと O(n)、
  長時間会議で総 O(n²/20)）。MVP は許容。cursor 以降だけ読む増分最適化の余地があること、全文再生成（6章）も
  全読みであることを注記として残す

### 4.4 Prompt 設計（`SummaryPromptBuilder`）

kikimi.md 8章「LLM への入出力の例」に沿う。

- **system prompt（固定）**: 「あなたは会議サマリを更新するエディタです。前サマリ state と直近の会話を受け取り、
  変更差分（patch）を JSON で返してください。」＋ schema 説明＋ルール（title は毎回提案・state.title が空なら
  必ず提案 / participants は新規登場者のみ participants_add に追加 / overview は全文書き直し可 / decisions は
  新規のみ / action_items は add/modify/complete / 変更なしは全 null）。**小さく固定**（12章 2.2）
- **user prompt（毎回）**: 現在の state（JSON）＋直近の会話（`start_ms` 昇順、未反映分）＋現在時刻。
  context.md の内容もここに含めて即時反映（毎回組み直すので caching 不要）
- セグメント表記は `seg_00350 (mic): テキスト`。refined があれば refined_text、無ければ raw text

---

## 5. Mustache レンダリング（`SummaryRenderer`）

kikimi.md 5章/8章の view template を Mustache で state → Markdown にレンダリングする。**サマリと Watcher の
両方で使う中核**なので、汎用の Mustache レンダラとして切り出す（Watcher 実装で再利用）。

- **依存ライブラリ**: 軽量 Mustache ライブラリを SPM 依存に追加する（ユーザー合意事項）。第一候補
  **GRMustache.swift**（`https://github.com/groue/GRMustache.swift`、product 名 `Mustache`）。section/inverted
  section/変数展開に対応し、kikimi.md の view 記法（`{{#items}}`/`{{^-last}}` 等）をそのまま使える
  - **確認事項（実装時）**: Swift 6 / strict concurrency での取り込み可否、`{{^-last}}`（配列末尾判定）の対応。
    仮に GRMustache が Swift 6 で不都合なら、同等機能の別 Mustache 実装に差し替える（代替候補: **swift-mustache**
    `hummingbird-project/swift-mustache` — Swift 6 対応・Sendable クリーン）。判断は**タイムボックス**して phase を
    詰まらせない。**自前実装はしない**（ユーザー方針: 軽量ライブラリ依存追加）
- **入力の作り方**: `SummaryState` を Mustache が食える辞書（`[String: Any]` 相当 / ライブラリの box）に変換する
  変換層を用意。`participants` の `{{^-last}}` 区切り、`action_items` の `{{#due}}...{{^due}}—{{/due}}` を
  正しく出すため、必要な派生値（`-last` 等）を注入する
- **frontmatter は含めない**（kikimi.md 8章: Wiki export 側の frontmatter が正）
- template 未存在時は内蔵デフォルト template にフォールバック（kikimi.md 8章「テンプレート読み込み規則」）
- **Watcher の derived flags（`is_<enum値>`）注入**は Watcher フェーズで足す。本フェーズのサマリ schema には enum が
  無い（action_items.status は view で使わない）ので、サマリレンダリングには derived flags 不要

### 5.1 Summary タブのライブ更新（`06-ui-panels.md` 6.4 との接続）

- 現状の `SummaryTabView` は Phase 1 スタブ（`summary.md` を 1 回読むだけ）。本フェーズで ViewModel が
  `@Published var summaryMarkdown: String?` を公開し、`SummaryUpdater` の更新完了ごとに流す形にする
- 「サマリ全文再生成」ボタンを表示し、`regenerateFromScratch()` を呼ぶ（6章）
- 最終更新時刻の表示（`06-ui-panels.md` 6.4）

---

## 6. 全文再生成（救済パス, kikimi.md 8章）

- 全 transcript（refined 優先）を `startMs` 昇順で読み、state を `SummaryState.empty` から作り直す
- 一度の巨大 LLM 呼び出しは避け、**チャンク分割して applyPatch を積み上げる**（例: 40 セグメントずつ複数回）。
  各チャンクは 4.3 と同じフローで、cursor を進めながら state を育てる
- 完了後 `summary.state.json`/`summary.md` を上書き。**冪等**（何度押しても全 refined から同じ手順で作り直す）
- Recording 中でも Ended 後でも呼べる（8章「サマリが劣化した場合の緊急脱出」）

---

## 7. `MeetingWorkspaceViewModel` との配線

本フェーズで ViewModel に足すもの（`06-ui-panels.md` のヘッダ／Summary タブが消費する契約）:

| 追加 | 用途 |
|---|---|
| `SummaryUpdater` の生成/破棄（Recording 開始/停止に合わせる） | パイプラインと同ライフサイクル |
| transcript append 時に `updater.noteSegmentAppended()` を呼ぶ | トリガ用カウント（呼び出し口は 7.1） |
| `updater.events` を購読して `summaryMarkdown`/`meta` を更新 | 自動更新を UI に反映（B2 の push 経路） |
| `@Published var summaryMarkdown: String?` | Summary タブのライブ表示 |
| `@Published`（`meta` 経由）`titleProposal` の監視 | ヘッダの提案バッジ |
| `func adoptTitleProposal() async` | 提案バッジの `[採用]`（3.2）。書き込みは `updateMeta` クロージャ内で atomic |
| `func requestSummaryUpdateNow() async` | 手動更新ボタン → `updateNow(.manual)` |
| `func regenerateSummary() async` | 「全文再生成」ボタン |
| Paused/Ended 遷移の**破棄前**に `updateNow(.pauseFlush)` を呼ぶ | 直近 <20 セグメントの取りこぼし防止（C2） |
| Ended 遷移時に `generateFinalTitleProposal()` を呼ぶ | session-end 最終タイトル案（3.4） |

- 既存の `renameTitle(_:)`/`meta` 更新経路と整合させる（`meta` を `updateMeta` 後に再読込して `@Published` を更新
  する既存パターンを踏襲）

### 7.1 `noteSegmentAppended()` の呼び出し口（SWE review C1）

transcript の append は `TranscriptPipeline` が `SessionHandle.appendTranscriptSegment` へ直接行い、ViewModel は
`liveSegments` サブスクリプションで眺めるだけ。カウントのフックは以下を満たす形にする:

- **live segment サブスクリプションのループ**（`MeetingWorkspaceViewModel.startLiveSegmentSubscription` 相当）で
  新規確定セグメント 1 件ごとに `noteSegmentAppended()` を呼ぶ
- **`onAppear` バックフィル分はカウントしない**（既存セグメントの読み直しでトリガを誤発火させない）。live 購読が
  「新規確定」だけを流す設計になっているか確認し、なっていなければ「購読開始時点以降の新規のみ」を区別する
- **reopen（Ended→Recording 復帰）時の二重カウント回避**: updater を作り直す際、cursor は `summary.state.json`
  から復元されるので過去分は未反映分に含まれない。カウンタは 0 から再開してよい

---

## 8. 設定（`config.yaml` の `summary.*`）

kikimi.md 12章の `summary` セクションに対応。`AppConfig`（要実装）から解決して `SummaryConfig` に詰める。
`AppConfig` 未整備の間は既定値をハードコードしたデフォルトで動かし、config 連携は後追いで良い。

```swift
struct SummaryConfig: Sendable, Equatable {
    var model: String = "claude-haiku-4-5-20251001"   // summary.model
    var updateTriggerSegments: Int = 20                 // summary.update_trigger_segments
    var updateTriggerSeconds: Int = 180                 // summary.update_trigger_seconds
    var autoNaming: Bool = true                         // summary.auto_naming
}
```

- `auto_naming == false` のときは 3章の自動タイトル反映・提案をすべて抑止する（サマリ本体は更新する）

---

## 9. 失敗モード一覧

| 事象 | 振る舞い |
|---|---|
| `LLMClient` エラー（CLI 不在・認証・タイムアウト・JSON 破損） | その更新をスキップ、state/cursor 不変、warn ログ。録音・transcript は無影響。次のトリガでリトライ相当 |
| patch のデコード成功だが中身が乱れている（未知 id の modify 等） | applyPatch が壊さず無視 or リネーム（2.3） |
| Mustache レンダリング失敗（template 破損） | 内蔵デフォルト template で再試行。なお失敗なら前回 `summary.md` を保持し warn |
| `summary.state.json` 破損（読み込み失敗） | `SummaryState.empty` から再開（サマリは劣化するが継続）。ユーザーは全文再生成で回復可能 |
| 未反映分が空でトリガ発火 | 何もせず return（LLM を叩かない） |
| Recording でない状態でトリガ | SummaryUpdater は Paused/Ended で停止済みなので発火しない。手動/再生成のみ可 |

---

## 10. テスト容易性（docs/development-process.md 2.9）

### レイヤ1（単体テスト, swift-testing）— pure function 中心

- **`applyPatch` の全分岐**（2.3 の表を網羅）: title 置換、participants 重複排除、overview snapshot、
  decisions append、action_items add/modify/complete、未知 id 無視、id 衝突リネーム
- **未反映分の抽出**（cursor による high-water mark、reordering の取りこぼしが仕様通りか）
- **自動タイトル命名の状態機械**（3.1）: 初回自動反映 → 2回目以降は proposal のみ → 手動編集後は無反応、を
  `SessionMeta` 入出力で検証
- **`SummaryRenderer`**（Mustache）: 既定 template で state → 期待 Markdown（pure。ライブラリ差し替えでも
  この期待値が回帰テストになる）
- **`SummaryPromptBuilder`**: state + セグメント → 期待 user prompt 文字列（seg 表記・昇順・現在時刻）
- **JSON Schema 定数 ↔ `SummaryPatch`**: schema 文字列が有効 JSON で、代表的な patch JSON が `SummaryPatch` に
  デコードできる
- **`LLMClient` はフェイク注入**（12章 7章の `LLMProcessRunner` フェイク、または `LLMClient` をプロトコル化して
  スタブ）で SummaryUpdater の end-to-end フローを実 CLI 無しで検証

### レイヤ2（`kikimi-verify`）

- `KIKIMI_STUB_LLM=1`（スタブキー `summary_patch` / `final_title`）で「録音 → ダミー音源 → 一定セグメント →
  サマリ更新が走る → `summary.md`/`summary.state.json` が生成される → ヘッダに自動タイトルが付く → 2回目で提案
  バッジが出る → 採用で反映」を end-to-end 確認
- session-end 最終タイトル案の生成確認（`final_title` スタブ経路も E2E で叩けること, SWE review nit）

---

## 11. 他ドキュメントとの境界（インターフェース契約まとめ）

| 相手 | 契約 |
|---|---|
| `12-llm-client.md` | `LLMCompleting.complete(LLMRequest)` を呼び `LLMResult<T>` を得る。エラー時は更新スキップ。テストはこの seam にフェイクを注入 |
| `07-session-store.md` | `readJSON/writeJSON(.summaryState)`, `readText/writeText(.summaryMarkdown)`, `updateMeta`, `readTranscriptSegments`/`readRefinedSegments`, `readContext` を消費 |
| `06-ui-panels.md` | ViewModel が `summaryMarkdown`/`titleProposal`/`adoptTitleProposal()`/`requestSummaryUpdateNow()`/`regenerateSummary()` を公開（7章） |
| 将来 `05-watcher-runner.md` | `SummaryRenderer`（Mustache）と derived flags 注入層を再利用 |
| 将来 `03-refinement-batch.md` | refined があれば SummaryUpdater が自動で refined_text を優先入力にする（実装済みフォールバック） |

---

## 12. Open Questions

- **未反映分の reordering 取りこぼし**（4.2）: high-water mark 方式で実戦上問題になるか。なるなら seg id 集合方式へ
- **全文再生成のチャンクサイズ**（6章）: 40 セグメント/チャンクで妥当か。長時間会議での回数・コストを Phase 4 で確認
- **Mustache ライブラリの Swift 6 適合**（5章）: GRMustache.swift が strict concurrency で問題ないか。ダメなら
  別 Mustache 実装へ差し替え（自前実装はしない方針）
- **`AppConfig` 未整備**（8章）: 当面ハードコード既定で動かし、config 連携は後追い
- **コスト表示**: `LLMClient` が返す `total_cost_usd` を会議ごとに累積表示するか（kikimi.md 15章）
