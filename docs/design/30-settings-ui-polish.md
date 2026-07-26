# 30. Settings UI ポリッシュ（grouped Form 化）詳細設計

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `docs/design/26-settings-ui.md`（現行 Settings UI の設計。本設計は §4 の UI コードスケッチを
見た目の面で置き換える。config スキーマ・binding 方式・Keychain 周りは 26 のまま変更しない）、
`docs/design/25-dictation-mode.md` §6（入力タブ）、`docs/design/28-glossary.md` §4（用語集タブ）。
消費側: `Kikimi/Views/SettingsView.swift`、`Kikimi/Views/DictationAppContextSection.swift`。

背景: 現行の Settings は `Form` をスタイル未指定（= macOS 既定の columns スタイル）のまま使っており、
(1) `Section` ヘッダが右カラム内に素のテキストとして浮いて見出しに見えない、(2) `Stepper` が
「ラベルに値を埋め込んだ裸の上下矢印」で値の直接入力ができずラベル列もガタつく、(3) コントロール
幅・揃えが行ごとにバラバラ、(4) 開発者向けチューニングノブがユーザー設定と同列に並ぶ、という
「こなれてなさ」が UI レビュー（本セッション）で指摘された。

## 1. 目的とスコープ

Settings ウィンドウの見た目・操作性を macOS 標準（System Settings 風の grouped スタイル）に
揃える。**純粋な View 層のリファクタリングであり、機能追加はしない。**

**不変条件（変えないもの）**:

- config スキーマ（`KikimiConfigData` とその全フィールド・YAML キー・デフォルト値）は一切変更しない
- `AppConfig.binding(_:)` / `optionalStringBinding(_:)`（`SettingsView.swift` の extension）による
  直バインド方式は変更しない。`SettingsViewModel` の責務（話者タブ・API キー draft）も変更しない
- 各設定項目の**集合**は変更しない（項目の追加・削除はしない。見せ方＝配置・コントロール種別・
  ラベル文言のみ変える）
- Keychain / API キー draft の永続化タイミング（`onSubmit` + `onDisappear`、26 §4.3）は変更しない
- 話者タブ（`VoiceprintSpeakersTab`）・用語集タブ（`GlossarySettingsTab`）の内部構造は変更しない
  （§6 のルート padding 変更の影響を受けるのみ）

**スコープ外（今回は着手しない）**:

- タブ名「Watchers」の日本語化。Watcher は kikimi.md 全体で使うプロダクト用語（固有名詞扱い）で
  あり、タブ名だけ訳すと逆に対応が取れなくなる。現状維持と決定済み
- 設定の検索・ウィンドウサイズの記憶・タブ選択の永続化などの新機能
- `storage.session_dir` / `llm.pricing` の UI 化（26 §1 のスコープ外方針を維持）

## 2. 方針: `.formStyle(.grouped)` への一括移行

Form ベースの4タブ（一般・モデル・Watchers・入力）すべてに `.formStyle(.grouped)` を適用する
（deployment target は macOS 14 なので利用可能）。これにより:

- `Section("...")` ヘッダが正しい見出し（太字・セクション余白・角丸グループボックス）になる
- 行レイアウト（ラベル左・コントロール右）が標準化され、コントロール幅の不揃いが解消する
- grouped Form は `List`（NSTableView）ベースで**自前のスクロールを持つ**ため、現行の手動
  `ScrollView` ラッパー（一般・モデル・入力タブが「plain Form は NSPanel 内でスクロールしない」
  対策として持っているもの）を**撤去できる**

**フォールバック（実装時にレイヤ2検証で判断）**: 万一 grouped Form が NSPanel ホストの TabView 内で
スクロールしない場合（plain Form と同根の問題が再現する場合）は、`ScrollView` + grouped Form の
組み合わせは不可（List が高さゼロに潰れる既知の SwiftUI 挙動）なので、grouped 化自体を中止し
「columns Form のまま §3 の共通コントロールだけ導入する」縮退案に切り替える。この判断は
一般タブ最下部（Wiki Export セクション）までスクロールできるかの1点で行う。

## 3. 共通コントロール（新規ファイル）

新規ファイル `Kikimi/Views/SettingsFormControls.swift`。現行の
`Stepper("ラベル: \(値)", value:in:step:)` パターン（一般タブ4箇所 + モデルタブ4箇所）をすべて
置き換える、「ラベル + 直接入力可能な数値フィールド + ステッパー」の行コンポーネント。

```swift
import SwiftUI

extension Comparable {
    /// Bounds `self` into `range`. Used by the numeric settings fields below to keep typed-in
    /// values inside the same range their steppers enforce.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// One numeric row in a settings `Form`: label on the left, a right-aligned editable value with an
/// optional unit and a stepper on the right. Replaces the bare `Stepper("label: \(value)")` rows,
/// whose value lived inside the label (not directly editable, and the label column shifted width
/// every time the value changed).
struct SettingsIntField: View {
    let label: String
    var unit: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", value: clampedValue, format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                if let unit {
                    Text(unit).foregroundStyle(.secondary)
                }
                Stepper("", value: clampedValue, in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    private var clampedValue: Binding<Int> {
        Binding(get: { value }, set: { value = $0.clamped(to: range) })
    }
}

/// `Double` counterpart of `SettingsIntField` (covers `TimeInterval` fields too).
/// `fractionDigits` fixes the displayed precision so 0.45 never renders as 0.45000000000000001.
struct SettingsDoubleField: View {
    let label: String
    var unit: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double
    var fractionDigits: Int = 1

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(
                    "", value: clampedValue,
                    format: .number.precision(.fractionLength(0...fractionDigits))
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                if let unit {
                    Text(unit).foregroundStyle(.secondary)
                }
                Stepper("", value: clampedValue, in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    private var clampedValue: Binding<Double> {
        Binding(get: { value }, set: { value = $0.clamped(to: range) })
    }
}
```

設計上のポイント:

- `TextField(value:format:)` は **Return / フォーカス喪失時にのみ**バインディングへ書き戻す
  （キーストロークごとではない）。`AppConfig.update` → `YAMLStore.save()` が走る頻度は現行の
  Stepper クリックと同等以下で、YAML 書き込みの増加はない
- 範囲外の値を直接入力した場合は `clampedValue` の setter が範囲内へ丸めて保存する。Stepper 側は
  もともと `in:` で制約済み。config.yaml 手編集で範囲外を書いた場合の挙動は従来どおり decoder 側の
  warning + fallback（26 §4.2 の記述のまま）
- 対象フィールドの型は全数調査済み: `segmentIdleTimeout`（`TimeInterval` = `Double`）、
  `speakerMatchThreshold` / `speakerMatchMargin`（`Double`）、残り8フィールドはすべて `Int`。
  この2ビューで全数カバーでき、generic 化は不要
- 閾値系（0...1）に `Slider` を使う案は不採用。行スタイルが2種類に増えて不揃いが再発する上、
  0.01 精度の値合わせはスライダーより直接入力の方が確実

## 4. タブ別の変更詳細

### 4.1 一般タブ（`GeneralSettingsTab`）

構造の変更: `ScrollView` ラッパーと `Form` 直下の `.padding()` を撤去し、`Form { ... }
.formStyle(.grouped)` にする。開発者向けチューニングノブは各セクション内の
`DisclosureGroup("詳細")` に畳む（grouped Form 内の `DisclosureGroup` は行としてレンダリング
され、展開時に内包行がインデント表示される標準挙動をそのまま使う）。

```swift
var body: some View {
    Form {
        Section("音声認識 (STT)") {
            TextField("言語コード", text: appConfig.binding(\.stt.language),
                      prompt: Text("ja-JP / auto"))
            DisclosureGroup("詳細") {
                Picker("チャンク長", selection: appConfig.binding(\.stt.chunkMs)) {
                    ForEach(SttEngineConfig.validChunkMsTiers.sorted(), id: \.self) {
                        Text("\(String($0)) ms").tag($0)
                    }
                }
                SettingsDoubleField(
                    label: "セグメント確定タイムアウト", unit: "秒",
                    value: appConfig.binding(\.stt.segmentIdleTimeout),
                    range: 0.5...10.0, step: 0.5
                )
                SettingsIntField(
                    label: "セグメント文字数上限", unit: "文字",
                    value: appConfig.binding(\.stt.maxSegmentCharacters),
                    range: 20...400, step: 10
                )
            }
        }
        Section("話者分離") {
            Toggle("話者分離を有効にする", isOn: appConfig.binding(\.diarization.enabled))
            if appConfig.data.diarization.enabled {
                TextField("自分の表示名", text: appConfig.binding(\.diarization.selfName))
                DisclosureGroup("詳細") {
                    Picker("LS-EEND ステップ幅", selection: appConfig.binding(\.diarization.stepMs)) {
                        Text("100 ms").tag(100)
                        Text("500 ms").tag(500)
                    }
                    Picker("モデルバリアント", selection: appConfig.binding(\.diarization.variant)) {
                        ForEach(["callhome", "dihard3", "dihard2", "ami"], id: \.self) { Text($0).tag($0) }
                    }
                    SettingsDoubleField(
                        label: "同一人物判定の距離閾値",
                        value: appConfig.binding(\.diarization.speakerMatchThreshold),
                        range: 0.0...1.0, step: 0.01, fractionDigits: 2
                    )
                    SettingsDoubleField(
                        label: "判定マージン",
                        value: appConfig.binding(\.diarization.speakerMatchMargin),
                        range: 0.0...0.5, step: 0.01, fractionDigits: 2
                    )
                }
            }
        }
        Section("音声") {
            Toggle("内蔵スピーカー利用時にヘッドホンを提案する",
                   isOn: appConfig.binding(\.audio.suggestHeadphonesOnBuiltInSpeaker))
        }
        Section("既定テンプレート") {
            TextField("既定 context.md のパス", text: appConfig.binding(\.defaults.contextFile))
            TextField("既定 summary_template.md のパス", text: appConfig.binding(\.defaults.summaryTemplateFile))
        }
        Section("サマリ更新") {
            SettingsIntField(
                label: "更新トリガ（セグメント数）", unit: "セグメント",
                value: appConfig.binding(\.summary.updateTriggerSegments),
                range: 5...100, step: 5
            )
            SettingsIntField(
                label: "更新トリガ（経過時間）", unit: "秒",
                value: appConfig.binding(\.summary.updateTriggerSeconds),
                range: 30...600, step: 30
            )
            Toggle("タイトル自動命名", isOn: appConfig.binding(\.summary.autoNaming))
        }
        Section("Wiki Export") {
            Toggle("セッション終了時に自動 export する", isOn: appConfig.binding(\.export.enabled))
            if appConfig.data.export.enabled {
                TextField("Export 先ディレクトリ", text: appConfig.binding(\.export.targetDir))
            }
        }
    }
    .formStyle(.grouped)
}
```

「詳細」への振り分け基準は「意味を理解せずに触ると認識品質が壊れる・かつ既定値で通常運用が成立
する」フィールドかどうか。STT では言語コードのみ表に残す（会議の言語は普通のユーザーが変える
正当な理由がある）。話者分離では有効化トグルと自分の表示名のみ表に残す。

ラベル・表示の修正点（現行 → 新）:

| 現行 | 新 | 理由 |
|---|---|---|
| 言語コード（例: ja-JP, auto） | ラベル「言語コード」+ prompt「ja-JP / auto」 | 例示はプレースホルダの仕事。ラベル列を短く保つ |
| チャンク長 (ms) の選択肢「2,240」 | 「2240 ms」（`String($0)` 経由） | `Text("\(Int)")` のロケール桁区切りは ms 値に不自然 |
| セグメント確定タイムアウト: 2.0秒（Stepper） | `SettingsDoubleField` + 単位「秒」 | 値の直接入力・ラベル安定化 |
| LS-EEND ステップ幅 (ms) の「100」「500」 | 単位を選択肢側に移し「100 ms」「500 ms」 | ラベルから単位表記を除去し選択肢を自己記述に |
| 更新トリガ: N セグメント / 更新トリガ: N 秒 | 「更新トリガ（セグメント数）」「更新トリガ（経過時間）」 | 同名ラベル2行の曖昧さ解消 |

### 4.2 モデルタブ（`ModelSettingsTab`）

構造の変更は一般タブと同じ（`ScrollView` 撤去 + `.formStyle(.grouped)`）。`.onDisappear` /
`.task`（API キー draft の永続化・読込、26 §4.3）は `Form` に付け替えるだけで挙動不変。

長い括弧書きラベルは「ラベル + prompt（空欄時に見える説明）」または「ラベル + `.help`」に分解する:

| 現行ラベル | 新ラベル | 補足の置き場 |
|---|---|---|
| claude 実行ファイルパス（空欄で自動検出） | claude 実行ファイルパス | prompt「空欄で自動検出」 |
| API キー（Keychain に保存されます） | API キー | prompt「Keychain に保存されます」 |
| API キー環境変数名（任意・フォールバック用） | API キー環境変数名 | prompt「任意・フォールバック用」 |
| モデル上書き（Azure デプロイ名運用向け・空欄で無効） | モデル上書き | prompt「空欄で無効（Azure デプロイ名向け）」 |
| API バージョン（Azure legacy 用・空欄で無効） | API バージョン | prompt「空欄で無効（Azure legacy 用）」 |
| Reasoning Effort（gpt-5系推論モデル用） | Reasoning Effort | `.help("gpt-5系推論モデルでのみ有効")` |
| 整形モデル (refinement.model) | 整形モデル | `.help("config.yaml: refinement.model")` |
| サマリモデル (summary.model) | サマリモデル | `.help("config.yaml: summary.model")` |
| Watcher 既定モデル (watchers.default_model) | Watcher 既定モデル | `.help("config.yaml: watchers.default_model")` |

prompt は「空欄のときにこそ読ませたい説明」（自動検出・フォールバックの挙動）に使い、埋まって
いても常に参照させたい対応 config キーは `.help`（ツールチップ）に置く、で使い分ける。

「バッチ整形」セクションの Stepper 4本は `SettingsIntField` へ置き換える:

```swift
Section("バッチ整形") {
    SettingsIntField(label: "バッチサイズ",
                     value: appConfig.binding(\.refinement.batchSize), range: 1...50)
    SettingsIntField(label: "バッチタイムアウト", unit: "ms",
                     value: appConfig.binding(\.refinement.batchTimeoutMs),
                     range: 1_000...30_000, step: 500)
    SettingsIntField(label: "コンテキストセグメント数",
                     value: appConfig.binding(\.refinement.contextSegments), range: 0...10)
    SettingsIntField(label: "コンテキスト再構築間隔", unit: "バッチ",
                     value: appConfig.binding(\.refinement.contextRefreshBatches), range: 1...50)
}
```

（モデルタブは全体が技術者向けタブなので、一般タブと違い `DisclosureGroup` への隔離はしない。）

### 4.3 Watchers タブ（`WatchersSettingsTab`）

`.formStyle(.grouped)` を付け、`.padding()` を外すのみ。項目は2つの `TextField` のまま。

### 4.4 入力タブ（`DictationSettingsTab` + `DictationAppContextSection`）

`ScrollView` ラッパーと `.padding()` を撤去し `.formStyle(.grouped)` を適用する。撤去理由の
ドキュメントコメント（「plain Form は NSPanel 内でスクロールしない」）は grouped Form が自前
スクロールを持つ旨に書き換える。

- 先頭の `Toggle("ディクテーションを有効にする")` 以下、現在セクションなしで並んでいる行は
  `Section` なしのままでよい（grouped Form では暗黙の無題セクションとして1つのグループボックスに
  まとまる）
- `TextField("モデル（空欄で既定値）")` → ラベル「モデル」+ prompt「空欄で既定値」
- `KeyboardShortcuts.Recorder("ホットキー:", name: .dictate)` はそのまま置く。grouped Form の行と
  して成立するかはレイヤ2検証項目（§8）。崩れる場合は `LabeledContent("ホットキー") {
  KeyboardShortcuts.Recorder("", name: .dictate) }` でラップする
- `DictationAppContextSection`（`Section("アプリ別コンテキスト")` + `TextEditor` + アプリ一覧）は
  無変更で grouped 化の恩恵を受ける。`TextEditor`（minHeight 140）が grouped 行内で潰れないかは
  レイヤ2検証項目

### 4.5 話者タブ・用語集タブ

内部は無変更。§5 のルート `.padding()` 撤去に伴い:

- `VoiceprintSpeakersTab`: ルート `Group` に `.padding()` を追加する（カスタム VStack + List 構成
  なので自前の inset を持たない。現状はルートの padding に依存していた）
- `GlossarySettingsTab`: **padding を追加しない**。サイドバー + 詳細ペインのマスター・ディテール
  構成は端まで到達（full-bleed）の方がむしろ標準的（現状は周囲の padding でサイドバーが浮いて
  見えていた）

## 5. `SettingsView` ルートの変更

```swift
var body: some View {
    TabView(selection: $selectedTab) {
        // ...（6タブの並びは不変）
    }
    .frame(minWidth: 760, minHeight: 480)
}
```

- `TabView` 直後の `.padding()` を撤去する。grouped Form は自前の inset を持つため二重マージンに
  なり、用語集タブでは full-bleed を阻害していた。padding が必要なタブ（話者）はタブ側で持つ（§4.5）
- `minHeight` を 380 → 480 に引き上げる。grouped Form は行が高く（1行 ≈ 40pt）、380 では一般タブの
  最初のセクションすら収まりきらない。`minWidth: 760` は据え置き（根拠コメントの用語集サイドバー
  事情は不変）
- `.frame` の根拠を説明する既存の長文コメントに、minHeight 480 の理由（grouped 行高）を追記する

## 6. ファイル構成の変更

`SettingsView.swift` は現在 588 行で lint の `file_length` warning（600行）目前。本設計の変更
（`DisclosureGroup` 追加・prompt 分解）で確実に超えるため、`DictationAppContextSection` の先例
（lint 対策の純粋なファイル分割）に倣って分割する:

| ファイル | 内容 |
|---|---|
| `Kikimi/Views/SettingsView.swift`（既存・縮小） | `SettingsView` ルート + `AppConfig.binding` extension + `WatchersSettingsTab` + `VoiceprintSpeakersTab` + `VoiceprintSpeakerRow` + `DictationSettingsTab` |
| `Kikimi/Views/GeneralSettingsTab.swift`（新規） | `GeneralSettingsTab`（`private` → `internal` に変更。同モジュール内なので他は無変更） |
| `Kikimi/Views/ModelSettingsTab.swift`（新規） | `ModelSettingsTab`（同上） |
| `Kikimi/Views/SettingsFormControls.swift`（新規） | `Comparable.clamped(to:)` + `SettingsIntField` + `SettingsDoubleField`（§3） |

- 新規ファイルは xcodegen のディレクトリ glob で自動的に取り込まれる。実装後に `mise run generate`
  を1回実行する（`swift build` 経路には影響なし）
- 各タブの doc コメント（設計文書への参照付き）は移動先ファイルへそのまま持っていく。
  `ScrollView` ラッパーの理由を説明していたコメント（`GeneralSettingsTab` / `ModelSettingsTab` /
  `DictationSettingsTab` の3箇所）は「grouped Form は List ベースで自前スクロールを持つため
  ラッパー不要」に書き換える

## 7. `docs/design/26-settings-ui.md` への追記

26 §4（Settings UI 設計）の冒頭に1行追記する:

> **注**: 本節の UI コードスケッチのうち見た目（Form スタイル・Stepper・ラベル文言）は
> `docs/design/30-settings-ui-polish.md` で更新済み。binding 方式・タブ構成・Keychain 連携は
> 本節が引き続き正。

## 8. テスト計画

**レイヤ1（swift-testing）**: 追加は最小限。View 本体は UI テスト対象外（既存方針どおり）。

- `Comparable.clamped(to:)` の境界テスト（下限未満→下限、上限超→上限、範囲内→そのまま）を
  `KikimiTests/Views/SettingsFormControlsTests.swift` に新設
- 既存テストへの影響: なし（config スキーマ・binding 方式が不変のため）。`swift test` 全通過を確認

**レイヤ2（`kikimi-verify` skill）**: 本設計の主戦場。以下を確認する。

1. **スクロール成立（§2 のフォールバック判断点）**: 一般タブを開き、最下部の「Wiki Export」
   セクションの「セッション終了時に自動 export する」トグルまでスクロールして操作できること
2. **全6タブのスクリーンショット確認**: セクションがグループボックスとして描画され、見出しが
   見出みえること。ルート padding 撤去で崩れたタブがないこと（特に話者タブの padding、
   用語集タブの full-bleed サイドバー）
3. **DisclosureGroup**: 一般タブの STT「詳細」を AX 名前指定クリックで展開し、チャンク長 Picker が
   「2240 ms」表記（桁区切りなし）で現れること
4. **数値フィールドの直接入力**: セグメント文字数上限に範囲外の値（例: 9999）を入力して Return →
   表示と `~/.config/kikimi/config.yaml` の `max_segment_characters` が 400 に丸まっていること
5. **Stepper 動作**: 同フィールドのステッパー増減が従来どおり config.yaml に反映されること
6. **入力タブ固有**: `KeyboardShortcuts.Recorder` の行が崩れていないこと、アプリ別コンテキストの
   `TextEditor` が高さ 140pt 以上で表示・編集できること
7. **既存シナリオの回帰**: モデルタブの API キー入力 → Keychain 保存（26 のレイヤ2シナリオ）が
   従来どおり動くこと

## 9. 実装手順

1. `SettingsFormControls.swift` 新設（§3）+ `clamped` のレイヤ1テスト
2. `SettingsView.swift` から `GeneralSettingsTab` / `ModelSettingsTab` をファイル分割（§6、
   この時点では中身無変更のまま分割だけ行い、ビルド確認）
3. 一般タブの grouped 化 + DisclosureGroup + コントロール置換（§4.1）
4. モデルタブの grouped 化 + ラベル分解 + コントロール置換（§4.2）
5. Watchers・入力タブの grouped 化（§4.3・§4.4）
6. ルートの padding 撤去・minHeight 変更 + 話者タブへの padding 追加（§4.5・§5）
7. `mise run generate` → `swift build` → `mise run lint` → `swift test`
8. `kikimi-verify` でレイヤ2の全項目（§8）を確認。項目1が不成立ならフォールバック（§2)へ切替
9. 26 への注記追記（§7）

## 10. リスク・既知の割り切り

- **grouped Form のスクロール可否**が最大の技術リスク（§2 にフォールバック定義済み）。plain Form が
  スクロールしなかった NSPanel ホスト環境で grouped（List ベース）が同じ問題を踏む可能性は低いが
  ゼロではない
- `KeyboardShortcuts.Recorder`（サードパーティ製ビュー）と `TextEditor` の grouped 行内での描画は
  実機確認するまで確定しない（§4.4 に代替レイアウト定義済み）
- `DisclosureGroup` の展開状態は保存しない（ウィンドウを開き直すと畳まれた状態に戻る）。詳細設定は
  低頻度操作なので許容する
- タブ切替時に grouped Form のスクロール位置は保持されない（TabView が非選択タブの View を破棄する
  既存挙動のまま）。従来の ScrollView でも同じだったため劣化ではない
