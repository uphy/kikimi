# プロンプト上書き

Kikimi がアプリ内に固定で持っている LLM プロンプトの「方針層」（役割宣言・整形ルール・編集方針など）は、
`~/.config/kikimi/prompts/` 配下の Markdown ファイルで上書きできる。**ファイルが無ければ組み込み
default が使われ、ファイルがあれば上書きが使われる。** JSON schema・出力形式指示・patch 操作契約などの
「契約層」はアプリが自動で付与するため、override ファイルからは触れない（設計は
[`docs/design/42-prompt-overrides.md`](design/42-prompt-overrides.md) を参照）。

編集はファイルの直接編集 + ヘッドレス CLI（`--eject-prompt` / `--validate-prompts` / `--render-prompt` /
`--list-prompts`）で行う。アプリ内に汎用プロンプトエディタは無い（ディクテーションの「アプリ別
コンテキスト」設定だけは例外で、既存 Settings UI がそのまま override ファイルの読み書きに接続される）。

## 対象プロンプト一覧

| id | 現在の所在 | 方針層（編集可） | 契約層（編集不可・アプリが自動付与） | placeholder | reload |
|---|---|---|---|---|---|
| `refinement` | `RefinementPromptBuilder` | 役割宣言 + 整形ルール | 【事前知識】（context + 用語集）+【出力形式】（segments 配列） | なし（任意: `{{leak_dedup_rule}}`） | session-start |
| `summary` | `SummaryPromptBuilder` | 役割宣言 + 編集方針 | 【patch 契約】（participants_add / decisions 追加のみ / action_items add・modify・complete） | なし | immediate |
| `final-title` | `SummaryUpdater+FinalTitle.swift` | 全文 | なし（structured output schema が強制） | なし | immediate |
| `chat` | `ChatPromptBuilder` | 全文 | なし（answer schema が強制） | なし | immediate |
| `simple-watcher` | `SimpleWatcherSpec.systemPrompt(forViewpoint:)` | 全文 | なし（markdown フィールドは schema が強制） | `{{viewpoint}}` | session-start |
| `glossary-header` | `GlossaryRenderer.defaultHeader` | ヘッダ全文 | 用語 bullet・カテゴリ見出し・カテゴリ instruction の描画（コードが生成） | なし | dictation は immediate / 会議整形経由は session-start |
| `dictation` | 旧 `dictation.context.global`（config.yaml から移行） | 整形ルール本文 | `DictationRefiner.preamble` +【出力形式】suffix | なし | immediate |
| `dictation/apps/<bundle-id>` | 旧 `dictation.context.apps[]`（config.yaml から移行） | そのアプリ向け追加指示 | アプリ名ラベルの付与 | なし | immediate |

Watcher full 形式（`watchers/<id>.md`）と LLM ヘルスチェック probe プロンプトはこの機構の対象外
（前者は既に完全ユーザー定義、後者は外部化のスコープ外）。

## ファイルの置き場所と形式

### ディスクレイアウト

```text
~/.config/kikimi/prompts/
├── refinement.md
├── summary.md
├── final-title.md
├── chat.md
├── simple-watcher.md
├── glossary-header.md
├── dictation.md
└── dictation/
    └── apps/
        └── <bundle-id>.md        # 例: com.microsoft.VSCode.md
```

- id → ファイルパスは `prompts/<id>.md` に 1:1 対応する。パスの設定項目は config.yaml に無い
  （`~/.config/kikimi/prompts/` に固定。CLI・テストだけ `--prompts-dir` で差し替え可能）
- `dictation/apps/<bundle-id>` の bundle id は `[A-Za-z0-9._-]+` に限る。それ以外の文字を含む
  ファイル名は無視され debug ログが出る
- 3 階層のディレクトリ（`prompts/` / `prompts/dictation/` / `prompts/dictation/apps/`）はアプリが
  起動時に自動で作成する。空ディレクトリを作るだけで、default プロンプトの実体化はしない

### frontmatter + 本文

Watcher の `.md`（`watchers/*.md`）と同じ「`---` 区切りの YAML frontmatter + 本文」形式。
`--eject-prompt simple-watcher` の出力例:

```markdown
---
# Kikimi のプロンプト override ファイル。削除するとアプリ内蔵の既定プロンプトに戻ります。
# 編集の作法: このファイルは `--eject-prompt` で生成し、編集後に `--validate-prompts` で検証すること。
prompt: simple-watcher
based_on: 4f8a2c19d3e0        # eject 元 default 本文の SHA-256 先頭 12 桁（staleness 検出用）
reload: session-start          # このプロンプトの反映タイミング（アプリ側仕様の写し。参考情報）
placeholders:
  required: ["{{viewpoint}}"]  # 本文に必ず残すこと。欠けると override 全体が無効になり default に戻る
  optional: []
---

あなたは会議のリアルタイム書き起こしを観察するアシスタントです。
...
```

frontmatter フィールド:

| フィールド | 必須 | 権威 | 意味 |
|---|---|---|---|
| `prompt` | 必須 | ファイル | 対象 id。パスから導出した id と不一致なら invalid（コピペ事故・誤リネーム検出） |
| `based_on` | eject が付与 | ファイル | eject 時点の default 本文ハッシュ。欠落は warning |
| `reload` | eject が付与 | アプリ | 参考情報。実際の反映タイミングは常にアプリ内蔵の仕様が権威。ファイル記載とのドリフトは `--validate-prompts` が警告する |
| `placeholders` | eject が付与 | アプリ | 参考情報。同上 |

本文の規則:

- 先頭・末尾の空白改行は trim してから使う
- 32KB（UTF-8 バイト）を超えたら warning を出して clamp する（`context.md` と同じ規則）
- trim 後に本文が空だと、原則 invalid（default にフォールバック）。**例外は `dictation` と
  `dictation/apps/<bundle-id>`**: 空本文は valid な override として扱われ、「文脈を一切注入しない」
  という意味になる
- 本文中の `{{...}}` のうち、そのプロンプトが認識しない placeholder はそのまま文字として残る
  （`--validate-prompts` が WARN として報告する）

不正な override は **warning ログを出したうえで default にフォールバックする**。録音・整形は止まらない。

## 反映タイミング（reload）

| id | 反映 |
|---|---|
| `refinement` / `simple-watcher` | 次のセッション開始時（Recording 開始時に system prompt がスナップショットされ、セッション中は編集しても反映されない。prompt cache のヒット率を維持するため） |
| `summary` / `final-title` / `chat` | 次回呼び出しから即時 |
| `glossary-header` | dictation 経由は即時。会議整形（refinement）経由はセッション開始時スナップショットの一部として固定 |
| `dictation` / `dictation/apps/<bundle-id>` | 次の発話から即時 |

録音中の「今すぐ反映」ボタン（`refreshContextNow()`）は context.md・参加者ブロックのみを再読込する。
`refinement` / `simple-watcher` の方針層は対象外なので、これらを変えたい場合は次回セッション開始を
待つ必要がある。

## CLI

Kikimi.app のバイナリにヘッドレスの引数を渡すと、GUI を起動せずにコマンドを実行して終了する。

```bash
KIKIMI=~/Applications/Kikimi.app/Contents/MacOS/Kikimi
$KIKIMI --eject-prompt refinement
```

アプリ本体が起動中でも安全に実行できる（CLI の書き込みは起動中プロセスの watch が拾って反映する）。

### `--eject-prompt <id> [--force] [--out <path>]`

組み込み default を frontmatter 付き override ファイルとして書き出す。

- 出力先は既定で `prompts/<id>.md`。`--out <path>` で任意パスへ書き出せる（後述の diff 用途）
- 既存ファイルがあれば何もせず exit 2。上書きするには `--force` を付ける
- `dictation/apps/<bundle-id>` は default 本文を持たないため、注意コメント付きの空本文スケルトンが出る
- exit code: `0` 書き出し成功 / `1` unknown id・I/O エラー / `2` 既存ファイルあり（`--force` なし）

### `--validate-prompts [<id> ...]`

override ファイルを検証する。引数を省略すると `prompts/` を（`dictation/apps/*` も含めて）全走査する。

- 出力は 1 件 1 行:
  - `ERROR <path>: <message>` — default にフォールバックする不備（frontmatter 不正・`prompt` 不一致・
    必須 placeholder 欠落・本文空など）
  - `WARN <path>: <message>` — 未知 placeholder・`reload`/`placeholders` 写しのドリフト・`based_on`
    欠落・32KB 超過・無視される謎ファイルなど
  - `STALE <path>: based_on <hash> != current <hash>` — アプリの default 本文が eject 後に更新された
- exit code: `0` 問題なし / `1` ERROR あり / `2` WARN・STALE のみ

### `--render-prompt <id>`

override（あれば）と契約層・内蔵サンプルデータで最終 system prompt を組み立てて stdout に出す。
実行中のアプリと同じ組み立て関数を通すので、編集した override が実際どう展開されるかを確認できる。

- サンプルデータは決定論的な内蔵固定値（実セッションのデータは使わない）
- override が invalid なら default で組み立てたうえで stderr に WARN を出し exit 2
- exit code: `0` 正常出力 / `1` unknown id / `2` フォールバック発生

### `--list-prompts`

全 id の状態を一覧で出す（発見性のため）。

```text
<id>\t<override|default|invalid>\t<current|stale|->
```

exit code は常に `0`。

## dictation.context の移行について

以前は `config.yaml` の `dictation.context.global` / `dictation.context.apps[]` にディクテーション用の
文脈を書いていたが、この機構の導入により `prompts/dictation.md` /
`prompts/dictation/apps/<bundle-id>.md` へ移設された。初回起動時に 1 回だけ自動移行される
（カスタマイズ済みの本文はそのまま override として書き出され、未カスタマイズの default 相当の本文は
移行されない）。`global` が空文字（文脈を一切注入しない、という明示的な設定）だった場合は空本文の
override として書き出される。空文字を「未カスタマイズ」扱いして移行をスキップすると、default の
整形ルールが無警告で復活してしまうため。移行後は `config.yaml` 側の `dictation.context` キーが
残っていても無視されるだけでエラーにはならない。以後の編集は `prompts/dictation.md` を直接編集するか、
Settings の「アプリ別コンテキスト」セクションを使う。

## stale になった override を取り込む手順（coding agent 向け）

アプリの更新で default プロンプトが改善されることがある。`--validate-prompts` が
`STALE <path>: based_on <hash> != current <hash>` を報告したら、override の `based_on` が古いバージョンの
default を指したままになっている。**アプリは自動追従しない**ので、取り込むかどうかは人間 / agent の判断
に委ねられる。以下の手順で取り込む。

1. **現行 default を一時パスへ eject する**

   ```bash
   $KIKIMI --eject-prompt <id> --force --out /tmp/<id>-new-default.md
   ```

   既存の override は変更されない（`--out` を指定しているため）。

2. **旧 `based_on` 時点の default との diff を確認する**

   `based_on` はハッシュしか保持していないため、対応する本文そのものはファイルに残っていない。
   default 本文は Kikimi の Swift ソース（`Kikimi/Prompts/` 配下の `PromptSpec` 定義）の文字列リテラル
   としてバージョン管理されているので、`git log -p` でその id の default が変わった履歴を辿り、
   `sha256` の先頭 12 桁が override の `based_on` と一致する版を特定する。特定できたら、その版と
   手順 1 で出力した現行 default を diff し、アプリ側で何が変わったか（表現の修正か、ルールの追加・
   削除か）を把握する。
   `based_on` が空 / 対応版が特定できない場合は、現行 default と手元の override 本文を直接 diff し、
   自分のカスタマイズ箇所を壊さないよう注意しながら差分を読む。

3. **手元の override へ反映する**

   自分が加えたカスタマイズ（方針層の言い回し・追加ルールなど）を維持したまま、手順 2 で確認した
   アプリ側の変更点だけを `prompts/<id>.md` の本文へ手作業でマージする。

4. **`based_on` を新ハッシュへ更新する**

   frontmatter の `based_on` を、手順 1 の eject 結果に書かれているハッシュ（または
   `--validate-prompts` / `--list-prompts` が報告する現行ハッシュ）へ書き換える。

5. **検証する**

   ```bash
   $KIKIMI --validate-prompts <id>
   ```

   `STALE` が消え、`ERROR` が無いことを確認する。必要なら `--render-prompt <id>` で最終プロンプトを
   目視確認する。

`dictation/apps/<bundle-id>` は default を持たないため、この stale 検知・取り込み手順の対象外
（`based_on` は常に無し）。
