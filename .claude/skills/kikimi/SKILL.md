---
name: kikimi
description: >-
  Kikimi のユーザー操作をまとめた入口 skill。プロンプト調整と会議準備の 2 ドメインを持ち、
  依頼に応じて references/ の該当ファイルを読んでから作業する。
  プロンプト調整:「プロンプトを調整して」「整形ルールを変えて」「サマリの方針を変えて」
  「ディクテーションの整形を◯◯にして」「プロンプトの override を作って / 検証して / 既定に戻して」
  「STALE を取り込んで」。
  会議準備:「会議の準備をして」「次の◯◯会議のプロファイルを作って」「Kikimi に会議情報をセットして」
  「この議題で聞き耳の準備をして」。
  そのほか Kikimi の利用者としての操作（録音アプリとしての設定・準備）を頼まれたときに使う。
  開発時の動作確認は対象外（kikimi-verify を明示指示時のみ使う）。
argument-hint: "[prompts|meeting] <依頼内容>（例: prompts 整形ルールを強めて / meeting 明日のAcme定例）"
---

# kikimi — ユーザー操作の入口

依頼を下表でルーティングし、**該当 reference を必ず読んでから**作業する（この SKILL.md だけで作業を
始めない）。引数の第 1 トークン（`prompts` / `meeting`）があればそれに従い、無ければ依頼文から判断する。

| 依頼 | reference |
|---|---|
| プロンプトの調整・override の作成 / 検証 / 削除・STALE 取り込み | [references/prompts.md](references/prompts.md) |
| 会議プロファイルの生成・更新・掃除、会議前の準備 | [references/prepare-meeting.md](references/prepare-meeting.md) |

どちらにも当てはまらない Kikimi 操作（例: 設定ファイルの場所を聞かれた）は、下の共通前提と
リポジトリの `docs/` で答える。

## 共通前提

```bash
KIKIMI=~/Applications/Kikimi.app/Contents/MacOS/Kikimi   # mise run apply 済みの通常環境
# 未インストール環境では: swift build && KIKIMI=./.build/debug/Kikimi
```

- config: `~/.config/kikimi/config.yaml`、state: `~/.local/state/kikimi/state.yaml`
- プロンプト override: `~/.config/kikimi/prompts/`、会議プロファイル: `~/.config/kikimi/profiles/`、
  watcher preset: `~/.config/kikimi/watchers/`
- ウィンドウ操作は `kikimi://` URL scheme（例: `open "kikimi://window/new?profile=<id>"`）
- アプリ起動中でもファイル編集・CLI 実行は安全（起動中プロセスが watch して反映する）

## 運用ルール

- 新しいユーザー操作ドメインを足すときは references/ にファイルを追加し、この表と frontmatter の
  description にトリガ語を追記する
- 発火はこの description だけで判定されるため、ドメインが増えて description が肥大しマッチ精度が
  落ちてきたら、そのドメインを独立 skill に戻す（router は原則であって教義にしない）

## セットアップ（初回のみ）

リポジトリの外から使う場合は user-level skills へ symlink を張る:

```bash
ln -s /path/to/kikimi/.claude/skills/kikimi ~/.claude/skills/kikimi
```
