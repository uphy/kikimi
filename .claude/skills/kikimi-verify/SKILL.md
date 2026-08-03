---
name: kikimi-verify
description: Kikimi の GUI・録音パイプライン動作確認を行うスキル。ビルド・再起動、ウィンドウキャプチャ、クリック・文字入力、セッションフォルダの構造検証を組み合わせて UI とデータ両方を検証する。「動作確認して」「確認して」「ビルドして試して」「録音を試して」「セッションフォルダを確認」など、Kikimi の見た目・挙動・保存データの確認が必要なとき、または開発後に変更が正しく反映されているかを確かめたいときは必ずこのスキルを使う。
---

# Kikimi GUI・録音パイプライン動作確認

Chirami の `chirami-verify` skill（`~/dev/github.com/uphy/chirami/.claude/skills/chirami-verify/`）を
ひな型にしている。差分は「録音開始 → ダミー音源投入 → 停止 → セッションフォルダ構造検証」という
データパイプライン確認が主要フローになる点。

## 前提

- アクセシビリティ権限が必要（クリック・キー入力を送るため）。失敗する場合は「システム設定 → プライバシーと
  セキュリティ → アクセシビリティ」に Terminal.app（または Claude Code）を追加するよう案内する。
- Kikimi は **グローバルホットキーを MVP では持たない**（kikimi.md 10 章で明示的に見送り）。ウィンドウの
  表示・録音操作は `kikimi://` URL scheme か画面上のボタンクリックで行う。
- **決定的なテストのため、Kikimi 側は以下の環境変数をサポートする前提で設計している**（Phase 1 の実装で
  Kikimi 側に組み込む）:
  - `KIKIMI_TEST_INPUT=/path/to/dummy.wav` — AVAudioEngine の実マイク入力の代わりにこの WAV ファイルを
    ストリーミング再生してフィードする（mic / system 両ストリームに使える）
  - `KIKIMI_STUB_LLM=1` — Claude API 呼び出しを id エコースタブに差し替える。`refined_text` は基本的に
    `"[stub] " + raw_text` だが、`raw_text` に「えーと」を含む、または空文字のセグメントは
    `refined_text: ""` を返す（意図的なドロップ）。整形成功パスとドロップパスの両方を E2E で検証できる
    （詳細は 5 章「LLM スタブ」）
  - `KIKIMI_TEST_HIDDEN=1` — 全ウィンドウ（Session Window / Session List / Settings）を画面に見えない
    状態（`alphaValue = 0`。ウィンドウは通常どおり order はするので AX ツリー・System Events からの
    クリックは効き続ける）で動かすテストモード。`mise run verify-smoke` は既定でこれを付けて起動する
    ので、実行中に Kikimi のパネルが画面にちらつくことも、Kikimi が frontmost アプリになることもない
    （`Kikimi/Window/FloatingPanel.swift` の `HiddenTestMode`、`SessionListWindowController`/
    `SettingsWindowController` の `show()` はこのモードでは `NSApp.activate` 自体をスキップする）。
    人間の目で見た目を確認したいとき（`capture.sh` でスクリーンショットを撮る通常のこのスキル運用）は
    付けないこと — 付けると何も写らない

## 0. 非侵襲設計（デフォルトでフォーカスを奪わない）

**このスキルの操作はすべて、既定でユーザーのフォーカス・マウスカーソルを奪わない。** 検証のたびに
`activate()`（前面化）していた旧方式を廃止し、Kikimi の `NSPanel .nonactivatingPanel`（
`Kikimi/Window/FloatingPanel.swift`）という実装特性を利用している。nonactivating panel は「クリックを
受け取ってもアプリ自体は前面化しない」という設計そのものなので、検証スクリプト側も前面化せずにクリック・
入力を届けられる（2026-07-05 に実機で実証済み。各操作の前後で `osascript -e 'tell application "System
Events" to get name of first process whose frontmost is true'` を取り、無関係のまま変化しないことを確認した）。

| 操作 | 既定の届け方 | 前面化が要る場面 |
|---|---|---|
| ボタンクリック（`ax_click.py`） | System Events の `click button`（AX 経由）。背面プロセスでも届く | 基本的に不要 |
| 座標クリック（`click.py`/`cmd_click.py`/`double_click.py`） | `CGEventPost` を画面座標に直接投げる（位置ベースなので前面化不要） | 基本的に不要 |
| 文字入力（`type.py`/`paste`） | `CGEventPostToPid`（対象プロセス限定）で Cmd+V。**事前にその欄をクリックして first responder にしておくこと**（このスクリプト自体はクリックしない） | ペースト先に何もフォーカスが無いと届いても無視される（クリック不足が原因であって前面化不足ではないことが多い） |
| `kikimi://` URL scheme（`open_url`） | `open -g`（前面化しない）| 不要 |
| 再起動（`restart.sh`） | `open -g` で再起動 | 不要 |

**うまく届かないときのフォールバック**: 各スクリプトに `--focus` フラグがある。付けると旧来の
`activate()` → 前面化 → グローバル HID tap にフォールバックする。既知の非対称性として、
`build_and_apply.sh`（= `mise run apply`）は **Kikimi リポジトリ側の `.mise/tasks/verify-smoke` が
内部で `open -a` を使っており前面化する**（このスキルの管轄外。触らない）。ビルド直後の1回だけは前面化
され得ると理解しておく。

**新しいスクリプトを足すときの原則**: 「念のため」で `activate()` を足さない。届かない証拠が出てから
足す。届くかどうかは上の `frontmost` 確認コマンドで機械的に検証できる。

### `KIKIMI_TEST_HIDDEN=1` は「見えない」だけでなく「触らせない」（2026-07-30 強化）

この Mac は普段の業務でも使うので、検証が作業を中断しないことを設計目標に置く。`KIKIMI_TEST_HIDDEN=1`
のとき `FloatingPanel` は次の 3 つを同時に満たす。

| 設定 | 効果 |
|---|---|
| `alphaValue = 0` | 画面にもスクリーンショットにも写らない |
| `canBecomeKey = false` / `canBecomeMain = false` | **キーボードを奪わない**。透明なウィンドウが key になると、ユーザーが打っている文字がそちらへ吸われる（「見えない」と「無害」は別） |
| `ignoresMouseEvents = true` | **マウスクリックを飲まない**。見えないウィンドウがヒットテストに参加すると、ユーザーのクリックが消える |

`mise run verify-smoke` の後始末も `open -g -a`（前面化しない）で戻す。

**この代償として、TEST_HIDDEN 下では次が使えない**:

- `click.py` / `cmd_click.py` / `double_click.py` / `right_click.py` などの**座標クリック**
  （`ignoresMouseEvents` で透過する）
- `type.py` / `replace_text_field.py` の **CGEvent キー入力**（key window にならないので届かない）

**代わりに使うもの**（いずれも key window を要らない。実測済み）:

- `ax_click.py` — ヘッダーのボタン
- `tab_click.py` — タブ切替
- `webview.sh` — WebView の読み取り・ページ内クリック
- `kikimi_interact.py open_url` — `kikimi://` URL scheme
- テキスト入力が要る検証（準備タブのエディタ・タイトル編集・チャット入力）は、
  **ファイル経由で代替する**（`context.md` / `summary_template.md` は実ファイル）か、
  **TEST_HIDDEN を外して可視・key ありで回す**。後者を選ぶときはユーザーの作業を中断するので、
  作業していないタイミングで行う

## 1. ビルドと再起動

```bash
SCRIPTS=~/.claude/skills/kikimi-verify/scripts

$SCRIPTS/build_and_apply.sh            # 通常ビルド（mise run apply）
$SCRIPTS/build_and_apply.sh --force    # キャッシュ無効ビルド（mise run -f apply）
$SCRIPTS/restart.sh                    # リビルドせず再起動のみ
```

完了後、Kikimi は自動再起動される。

## 2. ウィンドウの起動・確認

Kikimi のウィンドウはタイトルが動的（会議名）なので、`chirami-verify` の固定 "Test" ノートのような
決め打ちは使えない。`kikimi_interact.py list` で現在開いているウィンドウを確認するか、`kikimi://` URL
scheme で確実に狙った状態のウィンドウを作ってから操作する。**`kikimi://` URL scheme は実装済み**
（`window/new` / `window/new?based_on=` / `record/quick` とも実際にウィンドウ・セッションを生成する。
以前このスキルにあった「URL scheme は未実装で無反応」という制約は解消された）。`open_url()` は内部で
`open -g` を使うため、この呼び出し自体はフォーカスを奪わない（0 章参照）。

```bash
SCRIPT=$SCRIPTS/kikimi_interact.py

# 現在開いている Kikimi ウィンドウを一覧
python3 $SCRIPT list

# 新規 Draft ウィンドウを開く（確実にタイトル未確定の1ウィンドウを作る）
python3 $SCRIPT open_url "kikimi://window/new"

# 過去セッションを複製した Draft ウィンドウ
python3 $SCRIPT open_url "kikimi://window/new?based_on=<session-id>"

# デフォルト context で新規 Draft 作成 + 即録音開始
python3 $SCRIPT open_url "kikimi://record/quick"
```

> ⚠️ **`kikimi://record/quick` は既に Recording 中のとき拒否される。** 「Recording は同時に1つ」の不変
> 条件を守るため、他のウィンドウが Recording 中ならエラー通知だけを出して新規ウィンドウも録音も作らない
> （既存の Recording を優先し、意図しない切断を防ぐ設計。kikimi.md 10 章）。この URL を叩く前に、他の
> ウィンドウが Recording 中でないことを確認しておくこと（`kikimi_interact.py list` や各セッションの
> `meta.json` の `state` で確認できる）。拒否された場合、新しいセッションフォルダは作られない。

> ⚠️ **タイトル未確定のウィンドウを `capture.sh`/`click.py` の空文字タイトルで狙うと、Sessions ウィンドウ
> を誤って掴むことがある。** `kikimi://window/new`/`record/quick` 直後の会議ウィンドウは自動命名前で
> `kCGWindowName`/AX `name` が空文字のため、`capture.sh ""`（内部で `kikimi_interact.py capture ""` →
> `get_window(None)`）は「タイトル空文字にマッチする最初のウィンドウ」を返すが、その順序は
> `CGWindowListCopyWindowInfo` の並びに依存し、Sessions ウィンドウが同時に開いていると Sessions が先に
> 来て誤爆することがある（2026-07-04 に再現確認: 新規会議ウィンドウのキャプチャのつもりが Sessions の
> スクリーンショットになった）。**確実に狙うには**、ウィンドウ作成前後で `kikimi_interact.py list` の
> 差分を取って対象の `kCGWindowNumber` を特定し、`screencapture -l <number> -o <out.png>` で直接キャプ
> チャする（`capture()` 関数と同じ`-o`付き呼び出しなので座標換算は変わらない）。**一方 `ax_click.py` の
> ボタンクリック（AX/System Events 経由）はこの問題を踏まない**: System Events 側のウィンドウ順序は
> CGWindowList と一致するとは限らないが、実際には未確定タイトルの会議ウィンドウが `window 1`（空タイトル
> フォールバック）で安定して解決できている（同日確認）。つまり「クリック操作は `ax_click.py` を使う限り
> 空タイトルのままで問題ないが、キャプチャだけは window number を明示するほうが安全」という非対称性がある。

## 3. ウィンドウの可視判定

Kikimi はメニューバー常駐（LSUIElement）でプロセスの生死だけでは実際にウィンドウが見えているか分からない。
`kCGWindowListOptionOnScreenOnly` で実状態を判定する。

```bash
python3 $SCRIPTS/check_visible.py                    # プロセス状態 + on-screen 全ウィンドウを一覧
python3 $SCRIPTS/check_visible.py "デイリースクラム"    # 指定タイトルを含むウィンドウが on-screen なら exit 0
```

## 4. クリック・文字入力・キャプチャ

`click.py` / `type.py` は既定で **前面化しない**（0 章参照）。`click.py` は画面座標への
`CGEventPost`（位置ベースなので前面化不要）、`type.py` は対象プロセス限定の `CGEventPostToPid` で
Cmd+V を送る。**`type.py` はどこにもクリックしないので、ペースト先の欄には事前に `click.py` 等で
クリックして first responder にしておくこと**（例: 事前メモ欄をクリック → `type.py` でペースト）。
**開いた直後のウィンドウでは、欄への 1 回目のクリックがパネルのキー化に消費されて欄にフォーカスが
付かないことがある**（2026-07-06 に参加者入力欄で再現。traffic light が点灯しフォーカスリングなし →
2 回目のクリックでリング点灯）。type.py の前にキャプチャでフォーカスリングを確認し、無ければもう一度
クリックする。
届かない場合だけ `--focus` を付けて旧来の activate() 前面化にフォールバックする。第1引数はウィンドウ
タイトルの部分一致文字列（`""` で「最初に見つかった Kikimi ウィンドウ」にフォールバック）。

```bash
# -o キャプチャのピクセル(px,py)をクリックして結果をキャプチャ（前面化しない）
python3 $SCRIPTS/click.py "" 110 400 /tmp/out.png

# クリップボード経由でテキストを Cmd+V ペーストして結果をキャプチャ（前面化しない。
# 事前にペースト先の欄へ click.py 等でクリック済みであること）
python3 $SCRIPTS/type.py "" "会議のアジェンダ\n- 見積提示" /tmp/out.png

# 前面化しても構わない/届かないときのフォールバック
python3 $SCRIPTS/click.py "" 110 400 /tmp/out.png --focus
python3 $SCRIPTS/type.py "" "会議のアジェンダ" /tmp/out.png --focus

# 既に値が入っているインライン編集欄（例: Settings 話者タブのリネーム TextField）を
# 選択→置換→Return で確定したいときは type.py ではなく replace_text_field.py を使う。
# クリックで focus → Cmd+A（全選択）→ Cmd+V（ペースト）→ Return（確定）を一括で行う。
# (px, py) は zoom_crop.py のズーム後ローカル座標ではなく、素のキャプチャの px（click.py と同じ規約）。
# 2026-07-07: Settings 未アクティブ化時は素の click_px だけでは first responder にならず
# 入力が届かないことがあった。届かない場合は --focus を付ける（内部で activate() してから操作する）。
python3 $SCRIPTS/replace_text_field.py "設定" 230 1656 "新しい名前" /tmp/out.png --focus

# タイトルが空/曖昧で click.py の解決が誤爆し得るとき（2章のキャプチャ誤爆と同じ罠のクリック版）は、
# kikimi_interact.py list で kCGWindowNumber を特定して window number 指定でクリックする
python3 $SCRIPTS/click_win.py 6303 800 718 /tmp/out.png

# タイトル部分一致でウィンドウをキャプチャのみ（capture は元々前面化しない）
$SCRIPTS/capture.sh "デイリースクラム" /tmp/out.png
```

キャプチャ後は Read ツールで画像を読み込んで視覚的に確認する。

> ⚠️ **`with_env.sh`（テスト入力モード）起動時は黄色バナーでレイアウトが下にずれる。**
> `KIKIMI_TEST_INPUT` / `KIKIMI_STUB_LLM` で起動した Kikimi はウィンドウ上部に
> 「テスト入力モード」の警告バナーを常時表示し、**全コンテンツが約 57px（2x キャプチャ基準）
> 下にずれる**（2026-07-06 に参加者入力欄のクリックで空振りして再現確認）。通常起動時の
> キャプチャで測った座標をテストモードで使い回さないこと。テストモードで座標クリックする
> ときは必ずそのモードでキャプチャし直してから座標を読む。

### キャプチャ座標（`-o` で影を除外）

`capture()` は `screencapture -l <id> -o` を使う。`-o` で影が消えるため画像 = ウィンドウ bounds × 2x
（Retina）になり、座標換算が単純になる:

```
screen_x = bounds["X"] + pixel_x / 2
screen_y = bounds["Y"] + pixel_y / 2
```

クリック先は「`-o` キャプチャ画像の何 px か」を Read で見て決め、`click.py` に渡す。

### List の複数選択・ダブルクリックを検証する（`cmd_click.py` / `double_click.py`）

`SessionListView` のような `List(selection: Set<...>)` の Shift/Command 複数選択やダブルクリック
（`.contextMenu(forSelectionType:primaryAction:)` の `primaryAction`）を検証するときは、専用の
ヘルパーを使う。**素の `click.py` を2回連続で呼んでもダブルクリックにはならない**（AppKit は
`NSEvent.clickCount` を見ており、2回の独立したシングルクリックとして扱われる）。

```bash
# Command-click: 既存の選択に行を追加/除去するトグル複数選択を検証
python3 $SCRIPTS/cmd_click.py "Sessions" 300 462 /tmp/out.png

# ダブルクリック: kCGMouseEventClickState を 1→2 と設定して送るので、AppKit に
# clickCount==2 として認識される（primaryAction / 旧 TapGesture(count: 2) の検証に使う）
python3 $SCRIPTS/double_click.py "Sessions" 300 361 /tmp/out.png
```

`cmd_click.py` / `double_click.py` も既定で前面化しない（0 章参照）。届かない場合のみ末尾に `--focus`
を付ける。

> 2026-07-04 訂正: 以前このスキルには「Shift/Command 修飾付きクリックは合成イベントでは一切届かない」
> という記録があったが、これは誤りだった。**クリックイベント自体（`kCGEventLeftMouseDown`/`Up`）に
> `CGEventSetFlags` でモディファイアマスクを立てれば正しく届く**（実キー押下を別イベントとして送る
> 方式が届かなかった原因と見られる）。`cmd_click.py` / `kikimi_interact.click_px(..., flags=...)` を使えば
> Shift-click（範囲選択）も同様に検証できる（`kCGEventFlagMaskShift`）。

### 右クリックのコンテキストメニュー（`.contextMenu`）を検証する（`right_click.py`）

`List` の行に付いた SwiftUI `.contextMenu`（例: ディクテーション履歴のリスト行）を検証するときに使う。
**通常の `capture()`（`screencapture -l <window id>`）では開いたメニューが写らない**——NSMenu は対象
ウィンドウとは別の WindowServer ウィンドウとして描画されるため、window id 指定のキャプチャは素通りする。
`right_click.py`/`kikimi_interact.right_click_px()` はこれを踏まえ、内部で `screencapture -x`（画面全体）
を使う。

```bash
# 右クリックしてメニューを開き、画面全体をキャプチャ（前面化しない。--focus は届かない場合のみ）
python3 $SCRIPTS/right_click.py "ディクテーション履歴" 200 150 /tmp/menu.png
```

キャプチャ後は `zoom_crop.py` で該当領域をズームし、Read で各メニュー項目の中心座標（ズーム画像内 px）
を読んで元画像の px に戻し、**さらに `/2` して画面ポイント座標に変換してから** `CGEventPost` で普通の
左クリックを送る（`right_click_px()` が返すウィンドウの `bounds` から `screen_x = bounds.X + px/2` の
式は変わらない。メニュー自体はそのウィンドウ所属ではないが、開いた直後は右クリック地点を基準にほぼ
固定オフセットで描画されるため、一度ズームで実測したオフセットは同じ環境なら使い回せる）。

> ⚠️ **実データが活発に動いている環境（ダミー音源でなく実際にディクテーションが使われ続けている等）
> では、メニュー項目クリックまでの間に新しいエントリの `.kikimiDictationHistoryRecorded` 通知が飛んで
> リストが再描画され、開いていたコンテキストメニューが黙って閉じることがある**（2026-07-10 に発生:
> スクリーンショット確認 → 手動でズーム座標を計算 → 数秒後にクリック、という長い round-trip の間に
> 実発話が記録されてメニューが消え、クリックが素通りしてクリップボードが変化しなかった）。対策は
> 「右クリック→メニュー項目クリック」を **1つの python プロセス内で `time.sleep(0.3)` 程度の最小限の
> 待ちだけを挟んで連続実行する**こと（スクリーンショットの Read や別プロセス呼び出しを間に挟まない）。
> オフセットは一度実測すれば使い回せるので、毎回スクリーンショット→Read→計算のループを回す必要はない。

> 既知の未解決事項: 2行以上が既に複数選択されている状態から、追加の単発クリックを挟まずいきなり
> `double_click.py` で同じ行を叩くと、選択が単一行に収束せず開かないことがある（合成ダブルクリックが
> 複数選択からの選択収束を再現できていない可能性があり未確定）。単発クリックで単一選択にしてから
> ダブルクリックする手順は正常動作を確認済みなので、通常の「1行選ぶ→開く」検証はその順序で行うこと。

### 操作系のフォーカス確保（`--focus` フォールバック使用時のみ関係する）

既定では前面化しないので、通常はこの節を気にする必要はない（0 章参照）。`--focus` を付けて旧来の
activate() 経路にフォールバックしたときだけ関係する: `activate()` は `osascript ... to activate` を
Popen（非ブロッキング）で投げ ~0.18s 待つ。通らないときは数回試すと通りやすい（ターミナル/マルチ
プレクサがフォーカスを保持し続けると activate が通らないことがある）。

> ⚠️ **Esc を汎用 dismiss に使わない。** Esc がウィンドウを閉じ、2 発目が背後のターミナルへ抜けてセッションを
> 中断させ得る（chirami-verify で学んだ落とし穴）。パネルを閉じたいときは `×` ボタンなど対象を特定した操作で。

### ヘッダーボタンは ax_click.py の名前指定クリックを第一候補にする

`ax_click.py` は System Events 経由の AX クリック（`click button` = AXPress 相当）で、既定で前面化
しない（0 章参照）。**ヘッダーボタンのクリックは座標・index 指定より「名前指定」を第一候補にする**。
ボタンの並び順・個数はセッション状態（Draft/Recording/Paused/Ended）とタイトル提案バッジの有無で変わ
るため、`index` 指定は簡単にズレる。Kikimi はヘッダーの各ボタンに固定の AX `help` ラベルを付けている
（ボタンラベル契約）ので、これに対して安定してクリックできる。

**ボタンラベル契約**（AX `help`、完全一致文字列。実装側のコミットにより保証される）:

| ラベル | 対象ボタン |
|---|---|
| `録音開始` | Draft → Recording |
| `録音再開` | Paused → Recording |
| `一時停止` | Recording → Paused |
| `会議終了` | Recording/Paused → Ended |
| `再開` | Ended → Recording（救済） |
| `タイトルを編集` | タイトルのインライン編集 |
| `録音入力を設定` | マイク/システム音声の入力選択 |
| `タイトル案を採用` | 提案バッジ表示時のみ出現 |

```bash
# ヘッダーの group 1 配下のボタン一覧を確認（index:label。label は AX help、無ければ description）
python3 $SCRIPTS/ax_click.py list "デイリースクラム"

# 名前指定でクリック（推奨）。完全一致 → 部分一致の順で解決する
python3 $SCRIPTS/ax_click.py click "デイリースクラム" 一時停止

# クリック後 meta.json の state が期待値になるまでポーリングして PASS/FAIL 判定
# （視覚キャプチャより先にこちらで機械的に判定すること）
python3 $SCRIPTS/ax_click.py click "デイリースクラム" 一時停止 paused

# index 指定も後方互換で残っている（非推奨: 状態・バッジでボタン順が変わるため直接依存させない）
python3 $SCRIPTS/ax_click.py click "デイリースクラム" 3 paused

# 会議終了 → ended は on_session_end 込みで十数秒かかることがあるので timeout を伸ばす。
# 第4引数は session_dir なので、timeout だけ変えたいときは第4引数に "" を渡す
# （数値をそのまま渡すと session_dir として解釈され、存在しないパスで無言のまま timeout する）
python3 $SCRIPTS/ax_click.py click "デイリースクラム" 会議終了 ended "" 30

# --focus はどの位置に置いてもよい（フラグとして argv から取り除いてから位置引数を解釈する）。
# AX クリックが届かないときだけ付ける
python3 $SCRIPTS/ax_click.py click "デイリースクラム" 一時停止 paused --focus
```

> ⚠️ **必ずウィンドウタイトルで指定する。`window 1`/`window 2` のようなインデックス指定は使わない。**
> System Events のウィンドウ順序は CGWindowList の順序と一致するとは限らず、インデックス指定では
> 誤ったウィンドウを操作したり `-1719 正しくないインデックスです` で失敗したりする（2026-07-03 に再現確認）。
> `ax_click.py` / `kikimi_interact.py` の `ax_click_button` はタイトル部分一致でウィンドウを解決する
> （`title_substr` が空の場合のみ `window 1` にフォールバックする。複数ウィンドウが開き得る場面では
> 必ずタイトルを渡すこと）。

> ⚠️ **既知の未対応領域: NSPopover は AX ツリーに現れない。** 話者リネームなど nonactivating panel 上の
> popover は、クリック自体（座標クリック・AX クリックとも）は成功してもクリック後の popover 要素が
> AX ツリーに一切出てこず、`title`/`value` の取得が `-1700`/`-1719` で失敗する（2026-07-03 に再現確認）。
> この種のフローは UI クリックで検証しようとせず、結果として書き込まれる state ファイル
> （例: `voiceprints.json`）を直接読んで検証すること。

### リスト内の行内ボタン（Transcript 行の再生ボタン等）は座標クリック + ズームで探す

`ax_click.py` の「名前指定クリック」はヘッダー（`group 1`）専用。**Transcript 行の再生ボタンのような
スクロールリスト内の行内ボタンには使えない**。以下の2つの罠がある（`docs/design/15-segment
-playback.md`（セグメント再生機能）の検証、2026-07-03 に実際に踏んだ）:

- **`entire contents of window` での AX 全走査は危険。** ヘッダーボタン・行内ボタン・popover トリガーが
  フラットな1リストに混在し、視覚的な並び順とインデックスが一致しない。インデックスを目視で数えて
  `click element N` すると、意図した行内ボタンではなく **`会議終了` ボタンなどに誤ヒットしてセッションを
  終了させてしまう**ことがある（実際に発生。Ended は `↩ 再開` で救済できるとはいえ、テストが壊れる）。
  行内ボタンを AX 経由で操作しようとしないこと
- **opacity ベースの表示ボタン（ホバー時だけ見える等）は目視の座標推測だと数 px 外して空振りする。**
  ボタンが 20x20pt 程度と小さいため、フルウィンドウのスクリーンショットから座標を目算すると簡単に外れる

代わりに「ホバー→キャプチャ→ズームクロップで正確なピクセル位置を特定→座標クリック」の手順を使う:

```bash
SCRIPTS=~/.claude/skills/kikimi-verify/scripts

# 1) 対象行にマウスを乗せてボタンを表示させる（opacity: isHovered ? 1 : 0 なパターンが多い）
python3 -c "
import Quartz, time
from Quartz import CGEventCreateMouseEvent, CGEventPost, CGEventSetFlags, kCGHIDEventTap, kCGMouseButtonLeft, kCGEventMouseMoved
e = CGEventCreateMouseEvent(None, kCGEventMouseMoved, (SCREEN_X, SCREEN_Y), kCGMouseButtonLeft)
CGEventSetFlags(e, 0); CGEventPost(kCGHIDEventTap, e); time.sleep(0.3)
"

# 2) ウィンドウ領域をそのままキャプチャ（AppleScript で得た bounds を使う。-R は screencapture の領域指定）
screencapture -R<bounds.X>,<bounds.Y>,<bounds.W>,<bounds.H> -x /tmp/hover.png

# 3) ボタンがありそうな範囲をおおまかに（150x150px 程度、外し気味でよい）ズームクロップして Read で確認
python3 $SCRIPTS/zoom_crop.py /tmp/hover.png 1480 180 1600 320 /tmp/zoom.png 4
# → Read ツールで /tmp/zoom.png を見て、ボタン中心のズーム画像内座標 (zx, zy) を読む

# 4) zoom_crop.py の出力式で元画像座標に戻し、bounds.X + px/2, bounds.Y + py/2 でスクリーン座標に変換して
#    click.py（または直接 CGEventPost）でクリックする
```

再生中/停止中の見た目の違い（例: `play.circle` の灰色アイコン ⇔ `stop.circle.fill` のアクセントカラー
アイコン）で PASS/FAIL を判定する。ログには成功時に何も出ない設計（失敗時のみ warning/info）が多いので、
`log show --predicate 'subsystem == "io.github.uphy.Kikimi"'` でエラーが出ていないことの確認と、
見た目の状態変化の両方を見ること。

### メニューバーの操作（`menu_click.py`）

Kikimi のメニューバー拡張（`MenuBarExtra`。録音インジケータ・「〜 を表示」項目）はどのウィンドウの
AX ツリーにも属さない（`ax_click.py` の対象は `group 1` = ウィンドウヘッダ限定）。System Events の
`menu bar 2`（ステータスアイテム領域）を直接操作する専用スクリプトを使う。

```bash
# 現在のメニュー項目名を一覧（開いて読んで閉じる）
python3 $SCRIPTS/menu_click.py list

# 項目をクリック（完全一致）。例: しまってあるウィンドウの再表示
python3 $SCRIPTS/menu_click.py click "無題の会議 を表示"
```

`ax_click.py` 同様、既定で前面化しない（System Events の GUI scripting は背面プロセスにも届く）。
SwiftUI の `.menu` はメニューを開いた瞬間のスナップショットを描画するため、経過時間など最新値が
必要なときは `list` を都度取り直すこと（`docs/design/18-recording-window-stow-and-compact.md` §3.3）。

> ⚠️ **`build_and_apply.sh` / `restart.sh` の直後は MenuBarExtra の登録に最大 30 秒かかる。**
> その間 `menu bar 2` へのアクセスは `-1719 正しくないインデックスです` で落ちる。これは「スクリプトが
> 壊れている」ではなく「まだ準備できていない」のサイン（2026-07-09 に何度も誤診した）。`menu_click.py`
> は `wait_for_menu_bar()` で最大 40 秒ポーリングするようになったので、**呼び出し側で `sleep` や
> リトライループを書く必要はない**。それでも失敗したらプロセスの生死（`pgrep -x Kikimi`）を疑う。

### スクロール（`scroll.py`）

長い Form やリスト（Settings の「一般」タブ、用語集タブなど）を下まで確認するときに使う。

```bash
# 既定は --at left（ラベル列にポインタを置く）。フォームを下端まで送る
python3 $SCRIPTS/scroll.py "設定" down 30 /tmp/bottom.png

# リストを先頭まで戻す
python3 $SCRIPTS/scroll.py "設定" up 20 /tmp/top.png --at center

# 座標を明示（click.py と同じ -o キャプチャの px 規約）
python3 $SCRIPTS/scroll.py "設定" down 10 /tmp/out.png --px 400 --py 500
```

> ⚠️ **ウィンドウ中央でスクロールしない（`--at center` を安易に使わない）。** Settings の中央列には
> Stepper と Picker が並んでおり、**その上でホイールイベントを流すと値が書き換わる**（config.yaml が
> 黙って変わる）。既定の `--at left` はラベル列（ScrollView 内・コントロール外）にポインタを置くので
> 安全。Form をスクロールした後は、念のため config.yaml をバックアップと diff して値が動いていない
> ことを確認するとよい（2026-07-09 に用語集タブの検証で踏みかけた）。

### state ディレクトリへのフィクスチャ直接注入（ディクテーション履歴など）

UI へのデータ供給経路が無い機能（例: ディクテーション履歴 `~/.local/state/kikimi/dictation/history/`）
は、state ディレクトリへ直接フィクスチャを書いてから画面を確認する。このとき:

- **タイムスタンプ（フォルダ名・JSON 内とも）は必ず「現在より過去」の UTC にする。** きりのいい時刻を
  適当に書くと UTC 解釈で未来になり、実データより常に「新しい」と判定されてソート順の誤診を招く
  （2026-07-10 に発生: 未来時刻のフィクスチャがリスト上部に固定され、ユーザーが「新しい発話が下に出る
  バグ」と報告。実装は正しかった）。`date -u +%Y-%m-%dT%H-%M-%S` を起点に数分〜数時間引いて作るのが安全
- **検証が済んだらフィクスチャは必ず削除する**（ユーザーの実データに混ざったまま残さない）
- 外部からのファイル書き換えはアプリ内の更新通知を発火させない。開いているウィンドウには反映されない
  ので、注入・削除後は再起動（`restart.sh`）してからウィンドウを開き直す

### WebView で描画される画面の検証（`webview.sh`）

**サマリ / Watchers / チャットの本文と、図の拡大オーバーレイは WKWebView のページ**
（`docs/design/39-webview-markdown.md`）。ここは AX ツリーだけでは検証しきれない。

- テキストは AX の static text に出ることもあるが、当てにできない
- **`ax_click.py` は WebView 内の要素を押せない**。回答のコピー・再送・図の拡大ボタンはすべてページ側にある
- キャプチャは非同期描画（特に mermaid）とレースする

そこで `kikimi://debug/webview` 経由でアプリに `evaluateJavaScript` を代行させる。

**アプリはブリッジ有効で起動する必要がある**（無効時は URL が無視される）:

```bash
# KIKIMI_TEST_HIDDEN / KIKIMI_STUB_LLM でも有効になるので、通常の検証起動なら足りている
scripts/with_env.sh KIKIMI_DEBUG_BRIDGE=1 -- ~/Applications/Kikimi.app/Contents/MacOS/Kikimi
```

```bash
# 本文のテキストを読む（target は summary|summaryTopics|watchers|chat|diagram）
scripts/webview.sh dump summary
scripts/webview.sh dump chat /tmp/chat.txt

# 期待文字列が出るまでポーリング（描画は非同期。単発 dump は描画途中を掴む）
# ここを第一候補にする。キャプチャの目視より先に機械判定できる
scripts/webview.sh wait summary "決定事項" 10

# ページ内のボタンを data-testid で押す
scripts/webview.sh click chat "chat-copy-<turn-id>"
scripts/webview.sh click chat "mermaid-zoom"
```

**サマリタブは上下 2 ペインで、それぞれ別の WebView**（`docs/design/47-summary-split-pane.md`）。
`summary` は上ペイン（概要・決定事項・アクションアイテム）、`summaryTopics` は下ペイン（議事詳細）を指す。
議事詳細の文字列を `wait summary` で待つと**永遠に出てこない**ので `summaryTopics` を使う。
テンプレートを分割できなかったセッションだけは `summary` が全文を持ち、`summaryTopics` の WebView は
そもそも生成されない（`no response from Kikimi` になる）。

```bash
scripts/webview.sh wait summary "決定事項" 10
scripts/webview.sh wait summaryTopics "議事詳細" 10
```

**WebView のページはタブを開かないと存在しない**ので、`tab_click.py` で先にタブを切り替える。

```bash
# タブ名を一覧（準備 / 会議 / Watchers / チャット）
python3 scripts/tab_click.py list

# タブを開く（label 完全一致）
python3 scripts/tab_click.py click チャット
python3 scripts/tab_click.py click 会議 --window "会議タイトル"
```

タブバーは `ax_click.py` の走査対象（ヘッダーの group 1）には**いない**。実際の位置は
`window 1 > toolbar 1 > group 1 > radio group 1`（"Navigation Tab Bar"）で、タブは radio button、
**ラベルは `description` にだけ入っている**（`name` / `title` はいずれも `missing value`）。
`AXTabGroup` としては現れないので、それを探しても見つからない。

**`KIKIMI_TEST_HIDDEN=1` 下でも動く**（2026-07-30 実測）。AX は alpha を見ないので、
不可視ウィンドウでもタブ切替と `webview.sh` のダンプは通る — 座標クリックが使えない場面での
唯一の経路。

既知の `data-testid`: `chat-copy-<turn-id>` / `chat-retry-<turn-id>` / `mermaid-zoom`。
新しいボタンを HTML 側に足すときは `data-testid` と `aria-label`/`title`（同文言）を必ず付ける。

**なぜこれが要るのか**（2026-07-30 の教訓）: Swift → JS の引数順が入れ替わっていて、サマリ本文に
文書キー（`summary` / `watcher:<id>`）が描画されていた。目視確認を 2 回すり抜け、ユーザーが気づいた。
`webview.sh wait summary "<期待文字列>"` を回していれば初回で落ちていた。**WebView で描く画面を変えたら、
見た目の確認だけで済ませず必ず `wait` で本文を機械判定する。**

## 5. 録音パイプラインの確認（主要フロー）

Kikimi 固有の検証で最も重要なのはこのフロー。UI の見た目だけでなく、保存されたデータの構造、そして
クラッシュしていないかも毎回セットで確認する（UI・データが正常に見えても、裏でクラッシュ→自動再起動が
起きていたケースを見逃さないため）。

テスト env（`KIKIMI_TEST_INPUT` / `KIKIMI_STUB_LLM`）は **`with_env.sh` でプロセス限定** に渡す。
**`launchctl setenv` は使わない**（GUI 全体のグローバル env を汚し、戻し忘れ・crash・ユーザーの後の
通常起動で次回以降もダミー音源のままになる footgun。2026-07-03/07-04 に度々再発）。`with_env.sh` は
**アプリのバイナリを直接 exec** して env をそのプロセスにだけ効かせる（`open -a` は env を渡さないが、
バンドル内バイナリの直接 exec は env を引き継ぐ。2026-07-04 に検証）。グローバルには何も設定しないので
**unset も trap も不要**、通常起動が汚染される経路が構造的に消える。バイナリ直接 exec も前面化しない
（`open` を経由しないので当然 `-g` 相当。2026-07-05 に frontmost 不変を確認済み）。

```bash
SCRIPTS=~/.claude/skills/kikimi-verify/scripts

# 0) クラッシュレポートのベースラインを記録（これ以前の .ips は「無関係」として無視できるようにする）
$SCRIPTS/crash_diff.sh snapshot

# 1) ダミー音源 + LLM スタブでプロセス限定起動（バイナリを直接渡す。`open -a` は使わない）。
# with_env.sh が既存 Kikimi を kill → 直接 exec → 2 秒 settle まで面倒を見る。launchctl は一切汚さない。
# ダミー音源は KikimiTests/Fixtures/sense-voice-ja-sample.wav（リポジトリ同梱・16kHz mono・7.2秒、
# 「えーと」を含まない普通の発話）がそのまま使える。自前で用意しなくてよい。
$SCRIPTS/with_env.sh \
  KIKIMI_TEST_INPUT=~/dev/github.com/uphy/kikimi/KikimiTests/Fixtures/sense-voice-ja-sample.wav \
  KIKIMI_STUB_LLM=1 -- \
  ~/Applications/Kikimi.app/Contents/MacOS/Kikimi

# 2) 新規 Draft を開いて即録音開始（他ウィンドウが Recording 中でないことを事前に確認しておく。2章参照）
python3 $SCRIPTS/kikimi_interact.py open_url "kikimi://record/quick"
sleep 1

# 3) N 秒待って生書き起こしがリアルタイム表示されているかキャプチャで確認
sleep 10
$SCRIPTS/capture.sh "" /tmp/recording.png

# 4) 一時停止（ax_click.py の名前指定クリックが第一候補。meta.json の state 遷移まで機械的に確認する）
python3 $SCRIPTS/ax_click.py click "" 一時停止 paused

# 5) セッションフォルダの構造を検証（meta.json / audio/*.wav / transcript.jsonl / refined.jsonl）
# KIKIMI_TEST_INPUT はダミー WAV を mic ストリームにだけ流すため system_NNN.wav は生成されない。
# --mic-only を付けると system 音声の欠如を [FAIL] ではなく [WARN] に落とす（誤 FAIL 防止）。
python3 $SCRIPTS/verify_session.py --mic-only

# 6) クラッシュが起きていないか確認（0〜5 の間に新しい .ips が増えていないか）
$SCRIPTS/crash_diff.sh check

# 7) 【必須の後始末】ダミーモードのアプリを絶対に残さない。検証完了後は必ず
#    実マイクモードで起動し直してから報告する（with_env.sh はプロセス限定なので
#    launchctl の unset は不要 — kill して普通に開き直すだけでよい）。
#    restart.sh 自体が kill → 開き直しの両方を面倒見る。既定で -g（前面化しない）。
$SCRIPTS/restart.sh   # 実マイク・実 LLM で、前面化せずに起動し直す
```

> ⚠️ **検証を「書き起こしが動かない」と誤診しないための必須後始末（2026-07-03/07-04 に度々再発）。**
> `KIKIMI_TEST_INPUT` は `AudioCapture.swift` で **`MicrophoneSource` を丸ごと `TestFileAudioSource`
> （ダミー WAV）に差し替える**実装。この env のまま起動したアプリは**実マイクを一切拾わず**、ダミー
> WAV を一度読み終えると以降は無音同然になる。検証後にこのダミーモードのアプリを起動したまま残すと、
> ユーザーが自分の声を入れても何も書き起こされず「ビルドが壊れて書き起こしが一切できない」と誤認する。
> **`with_env.sh` はプロセス限定 env（launchctl を汚さない）に変更済み**なので、後片付けは
> `restart.sh`（内部で kill → `open -g` で実マイクのまま前面化せず開き直す）だけでよい。既に起動済み
> プロセスの env は変えられないので、必ず kill してから開き直すこと。完了報告の直前にこれを実行し、
> 実マイクモード（transcript にダミー文言が出ない・`mic_NNN.wav` が実録音で伸びる）を確認する。
>
> 逆に「書き起こしが出ない」と報告を受けたら、まず疑うのは**ダミーモードのアプリが起動したまま**か。
> `ps aux | grep Kikimi` の起動元・実行中プロセスがダミー由来のテキストを出していないかを最初に確認する
> （古い launchctl 汚染が残っている可能性もあるので `launchctl getenv KIKIMI_TEST_INPUT` も一応見る）。
> ビルドの健全性は `KIKIMI_TEST_INPUT`（＝ダミー）で segment が出るかで即判定できる（source を
> 差し替えるだけで STT・整形・永続化の downstream は実経路と同一なので、ダミーで出れば build は健全）。

`verify_session.py` は `~/.local/state/kikimi/sessions/` 内の最新セッション（または引数で指定した session_id）
について、以下を検証して PASS/FAIL を報告する:

- `meta.json` が存在し、`id` / `state` / `created_at` を持ち、`state` が `draft`/`recording`/`paused`/`ended` のいずれか
- `audio/mic_NNN.wav`, `audio/system_NNN.wav`（録音区間ごとの連番。休憩を挟むと `_001` 以降が増える）が
  1つ以上存在し、非空・16kHz・mono
- `transcript.jsonl` が存在し、各行が JSON として妥当で `id`（`seg_XXXXX` 形式）/ `start_ms` / `end_ms` /
  `speaker`（`mic`/`system`）/ `text` / `confidence` を持つ

### 既存セッションを開き直す場合は show_window.py（フォールバック経路）

上記が「新規セッションを作って検証する」主経路。**既存セッション（Draft/Paused/Ended）のフォルダを
そのまま開き直して続きを検証したい**ときだけ `show_window.py` を使う。`kikimi://window/new?based_on=`
は「複製して新規セッションを作る」であって「同じセッションを開き直す」ではない点に注意。

Kikimi は起動時に一度だけ `state.yaml` を読み、実行中は自分のメモリ上の状態で随時上書き保存するため、
**起動中に `state.yaml` を書き換えても効かない**（次の保存で消される）。`show_window.py` は安全のため
Kikimi 起動中は拒否する:

```bash
# Kikimi を終了させてから（起動中は ERROR で拒否される）
pkill -x Kikimi || true

# 対象セッションのウィンドウを visible: true にする（他ウィンドウ・Session List は隠して見失わないようにする）
python3 $SCRIPTS/show_window.py 2026-07-01T14-30-00_a1b2c3d4 --hide-others --hide-session-list

$SCRIPTS/restart.sh   # もしくは通常の起動手順
```

対象セッションがまだ `state.yaml` にエントリを持たない（一度もウィンドウを開いたことがない、など）場合は
既定ジオメトリ（`x=100 y=100 width=800 height=600 active_tab=prep`）で新規エントリを追加する。

### LLM スタブ（`KIKIMI_STUB_LLM=1`）は id エコースタブ

整形を決定的にするため、`KIKIMI_STUB_LLM=1` では Claude API 呼び出しが固定ロジックのスタブに差し替わる。

- 通常のセグメント: `refined_text = "[stub] " + raw_text`（Transcript にプレフィックス付きで残る）
- `raw_text` に「えーと」を含む、または空文字のセグメント: `refined_text = ""`（**意図的なドロップ**。
  該当行は Transcript から消える）

この2経路が揃っているので、整形成功パス（`[stub] ` プレフィックス）と整形ドロップパス（行が消える）の
両方を E2E で検証できる。ダミー音源にフィラー（「えーと」を含む発話）を混ぜておくと、ドロップの検証が
しやすい。

### LLM スタブのサマリ系 3 キー（`summary_patch` / `final_title` / `summary_final`）

`refinement`（上記の id エコースタブ）と `chat` に加えて、`LLMStubProvider.builtinDefaults` は
`SummaryUpdater` が使う 3 キーの固定 JSON も持つ（kikimi.md 8 章、いずれも `"[stub] "` プレフィックス付き
の固定文字列。`Date` や乱数は使わない決定論的な値）。これが無いと `KIKIMI_STUB_LLM=1` 下ではサマリ更新が
すべて `missingStructuredOutput` で失敗し、`summary.md` が生成されない。

- **`summary_patch`**（`SummaryPatch` にデコード）— 増分サマリ更新（20セグメント/3分ごと、または
  会議終了時の `updateNow(.pauseFlush)`）が使う。`title` / `overview` / `decisions_add` のみを返す。
  `topics_add` と `action_items`（add）は**意図的に含めない**: `decisions_add` と違い
  `SummaryPatchApplier` に内容ベースの重複排除が無く、id 衝突時はリネームして追記するだけなので、
  同じ固定 JSON を1セッション内で複数回リプレイすると `## 議事詳細` やアクションアイテムが
  重複蓄積してしまう（詳細は `LLMStubProvider.swift` の `builtinDefaults` doc comment）。topics /
  action items のスタブ内容が要る検証は `KIKIMI_STUB_LLM_FILE` で個別に差し込む
- **`final_title`**（`TitleOnly` にデコード）— 会議終了時の最終タイトル案生成が使う
- **`summary_final`**（`SummaryFinalRevision` にデコード）— 会議終了時の最終整形パス（overview /
  decisions / action_items の全置換）が使う。contract どおり `id` は含まない（適用時にアプリが
  `dc_00N` / `ai_00N` を採番し直す）。全置換なのでリプレイしても重複蓄積の問題は無い

`mise run verify-smoke` はこの3キーのおかげで `summary.md` が実際に生成されるようになったので、
`webview.sh wait summary "..."` でサマリタブの描画まで確認する（4 章「WebView で描画される画面の検証」参照）。

## 6. 確認フローの基本パターン

1. `build_and_apply.sh` でビルド・再起動（再起動で focus 状態はリセットされる）
2. まずレンダリングの確認（`capture.sh` でキャプチャ → Read で視覚確認）
3. 操作・挙動の確認が必要なときだけ `ax_click.py`（名前指定クリック）/ `click.py` / `type.py`
4. データパイプラインの確認は `verify_session.py` で構造検証（UI だけでは分からない欠落を機械的に検出できる）
5. クラッシュしていないかを `crash_diff.sh snapshot`（実行前）/ `check`（実行後）で機械的に確認する
6. 必要に応じて追加操作して再確認

## chirami-verify から引き継いだ落とし穴

- `screencapture -o` で影を除外しないと座標換算がずれる
- クリック前に `CGEventSetFlags(e, 0)` で前回キー入力のモディファイアフラグをクリアしないと、クリックが
  「モディファイア+ドラッグ」として無視されることがある
- ループでキーイベントを送るときは、各回の前にウィンドウの存在を確認してから送る（フォーカスが移ると誤入力になる）
- `kCGWindowListOptionOnScreenOnly` を使わないと、メニューバー常駐アプリの「実際に見えているか」を正しく判定できない

## 7. スキル自体の改善（検証後の必須チェック・ユーザー指示による恒常運用）

検証タスクの**完了報告を書く前に**、今回の検証で以下に当てはまるものがなかったか振り返り、
当てはまるなら**その場でこのスキルを改善する**（ユーザーへの確認は不要。改善した内容は完了報告に含める）。

**改善トリガ（1つでも該当したら改善する）**:

- 同じ操作を2回以上やり直した／試行錯誤した（例: ボタン index の推測、タイムアウト不足での誤 FAIL）
- scripts/ にない操作を生の osascript・python ワンライナー・インライン script ででっち上げた
  → 今後も使いそうなら script 化して scripts/ に追加する
- SKILL.md の手順どおりに実行して失敗した → 手順を実態に合わせて修正する
- スクリプトの引数・出力・エラーメッセージが不十分で原因究明に時間を食った → スクリプト自体を直す
- 誤った前提（古いボタン構成・古い挙動）に基づいて操作してしまった → 記述を更新する

**改善の仕方**:

- 手順の文言・注意書きの修正 → SKILL.md を直接編集
- 新しい操作の script 化 → scripts/ に追加（python3 は stdlib のみ、既存 script の docstring ヘッダ形式に合わせる）し、SKILL.md の該当セクションに使い方を追記
- 失敗の原因が**環境・アプリ仕様**（スキルでは解決できない）なら、プロジェクトメモリ
  `kikimi-verify-env-limits.md` に事実と回避策を追記する（古くなった記述はその場で直す）
- アプリ側の修正が根本対策の場合（AX ラベル欠如など）は、完了報告でユーザーに提案する

**判断基準**: 「次に同じ検証をする自分が、今回と同じ場所でまた止まるか？」— 止まるなら改善対象。
一度きりの偶発事象（フォーカス取り損ねの1回リトライ等）は対象外。
