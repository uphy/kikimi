---
name: kikimi-prepare-meeting
description: >-
  会議情報（議題・参加者・確認したいこと）から Kikimi の会議プロファイル
  （context / summary template / watchers）を生成し、検証して Draft ウィンドウを開くスキル。
  「会議の準備をして」「次の◯◯会議のプロファイルを作って」「Kikimi に会議情報をセットして」
  「この議題で聞き耳の準備をして」など、Kikimi で録音する会議の事前準備を頼まれたときに使う。
---

# kikimi-prepare-meeting

会議の説明テキストを受け取り、`~/.config/kikimi/profiles/<id>/` に会議プロファイル一式を生成して
`kikimi://window/new?profile=<id>` で Draft ウィンドウを開く。

仕様の正は Kikimi リポジトリの `docs/design/41-meeting-profiles.md`。この skill の実体は同リポジトリの
`.claude/skills/kikimi-prepare-meeting/` にあるので、symlink 経由で起動された場合は SKILL.md の実体パス
（`realpath`）から `../../../docs/design/41-meeting-profiles.md` で解決できる。プロファイル形式に迷ったら
必ず仕様を読む（特に §2 データモデル・§4 解決順序）。

## 手順

### 1. 入力を確認する

- 基本入力は会議の説明テキスト: 会議名・目的・議題・参加者・事前に確認したいこと・関連する背景
- カレンダー予定・Notion 議事録・過去メールなどの参照は、**ユーザーが明示的に指示した場合のみ**
  利用可能なツールで取得する（勝手に外部ソースを漁らない）
- 確認したいことが曖昧なら、生成前にユーザーへ 1 度だけ確認する（会議開始直前に使われる想定なので
  質問は最小限にする）

### 2. プロファイル id を決める

- id は `[A-Za-z0-9-]+`（ディレクトリ名 = id）。例: 定例 `acme-weekly`、単発 `20260805-acme-kickoff`
- 先に `~/.config/kikimi/profiles/` を一覧し、同じ会議の既存プロファイルがあれば**新規作成ではなく更新**する
- プロファイルは名前付きで永続。定例は使い回し、掃除は手動（ユーザーに頼まれたら §5 の掃除を行う）

### 3. ファイルを生成する

生成先とファイル（すべて任意ファイルはフォールバックがあるので、**会議に必要な差分だけ**書く）:

| ファイル | 内容 |
|---|---|
| `profiles/<id>/profile.yaml` | 必須。`name`（表示名、日本語可）・`description`・`enabled_watchers`（preset id のリスト） |
| `profiles/<id>/context.md` | 会議の背景・参加者・議題・固有名詞・専門用語。整形とサマリの精度に直結するので具体的に書く |
| `profiles/<id>/summary_template.md` | 既定テンプレで足りるなら**作らない**。見出し構成を変えたいときだけ書く |
| `~/.config/kikimi/watchers/<id>-*.md` | 会議固有の watcher。**プロファイル内には置けない**（下記） |

watcher の注意:

- watcher 定義の実体は `~/.config/kikimi/watchers/`（グローバル preset）のみ。プロファイルは
  `enabled_watchers` で preset id を参照するだけで、定義を同梱できない
- 会議固有の watcher を作るときは、掃除しやすいように **id をプロファイル id で prefix する**
  （例: `acme-weekly-precheck`）。汎用的に使える watcher は prefix なしの汎用 preset として育てる
- 形式は 2 種類。事前確認事項の追跡など **状態を持つ**ものはフル形式（kikimi.md 9 章）、
  「この観点で気付きを出して」だけなら `kind: simple`（`docs/design/34-simple-watchers.md`）で足りる
- `enabled_watchers` に書いた id の preset ファイルが実在することを必ず確認する

summary_template.md で参照できる変数（schema 固定。これ以外は使えない）:
`{{title}}` `{{overview}}` `{{#participants}}{{name}}{{is_last}}{{/participants}}`
`{{#decisions}}{{text}}{{/decisions}}` `{{#action_items}}{{task}} {{assignee}} {{due}}{{/action_items}}`

### 4. 検証する

生成後、必ず同梱の検証スクリプトを実行する:

```bash
ruby "<この skill の実体ディレクトリ>/scripts/validate.rb" <profile-id>
```

エラーが出たら修正して再実行し、エラーゼロになるまで繰り返す。warning は内容を確認し、
意図的なもの（例: 既定テンプレを使うので summary_template.md なし）はそのまま進めてよい。

### 5. Draft ウィンドウを開く

```bash
open "kikimi://window/new?profile=<id>"
```

最後に、生成したプロファイルの概要（id・context の要点・有効化した watcher と各々の狙い）を報告し、
**内容の最終確認と録音開始はユーザーが行う**ことを明記する。

## 掃除（頼まれたとき）

- プロファイル削除 = `profiles/<id>/` の削除 + そのプロファイル専用 watcher
  （`watchers/<id>-*.md`）の削除。ただし watcher が他プロファイルの `enabled_watchers` から
  参照されていないことを確認してから消す
- 過去セッションはプロファイルのコピーを持っているので、プロファイルを消しても影響しない

## セットアップ（初回のみ）

Kikimi リポジトリの外から使う場合は、user-level skills へ symlink を張る:

```bash
ln -s /path/to/kikimi/.claude/skills/kikimi-prepare-meeting ~/.claude/skills/kikimi-prepare-meeting
```
