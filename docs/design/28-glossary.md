# 28. 用語集（Glossary）

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `docs/design/25-dictation-mode.md`（ディクテーションの整形パイプライン全般。用語集は元々
ここの §14.2/R12〜R18 の拡張として実装されたが、本設計の R19 で会議整形と共有する top-level 機能に
昇格した）, `docs/design/03-refinement-batch.md` §4.2（会議書き起こしのバッチ整形 prompt 構成）,
kikimi.md 12 章（`config.yaml` 全体像）。

本設計の要点は以下のとおり。

- **用語集は会議書き起こし整形（`RefinementQueue`）とディクテーション整形（`DictationRefiner`）の
  両方が使う、機能非依存の共通設定にする**。固有名詞・専門用語を「書かせたい表記」に置換させるための
  schema+view 形式のリストで、`config.yaml` のトップレベル `glossary:` セクションに持つ
  （`dictation:` と同階層。`dictation.context` 配下ではない）
- **用語集は「誤変換の修正リスト」ではなく「置換ルール」である**（§2.1）。STT の誤変換の修正
  （「デブ環境」→「dev環境」）と、正しく書き起こされた語の表記統一（「ステージング環境」→「stg環境」）は
  モデルから見れば同一の操作なので、両者を分ける**種別フィールドは持たない**
- **カテゴリ（`glossary_categories`）はユーザー定義**で、種別ではなく**ドメインのヒント**の軸
  （「人物名」「環境名」など）。各カテゴリは自前の `instruction` を持ち、`## 見出し` 付きで
  レンダリングされる。`id` と `name` を分けてあるので**カテゴリ名はいつでも自由に変更できる**（§1.2）
- **R19（本設計での確定事項、当初 R12 系列の続番として付番）**: 用語集は当初 `dictation.context.glossary`
  として実装されたが、「会議の書き起こしでも使うので共通の設定にしてほしい」という実戦フィードバックにより
  トップレベルへ昇格した。`DictationContextConfig` から `glossary` フィールドを削除し、
  `KikimiConfigData.glossary: [GlossaryEntry]` として持つ。古い `dictation.context.glossary` キーが
  残った `config.yaml` は、単に無視される（デコードエラーにはしない。移行処理は行わない）
- **型・レンダラも feature 非依存の場所に置く**: `GlossaryEntry` / `GlossaryCategory`
  （`Kikimi/Config/GlossaryConfig.swift`）と `GlossaryRenderer` / `GlossaryCategorization` /
  `GlossaryFilter`（`Kikimi/Glossary/`）。どれも `Kikimi/Dictation/` にも `Kikimi/Refinement/` にも
  属さない
- **注入経路は 2 つ、レンダリングロジックは 1 つ**: `DictationContextResolver.resolve(bundleID:config:
  glossary:glossaryCategories:)`（ディクテーション）と `RefinementPromptBuilder.buildSystemPrompt(
  context:glossaryBlock:dedupSystemLeakSegments:)`（会議整形）の両方が
  `GlossaryRenderer.render(entries:categories:)` を呼ぶ。表示形式の改善は 1 箇所を直せば両方に効く
- **会議整形側は system prompt のキャッシュ固定を崩さない**: 用語集ブロックは `context.md` の
  「【事前知識】」ブロックとは別枠として system prompt に差し込むが、`context_refresh_batches` の
  リロード周期には従わない（`glossaryProvider()` はプロセス内スナップショットを返すだけで I/O を伴わない
  ため、毎バッチ再レンダリングしてもコスト・キャッシュヒット率に影響しない。§3 参照）
- Settings UI は独立した「用語集」タブに常時表示（`dictation.refine` の ON/OFF に関係ない。会議整形は
  常時動作しているため）。カテゴリのサイドバー + 詳細ペインの master-detail 構成（§4）

## 1. データモデル

### 1.1 `GlossaryEntry`（`Kikimi/Config/GlossaryConfig.swift`）

```swift
struct GlossaryEntry: Codable, Equatable, Sendable {
    var term: String       // 置換先の表記
    var reading: String    // 置換元の表記（空文字可）
    var category: String?  // GlossaryCategory.id への参照（nil で未分類）
}
```

- `term`: LLM に書かせたい表記（例: `"nekosuke"`, `"stg環境"`）
- `reading`: 置換元の表記（例: `"ねこすけ"`, `"ステージング環境"`）。**STT の誤変換とは限らない**
  — 正しく書き起こされた語の表記統一もここで表す（§2.1）。空文字なら「置換するものはないが、実在の
  固有名詞として認識してほしい」の意（別の一般語に「訂正」されるのを防ぐ）。置換元が複数あるときは
  カンマ区切りで 1 エントリにまとめる（例: `"山田, やまだ"`）— 1 表記 1 エントリより
  プロンプトの行数（term の繰り返し）を節約できる。カンマの解釈は header が LLM に指示する（§2.1）
- `category`: `glossary_categories[].id` への参照。省略・空文字・**存在しない id** はすべて未分類として
  扱う。存在しない id を decode 時に修復しないのは意図的で、解決は使用時に `GlossaryCategorization` が
  一箇所で行う（§1.3）

### 1.2 `GlossaryCategory`（`Kikimi/Config/GlossaryConfig.swift`）

ユーザーが自由に定義できる用語のグループ。**カテゴリは「置換の種別」ではなく「ドメインのヒント」の軸**
である（§2.1 参照。種別という軸は存在しない）。

```swift
struct GlossaryCategory: Codable, Equatable, Sendable, Identifiable {
    var id: String           // アプリが採番する UUID。エントリはこれを参照する
    var name: String         // 表示名。いつでも自由に変更できる
    var instruction: String  // このカテゴリ固有の追加指示（空文字可）
}
```

- **`id` と `name` を分けるのは、カテゴリ名を後からいくらでも変更できるようにするため**。`id` は
  Settings の `[+]` を押した瞬間に採番される UUID で、`name` から導出しない。導出してしまうと、
  リネームのたびに配下のエントリが宙に浮く
- `instruction` は `## {name}` 見出しの直下、用語リストの前にレンダリングされる（例:
  「以下は人物名です。敬称（さん・様）は原文のまま残してください。」）

### 1.3 config.yaml（トップレベル、`dictation:` と同階層）

```yaml
# ~/.config/kikimi/config.yaml
glossary_categories:
  - id: 8B1F...            # UUID（Settings が採番）
    name: 人物名
    instruction: |
      以下は人物名です。敬称（さん・様）は原文のまま残してください。
  - id: 4C7A...
    name: 環境名           # instruction は省略可

glossary:
  - term: nekosuke
    reading: ねこすけ
    category: 8B1F...      # 省略で未分類
  - term: stg環境
    reading: ステージング環境
    category: 4C7A...
  - term: Acme Works
    reading: ""
```

`KikimiConfigData.glossary: [GlossaryEntry]` / `.glossaryCategories: [GlossaryCategory]`（ともに既定
`[]`）。decode は既存の他セクションと同じ「壊れていたら warning + 既定値にフォールバック」の流儀:

- `glossary`: 1 エントリでもデコードに失敗したら**配列全体**を空にフォールバックする（個別エントリ単位の
  部分救済はしない。Settings UI 経由でしか書かれない想定のため）
- `glossary_categories`: `id` / `name` を欠くカテゴリは構造的な壊れとみなし、同じく**配列全体**を空に
  フォールバックする
- ただし **`id` の重複だけは修復する**（先勝ちで残し、後続を warning つきで捨てる）。重複は手編集の
  タイプミスで到達し得る修復可能な不整合であり、それ一つで全カテゴリを捨てるのは不釣り合いに破壊的
- **`glossary[].category` と `glossary_categories[].id` の突き合わせは decode 時に行わない**。宙に浮いた
  参照はそのまま保持され、使用時（レンダリング・UI）に `GlossaryCategorization` が未分類へ倒す。
  「何を未分類とみなすか」の実装を decode 側と render 側の 2 箇所に分裂させないための選択

## 2. レンダリング: `GlossaryRenderer`（`Kikimi/Glossary/GlossaryRenderer.swift`）

```swift
enum GlossaryRenderer {
    static let header = """
    # Glossary

    以下は、この書き起こしに登場する固有名詞・専門用語の一覧です。

    - 「A → B」形式の行は、文中に A（またはそれに近い表記・誤変換）が現れたら B に置換してください。A が正しく書き起こされていても、B の表記に統一してください。
      (例:「猫助」→「nekosuke」、「デブ環境」→「dev環境」、「ステージング環境」→「stg環境」)
    - 「A1, A2 → B」のようにカンマ区切りで複数並ぶ行は、そのいずれの表記が現れても B に置換してください。
    - 置換結果として出力してよいのは、必ず「→」の右側の表記です。左側（読み・誤変換の側）を出力に使わないでください。
    - 用語のみの行は、実在の固有名詞です。別の一般語に「訂正」しないでください。
    - どの行の A とも読みが明確に一致しない語は、そのまま残してください。一覧のどれかへ無理に寄せてはいけません。
    - ただし、文脈上明らかに無関係な語だと分かる場合は、無理に置換しないでください。
    """

    static func render(entries: [GlossaryEntry], categories: [GlossaryCategory] = []) -> String? { ... }
}
```

- `term` が空白のみ（trim 後に空）のエントリはスキップする（Settings で行を追加した直後の未入力行など）
- 全エントリがスキップされる場合は `nil` を返す（呼び出し側はブロックそのものを注入しない）
- 1 行 = 1 エントリ。`reading` があれば `- reading → term`、なければ `- term`（矢印形式の理由は §2.2）
- schema（データ）とレンダリング（表示文言）を分離しているのは、Watchers/summary で既に確立している
  schema+view 分離パターンと同じ理由: prompt 文言のチューニングを config の形を変えずに行える

**カテゴリのグルーピング**（`categories` 省略時は従来どおりの平坦なリストになる）:

- **未分類のエントリが先頭**に、見出しなしで header 直下に並ぶ（宙に浮いた `category` 参照を持つ
  エントリもここに落ちる。§1.3）
- 続いて各カテゴリが `glossary_categories` の順に `## {name}` → `instruction`（あれば）→ 用語の順で並ぶ
- カテゴリ内のエントリは元配列の順序を保つ
- **レンダリングできる用語が 1 つもないカテゴリは、見出しごと何も出力しない**

```
# Glossary

（共通指示）

- Acme Works

## 人物名
以下は人物名です。敬称（さん・様）は原文のまま残してください。
- ねこすけ → nekosuke

## 環境名
- デブ環境 → dev環境
- ステージング環境 → stg環境
```

グルーピング判定そのものは `GlossaryCategorization`（`Kikimi/Glossary/GlossaryCategorization.swift`）に
切り出し、**レンダラと Settings UI が同じ関数を使う**。「何が未分類か」の実装が 2 箇所に分裂すると、
プロンプトに出る場所と UI に出る場所が食い違い得るため。エントリ側の `category` は**trim してから**比較
する（`" person "` のような値がどのバケットにも属さず消えるのを防ぐ）。

### 2.1 header は「誤変換の修正」ではなく「置換ルール」として書く

当初の header は「音声認識でよく誤変換される〜。文中に読みが似た**誤変換**が含まれている場合は置換して
ください」と、用語集を**誤変換の修正リスト**として説明していた。この枠組みだと、置換元が日本語として
壊れている場合しか発火しない:

- 「デブ環境」→「dev環境」は効く（「デブ環境」は明白な誤変換）
- 「ステージング環境」→「stg環境」は**効かない**。「ステージング環境」は誤変換ではなく忠実な書き起こし
  なので、LLM には置換する動機がない（2026-07 の実戦フィードバックで発覚。`reading` をカタカナ表記に
  直しても再現した = 表層のマッチではなく指示文の問題）

モデル側から見れば「誤変換の修正」と「表記ゆれの統一」は同一の操作（**A を見たら B と書く**）なので、
header はそれをそのまま述べ、「正しく書き起こされていても置換する」を明示する。これにより
`GlossaryEntry` に「誤変換修正 / 表記統一」の**種別フィールドを持たせる必要がなくなる**（種別は指示文の
書き方の問題であって、データの性質ではない）。

あわせて、`reading` が空の行（`- Acme Works`）にも明示的な指示を与える。従来この行の意味
（「実在の固有名詞なので別の一般語に訂正するな」）は `GlossaryEntry` の doc comment にしか書かれておらず、
**prompt には一切現れていなかった**。

### 2.2 行は `A: B`（コロン）ではなく `A → B`（矢印）で描画する

当初の行形式は `- reading: term`（例: `- こんけん: konken`）だった。この形式は小さいモデル
（ディクテーションの実運用は gpt-5.4-nano クラス）で**置換方向を逆に読まれる**
（2026-07-10 実戦フィードバック）:

- 「根建さん」（発話は「こんけんさん」）が「**こんけんさん**」に整形された。行にはマッチしたのに、
  置換先 B（`konken`）ではなく**左側の読み A を出力**した
- 辞書の慣習は「見出し語: 説明」であり、コロン形式では**左側が正規表記**という事前分布に
  引きずられる。指示文で「B に置換」と書いても、小さいモデルは形式の先入観の方に従う
- しかも header の例示自体は 「猫助」**→**「nekosuke」 と矢印で書かれており、例と実データの
  形式が食い違っていた

矢印は方向を形式そのものにエンコードするので誤読の余地がなく、例示とも一致する。あわせて
「出力してよいのは必ず「→」の右側」を独立した行として明示する。

同じインシデントのもう一つの失敗（`konken` に reading が未登録だった時期に、「根建さん」が**別人の**
エントリ `nekokak` の読み「ねこかく」へ強引にマッチされた）に対しては、「どの行の A とも読みが明確に
一致しない語はそのまま残す。一覧のどれかへ無理に寄せない」の歯止めを追加した。fuzzy マッチ
（「それに近い表記・誤変換」）自体は §2.1 の経緯から必要なので残し、**マッチしない場合の挙動**を
明文化する形で両立させる。

## 3. 注入経路

### 3.1 ディクテーション: `DictationContextResolver.resolve(bundleID:config:glossary:glossaryCategories:)`

```swift
static func resolve(
    bundleID: String?,
    config: DictationContextConfig,
    glossary: [GlossaryEntry] = [],
    glossaryCategories: [GlossaryCategory] = []
) -> String? {
    var sections: [String] = []
    // global（dictation.context.global）
    // glossary（GlossaryRenderer.render(entries: glossary, categories: glossaryCategories)）
    // app 別コンテキスト（bundleID 一致時のみ）
    ...
}
```

- `glossary` / `glossaryCategories` は呼び出し元が解決して渡す別引数。`DictationContextConfig` はもう
  `glossary` フィールドを持たないため、`resolve` 自身が `config` から読むことはできない
- `DictationController` は `glossaryProvider: @MainActor () -> [GlossaryEntry] = { AppConfig.shared.data
  .glossary }` と `glossaryCategoriesProvider`（同型）を他の provider（`dictationConfigProvider` 等）と
  同じ DI パターンで保持し、`handleHotkeyUp()` で両方を呼んで渡す
- 結合順序は「global → glossary → app 別コンテキスト」（`DictationContextResolver` の既存の順序に
  glossary を挟み込む形。app 別コンテキストの「優先」ラベルは維持する）

### 3.2 会議整形: `RefinementPromptBuilder.buildSystemPrompt(context:glossaryBlock:dedupSystemLeakSegments:)`

```swift
static func buildSystemPrompt(
    context: String,
    glossaryBlock: String? = nil,
    dedupSystemLeakSegments: Bool = true
) -> (prompt: String, wasClamped: Bool)
```

- `glossaryBlock` は `GlossaryRenderer.render(entries:categories:)` 済みの文字列（呼び出し側でレンダリング
  済みのものを渡す。`buildSystemPrompt` 自身は `[GlossaryEntry]` を受け取らない -- 会議側は
  `RefinementQueue` が `glossaryProvider()` / `glossaryCategoriesProvider()` の結果をレンダリングして
  から渡す）
- 「【事前知識】」ブロックの直後、「【出力形式】」の直前に別ブロックとして差し込む（`context.md` の内容と
  用語集を同じスロットで奪い合わせない）
- `nil`（既定値）のときは従来どおりの prompt を一切変更せず出力する -- 用語集追加前の既存テスト・キャッシュ
  挙動は無変更

### 3.3 `RefinementQueue` 側の DI: `glossaryProvider` / `glossaryCategoriesProvider`

```swift
let glossaryProvider: @Sendable () -> [GlossaryEntry]
let glossaryCategoriesProvider: @Sendable () -> [GlossaryCategory]

init(
    ...,
    glossaryProvider: @escaping @Sendable () -> [GlossaryEntry] = { [] },
    glossaryCategoriesProvider: @escaping @Sendable () -> [GlossaryCategory] = { [] }
) { ... }
```

以下の議論は 2 つの provider に等しく当てはまる（`glossaryCategoriesProvider` は同じ DI 形と同じ制約を
持つ兄弟であり、既定値が固定の空配列であることも同じ理由による）。

- `now: @escaping @Sendable () -> Date = Date.init` と同じ「テスト用フェイク注入できる closure」DI
  パターンを踏襲する
- **ただし `now` とは異なり、既定値は `AppConfig.shared` を読まない**（固定で空リストを返す）。
  `AppConfig` は `ObservableObject` の plain class で、`@MainActor` 前提の慣習はあるが型自体は
  `Sendable` ではない（`WikiExporter` の doc comment 参照）。`RefinementQueue` は `actor`（`@MainActor`
  ではない）なので、そのバックグラウンド実行コンテキストから `AppConfig.shared` を直接読むのは
  データ競合のリスクがある
- 本番経路（`MeetingWorkspaceViewModel+Factories.swift` の `defaultRefinementQueueFactory`）は
  `@MainActor` 上で `AppConfig.shared.data.glossary` / `.glossaryCategories` を一度スナップショットし、
  そのスナップショットを返すだけの closure（`{ glossary }` / `{ glossaryCategories }`）を渡す --
  `config: AppConfig.shared.data.refinement` 自体を値としてキャプチャしているのと同じパターン
- `currentSystemPrompt()`（`RefinementQueue+BatchProcessing.swift`）は両 provider を**毎バッチ**呼んで
  レンダリングする。`context.md` の `context_refresh_batches` リロード周期には乗せない -- どちらも
  プロセス内スナップショットを返すだけで I/O を伴わないため、毎回呼んでもコスト増はなく、出力は本番では
  常に同じ（＝system prompt のキャッシュヒット率に影響しない）

## 4. Settings UI

`GlossarySettingsTab`（`Kikimi/Views/GlossarySettingsTab.swift`）を Settings の**独立した
「用語集」タブ**として置く（`docs/design/26-settings-ui.md` §4 のタブ構成に 6 つ目として追加。
話者/入力の間）。`dictation.refine` の ON/OFF には連動しない -- 会議整形は常に動作しているため、
用語集の効果はディクテーションを一切有効化していないユーザーにも及ぶ。

**なぜ専用タブか**: 当初は「一般」タブ（`GeneralSettingsTab`）の 1 セクションだったが、
そこで唯一の**件数無制限リスト**であるため、用語が数件増えるだけで下に並ぶ固定設定
（話者分離 / 音声 / 既定テンプレート / サマリ更新 / Wiki Export）がウィンドウ外に押し出され、
到達不能になった（2026-07 の実戦フィードバック）。声紋一覧を持つ「話者」タブと同格の
**データ管理タブ**として切り出す。「一般」タブには用語集の痕跡を一切残さない。

### 4.1 レイアウト: カテゴリのサイドバー + 詳細ペイン

```
┌──────────────┬─────────────────────────────────────────────┐
│ カテゴリ       │ 人物名                          [🔍 絞り込み]│
│              │ ┌─────────────────────────────────────────┐ │
│ すべて    (9) │ │ 追加指示（任意）                          │ │
│ 未分類    (4) │ │ 敬称（さん・様）は原文のまま残してください。 │ │
│ ─ カテゴリ ─  │ └─────────────────────────────────────────┘ │
│ ▸ 人物名  (2) │ 用語（正しい表記）  読み・置換元（任意）        │
│   環境名  (3) │ nekosuke           ねこすけ            🗑    │
│              │ Claude            クロード            🗑    │
│ [+] [−]      │ [+ 用語を追加]                    2 件登録済み │
└──────────────┴─────────────────────────────────────────────┘
```

**なぜ行ごとの category Picker ではなく master-detail か**: 行ごとの Picker だと用語を追加するたびに
カテゴリを選ばされ、しかも一覧上で同じカテゴリの用語がバラバラに並ぶ。先にカテゴリを選ぶ形にすれば
「+ 用語を追加」は行き先を既に知っており、同じカテゴリの用語が常にまとまって見える（＝プロンプトに
出力されるまとまりと一致する）。

view の分割（いずれも SwiftLint の `file_length: 600` に十分収まる）:

| ファイル | 役割 |
|---|---|
| `GlossarySettingsTab.swift` | `GlossaryBucket` の定義、選択 state、カテゴリの作成・削除（両ペインに跨る責務だけ） |
| `GlossaryCategorySidebar.swift` | すべて / 未分類 / 各カテゴリの行と件数、`[+]` `[−]` |
| `GlossaryCategoryDetailView.swift` | 選択中バケットの見出し・追加指示・絞り込み・用語一覧・「+ 用語を追加」 |
| `GlossaryEntryRow.swift` | 1 行（用語 / 読み / 削除）、ドラッグハンドル、「カテゴリを移動」/「上へ・下へ移動」context menu |

- `GlossaryBucket` は `すべて` / `未分類` / `カテゴリ(id)` の 3 値。**`すべて` は閲覧専用**の擬似バケット
  で、そこでは「+ 用語を追加」を出さない（どのカテゴリに入るか一意に決まらないため）。代わりに各行に
  カテゴリ名の小さいラベルを添えて「この用語どこに入れたっけ」を解決する
- サイドバーの件数も `GlossaryCategorization` から算出する。プロンプト側と同じ関数なので、宙に浮いた
  `category` を持つエントリは UI でもプロンプトでも等しく未分類に数えられる
- **カテゴリ削除は用語を消さない**。確認ダイアログの上で、配下の用語を未分類（`category = nil`）へ移して
  からカテゴリを消す。単に `glossary_categories` から消すだけでも宙に浮いた参照は未分類に落ちるが、
  死んだ id をディスクに残すと、将来同じ id を再利用したカテゴリに勝手に復活してしまう
- カテゴリ名と追加指示は詳細ペインの上部でその場で編集する。**リネームは `name` しか触らない** ため、
  エントリは 1 件も書き換わらない（`id` を参照しているため。§1.2）
- `[+]` は UUID を採番して「新しいカテゴリ」を作り、選択したうえで名前フィールドにフォーカスする
- 行の右クリックメニュー「カテゴリを移動 ▸」で用語のカテゴリを変更する。ドラッグ&ドロップでも同じ操作が
  できる（§4.3）。当初はドラッグ&ドロップを「実装コストのわりに使用頻度が低い」として見送っていたが、
  並び替え機能（§4.3）の実装ついでに同じ `GlossaryEntryTransfer` payload を再利用でき、追加コストが
  小さくなったため両方とも入れることにした
- サイドバーぶんの幅が要るので `SettingsView` の `minWidth` は 680 → **760**

### 4.2 一覧・追加操作の不変条件

以下は用語集タブがフラットな 1 リストだった頃から引き継いでいる（そのまま詳細ペインに移設した）。

- **一覧はペインの残り高さいっぱいを占め、その中でスクロールする**（`ScrollView` を
  `.frame(maxHeight: .infinity)`）。何件登録しても「+ 用語を追加」ボタンは下端に固定される
- **絞り込みフィールド**（`GlossaryFilter.matchingIndices(in:query:)`）で用語・読みの部分一致に
  絞る。`localizedStandardContains` なので大小文字を区別しない。件数表示は絞り込み中のみ
  「3 / 12 件」形式にして、隠れた行が削除されたものと誤読されないようにする。表示行は
  **バケット ∩ 絞り込み**（`GlossaryCategorization` の結果と `GlossaryFilter` の結果の積）
- バケットを切り替えたときは絞り込みをクリアする（絞り込みが残ったままだと、空のカテゴリに見える）
- **各エントリは 1 行**: `HStack { TextField（用語）; TextField（読み）; 削除ボタン }` + 列見出し。
  かつて「一般」タブでこれが幅に収まらず 2 行に折っていたのは、幅を他セクションと分け合っていたため
- **`ForEach` の id は元配列の index**（絞り込み後の並び位置ではない）。でないと絞り込みやバケット切替の
  たびに行のアイデンティティ（とキーボードフォーカス）が別のエントリへ移る。表示行がバケット ∩ 絞り込み
  になった今はいっそう重要
- 行のバインディングはすべて index の境界チェックを通す（削除直後に SwiftUI が古い行のバインディングを
  一度評価することがあり、`config.yaml` の file watcher が配列を縮めることもあるため）
- 「+ 用語を追加」は空エントリ（`term: "", reading: ""`、`category` は選択中のバケット）を追加し、
  **絞り込みをクリアしてから**その行までスクロールして用語フィールドへフォーカスする（空エントリは
  どんな絞り込みにもマッチせず、そのままでは見えない行を追加してしまうため）。空 `term` の行は
  `GlossaryRenderer` でスキップされるので、未入力のまま残しても system prompt には影響しない
- **スクロールの駆動は `pendingScrollTarget`（追加操作専用の state）であって、フォーカス変化ではない**。
  フォーカスに追従させると 2 つ壊れる: 追加直後はまだ行が view tree に存在しないため
  `ScrollViewReader.scrollTo` が何も掴めず、リスト上部を表示中に追加すると新しい入力欄が画面外のままに
  なる（2026-07 の実機確認で発覚）。加えて、既存行をクリックしただけでリストが飛ぶ

### 4.3 カテゴリ移動と並び替え

「カテゴリを移動」の右クリックメニューに加えて、ドラッグ&ドロップでのカテゴリ移動と、バケット内の
並び替え（ドラッグ、および「上へ/下へ移動」の no-drag フォールバック）を追加する。

**ドラッグハンドル（`GlossaryEntryRow.swift`）**: 行の先頭に `line.3.horizontal` アイコンを置き、
**このアイコンだけがドラッグソース**にする。行の大半は `TextField`（用語・読み）で占められており、行
全体をドラッグ可能にすると、テキストフィールド上でのクリック&ドラッグが「キャレット移動・テキスト選択」
なのか「行のドラッグ」なのか曖昧になり、通常のテキスト編集と衝突する。ドラッグ操作を独立した非対話的な
アイコンに閉じ込めることで、この曖昧さそのものを消す。これがハンドルという要素を独立して持つ唯一の理由。

**ドラッグペイロード（`Kikimi/Glossary/GlossaryEntryTransfer.swift`）**:

```swift
struct GlossaryEntryTransfer: Codable, Transferable {
    let index: Int   // ドラッグ開始時点の AppConfig.shared.data.glossary index
    let term: String // 再検証トークン: ドラッグ開始時点のそのエントリの term
}
```

`UTType(exportedAs: "io.github.uphy.Kikimi.glossary-entry", conformingTo: .data)` で作った、
`Info.plist` に宣言していないカスタム UTType を使う。このペイロードはドラッグハンドルから
サイドバー行 / 並び替えセパレータへ、常に同一プロセス内でしか運ばれないため、システム全体への型登録
（`UTExportedTypeDeclarations`）は不要 -- `NSItemProvider` がプロセス内で対応する `.dropDestination(for:)`
にルーティングできれば十分。

**ドロップ時は必ず再検証する**: `index` が現在も `glossary` の範囲内、かつ `glossary[index].term ==
term` であることを両方確認してから変更を適用する。どちらかが崩れていればドロップは黙って無視する
（`AppConfig` のファイル watcher がドラッグ中に `config.yaml` を再読み込みして配列を縮める、あるいは
別の編集が同時に走る可能性があるため）。これは `GlossaryEntryRow` の各バインディングが行っている
境界チェックと同じ規律。

**サイドバーのドロップ先（`GlossaryCategorySidebar.swift`）**: 未分類行と各カテゴリ行がドロップを
受け付け、それぞれ `category = nil` / `category = <そのカテゴリの id>` を設定する。ドラッグ中は
ドロップ先候補の行をハイライトする。**`すべて` はドロップを一切受け付けない**（`.dropDestination` 自体を
付けない）。`すべて` は全カテゴリを横断する擬似バケットなので、そこへのドロップが「どのカテゴリへ」を
一意に意味できない。ハイライトもしない（ドロップ先に見えると誤解を招くため）。

**バケット内の並び替え（`Kikimi/Glossary/GlossaryReorder.swift`）**: SwiftUI に依存しない純粋関数
`GlossaryReorder.reordered(entries:bucketIndices:from:to:)` で実装し、view host なしで単体テストできる
ようにした。

- 一覧に見えている行は常に **バケット ∩ 絞り込み**（`GlossaryCategoryDetailView.visibleIndices`）。
  見えている順序をそのまま `glossary` に書き戻すと、他のバケットに属するエントリの絶対位置まで
  ずれてしまう。正しい操作は「現在のバケットに属するエントリだけを互いに並べ替え、それらが元々
  占めていた**絶対スロット**（バケットの昇順 index 列）にそのまま書き戻す」こと。バケット外のエントリは
  値も位置も一切動かない
- **`to` の意味は `onMove`（`List.onMove` / `IndexSet.move`）方式**: `to` は「削除前」のバケット順序
  リストにおいて、そのエントリを挿入すべき位置を表す。`from < to` のときは削除で後続要素が 1 つ前に
  詰まるため、実際の挿入位置は `to - 1` になる。並び替えセパレータの「ここに挿入」はこの規約とちょうど
  一致するよう、バケット位置 `p` の直後のセパレータには `to: p + 1` を渡す。「上へ/下へ移動」の隣接
  スワップは `to: position - 1`（上）/ `to: position + 2`（下）で表現する（`+ 1` は no-op になる。
  `GlossaryReorder.swift` の doc comment 参照）
- **絞り込み中は並び替えを無効化する**（並び替えセパレータを設置しない、「上へ/下へ移動」も出さない。
  ツールバー付近に「絞り込み中は並び替えできません」の注記を出す）。見えている集合がバケットの一部
  でしかないため、「この見えている行の前に挿入」がバケットの隠れたメンバーのどこに対応するのか
  一意に決まらない。**サイドバーへのドラッグ（カテゴリ移動）は絞り込み中でも無効化しない**
  （そちらの行き先は絞り込みの影響を受けず常に一意）
- **配列順序 = プロンプト順序**。`GlossaryRenderer` はカテゴリ内で `glossary` の配列順に用語を並べる
  （§2）ため、ここでの並び替えは Settings UI 上の見た目だけでなく、LLM に渡される用語の提示順を
  変える
- UI 上は行の間・前後に薄い `Color.clear`（固定高さ 6pt）のドロップターゲットを置き、挿入位置を
  可視化する。`LazyVStack` + `ScrollViewReader` + `pendingScrollTarget` の既存の仕組みと
  `ForEach(visibleIndices, id: \.self)` の identity 規則はそのまま維持する（`List` へは移行しない）
- 「上へ/下へ移動」は右クリックメニューに追加する no-drag フォールバック。バケットの端では disabled
  になり（隠れはしない）、絞り込み中はメニュー項目ごと出さない

## 5. テスト方針

**レイヤ 1（swift-testing）**:

- `GlossaryRenderer.header`: 「正しく書き起こされていても」置換する旨を含むこと / 単独行（reading なし）
  の意味を説明していること（§2.1 の回帰ガード。header 全文ではなく意味を担う節だけを assert し、
  文言のチューニング余地を残す）/ 出力してよいのが「→」の右側だと明示していること / マッチしない語を
  一覧へ無理に寄せない旨を含むこと（§2.2 の回帰ガード）
- `GlossaryRenderer.render(entries:categories:)`: 空配列 → nil / reading あり・なし / 複数エントリの
  順序保持 / 空白のみの `term` はスキップ / 全エントリ空白なら nil / trim される。カテゴリについては、
  `categories` 省略時が従来の平坦なレンダリングと完全一致すること / 未分類が見出しなしで先頭に来ること /
  カテゴリが `glossary_categories` 順に `## 名前` → instruction → 用語で並ぶこと / instruction 省略時は
  その行が出ないこと / 空カテゴリは見出しごと出力されないこと / 宙に浮いた `category` と空文字 `category`
  が未分類として描画されること
- `GlossaryCategorization`: nil / 空文字 / 空白のみ / 宙に浮いた id がすべて未分類になること /
  実在カテゴリのエントリは未分類に含まれないこと / 返る index が元配列のものかつ元の順序であること /
  カテゴリ 0 件ならすべて未分類 / **前後に空白のある id が、`indices(in:)` と `uncategorizedIndices` の
  どちらから見ても同じバケットに属すること**（どのバケットにも属さず消えないこと）
- `DictationContextResolver.resolve(bundleID:config:glossary:glossaryCategories:)`: glossary のみ
  （global/app 空） / global・glossary・app が結合順序どおり結合される / glossary が空 term のみなら
  寄与しない / glossary・glossaryCategories 引数省略時は既定の `[]` として振る舞う / categories を渡すと
  グルーピング済みブロックが注入されること
- `RefinementPromptBuilder.buildSystemPrompt(context:glossaryBlock:dedupSystemLeakSegments:)`:
  `glossaryBlock` 省略時（nil）は既存 prompt と完全一致 / 非 nil のとき「事前知識」の直後・
  「出力形式」の直前に挿入される / context が空文字でも用語集ブロックは正しく描画される
- `RefinementQueue`: `glossaryProvider` / `glossaryCategoriesProvider` のフェイクを注入し、
  レンダリング結果が**毎バッチ**の system prompt に含まれること（context のリロード周期に従わないこと）、
  `glossaryProvider` 省略時は用語集セクションが system prompt に一切現れないこと、
  `glossaryCategoriesProvider` 省略時は平坦なレンダリングになること
- `KikimiConfigData` の decode: `glossary:` キー欠落 → 空配列 / 正常な配列のデコード / 1 エントリ破損で
  配列全体が空にフォールバック + warning / 旧 `dictation.context.glossary` キーが残っていてもエラーに
  ならず単に無視されること（後方互換） / `category:` キー欠落 → nil
- `glossary_categories` の decode: キー欠落 → 空配列 / id・name・instruction のデコード（instruction
  省略時は空文字） / `id` 欠落など構造破損で配列全体が空にフォールバック / **`id` 重複は先勝ちで 1 件に
  縮約される**（配列全体を捨てない） / 宙に浮いた `glossary[].category` があってもデコードは成功し、値は
  verbatim に保持される / snake_case キー（`glossary_categories`）で保存される / round-trip
- **`renamingACategoryDoesNotTouchAnyEntry`**: カテゴリの `name` を書き換えて再ロードしても、エントリの
  `category`（= `id`）が 1 文字も変わらないこと。id/name 分離の存在理由そのもの
- `GlossaryFilter.matchingIndices(in:query:)`: 空・空白のみの query は全 index / 用語にも読みにも
  マッチする / 大小文字を区別しない / query が trim される / 返る index が元配列のものかつ元の順序で
  あること / 不一致・空配列で空を返すこと
- `GlossaryReorder.reordered(entries:bucketIndices:from:to:)`（§4.3）: 連続したバケット内での上へ/下への
  移動（隣接スワップ） / 非連続バケット（`bucketIndices` が `[0, 3, 4]` のような場合）でバケット外の
  エントリが値・絶対位置ともに変わらないこと / `from == to` と、その 1 つ下（`to == from + 1`）の
  no-op がどちらも配列を無変更で返すこと / range 外の `from`/`to`、空の `bucketIndices`、要素 1 個の
  バケットがすべて無変更を返すこと / 並び替え後のバケット内の相対順序が指示どおりであること /
  `GlossaryCategorization.indices(entries:in:)` を通した round-trip でバケットのレンダリング順が
  期待どおり変わること
- `GlossaryEntryTransfer`: `Codable` の round-trip（`index`/`term` が保持されること。非 ASCII な
  `term` を含む）

**レイヤ 2（kikimi-verify）**:

- Settings に「用語集」タブが常時表示され（`dictation.refine` の ON/OFF に関係なく）、6 タブすべてが
  `minWidth: 760` のタブバーに収まって `>>` オーバーフローメニューに畳まれないこと
- サイドバーに すべて / 未分類 / 各カテゴリが正しい件数で並ぶこと。`[+]` でカテゴリが作られ、そのまま
  名前を入力できること。`[−]` は すべて / 未分類 では disabled で、カテゴリでは確認ダイアログを出し、
  確定すると配下の用語が未分類へ移ること（消えないこと）
- カテゴリ名を変更しても、再選択したときに配下の用語が変わらないこと
- 行の「カテゴリを移動」context menu で用語が移動し、サイドバーの件数が追随すること
- すべて バケットでは各行にカテゴリ名ラベルが出て、「+ 用語を追加」が出ないこと
- 用語集タブで行追加・削除・編集ができ、1 行に用語・読み・削除ボタンが収まって視認できること
- 絞り込みが用語・読みの両方にヒットし、大小文字を区別せず、件数表示が「N / M 件」に変わること
- **リスト上部を表示している状態で「+ 用語を追加」を押しても、新しい入力欄までスクロールして
  フォーカスが当たること**（逆に、既存行をクリックしただけではスクロールが起きないこと）
- 「一般」タブに用語集セクションが残っておらず、Wiki Export まで一画面内でスクロールして到達できること
- **（§4.3）** 行のドラッグハンドルを未分類 / 別カテゴリの行へドラッグするとカテゴリが移動し、
  ドロップ先候補の行がドラッグ中ハイライトすること。`すべて` へドラッグしてもハイライトせず、ドロップも
  効かないこと
- **（§4.3）** 同一バケット内で行をドラッグし、行間のセパレータへドロップすると並び順が変わり、
  他バケットの用語の順序・カテゴリは変わらないこと。絞り込み中はセパレータが出ず、行の「上へ/下へ移動」
  メニュー項目も出ないこと（絞り込みを解除すると両方戻ること）
- **（§4.3）** 右クリックメニューの「上へ移動」/「下へ移動」でバケット内の並びが 1 つずつ動き、
  バケットの先頭/末尾では該当ボタンが disabled になること

**レイヤ 3（実戦）**:

- 会議書き起こし・ディクテーションの両方で、用語集に登録した固有名詞が実際に正しい表記へ置換されること
