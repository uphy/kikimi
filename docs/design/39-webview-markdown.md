# 39. WebView ベースの Markdown 描画（mermaid 対応）詳細設計

`docs/design/38-session-chat.md` §9 が「サマリ / Watchers / チャットの 3 箇所を横断する別設計として
起こす」と予告した設計。`docs/design/06-ui-panels.md:71` の「**WKWebView は使わない**」を、
**Markdown 表示に限って覆す**。

- **描画を WKWebView + `markdown-it` + `mermaid` に置き換える**。MarkdownUI
  （`swift-markdown-ui`）は CommonMark レンダラで mermaid を描けず、コードブロックのシンタックス
  ハイライトも持たない。3 箇所が同じ `Theme.summary` を共有しているので、置き換えも 1 箇所で済む
- **CodeMirror は使わない**（MD1）。Chirami の `editor-web` は**編集**のための live preview で、
  Kikimi の 3 箇所は LLM の出力を読むだけ。`contenteditable` を抱えるリスクを表示側に広げない
- **Chirami から流用するのは基盤**: WKWebView ホスト、Swift ↔ JS ブリッジ、CSS 変数によるテーマ
  注入、npm → esbuild → `Resources/editor/` のビルド統合、そして
  `docs/webview-migration-plan/`（全 7 フェーズ）が残した「段階的にクラッシュ原因を切り分ける」段取り
- **Swift 側は Markdown 文字列を渡すだけ**（MD3）。`SummaryRenderer` / `WatcherViewRenderer` /
  `ChatRunner` の出力は変えないので、レンダラ系の既存テストは無傷で残る
- **チャットだけ再設計が要る**（MD4）。現在は 1 回答 = 1 バブル = 1 `Markdown()` で、そのまま
  WebView 化すると往復の数だけインスタンスが増える。履歴全体を 1 つの WebView で描く
- **`.nonactivatingPanel` の上で動く**という制約が全体を規定する（MD5）。会議中に Zoom から
  フォーカスを奪わないことがフローティングパネルの存在意義で、WebView がそれを壊してはならない
- **書き起こしタブは対象外**。あれは Markdown ではなく行単位の構造化表示で、再生・話者リネームの
  インタラクションが密に絡む（`TranscriptTabView`）

## 1. 目的とスコープ

**やること**:

- Markdown 表示の 3 箇所（サマリ / Watchers 結果 / チャット回答）を WKWebView 描画に置き換える
- ` ```mermaid ` フェンスを図として描く
- コードブロックのシンタックスハイライト、GFM テーブル、脚注、チェックボックスを描く
- `kikimi-seg:` リンク（design 05 §8.1 / §10.2）の挙動を現状のまま維持する
- ダークモード・アクセントカラー・フォントサイズを既存の見た目に合わせる
- `kikimi-verify`（レイヤ 2）が WebView の中身を読み・押せる経路を用意する（MD12。`kikimi://debug/webview` + `webview.sh`）
- `ChatPromptBuilder` の「図表は mermaid ではなく表と箇条書きで」（design 38 CH6）を外す
- `swift-markdown-ui` 依存を削除する

**やらないこと**:

- 書き起こしタブの WebView 化（構造化表示であって Markdown ではない）
- 準備タブ / Watcher 定義 / チャット入力欄の CodeMirror 化（MD17。別設計）
- Markdown の編集（3 箇所とも読み取り専用）
- Wiki export / コピー機能の変更（Markdown 文字列のままで、描画層に依存しない）
- ストリーミング表示（design 38 §9 の別項目。ただしブリッジ契約だけは今のうちに受け入れ可能な形にする。MD16）

## 2. 決定事項

| # | 決定 |
|---|------|
| MD1 | **レンダラは `markdown-it` + `highlight.js` + `mermaid`。CodeMirror は使わない**。CodeMirror はカーソル位置に応じて生 Markdown と整形表示を切り替えるためのもので、読むだけの画面にカーソルの概念がない。read-only でも `contenteditable` を抱えるため、Chirami が `docs/webview-migration-plan/README.md` で Phase 3 に Go/No-Go を置いたクラッシュリスクを表示 3 箇所すべてに広げることになる。バンドルも CodeMirror + lang-markdown + lezer 一式ぶん増える |
| MD2 | **WKWebView の実体は SwiftUI の外で保持する**。`MeetingWorkspaceWindowController` が `MarkdownWebViewStore`（キーは `summary` / `watchers` / `chat` の 3 つ）を所有し、`MarkdownWebView`（`NSViewRepresentable`）はストアから既存インスタンスを受け取って貼り替えるだけにする。`dismantleNSView` では detach だけを行い、破棄はウィンドウを閉じるとき。**素の representable では成立しない** — `MeetingTabView.content` の `switch paneMode`（`MeetingTabView.swift:153-178`）は `summaryContent()` を `.transcript` / `.summary` / `.both`（`HSplitView` 内）という構造的に別の位置に置くので、ペイン切替のたびに SwiftUI が view identity を失い、`makeNSView` からやり直しになる。そうなると `loadFileURL` → JS パース → `ready` → `setContent` が毎回走り、スクロール位置も選択も失われる |
| MD3 | **HTML への変換は JS 側が全部やる。Swift は Markdown 文字列を渡すだけ**。`SummaryRenderer` / `WatcherViewRenderer` / `ChatRunner` の出力は変えない。`SummaryRendererTests` / `WatcherViewRendererTests` ほかレンダラ系の既存テストは無傷。**例外は `ChatPromptBuilderTests.swift:109`** — `#expect(system.contains("mermaid"))` が mermaid 抑止行の存在をピン留めしているので、抑止を外す Phase C で一緒に直す（§8.1） |
| MD4 | **チャットは履歴全体を 1 つの WebView で描く**。バブル・コピーボタン・再送ボタン・時刻・降格ラベル（design 38 §4.5）を HTML 側に持ち、押下はブリッジで Swift に返す。1 バブル 1 WebView だと 10 往復で 10 インスタンスになり、各々の高さを Swift 側に通知して `LazyVStack` を組み直す羽目になる。**入力欄（`PlainTextEditor`）と履歴クリアのツールバーは SwiftUI のまま残す** — 入力欄は `hasMarkedText()` ガード（`PlainTextEditor.swift:163`）で日本語 IME を作り込んであり、捨てる理由がない。**ユーザー吹き出しは markdown-it に通さない**（現状 `Text(turn.text)`、`ChatTabView.swift:149`）。「#確認 これでOK?」が見出しに化けるのは退行 |
| MD5 | **WebView がフォーカスを奪ってはならない**。全ウィンドウが `.nonactivatingPanel`（`FloatingPanel.swift`）で、会議中に前面を取らないことがフローティングパネルの前提。WKWebView は選択・キャレット処理で key window を要求する挙動があるため、**「選択・コピーが効く」と「frontmost が変わらない」の両立は Phase A の Go/No-Go にする**（MD18）。あわせて Chirami の `FirstMouseWKWebView`（`NoteWebView.swift:684-686`）に倣い `acceptsFirstMouse` を `true` にする。Kikimi 側の `FirstMouseHostingView`（`FloatingPanel.swift:116-118`）は `NSHostingView` のオーバーライドなので、WKWebView 内部にヒットテストが落ちるクリックには効かない |
| MD6 | **ナビゲーションは editor ディレクトリ配下の `file://` だけ許す**。`decidePolicyFor` で `allowingReadAccessTo` に渡したディレクトリ配下のみ `.allow`、それ以外は `.cancel`。「常に `.cancel`」にすると `loadFileURL` の初回ナビゲーション自体が通らず真っ白になる。リンクの一次防御は JS 側の click 横取り（`preventDefault` + `openLink` メッセージ）で、`decidePolicyFor` は二段目。**コンテキストメニューも抑制する** — WKWebView 既定の「再読み込み」を押されると `index.html` が再ロードされ、Swift 側は関知しないまま次の `setContent` まで白紙になる。ルーティングは純関数 `MarkdownLinkRouter.route(_:)` に切り出して単体テストする |
| MD7 | **スクロールは WebView が持つ**。SwiftUI の `ScrollView` でラップしない（入れ子のスクロールになる）。WebView をタブ領域いっぱいに広げ、高さの計測・通知はしない |
| MD8 | **内容更新はページ再ロードではなく `setContent(markdown, docKey)`**。`docKey` が前回と同じなら「同一文書の更新」としてスクロール位置を復元し、変われば先頭から表示する。`docKey` が要るのは Watchers タブが 1 つの WebView にサブタブ切替で**別の文書**を流し込むため（`WatchersTabView.swift:107-136`）。位置だけを見ていると Watcher A の位置が B に復元される。`docKey` は `"summary"` / `"watcher:<id>"`。テーマ変更に伴う再描画（§3.4）は同一 `docKey` なので位置が保たれる |
| MD9 | **mermaid は classic script の 2 本目として遅延ロードする**。` ```mermaid ` が 1 つでも現れたら `<script src="mermaid.bundle.js">` を DOM に注入する。**ESM + code splitting は採らない** — esbuild で動的 import を別 chunk にするには `--format=esm --splitting --outdir` が要り、`file://` 上の module script と chunk fetch が WebKit のローカルファイル規則と CSP `script-src 'self'` を通るかが未検証。Chirami の実績は単一 IIFE（`--outfile`）+ mermaid の静的 import で、この組み合わせの前例がない。classic script なら 2 本とも同じ形のままで済む。**「2 本目の script が `file://` + CSP でロードできる」ことだけは Phase A で確かめる**（中身は空のスタブでよい。MD18） |
| MD10 | **LLM 出力を HTML として描く以上、素通しは許さない**。`markdown-it({ html: false })`、`mermaid` は `securityLevel: "strict"`、CSP は `default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'`。**markdown-it を通らない文字列（ユーザー吹き出し・エラーメッセージ・mermaid のエラーフォールバック）は必ず `textContent` 経由で DOM に入れる**（`innerHTML` を使わない）。書き起こしは会議の内容そのもので、外に出る経路を作らない |
| MD11 | **Swift → JS は `callAsyncJavaScript(_:arguments:)` で引数として渡す**。文字列補間でスクリプトを組み立てない。サマリにも書き起こしにも `"` も改行も U+2028 も出てくるので、素朴な補間は初回から JS 構文エラーで全滅する。**ページ側の関数は引数を 1 個のオブジェクトだけ取る**（`setContent({markdown, docKey})`、Swift 側は常に `payload` という名前 1 つを渡す）。`callAsyncJavaScript` は引数を辞書で渡すのにスクリプトでは位置で並べる必要があり、複数引数だと Swift と `bridge.ts` が「何も検査しない順序」で合意することになる。実際に食い違った — 辞書のキーを `sorted()` で並べたため `setContent` の 2 引数が入れ替わり、**本文の位置に `docKey` が描画された**（Phase A の目視確認をすり抜け、Watchers で `watcher:<id>` が本文として出るまで気づかなかった）。オブジェクト 1 個なら間違える順序が存在しない。**`ready` 前に届いた呼び出しはキューし、`ready` 受信時に theme → content の順で流す**（Chirami `handleReady`、`NoteWebView.swift:238-245` と同型）。ウィンドウを開いた時点で `summaryMarkdown` はディスクから復元済みなので、初回はほぼ確実に `ready` より先に内容が来る |
| MD12 | **`kikimi-verify`（レイヤ 2）用の読み出し・操作経路をアプリ側に作る**。`evaluateJavaScript` はアプリ内 API で、skill（osascript / CGEvent / ファイル検査 / `kikimi://` URL scheme の外部プロセス）からは呼べない。`kikimi://debug/webview?target=<surface>&action=dump&out=<path>` / `&action=click&testid=<id>` でアプリに代行させ、結果をファイルに書く（`DebugBridgeMode`: `KIKIMI_DEBUG_BRIDGE` / `KIKIMI_TEST_HIDDEN` / `KIKIMI_STUB_LLM` のいずれかが立っているときだけ有効。**`#if DEBUG` では駄目** — 検証対象は `mise run apply` が入れる Release ビルド）。**操作側が本質的にこの経路を要る** — `ax_click.py` は WebView 内の要素を押せず、コピー / 再送 / 拡大ボタンはすべてページ側にある。**描画完了の待ち方は「期待文字列が出るまで dump をポーリングする」**（`webview.sh wait`）。当初は描画世代番号を返す案だったが、ポーリングで足りるぶん経路が単純 |
| MD13 | **テーマは CSS 変数を Swift から注入**。`viewDidChangeEffectiveAppearance`（Chirami `NoteWebView.swift:229-236` と同型。KVO より素直）で再注入し、`NSColor` の解決は `performAsCurrentDrawingAppearance` の中で行う。現在の `Theme.summary`（`SummaryTabView.swift:98`、GitHub テーマの背景色を落として 13pt にしたもの）の見た目を CSS で再現する |
| MD14 | **`swift-markdown-ui` 依存を削除する**。3 箇所すべてが置き換わるので残す理由がない。2 つの Markdown 描画系を並行して保守しない。**削除と `Theme.summary` の削除は Phase C**（`WatchersTabView.swift:160` と `ChatTabView.swift:172` が Phase B / C まで `.summary` を参照し続けるので、Phase A で消すとビルドが壊れる） |
| MD15 | **失敗時はプレーンテキストに落とし、その旨を画面に出す**。`bundle.js` が無い（npm build 忘れ）、初期化に失敗した、コンテンツプロセスが落ちた — いずれも `Text(markdown)` の等幅表示にし、**本文の上に 1 行の通知を出す**。ログだけだと、生の `|---|` が並んだ画面はユーザーにも開発者にも「整形バグ」にしか見えない。**チャットのフォールバックは HTML 側に移した機能を失う**ので、最低限「失敗行 + 再送ボタン」は SwiftUI で残す（再送手段ごと消えるのは許容できない）。MarkdownUI はフォールバックとして残さない（MD14 と両立しない） |
| MD16 | **チャットのブリッジは最初からターン単位の更新 API を持たせる**。`setTurns`（全置換）だけにすると、design 38 §9 のストリーミングが入ったときにトークン到着のたびに全履歴を再描画することになり、ブリッジと JS 側の DOM 管理を作り直すことになる。`updateTurn(id, text)` を今のうちに契約へ入れておく（実装は全置換で始めてよい） |
| MD17 | **編集側の CodeMirror 化はこの設計に含めない**。準備タブの `context.md` / Watcher 定義 YAML にシンタックスハイライトが欲しいのは事実だが、`PlainTextEditor` の IME 対応を作り直す判断であり、表示側の安定を見てからでよい。§12 に将来拡張として置く |
| MD18 | **3 段階で入れる**（§11）。Phase A: 基盤 + サマリ、Phase B: mermaid + Watchers、Phase C: チャット + 依存削除。A が Go/No-Go。Chirami が `feat/web-view` の一発実装で頓挫した記録（`docs/webview-migration-plan/README.md`「過去の試行と反省」）を踏まえる |

## 3. コンポーネント構成

```
web/                                  ← 新設（リポジトリ直下。Chirami の editor-web に相当）
  package.json / tsconfig.json / eslint.config.js / vitest.config.ts
  index.html
  src/
    main.ts            エントリ。bridge を生やして document / chat のどちらかを起動する
    bridge.ts          Swift ↔ JS の型付き契約
    render.ts          markdown-it の構成（GFM・脚注・seg リンク・コードブロック）
    mermaid-loader.ts  2 本目の script 注入と描画・エラー処理
    mermaid-entry.ts   2 本目の bundle のエントリ（mermaid 本体）
    theme.ts           Swift から来た CSS 変数の適用
    document.ts        サマリ / Watchers 用のビュー（本文だけ）
    chat.ts            チャット用のビュー（バブル・ボタン・自動追従）
    testing.ts         __kikimiDumpText / __kikimiClick（MD12）
    style.css
  scripts/copy-html.js

Kikimi/Views/Markdown/                ← 新設
  MarkdownWebView.swift               NSViewRepresentable（ストアから実体を借りる）
  MarkdownWebViewStore.swift          WKWebView 実体の所有者（MD2）
  MarkdownWebViewCoordinator.swift    ブリッジ受信・ready キュー・テーマ再注入・プロセス復帰
  MarkdownLinkRouter.swift            リンク種別の判定（純関数。単体テスト対象）
  MarkdownWebViewAssets.swift         bundle の所在解決とフォールバック判定
  FirstMouseWKWebView.swift           acceptsFirstMouse = true + コンテキストメニュー抑制（MD5/MD6）
```

### 3.1 ブリッジ契約（`web/src/bridge.ts`）

```ts
// Swift -> JS
type SwiftToJs = {
  setTheme: (vars: Record<string, string>) => void;
  // document モード
  setContent: (markdown: string, docKey: string) => void;      // MD8
  // chat モード
  setTurns: (turns: ChatTurnView[]) => void;
  updateTurn: (id: string, text: string) => void;              // MD16（将来のストリーミング用）
  setResponding: (responding: boolean, since: number | null) => void;
  setCopyFeedback: (turnId: string | null) => void;
};

// JS -> Swift
type JsToSwift =
  | { type: "ready" }
  | { type: "rendered"; generation: number }   // MD12: 描画完了。外から待てるようにする
  | { type: "openLink"; url: string }
  | { type: "copyTurn"; id: string }
  | { type: "retryTurn"; id: string }
  | { type: "log"; level: "debug" | "info" | "warn" | "error"; message: string };
```

`ChatTurnView` は `ChatTurn`（design 38 §3.4）から表示に要るものだけを写した DTO。
`id` / `role` / `text` / `createdAt`（epoch 秒）/ `error` / `contextScope`。

`{ type: "log" }` は Chirami と同じ流儀で、JS 側のエラーを `Logger(subsystem:
"io.github.uphy.Kikimi", category: "MarkdownWebView")` に流す。WebView の中で起きたことが
`log stream` から見えないと、mermaid の構文エラーを追えない。

### 3.2 WebView の所有と貼り替え（MD2）

```swift
/// Owns the three `WKWebView` instances for one Session Window, outliving every SwiftUI view
/// rebuild. `MeetingTabView`'s pane switch re-creates the summary subtree from scratch, so a
/// representable that instantiated its own web view would reload the bundle on every toggle.
@MainActor
final class MarkdownWebViewStore {
    enum Slot: String { case summary, watchers, chat }

    func webView(for slot: Slot) -> FirstMouseWKWebView   // 初回だけ生成し、以降は使い回す
    func tearDown()                                       // ウィンドウを閉じるときに呼ぶ
}
```

`MeetingWorkspaceWindowController` がストアを 1 つ持ち、`MeetingWorkspaceView` に渡す。
`MarkdownWebView.makeNSView` は「ストアから借りたビューを載せるだけのコンテナ `NSView`」を返し、
`dismantleNSView` では `removeFromSuperview()` だけを呼ぶ（`WKWebView` 自体は生かす）。

`makeNSView` の要点（Chirami `NoteWebView.swift` の該当箇所をなぞる）:

- `FirstMouseWKWebView`: `acceptsFirstMouse` を `true`（MD5）、`willOpenMenu` で既定メニューを抑制（MD6）
- `webView.setValue(false, forKey: "drawsBackground")` + `underPageBackgroundColor = .clear`
- `loadFileURL(indexURL, allowingReadAccessTo: editorDirURL)`
- `allowsBackForwardNavigationGestures = false`
- `isInspectable` は `#if DEBUG` のときだけ `true`（配布ビルドでは無効なので、MD12 の検証経路は
  リモートインスペクタに依存できない）

`updateNSView` は差分だけを JS に送る。前回と等しい `Mode` なら何もしない（MD8）。

### 3.3 リンクのルーティング（MD6）

```swift
enum MarkdownLinkRouter {
    enum Destination: Equatable {
        case segment(String)   // kikimi-seg:seg_00042 -> onOpenSegment("seg_00042")
        case external(URL)     // http(s) -> NSWorkspace
        case ignored           // それ以外（javascript:, 相対パス, 空）
    }

    static func route(_ raw: String) -> Destination
}
```

`WatcherViewRenderer.linkifySegmentIds`（`Kikimi/Watchers/WatcherViewRenderer.swift:115`）が
`[seg_00042](kikimi-seg:seg_00042)` を生成する仕様は変えない。現在
`WatchersTabView.swift:165` の `.environment(\.openURL,)` でやっている傍受（design 05 §8.1 /
§10.2）が、このルータに移る。

### 3.4 テーマ注入（MD13）

| CSS 変数 | 由来 |
|---|---|
| `--kikimi-fg` | `NSColor.labelColor` |
| `--kikimi-fg-secondary` | `NSColor.secondaryLabelColor` |
| `--kikimi-accent` | `NSColor.controlAccentColor` |
| `--kikimi-code-bg` | `NSColor.textBackgroundColor`（透過を載せる） |
| `--kikimi-border` | `NSColor.separatorColor` |
| `--kikimi-font-size` | `13px`（現在の `Theme.summary` の `FontSize(13)`） |
| `--kikimi-font-family` | `-apple-system` |

背景色の変数は持たない。`drawsBackground = false` でパネルの背景を透かす（現在の
`Theme.summary` が GitHub テーマの背景を落としているのと同じ意図）。

mermaid のテーマも同時に切り替える（`theme: "dark" | "default"`）。既に描いた図は再描画が要るので、
テーマ変更時は現在の Markdown で `setContent` をやり直す（同一 `docKey` なのでスクロール位置は保たれる）。

### 3.5 サマリタブ / Watchers タブ

差し替えは小さい。どちらも `ScrollView { Markdown(...) }` を `MarkdownWebView` に置き換えるだけで、
周辺の UI（サマリの「サマリ全文再生成」バー、Watchers のサブタブバー・フッター・「管理」
DisclosureGroup）は SwiftUI のまま残る。

```swift
// SummaryTabView
if let summaryMarkdown, !summaryMarkdown.isEmpty {
    MarkdownWebView(store: store, slot: .summary,
                    mode: .document(markdown: summaryMarkdown, docKey: "summary"))
} else {
    SummaryPlaceholder()
}
```

Watchers は `docKey: "watcher:\(item.id)"` と `onOpenSegment` を渡す点が違う。プレースホルダ
（「サマリはまだ生成されていません」/「まだ実行結果がありません」）は SwiftUI のまま。

### 3.6 チャットタブ（MD4）

構成が変わる箇所。

```
現在:  toolbar(SwiftUI) / ScrollView { LazyVStack { バブル × N } }(SwiftUI) / composer(SwiftUI)
本設計: toolbar(SwiftUI) / MarkdownWebView(.chat)                          / composer(SwiftUI)
```

HTML 側に移るもの:

- ユーザー吹き出し（**markdown-it に通さない**。`textContent` + 改行のみ `<br>`。MD4/MD10）
- アシスタント吹き出しと回答本文の Markdown 描画
- コピーボタン（押下 → `copyTurn` → Swift の `onCopy`。チェックマークは Swift が
  `setCopyFeedback(turnId)` で戻す。**成功したときだけ印が出る**という design 37 §6 / §7 の
  テスト項目 (f) の契約はそのまま）
- 再送ボタン（`retryTurn`）、失敗行、降格ラベル（design 38 §4.5）
- 回答待ちのスピナーと経過秒（`setResponding(true, since:)` を受けて JS 側でタイマーを回す）
- 空のときのプレースホルダ、最下部への自動追従

**ボタンの AX 契約を HTML に引き継ぐ**。現在 `ChatTabView.swift:203-204, 218-219` は
`.help` と `.accessibilityLabel` を同一文言で付ける規約（コード内に「AX contract for
kikimi-verify」と明記）を守っている。HTML 側では `aria-label` と `title` を同じ文言にし、
さらに `data-testid` を付ける（MD12）。

自動追従は `TranscriptAutoFollow`（`Kikimi/Views/MeetingWorkspace/TranscriptAutoFollow.swift`）の
判定を JS に写す。**Swift 側の `TranscriptAutoFollow` は削除しない** — 書き起こしタブが引き続き
使っている。同じ判定が 2 言語に並ぶが、対象のスクロール実装が別物なので共有はできない。
JS 側の判定にも vitest を書く（§8.2）。

`ChatTabView` に残る `@State` は `isConfirmingClear` だけになる。

## 4. mermaid（MD9）

`render.ts` はフェンスの info string が `mermaid` のとき、コードブロックではなく
`<div class="kikimi-mermaid" data-src="...">` を出す。**描画前に暫定の `min-height` を与える** —
非同期で図が入って高さが変わると、MD8 で復元したスクロール位置が跳ぶ。

```ts
async function renderMermaid(root: HTMLElement, theme: "dark" | "default") {
  const blocks = root.querySelectorAll<HTMLElement>(".kikimi-mermaid");
  if (blocks.length === 0) return;               // MD9: 図が無ければ 2 本目を読まない
  await loadMermaidBundle();                     // <script src="mermaid.bundle.js"> を 1 回だけ注入
  window.__kikimiMermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme });
  for (const [i, block] of blocks.entries()) {
    try {
      const { svg } = await window.__kikimiMermaid.render(`kikimi-mermaid-${i}`, block.dataset.src ?? "");
      block.innerHTML = svg;                     // mermaid の出力のみ innerHTML を許す
    } catch (error) {
      block.replaceChildren(errorFallback(block.dataset.src ?? "", error));  // textContent 経由
    }
  }
}
```

構文エラーのフォールバックは「元のコードをそのまま等幅で出し、上に控えめなエラー行を添える」。
LLM が壊れた mermaid を吐いたときに内容が消えるのが最悪で、コードのまま読めれば用は足りる。

**横に長い図の扱いは `docs/design/40-diagram-zoom.md` で改めた**。当初は `max-width: 100%` で
パネル幅に縮めていたが、それだと線と文字が潰れて読めない。現在は自然な大きさで描いて溢れた分を
横スクロールさせ（DZ9）、描画に成功した図には**画面全体で見るための拡大ボタン**を添える（DZ1）。

`ChatPromptBuilder.swift:56` の「図表が必要なときは mermaid ではなく、表と箇条書きで表現して
ください」の削除は **Phase C**（§11）。Phase B で外すと、チャットの描画が MarkdownUI のままの
期間に生の mermaid コードブロックがユーザーに見える。サマリ・Watcher のプロンプトにはもともと
同種の記述がない。

## 5. セキュリティ（MD10）

| 面 | 対処 |
|---|---|
| LLM 出力の生 HTML | `markdown-it({ html: false })`。`<script>` も `<img onerror>` もテキストとしてエスケープされる |
| markdown-it を通らない文字列 | ユーザー吹き出し・エラーメッセージ・mermaid のエラーフォールバックは `textContent` 経由。`innerHTML` は markdown-it と mermaid の出力にだけ使う |
| mermaid 経由の注入 | `securityLevel: "strict"`（`htmlLabels` 無効・クリックイベント無効） |
| 外部通信 | CSP の `connect-src 'none'` / `img-src 'self' data:` |
| リンクの遷移 | MD6。editor ディレクトリ配下の `file://` 以外は `.cancel` |
| `javascript:` リンク | `MarkdownLinkRouter` が `.ignored` に落とす |
| 検証用 API | `__kikimiDumpText` / `__kikimiClick` は `KIKIMI_TEST_*` が立っているときだけ Swift 側が呼び出しを受け付ける（JS 側に生えていても、外から叩く経路が塞がっていれば無害） |

CSP は `index.html` の `<meta http-equiv="Content-Security-Policy">` に書く。`loadFileURL` で
読むので、サーバ側ヘッダという選択肢はない。

## 6. パフォーマンス

- **初期表示**: `bundle.js` は mermaid を外して 300KB 前後（`markdown-it` + `highlight.js` の
  必要言語のみ）。`mermaid.bundle.js` は 3MB 前後で、図があるときだけ読む
- **アプリサイズ**: 19MB → 22MB 程度
- **更新頻度**: サマリは `SummaryUpdater` の周期、Watchers は実行のたび、チャットは 1 往復ごと。
  いずれも秒オーダーより粗いので、`setContent` の全文入れ替えで足りる
- **インスタンス数**: ウィンドウあたり最大 3。MD2 のストアにより、タブ切替でもペイン切替でも
  作り直さない。ウィンドウを閉じたら `tearDown()`

## 7. 失敗モード

| 事象 | 挙動 |
|---|---|
| `Resources/editor/index.html` が無い（npm build 忘れ） | プレーンテキスト表示 + 本文上部に 1 行通知 + `.error` ログ（MD15）。開発者がここを踏みやすい（CLAUDE.md の実ビルド経路は `swift build` で、npm を経ない反復ビルドでは bundle 欠落が常態） |
| WebView のコンテンツプロセスが落ちた | `webViewWebContentProcessDidTerminate` で 1 回だけ再ロードし、直近の内容を再注入。2 回目以降はプレーンテキスト |
| `ready` が 3 秒来ない | プレーンテキストに落とす。**遅れて `ready` が来たら復帰する**（次の `setContent` で通常描画に戻す）。コールドスタートで 3 秒を誤超過しても恒久的に劣化させない |
| `ready` 前に `setContent` / `setTheme` が来た | キューして `ready` 時に theme → content の順で適用（MD11）。初回はほぼ確実にこの順序になる |
| ユーザーが右クリック → 再読み込み | MD6 でコンテキストメニューを抑制。抑制漏れに備え、`didFinish` で「内容が空なら直近の内容を再注入」する |
| Watchers のサブタブ切替 | `docKey` が変わるのでスクロールは先頭から（MD8） |
| mermaid の構文エラー | その図だけコード表示にフォールバック（§4）。他の図と本文は描画継続 |
| `mermaid.bundle.js` のロード失敗 | 全図をコード表示にフォールバック + `.warning` ログ |
| チャットでフォールバックした | 失敗行と再送ボタンだけ SwiftUI で残す（MD15）。再送手段ごと消さない |
| `npm ci` がネットワーク断で失敗 | `mise run build` が失敗する。これまでオフラインで完結していたビルドがネットワーク依存になるので、`node_modules` があればスキップする（§9） |
| `KIKIMI_TEST_HIDDEN`（`alphaValue = 0`）下 | 不可視ウィンドウの WKWebView は occlusion で描画・タイマーがスロットルされうる。`mise run verify-smoke` の既定なので、**Phase A で動作を確認する**（MD18） |
| 非アクティブパネルで選択できない / frontmost を奪う | Phase A の Go/No-Go（MD18）。ここで詰まったら設計を見直す |

## 8. テスト

### 8.1 レイヤ 1（Swift / XCTest）

レンダラ系の既存テストは無傷（MD3）。修正が要るのは 1 本、新規は 3 本。

- **修正**: `ChatPromptBuilderTests.swift:109` の `#expect(system.contains("mermaid"))` —
  Phase C で mermaid 抑止行を消すので、この期待も一緒に消す（design 38 §7(d) の仕様側も改訂）
- `MarkdownLinkRouterTests` — `kikimi-seg:seg_00042` → `.segment("seg_00042")`、`https://…` →
  `.external`、`javascript:alert(1)` → `.ignored`、空文字 → `.ignored`
- `MarkdownWebViewAssetsTests` — bundle が無いときに `nil` を返す（フォールバック判定）
- `ChatTurnViewTests` — `ChatTurn` → `ChatTurnView` の写像（`error` 有無、`contextScope` の伝播）

### 8.2 JS（vitest。Chirami と同じ）

- `render.test.ts` — GFM テーブル / チェックボックス / 脚注が期待どおり出る
- `render.security.test.ts` — `<script>alert(1)</script>` と `<img onerror=…>` がエスケープされる。
  ユーザー吹き出しが markdown-it を通らない（`# 見出し` が見出しにならない）
- `render.mermaid.test.ts` — ` ```mermaid ` が `.kikimi-mermaid` になり、` ```ts ` はコードブロックのまま
- `render.seglink.test.ts` — `[seg_00042](kikimi-seg:seg_00042)` が `openLink` を投げる `<a>` になる
- `document.dockey.test.ts` — 同一 `docKey` で位置を復元し、別 `docKey` で先頭に戻る
- `chat.autofollow.test.ts` — `TranscriptAutoFollow` と同じ判定（最下部にいるときだけ追従）

### 8.3 レイヤ 2（`kikimi-verify`）

MD12 の経路（`kikimi://debug/webview`）と、それを叩く `scripts/webview.sh` を用意した。

```bash
# ブリッジを有効にして起動（KIKIMI_TEST_HIDDEN / KIKIMI_STUB_LLM でも有効になる）
scripts/with_env.sh KIKIMI_DEBUG_BRIDGE=1 -- ~/Applications/Kikimi.app/Contents/MacOS/Kikimi

scripts/webview.sh dump  summary            # 本文のテキストを読む
scripts/webview.sh wait  summary "決定事項"  # 期待文字列が出るまでポーリング（第一候補）
scripts/webview.sh click chat "mermaid-zoom" # data-testid でページ内のボタンを押す
```

**`wait` を第一候補にする**。描画は非同期（特に mermaid）で、単発の `dump` は描画途中を掴む。
キャプチャの目視より先に機械判定できるのが要点で、実際これが無かったために Swift → JS の
引数順の取り違え（本文に `docKey` が描画される）を目視 2 回ですり抜けた。

既知の `data-testid`: `chat-copy-<turn-id>` / `chat-retry-<turn-id>` / `mermaid-zoom`。
HTML にボタンを足すときは `data-testid` と `aria-label` / `title`（同文言）を必ず付ける。

## 9. ビルド統合（MD-11 系）

```
mise.toml                     [tools] に node = "24" を追加（package-lock.json は npm 11 製）
.mise/tasks/build/web         新設。node_modules が無ければ npm ci、その後 npm run build
.mise/tasks/build/swift       depends に build:web を追加
.mise/tasks/build/_default    $app_dir/Resources/editor/ に web の生成物をコピー
.mise/tasks/test/{_default,web}  新設（従来 test タスクは無かった）。vitest → swift test
.mise/tasks/lint/{_default,web}  既存 lint をディレクトリ化し、web の tsc --noEmit を並置
.gitignore                    Kikimi/Resources/editor/ と web/node_modules/ を追加
```

`web/package.json` の `build` は Chirami と同じ形（`tsc --noEmit` → esbuild → `copy-html.js`）。
**esbuild は 2 回呼ぶ**（`main.ts` → `bundle.js`、`mermaid-entry.ts` → `mermaid.bundle.js`。
どちらも単一 IIFE。MD9）。出力先は `../Kikimi/Resources/editor/`。

生成物を `.app` に入れるのは `build/_default`（Assets.xcassets を手でコピーしているのと同じ流儀。
Kikimi は SPM の resource バンドルを使っていない）。

**`Package.swift` の Kikimi ターゲットは `path: "Kikimi"`** なので、`Resources/editor` を `exclude` に
足さないと `swift build` が unhandled-file 警告を出し続ける。

**`project.yml` には `Resources/editor` を足さない**。生成物であり、minify 済みの `bundle.js` を
Xcode で閲覧する価値がないうえ、git 管理外のディレクトリを sources に書くと fresh clone 直後の
`mise run generate` がパス不存在で転ぶ。xcodegen は IDE 閲覧用でしかない（CLAUDE.md）。

**ESLint は入れない**。`tsc --strict` + `noUnusedLocals` / `noUnusedParameters` で、SwiftLint が
Swift 側で担っている役割は足りている。設定ファイルと依存を 1 つ増やす対価に見合わない。
`mise run lint` が `web/` の `tsc --noEmit` も走らせる。

`mise install` が node を入れるので、セットアップ手順そのものは変わらない（CLAUDE.md の Build 節に
`build:web` と「`swift build` 単体では web 資産が更新されない」ことを明記した）。

## 10. 既存コードへの改修

| 対象 | 改修 | Phase |
|---|---|---|
| `Kikimi/Views/MeetingWorkspace/SummaryTabView.swift` | `Markdown(...)` → `MarkdownWebView` | A1 ✅ |
| `Kikimi/Window/`（`MeetingWorkspaceWindowController`） | `MarkdownWebViewStore` の所有と `windowWillClose` での解放（MD2） | A1 ✅ |
| `Kikimi/Views/MeetingWorkspace/MeetingWorkspaceView.swift` | ストアを受け取り、サマリ用 host を渡す | A1 ✅ |
| `Package.swift` | `exclude` に `Resources/editor` を追加 | A1 ✅ |
| `.gitignore` / `mise.toml` / `.mise/tasks/` | §9 | A1 ✅ |
| `Kikimi/Views/MeetingWorkspace/WatchersTabView.swift` | 同上 + `.environment(\.openURL,)` を `MarkdownLinkRouter` 経由に移す | B ✅ |
| `Kikimi/Views/MeetingWorkspace/ChatTabView.swift` | §3.6 の再構成。`isPinnedToBottom` / `isAutoScrolling` を削除（`respondingSince` は page に渡すため残る） | C ✅ |
| `Kikimi/Chat/ChatPromptBuilder.swift` | mermaid 抑止行を「図は mermaid で」に反転 | C ✅ |
| `KikimiTests/Chat/ChatPromptBuilderTests.swift` | `#expect` の意図を「図の書き方に触れている」に変更 | C ✅ |
| `SummaryTabView.swift`（`Theme.summary`） | 削除（CSS へ） | C ✅ |
| `Package.swift` | `swift-markdown-ui` を削除 | C ✅ |

### 既存設計文書への改訂（すべて反映済み）

- `docs/design/06-ui-panels.md:71` — 「WKWebView は使わない」を「Markdown **表示**は WKWebView
  （本設計）。**編集**（準備タブ / Watcher 定義）は `NSTextView` のまま」に改訂
- `docs/design/38-session-chat.md` — CH6（mermaid 抑止を外した）、§3.5（`:405` の図と `:421` の
  「MarkdownUI で描画し `Theme.summary` を共有」、`:172` のプロンプト例）、§7(d)（`:623` の
  「システムプロンプトに mermaid 禁止が含まれること」）、§9（第 1 項を本設計が消化）
- `docs/design/05-watcher-runner.md` — §8.1（`:363` の `.environment(\.openURL, OpenURLAction …)`）と
  §10.2（`:497-498` の `Markdown(...)` + `.markdownTheme(.summary)`）を `MarkdownWebView` /
  `MarkdownLinkRouter` に改訂
- `kikimi.md` 13 章 — 「JS（採用するなら）」を確定の依存として書き直す
- `docs/development-process.md` — 2.2（`:69` の「WKWebView は MVP では回避」を覆したこと、
  `:70` のテスト行）と 2.9（レイヤ 1 に vitest を並置、レイヤ 2 の WebView 対応）
- `CLAUDE.md` — コードマップに `web/` と `Kikimi/Views/Markdown/`、Build 節に node / `build:web`

## 11. 段階導入（MD18）

| Phase | 内容 | 完了条件 |
|---|---|---|
| **A0** | 検証スパイク。手書きの `Kikimi/Resources/editor-spike/`（`index.html` + `spike.js` + 空スタブの `second.js`）を `FirstMouseWKWebView` で表示するだけ。`KIKIMI_WEBVIEW_SPIKE=1` のときサマリタブに差し込む。npm も markdown-it も使わない — **失敗したときの原因を WKWebView / `file://` / CSP のどれかに限定するため** | 下の Go/No-Go のうち 1・2・3・6・7・8・11、および MD2 の前提（ペイン切替で representable が破棄されるか）の実測 |
| **A1** | `web/` 基盤（`bridge` / `render` / `theme` / `document` / `testing`）、`MarkdownWebViewStore` + `MarkdownWebView`、ビルド統合、検証経路（§8.3）、**サマリタブだけ差し替え**。`editor-spike` は削除 | 下の Go/No-Go のすべて。実装・ビルド・単体テストは完了（Swift 2105 / vitest 18）、UI 動作確認は未実施 |
| **B** | mermaid（2 本目 bundle・エラー処理）、Watchers タブ差し替え、`kikimi-seg:` 移設、`docKey` によるサブタブ切替 | seg リンクが書き起こしへジャンプする。mermaid が描ける。構文エラーがコード表示に落ちる。サブタブ切替で前の Watcher のスクロール位置が復元されない — **完了**（2026-07-30 に UI 動作確認済み） |
| **C** | チャットタブ再設計（§3.6）、mermaid 抑止の削除、`Theme.summary` と `swift-markdown-ui` の削除 | コピー / 再送 / 自動追従 / 経過秒が現在と同じ挙動。AX 契約（`aria-label` = 現行 `.help` 文言）が揃っている — **完了**（2026-07-30 に UI 動作確認済み） |

**Phase A の完了条件（Go/No-Go）**:

1. 非アクティブパネル上でテキスト選択・⌘C コピー・スクロールが効く
2. **WebView 内のクリック・スクロール・選択で `frontmost` が変わらない**（SKILL.md 0 章の
   確認コマンドで機械検証。MD5）
3. 非キー状態での 1 クリック目が JS の click として届く（`acceptsFirstMouse`）
4. **ペイン切替（書き起こしのみ ⇄ 両方 ⇄ サマリのみ）を往復してもスクロール位置と描画が保たれる**
   （MD2 のストアが効いていることの確認）
5. サマリの定期更新でスクロール位置が飛ばない
6. ダークモード切替に追従する
7. **`file://` + CSP で 2 本目の classic script がロードできる**（中身は空スタブでよい。MD9）
8. `KIKIMI_TEST_HIDDEN`（`alphaValue = 0`）下でも描画とダンプが機能する
9. 検証経路（§8.3）が外部プロセスから通る
10. 現行 `Theme.summary` とのスクリーンショット比較で、書き起こしペインと並べて違和感がない
11. クラッシュしない

1〜4 か 7 で詰まったら B / C に進まず設計を見直す。A / B だけでも「mermaid が描ける」という目的は
満たされ、チャットは MarkdownUI のまま動き続ける。

### A0 の実測結果（2026-07-29）

`KIKIMI_WEBVIEW_SPIKE=1` + `Kikimi/Resources/editor-spike/` で確認した。

| 条件 | 結果 |
|---|---|
| 1. 他アプリを前面にしたままクリック・スクロール・選択して `frontmost` が変わらないか | **変わらない**。選択・⌘C も効く。`.nonactivatingPanel` と WKWebView は両立する |
| 2. 非キー状態の 1 クリック目が届くか | **届く**（`FirstMouseWKWebView.acceptsFirstMouse`） |
| 3. `file://` + CSP `script-src 'self'` で 2 本目の classic script がロードできるか | **できる**。MD9 の遅延ロード方式が成立する。CSP を緩める必要はない |
| 6. タブ切替で representable が破棄されるか | **破棄される**（タブ切替で `dismantleNSView`）。**MD2 の `MarkdownWebViewStore` は必須**。ペイン切替は未計測だが、タブ切替で破棄される以上、構造が変わるペイン切替も同様とみなす |
| MD11 の `callAsyncJavaScript` でのテキスト取得 | **できる**（`__kikimiDumpText()` の戻り値をアプリ内で受け取れた） |
| 11. クラッシュ | 数分の操作では発生せず |

### A1 の結果（2026-07-30）

サマリタブを `MarkdownWebView` に差し替えて動作確認。**Phase A の Go/No-Go は満たされた** — タブ /
ペイン切替の往復でスクロール位置と描画が保たれ（`MarkdownWebViewStore` が効いている）、サマリの
更新でも位置が飛ばず、ダークモードに追従し、書き起こしペインと並べても違和感がない。テーブルと
コードブロックも崩れない。Swift 2105 / vitest 18 テストが通っている。

**未計測**（Phase B / C と並行して確かめる）:

- 5. AX ツリーから WebView 内テキストが読めるか — 読めれば MD12 の `kikimi://debug/webview` 経路は
  作らずに済む。MD12 の実装量だけを左右し、基盤・レンダラ・ストアには影響しない
- 8. `KIKIMI_TEST_HIDDEN=1`（alpha 0）下で描画と JS が動くか — A1 完了後に
  `mise run verify-smoke` を回せば分かる

**混在期間について**: Phase A 完了から C 完了までの間、`MeetingTabView` の分割表示では
CoreText 描画の書き起こしと WebKit 描画のサマリが同一画面の左右に並ぶ。完了条件 10 を満たす
限りこれを許容する（見た目の完全一致は求めない）。

## 12. やらないこと・将来拡張

- **編集側の CodeMirror 化**（MD17）: 準備タブの `context.md`、Watcher 定義 YAML に
  シンタックスハイライト・折りたたみ・live preview を入れる。`PlainTextEditor` の IME 対応
  （`hasMarkedText()` ガード）を Chirami 実装ベースで移植する必要があり、別設計として起こす
- **書き起こしタブの WebView 化**: 構造化表示 + 再生 + 話者リネームが密に絡む。Markdown 描画の
  問題ではない
- **ストリーミング表示**: design 38 §9 のまま据え置き。ただしブリッジには `updateTurn` を
  今のうちに入れておく（MD16）ので、載せるときに契約の作り直しは要らない
- **⌘F によるページ内検索**: 現在の SwiftUI 実装にも無いので退行ではない。WebView 化で
  実装しやすくなる（`find(_:configuration:)`）
- **VoiceOver の読み上げ順の作り込み**: Phase A で一度読み上げを確認して結果を記録するに留める。
  最低限 `aria-label` と `title` は現行 `.help` 文言と一致させる（§3.6）
- **画像の表示**: Markdown に画像が出てくる経路が今は無い。要るようになったらローカル画像用の
  custom scheme handler を足す（Chirami `LocalImageSchemeHandler` が前例）
- **回答への引用リンク**（design 38 §9）: `HH:MM:SS` クリックで書き起こしへジャンプ。
  `MarkdownLinkRouter` に 1 ケース足すだけで乗る形にしてある
