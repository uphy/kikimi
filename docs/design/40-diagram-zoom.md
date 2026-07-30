# 40. 図の拡大表示（画面全体オーバーレイ）詳細設計

`docs/design/39-webview-markdown.md` で mermaid が描けるようになった結果に対する追加。横に長い図は
フローティングパネルの幅に収まらず、**読むためにウィンドウを広げると会議アプリを覆ってしまう** —
パネルが狭いのは仕様（kikimi.md 10 章）なので、パネルの寸法を変えずに図だけ一時的に大きく見る道を作る。

- **図の右上の拡大ボタンから、画面全体のオーバーレイパネルに図を出す**（DZ1 / DZ2）
- **対象は mermaid の図だけ**。テーブルやコードブロックも横に長くなるが、そちらは横スクロールで
  追える（DZ3）
- **SVG ではなく mermaid のソースを渡して拡大側で描き直す**（DZ4）
- **拡大中もアプリは activate しない**。`.nonactivatingPanel` のまま、キーだけ受ける（DZ6）
- **パネル内は幅に収めて全体を見せ、読むための拡大はオーバーレイに任せる**（DZ9）

## 1. 目的とスコープ

**やること**:

- サマリ / Watchers / チャットに描かれた mermaid の図に拡大ボタンを付ける
- 押すと、そのウィンドウがある画面いっぱいのオーバーレイに図を表示する
- 拡大表示中にパン（ドラッグ）とズーム（スクロール / ⌘+ ⌘-）ができる
- Esc / 背景クリック / ⌘W で閉じる
- パネル内の図は幅に収めて全体を表示する（見切れさせない）

**やらないこと**:

- テーブル・コードブロック・本文全体の拡大（DZ3）
- 図の書き出し（PNG / SVG 保存）。要望が出たら別途
- 複数の図を並べて見る
- 拡大表示の状態（ズーム率・位置）の永続化

## 2. 決定事項

| # | 決定 |
|---|------|
| DZ1 | **トリガーは図の右上の拡大ボタン**。図そのもののクリックには割り当てない — 図をなぞっただけで全画面に飛ぶのは煩わしく、将来 mermaid のノードにリンクを載せるときにも競合する。ボタンは hover で現れる（常時表示は図に重なる情報が増えるだけ） |
| DZ2 | **表示先は画面全体の専用パネル**。WebView 内のオーバーレイでは親パネルの幅に閉じるので、横長の図には何の効果もない。パネルは `FloatingPanel(style: .borderless)` を使い、**きっかけになったウィンドウがある `NSScreen` の `visibleFrame`** いっぱいに開く（メニューバーと Dock は避ける） |
| DZ3 | **対象は mermaid だけ**。横に長くなるのはテーブルやコードブロックも同じだが、そちらは横スクロールで読める（文字の大きさが変わらないため）。図は縮小されると線と文字が潰れるので、別の道が要る |
| DZ4 | **渡すのは mermaid のソース**。描画済み SVG の文字列をブリッジに載せない。ソースなら数百バイトで、拡大側は自分の寸法に合わせて描き直せる（SVG の拡大は文字が滲むが、再描画なら滲まない）。ソースは `.kikimi-mermaid` の `data-src` に残っているので、取り出しは 1 行 |
| DZ5 | **オーバーレイの WebView は 1 つを使い回す**。`mermaid.bundle.js` は 3.3MB で、開くたびに読み直すと待たされる。パネルを閉じても WebView は `DiagramZoomWindowController` が保持し、2 回目以降は即描画。ウィンドウは `WindowManager` が 1 つだけ持つ（同時に 2 つの図を拡大する意味がない） |
| DZ6 | **アプリを activate しない**。`.nonactivatingPanel` を維持したまま `canBecomeKey` だけ許す（Esc と ⌘W を受けるため）。design 39 の Phase A で「WebView 内の操作で frontmost が変わらない」ことは実測済みで、その性質を拡大表示でも壊さない |
| DZ7 | **`level` は既存パネルより上**。サマリを出しているウィンドウの上に重ねる必要があるので `.modalPanel`。`collectionBehavior` は既存パネルと同じ（`.canJoinAllSpaces` / `.fullScreenAuxiliary`）で、全画面の会議アプリの上にも出る |
| DZ8 | **閉じ方は 3 つ**。Esc（`cancelOperation` で拾う）、図の外側のクリック（ページから `closeDiagram` を投げる）、⌘W。閉じたら親ウィンドウにキーを戻す |
| DZ9 | **パネル内の図は幅に収めて全体を見せる**（`max-width: 100%`）。当初は「縮小すると線と文字が潰れるので横スクロールにする」と決めたが、実機で見て撤回した — 右端が見切れる状態は、図の全体像がつかめないぶん潰れて読めないより悪い。**本文の役目は一望**で、読むための拡大は拡大ボタンが担う。実寸への固定（`pinNaturalSize`）はオーバーレイだけに適用する（`renderMermaidSource` の `sizing` 引数） |
| DZ10 | **拡大側の描画失敗も本文と同じ扱い**。mermaid が投げたらソースを等幅で出す（design 39 §4 の `showSource` を共有）。本文では描けた図が拡大側で描けない状況は理屈上起きないが、無言で空の画面を出すより安い |

## 3. コンポーネント構成

```
web/src/
  diagram.ts         オーバーレイのビュー（暗幕・パン・ズーム・fit）
  svg-size.ts        mermaid の SVG を viewBox の実寸へ固定する（§3.4）
  mermaid-loader.ts  描画成功時に拡大ボタンを添える（追加）
  bridge.ts          setDiagram / zoomDiagram / closeDiagram を追加

Kikimi/Window/
  DiagramZoomWindowController.swift   画面全体のパネルと、使い回す WebView を所有
Kikimi/Views/Markdown/
  MarkdownWebViewHost.swift           onZoomDiagram を追加
```

### 3.1 ブリッジの追加分

```ts
// Swift -> JS
setDiagram: (payload: { source: string }) => void;

// JS -> Swift
| { type: "zoomDiagram"; source: string }
| { type: "closeDiagram" }
```

`setDiagram` を最初に受けたページは**オーバーレイモード**で起動する（design 39 §3 の
「最初の API 呼び出しでビューが決まる」規則をそのまま延長）。オーバーレイ用の WebView は本文用とは
別インスタンスなので、1 つのページが両方のモードを持つことはない。

### 3.2 拡大ボタン（DZ1）

`mermaid-loader.ts` が描画に成功したブロックへ添える。

```html
<div class="kikimi-mermaid kikimi-mermaid-rendered" data-src="...">
  <svg>...</svg>
  <button class="kikimi-mermaid-zoom" data-testid="mermaid-zoom" aria-label="図を拡大" title="図を拡大">…</button>
</div>
```

`aria-label` と `title` を同文言にするのは Kikimi の AX 契約（design 39 §3.6）。`data-testid` は
`__kikimiClick` から押せるようにするため（design 39 MD12）。

### 3.3 `DiagramZoomWindowController`

```swift
@MainActor
final class DiagramZoomWindowController: NSWindowController {
    /// Shows `source` on the screen `anchor` currently lives on (DZ2).
    func show(source: String, anchoredTo anchor: NSWindow?)
    func close()
}
```

- パネル: `FloatingPanel(contentRect: screen.visibleFrame, style: .borderless)`、`level = .modalPanel`（DZ7）
- WebView: `MarkdownWebViewHost` を 1 つ保持し、`setDiagram` を投げる（DZ5）
- Esc: パネルの `cancelOperation(_:)` で閉じる（DZ8）
- 暗幕はページ側の CSS で描く。パネル自体は `isOpaque = false` / `backgroundColor = .clear`

`WindowManager.shared` が唯一のインスタンスを持ち、`MarkdownWebViewHost.onZoomDiagram` から呼ばれる。

### 3.4 パンとズーム

`diagram.ts` が CSS transform で行う。図は `transform: translate(x, y) scale(k)`。

| 操作 | 挙動 |
|---|---|
| ドラッグ | パン |
| スクロール / トラックパッドのピンチ | ズーム（カーソル位置を中心に） |
| ⌘+ / ⌘- / ⌘0 | ズームイン / アウト / 等倍 |
| ダブルクリック | 画面に合わせる（初期状態と同じ） |
| 図の外側のクリック | 閉じる（DZ8） |

初期状態は「画面に合わせる」。**縮小方向だけでなく拡大方向にも合わせる** — オーバーレイを開く理由が
「パネルでは小さすぎて読めない」ことなので、初期倍率を 1 で止めると横長の図が画面の 1/6 の高さで開いて
何も解決しない。ズーム倍率は 0.2〜8 に丸める（それ以上は操作不能になるだけ）。

**レイアウトと計測を一致させる**（`web/src/svg-size.ts`）。mermaid は
`<svg width="100%" style="max-width: NNNpx" viewBox="0 0 W H">` を吐く。この 3 つは互いに引っ張り合い、
実装中に 2 回同じ根で壊した。

1. `getBoundingClientRect` を実寸として使った → `max-width` のせいでコンテナ幅が返り、`fit` の倍率が
   常に 1 前後になって拡大されない
2. CSS で `width: auto !important` を当てて打ち消そうとした → SVG が置換要素の既定サイズに落ちる一方、
   `fit` は `viewBox` から計算し続けたので**両者が食い違い、canvas の背景だけが見える**状態になった

正解は「描画直後に SVG を `viewBox` の実寸へ固定する」（`pinNaturalSize`）。CSS で寸法を触らない。
固定するのは**オーバーレイだけ**（`renderMermaidSource` の `sizing: "natural"`）。こうすると
transform の倍率だけが見た目の大きさを決める。本文側は mermaid の `width="100%"` をそのまま残し、
`max-width: 100%` で幅に収める（DZ9）— 実寸に固定したら右端が見切れて一望できなくなった。

## 4. テスト

**レイヤ 1（Swift）**: `DiagramZoomWindowController` は AppKit との結線がほとんどで、切り出せる純粋な
判断は「どの画面に出すか」だけ。`DiagramZoomPlacement.screenFrame(for:)` として分離し、
アンカーが `nil`（ウィンドウが閉じた直後など）のときにメインスクリーンへ落ちることを検証する。

**JS（vitest）**:

- `diagram.test.ts` — fit が初期状態になる、ズームが上下限で丸められる、パンが transform に反映される、
  図の外側のクリックで `closeDiagram` が飛ぶ、内側では飛ばない
- `mermaid-loader.test.ts`（追加） — 描画成功時に拡大ボタンが添えられ、押すと `zoomDiagram` が
  ソース付きで飛ぶ。**描画に失敗したブロックにはボタンを付けない**（拡大しても同じ失敗を見るだけ）

**レイヤ 2**: `__kikimiClick("mermaid-zoom")` で拡大を開けるので、開いた後のウィンドウ数と
`__kikimiDumpText` で検証できる。

## 5. 既存への改修（すべて反映済み）

**完了**（2026-07-30 に UI 動作確認済み。Swift 2113 / vitest 55）。

| 対象 | 改修 |
|---|---|
| `web/src/style.css` | 拡大ボタンとオーバーレイのスタイル。本文側の図は `max-width: 100%`（DZ9） |
| `web/src/mermaid-loader.ts` | 描画成功時に拡大ボタンを添える |
| `web/src/bridge.ts` / `main.ts` | §3.1 の 3 つを追加 |
| `Kikimi/Views/Markdown/MarkdownWebViewHost.swift` | `onZoomDiagram` と `setDiagram` |
| `Kikimi/Window/WindowManager.swift` | `DiagramZoomWindowController` を 1 つ保持 |
| `Kikimi/Views/MeetingWorkspace/*TabView.swift` | 拡大の配線（3 タブとも `onZoomDiagram` を渡す） |
| `docs/design/39-webview-markdown.md` §4 | 図の縮小をやめたこと、拡大ボタンを添えることを追記 |

## 6. やらないこと・将来拡張

- **図の書き出し**（PNG / SVG をファイルへ、またはクリップボードへ）。拡大表示ができれば当面は
  スクリーンショットで足りる
- **テーブル・コードブロックの拡大**（DZ3）。同じオーバーレイに HTML を渡す口を足せば乗るが、
  横スクロールで読めるものに専用 UI を足す必要が薄い
- **ズーム率の永続化**。図ごとに適切な倍率は違うので、覚えても外れるほうが多い
- **複数画面にまたがる表示**。1 枚の画面いっぱいで足りる
