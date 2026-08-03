# 48. 会議中の話者リネームの入力補完

会議ウィンドウの書き起こし行から開く話者リネーム popover（`docs/design/13-speaker-diarization.md`
§6.1、`Kikimi/Views/MeetingWorkspace/RenameSpeakerPopoverView.swift`）の名前入力に、入力中の
インライン候補リストとキーボード選択を足す設計。

参照元: `docs/design/13-speaker-diarization.md`（§4.4/§6.1 の既存話者ピッカー）,
`docs/design/20-voiceprint-misassignment-mitigation.md`（§4 の名前正規化、§5.2 の声紋類似度順）,
`docs/design/22-participant-hints.md`（§4.3/§5 の suggest box — 本設計が踏襲する既存パターン）。

## 1. 現状と課題

リネーム popover には話者名を決める導線が2つある。

| 導線 | 実装 | 挙動 |
|---|---|---|
| 自由入力 | `TextField("名前を入力")` | 打ち込んで Enter か「適用」。`NormalizedRenameTarget.resolve` が trim 完全一致で既存話者に寄せる |
| 既存話者ピッカー | `KnownSpeakerPickerView` の `Menu`（「既存の話者から選択…」） | 登録済み話者を**全件**、声紋類似度順（`KnownSpeakerSort.sorted`）で並べて選ぶ |

課題は、両者の間が抜けていること。

- 名前を数文字打っても候補は出ない。打ち切って完全一致させるか、Menu を開いて全件から探すかの二択
- 会議中に話者が10人を超えると Menu の全件走査は実用的でない。一方で自由入力は、登録名を
  うろ覚えだと（「山田太郎」を「山田」と打つ）別人として新規登録されてしまう
- 準備タブの「参加者を追加」（`PrepContentView.swift` の `ParticipantsSectionView`）には既に
  入力連動の候補リストがあり、**会議前と会議中で話者を指名する操作感が食い違っている**

## 2. 設計

準備タブの suggest box と同じ「入力に連動するインライン候補リスト」を、リネーム popover の
2つの入力欄（スロット全体の「すべての発言に適用」と「この発言だけ」）の両方に足す。
候補はキーボードでも選べるようにする。

### 2.1 候補の選び方と並び順

新規の純粋型 `SpeakerSuggestList`（`Kikimi/ViewModels/SpeakerSuggestList.swift`）に閉じ込める。
I/O は持たず、呼び出し側が渡した `knownSpeakers`（`MeetingWorkspaceViewModel.knownVoiceprintSpeakers`）
を絞って並べるだけ。`KnownSpeakerSort`/`NormalizedRenameTarget` と同じ位置付けの決定ヘルパ。

- **絞り込み**: 入力を `SpeakerName.trimmed` した文字列で `localizedCaseInsensitiveContains`
  （準備タブと同じ判定）。空入力なら候補なし
- **並び順**: 前方一致（`localizedCaseInsensitiveCompare` ベースの prefix 判定）のグループを先、
  部分一致のみのグループを後に置く。各グループ内は `KnownSpeakerSort.sorted(speakers:slotEmbedding:)`
  にそのまま委譲する（design 20 §5.2 の声紋類似度順、embedding が無ければ `updatedAt` 降順）。
  「打った文字に近い順」と「この声に近い順」の両方を、前者優先で満たす
- **件数上限**: 5 件。popover は `frame(width: 300)` の固定幅で、候補が増えるほど縦に伸びて
  書き起こしを覆う。打ち切った分は「他 N 件は『既存の話者から選択…』から」の caption で明示する
  （黙って切らない）
- **「新しい名前で登録」行**: 入力が既知話者の**どれとも** trim 完全一致しないときだけ出す
  （準備タブの `showsRegisterNewRow` と同じ判定）。押すと `.newName` を submit する。
  自由入力＋Enter と同じ経路なので、`NormalizedRenameTarget` の正規化・曖昧解決はそのまま効く

### 2.2 キーボード操作

`SpeakerNameSuggestField`（`Kikimi/Views/MeetingWorkspace/SpeakerNameSuggestField.swift`、新規）が
`TextField` と候補リストをまとめて持ち、選択位置 `selectedIndex: Int?` を `@State` で管理する。

| キー | 挙動 |
|---|---|
| ↓ | 候補を1つ下へ。未選択なら先頭を選ぶ。末尾で止まる（循環しない） |
| ↑ | 候補を1つ上へ。先頭からさらに上で未選択に戻る（＝自由入力の状態） |
| Enter | 候補を選択中ならその候補を確定（`.existingSpeaker` / 「新しい名前で登録」行なら `.newName`）。未選択なら従来どおり自由入力を `.newName` で確定 |
| Esc | 候補リストを閉じる（`.handled` を返して popover 自体は閉じない）。候補が出ていなければ `.ignored` を返し、macOS 既定どおり popover が閉じる |

- 「新しい名前で登録」行も候補リストの最終要素として ↑↓ の対象に含める。行の並びと選択の動きを
  一致させ、`selectedIndex` の意味を「表示行の index」に統一する
- 選択位置の遷移は `SpeakerSuggestList.movedSelection(current:delta:count:)` に切り出して単体テスト
  する（View に埋めるとテストできない）
- 入力文字が変わったら選択位置をリセットする。候補の中身が変わっているのに index だけ残ると
  「見えている選択」と「確定される候補」がずれる
- 初期フォーカスは今回入れない。popover には最大3つの入力欄（mixed 行のスロット2つ＋
  「この発言だけ」）があり、どれに入れるべきかは操作意図次第で決め打ちできない

### 2.3 既存話者ピッカー（Menu）の扱い

**残す**。候補リストは入力があって初めて出るので、「名前を思い出せないので一覧から探す」用途と、
入力なしで声紋類似度順に全件を見る導線（design 20 §5.2）は Menu にしか無い。

### 2.4 スコープ外（明示）

- **準備タブの「参加者を追加」**: 既に候補リストがある。キーボード選択の追加は今回やらない
  （会議中の操作性が主題）。将来 `SpeakerNameSuggestField` へ寄せる余地は残す
- **Settings の話者タブ**: リネームは既存話者の改名であって候補から選ぶ操作ではない
- **あいまい一致**（表記ゆれ・読み仮名・ローマ字）: 部分一致のみ。`SpeakerName` の正規化は
  trim だけという既存の意味論（design 20 §4）を変えない

## 3. 実装対象ファイル

| ファイル | 変更内容 |
|---|---|
| `Kikimi/ViewModels/SpeakerSuggestList.swift` | 新規。候補の絞り込み・並び順・上限・選択位置遷移の純粋ロジック |
| `Kikimi/Views/MeetingWorkspace/SpeakerNameSuggestField.swift` | 新規。`TextField` ＋ 候補リスト ＋ キーボード操作の共通 View |
| `Kikimi/Views/MeetingWorkspace/RenameSpeakerPopoverView.swift` | `SlotRenameFieldView`/`SegmentOverrideFieldView` の `TextField` を `SpeakerNameSuggestField` に置き換え |
| `docs/design/13-speaker-diarization.md` | §6.1 の popover 説明に本設計へのリンクを追加 |

## 4. テスト

- `KikimiTests/ViewModels/SpeakerSuggestListTests.swift`（新規）
  - 空入力・空白のみの入力で候補が空になること
  - 大文字小文字を無視して部分一致すること
  - 前方一致が部分一致より先に来ること
  - 同グループ内が `KnownSpeakerSort` と同じ順（声紋距離昇順、embedding 無しは `updatedAt` 降順）
    になること
  - 上限 5 件で打ち切られ、打ち切り件数が返ること
  - `showsRegisterNewRow` が trim 完全一致の既存話者がいるときだけ false になること
  - `movedSelection` の境界（未選択から↓で 0、末尾で止まる、先頭から↑で nil、候補 0 件で常に nil）
- UI 動作確認（ユーザー）: 会議ウィンドウで話者ラベルをクリック → 数文字入力 → 候補が出る →
  ↑↓ で選び Enter で確定 → 書き起こしの表示名が変わる。Esc で候補だけ閉じ、もう一度 Esc で
  popover が閉じる
