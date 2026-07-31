# プロンプト調整

Kikimi のプロンプトは「ファイルなし = アプリ内蔵 default、ファイルあり = 上書き」の override 方式。
仕様の正はリポジトリの `docs/prompts.md`（id 一覧・placeholder・reload・CLI・stale 取り込み手順）と
`docs/design/42-prompt-overrides.md`。このファイルは作業ループと注意点だけを持つ。
`$KIKIMI`（バイナリパス）は SKILL.md の共通前提を参照。

## 作業ループ

1. **現状確認** — `$KIKIMI --list-prompts` で全 id の `override|default|invalid` と `current|stale` を見る
2. **eject（override が無い id を編集するとき）** — `$KIKIMI --eject-prompt <id>` で現行 default を
   frontmatter 付きで書き出す。**白紙からプロンプトを書き起こさない**: default には実戦チューニング
   （用語集ヘッダの矢印形式など）が蓄積されており、eject → 部分編集がそれを保存する
3. **編集** — 本文（方針層）だけを編集する。frontmatter の `prompt:` / `based_on:` /
   `placeholders:` / `reload:` は触らない（`placeholders.required` に列挙されたトークン、例:
   simple-watcher の `{{viewpoint}}` は本文に必ず残す。欠けると override 全体が invalid になり default に戻る）
4. **検証** — `$KIKIMI --validate-prompts <id>`。exit 0 で完了、1 は ERROR（修正必須）、2 は WARN/STALE
5. **プレビュー（任意）** — `$KIKIMI --render-prompt <id>` で契約層込みの最終 system prompt を確認
6. **反映タイミングをユーザーに伝える** — frontmatter の `reload:` が `immediate` なら即時、
   `session-start`（refinement / simple-watcher）なら次の録音セッションから

## よくある依頼と対応

| 依頼 | 対応 |
|---|---|
| 「◯◯の指示を強めて / 変えて」 | 該当 id を eject（済みなら直接）→ 本文編集 → validate |
| 「既定に戻して」 | `rm ~/.config/kikimi/prompts/<id>.md`（削除 = 組み込み default 復帰） |
| 「ディクテーションで文脈を一切入れないで」 | `dictation` の override を**空本文**にする（dictation 系のみ空本文が有効な設定） |
| 「Slack のときだけ◯◯」 | `prompts/dictation/apps/<bundle-id>.md` を作成（bundle id は `[A-Za-z0-9._-]+`。based_on 行は書かない） |
| 「STALE が出ている」 | docs/prompts.md「stale になった override を取り込む手順」に従う（`--eject-prompt <id> --force --out /tmp/...` で現行 default を取り出し diff → 手動マージ → based_on を現行 hash に更新 → validate） |

## 注意

- 契約層（JSON schema・【出力形式】・【patch 契約】）はアプリが自動付与するので、override で書き直そうと
  しない。書いても二重になるだけ
- simple-watcher の「seg ID を本文に書く」ルールを消すと、Watcher 出力から発言へジャンプする UI 機能が
  退化する（eject ファイルの frontmatter コメントにも明記されている）
- default 本文そのものを改善したい（全ユーザー向けに変えたい）場合は override ではなく
  `Kikimi/Prompts/PromptSpec.swift` の該当定数を編集する開発作業になる。既存テストに default 同値性
  テストがあるため、`swift test --filter Prompt` まで回すこと
