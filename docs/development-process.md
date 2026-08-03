# Kikimi 開発プロセス

`kikimi.md`（プロダクト仕様）から分離した、開発方式・移行計画に関する章。実装サイクルや
workflow の運用を確認するときに読む。プロダクト仕様そのもの（不変条件・データモデル・
パイプライン仕様）は `kikimi.md` を見ること。

---

## 1. Chirami 移行計画

### 1.1 ロードマップ

| フェーズ | 内容 | Kikimi バージョン |
|---------|------|------------------|
| Phase 1 | 録音・書き起こし・JSONL 保存・UI 表示 | v0.1 |
| Phase 2 | Haiku 整形・サマリ・自動タイトル | v0.2 |
| Phase 3 | 登録 Watcher・Wiki export・Raycast 連携 | v0.3 |
| Phase 4 | 実戦投入（リアル会議で使う） | v0.4 |
| **判定** | **リアル会議3本以上を問題なく録音・整形できたら次へ** | — |
| Phase 5 | Chirami の transcript block を deprecated 表示 | Chirami 次リリース |
| Phase 6 | Chirami から transcript block・sherpa-onnx 依存を削除 | Chirami その次のリリース |

### 1.2 Chirami 削除対象（Phase 6 で除去）

- `Chirami/Blocks/Transcript/` 一式（Swift 側）
- `editor-web/src/extensions/transcript.ts` および関連 CodeMirror 拡張
- sherpa-onnx SPM 依存
- `~/.local/state/chirami/models/sherpa-onnx/` は残置（ユーザーに手動削除を促す）
- `docs/configuration.md` の transcript セクション

### 1.3 移行期間中の相互運用

- Kikimi 側は Wiki export に集中し、Chirami の `.md` を直接触らない
- ユーザーが望めば Kikimi の export 先を Chirami で開いているノートフォルダにできる（結果的にフローティング閲覧できる）
- Chirami の transcript block は Phase 5 で「Kikimi をお勧めします」の非侵襲的な誘導を追加

---

## 2. 開発方式（Vibe Coding）

### 2.1 開発モデル

**Claude Code を主導ドライバ、ユーザー（uphy）をレビュアー・意思決定者**として位置付ける。

- Claude Code が「詳細設計 → セルフレビュー → 実装 → 実装レビュー → 単体テスト」までを **1 サイクルとして自律的に回す**
- ユーザーは以下のポイントだけで介入する
  - Phase 開始時の目標合意
  - 詳細設計レビューでの Go/No-Go 判断
  - 実装完了時の動作確認（UI 動作確認・リアル会議確認）
  - ロードマップ調整
- UI 動作確認は基本的にユーザーが行う。phase-cycle / fix-cycle には UI 検証ステップを含めない。
  Claude が `kikimi-verify` skill を実行するのは、ユーザーから明示的に指示されたとき
  （「動作確認して」や `kikimi-ui-verify` workflow の実行指示）のみ

### 2.2 技術スタック

Chirami と同じスタックを踏襲。理由: sherpa-onnx / AVAudioEngine / ScreenCaptureKit / NSPanel の実装ノウハウがそのまま参照でき、`chirami-verify` skill の UI 自動検証パターンも流用できる。

| レイヤ | 技術 |
|--------|------|
| 言語 | Swift 6 |
| UI | AppKit（NSPanel）+ SwiftUI（コンテンツ）|
| ビルド | xcodegen + `project.yml`、mise タスク |
| パッケージ | SPM |
| 設定 | Yams（YAML）|
| STT | sherpa-onnx（SPM）|
| 音声取込 | AVAudioEngine（マイク）+ ScreenCaptureKit（システム音声）|
| Claude API | 公式 Anthropic Swift SDK（あれば）or `URLSession` ベースの薄いクライアント |
| Markdown 表示 | WKWebView + `markdown-it` + mermaid（`web/`、`docs/design/39-webview-markdown.md`）。MVP では MarkdownUI を使い WKWebView を回避していたが、mermaid とコードハイライトのために置き換えた。**編集**は `NSTextView` のまま |
| テスト | XCTest（Swift 単体）+ vitest（`web/` 単体）+ `kikimi-verify` skill（UI 動作確認）|

### 2.3 参考リポジトリ（Chirami）

**別ディレクトリ並列クローン方式**。

- 前提: chirami がローカルに並列クローンされている（場所は CLAUDE.local.md に記載）
- Kikimi の `CLAUDE.local.md` に参考リポジトリの場所を明記し、Claude Code が Read/Grep で直接参照できるようにする
- **submodule にはしない**: Kikimi のクローンに Chirami の全履歴を巻き込むのはノイズ。ローカルパスを触れるのは開発者だけで十分
- Claude Code が Chirami を参照する典型パターン
  - sherpa-onnx 初期化コード → `chirami/Chirami/Blocks/Transcript/`
  - NSPanel 実装 → `chirami/Chirami/Window/NoteWindow.swift`
  - AVAudio + ScreenCapture 統合 → `chirami/Chirami/Services/AudioCapture*`
  - Yams config パターン → `chirami/Chirami/Config/`
  - mise タスク雛形 → `chirami/.mise/tasks/`
  - chirami-verify skill → `~/.claude/skills/chirami-verify/`

### 2.4 設計ドキュメントの置き場

機能別に `docs/design/*.md` を作り、Claude Code が実装前に必ず読み込む。

```
kikimi/
├── kikimi.md                   # 全体設計・単一真実
├── docs/
│   ├── development-process.md  # このファイル（開発方式・移行計画）
│   ├── design/
│   │   ├── 00-architecture.md          # 全体アーキテクチャ
│   │   ├── 01-audio-capture.md         # 2ストリーム音声取込
│   │   ├── 02-stt-pipeline.md          # TranscriptPipeline（接着層）詳細設計
│   │   ├── 03-refinement-batch.md      # Haiku バッチ整形
│   │   ├── 04-summary-updater.md       # サマリ更新
│   │   ├── 05-watcher-runner.md        # Watcher 実行
│   │   ├── 06-ui-panels.md             # UI レイアウトと状態
│   │   ├── 07-session-store.md         # ファイル I/O
│   │   ├── 08-wiki-export.md           # LLM Wiki export
│   │   └── 09-raycast-integration.md   # URL scheme + CLI
│   └── references/
│       └── chirami-map.md      # Chirami 内の該当実装への案内マップ
├── CLAUDE.md
├── CLAUDE.local.md
└── ...
```

- **`kikimi.md`は全体像・不変条件**を書く
- **`docs/design/*.md` は機能単位の詳細**を書く（API、型、状態遷移、失敗モード）
- 実装フェーズごとに1つずつ設計ドキュメントを書き起こし → レビュー → 実装、のサイクルを回す

### 2.5 開発フェーズ内サイクル

各機能について、以下の **1 サイクル = 1 Dynamic Workflow** として実行する。

```
[1. 詳細設計]
   ↓ docs/design/NN-<feature>.md を書く（Claude が起草）
[2. 設計レビュー（並列 subagent 3種）]
   ↓ code-reviewer / swe / persona-junior (ユーザー役)
[3. 設計修正・確定]
   ↓
[4. 実装（機能を分割して pipeline）]
   ↓ 各モジュールごとに実装 → セルフレビュー → ユニットテスト
[5. 統合]
   ↓ mise run build && mise run apply
[6. 実装レビュー（並列 subagent）]
   ↓ code-reviewer で最終レビュー
[7. Phase 完了報告]
   ↓ UI 動作確認はユーザーが実施（必要なら kikimi-ui-verify を指示）
```

このサイクルを **1 つの Workflow script として書き下す**ことで、途中で止まっても resume でき、各ステップの成果物が journal に残る。

### 2.6 Dynamic Workflow の使い方

Workflow tool を「1 サイクル = 1 workflow 呼び出し」の粒度で使う。**Phase 単位で workflow を書き分ける**（Phase 1: 音声取込〜JSONL 保存、Phase 2: 整形、など）。

#### Workflow スクリプトの保存場所

```
kikimi/
└── .claude/
    └── workflows/
        ├── design-review.js            # 設計を並列レビュー
        ├── implement-module.js         # 実装 → セルフレビュー → テスト
        ├── ui-verify.js                # kikimi-verify を呼んで動作確認
        └── phase-cycle.js              # 上記を組み合わせた1サイクル
```

#### phase-cycle.js のスケルトン（概念）

```javascript
export const meta = {
  name: 'kikimi-phase-cycle',
  description: 'Kikimi 1機能を設計→レビュー→実装→検証まで一括で回す',
  phases: [
    { title: 'Design' },
    { title: 'Design Review' },
    { title: 'Implement' },
    { title: 'Self Review' },
    { title: 'Unit Test' },
    { title: 'Final Review' },
  ],
}

// args: { feature: 'audio-capture', design_doc: 'docs/design/01-audio-capture.md' }

phase('Design')
const design = await agent(`docs/design/${args.feature}.md を起草せよ。...`, { schema: DESIGN_SCHEMA })

phase('Design Review')
const reviews = await parallel([
  () => agent('code-reviewer 視点で設計レビュー', { schema: REVIEW_SCHEMA }),
  () => agent('swe 視点で設計レビュー', { schema: REVIEW_SCHEMA }),
  () => agent('実装可能性チェック', { schema: REVIEW_SCHEMA }),
])
// 問題があれば1回だけ設計を修正
if (reviews.some(r => r?.blockers?.length)) {
  await agent('レビュー指摘を反映して設計を更新', { schema: DESIGN_SCHEMA })
}

phase('Implement')
const modules = await agent('実装対象モジュールをリストアップ', { schema: MODULE_LIST_SCHEMA })
const implementations = await pipeline(
  modules.list,
  m => agent(`${m.name} を実装せよ。${m.spec}`, { label: `impl:${m.name}` }),
  (impl, m) => agent(`${m.name} の実装をセルフレビュー`, { label: `review:${m.name}` }),
  (review, m) => agent(`${m.name} の単体テストを書いて実行`, { label: `test:${m.name}` }),
)

// UI 動作確認はサイクルに含めない（ユーザーが実施。必要なら kikimi-ui-verify を別途指示）

phase('Final Review')
const finalReview = await agent('全実装の code-review を実施', { schema: FINAL_REVIEW_SCHEMA })

return { design, implementations, finalReview }
```

#### 起動する典型シーン

- Claude Code のターン内で `Workflow({ scriptPath: '.claude/workflows/phase-cycle.js', args: { feature: 'audio-capture' } })` を呼ぶ
- 途中で失敗しても `resumeFromRunId` で続きから再開
- ユーザーは `/workflows` でリアルタイムに進捗を眺める

#### Dynamic であることの活用ポイント

- **設計レビューの指摘数**に応じて修正 agent の起動有無を分岐
- **実装対象モジュール数**に応じて pipeline のアイテム数を動的決定
- **単体テスト失敗**があった場合、失敗数分だけ fix agent を並列起動
- **UI 動作確認の失敗**（ユーザー指示で `kikimi-ui-verify` を実行した場合のみ）は diff を分析して fix→再検証をループ

### 2.7 kikimi-verify skill

Chirami の `chirami-verify` skill を模倣して、Kikimi 用の UI 自動検証 skill を早期に作る。**Phase 1 の最初にこの skill を作る**ことを最優先とする（作らないと Vibe Coding の検証ループが回らない）。

#### 機能

- ビルド + `apply`（`~/Applications/Kikimi.app` に配置）
- 起動 / 停止 / 再起動
- Kikimi ウィンドウのスクリーンショット取得
- グローバルホットキーの送信（HotKey を組み込んだ場合）
- 座標指定クリック（cliclick 経由）
- 文字列入力（AppleScript keystroke or cliclick）
- ウィンドウの可視判定（OnScreenOnly でメニューバーアプリの実状態を判定）
- 録音開始/停止のシミュレーション
- セッションフォルダの生成確認
- JSONL 内容の検証

#### 実装場所

```
~/.claude/skills/kikimi-verify/
├── SKILL.md
└── scripts/
    ├── build_and_apply.sh
    ├── restart.sh
    ├── capture.sh
    ├── click.py
    ├── type.py
    ├── check_visible.py
    └── verify_session.py    # セッションフォルダの構造検証
```

#### chirami-verify との差分

- Kikimi では「録音開始 → N 秒待機 → 停止 → セッションフォルダ確認」が主要フロー
- テストでは実際の音声を使わずに **AVAudioEngine にダミー音源をフィード**するモードを Kikimi 側に用意する（`KIKIMI_TEST_INPUT=path/to/wav`）
- 整形は Claude API を叩くので、テスト時は **`KIKIMI_STUB_LLM=1` で固定文字列返却**にする
- ダミー音源 + LLM スタブの組み合わせで、統合テストが決定的になる

#### chirami-verify で学んだ落とし穴の共有

`memory/project_chirami_verify_env_limits.md` に記録された「screencapture の黒画像チェック」「OnScreenOnly での可視判定」パターンをそのまま踏襲する。

### 2.8 レビュー方式（subagent 使い分け）

Claude Code の subagent を目的別に使い分ける。

| フェーズ | subagent | 用途 |
|---------|---------|------|
| 設計レビュー | `swe`, `code-reviewer` | 設計文書の技術的妥当性・見落とし |
| 実装レビュー | `code-reviewer` | 差分単位の PR レビュー相当 |
| 動作確認 | `general-purpose` + `kikimi-verify` skill | UI の実動作検証 |
| セルフチェック | `impl-validator` skill | 実装が仕様通りか検証 |
| API 設計 | `platform-team` | 内部 interface 設計のセカンドオピニオン |

**明示呼び出し以外では発火しない subagent（`ae`, `pdm`, `persona-*` など）は Kikimi では基本使わない**。Kikimi は個人開発なので顧客レビューの疑似ペルソナは不要。

### 2.9 テスト方式

3層で構成する。

#### レイヤ 1: 単体テスト（XCTest / vitest）

各機能の入出力を対象。実装フェーズと同時に書く。Swift は `swift test`、描画層（`web/`）は vitest で、
`mise run test` が両方を回す。

- 対象例
  - JSONL 追記が atomic であること
  - PathTemplateResolver 相当のパス解決
  - Config YAML の読み書きが等冪
  - Batch の flush 条件（N 件 or T 秒）が正しくトリガされる
  - Summary Updater の incremental マージが構造を破壊しない
  - Markdown 描画（`web/`）: LLM 出力の生 HTML がエスケープされること、mermaid の構文エラーで
    ソースが残ること、質問の吹き出しが Markdown として解釈されないこと

#### テストは実時間の長さを判定しない

**CI で不定期に落ちる原因はほぼこれ**（2026-07-30 に 7 箇所を修正）。落ちたテストはすべて「速いこと」を
assert していた — `elapsed < 2.5s`、`elapsed < 5s`、成功パスに 5 秒のタイムアウト。どれも挙動は正しく、
ランナーが遅かっただけで落ちる。

**検証したいのは因果**（タイムアウトを待っていない / 子プロセスが kill された / `drain()` を待っていない）
**で、所要時間ではない**。所要時間で代用すると、代用が壊れる。

手段を上から順に試す。

1. **明示的に止める**。フェイクにゲートを持たせ、完了できない状態にする。「それでも呼び出しが返った」
   事実が証明になる（`FakeRefinementLLM.closeGate()`。`endMeetingDoesNotAwaitRefinementDrain` が例）。
   時間が一切絡まないので最も堅い
2. **待つべきでない時間を桁違いに大きくする**。バッチタイムアウトを 5 秒から 10 分にすれば、`drain()` が
   返った事実だけで「タイムアウトを待っていない」が言える。**時間の計測そのものが不要になる**
   （`batchSizeTriggerFlushesImmediately`）
3. **完了待ちはポーリング**（`waitUntil`、`KikimiTests/TestSupport/WaitUntil.swift`）。上限は緩くてよい
   — 条件が成立した瞬間に返るので、通るテストは 1 ミリ秒も無駄にしない
4. **時間の上限 assert はハング検出としてのみ使う**。値に意味を持たせない。コメントに
   `hang guard, not a latency budget` と書いて意図を残す

**例外: ネガティブ検証では固定 sleep が正当**。「キャンセルした処理が発火しないこと」「`watchForChanges:
false` なら外部変更が反映されないこと」はポーリングする状態が無く、**遅い環境ほど安全**。固定 sleep を
使うときは「これはネガティブ検証だから」とコメントに書く（次の読み手がポーリングに"修正"しないように）。

**性能テストは桁で判定する**。`O(M²)` への退行は分単位になるので、60 秒の上限で足りる。1 秒で判定すると
負荷で破れるだけで、退行の検出力は上がらない。

#### レイヤ 2: 統合テスト（`kikimi-verify` skill）

エンドツーエンドの UI 動作を Claude 主導で叩く。

- 起動 → 録音開始 → ダミー音源投入 → 停止 → セッションフォルダ確認
- 整形は LLM スタブでスキップ、または固定応答モックで検証
- 各テストは独立に再現できるように環境変数で状態を制御
- **WebView の中身は AX ツリーだけでは確かめきれない**。`window.__kikimiDumpText()` /
  `__kikimiClick()` を通す経路が要る（`docs/design/39-webview-markdown.md` MD12 / §8.3）

#### レイヤ 3: 実戦テスト（リアル会議）

**Phase 4** で人間（uphy）が実際の会議で使う。最低3本のリアル会議を録音・整形して問題なければ Chirami の transcript block 削除に踏み込む。

- チェック項目
  - 1時間以上の録音でクラッシュしないこと
  - バックプレッシャ発生時に UI が固まらないこと
  - サマリが有意義に更新されていること
  - 登録 Watcher（TODO 追跡）が期待通り動くこと
  - Wiki export が LLM Wiki の raw フォーマット規約に合致すること

### 2.10 リポジトリ初期セットアップ手順

Vibe Coding を始める前に、Claude Code が最初に実行する初期化 workflow。

```
1. 新規リポジトリ作成: ~/dev/github.com/uphy/kikimi
2. project.yml, Package.swift, .mise.toml を Chirami から流用してカスタマイズ
3. Chirami の該当パスをまとめた docs/references/chirami-map.md を作成
4. CLAUDE.local.md に参考リポジトリの場所を、CLAUDE.md に「vibe coding 方式」を明記
5. CLAUDE.local.md に kikimi-verify の運用ルール（ユーザー指示時のみ実行）を書く
6. kikimi-verify skill を ~/.claude/skills/ に作成（Phase 1 のゼロ番目）
7. .claude/workflows/phase-cycle.js の雛形を作成
8. 最初の Workflow を起動: Phase 1 = 音声取込 + JSONL 保存
```

この初期化自体も Claude Code の workflow として書ける（`bootstrap.js`）。

### 2.11 開発の粒度と PR 戦略

コード変更は必ず **worktree + PR** で進める。`main` に直接コミットしない。マージするのはユーザーだけで、
Claude は CI が緑になるところまでを担当する。

**分担**

| 担当 | 範囲 |
|---|---|
| Claude | worktree 作成 → 実装 → コミット → push → PR 作成 → 必須チェックが緑になるまで待つ → 報告して停止 |
| ユーザー | PR を読んでマージする（UI 動作確認もここ） |
| 自動 | マージ済み worktree の削除（SessionStart hook が `mise run wt:reap` を叩く） |

**手順**

```bash
mise run wt fix/summary-pane-blank   # .claude/worktrees/fix/summary-pane-blank を作る
cd .claude/worktrees/fix/summary-pane-blank
# 実装 → コミット → push → gh pr create
mise run pr:wait                     # 必須チェックが緑になるまで待つ（マージはしない）
```

`mise run wt` は origin/main から生やし、gitignore されているローカル資産（`CLAUDE.local.md`、
`docs/references/chirami-map.md`、`.build`、`web/node_modules`、`Kikimi/Resources/editor`）を
APFS クローンで持ち込む。`.build` は約 10GB あるが `cp -c` はブロックを共有するので、コピー自体は数十秒、
ディスクもほぼ増えない。クローンした `.build` 内の `ModuleCache` だけは削除する（clang が絶対パスを
焼き込むため、残すとビルドが必ず失敗する）。

**並行作業の制約**

- worktree は何本でも並べてよい。ただし **UI 動作確認は 1 本ずつ**。`~/Applications/Kikimi.app`・
  `~/.config/kikimi`・`~/.local/state/kikimi` は worktree 間で共有されるので、同時に `mise run apply`
  すると壊れる
- `main` ruleset の `strict_required_status_checks_policy` は off。古い main の上で緑になった PR も
  マージできるので、同じファイルを触る PR を並べたときは、マージ後の main で改めて `mise run test` を回す
- コミットは Conventional Commits 準拠（`feat:`, `fix:`, `chore:`）。マージ方式は merge / squash / rebase の
  いずれも許可されている

**片付け**

`mise run wt:reap` が worktree を 1 本ずつ見て、**PR が MERGED かつ worktree がクリーンかつ HEAD が
マージされた commit のまま**のときだけ削除する。それ以外（PR が OPEN、未コミットあり、マージ後に
commit を積んだ）は理由を出して残す。SessionStart hook から毎セッション自動で走るので、通常は手で
叩く必要はない。

### 2.12 強制されるチェック

**GitHub 側（`main` ruleset、有効）**

- PR 必須（直接 push 不可）、force push と削除の禁止
- 必須ステータスチェック 3 本: `SwiftLint` / `Web (typecheck & test)` / `Build & test`
- 承認レビューは 0 人。ユーザー本人がマージできる

**ローカル側（`.claude/settings.json`）**

| hook | 内容 |
|---|---|
| PostToolUse (Edit/Write) | 変更した Swift ファイルに SwiftLint |
| PreToolUse (Bash) | `main` での `git commit` を拒否（`KIKIMI_ALLOW_MAIN_COMMIT=1` で解除）。そのうえで `mise run build` が通ることを確認 |
| SessionStart | マージ済み worktree を片付ける |

### 2.13 開発方式のまとめ

| 項目 | 選択 |
|------|------|
| 主導 | Claude Code（Vibe Coding）|
| 言語 | Swift + AppKit/SwiftUI |
| 参考 | 並列クローンの Chirami |
| 仕様 | `docs/design/*.md` を機能別に |
| サイクル | 1機能 = 1 Dynamic Workflow |
| UI 検証 | `kikimi-verify` skill（chirami-verify を模倣）|
| レビュー | subagent（swe / code-reviewer）並列 |
| テスト | XCTest + kikimi-verify + リアル会議3本 |
| Phase 判定 | 各 Phase 終了時に人間が Go/No-Go |

---

## 3. 開発の最初の一歩

Kikimi 開発を始める最初のセッションで Claude Code が実行するべきタスク順序。

1. **リポジトリ初期化** (`~/dev/github.com/uphy/kikimi/` を作成、`project.yml` / `Package.swift` / `.mise/tasks/` を Chirami から流用)
2. **`docs/references/chirami-map.md` の作成** — 参照すべき Chirami コードのマップ
3. **`kikimi-verify` skill の作成** — build/apply/capture/click/type/verify_session を用意
4. **`CLAUDE.md`, `CLAUDE.local.md` の整備** — 参考リポパス、vibe rules、`kikimi-verify` の運用ルール
5. **`.claude/workflows/phase-cycle.js` の雛形作成**
6. **Phase 1 Workflow を起動** — 目標: 「録音開始 → 2ストリーム WAV 保存 → 生 JSONL 追記 → UI に生書き起こしが表示される」まで

ここまで動けば、以降の Phase は同じ workflow を feature 引数だけ変えて回せる。
