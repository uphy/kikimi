# 09. Raycast Integration（`kikimi://` URL scheme）詳細設計

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `kikimi.md` 10章「録音の開始・一時停止・終了」の Raycast 連携 subsection。
`WindowManager` 呼び出し先: `docs/design/06-ui-panels.md` 5.2章（`createDraftWorkspace(basedOn:)`/
`quickRecord()`）・11章 失敗モード #13。
Chirami 参照実装: `ChiramiApp.swift`（`application(_:open:)` +
`NSAppleEventManager`/`kAEGetURL` の二重登録パターン。読み取り専用参照）。

## 1. 目的とスコープ

`kikimi://` URL scheme の**受信処理**のみを対象にする。Raycast 側の Quick Link / Script Command 定義や
公式 Raycast Extension 化は範囲外（将来検討、kikimi.md 15章）。CLI（`kikimi` コマンド）の提供も範囲外。

対象は以下の2エンドポイントのみ（kikimi.md 10章に明記されたもの以外は実装しない）。

| URL | 動作 |
|---|---|
| `kikimi://window/new` | 空の Draft ウィンドウを新規作成 |
| `kikimi://window/new?based_on=<session-id>` | `<session-id>` の context/summary_template を複製した Draft ウィンドウを新規作成 |
| `kikimi://record/quick` | デフォルト context で新規 Draft 作成 + 即録音開始。Recording 中なら何もしない |

`WindowManager.createDraftWorkspace(basedOn:)`/`quickRecord()`（06-ui-panels.md 5.2章）が既に
これらのユースケースを実装済み。本ドキュメントは「URL → どちらを呼ぶか」のルーティングと、
OS からの URL 受信配線のみを担当する。

## 2. 受信経路: 二重登録

AppKit + `MenuBarExtra`（`WindowGroup` を持たない）構成のため、SwiftUI の `.onOpenURL` は使えない。
Chirami と同じ二重登録パターンを踏襲する。

1. **`NSApplicationDelegate.application(_:open:)`** — `open "kikimi://..."` やアイコンダブルクリック等、
   通常の URL オープン経路
2. **`NSAppleEventManager`（`kInternetEventClass`/`kAEGetURL`）** — `AppDelegate.init()` で
   `setEventHandler(_:andSelector:forEventClass:andEventID:)` を登録。古い呼び出し経路（AppleScript
   `open location` 等）や、`application(_:open:)` が呼ばれないケースへのフォールバック

両経路とも最終的に同じ `routeIncomingURLs(_ urls: [URL])` に委譲し、二重実装を避ける。

## 3. URL ルーティング（純粋関数）

```swift
enum KikimiURLRoute: Equatable {
    case newWindow(basedOn: String?)
    case recordQuick

    static func parse(_ url: URL) -> KikimiURLRoute?
}
```

- `scheme` は大文字小文字を無視して `kikimi` と比較
- `host` + `path` の組み合わせで判定: `("window", "/new")` → `.newWindow`、`("record", "/quick")` → `.recordQuick`
- `.newWindow` は `based_on` クエリパラメータを読む。**値が空文字列（`?based_on=`）の場合は `nil` 扱い**
  （「based_on を指定しない」と等価に倒す。空文字列をそのまま `SessionStore.createDraftSession(basedOn:)` に
  渡すと `SessionIdValidation.validate` が空文字列を拒否しエラーになってしまうため、ここで正規化する）
- `based_on` の値自体（実在するセッションか、セッションIDとして正しい形式か）はここでは検証しない。
  下流（`SessionStore.createDraftSession(basedOn:)`）の既存バリデーション・フォールバックにそのまま委譲する
  （4章参照）
- 上記に一致しない URL（未知の scheme・host・path、`?based_on=` 以外の余計なクエリを含む場合も許容し無視）は
  `nil` を返す。ログ出力は呼び出し側（`AppDelegate`）の責務とし、この関数自体は副作用を持たない
  純粋関数のまま保つ（テスト容易性のため、`TranscriptRowList`/`SessionListGrouping` と同じ設計方針）

## 4. エラー・検証方針

| 状況 | 挙動 | ログレベル |
|---|---|---|
| 未知の scheme/host/path | `KikimiURLRoute.parse` が `nil` を返し、`AppDelegate` は何もせず無視する。**新規ウィンドウ作成にフォールバックしない**（意図しないセッション作成を避けるため） | `.warning` |
| `based_on` が `SessionIdValidation` に違反する形式（空文字列以外の不正値、例: `/`を含む） | `SessionStore.createDraftSession(basedOn:)` が `.invalidSessionId` を throw。`AppDelegate` はこれを catch してログを出すのみで、プレーンな新規ウィンドウにフォールバックしない（誤った ID を渡した呼び出し元に気付けなくなるため） | `.warning` |
| `based_on` が形式は正しいが実在しないセッションID | `SessionStore` 側の既存フォールバック（`loadInitialContext`/`loadInitialSummaryTemplate` がグローバル既定値にフォールグレードし `.warning` を出す。07-session-store.md 8章）がそのまま働く。ウィンドウ自体は正常に作成される | `.warning`（`SessionStore` 側で出力済み） |
| `kikimi://record/quick` が Recording 中に呼ばれる | `WindowManager.quickRecord()` が `.anotherSessionRecording` を throw（既に `.warning` ログ済み、06-ui-panels.md 11章 #13）。`AppDelegate` は新規ウィンドウを作らず、`NSSound.beep()` で非侵襲な音のみのフィードバックを返す。メニューバー常駐アプリの性質上 `NSAlert` 等のモーダル通知は出さない | 追加ログなし（重複を避ける） |
| その他 `WindowManager` からの想定外エラー | catch して `.error` ログのみ。ユーザー通知はしない（Raycast 経由の非対話的な呼び出しのため、UI 側にダイアログを出す先がない） | `.error` |

## 5. 実装配置

- `Kikimi/Window/KikimiURLRoute.swift` — 3章の純粋な enum + `parse(_:)`（副作用なし、`KikimiTests` から直接テスト）
- `Kikimi/KikimiApp.swift` の `AppDelegate` — `application(_:open:)`・`handleGetURLEvent(_:withReplyEvent:)`・
  `routeIncomingURLs(_:)`・`route(_:)`（`KikimiURLRoute` → `WindowManager` 呼び出しの実行部分）を追加

`routeIncomingURLs`/`route(_:)` 自体はテスト対象にしない（`WindowManager.shared` シングルトン・実ファイル I/O
に依存するため、06-ui-panels.md 12章と同じ理由でレイヤ2 `kikimi-verify` skill の担当とする）。

## 6. project.yml / Info.plist との対応

`CFBundleURLTypes`（scheme `kikimi`）は既に `project.yml` と `Kikimi/Info.plist` の両方に宣言済み
（`Kikimi/Info.plist` は `.mise/tasks/build/_default` が `swift build` の実行成果物に直接コピーする対象
であり、xcodegen 生成物ではなく手で編集する正のファイルである点に注意）。本ドキュメントの実装で
追加のプロパティリスト変更は不要。

## 7. テスト容易性

- レイヤ1: `KikimiURLRoute.parse(_:)` を `KikimiTests/Window/KikimiURLRouteTests.swift` で網羅する
  - `kikimi://window/new` → `.newWindow(basedOn: nil)`
  - `kikimi://window/new?based_on=2026-07-01T14-30-00_a1b2c3d4` → `.newWindow(basedOn: "...")`
  - `kikimi://window/new?based_on=` → `.newWindow(basedOn: nil)`（空文字列の正規化）
  - `kikimi://record/quick` → `.recordQuick`
  - 未知の scheme（`https://...`）、未知の host（`kikimi://unknown/new`）、未知の path
    （`kikimi://window/other`）→ すべて `nil`
- レイヤ2: `kikimi-verify` skill から `open "kikimi://window/new"` 等を実行し、セッションフォルダが
  新規作成されることを確認する（Draft ウィンドウのスクリーンショットまでは検証しない。ウィンドウ生成の
  実処理は既に 06-ui-panels.md のテストが担当しているため、ここでは「URL 経由で到達できること」のみを見る）

## 8. 将来検討（範囲外）

- 公式 Raycast Extension（Quick Link の代わりに TypeScript コマンドを配布）
- CLI（`kikimi` コマンドで同等の操作をターミナルから叩けるようにする）
- `kikimi://window/open?session=<id>` のような既存セッションを開く用途の URL（kikimi.md 10章に明記が
  ないため、現時点では未実装。必要になった時点で `KikimiURLRoute` にケースを追加する）
