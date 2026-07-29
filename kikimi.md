# Kikimi 設計ドキュメント

Chirami から transcript 機能を切り出した、会議特化のリアルタイム書き起こしアプリの設計。

---

## 1. Vision（Golden Circle）

### Why

Chirami は「フローティングノート」の道具として最適化されており、その中に会議書き起こし機能を抱え込むと以下の問題が生じている。

- sherpa-onnx / モデルダウンロード / macOS 14.2+ 制約が chirami 本体に不要な重さをもたらす
- 会議は「セッション（開始・進行・終了・アーカイブ）」というモデルで、chirami の「常時フロートするノート」というモデルと噛み合わない
- 音声データの保持・LLM API 統合・コスト管理は独自の設計を必要とし、chirami の「plain .md ファイル」原則と衝突する

### How

会議特化の別アプリとして分離し、以下の3層を独立して育てる。

1. **リアルタイム書き起こし**: FluidAudio（Nemotron 3.5 ASR Streaming）によるオンデバイス streaming STT（システム音声 + マイクを別ストリームで並列処理）
2. **LLM 整形とサマリ**: Claude Haiku によるセグメント整形と、schema + view + patch 方式の差分サマリ更新
3. **文脈化された自動化**: 登録 Watcher（TODO 追跡など stateful なタスク）をサマリ更新に連動して実行

### What

macOS メニューバー + フローティングパネル型の会議書き起こしアプリ。

- **入力**: システム音声 + マイク（2ストリーム独立処理）
- **出力**: セッションごとの音声ファイル + 生 JSONL + 整形済み JSONL + サマリ Markdown
- **周辺**: 登録 Watcher実行結果、Wiki raw export

**In one sentence**: 「会議を、聞いて・整えて・使える文脈にする」

---

## 2. スコープ

### スコープ内

- システム音声 + マイクのリアルタイム録音・書き起こし
- 音声データそのものの永続保持（後段の高精度再書き起こし用）
- Claude Haiku によるセグメント単位整形（バッチ処理）
- 固定見出しサマリの incremental 更新
- 登録 Watcherの自動・手動実行（stateful）
- LLM Wiki 用 raw Markdown export
- 手動セッション管理（一覧・タイトル変更・削除）

### スコープ外（明示的に「作らない」と決めたもの）

- **他ユーザーとのクラウド同期・共有** — 完全にローカルアプリとして完結する

### 将来的に検討し得る（現時点では未定）

- カレンダー連携での会議自動検知・自動録音開始
- Zoom / Meet / Teams API 経由の参加者情報取得
- 過去セッションの全文検索 UI
- リアルタイム翻訳
- 音声文字入力（[Handy](https://handy.computer/) 型のディクテーション）— ホットキー押下中だけマイクを録音し、カーソル位置に整形済みテキストをペーストするユーティリティ。streaming STT（キーを離した瞬間に flush して即確定）+ LLM 整形（フィラー除去・句読点補完）という Kikimi の部品で Handy より高品質にできる見込み。ただしセッションを持たないステートレスな道具なので、**Kikimi のセッションモデルには組み込まず**、`SttEngine` / `AudioCapture` / LLM クライアントを共有する別モード（または別アプリ）として設計する。検討開始は Phase 4 完了後（論点の詳細は 15 章）

---

## 3. アプリケーション基本情報

| 項目 | 値 |
|------|-----|
| 名前 | **Kikimi**（聞き耳） |
| リポジトリ | 別リポジトリ（chirami とは独立） |
| プラットフォーム | macOS 14.2+ |
| バンドル ID 予定 | `io.github.uphy.kikimi` |
| アプリ種別 | メニューバー常駐（LSUIElement）+ フローティング NSPanel |

---

## 4. ディレクトリ構造とデータ保存

### 保存場所

```
~/.local/state/kikimi/
├── sessions/
│   └── 2026-07-01T14-30-00_<uuid8>/
│       ├── meta.json              # セッションメタ情報
│       ├── context.md             # このセッション専用の事前知識（編集可）
│       ├── summary_template.md    # このセッション専用のサマリテンプレ（編集可）
│       ├── audio/
│       │   ├── mic_000.wav        # マイク・録音区間0（16kHz mono）
│       │   ├── system_000.wav     # システム音声・録音区間0（16kHz mono）
│       │   ├── mic_001.wav        # 録音再開で区間1が増える（以降 _NNN 連番）
│       │   └── system_001.wav     #   （meta.json の recordings[] と 1:1 対応）
│       ├── transcript.jsonl       # 生書き起こし（追記）
│       ├── refined.jsonl          # 整形済み（追記）
│       ├── participants.json      # 参加者ヒント（声紋照合のクローズドセット名簿。docs/design/22）
│       ├── summary.state.json     # サマリ内部 state（JSON、patch を適用して更新）
│       ├── summary.md             # view template でレンダリング済み（上書き）
│       ├── chat.jsonl             # チャットタブの質問と回答（追記。docs/design/38）
│       └── watchers/
│           ├── enabled.yaml       # このセッションで有効な Watcher ID 一覧
│           ├── <id>.md            # session-local Watcher（preset を fork した場合もここ）
│           └── <id>.state.json    # 各 Watcher の実行状態
└── plugins/                       # 予約

~/.config/kikimi/
├── config.yaml                    # 設定（モデル・トリガ・パス参照）
├── context/
│   └── common.md                  # 新規ウィンドウの context 初期値
├── templates/
│   └── summary.md                 # 新規ウィンドウの summary_template 初期値
├── watchers/
│   └── *.md                       # Watcher preset（グローバルライブラリ）
└── default_watchers.yaml          # 新規ウィンドウで既定 enable する Watcher ID

~/.local/state/kikimi/state.yaml   # ウィンドウ位置・可視状態
```

- **XDG 準拠**: chirami と同じ流儀。dotfiles で `~/.config` を管理している場合と親和的。
- **音声フォーマット**: WAV 16kHz mono / 16-bit（実装最小・ロスレス・STT モデルが要求するサンプルレートと直結）。ストリームあたり約 110 MB/h。mic + system の 2 ストリームで合計約 220 MB/h。
- **クリーンアップ**: 自動削除なし。UI から手動削除のみ（Draft ウィンドウを閉じても空フォルダは残る。Session List から削除する）。
- **STT モデルの配置**: STT は FluidAudio（6章）が担い、モデルは FluidAudio 自身のキャッシュ（`~/Library/Application Support/FluidAudio/Models/`）に自動ダウンロードされる。`~/.local/state/kikimi/models/sherpa-onnx/` は旧方式（sherpa-onnx）の名残で、Kikimi は新規にここへ書き込まない。過去にインストールした環境で残っている場合も自動削除はせず、ユーザーが手動で削除する（`mise run purge` も同様にこのディレクトリだけは残す）。

### セッションフォルダ命名規則

`{ISO8601開始時刻}_{短縮UUID}` 形式。

- 例: `2026-07-01T14-30-00_a1b2c3d4/`
- Finder で開いた時に時系列で並ぶ
- UUID 短縮部（8文字）で同時刻の衝突を回避

### セッションウィンドウ（Session Window）

Kikimi の**ウィンドウ=セッション**という設計。1 つのフローティングウィンドウが「1 つの会議の準備〜録音〜レビュー」の全部を担う。Chirami の「1 note = 1 window」思想と揃える。

- ウィンドウは **Draft**（未録音）/ **Recording**（録音中）/ **Paused**（録音を止めているが会議は継続中・再開できる）/ **Ended**（会議終了・確定）の4状態を持つ
- **Draft ウィンドウは複数同時に開ける**。翌週の3会議分を事前に Prep しておく、が自然にできる
- **Recording は同時に1つだけ**（音声リソースは単一。他ウィンドウの録音ボタンは Recording 中は disabled）
- Ended ウィンドウは閉じても、セッションフォルダから何度でも再オープンできる

#### 「停止」と「終了」を分離する（この設計の要）

会議書き起こしでは「録音を止める」操作に**2つの異なる意味**が混ざる。これを別操作に分ける。

- **一時停止（Recording → Paused）**: 休憩・途中退席・誤操作。会議はまだ続くので**また録りたい**。`on_session_end`（Wiki export・最終タイトル生成・session-end Watcher）は**走らない**
- **会議終了（Recording/Paused → Ended）**: もう録らない。ここで初めて `on_session_end` の確定処理が走る

これにより、誤って停止しても「Paused に落ちるだけ」になり、再開すれば同じセッションに続けて追記される（transcript が別セッションに分裂しない）。確定処理はユーザーが「終わった」と意思表示したときだけ走る。

- **録音区間（recording segment）**: Recording になるたびに新しい区間が始まり、Paused / Ended で区間が閉じる。1 セッションは複数の録音区間を持ち得る。`meta.json` の `recordings[]` が区間リスト（5 章）
- **タイムライン**: `start_ms` は「録音アクティブ時間の累積（区間を詰めた連続タイムライン）」。休憩中の実時間ギャップは詰める（音声ファイルに無音を挿入しないため、これで音声シークと transcript が一致する）。実時刻は各区間の `started_at` から復元でき、UI では区間境界に「── 録音再開 15:05 ──」の区切りを描いて実時刻の飛びを可視化する
- **Ended も可逆**: 誤って終了しても `[↩ 再開]` で Recording に戻せる。`on_session_end` の副作用（export 等）は冪等（上書き）なので、録り足して再終了しても壊れない。ただし主経路は Paused
- **STT の扱い**: 区間終了時に streaming を flush して確定、区間開始で fresh start（cache-aware streaming の内部状態を休憩ギャップ跨ぎで持ち越さない。6 章）

各ウィンドウが以下を独自に持つ:

- タイトル（自動命名 or 手動）
- context.md（このセッション専用の事前知識）
- summary_template.md（このセッション専用のサマリ構造）
- 進行中のセグメント / サマリ / Watcher 実行結果

### context.md / summary_template.md のライフサイクル

セッションフォルダ内の `context.md` と `summary_template.md` が **セッション専用の値**として扱われる。

| 段階 | 挙動 |
|------|------|
| ウィンドウ作成時（Draft） | セッションフォルダを即座に作り、`~/.config/kikimi/context/common.md` と `~/.config/kikimi/templates/summary.md` を初期値としてコピー |
| Draft 中の編集 | UI 上で自由に編集可能。ファイルに即保存 |
| 録音開始（Draft → Recording） | 開始時点の内容を LLM へ渡すコンテキストとして採用。ファイルはそのまま |
| Recording 中の編集 | UI 上で編集可能。**summary は次回サマリ更新から即反映**、**refinement は最大 `context_refresh_batches` バッチ後に反映**（既存 refined / 既存サマリの backfill はしない）|
| 一時停止（Recording → Paused） | 録音区間を閉じ、STT を flush して確定。`duration_ms` に区間長を加算。`on_session_end` は走らない。context / summary_template はそのまま編集可能 |
| 再開（Paused → Recording） | 新しい録音区間を開始（`start_ms_offset = 現在の duration_ms`）。context / summary_template の最新値をその時点で採用（refinement は次のキャッシュ更新で反映） |
| Ended 後の編集 | 「サマリ全文再生成」を明示的に押した場合のみ、新しい template で全 refined から再構築される |
| Draft のまま閉じた | セッションフォルダは残る（Session List に Draft 状態として並ぶ）。削除は Session List から手動でのみ |

- **注**: refinement（セグメント整形）の system prompt に含まれる context は、**キャッシュヒットを守るためバッチ間で固定したい**。そのため refinement 側は **10 バッチに1回など粒度を粗くしてキャッシュ更新**する運用にする（詳細は 7 章）。summary 側は毎回全文を組み立て直すので即時反映で問題ない。

---

## 5. データモデル

### transcript.jsonl（生書き起こし）

1行 = 1セグメント（JSON Lines）。**追記のみ**、決してrewriteしない。

```json
{
  "id": "seg_00042",
  "start_ms": 125300,
  "end_ms": 128100,
  "speaker": "mic",
  "text": "そうですね、次のスプリントで対応します",
  "confidence": 0.87
}
```

| フィールド | 型 | 説明 |
|-----------|-----|------|
| `id` | string | `seg_` + 5桁ゼロ埋め連番。refined 側からの参照に使う |
| `start_ms` | int | **録音アクティブ時間の累積タイムライン上**の位置（ミリ秒）。= その区間の `start_ms_offset` + 区間内経過。休憩（Paused）区間は詰めるので、実時刻ではなく「録音していた総時間」基準。実時刻が要る箇所は `recordings[]` から復元する |
| `end_ms` | int | 同上 |
| `speaker` | `"mic"` \| `"system"` | 物理ソース由来。diarization はしない |
| `text` | string | 確定に使った STT 出力（バッチ再デコードまたはストリーミング。改行含まない。`docs/design/33-meeting-two-pass-decode.md`） |
| `confidence` | float | STT の確信度（0.0〜1.0）|
| `stt_source` | string? | `"batch"`（バッチ再デコード由来）のときのみ存在。キー不在はストリーミング確定（design 33 MT9） |

### refined.jsonl（整形済み）

transcript.jsonl と同じ ID・時刻情報を持ち、整形結果を追加。

```json
{
  "id": "seg_00042",
  "start_ms": 125300,
  "end_ms": 128100,
  "speaker": "mic",
  "raw_text": "そうですね、次のスプリントで対応します",
  "refined_text": "次のスプリントで対応します。",
  "refined_at": "2026-07-01T14:32:15Z",
  "model": "claude-haiku-4-5-20251001",
  "batch_id": "batch_00004"
}
```

- 整形失敗時: `refined_text: null, error: "エラーメッセージ"` を追記して次に進む
- `batch_id`: 同一 Haiku 呼び出しで整形された仲間の識別。デバッグとリトライ判断に使う

### meta.json（セッションメタ）

セッション開始時に作成、進行中に更新される。

```json
{
  "id": "2026-07-01T14-30-00_a1b2c3d4",
  "title": "デイリースクラム",
  "title_auto_generated": true,
  "title_auto_named_once": true,
  "title_proposal": null,
  "state": "ended",
  "created_at": "2026-07-01T14:28:12Z",
  "started_at": "2026-07-01T14:30:00Z",
  "ended_at": "2026-07-01T15:15:22Z",
  "duration_ms": 2722000,
  "recordings": [
    { "index": 0, "started_at": "2026-07-01T14:30:00Z", "ended_at": "2026-07-01T14:52:10Z", "start_ms_offset": 0 },
    { "index": 1, "started_at": "2026-07-01T15:05:30Z", "ended_at": "2026-07-01T15:15:22Z", "start_ms_offset": 1330000 }
  ],
  "based_on_session": "2026-06-24T14-30-00_x9y8z7w6",
  "segment_count": 342,
  "refined_count": 342,
  "app_version": "0.1.0"
}
```

- `title` は最初は空 or 開始時刻（Draft で手入力があればそれ）。**Recording 中の自動更新は最初のサマリ更新の 1 回のみ**（詳細は 8 章「自動タイトル命名」）
- `title_auto_generated` はユーザーが手動編集したら false に固定される
- `title_auto_named_once` は Recording 中に既に一度自動命名済みかどうかのフラグ
- `title_proposal` は現在の提案タイトル案（あれば。ヘッダに提案バッジで表示するために使う）
- `state` は `draft` / `recording` / `paused` / `ended` のいずれか
- `created_at` は Draft ウィンドウ作成時刻。`started_at` は**最初の**録音開始時刻（不変）
- `ended_at` は**会議終了（Ended）時刻**。Recording / Paused の間は `null`（一時停止では埋めない）
- `duration_ms` は**録音アクティブ時間の累積**（各録音区間長の合計。休憩時間は含めない）。進行中も区間が閉じるたびに更新される
- `recordings` は**録音区間**のリスト。区間ごとに `index`（0 始まり連番、音声ファイル `mic_NNN.wav` / `system_NNN.wav` と対応）、`started_at`（区間の実開始時刻）、`ended_at`（区間を閉じた実時刻。進行中の区間は `null`）、`start_ms_offset`（この区間の最初のセグメントの `start_ms`。= 区間開始時点の累積 `duration_ms`）を持つ
- `based_on_session` は Session List で複製元にしたセッションの id（あれば）

### summary.state.json と summary.md

サマリは2ファイル構成。

- **`summary.state.json`**: 内部の構造化 state。**MVP では schema はアプリ内蔵固定**（8 章参照）。LLM が返す patch を Kikimi が適用して更新
- **`summary.md`**: view template（Mustache）で state を Markdown にレンダリングした最終形。**上書き保存**（追記ではない）。UI 表示・Wiki export の参照元

サマリの表示レイアウトを変えたい場合は `summary_template.md` を編集する。**MVP では schema は固定なので、template が参照できる変数は schema で定義された field のみ**（`{{title}}` `{{overview}}` `{{decisions}}` `{{action_items}}` `{{participants}}`）。カスタム見出しを増やしたい用途は Watcher 側で表現する。

---

## 6. 録音・書き起こしパイプライン

### 全体フロー

```
[マイク]     ──→ [AVAudioEngine]  ──→ [chunk buffer] ──→ [Nemotron streaming #1] ──→ [Segment Queue]
[システム音声] ──→ [Screen Capture Kit] ─→ [chunk buffer] ──→ [Nemotron streaming #2] ──→ [Segment Queue]

[Segment Queue] ──→ [JSONL 追記] ──→ [UI 通知（生表示）] ──→ [整形バッチキュー]
                                                          ↓
                                          [Batch Refiner (Haiku)]
                                                          ↓
                                          [refined.jsonl 追記] ──→ [UI 差分更新]
                                                          ↓
                                          [Summary Trigger 判定]
                                                          ↓
                                          [Summary Updater] ──→ [summary.md 上書き]
                                                          ↓
                                          [Watcher Runner（自動連動）]
```

### STT モデル

- **FluidAudio（CoreML/ANE）+ NVIDIA Nemotron 3.5 ASR Streaming 0.6B（ja-JP、multilingual streaming）**。
  cache-aware streaming Conformer + RNN-T で、chunk ごとにトークンを逐次確定する真の streaming STT
- モデルは初回使用時に FluidAudio 自身のキャッシュ（`~/Library/Application Support/FluidAudio/Models/`）へ自動ダウンロード
- 詳細設計は [`docs/design/11-streaming-stt.md`](docs/design/11-streaming-stt.md) を参照

### 2ストリーム独立処理

- マイクとシステム音声は**別スレッド・別 Nemotron streaming インスタンス**で処理
- diarization は不要（物理ソースで話者が確定するため）
- セグメントは各ストリームで独立に確定し、共通の Segment Queue に投入される
- `id` は投入順に採番されるので、時系列とはズレる可能性がある（時系列参照は必ず `start_ms` を使う）

### 録音区間ごとの STT リセットとタイムライン採番

- 一時停止（Paused）で区間を閉じるとき、両ストリームの streaming インスタンスを **flush して残りのトークンを確定**させ、区間の最後のセグメントまで取りこぼさない
- 再開（Recording）で区間を開始するとき、streaming インスタンスは **fresh start**（内部状態をリセット）。cache-aware streaming Conformer の内部履歴を休憩ギャップ跨ぎで持ち越すと、無音を挟んだ文脈が汚染されるため
- **`start_ms` の採番**: 各セグメントの `start_ms` は `区間の start_ms_offset + 区間内の音声フレーム経過ミリ秒`。`start_ms_offset` は区間開始時点の累積 `duration_ms`（＝それまでの全区間長の合計）。これにより休憩を挟んでも `start_ms` は連続した「録音アクティブ時間」タイムラインになり、音声ファイルの連結再生位置と一致する
- 音声ファイルは区間ごとに `mic_NNN.wav` / `system_NNN.wav` に分けて書く（`WavFileWriter` は区間ごとに開き直す。ヘッダのサイズ書き換えを区間跨ぎで行わないので、途中クラッシュしても区間単位で健全）

### 録音は絶対に止めない

- 後段（整形・サマリ・Watcher）がどれだけ詰まっても、録音と JSONL 追記は継続する
- 詰まった時の振る舞いは [8.5. バックプレッシャ](#85-バックプレッシャ超過時の振る舞い) 参照

---

## 7. LLM 整形パイプライン

### モデル

- config の `refinement.model` で指定。既定 `claude-haiku-4-5-20251001`
- サマリ生成モデル（`summary.model`）とは独立に指定可能
- Watcher 実行モデルもさらに独立（9 章）

### バッチ整形（常にバッチ化）

- **常にバッチで整形する**（1件ずつは扱わない）
- **バッチサイズ**: デフォルト10セグメント（config で変更可能）
- **フラッシュ条件**: 「10 セグメント溜まる」または「最初のセグメント投入から 5 秒経過」のいずれか早い方
- バッチ処理は **直列**（同時に走る Haiku 呼び出しは1つ）。文脈順序を確実に保つため

### Prompt 設計

Prompt caching を最大限効かせるため、system prompt を完全固定にする。

#### System prompt（キャッシュヒット狙い・完全固定）

```
あなたは会議書き起こしを整形する専門家です。以下のルールに従ってください。

【整形ルール】
- フィラー（「えーと」「あの」など）を除去する
- 句読点を補い、自然な日本語にする
- 意味を変えない範囲での軽微な言い換えは可
- 意味の解釈が不明瞭な箇所は元の表現を残す
- フィラー・相槌・言い直しの断片のみで、除去すると意味のある内容が何も残らないセグメントは、refined_text を空文字にする（そのセグメントを削除する扱い）

【事前知識】
{{セッション共通の固定知識（用語集・組織用語・省略語など。config.yaml から注入。1セッション中は固定）}}

【出力形式】
schema の "segments" 配列で、対象セグメント数分の整形結果を返す。
segments の各要素: {"id": "seg_XXXXX", "refined_text": "..."}
意味のある内容がないセグメントは refined_text を空文字（{"id": "seg_XXXXX", "refined_text": ""}）にする。
```

- **`refined_text: ""`（空文字）は「意味なしセグメントの削除」の合図**。整形失敗（`refined_text: null` + error）とは別扱いで、Transcript 表示・サマリ入力・整形の文脈行から除外する（raw フォールバックしない）

- **`{{事前知識}}` はセッション開始時に config + プリセット + セッション開始時追加情報から組み立て、1セッション中は完全に固定**
- これにより Haiku 呼び出しの system prompt が全バッチでキャッシュヒットする
- キャッシュヒットしない場合の課金コストを考えて、事前知識のサイズは 1024〜4096 トークン程度に抑える

#### User prompt（毎回変わる）

```
【直前の文脈（整形済み）】
seg_00039 (system): （refined_textまたはraw_text）
seg_00040 (mic): ...
seg_00041 (system): ...

【今回整形する対象】
seg_00042 (mic): そうですね、次のスプリントで対応します
seg_00043 (mic): あ、それとテストシナリオも追加します
seg_00044 (system): 了解しました
...（バッチ内の全セグメント）
```

- **文脈は「直前3セグメント」**（refined 版があれば refined、なければ raw）
- **並び順は `start_ms` 昇順**（mic / system の 2 ストリームを時系列マージしたもの。`id` は投入順で時系列と食い違うため使わない）
- 対象バッチ内のセグメントは、バッチ内でも文脈として相互参照できる
- 「対象内のセグメント数分だけ出力してください」を強制

### 事前知識（Context Prime）の構成

**セッション内の `context.md` が single source of truth**。

- 新規 Draft ウィンドウ作成時に `defaults.context_file`（既定 `~/.config/kikimi/context/common.md`）をコピーして初期値にする
- ウィンドウ上でユーザーが自由に編集する（アジェンダ・参加者・その会議固有の用語など）
- 録音中も編集可能

これを system prompt の `{{事前知識}}` 部に埋め込み、キャッシュヒットを狙う。

#### キャッシュ更新戦略

Recording 中に context.md が変わってもリアルタイムでは反映せず、**`context_refresh_batches` バッチごとに system prompt を組み直す**（既定 10 バッチ）。これで:

- 90% のバッチはキャッシュヒット
- 変更は最悪でも 10 バッチ後には反映される
- ユーザーが「今すぐ反映」ボタンを押せば即時 refresh

#### Context ファイルの読み込み規則

- Draft/Recording/Ended いつでも編集可能。ファイル書き込みは即時
- Refinement の system prompt への反映は上記キャッシュ更新戦略に従う
- Summary への反映は次回サマリ更新時に即時（毎回 prompt を組み直すので追加コストなし）
- ファイル未存在時（削除された場合）は起動時 warning、その context を空文字扱いで継続
- ファイルサイズ上限は 32KB。超過時は warning（内容は使う）

---

## 8. サマリ更新戦略

### スコープ（MVP）

サマリは以下の**軽量セクション**に絞る。**議事詳細（トピック別 H3 セクションで詳細を積む形式）は MVP では作らない**。

- 会議のトピック境界判定はリアルタイムでは精度・安定性ともに担保が難しく、Phase 4 実戦で本当に必要か見極めてから将来的に追加する
- 詳細を残したいユーザーは、当面は Watcher（例: 話題リスト系）で埋めるか、Wiki export の書き起こしセクションを見る

対象セクション:

- 概要（overview）
- 決定事項（decisions）
- アクションアイテム（action_items）
- meta として title / participants

### 更新トリガ

**20セグメント追加 or 3分経過** のいずれか早い方。手動更新ボタンでもトリガ可能。

### モデル

- config の `summary.model` で指定。refinement とは独立
- サマリは 1 セッションあたり数十回程度なので、必要なら Sonnet 等の上位モデルにしてもコスト影響は限定的
- 既定 `claude-haiku-4-5-20251001`

### 内部 state と patch 更新

サマリは Watcher と同じ **schema + view + patch モデル**で管理する。LLM は毎回全文を書き直すのではなく、**変更差分（patch）だけ**を返す。Kikimi 側で state に patch を適用し、view template で summary.md を決定論的にレンダリング。

### 内部 state の schema

MVP ではアプリ内蔵の固定 schema。ユーザーが session ごとに書き換える口は用意しない。将来的にカスタム schema を許すかは Phase 4 実戦後に判断する。

```yaml
title: string
participants: [string]
overview: string
decisions:
  - text: string
    source_seg_ids: [string]
action_items:
  - id: string
    task: string
    assignee: string
    due: string?
    status: enum[open, done]
    source_seg_ids: [string]
```

state は `sessions/<id>/summary.state.json` に保存される。長時間会議で state が肥大化しても LLM に渡すのは全 state（MVP では絞り込みなし）。

### セクションごとの patch 戦略

| セクション | 更新モード | LLM が返すもの |
|-----------|-----------|----------------|
| title | cumulative | 変更があれば新値、なければ null |
| participants | append_only | 追加された人だけ |
| overview | snapshot | 全文（量が少ないので許容） |
| decisions | append_only | 新規追加分のみ |
| action_items | patch（add/modify/complete）| 差分操作 |

### LLM への入出力の例

**System prompt（固定）**:

```
あなたは会議サマリを更新するエディタです。前サマリ state と直近の会話を受け取り、変更差分（patch）を JSON で返してください。

【schema】
（Kikimi が内部 schema を JSON Schema として埋め込む）

【ルール】
- overview は必要に応じて全文書き直し
- decisions は新規追加分のみ返す（既存には触らない）
- action_items は add / modify / complete のいずれかの操作を返す
- 何も変更がなければ全フィールド null で良い
```

**User prompt（毎回）**:

```
【現在の state】
{ ... summary.state.json の内容 ... }

【直近の会話】
（start_ms 昇順で並べたセグメント。前回サマリ更新以降の未反映分）
seg_00350 (mic): ...
seg_00351 (system): ...

【現在時刻】 2026-07-01T14:52:00Z

patch を返してください。
```

**LLM 出力（例）**:

```json
{
  "overview": "顧客A向け提案書作成の支援について...",
  "decisions": {
    "add": [
      {"text": "スライド検索結果の新規UI開発はスコープ外", "source_seg_ids": ["seg_00087"]}
    ]
  },
  "action_items": {
    "add": [
      {"id": "ai_003", "task": "検索対象テーブルのデータ量確認", "assignee": "tanaka-san", "source_seg_ids": ["seg_00102"]}
    ],
    "modify": [
      {"id": "ai_001", "due": "7月末"}
    ]
  }
}
```

### view template（Mustache）

`sessions/<id>/summary_template.md` は Mustache テンプレート。**frontmatter は含めない**（Wiki export 側の frontmatter が正。11 章参照）。既定内容:

```markdown
# {{title}}

## 概要

{{overview}}

**参加者:** {{#participants}}{{name}}{{^is_last}}、{{/is_last}}{{/participants}}

## 決定事項

{{#decisions}}- {{text}}
{{/decisions}}

## アクションアイテム

| タスク | 担当 | 期限 |
|--------|------|------|
{{#action_items}}| {{task}} | {{assignee}} | {{#due}}{{due}}{{/due}}{{^due}}—{{/due}} |
{{/action_items}}
```

- 見出しの追加・削除・改名は可能。ただし **schema は固定**なので参照可能な変数は schema に定義された field のみ
- **participants の記法**: 実装の Mustache（GRMustache.swift）は `{{^-last}}` 拡張を持たないため、各参加者は
  `{{name}}`（名前）と `{{is_last}}`（末尾判定 bool）を持つオブジェクトとして展開される。区切りは
  `{{^is_last}}、{{/is_last}}` で表現する（詳細は `docs/design/04-summary-updater.md` §5）
- **`{{#decisions}}`/`{{#action_items}}` の開始タグは行内（前の行の末尾ではなく、繰り返し行の直前）に詰めて書く**。
  GRMustache.swift は「タグだけの行」を単独行として折りたたむため、開始タグを単独行のままにすると
  セクション前後に空行が入り、GFM のテーブルは空行で分断されてヘッダー行だけが表として解釈されてしまう
  （`action_items` のテーブルで特に致命的）。終了タグは単独行のままで問題ない
- 新規ウィンドウ作成時に `defaults.summary_template_file`（既定 `~/.config/kikimi/templates/summary.md`）をコピー

### テンプレート読み込み規則

- **セッション内 `summary_template.md` が最優先**（起動時に一度読み、UI から編集されると即再読み込み）
- Recording 中の編集は **次回サマリ更新から反映**（backfill しない）
- ファイル未存在時は内蔵デフォルト template にフォールバック
- ファイルサイズ上限 16KB

### 自動タイトル命名

チラつき防止のため **1 回命名 + 提案バッジ** 方式。

- サマリ更新時に patch の `title` フィールドで LLM が提案（毎回）
- **Recording 中の自動反映は 1 回だけ**: `title_auto_named_once == false` かつ `title_auto_generated == true` のとき、初回 patch の title を `meta.title` に反映して `title_auto_named_once = true` に立てる
- 以降の patch の title は自動反映せず、`meta.title_proposal` にだけ保存し、**ヘッダに「新しいタイトル案: XX [採用]」の提案バッジ**を出す
  - ユーザーが `[採用]` を押すと `meta.title` に反映し、`title_proposal = null`
  - ユーザーが無視すれば次の patch で `title_proposal` が上書きされる
- **セッション終了時（`on_session_end`）**: 全 refined から最終タイトル案を生成し、同じ提案バッジで通知。手動採用まで自動反映しない
- ユーザーが UI で手動編集すると `title_auto_generated = false` に固定され、以降は提案バッジも出さない

### 全文再生成モード（救済パス）

UI に「サマリを全 refined から再生成」ボタン。全 refined セグメントを渡して state を最初から作り直す。サマリが劣化した場合の緊急脱出。

---

## 8.5. バックプレッシャ超過時の振る舞い

- **既定戦略**: Best-effort catch-up（キューは伸ばし続け、遅延だけ伸びる。データは絶対に失わない）
- リアルタイム表示は生 JSONL の内容で行われるので、整形やサマリが遅延しても最低限の情報は見える
- 会議終了後に自然にバッチ処理が追いつく想定
- UI にはキュー長のインジケータを控えめに表示（デバッグ可視化）
- **整形失敗（refined_text が null）のセグメントは summary / Wiki export で raw_text にフォールバック**して欠落を作らない

---

## 9. Watchers

### コンセプト

**Watcher = 会議を "見張って" 事前に指定した観点で気付きを更新し続ける役**。事前確認事項の追跡、TODO 追跡、アクション抽出、リスク検出、議事録メール下書きなどを表現できる Kikimi のカスタマイズ性の中核。

多くの Watcher は会議ごとに違うため、context / summary_template と同じく **Preset（グローバル） + Session-local（ウィンドウ単位）** の二層モデルにする。

### 2種類の Watcher

| 種類 | 保存場所 | 用途 |
|------|---------|------|
| **Preset** | `~/.config/kikimi/watchers/<id>.md` | 全ウィンドウ共通で使える汎用ライブラリ |
| **Session-local** | `sessions/<id>/watchers/<id>.md` | そのセッション専用。会議固有の観点 |

同名 ID の場合は **session-local が優先**。

### 変数分離モデル（schema + view）

Watcher の根本設計。LLM は **schema に沿った構造化データだけ**を返し、表示は **view template（Mustache）**で決定論的にレンダリングする。

- LLM の出力ブレによる表示崩れを排除
- 表示のカスタマイズは view を書き換えるだけ（LLM は無関係）
- view のレンダリングは pure function なのでテスト可能
- schema バリデーションで壊れた出力を検出・リトライ可能

### Watcher ファイル形式

`.md` に frontmatter（メタ情報 + schema + view）+ `# System` / `# User` セクション。

**例**: `~/.config/kikimi/watchers/pre-check.md`

````markdown
---
id: pre-check
name: 事前確認事項チェッカー
model: claude-haiku-4-5-20251001
trigger: on_summary_update
state_mode: cumulative
input_scope: summary_and_recent

# LLM が返す JSON の構造（内部で JSON Schema に変換して structured output に食わせる）
schema:
  items:
    - id: int
      question: string
      status: enum[open, partial, answered]
      answer: string?          # ? = nullable
      source_seg_id: string?

# UI 表示用テンプレート（Mustache）
view: |
  {{#items}}
  - {{#is_answered}}✅{{/is_answered}}{{#is_partial}}◐{{/is_partial}}{{#is_open}}⬜{{/is_open}} {{question}}
    {{#answer}}→ {{answer}} `{{source_seg_id}}`{{/answer}}
  {{/items}}

initial_state: |
  {
    "items": [
      {"id": 1, "question": "見積金額", "status": "open"},
      {"id": 2, "question": "納期",     "status": "open"}
    ]
  }
---

# System

あなたは会議中の「事前確認事項」を追跡します。ユーザーは会議前に確認したい点をリストしています。会議での会話から明示的な回答が得られた項目を更新してください。

【判定ルール】
- 答えが明確に得られた → status="answered"、answer に会話内の言葉で簡潔に、source_seg_id に根拠セグメントID
- 部分的にしか得られていない → status="partial"、answer に分かっている範囲だけ
- 答えが得られていない → status="open" のまま
- 一度 answered になったものを勝手に open に戻さない
- 新規項目の追加はしない

# User

【現在の確認事項リスト】
{{state}}

【直近のサマリ】
{{summary}}

【直近の会話】
{{recent_segments}}

schema に沿った更新後の JSON を返してください。
````

### frontmatter フィールド

| フィールド | 値 | 説明 |
|-----------|-----|------|
| `id` | string | 一意 ID。session-local が preset より優先 |
| `name` | string | UI 表示名 |
| `model` | string | LLM モデル。省略時は `watchers.default_model` |
| `trigger` | enum | `on_summary_update` / `on_session_end` / `on_manual` / `on_interval:<秒>` |
| `state_mode` | enum | `cumulative` / `snapshot` / `append_only` |
| `input_scope` | enum | `summary` / `summary_and_recent[:<n>]` / `full_refined`。`:<n>` で直近セグメント数を指定（1〜200 にクランプ、無印は 30） |
| `schema` | YAML | LLM が返す JSON の構造宣言 |
| `view` | Mustache | UI・Wiki export 表示用テンプレート |
| `initial_state` | JSON | 初回実行時の state |

### 簡易 Watcher（kind: simple）

上記のフル形式は表現力の代償として学習コストが高い。「プロンプト 1 個 + 対象 + 頻度」で足りる
用途（脱線検出・論点整理・用語解説など）向けに、同じ `.md` に `kind: simple` を宣言する簡易形式を
用意する（詳細設計は `docs/design/34-simple-watchers.md`）。

````markdown
---
kind: simple
id: simple-3f2a9c
name: 論点整理
trigger: on_summary_update
input_scope: summary_and_recent:30
---

いま議論している論点を 3 つ以内で整理してください。
````

- frontmatter は `kind` / `id` / `name` / `trigger` / `input_scope`（+任意 `model`）のみ。
  本文全体が「観点プロンプト」になる
- 内部ではフル Watcher に脱糖される: `state_mode: snapshot`・`schema: { markdown: string }`・
  `view: {{{markdown}}}` 固定。実行系（Runner・state 保存・fork・promote・enabled.yaml）は
  フル形式と完全に共通
- `schema` / `view` / `state_mode` / `initial_state` を simple に書くとパースエラー（黙って無視しない）
- **役割分担**: 構造化表示・stateful 追跡（TODO 追跡・事前確認チェッカー等）はフル Watcher の領分。
  簡易 Watcher は LLM の Markdown 出力を素通し表示する（表示ブレは許容する割り切り）
- UI: Watchers 管理の「新規作成」は簡易フォーム（名前・観点・対象・実行タイミング）が既定入口。
  「詳細形式に変換…」でフル形式の `.md` に一方通行で変換できる（逆変換なし）

### schema の型記法

シンプルな YAML 型宣言。実装時に JSON Schema へ変換して LLM SDK の structured output に食わせる。

- 基本型: `string` / `int` / `float` / `bool`
- nullable: 型の後ろに `?`（例: `string?`）
- enum: `enum[a, b, c]`
- 配列: YAML のリスト直下の `-` は **その配列要素の型宣言**（`items: [ - id: int, question: string ]` は `items: Array<{id, question}>` と解釈される。要素は 1 度しか書けない）
- ネスト: そのまま YAML の入れ子

### view の記法（Mustache）

- 変数展開: `{{variable}}`
- 配列繰り返し: `{{#items}} ... {{/items}}`
- 条件分岐: `{{#is_answered}} ... {{/is_answered}}`（bool または truthy）
- **derived flags の自動注入**: enum 値ごとに `is_<value>: bool` を Kikimi が自動生成
  - 例: `status: "answered"` → `is_answered: true, is_open: false, is_partial: false`

### Trigger の種類

| Trigger | 発火タイミング | 典型的用途 |
|---------|---------------|-----------|
| `on_summary_update` | サマリ更新のたび | 事前確認事項・TODO 追跡・脱線検出 |
| `on_session_end` | **会議終了（Ended）時に1回**（一時停止では発火しない） | 議事録メール下書き・振り返り |
| `on_manual` | UI「今すぐ実行」ボタンのみ | コスト重いもの・確認用 |
| `on_interval:<秒>` | N 秒ごとに定期（**Recording 中のみ発火**、Paused / Ended では停止し、再開で再始動） | 時間管理系・進捗チェック |

**実行順序**: 同じトリガで複数の Watcher が発火する場合、**並列実行**する。各 Watcher の state は独立なので相互依存はない。UI は各サブタブごとに完了順に更新表示。

**Recording 中の Watcher .md 編集**: 次回発火から即反映（state はそのまま、view / schema / prompt だけ入れ替え）。schema 変更で既存 state のバリデーションが落ちた場合は `initial_state` にリセットしてバッジ表示する。

### source_seg_id によるトレーサビリティ

- schema に `source_seg_id: string?` を含めれば、LLM に根拠セグメントIDを返させられる
- view でレンダリングされた出力の該当箇所（seg ID を含むテキスト）をクリックすると **Transcript タブに切り替わり、該当セグメントへスクロール**
- ファクトチェック・「これいつ言った？」の追跡に有用

### セッション有効化リスト

各セッションフォルダの `watchers/enabled.yaml` で「このセッションで有効な Watcher ID」を管理。

```yaml
# sessions/<id>/watchers/enabled.yaml
enabled:
  - pre-check          # preset 参照（session-local に同名がなければ）
  - action-items       # preset
  - risk-check         # session-local
```

- ID の解決順序: **session-local を優先**、無ければ preset をルックアップ
- 新規ウィンドウ作成時は `~/.config/kikimi/default_watchers.yaml` をコピー
- Watchers タブ（Draft 中は準備専用画面の「▸ Watchers」）のチェックボックスで有効/無効切り替え

### Session-local Watcher の作り方

Watchers タブの管理セクションから3つの経路:

- **新規作成**: 空 template から書く
- **Preset を fork**: 好きな preset を選ぶと `sessions/<id>/watchers/<id>.md` にコピーされ、session-local として編集可能に
- **他セッションからコピー**: 過去セッションの `watchers/` にあった local watcher を持ってくる

### Session-local → Preset への昇格

UI から「これをプリセットとして保存」で `~/.config/kikimi/watchers/<id>.md` に書き出す。同名 preset があれば上書き確認ダイアログ。

### State 永続化

- 各 Watcher の実行結果は `sessions/<id>/watchers/<id>.state.json`（schema に沿った JSON）
- `state_mode` による扱い
  - `cumulative`: 次回 `{{state}}` に前回結果を注入して更新
  - `snapshot`: 毎回作り直し（`{{state}}` は空）
  - `append_only`: 差分のみ LLM に返させ、Kikimi 側で累積マージ
- セッション横断ではない（新セッションで initial_state から開始）

### 表示レンダリング

- **UI 表示**: view で生成された Markdown をセッションウィンドウの Watchers タブ内サブタブで表示
- **Wiki export**: 同じ view を使ってセッション終了時の Markdown に埋め込む（11 章）
- **エラー時のフォールバック**: schema バリデーション失敗時は前回の state をそのまま表示 + エラーバッジ

### UI 表示

セッションウィンドウの **Watchers タブ**内にサブタブとして表示（10 章参照）。

- サブタブ切り替えで各 Watcher の最新結果を見る
- 表示は常に view template のレンダリング結果（Markdown プレビュー）
- サブタブヘッダに「実行中」「エラー」「N分前更新」バッジ
- 出力の seg ID 記法をクリックで **該当セグメントへジャンプ**
- 「今すぐ実行」ボタンで手動トリガ

### Watchers タブでの管理 UI

管理 UI（有効化・追加・編集）は **Watchers タブに集約**する（結果表示と管理が 1:1 で対応する。
`docs/design/17-session-window-redesign.md` §5.4）。Draft 中はタブが無いため、準備専用画面の
「▸ Watchers」DisclosureGroup から同じ管理 UI に到達できる。

```
── 管理 ─────────────────────────────────────────
✓ 事前確認事項           共通             [編集] [fork]
✓ アクション抽出         共通             [編集] [fork]
✓ 顧客A用語チェック      この会議のみ      [編集] [削除]

[新規作成]  [プリセットから追加]
────────────────────────────────────────────────
```

- チェックボックスで enabled 切り替え（`enabled.yaml` に反映）
- `[編集]` は preset なら read-only プレビュー、local なら編集エディタ
- `[fork]` は preset を session-local にコピーして編集可能にする
- `[プリセットから追加]` は既存 preset ライブラリからピック
- 空状態では「この会議で追跡したい観点を追加できます」の説明とともに管理 UI を直接表示する

---

## 10. UI / UX

### 3種類のウィンドウ

Kikimi の UI は以下の3ウィンドウ種別で構成される。全てフローティング NSPanel。

1. **Session Window** — 1つの会議を担うメインウィンドウ（複数同時に開ける）
2. **Session List** — 過去セッションの一覧・管理・複製起動
3. **Settings** — 全体設定（既定 context・既定 summary_template・モデル・Watcher 管理）

### Session Window（セッションウィンドウ）

常時見えるヘッダ + 状態で切り替わるコンテンツから成る（詳細設計は
`docs/design/17-session-window-redesign.md`）。

- **Draft（未録音）**: タブバーを出さず、**準備専用画面**（事前メモ + 折りたたみの詳細オプション）
- **Recording / Paused / Ended**: **4 タブ**（`準備 / 会議 / Watchers / チャット`）

```
Draft（準備専用画面）                    Recording 以降（4タブ）
┌──────────────────────────────┐       ┌──────────────────────────────────┐
│ 無題の会議 ✎      [● 録音開始] │       │ [準備][会議][Watchers][チャット]   │
├──────────────────────────────┤       ├──────────────────────────────────┤
│ 事前メモ                      │       │ デイリースクラム [■][⏹] 25:12       │
│ ┌──────────────────────────┐ │       ├───────────────────────[▤|▥|▦]───┤
│ │ (参加者・アジェンダ…)      │ │       │ 書き起こし        │ サマリ          │
│ └──────────────────────────┘ │       │ 14:30:05 (mic) … │ ## 概要         │
│ ▸ サマリの構成をカスタマイズ   │       │ 14:30:08 (シ) …  │ ## 決定事項      │
│ ▸ Watchers                   │       │                  │                │
│          [他セッションから複製…]│       └──────────────────┴────────────────┘
└──────────────────────────────┘
```

- 録音開始で準備専用画面 → タブ UI に遷移し、会議タブがアクティブになる
- 会議終了時はサマリペインを可視化する（書き起こしのみ表示中なら「両方」へ）
- 自動切替は状態遷移の瞬間のみ。以降のユーザーのタブ・ペイン操作には介入しない

**ヘッダ**（常時表示）

- タイトル（インライン編集可、自動命名は `title_auto_generated` フラグ管理）
- 録音操作ボタンは状態で変わる（「停止」と「終了」を分離。前述「セッションウィンドウ」参照）:

  | 状態 | ボタン |
  |------|--------|
  | Draft | `[● 録音開始]` |
  | Recording | `[■ 一時停止]` `[⏹ 会議終了]` |
  | Paused | `[● 録音再開]` `[⏹ 会議終了]` |
  | Ended | `[↩ 再開]`（救済。押すと Recording に戻る） |

- **`■ 一時停止` は録音を止めるだけ**で確定処理（`on_session_end`）は走らない。何度でも `● 録音再開` できる
- **`⏹ 会議終了` が唯一の確定操作**。ここで `on_session_end`（Wiki export・最終タイトル生成・session-end Watcher）が発火
- Recording / Paused 中は経過時間（＝累積録音アクティブ時間）を表示
- 他ウィンドウが Recording 中は、このウィンドウの `● 録音開始` / `● 録音再開` が disabled（Recording は同時に1つ）

**準備（Draft 専用画面 / 録音開始後は「準備」タブ）**

セッション専用の準備を書く場所。単一スクロールで「事前メモ（context.md）」を主役に置き、
上級者向け要素は折りたたみに隠す。

- **事前メモ**（context.md のエディタ）: 空のときはプレースホルダ
  「参加者・アジェンダ・専門用語を書いておくと、書き起こしの整形とサマリの精度が上がります」を表示
- **▸ サマリの構成をカスタマイズ**（DisclosureGroup・既定閉）: summary_template.md のエディタ +
  使用可能変数（`{{title}}` `{{overview}}` `{{decisions}}` `{{action_items}}` `{{participants}}`）のヘルプ
- **▸ Watchers**（DisclosureGroup・既定閉、**Draft 専用画面のみ**）: Watchers タブと同じ管理 UI（9 章参照）。
  録音開始後は Watchers タブ側で管理するため準備タブには置かない
- **NSTextView（プレインテキスト）** で実装（MVP 最小構成）
- 編集は Draft / Recording / Ended いつでも可能
- Recording 中の変更反映タイミングは 4 章「context.md / summary_template.md のライフサイクル」表を参照。
  事前メモ入力枠の直下に反映タイミングのヒント（「ここの変更は次のサマリ更新から反映されます。
  書き起こしの整形には少し遅れて反映されます。」）を **Recording / Paused 中のみ**表示
- ファイルサイズカウンタ（32KB/16KB 上限）は使用量が上限の 80% を超えたときのみ表示
- 「他セッションから複製」で Session List を絞り込み表示 → **context だけ / template だけ / 両方** を明示的に選んで上書き（複製対象を切り替えられる）

**会議タブ（書き起こし + サマリの統合ビュー）**

書き起こしとサマリを 1 タブに統合し、右上の 3 状態セグメントコントロールで表示を切り替える。

- **表示モード**: `書き起こしのみ / 両方（2 ペイン・既定） / サマリのみ`。モードはウィンドウごとに
  state.yaml へ保存される
- **書き起こしペイン**: セグメントリスト（時系列）
  - 各行: `HH:MM:SS` `話者アイコン` `テキスト`
  - 生書き起こしは薄いグレー、整形完了で通常色
  - 整形待ちは「🔄」
  - 自動追従スクロール（上スクロールで一時停止）
- **サマリペイン**: 現在の `summary.md` を Markdown プレビュー表示
  - 「サマリ全文再生成」ボタン（refined 全体から作り直し。サマリ未生成時は非表示）
  - MVP は `AttributedString` ベースの簡易プレビューでよい
- **更新ドット**: サマリペインが見えていない間にサマリが更新されたら、セグメントの
  「サマリのみ表示」アイコンにドットを出す
- seg ID クリックのジャンプ先はこのタブの書き起こしペイン（サマリのみ表示中は「両方」に切り替わる）
- **Markdown コピー**（詳細設計は `docs/design/37-transcript-markdown-copy.md`）: ツールバー左端の
  コピーボタンで、11 章の Wiki export と同一形式の Markdown をクリップボードへ書き出す。
  クリックで全体（frontmatter + サマリ + 書き起こし）、ドロップダウンで
  `書き起こしのみ / サマリのみ` を選べる。ショートカットは **⌘⇧C**（⌘C は書き起こし行の
  テキスト選択コピーが使うため奪わない）。書き起こしの各行にもホバーで出るコピーボタンがあり、
  その 1 行だけをコピーできる

**Watchers タブ**

有効化されている Watcher の実行結果表示と、有効/無効・編集・追加などの管理を集約する。

- サブタブ切り替えで各 Watcher の最新結果を見る
- 表示は常に view template のレンダリング結果（Markdown）
- 出力の seg ID 記法をクリックで会議タブの該当セグメントへジャンプ
- 「今すぐ実行」ボタンで手動トリガ
- **管理 UI（有効化・新規作成・プリセットから追加・編集・fork・削除・プリセット昇格）もこのタブに置く**（9 章参照）。
  空状態では「この会議で追跡したい観点を追加できます」の説明とともに管理 UI を直接表示する

**チャットタブ**

その場で思いついたことをこの会議の会話について 1 回聞くための経路（詳細設計は
`docs/design/38-session-chat.md`）。Watcher が「あらかじめ決めた観点を継続的に見る」のに対して、
チャットは ad-hoc な単発の質問を受け持つ。

- 質問と回答の履歴は下が最新の 1 列。入力欄は複数行で、**⌘⏎ で送信**（⏎ は改行）
- コンテキストはセッション全体（整形済み書き起こし + サマリ）。`chat.max_context_chars` を超える
  長い会議では**サマリ + 直近の会話**へ自動で降格し、その回答の上に理由を注記する
- 直近数ターンを踏まえた追い質問ができる。回答ごとにコピーボタン
- 録音の状態に依存しない。会議終了後に聞き直すのがむしろ主用途
- コストは既存のセッション別 LLM 課金集計（`docs/design/16-llm-usage-stats.md`）に `chat` として乗り、
  ヘッダのコストバッジに「チャット」の行が出る
- 読むだけで、話者リネームやサマリ更新などの副作用は持たない

### Session List ウィンドウ

過去セッションを一覧できる別ウィンドウ。メニューバー or セッションウィンドウの `⋯` から開く。

```
┌──────────────────────────────────────────────────────────┐
│ Sessions                              [🔍 検索]   [+ 新規] │
├──────────────────────────────────────────────────────────┤
│ ▼ 2026-07                                                │
│   📄 2026-07-01 14:30  デイリースクラム       45m        │
│   📄 2026-07-01 10:00  顧客A打ち合わせ         62m       │
│ ▼ 2026-06                                                │
│   📄 2026-06-30 15:00  1on1                    30m       │
│                                                          │
│  選択中: デイリースクラム                                │
│  [開く] [複製して新規セッション] [削除]                  │
└──────────────────────────────────────────────────────────┘
```

- 月別グルーピング
- Draft / Recording / Paused / Ended の全状態を並べる（Draft のみ / Ended のみ の絞り込みトグルあり）。Draft のまま閉じた空フォルダもここから手動で削除する。**Paused（会議終了せず閉じた）セッションは開き直して再開・終了できる**
- 検索は今のところタイトルのみ（全文検索は将来）
- **「複製して新規セッション」** で context.md / summary_template.md を初期値に使った Draft ウィンドウを開ける（繰り返し会議の主導線）
- **「+ 新規」** はデフォルト context を持つ Draft ウィンドウを開く
- 右クリックメニューの **「Markdown をコピー」** で、ウィンドウを開かずに 11 章と同一形式の
  Markdown をコピーできる（単一選択時のみ。`docs/design/37-transcript-markdown-copy.md`）

### フローティング挙動

- NSPanel `.nonactivatingPanel` で常時最前面
- Chirami と共存（別プロセス）
- 位置・サイズ・開いているウィンドウ一覧は `~/.local/state/kikimi/state.yaml` に保存
- アプリ起動時に前回開いていたセッションウィンドウを復元

### 録音の開始・一時停止・終了

- **各セッションウィンドウのボタン**が主要経路
- Recording は 1 つだけ（グローバル排他）
- **一時停止（Paused）と会議終了（Ended）は別操作**。一時停止は何度でも再開でき、会議終了で初めて確定処理が走る（前述「セッションウィンドウ」参照）
- **ウィンドウを閉じるとき**（close ボタン / ⌘W）、Recording / Paused なら確認なしで「しまう」（後述）に振り替える — 録音は継続し、ウィンドウはメニューバーに退避する。閉じる操作は常に非破壊で、確認ダイアログは出さない
  - 会議を終了したいときは、ヘッダの `⏹ 会議終了` か、メニューバーの「会議を終了」（確認あり）を使う。破壊的（確定処理を伴う）操作の経路はこの2つだけ
  - Draft / Ended のウィンドウは従来どおりそのまま閉じる（セッションは Session List に残る）
- **Paused 放置は無害**（`on_session_end` が走らないだけで、いつでも再開・終了できる）。押し忘れ対策として能動的な自動終了はしない
- **Raycast 連携**（Quick Links / Script Commands）
  - `kikimi://window/new` — 空の Draft ウィンドウを新規作成
  - `kikimi://window/new?based_on=<session-id>` — 過去セッションを複製した Draft ウィンドウ
  - `kikimi://record/quick` — デフォルト context で新規 Draft 作成 + 即録音開始。**既に Recording 中の場合はエラー通知だけ出して何もしない**（既存 Recording を優先し、意図しない切断を防ぐ）
- **グローバルホットキー**: MVP では入れない。将来検討

### しまう / コンパクト表示

録音中に Session Window が居座り会議の邪魔にならないよう、ウィンドウを退避する2つの操作を用意する（詳細設計は [`docs/design/18-recording-window-stow-and-compact.md`](docs/design/18-recording-window-stow-and-compact.md)）。

- **しまう**: Recording / Paused のウィンドウを**閉じる操作（close ボタン / ⌘W）**で発動する。ウィンドウを `orderOut` で非表示にし、録音・整形・サマリ・Watcher は継続する（コントローラ・ViewModel は破棄しない）。ヘッダに専用ボタンは置かない — 「閉じる」がそのまま安全な退避になる。メニューバーが録音インジケータ化し（録音中は経過時間付き録音アイコン、警告バナー保有中は警告アイコン）、メニューの「〜 を表示」からいつでも戻せる
- **メニューバーからの会議終了**: 録音中はメニューバーの「会議を終了」（確認あり）で、ウィンドウを開き直さずに終了できる。終了後はウィンドウが自動再表示され、サマリが見える
- **コンパクト表示**: 同一ウィンドウを 380×44 のピル型ミニバー（録音ドット・経過時間・一時停止/再開・書き起こし1行ティッカー・展開ボタン）に切り替える。ヘッダのボタンで切り替え、会議終了で自動的に通常表示へ復帰する。コンパクト中に閉じる操作をした場合も「しまう」になる
- コンパクト表示ボタンは Recording / Paused のときだけヘッダに出す。Draft / Ended は対象外

---

## 11. LLM Wiki raw export

### 目的

Kikimi のセッションを、既存の LLM Wiki の `_raw/` ステージング領域にそのまま流し込めるようにする。

### タイミング

- **セッション終了時に自動 export**
- config で無効化可能

### 出力先

```yaml
# config.yaml
export:
  enabled: true
  target_dir: ~/Documents/Kikimi/export/
```

### ファイル形式

1セッション = 1 Markdown ファイル。ファイル名は `YYYY-MM-DD-{タイトルslug}.md`。

```markdown
---
date: 2026-07-01
duration: 45m
source: kikimi
session_id: 2026-07-01T14-30-00_a1b2c3d4
tags: [meeting, transcript]
---

# デイリースクラム

## サマリ

{summary.md の内容をそのまま埋め込み}

## 書き起こし

**14:30:05 自分** 次のスプリントで対応します。

**14:30:08 田中** 了解しました。

...
```

- **Frontmatter は export 側を正とする**（固定キー: `date` / `duration` / `source` / `session_id` / `tags`）。summary.md 側は frontmatter を含めない前提なので二重にはならない
- タイトルは meta.json の最終タイトル
- **話者列は話者分離の表示名**（`自分` / 実名 / `Speaker N` / `A + B`）。話者分離が無効・未稼働の区間は `system` になる。詳細な写像は `docs/design/37-transcript-markdown-copy.md` §4.2
- **中身のないセクションは見出しごと省く**（サマリ未生成なら `## サマリ` を出さない）
- 書き起こしは refined 版を優先、**refined_text が null の場合は raw_text にフォールバック**（欠落を作らない。フォールバックした行にはマーカーを付けてトレーサビリティを保つ）。**まだ整形されていないセグメントも同じマーカー付きで出す**
- **refined_text が空文字（意味なしと判定され削除されたセグメント。7 章）の行は export に含めない**（フォールバックもしない）
- 会議終了時の export は**整形の drain 完了後にもう一度実行して上書きする**（末尾の端数バッチが未整形のまま残らないようにするため。`docs/design/37-transcript-markdown-copy.md` §5.1）

---

## 12. 設定ファイル

### config.yaml

```yaml
# ~/.config/kikimi/config.yaml

storage:
  session_dir: ~/.local/state/kikimi/sessions/

audio:
  format: wav
  sample_rate: 16000
  channels: 1

stt:
  engine: nemotron-streaming    # 既定値。将来のエンジン差し替え口として名前を残す（FluidAudio + Nemotron 3.5 ASR Streaming）
  language: ja-JP               # Nemotron の言語条件付け（プロンプト指定）。auto も指定可
  chunk_ms: 2240                # streaming chunk 長。560/1120/2240/4480 のいずれか。既定 2240（ja/zh 等 multilingual vocab での推奨値）
  segment_idle_timeout: 2.0     # セグメント確定ロジック（docs/design/11-streaming-stt.md 3.3 route 2）の秒数。既定 2.0
  max_segment_characters: 120   # セグメント確定ロジック（同 3.3 route 3）の文字数上限。既定 120
  two_pass_decode: true         # セグメント確定時の Parakeet バッチ再デコード（docs/design/33-meeting-two-pass-decode.md）。既定 true。false でストリーミング確定のみに戻る
  # モデルは FluidAudio 自身のキャッシュ（~/Library/Application Support/FluidAudio/Models/）に自動ダウンロードされる

# 話者分離（システム音声内の複数話者の分離・実名化）。
# 詳細は docs/design/13-speaker-diarization.md / docs/design/20-voiceprint-misassignment-mitigation.md
diarization:
  enabled: true                     # false で本機能を丸ごと無効化（従来どおり mic/system 表示）
  self_name: 自分                    # mic セグメントの表示名
  step_ms: 500                      # LS-EEND step（100/500）
  variant: callhome                 # LS-EEND variant（callhome/dihard3/dihard2/ami）
  min_enroll_speech_ms: 5000        # 声紋抽出に必要な最低発話量
  speaker_match_threshold: 0.45     # 声紋照合の cosine 距離閾値（実測データにより 0.65 から引き下げ）
  speaker_match_margin: 0.05        # 異名の次点話者との距離差がこれ未満なら曖昧として棄却。0 で無効

# 新規 Draft ウィンドウの初期値として使うファイル
defaults:
  context_file: ~/.config/kikimi/context/common.md
  summary_template_file: ~/.config/kikimi/templates/summary.md

# LLM プロバイダ選択（claude CLI サブスク方式 / OpenAI 互換 HTTP 方式）。詳細は docs/design/14-llm-provider.md
llm:
  provider: claude-cli          # claude-cli | openai。既定 claude-cli（後方互換）
  claude:
    cli_path: null              # 任意。claude 実行ファイルの明示パス
  openai:
    base_url: ""                # 必須。例:
                                #   OpenAI:       https://api.openai.com/v1
                                #   Azure v1:     https://<res>.openai.azure.com/openai/v1
                                #   Azure legacy: https://<res>.openai.azure.com/openai/deployments/<dep>
    api_key: ""                 # 直接指定（ローカル個人アプリなので config 直書きを許容）
    api_key_env: ""             # api_key が空のとき、この名前の環境変数から読む
    api_version: ""             # 空以外なら ?api-version=<値> を付与（Azure legacy 形式）
    model: ""                   # 空以外なら全呼び出しの model を上書き（Azure のデプロイ名運用向け）
    auth_header: ""             # "bearer" | "api-key"。空なら api_version 有→api-key / 無→bearer

refinement:
  model: claude-haiku-4-5-20251001    # セグメント整形のモデル
  batch_size: 10
  batch_timeout_ms: 5000
  context_segments: 3
  # context.md の反映粒度（キャッシュ更新間隔）。詳細は 7 章
  context_refresh_batches: 10

# 用語集のカテゴリ（人物名・環境名など、ユーザーが自由に定義するグループ）。
# id はアプリが採番する UUID で、エントリはこれを参照する。name はいつでも変更してよい。
glossary_categories: []
  # - id: 8B1FA0C2-...      # Settings の [+] が採番する
  #   name: 人物名            # 自由に変更可（エントリは id を参照しているので壊れない）
  #   instruction: |          # このカテゴリ固有の追加指示（任意）
  #     以下は人物名です。敬称（さん・様）は原文のまま残してください。

# 用語集（固有名詞・専門用語を、書かせたい表記へ置換させる）。
# 会議書き起こし整形（refinement）とディクテーション整形の両方が使う共通設定。
# 「誤変換の修正」と「表記ゆれの統一」は同じ操作として扱う（種別フィールドは持たない）。
# 詳細は docs/design/28-glossary.md
glossary: []
  # - term: nekosuke         # 書かせたい表記
  #   reading: ねこすけ       # 置換元の表記（任意。空なら「実在の固有名詞」の合図のみ）
  #   category: 8B1FA0C2-... # glossary_categories[].id への参照（任意。省略で未分類）
  # - term: stg環境
  #   reading: ステージング環境  # 正しく書き起こされた語の表記統一もここで表す
  # - term: yamada
  #   reading: 山田, やまだ  # 置換元が複数あるときはカンマ区切りで 1 エントリにまとめる

summary:
  model: claude-haiku-4-5-20251001    # サマリ生成のモデル。refinement とは独立に指定可
  update_trigger_segments: 20
  update_trigger_seconds: 180
  auto_naming: true

watchers:
  # Watcher preset ライブラリ（各 .md ファイル）
  presets_dir: ~/.config/kikimi/watchers/
  # 新規ウィンドウで既定 enable にする Watcher ID 一覧
  default_enabled_file: ~/.config/kikimi/default_watchers.yaml
  # Watcher 実行のモデル既定値（Watcher frontmatter で上書き可）
  default_model: claude-haiku-4-5-20251001

chat:
  # チャットタブ（会話への ad-hoc 質問）のモデル
  model: claude-haiku-4-5-20251001
  # プロンプト全体（書き起こし + サマリ + 質問 + 会話履歴）の文字数上限。
  # 超えるとサマリ + 直近セグメントへ自動降格する
  max_context_chars: 120000
  # プロンプトに載せる過去ターン数（画面の履歴は切り詰めない）
  history_turns: 6
  timeout_seconds: 180

export:
  enabled: true
  target_dir: ~/Documents/Kikimi/export/

appearance:
  # フォント・サイズ・カラーなど
```

### state.yaml

```yaml
# ~/.local/state/kikimi/state.yaml

windows:
  - session_id: 2026-07-01T14-30-00_a1b2c3d4
    x: 100
    y: 100
    width: 800
    height: 600
    visible: true
    active_tab: meeting          # prep | meeting | watchers（旧 transcript/summary は読み込み時に meeting へ移行）
    meeting_pane_mode: both      # transcript | both | summary（会議タブのペイン表示モード）
  - session_id: 2026-07-01T16-00-00_b2c3d4e5
    x: 950
    y: 100
    width: 800
    height: 600
    visible: true
    active_tab: prep
    meeting_pane_mode: both

session_list_window:
  x: 100
  y: 750
  width: 500
  height: 400
  visible: false
```

---

## 13. アーキテクチャ概要（実装イメージ）

Chirami のアーキテクチャを踏襲する。

### 主要コンポーネント

| コンポーネント | 役割 |
|---------------|------|
| `AppConfig.shared` | config.yaml の読み書き |
| `AppState.shared` | state.yaml の読み書き |
| `SessionStore.shared` | セッションのファイル I/O（JSONL 追記・meta 更新）|
| `WindowManager.shared` | フローティングパネルの管理 |
| `AudioCapture` | AVAudioEngine + ScreenCaptureKit ラッパー |
| `SttEngine` | FluidAudio（Nemotron 3.5 ASR Streaming）ラッパー（2インスタンス）。セグメント確定時に Parakeet バッチ再デコードで raw を高精度化（design 33） |
| `RefinementQueue` | バッチ整形キュー + Haiku 呼び出し |
| `SummaryUpdater` | サマリ更新スケジューラ |
| `WatcherRunner` | Watcher の実行と state 管理 |
| `WikiExporter` | セッション終了時の Markdown export |

### 依存ライブラリ

**Swift (SPM)**

| ライブラリ | 用途 |
|-----------|------|
| Yams | YAML パーサー |
| FluidAudio (SPM package) | STT（CoreML/ANE 版 Nemotron 3.5 ASR Streaming） |
| swift-sdk (Anthropic) or 自前 HTTP クライアント | Claude API |
| HotKey（将来） | グローバルホットキー |

**JS（採用するなら）**

- サマリ・書き起こしプレビューを WKWebView にする場合は Chirami の editor-web を参考に最小構成を組む
- MVP では SwiftUI Markdown プレビュー（`AttributedString` or `MarkdownUI`）で十分な可能性

### Xcode プロジェクト

- xcodegen + `project.yml` の運用を踏襲
- mise タスク（`mise run build`, `apply`, `generate` など）を整備

---

## 14. Chirami 移行計画

→ docs/development-process.md へ移動（1章「Chirami 移行計画」）

---

## 15. Open Questions（実装着手前に確認したい事項）

- **Claude API キー管理**: Keychain 保存で良いか？初回起動時に UI 入力させるフローの詳細
- **オフライン時の挙動**: refined キューは溜め続けて復帰後にまとめて処理するか、UI で警告するか
- **セッション中のクラッシュ復旧**: JSONL 追記なので transcript.jsonl は残る。`state` が `recording`（区間の `ended_at` が `null`）のまま残っていたら異常終了とみなし、次回起動時にその区間を閉じて（`ended_at` を最終セグメント時刻で補完、`duration_ms` を再計算）**Paused として開く**。ユーザーは再開または会議終了を選べる。`on_session_end` は勝手に走らせない（明示的な会議終了でのみ）
- **音声ファイルサイズ制限**: 長時間会議（3時間 ≒ 330 MB/stream × 2 = 約 660 MB）でのディスク圧迫警告
- **Screen Capture Kit の権限フロー**: 初回起動時のシステム設定誘導
- **Raycast Extension 化**: URL scheme + CLI で足りるか、それとも公式 Raycast Extension を出すか
- **Watcher 実行のコスト計算表示**: 会議ごとの累積 API コストを UI に表示するか
- **音声文字入力（ディクテーション、2 章「将来的に検討し得る」参照）**: 詳細設計は
  [`docs/design/25-dictation-mode.md`](docs/design/25-dictation-mode.md)。以下の論点はすべて同文書で確定済み
  - **録音排他との干渉**: 会議録音中でもディクテーションホットキーを拒否せず、マイクを共有して両方同時に動かす（同一発話が会議 transcript とディクテーションの両方に入る可能性は許容する。同文書 R4）
  - **整形の低レイテンシ経路**: `RefinementQueue`（バッチ直列）は使わず、単発・低レイテンシの `LLMClient.shared` 直呼び + タイムアウト/オフライン時は raw フォールバック（同文書 R9）
  - **ペースト方式**: 整形完了を待ってから 1 回ペーストする方針は維持しつつ、挿入直前に挿入先を再検証し不一致なら中止・退避する誤爆ガードを追記改定（同文書 R5・§8）。挿入方式は Pasteboard + 合成 `⌘V` を既定とする（unicode 直接タイプは IME 相互作用が実機未検証のため既定にしない。同文書 R6）
  - **新規権限・機能面**: グローバルホットキー（`KeyboardShortcuts`、Input Monitoring 不要）とアクセシビリティ権限（他アプリへのテキスト挿入）が新たに必要。いずれも feature 有効化時に遅延取得（同文書 R7・R8）
  - **実装形態**: Kikimi 本体の別モード（`Kikimi/Dictation/`）として同居させる。別アプリ化はしない（同文書 R1）
  - **確定テキストの二段デコード**: 確定テキスト（refinement への入力）は、key-up 後に発話全体を Parakeet バッチモデルで再デコードした結果を使う（ストリーミングはライブ表示専用。バッチ不可時はストリーミングへフォールバック）。ストリーミングモデルがポーズ明けの語を決定的に取りこぼす事象への対策（[`docs/design/31-dictation-two-pass-decode.md`](docs/design/31-dictation-two-pass-decode.md)）

---

## 16. まとめ

Kikimi は Chirami から会議書き起こしを分離した専用アプリで、以下の設計原則で構築する。

1. **ウィンドウ = セッション**。1 会議 1 ウィンドウで独立に準備・録音・レビューできる。複数を Draft で並行仕込みできる
2. **録音は絶対に止めない**。整形・サマリ・Watcher は後段で追いつく前提のパイプライン
3. **バッチ整形 + プロンプトキャッシュ**でコストとレイテンシのバランスを取る
4. **セッションローカルな context / summary_template / Watcher** でプリセット登録なしにアドホック準備が完結。過去セッション複製で繰り返し会議を最短化
5. **モデル分離**（refinement / summary / watchers で個別指定）で用途に応じたコスト/品質バランス
6. **schema + view + patch の分離**をサマリ・Watcher の両方に適用。LLM は差分だけ返し、表示は決定論的にレンダリング。会議が長くなっても更新コストが増えにくい
7. **議事詳細は MVP スコープ外**。トピック境界のリアルタイム判定が難しいため、実戦で必要性を確認してから追加検討
8. **LLM Wiki への自動 export**で個人ナレッジベースにシームレスに接続する
9. **Chirami との完全分離**で、両アプリがそれぞれの本質に集中できるようにする

Phase 4（実戦3本）でチェックポイントを置き、そこで Chirami からの transcript 削除に踏み込む。

---

## 17. 開発方式（Vibe Coding）

→ docs/development-process.md へ移動（2章「開発方式（Vibe Coding）」。17.1〜17.13 は 2.1〜2.13 に対応）

---

## 18. 開発の最初の一歩

→ docs/development-process.md へ移動（3章「開発の最初の一歩」）
