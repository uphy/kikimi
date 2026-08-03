# 47. サマリペインの上下 2 分割 詳細設計

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `kikimi.md` 8 章（サマリ更新戦略・schema + view + patch・view template）,
`kikimi.md` 13 章（会議タブ 1006 行付近のサマリペイン仕様）,
`docs/design/04-summary-updater.md` §2.1/§5/§9（state schema・レンダリング・失敗モード）,
`docs/design/summary-quality-topics-and-final-pass.md` §2.1/§7（`topics` の導入と最終整形）,
`docs/design/39-webview-markdown.md` MD2/MD8/MD12（WebView の寿命・`docKey`・検証ブリッジ）,
`docs/design/17-session-window-redesign.md` §5.3/§5.6（`HSplitView` の min-width と初期比率の既知問題）。

**実装状況**: 未実装（本書が起草）。

## 0. 結論（要約）

**サマリペインを上下 2 つの独立したスクロール領域に分ける**。上は会議全体の状態（概要・決定事項・
アクションアイテム）、下は時系列に伸びる議事詳細（`topics`）。下だけ末尾追従する。

- **分割の境界はテンプレートの `{{#topics}}` セクションから機械的に決める**。「カスタムテンプレなら
  分割しない」という判定は**採用しない**（§3.1: 全セッションに `summary_template.md` が必ず書き込まれる
  ため、その判定は実質常に誤爆する）
- **分割の正しさは連結一致 + 上ペイン非空で検証する**。上下を別々にレンダリングして連結した結果が、
  分割せずにレンダリングした結果と一致しなければ分割を捨てて 1 ペインに落ちる（§3.3）。連結一致だけでは
  「上ペインが空」を検出できないので、境界の下限ガードも要る（§3.2）
- **`summaryMarkdown` への代入経路は 1 本に集約する**。`summary.md` を直読みしている 4 箇所を
  `reloadSummaryMarkdownFromDisk()` に寄せる。1 箇所でも残すと再生成ボタンで分割が潰れる（§2.1/§2.3）
- `summary.md` の**保存は従来どおり連結 1 本**。コピー・チャットコンテキスト・Wiki export は無傷
- UI は `VSplitView` + `MarkdownWebViewStore.Slot` に `summaryTopics` を追加した WebView 2 つ
- **分割比は保存しない**。50:50 で始まりドラッグで可変（§4.2: `NSSplitView` が初期比率を無視する
  既知問題があり、`HSplitView` で既に同じ割り切りをしている）
- 末尾追従は `web/src/chat.ts` の `followIfPinned` と同じ契約を `DocumentView` に持たせる。
  mermaid 描画後の再追従が要る（§5.2）。**追従するのは Ended でないセッションだけ**。終わった議事録を
  開いた瞬間に末尾へ飛ばさないため（§5.1）

## 1. 目的

サマリペインは 1 本のスクロールに性格の違う 2 種類のドキュメントを同居させている。

| | 内容 | 性質 | 読み方 |
|---|---|---|---|
| 会議全体の情報 | `title` / `overview` / `participants` / `decisions` / `action_items` | **状態**。既存項目が patch で書き換わる | 常に最新を一目で見たい |
| 議事詳細 | `topics` | **時系列ログ**。`topics_add` で末尾に追記される | 末尾を追いたい。会議が長いほど際限なく伸びる |

現状は後者が前者を画面外に押し出す。会議が 1 時間続けば、概要を見るたびに延々スクロールで戻ることになる。

加えて、時系列コンテンツのうち `topics` だけ末尾追従がない。書き起こしペインは
`TranscriptAutoFollow`、チャットは `chat.ts` の `followIfPinned` を持っている。ここだけ一貫していない。

## 2. データフローの現状と変更点

### 2.1 現状: UI はレンダリング済みの文字列しか持たない

```
SummaryState (summary.state.json)
  └─ SummaryRenderer.render(state, templateString:) -> String?      ← 4 箇所から呼ばれる
       ├─ sessionHandle.writeText(rendered, to: .summaryMarkdown)   ← summary.md
       └─ SummaryUpdateEvent.summaryMarkdown: String?
            └─ MeetingWorkspaceViewModel.summaryMarkdown: String?   ← @Published
                 └─ SummaryTabView -> MarkdownWebView(docKey: "summary")
```

`SummaryRenderer.render` の呼び出しは 4 箇所。

| 呼び出し元 | 契機 |
|---|---|
| `SummaryUpdater.swift:452` | 通常のインクリメンタル更新 |
| `SummaryUpdater+FinalPass.swift:133` | セッション終了時の最終整形 |
| `SummaryUpdater+ParticipantsMerge.swift:76` | 話者リネームに伴う参加者マージ |
| `SummaryUpdater+Regeneration.swift:75` | 「サマリ全文再生成」 |

一方 `MeetingWorkspaceViewModel.summaryMarkdown` に代入する経路は、上の `SummaryUpdateEvent` 以外に
**`summary.md` をファイルから直読みするものが 4 箇所ある**。ここを取りこぼすと分割が消えるので全部挙げる。

| 代入箇所 | 契機 | 取りこぼしたときの症状 |
|---|---|---|
| `+Hydration.swift:36` | ウィンドウを開いたとき（Ended セッションを開く等） | 開いた直後だけ 1 ペイン |
| `+Summary.swift:32` | 録音開始時の初期表示シード | 最初のサマリ更新まで 1 ペイン |
| `+Summary.swift:146` | 「サマリ全文再生成」（`regenerateSummary`） | 押した瞬間に 1 ペインへ退行 |
| `+Summary.swift:169` | 「最終整形を再実行」（`rerunFinalPass`） | 同上。**Ended では永久に戻らない** |

後ろ 2 つが特に危ない。`stopSummaryUpdater()` 済みの Ended セッションには live な `SummaryUpdater` が
無く `events` も飛ばないので、1 ペインに潰れたらウィンドウを開き直すまで戻らない。Recording 中でも、
events 由来の代入とディスク読みが競合する。§2.3 でこの 4 箇所を 1 本のヘルパに集約する。

### 2.2 変更: `SummaryMarkdown` を導入する

レンダリング済み文字列を、上下 2 本を保持する値型に置き換える。

```swift
/// A rendered summary, split into the two panes the Summary tab shows (design 47 §3).
/// `topics == nil` means "this template could not be split" -- the Summary tab then falls back to
/// the single-pane layout it had before design 47.
struct SummaryMarkdown: Sendable, Equatable {
    /// 会議全体の情報（概要・決定事項・アクションアイテム）。分割できなかったときは全文。
    var top: String
    /// 議事詳細（`## 議事詳細` 見出しから末尾まで）。分割できなかったときは `nil`。
    var topics: String?

    /// `summary.md` に書き出す形。分割前のレンダリング結果と**必ず一致する**（§3.3 の連結一致検証が
    /// それを保証する）。コピー・チャットコンテキスト・Wiki export は全部これを使う。
    var joined: String { topics.map { top + $0 } ?? top }
}
```

- `SummaryRenderer.render(_:templateString:)` の戻り値を `SummaryMarkdown?` に変える
- 4 箇所の呼び出し元は `rendered.joined` を `writeText` に渡す。**書き出す内容は 1 バイトも変わらない**
- `SummaryUpdateEvent.summaryMarkdown` の型を `SummaryMarkdown?` にする
- `MeetingWorkspaceViewModel.summaryMarkdown` の型を `SummaryMarkdown?` にする。
  `+Copy.swift:25` は `summaryMarkdown?.joined ?? ""` になる

### 2.3 ディスク読み 4 箇所を 1 本のヘルパに集約する

`summary.md` を読んで機械分割するのは**採らない**。kikimi.md 8 章は view template の見出し改名を
明示的に許しているので、レンダリング結果の文字列から境界を当てるのは原理的に不可能。

代わりに `SessionFile.summaryState`（永続化済み）と `.summaryTemplate` から `SummaryRenderer` を
もう一度通す。**§2.1 の 4 箇所すべてをこの 1 本のヘルパ経由にする**（`SummaryUpdater` 側の戻り値を
`SummaryMarkdown` に変える案は採らない。`regenerateFromScratch` / `runFinalPass` は失敗しても
`summary.md` を維持する契約であり、戻り値を足すと「失敗時に何を返すか」を新たに決める必要が出る。
state からの再レンダリングなら、成功でも失敗でも「今ディスクにある state の見た目」が必ず得られる）。

```swift
// MeetingWorkspaceViewModel+Summary.swift（4 箇所から呼ばれる唯一の代入経路）
/// Re-renders `summaryMarkdown` from the persisted `summary.state.json`, keeping the two-pane split
/// (design 47 §2.1). Every path that used to do `readText(.summaryMarkdown)` goes through this --
/// reading the rendered `summary.md` back can only ever produce a `topics == nil` single pane.
func reloadSummaryMarkdownFromDisk() async {
    if let state: SummaryState = try? await sessionHandle.readJSON(from: .summaryState),
       let rendered = SummaryRenderer.render(state, templateString: await sessionHandle.readSummaryTemplate()) {
        summaryMarkdown = rendered
    } else if let onDisk = try? await sessionHandle.readText(.summaryMarkdown), !onDisk.isEmpty {
        // No/corrupt state (a pre-design-04 session): show summary.md as a single pane.
        summaryMarkdown = SummaryMarkdown(top: onDisk, topics: nil)
    }
}
```

呼び出し側は 4 箇所とも 1 行になる。

```swift
// +Summary.swift:146 / :169 — 旧: summaryMarkdown = (try? await sessionHandle.readText(.summaryMarkdown)) ?? summaryMarkdown
await reloadSummaryMarkdownFromDisk()
meta = await sessionHandle.meta
```

- 旧コードの `?? summaryMarkdown`（読めなければ現在値を保つ）は、ヘルパが両方の `if` を外れたとき
  何もしないことで維持される。**表示が消えることはない**
- レンダリングコストは Mustache 3 回（§3.3）。ウィンドウを開くとき・再生成ボタンを押したときだけなので
  無視できる
- `+Hydration.swift` からは `MainActor` 上の同じヘルパを `await` するだけ

## 3. テンプレートの分割

### 3.1 「カスタムテンプレなら分割しない」を採らない理由

`SessionStore+Defaults.swift:113` の `loadInitialSummaryTemplate` は、seed（`.basedOn` / `.profile`）→
グローバル既定 `~/.config/kikimi/templates/summary.md` → 内蔵既定、の順に必ず解決して**全セッションに
`summary_template.md` を書き込む**（kikimi.md 626 行）。

- **ファイルの有無で判定 → 100% 誤爆**。全セッションにファイルがあるので分割が一度も発動しない
- **内蔵既定との内容一致で判定 → ほぼ誤爆**。カスタマイズの主用途はグローバル既定テンプレの編集であり、
  そこを 1 文字でも触ると全セッションで分割が無効になる。内蔵既定テンプレを将来変更したときも、
  既存セッション全部が静かに 1 ペインへ退行する

判定の設計をやめ、テンプレの構造から機械的に分割する。

### 3.2 分割アルゴリズム

**入力**: テンプレート文字列（`summary_template.md` の中身、または内蔵既定）。

1. `{{#topics}}` と `{{^topics}}` のうち**最初に現れる方**の位置を探す。どちらも無ければ分割しない（`nil` を返す）
2. その位置から**行頭に向かって遡り**、`##` 以上の見出し行（`##` / `###` / …）を探す。
   **`# ` 単独の行は境界にしない**（下記）。見つからなければ、`{{#topics}}` を含む行の行頭を境界にする
3. その行の行頭を境界として、テンプレ文字列を `topTemplate` / `topicsTemplate` の 2 つに切る
4. **`topTemplate` が空白のみなら分割しない**（下記）
5. それぞれを独立に `Template(string:)` でパースしてレンダリングする。どちらかが失敗したら分割しない
6. **レンダリング後の `top` が空白のみなら分割しない**
7. §3.3 の連結一致検証を通す

内蔵既定テンプレでは `## 議事詳細` の行頭が境界になる。

```
（top 側）                          （topics 側）
# {{title}}                         ## 議事詳細
                                    ⏎
## 概要                             {{#topics}}### {{heading}}
...                                 ⏎
## アクションアイテム                {{body}}
| タスク | 担当 | 期限 |            ⏎
...                                 {{/topics}}
⏎
```

境界より下は**全部** topics 側に入る。議事詳細のあとに `## 備考` のような節を足したカスタムテンプレでは、
それも下ペインに出る。ここは単純さを取る（節ごとの振り分けは schema を持たない見出し文字列からは決められない）。

**手順 2 の `# ` 除外と手順 4/6 の空判定は、上ペインが真っ白になるのを防ぐためにある**（GRMustache.swift を
実際に動かして確認した）。`# {{title}}` の直後に `{{#topics}}` を置く最小テンプレ（`## 議事詳細` にあたる
見出しを持たない形）だと、遡り探索が `# {{title}}` に当たって `topTemplate` が空文字列になる。このとき
`"" + whole == whole` は成立するので §3.3 の連結一致検証は**素通りする**。`SummaryTabView` の空判定は
`joined` 側なのでプレースホルダにも落ちず、「空の上ペイン + 全文が入った下ペイン」という壊れた 50:50 分割が
そのまま画面に出る。ガードに掛かれば `topics = nil` の 1 ペインに落ちる。

`{{#topics}}` がテンプレ前半にあり、決定事項・アクションアイテムがその下にあるテンプレでは、状態系の節が
全部下ペインへ落ちる。分割としては意図どおりではないが、上ペインに `# {{title}}` が残るので許容する
（実害が出るのは上ペインが空になるケースだけで、それは手順 4/6 が塞ぐ）。

### 3.3 連結一致検証（分割の正しさを保証する仕組み）

Mustache のセクションは互いに状態を持たないので、「切ったテンプレを個別にレンダリングして連結」は
「全体を 1 回レンダリング」と等しくなる**はず**。しかし境界が Mustache セクションの内側に落ちるカスタム
テンプレ（例: `{{#foo}}## 議事詳細 {{#topics}}...{{/topics}}{{/foo}}`）では等しくならない。

そこで**分割せずに 1 回レンダリングした結果を必ず作り、`top + topics` と一致するか比べる**。

**分割対象は「実際にレンダリングに成功したテンプレソース」**。`SummaryRenderer.render(_:templateString:)`
は「セッションの `summary_template.md` → 失敗したら内蔵既定」の 2 段フォールバック
（`SummaryRenderer.swift:76-89`、`04-summary-updater.md` §9）を持つので、分割対象と `whole` の由来が
ズレないよう、**フォールバック解決を先に済ませてから同じソースを分割に渡す**。ユーザーテンプレが render
失敗して内蔵既定にフォールバックしたのに、分割だけ失敗したユーザーテンプレを見にいくと、`joined` と
`summary.md` が別テンプレ由来になって食い違う。

```swift
static func render(_ state: SummaryState, templateString: String?) -> SummaryMarkdown? {
    let trimmed = templateString?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty, let rendered = renderSplit(state, usingTemplateSource: trimmed) {
        return rendered
    }
    if trimmed?.isEmpty == false {
        logger.warning("session summary_template.md failed to render, falling back to the built-in default template")
    }
    return renderSplit(state, usingTemplateSource: defaultTemplate)  // nil ならレンダリング自体の失敗
}

/// `templateSource` renders **and** splits, or renders as a single pane. Never mixes two sources.
private static func renderSplit(_ state: SummaryState, usingTemplateSource templateSource: String) -> SummaryMarkdown? {
    guard let whole = render(state, usingTemplateSource: templateSource) else { return nil }
    guard let (topSource, topicsSource) = splitTemplate(templateSource),   // §3.2 手順 1-4
          let top = render(state, usingTemplateSource: topSource),
          let topics = render(state, usingTemplateSource: topicsSource),
          !top.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,    // §3.2 手順 6
          top + topics == whole
    else {
        logger.debug("summary template could not be split; falling back to the single-pane layout")
        return SummaryMarkdown(top: whole, topics: nil)
    }
    return SummaryMarkdown(top: top, topics: topics)
}
```

- **`renderSplit` が `nil` を返すのはレンダリング自体が失敗したときだけ**。分割の失敗は `nil` ではなく
  `topics == nil` の 1 ペインとして返る。これで外側のフォールバック連鎖は従来と 1 対 1 に対応する
- 一致しないテンプレは黙って 1 ペインになる。**壊れた表示にはならない**
- `joined == whole` が構造的に保証されるので、`summary.md` の中身・コピー・チャット・Wiki export への
  影響がゼロであることを型と等式の両方で言える
- コストは Mustache レンダリング 3 回（従来 1 回）。サマリ更新は数十秒〜数分に 1 回なので無視できる

## 4. UI

### 4.1 レイアウト

```
┌──────────────────────────────────┐
│ [最終整形を再実行] [サマリ全文再生成]  │  regenerateBar（従来どおり）
├──────────────────────────────────┤
│ # 打合せタイトル                    │  WebView #1 (Slot .summary)
│ ## 概要 / ## 決定事項 / ## AI       │   docKey: "summary"
│                                  │   独立スクロール・追従なし
├━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┤  VSplitView の divider（ドラッグ可）
│ ## 議事詳細                        │  WebView #2 (Slot .summaryTopics)
│ ### … / ### …                     │   docKey: "summary-topics"
│                                  │   独立スクロール・末尾追従
└──────────────────────────────────┘
```

- `summaryMarkdown?.topics == nil` のときは `VSplitView` を使わず、従来どおり単一の
  `MarkdownWebView(markdown: joined, docKey: "summary")` を出す
- `summaryMarkdown == nil` のときは従来どおり `SummaryPlaceholder`
- 上下それぞれに `minHeight: 120` を置く（`HSplitView` の `minWidth: 240` に相当）

**分割時の上ペインは `docKey: "summary-top"`、非分割時は `docKey: "summary"`。** 同じ `docKey` を
使い回すと、分割⇄非分割が切り替わったとき（§7 #6）に `MarkdownWebViewHost.setContent` が
「同じ文書の更新」と判断してスクロール位置を復元してしまう。中身の長さがまったく違う文書に前の位置を
引き継ぐことになるので、`docKey` を分けて先頭から見せる。検証ブリッジの `target=summary` は
`Slot.summary` を指したままなので影響しない（§4.3）。

**2 つ目の host は格納プロパティで渡さない。`() -> MarkdownWebViewHost` のクロージャで渡し、分割分岐の
内側で解決する。**

```swift
// SummaryTabView
let markdownHost: MarkdownWebViewHost                  // 上ペイン。従来どおり即時解決
let topicsMarkdownHost: () -> MarkdownWebViewHost      // 下ペイン。分割が成立したときだけ呼ぶ

// MeetingWorkspaceView.swift:267 付近
topicsMarkdownHost: { markdownWebViewStore.host(for: .summaryTopics) }
```

`markdownHost:` と同じ形（`topicsMarkdownHost: markdownWebViewStore.host(for: .summaryTopics)`）で渡すと、
`MeetingWorkspaceView.summaryTabView` は **body 評価時に即時実行される**ので、分割の可否を知る前に
`host(for:)` が呼ばれる。`MarkdownWebViewStore.host(for:)` は生成と同時に `start()`（312KB バンドルの
`loadFileURL`。`WKWebViewConfiguration` が独立なので WebContent プロセスも別）まで走らせるため、
分割不能なテンプレのセッションでも WKWebView が 1 個丸ごと増える（サマリペインを一度でも表示した
ウィンドウで 3 → 4 個）。クロージャなら `host(for:)` の呼び出しが `if topics != nil` の内側に入り、
分割しないセッションでは**本当にコストゼロ**になる。`MarkdownWebViewStore` 自体を渡す案もあるが、
`SummaryTabView` に store 全体（他 slot への到達性）を持たせる必要はないのでクロージャを採る。
store は同じ slot に対して同一 host を返すので、body が何度評価されても WebView は 1 個のまま。

### 4.2 分割比は保存しない

`MeetingTabView.swift:165` に既知の失敗が記録されている。「両方」モードの初期比率 6:4 を狙って
`.frame(idealWidth:)` と `GeometryReader` 実測幅の両方を試したが、両方の子が同じ
`minWidth`/`maxWidth: .infinity` を持つと `HSplitView`（中身は `NSSplitView`）が無視する。真の 6:4 には
`NSSplitViewController` レベルの API が要り、SwiftUI からは触れない。

`VSplitView` も同じ `NSSplitView` なので、比率を `state.yaml` に保存しても**復元できない**。保存機構だけ
作って効かないより、`HSplitView` と同じ割り切り（50:50 で始まりドラッグで自由に変えられる、
ウィンドウを閉じると忘れる）で揃える。

**却下した代案: WebView 1 枚のページ内を 2 スクロール領域に分ける。** WebContent プロセスが増えず、
mermaid ランタイムが 1 つで済み、`Slot` / `DebugWebViewTarget` / `webview.sh` に新ターゲットを足す必要が
なく、`NSSplitView` を経由しないので**分割比の保存も普通にできる**。代償は divider（ドラッグ・カーソル
形状・アクセシビリティ）を JS で自作することと、macOS ネイティブな操作感を失うこと。ユーザーが
「比率の保存より実装の軽さと既存アーキとの素直さを取る」判断をしたため `VSplitView` を採る。
分割比の保存が後で必要になったら、この代案に戻ることになる。

### 4.3 `Slot` の追加と検証ブリッジ

```swift
enum Slot: String, CaseIterable {
    case summary
    case summaryTopics   // 追加
    case watchers
    case chat
}
```

`kikimi://debug/webview`（`docs/design/39-webview-markdown.md` MD12）の
`KikimiURLRoute.DebugWebViewTarget` に `summaryTopics` を足し、`WindowManager.debugWebViewHost` の
switch に対応を足す（`Kikimi/Window/WindowManager.swift:390`）。既存の `summary` ターゲットは上ペインを
指したままにする（`kikimi-verify` の既存シナリオを壊さない）。

## 5. 末尾追従

### 5.1 Swift → web のインタフェース

`DocumentView.setContent` に追従の要否を渡す。`MarkdownWebViewHost.setContent` にパラメータを足し、
`MarkdownWebView` が `followBottom` を持つ。

```swift
func setContent(markdown: String, docKey: String, followBottom: Bool = false)
```

`followBottom: true` を渡すのは topics ペインだけ。既定 `false` で Watchers・上ペインは従来どおり。

**さらに `meta.state != .ended` のときだけ `true` にする。** web 側の pinned 初期値は `chat.ts` と同じ
`true`（末尾にいる扱い）なので、無条件に `followBottom: true` を渡すと Ended セッションを開いた瞬間に
議事詳細の末尾へ飛ぶ。終わった会議の議事録は普通は頭から読む。逆に初期値を `false` にすると、録音中に
一度手でスクロールして末尾に触れるまで追従が始まらない。**追従の要否そのものをセッションの状態で
決める**ほうが、web 側に状態を持ち込まずに両方を満たせる。Paused は追記が来ないのでどちらでも同じだが、
再開しうるので `.ended` 以外はすべて `true` にする。

`webViewWebContentProcessDidTerminate` のクラッシュ復帰（`MarkdownWebViewHost.swift:345`）とテーマ変更の
再送（同 :167）も `lastContent` に `followBottom` を含めて復元する。

### 5.2 web 側（`web/src/document.ts`）

`chat.ts` の `installScrollTracking` / `distanceFromBottom` / `followIfPinned` と**同じ契約**を持たせる。
共有コードにはせず移植する（`chat.ts` はページ全体スクロール、`DocumentView` も同じ `scrollingElement` を
使うが、Chat 側は turn 単位の別ロジックと絡んでいる）。閾値 `BOTTOM_THRESHOLD_PX` は chat と揃える。

落とし穴が 3 つある。

1. **mermaid 描画後にもう一度追従が要る**。`document.ts:32-43` は rAF 内で scrollTop 復元 → mermaid 描画 →
   `rendered` 通知の順。topics に mermaid があると描画完了で `scrollHeight` が伸びるので、末尾にいたはずが
   途中で止まる。`chat.ts:94-102` は `renderMermaidBlocks().finally()` の中で `followIfPinned()` している。
   **rAF 直後と mermaid の `finally` の両方**で追従すること
2. **`docKey` が変わったら pinned 状態をリセットする**。別ドキュメントに前のピン状態を持ち越さない。
   現行 `setContent` の `isSameDocument` 分岐に合わせて初期化する
3. **追従中は scrollTop 復元をスキップする**。`followBottom && isPinnedToBottom` なら復元せず末尾へ

追従の分岐は `setContent` の中に閉じる。`followBottom: false` のときの挙動は**現行と 1 行も変わらない**。

## 6. 波及範囲（変更が要らないことの確認）

| 経路 | 参照 | 影響 |
|---|---|---|
| コピー（⌘⇧C） | `Kikimi/Markdown/TranscriptMarkdownSource.swift:47` | `joined` を渡すだけ。出力は同一 |
| チャットコンテキスト | `Kikimi/Chat/ChatContextBuilder.swift:111` | 同上 |
| Wiki export | `TranscriptMarkdownRenderer` 経由 | 同上 |
| `summary.md` の中身 | `writeText(rendered.joined, to: .summaryMarkdown)` | §3.3 の連結一致で同一が保証される |
| 更新ドット | `MeetingWorkspaceViewModel+Summary.swift:59` | `event.summaryMarkdown != nil` の判定はそのまま |
| 「両方」モード | `MeetingTabView.swift:172` | 左右分割の中で右側が上下に割れる。高さは変わらないので追加の制約なし |
| 既存 Ended セッション | `summary.state.json` あり | §2.3 で再レンダリングされ、分割表示になる |

## 7. 失敗モード

| # | 状況 | 挙動 |
|---|---|---|
| 1 | テンプレに `{{#topics}}` が無い | 分割せず 1 ペイン。`debug` ログ |
| 2 | 分割後のテンプレが Mustache パースに失敗 | 同上 |
| 3 | 連結一致検証が不一致 | 同上（§3.3） |
| 3b | 境界が先頭に落ちて `top` が空になる（`# {{title}}` の直後が `{{#topics}}`） | 分割せず 1 ペイン。連結一致では検出できないので §3.2 手順 2/4/6 のガードが塞ぐ |
| 4 | `summary.state.json` が無い/壊れている（旧セッション） | `summary.md` を 1 ペインで表示（§2.3） |
| 5 | レンダリング自体が失敗 | 従来どおり `summary.md` を更新せず `warning`（04-summary-updater.md §9） |
| 6 | セッション途中でテンプレを分割不能な内容に編集 | 次回サマリ更新から 1 ペインに変わる。`docKey` も変わるのでスクロールは先頭へ。頻度が低いので許容する |
| 7 | topics が空（会議序盤） | 下ペインに `## 議事詳細` の見出しだけが出る。空でも分割は維持する（すぐ埋まる） |

## 8. テスト（レイヤ 1）

`KikimiTests/Summary/SummaryRendererTests.swift` に追加。

- 内蔵既定テンプレが `## 議事詳細` で分割され、`top` に `## 概要`、`topics` に `### {heading}` が入る
- **`joined` が分割前のレンダリング結果と完全一致する**（既存テストの期待値をそのまま使える）
- `{{#topics}}` の無いテンプレ → `topics == nil`、`top` が全文
- `{{^topics}}` だけのテンプレ → そこが境界になる
- 境界が Mustache セクションの内側に落ちるテンプレ → 連結一致に失敗して `topics == nil`
- `{{#topics}}` の前に見出し行が無いテンプレ → `{{#topics}}` の行頭が境界
- **`# {{title}}` の直後に `{{#topics}}` が来るテンプレ → `topics == nil`**（§3.2 のガード。
  これが無いと連結一致を素通りして空の上ペインになる）
- ユーザーテンプレが Mustache パースに失敗 → 内蔵既定で再試行し、**内蔵既定が分割された結果**が返る
  （分割対象がユーザーテンプレに残っていないこと。§3.3）
- `topics` が空配列 → 下は見出しだけ、`joined` は従来どおり

`KikimiTests/Views/`（該当があれば）に `SummaryMarkdown.joined` の等式テスト。

ViewModel 側は `KikimiTests/ViewModels/MeetingWorkspaceViewModelTests.swift:2139` の
`regenerateSummaryAfterEnded` が既に §2.1 の経路を踏んでいるので、そこに**分割が維持される**アサートを足す
（`viewModel.summaryMarkdown?.topics != nil`）。`rerunFinalPass` にも同じ形のテストを 1 本足す。

web 側は `web/src/document.test.ts` に追加。

- `followBottom: false` のとき、既存のスクロール位置復元の挙動が変わらない
- `followBottom: true` かつ末尾にいるとき、`setContent` 後に末尾へ移動する
- `followBottom: true` だが上にスクロールしているとき、位置が保たれる
- `docKey` が変わったら pinned がリセットされる

**追従が絡む後ろ 3 つは、jsdom のレイアウトを明示的にスタブしないと成立しない**。jsdom は `scrollHeight` /
`clientHeight` が常に 0 を返すので、`chat.ts` から移植した
`distanceFromBottom() = scrollHeight - scrollTop - clientHeight` は必ず閾値以下、つまり**常に pinned**
と判定される。「上にスクロールしている」ケースはそもそも作れず、「末尾にいる」ケースは `scrollTop` が
0 のまま 0 と比較されて**素通りで green になる**。既存の `web/src/chat.test.ts` に追従のテストが 1 件も
無いのはおそらくこれが理由で、追従は本設計で初めて自動テストの対象になる。

```ts
// jsdom's scrollHeight/clientHeight are hard-wired to 0; scrollTop is a plain stored value
// (the existing MD8 tests rely on that). Stub the two getters so distanceFromBottom() is meaningful.
function stubLayout(scrollHeight: number, clientHeight: number): void {
  for (const [name, value] of [["scrollHeight", scrollHeight], ["clientHeight", clientHeight]] as const) {
    Object.defineProperty(document.documentElement, name, { value, configurable: true });
  }
}
```

- `document.scrollingElement` は jsdom では `document.documentElement` なので、スタブ先はそこでよい
- `documentElement` はテスト間で使い回されるため `configurable: true` は必須。`afterEach` で
  `delete (document.documentElement as ...)[name]` して元の getter を戻す
- pinned 判定は scroll イベントで更新される（`installScrollTracking`）ので、`scrollTop` を書いたあと
  `document.dispatchEvent(new Event("scroll"))` を明示的に発火させる。初期値は `chat.ts` と同じ
  `isPinnedToBottom = true`
- 「末尾へ移動する」は `setContent` 前後で `scrollHeight` のスタブ値を変えて（コンテンツが伸びた状況を
  作って）、`scrollTop === 新しい scrollHeight` を assert する。伸ばさないと従来値と区別がつかない

UI 動作確認（レイヤ 2）はユーザーが行う。次の 3 点を依頼する。

- **ペイン切替の往復で両ペインが白くならないこと**。`MarkdownWebViewContainer.detach()`
  （`Kikimi/Views/Markdown/MarkdownWebView.swift`）のコメントに「サマリのみペインが白いまま描かれた」
  既知バグとその修正が残っており、WebView を SwiftUI サブツリー間で移動させる部分は元々脆い。
  `HSplitView > VSplitView > WebView 2 枚` になると移動対象が倍になる。
  「書き起こしのみ ↔ サマリのみ ↔ 両方」を往復して確認する
- 録音中に議事詳細が伸びたとき、末尾にいれば追従し、上にスクロールしていれば追従しないこと
- Ended セッションを開いたとき、議事詳細が末尾ではなく先頭から表示されること（§5.1）

## 9. 実装順序

1. `SummaryMarkdown` 型 + `SummaryRenderer` の分割・連結一致検証 + 単体テスト
2. 呼び出し 4 箇所と `SummaryUpdateEvent` / ViewModel の型変更（この時点では UI は `joined` を出すだけ。
   **見た目が一切変わらないことを確認できる**）
3. `reloadSummaryMarkdownFromDisk()` を足し、`summary.md` 直読み 4 箇所を全部そこに寄せる（§2.1/§2.3）
4. `Slot.summaryTopics` 追加 + `SummaryTabView` の `VSplitView` 化（host は遅延クロージャ・§4.1）+ 検証ブリッジ
5. web 側の末尾追従 + `followBottom` の受け渡し
6. `kikimi-verify` の更新（`.claude/skills/kikimi-verify/scripts/webview.sh` の usage 行と SKILL.md に
   `summaryTopics` ターゲットを足す）

2 の時点で一度ビルドとテストを通す。ここまでは挙動が変わらないので、以降の変更を切り分けやすい。

手順 6 を省くと、`webview.sh wait summary "..."` で議事詳細の文字列を待っている既存シナリオが、
`target=summary` が上ペインしか指さなくなることで黙って落ちる。`mise run verify-smoke` の期待文字列は
概要側（`[stub] スタブ応答による最終概要です`）なので**スモークは green のまま**で、気づけない。
