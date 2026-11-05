# 環境とアプリの仕様による制約

スキルの script では解決できない、環境やアプリの仕様による制約と回避策。§7 の改善で新しい制約を見つけたら、ここに足す（古くなった記述はその場で直す）。

## ログ

- `log` は zsh の builtin とぶつかるので、必ず `/usr/bin/log` をフルパスで呼ぶ。素の `log stream` は `(eval):log:1: too many arguments` になり、predicate のクォート崩れに見える
- `log show` は info・debug を既定で残さない。info のログ（声紋の照合距離など）を見たいときは、録音の前に `/usr/bin/log stream --info --debug --process Kikimi` を仕掛けてから操作する

## env の注入

- 直接 exec した Kikimi のバイナリは LaunchServices の登録が不完全で、URL・AppleEvent を受けない。env は `with_env.sh`（`launchctl setenv` → `open -a`）で渡す
- テストの後は必ず `launchctl unsetenv` で戻す。戻さないと、以降の通常の起動までスタブとダミーの音源で動く（`with_env.sh` は `trap` で戻す）
- `open -a` は起動中のプロセスには効かない（前面に出すだけ）。env を確実に効かせるには、先に `pgrep -x Kikimi` で確かめ、動いていれば kill してから `with_env.sh` を流す。効いていないと、録音してもセグメントが増えない形で気づく

## クリックと AX

- Session List が開いていると `window 1` は "Sessions" のウィンドウになる。window はインデックスでなくタイトルで指す
- 修飾キー付きのクリックは、キーイベントを別に送らず、クリックのイベント自体に `CGEventSetFlags` でマスクを立てる（`post_click(x, y, flags=...)`、`scripts/cmd_click.py`）。ダブルクリックは `kCGMouseEventClickState` を 1→2 にして送る（`scripts/double_click.py`）
- 複数選択の状態からいきなり 1 行をダブルクリックすると、選択が 1 行にまとまらず `primaryAction` も発火しない。先に単発のクリックで 1 行を選んでからダブルクリックすると開く。実機のトラックパッドでも起きるかは切り分けていない
- SwiftUI の `onTapGesture`・`contentShape` のタップ領域（話者マップの Canvas の点、List の行の選択など）は、ウィンドウが key でないと合成クリックで発火しない。最初から `click.py ... --focus` を使う。NSButton のボタンとタブは背面のままで動く
- SwiftUI の `confirmationDialog` は `sheet 1 of window` に出る。ボタンに名前が無いので、`position of button N of sheet 1` で左右を見てインデックスでクリックする（左がキャンセル、右が確定）。Session List のフッタのボタン（開く・複製・削除）も名前が無く、position で見分ける
- DisclosureGroup（準備画面の「サマリの構成をカスタマイズ」「Watchers」など）は、座標でなく `AXDisclosureTriangle` を AX でクリックする。開くと要素の数が変わるので、次のトライアングルを押す前に `UI elements of` を取り直す。開閉は `value of` の `true`・`false` で分かる
- `group 1` の直下に無いボタン（会議タブのペイン切替など）は、`UI elements of` で一段ずつ潜り、`help of e` で探す。`entire contents` の全走査は誤クリックのもとなので使わない
- NSPopover（話者のリネームなど）は AX ツリーに出ない。クリックは届くが要素を読めないので、結果の state ファイル（`voiceprints.json` など）を読んで確かめる

## IME

- `type.py`・paste はクリップボードの Cmd+V で、IME を通らない。未確定の文字列の変換は自動で再現できないので、原因をコードで直し、ビルドの健全性を機械で確かめ、IME の高速入力の最終確認だけを ユーザーに頼む
- NSTextView を包む `updateNSView` で `textView.string = text` を入れると、変換中の文字列を上書きして打った文字が消える。冒頭に `guard !textView.hasMarkedText() else { return }` を置く

## メニューバーが AX から消える

- 再起動（`build_and_apply.sh`・`restart.sh`・`pkill`）を 8〜10 回ほど繰り返すと、`count menu bars` が 0 を返し続け、メニューバー経由で Settings に届かなくなることがある。コードの問題ではなく、`killall SystemUIServer` でも直らない
- 回数は Kikimi.app 全体の再起動の数で数える。並列の subagent が同じ `~/Applications/Kikimi.app` を build・再起動していると、自分の再起動が少なくても起きる（`ps aux | grep -i "swift build"` に自分の起動でないプロセスがいる、`git status` に自分の範囲外の変更が出る、で気づく）
- 回避策
	- 変更をまとめてから 1 回だけ再起動する
	- 起きたら UI のクリックでの検証をやめ、`swift test`、同じファイル内の検証済みの UI の形とのコード照合、`~/.config/kikimi/config.yaml` の読み書きでの round-trip の 3 つで代え、完了報告にそう書く
	- それでも要るなら ユーザーにログアウト・ログインか再起動を頼む
