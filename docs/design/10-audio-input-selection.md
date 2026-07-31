# 10. 録音入力設定（Audio Input Selection）詳細設計

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `kikimi.md` 6章（録音パイプライン）, 10章（Session Window ヘッダ）, 12章（`state.yaml`）。
関連設計: `01-audio-capture.md` 4章（デバイス方針: 現状は「選択 UI を持たない」）・9章（失敗モード）・12章（契約）、
`02-stt-pipeline.md`（`TranscriptPipeline`）、`06-ui-panels.md` 5.1章（`state.yaml` の所有）・6.1章（録音シーケンス）。
Chirami 参照実装: `Chirami/Transcript/AudioDeviceEnumerator.swift`（マイク列挙）・
`AudioProcessEnumerator.swift`（プロセス列挙）・`SystemAudioCapture.swift`（include-list tap）。

> **注**: 本機能は kikimi.md 執筆時点のスコープ（`01-audio-capture.md` 4章「選択 UI を持たない」）を
> ユーザー要件により拡張するもの。実装確定後に以下を改訂する:
> kikimi.md 10章（ヘッダ）・12章（state.yaml サンプル）、`01-audio-capture.md` 4章（デバイス方針）・
> 9章（mic 必須原則の表現）、`06-ui-panels.md` 3章/5.1章（`AppState` の所有権）、および実装コメント
> `MicrophoneSource.swift`（「deviceUID は常に nil」）・`AppState.swift`（「WindowManager のみが読み書き」）。

## 1. 目的と要件

会議の入力ソースを録音のたびに選べるようにする。要件:

1. **マイク**: 有効/無効の切り替え。有効時は入力**デバイス**を選択できる
2. **システム音声**: 有効/無効の切り替え。有効時は対象**アプリケーション**を選択できる
   （Chirami の UI と同じ軸: 「All System Audio」または特定アプリ。出力デバイスではない）
3. **既定値は前回録音時の設定**: あるセッションで録音を完了したら、次に作る新しいセッションでも
   同じ有効/無効・選択が初期値になる（セッション横断のグローバル記憶）
4. **自動フォールバック**: 選択済みの対象が使えない状態なら、適切なタイミングで有効なもの
   （マイク: システムデフォルト入力 / システム音声: すべてのシステム音声）に自動で選び直す。
   録音開始の実行時点でもソースが本当に使えない場合（例: 入力デバイスがゼロ）はエラーにして
   録音を開始しない

### スコープ外

- 録音中の選択変更（Recording 中は設定 read-only）
- セッションごとに異なる設定の永続化（meta.json への記録はしない。記憶はグローバル1つ）
- config.yaml への設定追加（`AppConfig` 未実装。かつ「前回使ったもの」はユーザーが手で編集する設定
  ではなくアプリが管理する状態なので、実装後も `state.yaml` 側が正しい置き場所）
- システム音声の**出力デバイス単位**の選択（要件の軸はアプリ。デバイス軸は作らない）
- **複数アプリの同時選択**（選べるのは「すべて」または単一アプリ。複数選択は Phase 4 実戦後に検討）

## 2. 用語とデータモデル

### AudioInputSelection

「この録音で何をどこから取るか」を表す値型。UI・永続化・`AudioCapture` の三者で共有する
唯一のモデル。マイクとシステム音声で選択軸が違う（デバイス UID vs bundle ID）ため、
ソースごとに別の型にする。

```swift
/// Microphone choice. `deviceUid == nil` means "follow the system default input device".
struct MicSelection: Codable, Equatable, Sendable {
    var enabled: Bool
    var deviceUid: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case deviceUid = "device_uid"
    }
}

/// System audio choice. `bundleId == nil` means "All System Audio"
/// (the current global exclude-list tap). Non-nil limits capture to the processes
/// belonging to that application bundle.
struct SystemAudioSelection: Codable, Equatable, Sendable {
    var enabled: Bool
    var bundleId: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case bundleId = "bundle_id"
    }
}

struct AudioInputSelection: Codable, Equatable, Sendable {
    var mic: MicSelection
    var system: SystemAudioSelection

    /// Both sources enabled: default input device + all system audio.
    static let `default` = AudioInputSelection(
        mic: MicSelection(enabled: true, deviceUid: nil),
        system: SystemAudioSelection(enabled: true, bundleId: nil)
    )

    var hasEnabledSource: Bool { mic.enabled || system.enabled }
}
```

- `deviceUid` は CoreAudio の device UID。`AudioDeviceID` は再起動で変わり得るため永続化には
  UID を使う
- システム音声側は **bundle ID** で永続化する。Chirami は選択値を `pid:<PID>` で保持するが、
  PID はアプリ起動ごとに変わるためセッション横断の記憶（要件 3）には使えない。
  録音開始時に bundle ID → その時点の実プロセス（`AudioObjectID` 群）へ解決する（4章・5.1章）。
  同一 bundle ID の複数プロセス（ブラウザの helper 群など）は**すべて**タップ対象に含める

### 列挙コンポーネント（AudioInputEnumerator）

マイクデバイスとシステム音声プロセスの列挙を新規コンポーネント `AudioInputEnumerator` が担う。
どちらも Chirami に直接の先行実装がある。

```swift
struct AudioDeviceInfo: Equatable, Identifiable, Sendable {
    var id: String { uid }
    let uid: String
    let name: String
}

/// One selectable application (deduped by bundle id across its processes).
struct AudioProcessInfo: Equatable, Identifiable, Sendable {
    var id: String { bundleId }
    let bundleId: String
    let displayName: String   // NSRunningApplication.localizedName ?? bundleId
}

/// Stateless enumeration of selectable inputs; every call reads the current system state.
/// Protocol-backed so view-model tests can fake both lists (same DI pattern as
/// `AudioSourceCapturing`).
protocol AudioInputEnumerating: Sendable {
    func inputDevices() -> [AudioDeviceInfo]
    func systemAudioProcesses() -> [AudioProcessInfo]
}

struct AudioInputEnumerator: AudioInputEnumerating { ... }
```

- **マイク列挙**: Chirami の `AudioDeviceEnumerator.swift` を踏襲し
  `AVCaptureDevice.DiscoverySession` で入力デバイスを列挙する（`uid` は `uniqueID`。
  CoreAudio device UID と互換）。UID → `AudioDeviceID` の解決も同ファイルの
  `kAudioHardwarePropertyTranslateUIDToDevice` 実装を踏襲
- **プロセス列挙**: Chirami の `AudioProcessEnumerator.swift` を踏襲する
  （`kAudioHardwarePropertyProcessObjectList` で全プロセスオブジェクト取得 →
  `kAudioProcessPropertyPID` / `kAudioProcessPropertyBundleID` / `NSRunningApplication` で
  表示名解決 → `kAudioProcessPropertyIsRunningOutput` で「音声出力中」に絞る）。
  Kikimi 側の差分は2点: bundle ID が取れないプロセスは選択肢から除外する
  （bundle ID を永続化キーにするため）、および同一 bundle ID のプロセス群を
  `AudioProcessInfo` 1件に集約する
- `isRunningOutput` フィルタの妥当性（出力開始前の会議アプリが選択肢に出ない問題）は
  10章 Open Questions
- 増減のリアルタイム監視は MVP では持たない。ポップオーバーを**開くたびに列挙し直す**ことで
  代替する（10章 Open Questions）

## 3. 永続化（state.yaml）

「前回録音時の設定」はウィンドウ位置と同じくアプリ管理の状態なので `state.yaml` に置く。
`KikimiStateData` にキーを1つ追加する:

```yaml
# ~/.local/state/kikimi/state.yaml
windows: [ ... ]
session_list_window: { ... }
last_audio_input:
  mic:
    enabled: true
    device_uid: "BuiltInMicrophoneDevice"   # キー省略 = システムデフォルト入力
  system:
    enabled: true
    bundle_id: "us.zoom.xos"                # キー省略 = すべてのシステム音声
    # （Encodable は nil を encodeIfPresent でキーごと省略する。
    #   読み込みは explicit null / キー省略の両方を受ける）
```

```swift
struct KikimiStateData: Codable, Equatable, Sendable {
    var windows: [WorkspaceWindowState] = []
    var sessionListWindow: FloatingWindowState = .default
    var lastAudioInput: AudioInputSelection = .default

    enum CodingKeys: String, CodingKey {
        case windows
        case sessionListWindow = "session_list_window"
        case lastAudioInput = "last_audio_input"     // ← 既存の明示 CodingKeys への追加を忘れないこと
    }

    // Codable の synthesized init(from:) はプロパティ既定値を使わないため、custom init(from:) で
    // lastAudioInput を decodeIfPresent(...) ?? .default にする（下記「後方互換」参照）。
}
```

- **後方互換（必須）**: 既存ユーザーの `state.yaml` には `last_audio_input` キーが存在しない。
  synthesized デコーダのままだと `keyNotFound` で**全体のデコードが確定的に失敗**し、しかも
  `YAMLStore` はデコード失敗時に `loadFailed` を立てて**以後の `save()` を恒久的に拒否する**
  （壊れたファイルをデフォルトで上書きしないためのガード）。つまりウィンドウ復元が全滅した上、
  そのプロセス中の永続化がすべて黙って捨てられる。これを避けるため `KikimiStateData` に
  custom `init(from:)` を書き、`lastAudioInput = try container.decodeIfPresent(
  AudioInputSelection.self, forKey: .lastAudioInput) ?? .default` とする（キー欠損は
  フィールド単位でデフォルト補完。`loadFailed` に落ちるのは型不一致等の真の破損のみ）
- **書き込みタイミングは「録音開始が成功した直後」の1箇所のみ**（6章シーケンス参照）。
  ポップオーバーでの変更操作では書かない。Draft でいじっただけの選択は揮発し、
  「前回の**録音時**のもの」というユーザー要件の字義に一致する
- `06-ui-panels.md` 3章の「`AppState.shared` は `WindowManager` からのみ読み書きされる」という
  不変条件を本設計で改訂する: `lastAudioInput` に限り `MeetingWorkspaceViewModel` が
  読み書きする（読み: ウィンドウ生成時 / 書き: 録音開始成功時）。`windows` /
  `sessionListWindow` の所有は従来通り `WindowManager` のみ

## 4. 選択解決規則（フォールバック）

要件 4 の「選び直し」を、**検証タイミング + 実行時ガード**として定義する。
**マイクとシステム音声で検証タイミングが異なる**ことに注意:

| タイミング | マイク（deviceUid） | システム音声（bundleId） |
|---|---|---|
| ① ウィンドウ生成/再オープン時（hydrate） | `deviceUid` が現在の列挙結果に**存在しなければ `nil`（デフォルト）に書き換える**。UI 通知は出さない | **検証しない**（選択を保持）。アプリの起動/出力状態は揮発的で、「会議前に Zoom がまだ音を出していない」のは正常。ここで破壊的リセットすると毎セッション選び直しになり要件 3 が無意味化する |
| ② 録音開始時（`startRecording()` 冒頭） | ①と同じ解決をもう一度行う | `bundleId` をその時点のプロセス列挙に対して解決。**該当プロセスが1つもなければ `nil`（すべてのシステム音声）に書き換えて続行** + info ログ。会議音声を取り漏らすより広めに録るほうが安全側 |
| ③ 録音実行時ガード | 解決後もなおソースが使えない場合はエラーにして録音を開始しない（下表） | 同左 |

- ②の解決結果が実際に使われ、そのまま `lastAudioInput` として永続化される
- フォールバックは**破壊的**（選択状態を `nil` に書き戻す）。
  「AirPods で録っていたが今日は未接続 → デフォルトで録音 → 次回のデフォルトもデフォルトデバイス」
  「Zoom を選んでいたが起動前に録音開始 → 全体を録音 → 次回のデフォルトも全体」という挙動になる。
  非破壊（使えない間だけ一時的にデフォルトを使い、復帰したら戻す）は実装・表示とも複雑になるため
  採らない（要件 3・4 の字義通りの挙動を優先）

③のエラー条件（`recordingStartFailed` バナー、Draft に留まる）:

| 条件 | エラー |
|---|---|
| 両ソースとも `enabled == false` | 「入力がすべて無効です。マイクまたはシステム音声を有効にしてください」（UI は事前にボタンを disabled にするので防御的ガード） |
| マイク有効だが入力デバイスが1台も存在しない | 「利用できるマイクがありません」 |
| マイクが唯一の有効ソースで、`MicrophoneSource.start` が失敗 | 既存の `.microphonePermissionDenied` 等（現行と同じ） |
| システム音声が唯一の有効ソースで、tap 生成が失敗 | 新設 `.systemAudioStartFailed(message:)`（5.2章） |

## 5. AudioCapture 層の変更

### 5.1 API 変更

```swift
// AudioCapture
init(
    sessionDirectory: URL,
    selection: AudioInputSelection = .default,   // ← 追加
    config: AudioCaptureConfig = AudioCaptureConfig(),
    microphoneSource: AudioSourceCapturing? = nil,
    systemAudioSource: AudioSourceCapturing? = nil
)
```

- `AudioCaptureConfig` には足さない（config はフォーマット系チューニング値、selection は
  「この録音で何を取るか」で関心が違う）
- `MeetingWorkspaceViewModel.AudioCaptureFactory` の署名を
  `(URL, AudioInputSelection) -> RecordingAudioCapturing` に変更（テストの fake も追随）

**MicrophoneSource**: 予約済みの `init(deviceUID:)` 引数を実際に使うようにする。

- `deviceUID != nil` なら `kAudioHardwarePropertyTranslateUIDToDevice` で `AudioDeviceID` に解決し、
  `engine.inputNode` の audio unit に `kAudioOutputUnitProperty_CurrentDevice` を設定する。
  解決失敗（start までの間に抜かれた等）は `MicrophoneSourceError.engineFailed` 相当として扱わず、
  **警告ログの上でデフォルト入力にフォールバックして続行**する（録音を止めないことを優先）
- **順序制約**: デバイス設定は `inputNode.inputFormat(forBus: 0)` の読み取り・
  `AVAudioConverter` 生成・`installTap` より**前**に行うこと。後から設定すると converter/tap が
  旧デバイスのフォーマットで構築され、無音や変換エラーになる
- **無効フォーマットガード**: デバイス設定後の `inputFormat(forBus: 0)` が無効
  （`sampleRate == 0` 等。入力デバイスがゼロの状態で `installTap` に進むと Swift の `throws`
  ではなく Objective-C 例外でクラッシュし得る）なら `MicrophoneSourceError.engineFailed` を
  throw する。ViewModel の事前チェック（4章③）と `engine.start()` の間には
  モデルダウンロード等で分単位の隙間があり得るため、この防御は必須

**SystemAudioSource**: `init` に `includedBundleId: String? = nil` を追加。

- `nil` は現行のグローバルタップ（除外リスト方式、自プロセスのみ除外）— 「すべてのシステム音声」
- 非 `nil` の場合は `start()` 内でその時点のプロセスオブジェクトを列挙し、bundle ID が一致する
  **全プロセス**（helper 群含む）の `AudioObjectID` を集めて
  `CATapDescription(monoMixdownOfProcesses:)`（**include-list 方式**、`isExclusive = false`）で
  タップする。Chirami の `SystemAudioCapture.swift` がまさにこの include-list 方式の先行実装で、
  tap → aggregate device → IOProc の流れはそのまま流用できる
- 解決の結果**該当プロセスがゼロ**だった場合（4章②とこの `start()` の間にアプリが終了した等）は、
  新設 `SystemAudioSourceError.selectedAppNotRunning(bundleId)` を throw する。
  **グローバルタップへの暗黙フォールバックはしない**（意図的な非対称）:
  4章②の解決はユーザーに見える選択状態の書き換え + 永続化として行われるのに対し、
  `start()` 内での暗黙の広域化は「このアプリだけを録る」という選択を黙って「すべてを録る」に
  変えてしまい、録音対象外と考えていた音声まで記録するため。失敗は縮退/エラーとして明示的に扱う
  （5.2章のマトリクスに乗る: mic も有効なら `[.mic]` へ縮退、system 単独なら fatal）
- **include-list は start 時点のスナップショット**（`01-audio-capture.md` 4章に記載済みの
  Chirami 由来の既知の欠点）: 録音中に対象アプリが再起動すると新 PID のプロセスは捕捉されない。
  IOProc は無音で回り続けるため既存の stall 検出にも掛からない。MVP はこの制約を受容する
  （10章 Open Questions）

### 5.2 start() の挙動マトリクス

`start()` は `selection` に従い、**無効なソースはそもそも起動を試みない**（WAV ファイルも作らない。
権限プロンプトも発生しない — マイク無効ならマイク権限、システム音声無効なら System Audio
Recording 権限を要求しないことが副次的な利点）。

| mic | system | 挙動 |
|---|---|---|
| 有効 | 有効 | 現行と同一（mic 失敗は fatal、system 失敗は `[.mic]` に縮退 + `didDegrade`） |
| 有効 | 無効 | system 系を一切起動しない。`system.wav` なし。`running([.mic])`。**`didDegrade` は発火しない**（意図的な無効化は縮退ではない） |
| 無効 | 有効 | mic 系を一切起動しない。`mic.wav` なし。system の起動失敗は縮退先がないため fatal: 新設 `AudioCaptureError.systemAudioStartFailed(message:)` を throw |
| 無効 | 無効 | ViewModel 側でガード済みの前提だが、防御的に `.allSourcesUnavailable` を throw |

- 「マイクは（有効化されているなら）必須」という既存原則（`01-audio-capture.md` 9章）は
  **維持する**: mic が有効で start に失敗したら、system が成功していても従来通り fatal。
  本設計が変えるのは「**無効化されたソースは fatal 判定の分母から外れる**」ことだけであり、
  その帰結として mic 無効時に限り system が唯一の必須ソースになる（上表3行目）
- Recording 中の縮退（system stall 等）も従来通り。ただし mic 無効・system 単独録音で stall した
  場合、既存の縮退通知は文言が「マイクのみで記録します」前提（`didDegrade` 経由のバナー・ログとも）
  のため嘘になる。`activeSources` が空になるケースでは文言を分岐し
  「システム音声が停止しました。録音を停止して確認してください」とする。
  「録音は絶対に止めない」原則に従い自動停止はしない（自動停止の要否は 10章 Open Questions）
- `KIKIMI_TEST_INPUT` によるテスト用ソース差し替えも selection を尊重する（無効ソースには
  `TestFileAudioSource` を割り当てない）。これにより kikimi-verify で
  「マイクのみ録音 → セッションフォルダに `mic.wav` のみ」を決定的に検証できる

### 5.3 TranscriptPipeline への影響

**変更なし**。`TranscriptPipeline` は `didCapture` で届いたバッファを処理するだけなので、
起動されなかったソースのバッファは単に流れてこない。未使用側の `SttEngine` はアイドルのまま
（`prepare()` のモデルダウンロードは両ソース同一モデルで1回分のため無駄もない）。
`transcript.jsonl` の `speaker` には有効だったソースの値だけが現れる。

## 6. ViewModel / シーケンス

### 6.1 MeetingWorkspaceViewModel への追加

```swift
// 追加 @Published
@Published var audioInputSelection: AudioInputSelection = .default
@Published private(set) var availableInputDevices: [AudioDeviceInfo] = []
@Published private(set) var availableSystemAudioApps: [AudioProcessInfo] = []

// 追加 DI（既存 factory 群と同じパターン）
private let inputEnumerator: AudioInputEnumerating   // default: AudioInputEnumerator()
private let appState: AppState                        // default: .shared
```

- `hydrateFromSessionHandle()` で `appState.data.lastAudioInput` を読み、4章①の解決を適用して
  `audioInputSelection` に反映する。ただし既存の `recordingButtonState` と同じレースガードを置く:
  hydrate 完了前にユーザーがポップオーバーを開いて編集していた場合（`audioInputSelection` が
  `.default` から動いていた場合）は上書きしない
- `refreshAudioInputs()`: ポップオーバー表示時に呼ばれ、列挙し直して published 配列を更新する。
  4章①の解決（マイク UID の破壊的 `nil` 書き戻し）の再適用は
  **Draft / `disabledOtherRecording` のときのみ**。Recording / starting / stopping 中は
  表示目的が「現在使用中の構成の確認」（7.1章 read-only）なので選択状態を書き換えない。
  選択中の bundle ID が現在の列挙結果にない場合も選択は保持し、Picker にプレースホルダ行
  「<アプリ名 or bundle ID>（停止中）」として表示する（4章①でシステム音声を検証しない、の UI 表現）
- 録音ボタンの活性条件に `audioInputSelection.hasEnabledSource` を追加する
  （`RecordingButtonState` に新 case は足さない。`.startRecording` のままボタンを
  disabled にし、ポップオーバー側の警告行が理由を説明する — 状態機械を増やさないため）

### 6.2 startRecording() シーケンス（変更後）

```
0. guard hasEnabledSource（防御的。falseなら banner + return）
1. 4章②の選択解決 → audioInputSelection を確定
   1a. mic: deviceUid が未接続なら nil へ / system: bundleId のプロセスが見つからなければ nil へ
   1b. mic 有効かつ enumerator.inputDevices() が空なら banner
       「利用できるマイクがありません」+ return（AudioCaptureError の新 case は作らない。
       AudioCapture はデバイス列挙を持たないため、この判定は ViewModel の責務）
2. SessionStore.beginRecording()                     （既存）
3. TranscriptPipeline.prepare()                      （既存）
4. audioCaptureFactory(directory, audioInputSelection) で生成、delegate 接続、start()（既存+引数追加）
5. start() 成功 → appState.update { $0.lastAudioInput = audioInputSelection }   ← 追加
6. meta reload・タイマー・liveSegments 購読           （既存）
```

- 失敗時のロールバック（`cancelRecording`）は既存のまま。手順5より前に失敗した場合は
  `lastAudioInput` を書かない（失敗した構成を次回の既定にしない）
- 手順5で永続化される値と実際に使われた入力は、失敗モード #7（手順1〜4の間にマイクが抜かれて
  `MicrophoneSource` 内で暗黙フォールバック）の経路に限り乖離し得る。次回オープン時の解決①で
  `nil` に矯正されるため自己修復するが、「永続値 = 実際に使った構成」は厳密には保証しない
  （システム音声側は `start()` 内フォールバックを持たないためこの乖離は起きない — 5.1章）

## 7. UI 設計

### 7.1 ヘッダ: 入力設定ボタン

録音ボタンの左に入力設定ボタンを置く。押すとポップオーバー（7.2）が開く。

```
┌────────────────────────────────────────────────────────────┐
│ [デイリースクラム ✎]              [🎙 ⃠🔊] [● 録音開始]      │
├────────────────────────────────────────────────────────────┤
│ [ Prep ] [ Transcript ] [ Summary ] [ Watchers ]           │
```

- ボタンラベルは現在の有効状態を示す2つの SF Symbol:
  マイク = `mic` / `mic.slash`、システム音声 = `speaker.wave.2` / `speaker.slash`。
  無効側は slash + `.secondary` 色。`help`（ツールチップ）に「録音入力を設定」
- 表示条件:
  - **Draft**: 表示・編集可能
  - **Recording / 開始中 / 停止中**: 表示するがポップオーバーは read-only
    （現在使用中の構成の確認用。コントロールはすべて disabled）
  - **Ended / 他ウィンドウ録音中**: Ended は非表示（設定対象がない）。
    `disabledOtherRecording` 中は表示・編集可能（この窓の「次の録音」の準備は正当）

### 7.2 入力設定ポップオーバー（AudioInputPopover）

```
┌──────────────────────────────────────────┐
│ 録音入力                                  │
│                                          │
│ マイク                          ( On )   │
│   ┌────────────────────────────────┐     │
│   │ システムデフォルト            ▾ │     │
│   └────────────────────────────────┘     │
│                                          │
│ システム音声                     ( On )   │
│   ┌────────────────────────────────┐     │
│   │ すべてのシステム音声          ▾ │     │
│   └────────────────────────────────┘     │
│                                          │
│ ⚠ 少なくとも1つの入力を有効にして         │  ← 両方 Off のときのみ表示
│   ください                                │
└──────────────────────────────────────────┘
```

システム音声の Picker を開いたときの選択肢（Chirami の UI に準拠）:

```
┌────────────────────────────────────┐
│ ✓ すべてのシステム音声              │  ← bundleId = nil
│ ──────────────────────────────     │
│   Zoom                             │
│     us.zoom.xos                    │
│   Arc                              │
│     company.thebrowser.browser     │
└────────────────────────────────────┘
```

- 各ソースは `Toggle`（switch スタイル）+ `Picker`（pop-up button）。Off のとき Picker は disabled
- Picker の先頭項目は常に固定の既定項目: マイク=「システムデフォルト」（`deviceUid = nil`）、
  システム音声=「すべてのシステム音声」（`bundleId = nil`）。以降に列挙結果を名前順で並べる
- システム音声のアプリ行は表示名（`NSRunningApplication.localizedName`）を主、bundle ID を
  サブテキストにする（Chirami の `displayLabel` / `transcriptDetail` と同じ構成）
- 選択中の bundle ID のアプリが現在列挙されない場合は「<表示名>（停止中）」のプレースホルダ行を
  出して選択を維持する（6.1章）
- ポップオーバーの `onAppear` で `refreshAudioInputs()` を呼ぶ（2章の「開くたびに列挙」）
- 変更は `audioInputSelection` に即時反映（バインディング）。**永続化はしない**（3章）
- 実装は `Kikimi/Views/MeetingWorkspace/AudioInputPopover.swift`。
  `MeetingWorkspaceView` のヘッダ `HStack` に `recordingControl` の前としてボタンを追加する

## 8. 失敗モード表

| # | 状況 | 挙動 | ログ | UI |
|---|---|---|---|---|
| 1 | 両ソース無効で録音開始が呼ばれた | 開始しない（防御的ガード。通常はボタン disabled で到達しない） | warn | ポップオーバー内の警告行 |
| 2 | 保存済みマイク `deviceUid` が未接続（ウィンドウ開時/録音開始時） | デフォルト（`nil`）に書き戻して続行 | info | なし（ポップオーバーを開けば見える） |
| 3 | 選択アプリ（`bundleId`）のプロセスが録音開始時に存在しない | 「すべてのシステム音声」（`nil`）に書き戻して続行 | info | なし（ポップオーバーを開けば見える） |
| 4 | マイク有効だが入力デバイスがゼロ | 録音開始エラー | error | `recordingStartFailed` バナー「利用できるマイクがありません」 |
| 5 | マイクが唯一の有効ソースで start 失敗（権限等） | 既存どおり fatal | error | 既存バナー |
| 6 | システム音声が唯一の有効ソースで tap 失敗 / `selectedAppNotRunning` | fatal（新設 `.systemAudioStartFailed`） | error | `recordingStartFailed` バナー「システム音声を開始できませんでした: <詳細>」 |
| 7 | 両ソース有効で system のみ失敗（`selectedAppNotRunning` 含む） | 既存どおり `[.mic]` へ縮退 | warn | 既存 `systemAudioUnavailable` バナー |
| 8 | `MicrophoneSource` 内で UID→DeviceID 解決失敗（start 直前に抜かれた） | デフォルト入力にフォールバックして続行 | warn | なし |
| 9 | Recording 中にマイクのシステムデフォルト入力が切り替わった（Sound 設定・AirPods 接続等）、または選択デバイスが抜かれた | `MicrophoneSource` が `AVAudioEngine.configurationChangeNotification` を購読し、tap を外して `configureInputDevice` を再適用 → 新 `inputFormat` で converter を作り直し → tap 再インストール → `engine.start()` で自動追従する（数百ms の欠落は許容。`elapsed` はホスト時刻ベースのため再起動をまたいでも一貫）。再構築が失敗した場合（フォーマット無効 / converter 生成失敗 / `engine.start()` 失敗）はリトライせずそのまま tap を停止し、以後は無音のまま Recording が継続する（`AudioSourceCapturing` に mic 向けの mid-stream 失敗通知はまだ無いため、この失敗は UI に表示されない — 実戦で問題になれば `SystemAudioSource.onDegraded` 相当を mic 側にも広げる） | 再構築成功: info / 再構築失敗: error | なし（system 側の失敗のみ 5.2章の文言分岐で通知される） |
| 9a | Recording 中に選択アプリが終了・再起動した（システム音声） | 本設計では検出しない（include-list はスナップショットのため無音継続、stall 検出にも掛からない）。10章 Open Questions | — | （system 全体停止で `activeSources` が空になる場合は 5.2章の文言分岐） |
| 10 | `state.yaml` に `last_audio_input` キーがない（アップグレード初回起動の正常系） | custom `init(from:)` の `decodeIfPresent ?? .default` で補完。`windows` 等は保持され、以後の save も成功する（3章「後方互換」） | なし | なし |
| 11 | `last_audio_input` の値が型不一致等で真に壊れている | `YAMLStore` の既存デコード失敗パス（`loadFailed`、save 拒否） | 既存 | なし |

## 9. テスト方式

### レイヤ 1（swift-testing / XCTest）

- `AudioInputSelection` の Codable round-trip（snake_case キー。`deviceUid == nil` /
  `bundleId == nil` はキー省略としてシリアライズされ、explicit null / キー省略の両方から読めること）
- **マイグレーションテスト（必須）**: `last_audio_input` キーを持たない既存形式の `state.yaml` を
  読んでも `windows` / `sessionListWindow` が保持され、`lastAudioInput == .default` になり、
  以後の `save()` が成功すること（3章「後方互換」の検証）
- 選択解決規則（4章）を pure function
  `resolve(selection:availableDevices:availableApps:phase:)` として切り出し、全分岐をテスト
  （mic: UID あり/なし/未接続 × ①② / system: ①では検証しないこと・②で見つからなければ nil に
  落ちること / 有効・無効の直交）
- `AudioCapture.start()` の挙動マトリクス（5.2章）: fake `AudioSourceCapturing` で
  「無効ソースの start が呼ばれないこと」「mic 無効時に `mic.wav` が作られないこと」
  「system 単独失敗が fatal になること」を検証
- `MeetingWorkspaceViewModel.startRecording()`: fake enumerator + fake factory で
  「開始成功時のみ `lastAudioInput` が書かれること」「両無効ガード」を検証
- `AppState` round-trip（`last_audio_input` キーの読み書き）

### レイヤ 2（kikimi-verify）

- ポップオーバーを開いてキャプチャ（トグル・Picker の描画確認）
- マイクのみ有効で録音 → セッションフォルダに `mic.wav` のみ存在し `system.wav` がないこと、
  `transcript.jsonl` の `speaker` が `mic` のみであることを `verify_session.py` で検証
- 録音完了後に新規 Draft ウィンドウを作成 → ポップオーバーが前回の構成を初期表示すること

## 10. Open Questions（実装フェーズで検証・判断）

1. **プロセス列挙のフィルタ基準**（実装で部分解決済み）: 用途で使い分ける二段構成にした。
   Picker の選択肢は Chirami 踏襲の `isRunningOutput` フィルタ付き
   （`systemAudioProcesses()`。リストを短く保つ）、録音開始時の bundle ID 解決（4章②）は
   フィルタなしの `registeredSystemAudioApps()`（起動中だが無音のアプリ選択を
   破壊的リセットしないため）。「出力開始前のアプリが Picker に出ない」問題自体は残る
   （選択済みなら「（停止中）」プレースホルダで維持される）。Phase 4 実戦で再評価
2. **録音中の対象アプリ再起動への追従**: include-list tap は start 時点のスナップショットのため、
   アプリ再起動（新 PID）後の音声は捕捉されず無音になる（既存 stall 検出にも掛からない）。
   プロセスリスト変更の監視 + tap 再生成で追従するかは Phase 4 実戦後に判断
3. **Recording 中のマイクデバイス抜去**（解決済み）: `MicrophoneSource` が
   `AVAudioEngine.configurationChangeNotification` を購読し、tap 除去 → `configureInputDevice`
   再適用 → 新フォーマットで converter/tap 再構築 → `engine.start()` で自動追従する（8章
   失敗モード#9）。再構築自体が失敗した場合（フォーマット無効・converter 生成失敗・
   `engine.start()` 失敗）はリトライせず tap を停止し、以後は無音のまま Recording が継続する
   （UI 通知は無い）。この「再構築失敗を UI に出すか」「無限に無音のまま録音を続けさせて
   良いか」は Phase 4 実戦で再評価
4. **システム音声が唯一のソースで stall した場合の自動停止**: 現設計は「録音は止めない」を
   優先しバナーのみ。無音録音が長時間続く問題が実戦で出たら再検討
5. **入力増減のリアルタイム監視**: ポップオーバー表示中の抜き差し・アプリ起動の反映
   （`kAudioHardwarePropertyDevices` / `kAudioHardwarePropertyProcessObjectList` リスナ）。
   MVP は開くたびの再列挙で足りる想定
