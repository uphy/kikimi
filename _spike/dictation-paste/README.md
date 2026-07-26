# spike: グローバルホットキー + 他アプリへのテキスト挿入

ディクテーション機能（kikimi.md 2章「将来的に検討し得る」/ 15章）の**唯一の未知数**を潰すための使い捨てスパイク。

STT と LLM は既存資産（`SttEngine` / `LLMClient`）で足りることがコード調査で分かっている。一方、
ホットキー・アクセシビリティ権限・他アプリへのテキスト挿入は Kikimi に一行も存在せず、
しかもここが動かなければ機能そのものが成立しない。設計を積む前にここだけ確かめる。

**このコードは製品に入れない。** 判断材料を取ったら捨てる。

## 使い方

```bash
(cd ../.. && mise run signing-identity)   # 初回のみ。再ビルドで権限を失わないため
./run.sh                                  # ビルド → .app 化 → 署名 → 起動
tail -f /tmp/dictation-spike.log
```

初回は「アクセシビリティ」権限を求めるダイアログが出る。System Settings で許可すると、
アプリを再起動せずそのままホットキーが有効になる（ログに `trust granted` が出る）。

| 操作 | 意味 |
|------|------|
| `⌃⌥Space` を押して離す | 押下時刻を記録し、離した瞬間の入力先をキャプチャ。`SPIKE_DELAY_MS` 後にサンプル文を挿入 |
| `⌃⌥1` | 挿入方式を AX（`kAXSelectedText` への書き込み）に切替 |
| `⌃⌥2` | 挿入方式を クリップボード + 合成 `⌘V` に切替（既定） |
| `⌃⌥3` | 挿入方式を CGEvent unicode 直接タイプに切替 |
| メニューバー 🎤 → Quit | 終了 |

```bash
SPIKE_DELAY_MS=0 open build/DictationSpike.app     # 遅延なし
SPIKE_DELAY_MS=1500 open build/DictationSpike.app  # 重い整形を想定
```

`SPIKE_DELAY_MS` は「キーを離してから LLM 整形が返るまで」の模擬待ち時間（既定 800ms）。
この遅延中にユーザーが別アプリへ切り替えると、ログに `⚠︎ focus moved during delay` が出る。

`./run.sh --no-build` は再ビルドせずプロセスだけ入れ替える。

## 何を確かめるのか

### A. ホットキーのジェスチャ

Handy 型の「押している間だけ録音」が成立するかどうか。Carbon `RegisterEventHotKey` を使っている
（`NSEvent.addGlobalMonitorForEvents` と違い Input Monitoring 権限が不要で、key-up も取れる）。

- [x] `kEventHotKeyReleased` が安定して発火する（`held 61ms` / `held 44ms` を観測）
- [ ] **修飾キーを主キー（Space）より先に離した**ときも release が来るか ← 最も怪しい
- [x] 他アプリのショートカットと衝突しないか → **衝突した**。下記参照

`⌥Space` は Raycast が CGEventTap で握っており、Carbon hotkey より先に処理される。
`RegisterEventHotKey` は成功するので**両方が発火**し、ランチャが開くと同時に文字も挿入された。
ホットキーを `⌃⌥Space` に変更して回避済み。

> 本体への示唆: ホットキーはユーザー設定可能にすべき。既定値を固定で決め打つと、
> ランチャ系ツールと衝突したときに黙って二重発火する（登録は成功するのでエラーも出ない）。

### B. 挿入方式ごとの成否（本命）

3方式 × 対象アプリのマトリクスを埋める。**1つの方式で全アプリを賄えないなら、
アプリごとにフォールバックする設計コストが乗る**ので、その事実が分かることに価値がある。

| アプリ | AX | Pasteboard+⌘V | unicode | 備考 |
|--------|-----|---------------|---------|------|
| TextEdit (native Cocoa) | ✅ | ✅ | ✅ | 3方式とも readback で確認 |
| Chrome (Chromium) | ✅ | ✅ | ✅ | `role=AXTextArea` のとき。下記の落とし穴あり |
| VS Code (Electron) | ❌ | ✅ | ✅ | 保存後のファイル内容で確認（readback は使えない） |
| cmux (ターミナル) | | ✅ | | `role=AXTextField` |
| Slack (Electron) | | | | 未検証。誤送信リスクがあり自動化しなかった |

事前の仮説は**外れた**。「AX は native Cocoa でのみ効く」と踏んでいたが、Chrome では AX 書き込みが通る。
効かなかったのは Electron（VS Code）だけ。一方で **Pasteboard と unicode は全アプリで通った**ため、
アプリごとのフォールバックは不要に見える。

### 落とし穴: 挿入 API の戻り値は信用できない

`AXUIElementSetAttributeValue` は `role=AXButton` の要素に対しても `.success` を返す。
実際には何も挿入されない。Pasteboard 方式に至っては「⌘V を post した」以上のことを何も知らない。

そのため spike は挿入後に `AXValue` を読み返して実挿入を検証している。これがなければ
「AX 方式は全アプリで動く」という**誤った結論**を出していた。

readback にも限界がある。Electron/Monaco は本文を `AXValue` に載せないので、
VS Code では空文字が返り、判定不能になる（当初これを "NOT INSERTED" と誤表示していた）。
VS Code の結果は `⌘S` で保存してファイルの中身を見て確定させた。

### C. レイテンシ

ログの `release→done` が「キーを離してから文字が出るまで」。整形の待ち時間込み。

- [x] `insert` 単体は 1〜15ms。挿入方式そのもののコストは無視できる
- [x] `release→done` は 835〜854ms。ほぼ模擬遅延（800ms）そのもの
- [ ] 実際の LLM 整形を挟んで体感が許容できるか（目標 1 秒以内）

レイテンシは**整形の往復時間がすべて**であり、挿入手段の選択はここに影響しない。

### F. focused element の粒度（誤爆ガードの前提）

挿入は key-release ではなく「整形が返った約 1 秒後」に起きる。合成 `⌘V` も unicode タイプも宛先を持たず、
発行時点のフォーカスに入る。よって挿入直前に「挿入先が変わっていないか」を検証したいが、
frontmost の pid だけでは同一アプリ内のフォーカス移動を見逃す。

`AXUIElement` の同一性で判定できるかを SIGUSR2 プローブで実測した（挿入せず読むだけ）。

- [x] Electron（Slack）は pid 同一のまま**要素ごとに別の `AXUIElement`** を返す。
      メッセージ画面の `AXButton` と `⌘K` 検索欄の `AXComboBox` を `CFEqual` で区別できた
- [x] 同一要素を 2 回読むと `CFEqual` は一致する（VS Code の `AXTextArea`）。比較基準として安定
- [x] `AXError -25212` は `kAXErrorNoValue`（その瞬間フォーカス要素が無い）。**アプリが隠しているのではない**
- [ ] VS Code のエディタ ↔ 統合ターミナル。ワークスペース信頼ダイアログに阻まれ未測定

**AX に「書けない」ことと「読めない」ことは別。** AX 書き込みは Electron で効かないが、読み取りは効く。
だから誤爆ガードは Electron でも入力欄レベルで機能する。

### D. 遅延中のフォーカス移動 ← 未確定・要再検証

- [ ] 遅延中に別アプリへ切り替えると、テキストはどこへ入るか
- [ ] キャプチャ済み `AXUIElement` に書けば元のアプリへ入るか（AX 方式のみ可能なはず）
- [ ] Pasteboard 方式では**必ず**手前のアプリに入ってしまうか（= 誤爆する）

**一度測ろうとして失敗した。** readback は「ターゲットに サンプル文が含まれるか」しか見ないので、
同じ TextEdit に何度も挿入した後だと、今回どこに入ったかに関わらず VERIFIED を返す。
両方式とも VERIFIED と出たが、これは前回までの残留テキストを拾っただけ。

再検証するときは、**毎回まっさらな空のターゲットを用意する**こと（毎回新規ファイルを開き、
挿入前に 0 バイトであることを確認する）。

D は設計に直結する。Pasteboard も unicode も「その瞬間の frontmost」に送る方式なので、
遅延中にユーザーがアプリを切り替えれば必ず誤爆する。AX 方式ならキャプチャ済みの element に
書けるので誤爆しないはずだが、**その AX 方式は Electron で使えない**。
つまり「整形完了を待って1回ペースト」（kikimi.md 15章の決定）は、
Electron アプリでは誤爆を構造的に避けられない可能性がある。ここは詰める必要がある。

### E. 日本語 IME との相互作用

サンプル文は `次のスプリントで対応します。` にしてある。

- [ ] IME が「ひらがな」入力モードのとき、挿入結果が変換対象として横取りされないか
- [ ] 未確定文字列が残っている状態で挿入したらどうなるか

## 権限が再ビルドで失効する問題（解決済み）

`swift build` が付ける ad-hoc 署名は TeamIdentifier を持たないため、TCC が保存する
designated requirement が cdhash に直結する（`designated => cdhash H"..."`）。
cdhash はビルドごとに変わるので、許可が毎回失効する。

**厄介なのは、System Settings の一覧には「許可済み」と表示されたままになること。**
TCC.db の `auth_value` は 2（許可）のまま残り、csreq 検証だけが落ちるため、
UI 上は正常に見えるのに `AXIsProcessTrusted()` は false を返し続ける。トグル OFF → ON でも直らない。

`mise run signing-identity` で作る自己署名証明書で署名すると、requirement が

```
designated => identifier "io.github.uphy.DictationSpike" and certificate leaf H"b2fa..."
```

となり cdhash を参照しなくなるため、再ビルドしても権限が保たれる。
Kikimi 本体の `mise run build` も同じ証明書で署名するようになっている。

署名方式を切り替えた直後だけ、古い csreq のエントリを消す必要がある:

```bash
tccutil reset Accessibility io.github.uphy.DictationSpike
./run.sh
```

現在の登録状態は次で確認できる（`auth_value` が 2 でも信用しないこと）:

```bash
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select client, auth_value from access where service='kTCCServiceAccessibility';"
```

## バンドル化は必須

ターミナルから直接実行ファイルを叩くと、TCC は権限をターミナル側に紐づけてしまい、
検証結果が嘘になる。`run.sh` は必ず `.app` 化してから `open` する。

## 結果

### 判定

- [x] **Go** — Pasteboard 方式と unicode 方式は、native / Chromium / Electron / ターミナルの
  すべてで実挿入を確認できた。**単一方式で全アプリを賄える**ので、アプリごとのフォールバックは要らない。
  この機能は成立する

未検証の項目（D の誤爆・E の IME・修飾キーの離す順序）は、いずれも
「成立するか」ではなく「どう作るか」の問題なので、Go 判定を覆さない。

### 所見

**挿入手段は問題ではなかった。** 当初「ここが動かなければ機能そのものが成立しない」と見ていた部分は、
2 方式が全アプリで通り、コストも 1〜15ms と無視できる。想定していた最大の不確実性は解消した。

**本当の論点は3つに移った。**

1. **誤爆（D）**: Pasteboard も unicode も「その瞬間の frontmost」に送る。整形の往復に約 1 秒かかる以上、
   その間にユーザーがアプリを切り替えれば別のアプリに文字が入る。AX 方式なら防げるが Electron で使えない。
   Slack や VS Code を対象にする以上、**誤爆を構造的に避けられない**可能性がある
2. **クリップボード汚染**: Pasteboard 方式はユーザーのクリップボードを踏む（spike では 400ms 後に復元しているが、
   その間にユーザーがコピーすると壊れる）。unicode 方式ならこの問題はない。ただし IME との相互作用が未検証
3. **開発フローのコスト**: アクセシビリティ権限を要求するアプリは、安定した署名 identity がないと
   ビルドのたびに権限が失効する（下記）。これは Kikimi 本体の開発体験に恒久的に影響する

**推奨**: unicode 方式を第一候補にする（クリップボードを踏まない）。ただし採用前に日本語 IME との
相互作用（E）を必ず確かめること。Pasteboard はフォールバックとして残す。

**ホットキーはユーザー設定可能にすること。** `⌥Space` は Raycast が CGEventTap で握っており、
Carbon hotkey より先に処理される。`RegisterEventHotKey` は成功してしまうので**エラーも出ず両方が発火した**
（ランチャが開くと同時に文字が入った）。既定値を決め打つと、この種の衝突が黙って起きる。

**API の戻り値を信じないこと。** `AXUIElementSetAttributeValue` は AXButton にすら `.success` を返す。
挿入結果は必ず読み返して検証する。この spike も readback を入れるまで誤った結論を出しかけた。
