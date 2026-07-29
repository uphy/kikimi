# 17. Session Window UX リデザイン詳細設計

Session Window の UX リデザインの詳細設計。**本ドキュメントは `06-ui-panels.md` の §3（タブ構成）・
§6.2（Prep タブ）・§6.4（Summary/Watchers タブ）、および `05-watcher-runner.md` §10.3
（Prep タブの Watchers 管理 UI）を supersede する。**

---

## 1. 目的と背景

現行の Session Window は「4 タブ（Prep/Transcript/Summary/Watchers）+ Prep 内 3 領域
（Context / Summary Template / Watchers）」で、以下の問題があった:

1. 新規 Draft ウィンドウを開いた瞬間に Mustache 生コード（Summary Template）が視覚的主役になる
2. 内部語彙（Prep / Context / refinement / バッチ / preset / local）がそのまま UI に露出
3. Watchers が Prep 内セクションと専用タブの 2 箇所に露出（タブ側の空状態は Prep へのリダイレクト文のみ）
4. タブが処理パイプラインの写像で、ユーザーの時間軸（会議前→中→後）と一致しない
5. 実装都合の要素（KB カウンタ・disabled の「初期値に戻す」）が常時表示

## 2. 決定事項（確定済み・変更不可の要件）

| # | 決定 |
|---|---|
| R1 | Draft（未録音）中は **タブバーを出さず専用の準備画面** を表示。録音開始でタブ UI に遷移 |
| R2 | Transcript / Summary タブを **「会議」1 タブに統合**し、**2 ペイン + 3 状態セグメント切替**（書き起こしのみ / 両方 / サマリのみ）にする。タブは `準備 / 会議 / Watchers` の 3 つ |
| R3 | **Summary は会議中にも見れる**こと（不変条件）。既定ペインモードは「両方」 |
| R4 | 状態遷移でのタブ自動切替を入れる（録音開始 → 会議タブ、会議終了 → サマリペインを可視化）。**遷移の瞬間のみ**で、以降の手動操作には介入しない |
| R5 | Watchers の管理 UI（有効化・追加・編集・fork・削除・昇格）を **Watchers タブに集約**し、準備画面からセクションを撤去（Draft 中は準備画面の「詳細オプション」から同じ管理 UI に到達できる） |
| R6 | 「Watchers」の呼称は英語のまま。タブ名は `準備 / 会議 / Watchers` |
| R7 | Summary Template 編集は準備画面内の **DisclosureGroup（既定閉）** に格納 |
| R8 | quick wins: Context プレースホルダ / ヒント文の Recording 中限定化と平易化 / KB カウンタは 80% 超過時のみ / 「初期値に戻す」非表示 / サマリ未生成時は「サマリ全文再生成」非表示 / ボタン文言の平易化 |

## 3. 画面構成（最終形）

### 3.1 Draft（`meta.state == .draft`）: 準備専用画面

```
┌──────────────────────────────────────────────────┐
│ 無題の会議 ✎                  [🎙][🔊] [● 録音開始] │   ← ヘッダは現行と共通
├──────────────────────────────────────────────────┤
│ 事前メモ                                          │
│ ┌──────────────────────────────────────────────┐ │
│ │ (placeholder: 参加者・アジェンダ・専門用語を書いて  │ │
│ │  おくと、書き起こしの整形とサマリの精度が上がります) │ │
│ └──────────────────────────────────────────────┘ │
│                                                  │
│ ▸ サマリの構成をカスタマイズ        （DisclosureGroup）│
│ ▸ Watchers                       （DisclosureGroup）│
│                                                  │
│                            [他セッションから複製…]  │
└──────────────────────────────────────────────────┘
```

- タブバーなし。ヘッダ（タイトル・音声入力・録音開始）は現行 `header` をそのまま使う
- 「事前メモ」= 現行 Context エディタ。画面の主役として最大の面積を取る
- 「サマリの構成をカスタマイズ」を開くと Summary Template エディタ + 使用可能変数ヘルプ
- 「Watchers」を開くと Watchers タブと同じ管理コンポーネント（§5.4）を埋め込み表示
- フッタは「他セッションから複製…」のみ（「初期値に戻す」は撤去、R8）

### 3.2 Recording / Paused / Ended: 3 タブ

```
┌──────────────────────────────────────────────────┐
│ [ 準備 ] [ 会議 ] [ Watchers ]                     │
├──────────────────────────────────────────────────┤
│ デイリースクラム    [■ 一時停止] [⏹ 会議終了]  25:12  │
├──────────────────────────────────────［▤|▥|▦]──┤   ← 会議タブのみ
│ 書き起こし                  │ サマリ                │
│ 14:30:05 (mic) …           │ ## 概要              │
│ 14:30:08 (システム) …       │ …                    │
└────────────────────────────┴─────────────────────┘
```

- **準備タブ**: Draft 専用画面と同じコンテンツ（§5.2 `PrepContentView`）。ただし
  Watchers の DisclosureGroup は置かない（Watchers タブがあるため）
- **会議タブ**: §5.3 `MeetingTabView`。ペイン切替セグメント + HSplitView
- **Watchers タブ**: 結果表示（既存サブタブ）+ 管理セクション（§5.4）

## 4. 型・状態の変更

### 4.1 `MeetingWorkspaceTab`（`Kikimi/Config/AppState.swift`）

```swift
enum MeetingWorkspaceTab: String, Codable, CaseIterable, Sendable, Identifiable {
    case prep
    case meeting
    case watchers

    var title: String {
        switch self {
        case .prep: return "準備"
        case .meeting: return "会議"
        case .watchers: return "Watchers"
        }
    }
}
```

- `transcript` / `summary` ケースは削除。**enum 自体は 3 ケースの strict なまま**にし、
  旧値の移行は `WorkspaceWindowState` のカスタムデコード（§4.3）で行う

### 4.2 `MeetingPaneMode`（新設、`AppState.swift` に併置）

```swift
/// 会議タブのペイン表示モード。ウィンドウごとに state.yaml へ永続化する。
enum MeetingPaneMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case transcript   // 書き起こしのみ
    case both         // 2 ペイン（既定）
    case summary      // サマリのみ
}
```

### 4.3 `WorkspaceWindowState` の移行つきデコード

- stored property 追加: `var meetingPaneMode: MeetingPaneMode`（CodingKey `meeting_pane_mode`）
- **カスタム `init(from:)`** で旧 `active_tab` 値を移行する:

| 旧 `active_tab`（raw string） | 新 `activeTab` | 新 `meetingPaneMode` |
|---|---|---|
| `prep` | `.prep` | `.both`（既定） |
| `transcript` | `.meeting` | `.transcript` |
| `summary` | `.meeting` | `.summary` |
| `watchers` | `.watchers` | `.both`（既定） |
| `meeting`（新値） | `.meeting` | `meeting_pane_mode` キーがあればその値、なければ `.both` |
| 不明値 | `.prep` にフォールバック | `.both` |

- `meeting_pane_mode` キーが存在する場合はそちらを優先（新形式の読み込み）
- エンコードは常に新形式（`active_tab: meeting` + `meeting_pane_mode: ...`）
- 既定値: 新規ウィンドウは `activeTab = .prep` / `meetingPaneMode = .both`

### 4.4 `MeetingWorkspaceViewModel` の追加状態

```swift
@Published var meetingPaneMode: MeetingPaneMode = .both
/// サマリペインが見えていない間にサマリが更新されたら true（セグメントの「サマリ」アイコンにドット表示）
@Published var summaryHasUnseenUpdate: Bool = false
/// Draft 専用画面を出すかどうか。meta.state == .draft と同値
var isDraft: Bool { meta.state == .draft }
```

- `meetingPaneMode` は `MeetingWorkspaceWindowController` の save/restore に `activeTab` と
  同様に配線する（`MeetingWorkspaceWindowController.swift:98-104` の restore、`:248` 付近の save）

### 4.5 挙動ルール

| イベント | 挙動 |
|---|---|
| 録音開始成功（`startRecording` の成功パス） | `activeTab = .meeting`。`meetingPaneMode` は記憶値を維持 |
| 会議終了完了（`endMeeting` の成功パス） | `activeTab = .meeting`。`meetingPaneMode == .transcript` なら `.both` に変更（サマリを可視化）。`.both`/`.summary` はそのまま |
| サマリ更新（`summaryMarkdown` が新値になった時） | サマリペインが不可視（`activeTab != .meeting || meetingPaneMode == .transcript`）なら `summaryHasUnseenUpdate = true` |
| サマリペインが可視になった時（タブ切替 or ペインモード変更） | `summaryHasUnseenUpdate = false` |
| seg ID ジャンプ（`jumpToTranscriptSegment`、現行 `MeetingWorkspaceViewModel+Watchers.swift:195` の `activeTab = .transcript`） | `activeTab = .meeting`。`meetingPaneMode == .summary` なら `.both` に変更してからスクロール |
| Draft → Recording 遷移 | ビューが専用画面 → タブ UI に切り替わる（`isDraft` の変化で自動） |
| Ended → 再開（`reopenRecording`） | タブ UI のまま（Draft には戻らないので専用画面には戻らない） |

自動切替は上表のイベント時のみ。それ以外でコードから `activeTab` / `meetingPaneMode` を
書き換えてはならない（ユーザーの手動操作を尊重する不変条件）。

## 5. View の変更

### 5.1 `MeetingWorkspaceView`（ルート）

```swift
var body: some View {
    VStack(spacing: 0) {
        header          // 現行のまま（タイトル・バッジ・音声入力・録音コントロール）
        Divider()
        if !viewModel.banners.isEmpty { bannerList; Divider() }
        if viewModel.isDraft {
            PrepContentView(..., showsWatchersSection: true)   // Draft 専用画面
        } else {
            TabView(selection: $viewModel.activeTab) { ... }   // 3 タブ
        }
    }
}
```

- タブは `準備`（`PrepContentView(showsWatchersSection: false)`）/ `会議`（`MeetingTabView`）/
  `Watchers`（`WatchersTabView`）
- Draft 中に他ウィンドウが Recording でも専用画面のまま（録音開始ボタンが disabled になるだけ。現行どおり）

### 5.2 `PrepContentView`（`PrepTabView` を改名・再構成）

現行 `PrepTabView.swift` をベースに以下を変更:

- **改名**: `PrepTabView` → `PrepContentView`（Draft 専用画面とタブの両方で使うため）。
  ファイル名も `PrepContentView.swift` に変更
- **レイアウト**: VSplitView（Context/Template の 2 分割）をやめ、単一 `ScrollView` +
  `VStack` にする:
  1. 「事前メモ」ラベル + Context エディタ（`minHeight: 200`、主役）
  2. `DisclosureGroup("サマリの構成をカスタマイズ")`（既定閉）: Summary Template エディタ
     （`minHeight: 160`）+ 使用可能変数のキャプション
     （`{{title}} {{overview}} {{decisions}} {{action_items}} {{participants}}`）
  3. `showsWatchersSection == true` のときのみ `DisclosureGroup("Watchers")`（既定閉）:
     `WatcherManagementSection`（§5.4）を埋め込み
- **B-1**: Context エディタにプレースホルダ「参加者・アジェンダ・専門用語を書いておくと、
  書き起こしの整形とサマリの精度が上がります」。`PlainTextEditor` に
  `var placeholder: String?` を追加して実装（§5.5）
- **B-2**: ヒント文は **Recording / Paused 中のみ**表示し、文言を
  「ここの変更は次のサマリ更新から反映されます。書き起こしの整形には少し遅れて反映されます。」
  に変更。表示判定のため `isRecordingActive: Bool`（または同等の状態）をパラメータで受け取る
- **B-3**: `ByteCountLabel` は使用量が上限の 80% を超えたときのみ表示（超過時の赤色表示は現行維持）
- **B-4**: 「初期値に戻す」ボタンを削除（disabled 常設をやめる。設定機能実装時に再導入）
- **Watchers セクション（現行 `watchersSection`）は本体から削除**し、`WatcherManagementSection`
  として切り出す（§5.4）
- 「他セッションから複製…」フッタと `DuplicateFromSessionSheet` は現行のまま維持

### 5.3 `MeetingTabView`（新規、`Kikimi/Views/MeetingWorkspace/MeetingTabView.swift`）

```
┌［📋]──────────────────────────────［▤|▥|▦]──┐   ← ツールバー行（左端コピー・右寄せ表示切替）
│ TranscriptTabView │ SummaryTabView            │   ← HSplitView（mode == .both）
└───────────────────┴───────────────────────────┘
```

- ツールバー行: 左端にコピーボタン（**改訂**: `docs/design/37-transcript-markdown-copy.md` §3.3）、
  右寄せで 3 つの toggle ボタン群（`Picker`（`.segmented`, labelsHidden）でも可）。
- **ボタン一覧と AX 契約**（kikimi-verify 用。ヘッダのボタンラベル契約と同じ流儀で `.help` +
  `.accessibilityLabel` を完全一致で付ける）:

  | ボタン | 位置 | アイコン（SF Symbols） | AX 契約（`.help` = `.accessibilityLabel`） |
  |---|---|---|---|
  | コピー | ツールバー左端 | `doc.on.doc`（コピー成功後 1.5 秒 `checkmark` に切替、TC11） | `Markdown をコピー` |
  | 書き起こしのみ表示 | 右寄せ | `list.bullet.rectangle` | `書き起こしのみ表示` |
  | 両方表示 | 右寄せ | `rectangle.split.2x1` | `両方表示` |
  | サマリのみ表示 | 右寄せ | `doc.text` | `サマリのみ表示` |

  コピーボタンの primary action（クリック）は全体をコピー（⌘⇧C と同じ）。ドロップダウンで
  「書き起こしのみ」「サマリのみ」も選べる（TC6）。

- **更新ドット**: `summaryHasUnseenUpdate == true` のとき「サマリのみ表示」アイコンの右肩に
  小さな `Circle()`（accent color, 6pt）を重ねる。セグメント標準コントロールでドットを重ねられない
  場合はカスタムボタン群で実装してよい
- コンテンツ:
  - `.transcript`: `TranscriptTabView` のみ（全幅）
  - `.summary`: `SummaryTabView` のみ（全幅）
  - `.both`: `HSplitView { TranscriptTabView...; SummaryTabView... }`、
    初期比率 6:4、各ペイン `minWidth: 240`
- `TranscriptTabView` / `SummaryTabView` は**無変更で再利用**する（配線パラメータは
  現行 `MeetingWorkspaceView.tabContent(for:)` の `.transcript` / `.summary` ケースから移設）

### 5.4 `WatcherManagementSection`（新規）+ `WatchersTabView` 改修

- 現行 `PrepTabView` の `watchersSection` / `watcherRow` / 各シート
  （`NewLocalWatcherSheet` / `AddPresetWatcherSheet` / `WatcherEditSheet` / 削除・昇格 alert）を
  `WatcherManagementSection`（独立 View、`Kikimi/Views/MeetingWorkspace/WatcherPrepSheets.swift`
   近傍か新ファイル）に移設。閉包パラメータ群（`onSetWatcherEnabled` ほか）は現行のまま
- **文言変更（R8）**: `+ 新規 local watcher` → `新規作成`、`+ preset から追加` →
  `プリセットから追加`、origin 表示 `(preset)` → `共通`、`(local)` → `この会議のみ`、
  `(見つかりません)` は現行のまま
- **`WatchersTabView`**:
  - 有効 Watcher が 1 つ以上: 現行のサブタブ + 結果表示の下部に `DisclosureGroup("管理")`
    （既定閉）で `WatcherManagementSection` を置く
  - 空状態: 「この会議で追跡したい観点（TODO 追跡・確認事項チェックなど）を追加できます。」
    の説明文 + `WatcherManagementSection` を直接表示（リダイレクト文
    「Prep タブで追加してください」は廃止。`WatchersTabView.swift:159`）
- ViewModel 側の既存メソッド（`setWatcherEnabled` / `forkPresetWatcher` / …）は無変更。
  配線を `MeetingWorkspaceView` から渡す

### 5.3.1 Transcript 行の 2 行レイアウト

2 ペイン化で書き起こしペインが約 400pt になり、現行の横 1 列レイアウト
（時刻 64pt + アイコン 16pt + 話者ラベル固定 100pt + 本文 + 再生 20pt）では本文の有効幅が
半分以下になる。**ヘッダ行 + 本文行の 2 行構成**に変更してペイン全幅を本文に使う。

```
00:00:54  🔊 uphy                                    ▶   ← ヘッダ行（caption、再生は右端）
[stub] うちの中学は弁当制で持っていけない場合は…            ← 本文行（全幅で折り返し）
```

- **ヘッダ行**: 時刻（monospaced caption）+ 話者アイコン + 話者ラベル（**固定 100pt 幅を廃止**し
  自然幅。`SpeakerLabelColumnView` と rename popover はヘッダ行に残す）+ `Spacer()` +
  再生ボタン（ホバー/再生中のみ可視、幅予約は現行踏襲）
- **本文行**: `Text(displayText)` を `maxWidth: .infinity` で全幅に。色ルール
  （raw/refining = secondary、refined = primary）は現行のまま
- **volatile 行**（`TranscriptVolatileRowContentView`）も同じ 2 行形式に揃える
  （ヘッダ行は時刻なし・アイコンのみ）
- 行間: 行全体の `padding(.vertical)` を 2 → 4 に広げ、行の区切りを視認しやすくする
  （ヘッダ行と本文行の間は詰める）
- `speakerLabelColumnWidth`（100pt 固定）と volatile 行側の対応する spacer は削除
- ホバー判定（`contentShape(Rectangle())` + `onHover`）は行全体（2 行分）を対象にする
- 同一話者の連続行でヘッダを省略する「ぶら下げ」最適化は**今回はやらない**（将来の磨き込み）

### 5.5 `PlainTextEditor` プレースホルダ対応

- `var placeholder: String?` を追加。`NSTextView` にはネイティブの placeholder API がないので、
  text が空のとき `.secondaryLabelColor` のオーバーレイ `Text` を重ねる
  （SwiftUI 側 `ZStack(alignment: .topLeading)` でよい。`allowsHitTesting(false)` にする）

### 5.6 `SummaryTabView`（B-6）

- `summaryMarkdown == nil` のとき「サマリ全文再生成」ボタンを出さない
  （空状態プレースホルダ「サマリはまだ生成されていません」は現行のまま）

## 6. 文言の対訳（本設計で変更するラベル一覧）

| 現状 | 変更後 | 箇所 |
|---|---|---|
| Prep / Transcript / Summary / Watchers（タブ） | 準備 / 会議 / Watchers（3 タブ） | `MeetingWorkspaceTab.title` |
| Context | 事前メモ | `PrepContentView` |
| Summary Template | サマリの構成をカスタマイズ（DisclosureGroup ラベル） | 同上 |
| summary は次回更新で反映、refinement は最大10バッチ後に反映されます。 | ここの変更は次のサマリ更新から反映されます。書き起こしの整形には少し遅れて反映されます。（Recording/Paused 中のみ表示） | 同上 |
| + 新規 local watcher | 新規作成 | `WatcherManagementSection` |
| + preset から追加 | プリセットから追加 | 同上 |
| (preset) / (local) | 共通 / この会議のみ | 同上 |
| 有効な Watcher がありません。Prep タブで追加してください。 | この会議で追跡したい観点（TODO 追跡・確認事項チェックなど）を追加できます。 | `WatchersTabView` |

ヘッダのボタンラベル契約（`録音開始` / `一時停止` / `会議終了` / `再開` / `録音再開` /
`タイトルを編集` / `録音入力を設定` / `タイトル案を採用`）は**変更しない**（kikimi-verify の AX 契約）。

## 7. テスト計画

### 7.1 単体テスト（swift-testing / XCTest、既存テストの修正含む）

- `WorkspaceWindowState` デコード移行: §4.3 の表の全行（旧 `transcript` → `.meeting` +
  `.transcript`、旧 `summary` → `.meeting` + `.summary`、新形式 round-trip、不明値フォールバック、
  `meeting_pane_mode` 欠落時の `.both` 既定）
- エンコードが常に新形式であること（`active_tab: meeting` + `meeting_pane_mode`）
- ViewModel: 録音開始成功で `activeTab == .meeting`、会議終了で `.transcript` → `.both` 昇格、
  `jumpToTranscriptSegment` で `.summary` → `.both`、`summaryHasUnseenUpdate` の set/clear 条件
- 既存テストで `MeetingWorkspaceTab.transcript` / `.summary` を参照している箇所
  （`MeetingWorkspaceViewModelTests` など）を新 enum に追従
- `MeetingWorkspaceTab.allCases` が 3 ケースであること / `title` が `準備`/`会議`/`Watchers`

### 7.2 kikimi-verify（レイヤ 2、実装完了後にメインエージェントが実施）

- 新規 Draft ウィンドウ: タブバーが無く、事前メモ + 2 つの DisclosureGroup + 複製ボタンのみ
- プレースホルダ表示 / DisclosureGroup 展開で Summary Template・Watchers 管理が出る
- 録音開始 → タブ UI に遷移し会議タブがアクティブ / ペイン切替 3 状態が動く
- 旧 `state.yaml`（`active_tab: transcript`）を持つセッションを開いて会議タブ + 書き起こしのみで復元
- Watchers タブ空状態に管理 UI が直接出る
- crash_diff / verify_session で回帰確認

## 8. 他ドキュメントへの波及（本設計とセットで改訂）

- `kikimi.md` 9 章（Prep タブでの管理 UI → Watchers タブ + Draft 詳細オプション）、
  10 章（Session Window のタブ構成・モックアップ）、12 章（state.yaml サンプル）
- `docs/design/06-ui-panels.md` 冒頭 + §6.2 / §6.4 に supersession 注記
- `docs/design/05-watcher-runner.md` §10.3 に supersession 注記

## 9. スコープ外（本設計ではやらない）

- Settings ウィンドウへの既定テンプレ編集の移設（B-5 の折りたたみで対応と決定済み）
- 「Watchers」の日本語化（英語のままと決定済み）
- タブバッジ以外の通知（A-3 はセグメントアイコンのドットとして吸収済み）
- `06-ui-panels.md` 全体の書き直し（注記による supersede に留める）
