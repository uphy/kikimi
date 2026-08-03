# 46. Control Socket（制御ソケット）詳細設計

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `kikimi.md` 4 章（「停止」と「終了」を分離する）, 10 章（Recording は同時に1つだけ）,
`docs/design/06-ui-panels.md` §9（terminateLater パターン・失敗モード #15）,
`docs/design/25-dictation-mode.md` §4（dictation の状態機械）,
`docs/design/07-session-store.md` §6（SessionState）, `docs/design/09-raycast-integration.md` §3
（`kikimi://` URL scheme。本書はこれと別系統の入口を足す理由を §2 で述べる）。

**実装状況**: 実装済み（`Kikimi/Control/`・`.mise/tasks/_kikimi_control.sh`）。

## 0. 結論（要約）

**アプリに Unix domain socket の制御入口を1つ足し、「いま再起動していいか」をアプリ自身に答えさせる**。
`mise run apply` が外からディスクを覗いて推測するのをやめ、判定と終了をアプリ内で連続実行する。

- ソケット: `~/.local/state/kikimi/control.sock`（0600、起動時 bind・終了時 unlink）
- コマンドは 2 つ。`status`（busy か理由を答える）と `quit`（idle なら flush して終了、busy なら拒否）
- 応答は 1 行 JSON。`nc -U` で 1 行送って 1 行受け取れる（`jq` でそのまま読める）
- busy の定義は 3 つ: 録音中・ディクテーション実行中・Paused セッションのウィンドウが開いている
- `quit` は判定と `NSApp.terminate` を同一 MainActor ホップで行うため、判定と終了の間に発話が
  割り込む窓がない。従来のディスク推測にあった「猶予窓」というヒューリスティック自体が消える
- 併せて `pkill` を既定の終了手段から外す。SIGTERM ハンドラが無いため `applicationShouldTerminate`
  を通らず、`prepareForTermination()` の flush が飛んでいた（本書の副次的な目的）

## 1. 目的

`mise run apply` は `~/Applications/Kikimi.app` を差し替えるためにアプリを一度終了させる。会議の
書き起こし中やディクテーション中に終了させると、その発話は失われる。

初版は外からディスクを見て推測していた（`meta.json` の `state`、履歴フォルダに `entry.json` が
無いこと）。これには 3 つの弱点がある。

- **猶予窓が要る**: クラッシュ残骸と進行中を区別できないため「N 秒以内なら進行中」と近似するしかない。
  ディクテーションは 1 発話 4〜21 秒（2026-08-03 実測）なのに、残骸を捨てるために 120 秒待たせていた
- **取りこぼしの窓が残る**: 判定してから `pkill` するまでの間に発話が始まると殺してしまう
- **`dictation.history.enabled: false` で完全に盲目になる**: フォルダが作られないため何も検出できない

アプリ自身は `DictationController.shared.state`（全遷移が 1 点に集約）と
`WindowManager.shared.recordingSessionId` を持っている。そこに聞けば 3 つとも消える。

## 2. なぜ URL scheme ではなく socket か

`kikimi://` は一方向で、応答は `out=<path>` に書かせてクライアントがポーリングするしかない
（`kikimi://debug/webview` がその方式）。「まだ書いていない」と「アプリが受け取っていない」を
区別できず、拒否理由を同期で受け取れない。

| 経路 | 理由の返し方 | 待ち方 | Web から叩けるか |
|---|---|---|---|
| Unix domain socket | 応答が標準出力に返る | 同期。接続可否で生存も分かる | 不可 |
| SIGUSR1 | 固定パスのファイル | ポーリング | 不可 |
| URL scheme | `out=` のファイル | ポーリング | 可 |

socket は接続できた時点で「アプリが生きていて応答できる」が確定する。残骸ソケットは connect が
失敗するので誤検出しない。`kikimi://` はウィンドウ操作という別の目的を持つ入口であり、そちらは残す。

## 3. プロトコル

行指向。1 接続 1 往復で閉じる。

```
$ echo "status" | nc -U ~/.local/state/kikimi/control.sock
{"busy":true,"reason":"dictation is capturing"}

$ echo "quit" | nc -U ~/.local/state/kikimi/control.sock
{"quit":false,"reason":"session 2026-08-03T05-59-26_9427133b is recording"}
```

| コマンド | 応答（idle） | 応答（busy） |
|---|---|---|
| `status` | `{"busy":false}` | `{"busy":true,"reason":"<理由>"}` |
| `quit` | `{"quit":true}` を返してから終了 | `{"quit":false,"reason":"<理由>"}` |

未知のコマンドは `{"error":"unknown command"}`。理由文字列は人間とログのためのもので、クライアントは
真偽値だけで分岐する（文字列マッチに依存させない）。

改行区切りにするのは `nc` がそのまま使えるからで、フレーミングは行末 `\n` 1 つ。リクエストは
64 バイトで打ち切る（`status`/`quit` しか受けないため、それ以上は不正な入力）。

## 4. busy の定義

上から順に評価し、最初に成立したものを理由として返す。

| 条件 | 判定元 | 理由文字列の例 |
|---|---|---|
| 録音中 | `WindowManager.shared.recordingSessionId != nil` | `session <id> is recording` |
| ディクテーション実行中 | `DictationController.shared.state` が `.idle` / `.disabled` 以外 | `dictation is capturing` |
| Paused セッションのウィンドウが開いている | 開いている workspace の session state | `session <id> is paused and open` |

3 つ目は kikimi.md 4 章の「停止と終了の分離」に対応する。録音は止まっていても会議は続いているので、
ウィンドウが開いている間は会議中とみなす。ウィンドウを閉じてある Paused セッション（過去の残骸）は
busy にしない。初版の「30 分以内に更新された Paused」という時間ヒューリスティックはこれで不要になる。

`.disabled` を idle 側に置くのは、ディクテーション機能が off のときの状態だからである。

## 5. quit の順序

```
MainActor:
  1. busy 判定 → busy なら {"quit":false,...} を返して終了しない
  2. DictationController.suspendForTermination()   // 以後のホットキーを無視させる
  3. {"quit":true} を書き、socket を close
  4. AppDelegate.terminateForUpdate()
       a. await flushBeforeTermination()   // 録音停止 + 全ウィンドウの flush。5 秒で打ち切る
       b. isTerminatingForUpdate = true
       c. NSApp.terminate(nil) → applicationShouldTerminate は .terminateNow を返す
```

1・2 は同じ MainActor ホップで連続実行する。間に別のイベントが割り込まないため、「判定したときは
idle だったが terminate の直前に発話が始まった」という窓が存在しない。

2 は 4a の待ち時間に対する保険である。flush は非同期で、その間もホットキーは生きている。
`state = .disabled` にすれば `DictationHotkeyDownDecision.decide` が `.ignore` を返す。

3 を 4 より先に行うのは、プロセスが消えると応答が届かないためである。

### なぜ `terminateLater` を使わないか

**`NSApp.terminate` を Swift concurrency のタスクから呼ぶと `terminateLater` はデッドロックする**。
`-[NSApplication terminate:]` は `replyToApplicationShouldTerminate:` をネストしたイベントループで
待つが、そのループは MainActor タスクがスケジュールされるキューを drain しない。結果、`reply` を
呼ぶはずのタスクが永久に実行されない。

2026-08-03 に実測。`sample` の出力ではメインスレッドが次の位置で止まっていた。

```
ControlSocketServer.serve(clientFD:) closure
  -> -[NSApplication terminate:]
     -> -[NSApplication _shouldTerminate]
        -> nextEventMatchingMask: ...   （ここで待機したまま）
```

したがって制御ソケット経路では **flush を先に済ませ、`applicationShouldTerminate` は
`.terminateNow` を返す**。メニューからの終了は従来どおり `terminateLater` を通る（AppKit が
イベントループから `terminate:` を呼ぶため、この問題を踏まない）。

`applicationShouldTerminate` の録音中モーダルもこの経路では出ない。1 で録音していないことを
確認済みだからである。

## 6. クライアント（`mise run apply`）

ビルドは status で通してから走らせ、終了はビルド後に quit で依頼する。ビルドは数分かかるので、
その間アプリを落としたままにはしない。ビルド中に会議が始まった場合は quit が拒否し、成果物だけが
残る（会議後の `mise run apply` はその成果物を使うので速い）。

```
1. pgrep -x Kikimi                     -- 動いていなければ以下をすべて省略
2. status で問い合わせ                  -- busy なら exit 10（ビルドしない）
3. mise run build
4. quit で終了を依頼                    -- busy なら exit 10（成果物は残る）
5. プロセス消滅を待つ（最大 10 秒）
6. ~/Applications/Kikimi.app を差し替え、open -g で起動
```

**フォールバック**: socket が無い・`nc` が無い・応答が壊れている場合は、初版のディスク推測
（`.mise/tasks/_kikimi_control.sh` の `kikimi_fallback_*`）に落ちる。本書のバージョンをまだ
入れていないアプリが動いている間は、これが唯一の判定手段になるため残す。制御ソケットを持たない
ビルドが動きうる期間を過ぎたら削除する。

**エスカレーション**: quit を受理したのに 10 秒経ってもプロセスが消えない場合のみ `pkill` する。
flush が固まった場合の最終手段であり、通常経路では使わない。

## 7. 失敗モード

| # | 状況 | 挙動 |
|---|---|---|
| 1 | bind 失敗（パーミッション等） | `.error` ログ。制御ソケット無しで起動を続行（アプリ本体は止めない） |
| 2 | 前回のソケットが残っている | bind 前に unlink する。connect 中のクライアントは失敗し、フォールバックへ |
| 3 | クライアントが送らずに切断 | accept したまま 5 秒で読み捨てて close |
| 4 | 応答が読めない / 壊れている | クライアント側はフォールバックへ（安全側 = 判定できないなら止めない側ではなく、推測に戻す） |
| 5 | quit 受理後に flush が固まる | `flushBeforeTermination()` の 5 秒タイムアウト（メニュー経路と共用）→ それでも残ればクライアントが 10 秒後に pkill |
| 6 | AF_UNIX のパス長制限（104 バイト） | 実パスは 57 バイト。`$HOME` が異常に長い環境では bind に失敗し #1 と同じ扱い |

## 8. テスト

- `ControlCommand.parse` / `ControlResponse.encode` — 純粋関数。未知コマンド・空行・長すぎる入力
- `ControlBusyEvaluator` — 3 条件の優先順位と、`.disabled` が idle 側であること。状態は注入する
- socket サーバーの結合テスト — 一時ディレクトリに bind して 1 往復。パス長制限に触れないよう
  `TMPDIR` 直下ではなく短いパスを使う
- `_kikimi_control.sh` のフォールバック — socket 不在時に初版のロジックが動くこと（手動確認）
