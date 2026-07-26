# 15. セグメント単位の音声再生（Transcript タブ）詳細設計

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `kikimi.md` 4 章（ディレクトリ構造・録音区間）, 5 章（データモデル、`start_ms`/`end_ms` の
タイムライン規則）, 6 章（録音・書き起こしパイプライン）, 10 章（Transcript タブ）。
既存の類似実装: `Kikimi/Diarization/VoiceprintEnrollmentSampleResolver.swift`（タイムライン →
WAV ローカル位置への変換規則を踏襲）。

## 1. 目的

Transcript タブの各行（セグメント）に再生ボタンを付け、その発言の音声だけをその場で聞き直せるように
する。ファクトチェック・聞き取り精度の確認・「これいつ言った？」の追跡に有用。全文の連続再生や
シークバー付きプレイヤーは対象外（MVP はワンクリック単発再生のみ）。

## 2. コンポーネント

| コンポーネント | 役割 |
|---|---|
| `SegmentPlaybackResolver`（`Kikimi/Playback/SegmentPlaybackResolver.swift`） | 純関数。セグメントの累積タイムライン位置（`startMs`/`endMs`）を、対応する録音区間の WAV ファイル内ローカル位置（`localStartMs`/`durationMs`）に変換する |
| `SegmentAudioPlayer`（`Kikimi/Playback/SegmentAudioPlayer.swift`） | `@MainActor` クラス。`AVAudioPlayer` を1つ保持し、指定スライスだけを再生・自動停止する |
| `MeetingWorkspaceViewModel` + `+SegmentPlayback.swift` | `playingSegmentId` の公開・`toggleSegmentPlayback(_:)` によるトグル制御 |
| `TranscriptTabView` / `TranscriptRowContentView` | 各行に再生/停止ボタンを表示 |

## 3. タイムライン → WAV マッピング規則

`TranscriptRowViewModel.startMs`/`endMs` は「録音アクティブ時間の累積タイムライン」上の位置
（kikimi.md 5 章）。これを対応する録音区間 `RecordingSegment`（`meta.recordings`）の
`mic_NNN.wav`/`system_NNN.wav` 内のローカル位置に変換する必要がある。

`VoiceprintEnrollmentSampleResolver` と同じ流儀を踏襲する:

- `recordings` を `startMsOffset` 昇順にソートし、`startMs` 以下の `startMsOffset` を持つ最後の区間を
  対象区間とする
- 対象区間の終端は「次の区間の `startMsOffset`」。**最後の区間は unbounded（`Int.max`）**として扱う。
  理由: 進行中の区間は `durationMs`/`endedAt` がまだ確定しておらず、上限を導出する根拠がないため
  （`VoiceprintEnrollmentSampleResolver` の同種コメント参照）
- セグメントが区間境界をまたぐ場合（通常は起こらないが、録音区間の切り替わり直後の書き起こし確定
  タイミング次第ではあり得る）、`endMs` を対象区間の終端でクランプする。セグメント単位の再生ボタンは
  1つの WAV ファイルにしか対応しないため、複数区間にまたがる分割再生はサポートしない（区間をまたいだ
  残りは無視する）
- `localStartMs = startMs - 区間.startMsOffset`、`durationMs = クランプ後の endMs - startMs`

区間が1件も無い（録音されたことがないセッションを開いた等）、または対象区間が解決できない場合は
`nil` を返し、呼び出し側は「再生できない」として何もしない（UI にエラー表示はしない）。

## 4. 録音中の再生の扱い

- `WavFileWriter` は書き込み中も定期的にヘッダを flush するため（`docs/design/01-audio-capture.md`）、
  録音中の WAV も `AVAudioPlayer` で読める。ただしヘッダの `duration` が実データより古い（短い）ことが
  ある
- 再生長は `min(セグメントの durationMs, player.duration - 開始位置) `にクランプする。クランプ後の
  残り時間が 0 秒以下になった場合は何もしない（まだファイルに書き込まれていない、または stale header）
- システム音声のキャプチャは自プロセス（Kikimi 自身の出力音声）を除外済み（`docs/design/01-audio-capture.md`）
  なので、Kikimi 自身がこの再生機能で鳴らす音がシステム音声ストリームに再混入する心配はない

## 5. 失敗モード

| 状況 | 挙動 | ログレベル |
|---|---|---|
| `SegmentPlaybackResolver.resolve` が `nil`（区間未解決・空 `recordings`・不正な `startMs`/`endMs`） | 再生を諦める。UI には何も表示しない | `.warning` |
| 対応する WAV ファイルが存在しない（削除済み等） | `AVAudioPlayer(contentsOf:)` の `init` が throw。catch して再生しない | `.warning` |
| `player.duration` が `localStartMs` より短い（stale header / 未書き込み） | 再生しない（4章のクランプ） | `.info` |
| `player.play()` が `false` を返す | 再生しない | `.warning` |

いずれの失敗も**録音・書き起こしパイプラインには一切影響しない**（kikimi.md 6 章「録音は絶対に止めない」
の対象外の付随機能として、UI 側で握りつぶす）。

## 6. UI

- `TranscriptTabView` の各行末尾に再生/停止ボタン（`play.circle` / `stop.circle.fill`）を追加
- ボタンは行にマウスオーバーしているとき、または現在再生中のときのみ見える（`opacity` 切り替え。
  幅は常に確保し、行の横方向のガタつきを防ぐ）
- 同時に再生できるセグメントは1つ（新しい行を再生すると前の再生は自動停止）
- ウィンドウが閉じられたら（`onDisappear`）再生も停止する（録音自体は止めない）

## 7. テスト方針

- レイヤ1（XCTest/swift-testing）: `SegmentPlaybackResolver` を純関数として網羅的にテストする
  （単一区間・複数区間・区間境界クランプ・最終区間 unbounded・異常系）
- `SegmentAudioPlayer`/ViewModel 統合/UI は `kikimi-verify` skill での手動確認に委ねる（実ファイル
  I/O・実オーディオ再生を伴うため、レイヤ1のユニットテスト対象外）
