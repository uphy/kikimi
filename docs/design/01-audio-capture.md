# 01. Audio Capture 詳細設計

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `kikimi.md` 4章（ディレクトリ構造）, 5章（`transcript.jsonl`）, 6章（録音・書き起こしパイプライン）,
10章（録音の開始・停止）, 12章（`config.yaml`）, 13章（アーキテクチャ）,
`docs/development-process.md` 2.7/2.9（`kikimi-verify` / テスト方式）。
Chirami 参照実装: `docs/references/chirami-map.md` 2章。

---

## 1. 目的とスコープ

このドキュメントが担当するのは **`AudioCapture` コンポーネント**、すなわち以下の責務のみ。

- マイクとシステム音声を**2ストリーム独立**にキャプチャする（AVAudioEngine + CoreAudio Process Tap）
- 16kHz mono にフォーマット変換する
- セッションフォルダの `audio/mic_NNN.wav` / `audio/system_NNN.wav`（`NNN` = 録音区間ごとの連番）に**永続化**する
- 変換済み PCM バッファを下流（STT）へ**ノンブロッキングに受け渡す**
- 権限・デバイス・ディスクに起因する失敗を検出し、**録音を止めずに**縮退動作する
- `KIKIMI_TEST_INPUT` によるダミー音源注入で `kikimi-verify` の決定的な統合テストを可能にする

**スコープ外**（他ドキュメントに委譲）:

| 関心事 | 担当ドキュメント |
|---|---|
| STT エンジンへの入力・セグメント確定（`TranscriptPipeline`/`SttEngine`） | `02-stt-pipeline.md` 5.2章 + `11-streaming-stt.md` |
| セッションフォルダの作成・`meta.json` 更新・Recording の全体排他制御 | `07-session-store.md` |
| 録音ボタン UI・経過時間表示・エラーバナー | `06-ui-panels.md` |

`AudioCapture` は「マイク/システム音声 → PCM バッファ + WAV」までを提供する部品であり、STT や UI の状態管理は持たない。

---

## 2. Chirami 実装との差分サマリ

| 項目 | Chirami | Kikimi（本設計） | 理由 |
|---|---|---|---|
| システム音声取得方式 | CoreAudio Process Tap（`kikimi.md` の記述はScreenCaptureKitだが実装はProcess Tap） | **Process Tap を踏襲**（`chirami-map.md` で既定路線） | Chirami で実績のある方式。ScreenCaptureKit は今回採用しない |
| 音声の永続化 | **しない**（ライブSTTのみ、`AVAudioFile` 等の書き出しコードは存在しない） | **する**（`mic_NNN.wav` / `system_NNN.wav` を録音区間ごとに追記保存） | kikimi.md 4章「後段の高精度再書き起こし用」に音声保持が要件として明記されている。Chirami にない新規コンポーネント `WavFileWriter` を追加 |
| マイクデバイス選択 / システムプロセス選択 | `AudioDeviceEnumerator` / `AudioProcessEnumerator` / `TranscriptDeviceResolver` でユーザーが個別デバイス・個別アプリを選択できる。`SystemAudioCapture` は選択された `processes` を `CATapDescription` の**包含リスト**（`isExclusive = false`）として渡す＝起動時点のスナップショット | **選択 UI を持たない**。マイクは常にシステムデフォルト入力。システム音声は `CATapDescription` を**除外リスト**（`isExclusive = true`）として使い、Kikimi 自身のプロセスのみを除外して**システム出力全体**を対象にする（4節参照） | kikimi.md 10章の Prep タブ仕様にデバイス/プロセス選択 UI の記載がなく、kikimi.md 全体でも「システム音声」はアプリ単位ではなく全体として扱われている。Chirami の包含リスト方式は「起動時点に存在したプロセスのみ」に対象が固定される既知の欠点があり（4節参照）、Kikimi では除外リスト方式でこれを回避する |
| 音声バッファの受け渡し | `typealias BufferHandler = (AVAudioPCMBuffer) -> Void`（タイムスタンプなし） | `(AVAudioPCMBuffer, AudioSourceKind, TimeInterval)`（**セッション開始からの経過秒を必須で持つ**） | `transcript.jsonl` の `start_ms`/`end_ms` は「セッション開始からの経過ミリ秒」と定義されており、生成元はこの層。Chirami はライブ表示のみでこの情報が不要だったため持っていない |
| 一時停止（pause/resume） | `MicrophoneCapture` / `SystemAudioCapture` に `pause()`/`resume()` あり | **`AudioCapture` 自体には出さない**（start/stop のみ）。UI 上の「一時停止/録音再開」（kikimi.md 4/10章）は `06-ui-panels.md` 側が `stop()` した上で、再開時に**新しい `AudioCapture` インスタンス**（次の `recordingIndex`）を生成し直すことで実現する | `AudioCapture` インスタンス内部で pause/resume 状態を持たせると、`WavFileWriter`（開いたら追記のみ・シークしない方針、8章）を休憩を挟んで同一ファイルへ書き続ける必要が生じ複雑化する。区間ごとに別インスタンス・別ファイルに分ける方が `WavFileWriter` の単純な契約を維持できる（`07-session-store.md` の録音区間モデル参照） |
| コンポーネント分割 | `MicrophoneCapture` / `SystemAudioCapture` の2クラスをそれぞれ呼び出し元（`TranscriptSession`）が個別に束ねる | **`AudioCapture` という単一ファサード**が内部で `MicrophoneSource` / `SystemAudioSource` を束ねる | kikimi.md 13章のアーキテクチャ表が `AudioCapture` を1コンポーネントとして列挙しているため、責務境界をそれに合わせる |
| テスト用ダミー入力 | なし | `KIKIMI_TEST_INPUT` 環境変数によるファイル入力の注入（10節） | `docs/development-process.md` 2.7 に明記された Kikimi 固有のテスト要件。Chirami には対応する仕組みがない |

---

## 3. 全体構成（このドキュメントの範囲）

```
                         AudioCapture (facade)
                         ┌─────────────────────────────────────────────────────────────┐
[マイク]        ──▶ MicrophoneSource ──┐   (呼び出し元スレッド: AVAudioEngine tap thread)  │
                                       ├─▶ format convert (16kHz mono, 呼び出し元スレッドで同期実行)
[システム音声]  ──▶ SystemAudioSource ─┘   (呼び出し元スレッド: CoreAudio IOProc thread)   │
                                                 │                                        │
                                                 │ elapsed 計算（7節）はこの時点・この場で行う │
                                                 │                                        │
                                    ┌────────────┼──────────────────────┐                 │
                                    │            │                      │                 │
                              .async へ hop  .async へ hop         .async へ hop           │
                                    │            │                      │                 │
                                    ▼            ▼                      ▼                 │
                          eventQueue(単一)  writerQueue(mic)     writerQueue(system)       │
                                    │            │                      │                 │
                          delegate.didCapture  WavFileWriter(mic)  WavFileWriter(system)    │
                          delegate.didDegrade  .append()           .append()               │
                          delegate.didUpdateLevel                                          │
                                    │            └──▶ sessions/<id>/audio/mic_NNN.wav       │
                                    │                 (headerFlushInterval タイマーも同じ    │
                                    │                  writerQueue へ enqueue、8節参照)      │
                                    │                                                       │
                                    │                 sessions/<id>/audio/system_NNN.wav も同様  │
                         └─────────┼─────────────────────────────────────────────────────┘
                                   │
                     (TranscriptPipeline が消費: バッファキュー → SttEngine（streaming, 11-streaming-stt.md 参照）)
```

3つの `.async` hop（`eventQueue` 用・`writerQueue(mic)` 用・`writerQueue(system)` 用）はすべて
**呼び出し元スレッド（オーディオコールバック）から直接・独立に**行われる。`eventQueue` への hop の後に
`writerQueue` への hop が連鎖する、あるいはその逆、という依存関係は存在しない。これにより：

- WAV 書き込み（ディスク I/O、失敗し得る／遅延し得る）は STT 経路（`eventQueue` → `delegate.didCapture`）と
  **キューを共有しない**。ディスク遅延が書き起こしの遅延に波及することはない
- `eventQueue` と `writerQueue(mic)` / `writerQueue(system)` はいずれもオーディオコールバックそのものではないため、
  ここで詰まってもオーディオコールバックの滞留（グリッチ）には直結しない
- `writerQueue(mic)` と `writerQueue(system)` も互いに独立（インスタンスごとに専用の serial queue を持つ、8節参照）なので、
  片方のディスク書き込みが遅延しても他方はブロックされない

各キューの役割・直列化保証の詳細は 5.1 節（`eventQueue`）・8節（`writerQueue`）を参照。

`KIKIMI_TEST_INPUT` が設定されている場合、`MicrophoneSource` / `SystemAudioSource` は
`TestFileAudioSource` に差し替えられる（10節）。それ以外の下流経路は本番と同一。

---

## 4. マイク/システム音声の選択方針（MVP）

- **マイク**: `AVCaptureDevice.default(for: .audio)`（システムデフォルト入力）を常に使う。デバイス切り替え UI は持たない
- **システム音声**: `CATapDescription(monoGlobalTapButExcludingProcesses:)`（除外リスト方式、`isExclusive = true`）を使い、
  **Kikimi 自身のプロセスだけを除外**してシステム出力全体を Process Tap 対象にする
  - Chirami の `AudioProcessEnumerator.runningOutputProcesses()` による**包含リスト方式**（`isExclusive = false`,
    `CATapDescription.initStereoMixdownOfProcesses`/`initMonoMixdownOfProcesses` 系）は**採用しない**。
    包含リストは `start()` 時点の1回のスナップショットで確定するため、**「Kikimi で先に録音を開始してから
    会議アプリを起動して参加する」という自然な操作順序で、会議アプリの音声が録音全体を通じて一切捕捉されない**
    致命的な欠陥がある（会議アプリのプロセスがスナップショットに存在しないため。かつ他のプロセス、
    例えば Finder や Music が音を出していれば `activeSources` は `{mic, system}` のままとなり `didDegrade` も
    発火しないので、ユーザーは「システム音声も録れている」と誤認したまま実際には目的の会議アプリの音声だけが
    欠落する、最も気づきにくい失敗形態になる）
  - 除外リスト方式（`isExclusive = true`）はプロセス単位の包含リストを持たないため、**録音開始後に起動した
    アプリの音声も動的に捕捉できる**（Apple のヘッダコメント "Mix all processes to a mono stream except the
    given processes" は特定時点のスナップショットでなく実行中の全プロセスを指す設計であるため）。これにより
    上記の操作順序問題が構造的に解消される
  - **Chirami に前例のない新規の採用方式のため、この動的捕捉の挙動は未検証**。実機・`kikimi-verify` での
    検証が必須（13節 Open Questions）。もし実際には tap 作成時点のプロセス集合に固定される（＝除外リストでも
    動的に増えない）ことが判明した場合のフォールバック案も 13節に記載する
  - 除外対象は Kikimi 自身の `AudioObjectID` のみ（Kikimi は現状音声を再生しないため実害はないが、将来通知音等を
    追加した場合の自己ループ防止として除外しておく）。自プロセスの `AudioObjectID` 解決に失敗した場合は
    `.warning` ログを出し、除外リストを空（＝自プロセスも含めて全プロセスを対象）にしたまま `start()` を継続する
    （9節 失敗モード表 参照）。**Chirami の `processes.isEmpty` での無言 `return`（`SystemAudioCapture.swift:113-115`）
    に相当する分岐は、除外リスト方式では「空の除外リスト」が正常系そのものであるため存在しない**
- 将来、マイクデバイス選択・特定アプリの除外/絞り込み UI が必要になった場合は、`MicrophoneSource.init(deviceUID:)` /
  `SystemAudioSource.init(excludedProcesses:)` に引数を追加するだけで拡張できるよう、コンストラクタ引数として
  最初から持たせる（値は現状常に `nil` / Kikimi 自身のみ）

---

## 5. 型定義（公開 API）

```swift
enum AudioSourceKind: String, Codable, Sendable {
    case mic
    case system
}

struct AudioCaptureConfig: Sendable, Equatable {
    var sampleRate: Double = 16_000
    var channels: AVAudioChannelCount = 1
    var micTapBufferSize: AVAudioFrameCount = 1024
    /// WAV ヘッダ（RIFF/data チャンクのサイズ）を書き戻す間隔。
    /// クラッシュ時の再生可能性とディスク I/O 頻度のトレードオフ（8節参照）。
    var headerFlushInterval: TimeInterval = 5.0
}

enum AudioCaptureState: Equatable, Sendable {
    case idle
    case starting
    case running(activeSources: Set<AudioSourceKind>)
    case stopping
    case stopped
}

enum AudioCaptureError: LocalizedError, Equatable, Sendable {
    // start() 失敗（録音は開始されない。呼び出し元は Draft のまま留まる）
    case alreadyRunning
    case sessionDirectoryUnavailable(String)
    case microphonePermissionDenied
    case microphonePermissionRestricted
    case microphoneEngineFailed(String)
    /// マイク・システム音声の両方が使用不能（Recording を開始できない）
    case allSourcesUnavailable

    // 録音継続中の縮退（delegate 経由で通知。録音は止まらない）
    case systemAudioUnavailable(message: String)
    case fileWriteFailed(source: AudioSourceKind, message: String)
    case bufferConversionDropped(source: AudioSourceKind)
}

protocol AudioCaptureDelegate: AnyObject {
    /// 変換済み PCM バッファ。`elapsed` はセッション開始（`start()` 成功時刻）からの経過秒。
    /// 呼び出しはリアルタイムスレッド起点だが `AudioCapture` 内部の専用 serial queue（`eventQueue`, 5.1節）
    /// にホップ済み。**メインスレッドではない**ため、UI 更新が必要な実装側は自分でさらに
    /// `DispatchQueue.main` / `@MainActor` へホップすること。また `eventQueue` は `WavFileWriter` の
    /// `writerQueue`（8節）とは独立しているため、ここで重い処理をしても WAV 書き込みは遅延しないが、
    /// 実装側でも重い処理をせずに次のキュー（Ring Buffer 等）へ即座に受け渡すこと。
    func audioCapture(_ capture: AudioCapture, didCapture buffer: AVAudioPCMBuffer, source: AudioSourceKind, elapsed: TimeInterval)

    /// 録音は継続したまま、特定ソースが縮退したことを通知（UI バナー用）
    func audioCapture(_ capture: AudioCapture, didDegrade source: AudioSourceKind, error: AudioCaptureError)

    /// レベルメーター用（Phase 1 では UI 未実装でも値だけは流す）
    func audioCapture(_ capture: AudioCapture, didUpdateLevel level: Double, source: AudioSourceKind)

    func audioCaptureDidStop(_ capture: AudioCapture)
}

/// マイク/システム音声/テスト入力を差し替え可能にするための内部プロトコル。
/// Chirami の `MicrophoneCapturing` / `SystemAudioCapturing` と同じ DI パターン。
protocol AudioSourceCapturing: AnyObject {
    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws
    func stop()
}

final class AudioCapture {
    init(
        sessionDirectory: URL,
        selection: AudioInputSelection = .default,
        recordingIndex: Int = 0,   // kikimi.md 4章: 録音区間ごとに1インスタンス。mic_NNN.wav/system_NNN.wav の NNN
        config: AudioCaptureConfig = AudioCaptureConfig(),
        microphoneSource: AudioSourceCapturing? = nil,   // nil → 本番実装 or TestFileAudioSource を内部で解決
        systemAudioSource: AudioSourceCapturing? = nil
    )

    weak var delegate: AudioCaptureDelegate?
    private(set) var state: AudioCaptureState { get }

    /// `mic_NNN.wav`（`NNN` = `recordingIndex` をゼロ埋め3桁）オープン → 両ソース起動（マイク権限確認は
    /// `MicrophoneSource.start(bufferHandler:)` 内部で行われる） → `system_NNN.wav` は best-effort で
    /// オープンし、失敗してもマイクのみで継続する、の順で行う。失敗時は例外を投げ、既にオープン済みの
    /// WAV ファイルは閉じた上でファイル自体も削除し（空のプレースホルダを残さない）、state は `.idle`
    /// に戻る（呼び出し元は Draft/Paused/Ended のまま）。
    func start() async throws

    /// 両ソース停止 → WAV ファイルの最終ヘッダ書き戻し・クローズ。
    /// 二重呼び出しは無害（`.idle`/`.stopped` なら即 return）。
    func stop() async
}
```

**録音区間ごとの音声ファイル分割（kikimi.md 4/6章、一時停止/再開機能）**: 1つの `AudioCapture` インスタンスは
1つの録音区間（`SessionStore.RecordingSegment`）専用であり、一時停止→再開のたびに Session Window の
ViewModel が新しい `AudioCapture(sessionDirectory:selection:recordingIndex:)` を生成し直す
（`06-ui-panels.md` 6.1章）。これにより `audio/mic_000.wav`/`audio/system_000.wav`（最初の区間）、
一時停止から再開すれば `audio/mic_001.wav`/`audio/system_001.wav`、という具合に区間ごとに別ファイルへ
書き込まれる。1つの WAV ファイルへ休憩を挟んで再オープン・シークし直す設計は取らない
（`WavFileWriter` の「開いたら追記のみ、シークしない」方針、8章参照、をそのまま維持するため）。

`AudioCapture` 自身は「同一インスタンスの二重 `start()`」だけを `.alreadyRunning` で防ぐ。
**「アプリ全体で Recording は同時に1つ」という排他制御は `07-session-store.md` 側（Session Window / WindowManager）の責務**とし、
このドキュメントでは扱わない（`AudioCapture` のインスタンスはセッションウィンドウごとに作られる想定）。

### 5.1 並行性モデル

`AudioCapture` は `actor` でも `@MainActor` でもない**plain `final class`**とする。理由:
オーディオコールバック（マイクの `installTap` クロージャ、システム音声の CoreAudio IOProc ブロック）は
Swift concurrency のグローバル協調スレッドプールとは別の、リアルタイム性が要求される専用スレッドで
呼ばれる。`actor` にすると呼び出し元スレッドから actor の executor へのホップが Swift concurrency
ランタイム任せになり、どの物理スレッド・どの優先度で処理されるかを設計側で明示的に固定できない。
Chirami の `ioQueue`（`DispatchQueue`）パターンを踏襲し、`DispatchQueue` による明示的なホップ制御を保つ。

- **`eventQueue`**: `AudioCapture` が内部に持つ**単一の serial `DispatchQueue`**
  （`DispatchQueue(label: "io.github.uphy.Kikimi.AudioCapture.event")`）。
  `AudioCaptureDelegate` の4メソッド（`didCapture` / `didDegrade` / `didUpdateLevel` / `audioCaptureDidStop`）は
  **すべてこの `eventQueue` 上で呼び出される**。呼び出し元（マイク tap thread / システム音声 ioQueue thread）から
  `eventQueue.async { ... }` で hop する（3節参照）。同一 `eventQueue` に順序どおり enqueue されるため、
  複数ソースからのイベントが `eventQueue` 上で互いに直列化される（＝ delegate 実装側は複数スレッドからの
  同時呼び出しを心配しなくてよい）
  - **`eventQueue` はメインスレッドではない**。`06-ui-panels.md` 側で UI 更新（例: `@Published` プロパティへの反映）を
    行う場合は、delegate 実装内で `DispatchQueue.main.async` / `@MainActor` への追加ホップを**呼び出し側が行う**こと。
    `AudioCapture` はメインスレッドへの配送を保証しない
  - `state` の遷移（`.idle → .starting → .running(...) → .stopping → .stopped` および縮退による
    `activeSources` の更新）は、実装上必ず `eventQueue` 上で行う（`start()`/`stop()` の内部処理も
    `eventQueue` 経由でシリアライズする）。これにより `state` の書き込み同士が競合することはない
- **`state` の読み出し**: `private(set) var state: AudioCaptureState { get }` は `eventQueue` 以外の任意のスレッド
  （典型的には UI のメインスレッドからのポーリング）から同期的に読める必要がある。書き込みは常に `eventQueue`
  という単一スレッドからのみ行われるため、実装は `OSAllocatedUnfairLock<AudioCaptureState>`
  （`os` モジュール、macOS 13+ で利用可能。システム音声側がそもそも macOS 14.2+ 前提のため利用制約はない）で
  バッキングストレージを保護し、`eventQueue` からの書き込み・任意スレッドからの読み出しの両方をこのロック越しに行う。
  読み出し側同士・書き込み側（単一）との競合はロックが吸収するため、追加の `actor` 化やメインスレッド限定は不要
- **`AudioSourceKind` / `AudioCaptureConfig` / `AudioCaptureState` / `AudioCaptureError` が `Sendable`** なのは
  「値としてスレッド間を安全にコピーできる」ことの保証であり、それらを保持する `var`（＝上記の `state`）自体の
  排他制御を代替するものではない。排他制御は上記のロック／`eventQueue` が担う、という関係を明示しておく
- `WavFileWriter` の `writerQueue`（8節）は `eventQueue` とは**別の**独立した serial queue。
  `AudioCapture` はどちらのキューへの hop も呼び出し元スレッドから直接行い、両キュー間に呼び出し依存はない（3節参照）

### 5.2 `WavFileWriter`（内部型）

Chirami に前例のない新規コンポーネント。テスト容易性（10節）を担保するため、
**ヘッダのバイト列生成を実ファイル I/O から独立した純粋関数として切り出す**ことを型定義の時点で明示する。

```swift
/// 44 バイト固定 PCM WAV ヘッダのバイト列表現。ファイル I/O を一切持たない純粋な値型。
/// レイヤ1テスト（10節）はこの型だけを対象に「サンプルサイズ → 正しい44バイトヘッダ」を検証できる。
struct WavHeader: Equatable {
    var sampleRate: UInt32
    var channels: UInt16
    var bitsPerSample: UInt16
    /// 書き込み済みサンプルデータの総バイト数（＝ data チャンクサイズ）。
    /// 途中経過では暫定値、`close()` 時点では最終値が入る（10節の「途中ヘッダ」「最終ヘッダ」比較に対応）。
    var dataByteCount: UInt32

    /// RIFF/data チャンクサイズを埋め込んだ 44 バイトのヘッダを生成する（純粋関数、I/O なし）。
    func encode() -> Data
}

final class WavFileWriter {
    /// `fileURL` を作成し、プレースホルダ（サイズ0）の `WavHeader` を書き込んで返す。
    /// 内部に専用の serial `DispatchQueue`（`writerQueue`, 8節）を1つ持ち、
    /// 生成した瞬間からタイマー（`headerFlushInterval`）を `writerQueue` 上で駆動し始める。
    init(fileURL: URL, sampleRate: Double, channels: AVAudioChannelCount, headerFlushInterval: TimeInterval) throws

    /// Float32 std format のバッファを Int16 interleaved に変換して追記する。
    /// 呼び出し元スレッドをブロックしない（内部で `writerQueue.async` するのみ。8節参照）。
    /// 変換・書き込みに失敗した場合は `onFailure` を**一度だけ** `writerQueue` 上で呼ぶ
    /// （9節・8節の「以後 append を諦める」制御用）。
    func append(_ buffer: AVAudioPCMBuffer, onFailure: @escaping @Sendable (Error) -> Void)

    /// 最終値で `WavHeader` を書き戻してからファイルをクローズする。
    /// `writerQueue` 上で同期的に完了を待ってから返る（`AudioCapture.stop()` から呼ばれる想定）。
    /// 二重呼び出しは無害。
    func close()
}
```

- `WavHeader.encode()` が実ファイルから独立した純粋関数であることが、10節のレイヤ1テストが
  「実際のファイル書き込みを経由せずに」ヘッダ生成ロジックだけを検証できることの前提になる
- `WavFileWriter` 自体（`init`/`append`/`close`）は実ファイル I/O を伴うため、レイヤ1テストでは
  一時ディレクトリ（`FileManager.default.temporaryDirectory`）に対して実行する統合的な単体テストとして書く
  （`WavHeader` 単体テストとは別立て）

---

## 6. 状態遷移

```
                start() 成功
   idle ────────────────────────▶ running(activeSources: {mic, system})
    ▲  \                                │      │
    │   \ start() 失敗（throw）          │      │ systemAudioSource 縮退
    │    \  例: マイク権限拒否            │      ▼
    │     \  例: allSourcesUnavailable   │  running(activeSources: {mic})
    │      ▼                            │      │
    │     idle（再試行可能）              │      │ stop()
    │                                   ▼      ▼
    │                                stopping ──▶ stopped
    └────────────────────────────────────────────┘
                     （stopped は再利用不可。次の録音には新しい AudioCapture を生成する）
```

- `starting` は `start()` 実行中の内部一時状態（外部観測される猶予は基本無い想定だが、権限ダイアログ待ちで数秒滞在し得る）
- `running(activeSources:)` の集合は**縮退のみで変化する**（開始時に無かったソースが後から追加されることはない。当初から `{mic}` のみだったのか、`{mic, system}` から縮退したのかは `didDegrade` イベントの有無で判別できる）
- `activeSources` が空集合になる遷移は無い。`allSourcesUnavailable` は `start()` 自体を失敗させるため、`running` に入った時点で必ず最低1ソースは有効
- `stop()` は `idle` / `stopping` / `stopped` に対しては no-op

---

## 7. タイムスタンプと座標系

- `AudioCapture.start()` が成功した瞬間の `AVAudioTime` ホスト時刻を `recordingStartHostTime` として保持する
- 各バッファ到着時に渡される `AVAudioTime`（マイク: `installTap` のクロージャ引数 `when`、システム音声: CoreAudio IOProc の `inInputTime`）から
  `AVAudioTime.seconds(forHostTime:)` を使って絶対秒に変換し、`recordingStartHostTime` との差分を `elapsed`（`TimeInterval`, 秒）として delegate に渡す
- **Chirami はこのホスト時刻を捨てている**（`{ buffer, _ in ... }` / IOProc コールバックの時刻引数を無視）。Kikimi では
  `transcript.jsonl` の `start_ms` / `end_ms`（セッション開始からの経過ミリ秒）を生成するために必須なので、明示的に伝播させる
- マイク（AVAudioEngine）とシステム音声（CoreAudio Process Tap）は両方とも同一のシステム全体 host time クロック
  （`mach_absolute_time` 系）を基準にしているため、2ストリーム間の `elapsed` はそのまま比較可能（diarization 不要の設計と整合）
- `elapsed` の単位変換（秒 → ミリ秒、`seg_id` の採番等）は `02-stt-pipeline.md` の責務。本ドキュメントは「経過秒を正確に届ける」ところまで

### 7.1 変換前の時刻を変換後バッファへ紐付ける方法

`MicrophoneSource` / `SystemAudioSource` はどちらも内部で `AVAudioConverter.convert(to:error:)` により
入力フォーマット（マイクのネイティブ入力フォーマット／システム音声の tap フォーマット）から
16kHz mono Float32 std format へ変換する。`AVAudioConverter.convert` の出力 `AVAudioPCMBuffer` には
**時刻を保持するプロパティが存在しない**ため、変換後にホスト時刻を後から取り出す方法はない
（Chirami の `MicrophoneCapture.installTap`（`{ buffer, _ in ... }`）と `SystemAudioCapture` の IOProc ブロック
（`{ [weak self] _, inputData, _, _, _ in ... }`）は、まさにこの時刻引数を明示的に捨てている。Kikimi ではこの
2箇所を踏襲しつつ時刻だけは捨てずに拾う点が Chirami との差分であり、Chirami に類例はない）。

そのため設計上は、**変換の直前**（＝コールバック引数の生の時刻値がまだ手元にある時点）で `elapsed` を
計算し、変換後バッファとは別の値として一緒に運ぶ。実装方針:

1. マイク: `installTap` クロージャ引数 `when: AVAudioTime` から、変換を呼び出す**前**に
   `AVAudioTime.seconds(forHostTime: when.hostTime)` を計算しておく
2. システム音声: IOProc ブロック引数 `inInputTime: UnsafePointer<AudioTimeStamp>` から、
   `AVAudioTime(hostTime: inInputTime.pointee.mHostTime)` を経由して同様に変換前に秒へ変換しておく
3. `AVAudioConverter.convert` 呼び出し（入力を1回だけ供給し2回目以降は `.noDataNow` を返す、
   Chirami と同じ single-shot パターン）は、**1回の呼び出しにつき入力バッファ1個ぶんの全フレームを
   1回で出力する**ため、出力バッファは常に「その入力バッファに対応する時刻区間」を過不足なく表す。
   よって上記1./2.で変換前に計算しておいた `elapsed` を、**そのまま**変換後の出力バッファに紐付けてよい
   （フレーム単位の按分・累積カウンタは不要）
4. `AVAudioPCMBuffer` 自体には時刻を格納するフィールドがないため、`elapsed`（`TimeInterval`, 値型で
   Sendable）は変換後バッファとは別の**引数**として、`(AVAudioPCMBuffer, TimeInterval)` のペアで
   `AudioCapture` 内部の hop（3節・5.1節）まで運ぶ。`AudioSourceCapturing.start(bufferHandler:)` の
   シグネチャが `(AVAudioPCMBuffer, AVAudioTime) -> Void` になっているのはこのため
   （変換後バッファと変換前ホスト時刻を1組で受け渡す契約）

**既知の精度限界**: 1バッファは `micTapBufferSize`（既定1024フレーム、16kHzで約64ms）ぶんのフレームを
含むため、`elapsed` はそのバッファ内の全フレームに対して単一値（バッファ先頭フレームの時刻）を採用する。
バッファ内部でのフレーム単位の精度は扱わない。これは `02-stt-pipeline.md` がバッファを不可分な単位として
扱う既存の前提と整合する。

---

## 8. WAV 永続化（`WavFileWriter`）

### なぜ `AVAudioFile` をそのまま使わないか

`AudioCapture` 内部でダウンストリーム（STT）に渡す作業用フォーマットは
`AVAudioFormat(standardFormatWithSampleRate:channels:)` で得られる **Float32 / non-interleaved** 形式である
（Chirami の sherpa-onnx 連携もこの形式を前提にしている）。
一方 kikimi.md 4章は音声ファイルを **「16kHz mono / 16-bit」** と明記しているため、
WAV 書き出し用に **Float32 → Int16 PCM interleaved** への追加変換が必要になる。
`WavFileWriter` は自前の `AVAudioConverter`（Float32 std format → Int16 interleaved format）をもう1段持ち、
STT 用バッファとは独立に変換・書き込みを行う。

### ヘッダ更新戦略（クラッシュ耐性）

`AVAudioFile` はヘッダの内部書き戻しタイミングを利用側から制御できないため、独自の軽量 WAV ライタを実装する。

- 起動時に 44 バイトの固定 PCM WAV ヘッダ（`RIFF` サイズ・`data` チャンクサイズはプレースホルダ 0）を書き込む
- 以降はサンプルデータを `FileHandle` で追記するのみ（seek しない）
- `config.headerFlushInterval`（既定 5 秒）ごとに一度、ファイル先頭に seek してヘッダの2箇所のサイズフィールド
  （RIFF チャンクサイズ = 総ファイルサイズ - 8、data チャンクサイズ = 書き込んだサンプルバイト数）だけを書き戻し、
  末尾へ seek し直して追記を継続する
- `stop()` 時に最終値で同じヘッダ書き戻しを1回行ってからクローズする
- **既知の限界**: 直近の `headerFlushInterval` 未満の区間でクラッシュ（`kill -9` 相当）した場合、
  ヘッダのサイズフィールドは古い値のまま残る。多くの WAV デコーダはヘッダのサイズが実ファイルサイズと矛盾していても
  先頭から読める範囲までは再生可能だが、シークバー等が壊れる可能性がある。これは kikimi.md 15章
  「セッション中のクラッシュ復旧」と同種の既知の制約として扱い、次回起動時のリカバリダイアログ実装（`07-session-store.md`）側で
  「ヘッダのdata sizeを実ファイルサイズから再計算して修復する」オプションを持たせることを推奨する（このドキュメントでは修復ロジック自体は実装しない）

### `writerQueue`: `append` とヘッダ書き戻しの直列化、およびオーディオコールバックからの隔離

`WavFileWriter` インスタンスは**自分専用の serial `DispatchQueue`**（`writerQueue`, 例:
`DispatchQueue(label: "io.github.uphy.Kikimi.WavFileWriter.\(source)")`）を1つ持つ。
`mic_NNN.wav` 用と `system_NNN.wav` 用の `WavFileWriter` はそれぞれ別インスタンス＝別 `writerQueue` であり、
互いに独立している（3節参照）。

- **同一 `FileHandle` への直列化**: `append(_:)`（オーディオコールバック起点）と定期ヘッダ書き戻しタイマー
  （`headerFlushInterval` ごとに発火）は、どちらも実際の `FileHandle` 操作を**必ず `writerQueue.async { ... }`
  で包んで実行する**。`writerQueue` は serial（FIFO・同時実行数1）なので、この2つの作業項目は
  enqueue された順に確実に1つずつ実行される。これにより「`append` の追記中にヘッダ書き戻しが割り込んで
  seek 位置がずれる」「ヘッダ書き戻し中に追記が発生してファイルが壊れる」といった競合はキューの直列実行
  そのものによって防止され、追加のロックは不要（タイマー自体は任意のスレッド／`DispatchSourceTimer` で
  駆動してよいが、ハンドラの中身は必ず `writerQueue.async` 経由で `FileHandle` に触れる）
- **オーディオコールバックからの隔離**: `append(_:)` は呼び出し元（マイク tap thread /
  システム音声 ioQueue thread）に対しては**即座に返る**。実体の変換（Float32 → Int16）と
  `FileHandle.write` はすべて `append(_:)` 内部の `writerQueue.async { ... }` に包まれており、
  呼び出し元スレッドではファイルへの同期書き込みを一切行わない。これにより:
  - ディスクが遅い（HDD・ネットワークボリューム・容量枯渇直前等）場合でも、その遅延は `writerQueue` 内に
    閉じ込められ、オーディオコールバックの滞留（＝グリッチ）には波及しない
  - `writerQueue` は `AudioCapture.eventQueue`（5.1節、STT 経路への delegate 通知に使う）とも別の
    キューであるため、ディスク I/O の遅延が書き起こしの遅延に波及することもない
  - この隔離により kikimi.md 8.5章「録音は絶対に止めない」を、ファイル書き込みが遅延・失敗した場合にも
    オーディオ経路・STT 経路の双方について保証できる

### ディスク書き込み失敗時の挙動

- `append(_:)` が失敗（ディスクフル・権限エラー等）した場合、**その旨を `.error` レベルでログし、
  `didDegrade(source:.fileWriteFailed)` を1回だけ発火した上で、以後そのストリームへの `append` 呼び出し自体を諦める**
  （リトライで無限にログを吐き続けない）。この失敗検出・通知自体も `writerQueue` 上で行われ、
  `didDegrade` の発火は `AudioCapture` を経由して `eventQueue` へ改めて hop される（5.1節）
- **STT 側への delegate 通知（`didCapture`）は WAV 書き込みの成否に関係なく継続する**。
  音声の永続化に失敗しても、書き起こし・整形パイプラインは止めない（8.5章「録音は絶対に止めない」の精神をファイル I/O 層にも適用）。
  上記の通り `didCapture`（`eventQueue` 経由）と `append`（`writerQueue` 経由）は独立した経路なので、
  この継続性はキュー構成そのものによって保証される
- ディスク容量そのものの事前警告（3時間会議で約660MB等）は UI 層（`06-ui-panels.md`）の関心事とし、本コンポーネントは
  書き込み失敗を検出・通知するところまでを担当する

---

## 9. 失敗モード一覧

| # | 状況 | `AudioCapture` の挙動 | ログレベル | ユーザー可視性 |
|---|---|---|---|---|
| 1 | マイク権限が `denied`/`restricted` | `start()` が `.microphonePermissionDenied`/`.microphonePermissionRestricted` を throw。録音は開始されない（Draft のまま） | `.error` | Session Window がエラーダイアログ表示、システム設定への誘導リンク |
| 2 | マイクは許可されたが `AVAudioEngine.start()` が失敗 | `.microphoneEngineFailed` を throw。録音は開始されない | `.error` | 同上 |
| 3 | システム音声の Process Tap 権限がユーザーに拒否される、または `AudioHardwareCreateProcessTap` が失敗 | **マイクが使える限り録音は開始する**。`activeSources` は `{mic}` のみとなり、`didDegrade(.system, .systemAudioUnavailable)` を発火 | `.warning` | 「システム音声を取得できません。マイクのみで記録します」バナー |
| 4 | マイク・システム音声が両方とも使用不能 | `start()` が `.allSourcesUnavailable` を throw。録音は開始されない | `.error` | エラーダイアログ |
| 5 | 録音中にシステム音声デバイス構成が変化（既定出力の切替・Process Tap 対象アプリの終了等）で以後のコールバックが停止 | 検出できた場合は `{mic}` に縮退し `didDegrade` を発火。**マイク側は継続**。（実装時に `kAudioObjectSystemObject` の device-changed 通知を監視するか、tap からのコールバック断絶をタイムアウト検出するかは実装フェーズで決定 — 13節 Open Questions） | `.warning` | バナー表示更新 |
| 6 | `AVAudioConverter.convert` が1バッファ分だけ失敗 | そのバッファは破棄し、次のバッファ処理を継続（Chirami は無言で捨てるが、Kikimi は必ずログを出す）。`AudioCaptureError` に専用ケースは設けず（発火経路が無い過剰実装を避けるため）、`SystemAudioSource`/`MicrophoneSource` 内のログ出力のみで表現する | `.warning` | 通常は非表示（頻発時のみ将来 UI 検討・専用ケースの再導入を検討） |
| 7 | `WavFileWriter.append` が失敗（ディスクフル・権限） | 8節参照。ファイル書き込みのみ諦め、STT への受け渡しは継続 | `.error` | バナー表示（「音声ファイルの保存に失敗しました」） |
| 8 | セッションフォルダの `audio/` が作成できない | `start()` が `.sessionDirectoryUnavailable` を throw。録音は開始されない | `.error` | エラーダイアログ |
| 9 | 下流（Ring Buffer / STT / 整形キュー）が詰まる | `AudioCapture` は関知しない。`didCapture` は呼び出し元が非同期キューに積むだけの想定で、`AudioCapture` 自身はブロックしない（10節・8.5章参照） | — | キュー長インジケータは `02-stt-pipeline.md` 側の関心事 |
| 10 | 同一 `AudioCapture` インスタンスへの `start()` の二重呼び出し | `.alreadyRunning` を throw | `.warning` | 通常発生しない想定（呼び出し元のバグ検出用） |
| 11 | Kikimi 自身の `AudioObjectID`（除外対象）の解決に失敗する（4節） | **フェイルセーフとして除外リストを空のまま `start()` を継続する**（＝ Kikimi 自身も含めて全プロセスを対象にタップする）。現状 Kikimi は音声を再生しないため実害はない。`.allSourcesUnavailable` 等の致命的失敗としては扱わない | `.warning` | 通常は非表示（内部的なフォールバックのため） |
| 12 | `system_NNN.wav` のオープンにファイルシステム起因で失敗する（`mic_NNN.wav` 自体は開けている） | **マイクが使える限り録音は開始する**（#3 と同様の扱い）。`systemAudioSource` はそもそも起動せず、`activeSources` は `{mic}` のみとなり、`didDegrade(.system, .systemAudioUnavailable)` を発火。`mic_NNN.wav` のオープン失敗は引き続き致命的（#1/#2/#4/#8 と同様） | `.warning` | 「システム音声を取得できません。マイクのみで記録します」バナー |

**共通原則**: 「マイク」は必須（無ければ録音そのものを開始しない）。「システム音声」は best-effort（無くてもマイクのみで録音を継続する）。
これは、会議の主目的が「自分の発言を含めた書き起こし」であり、マイクさえ確保できれば最低限の価値提供ができるという判断による
（kikimi.md に明文化された規定ではなく、本設計での判断。13節 Open Questions にも記載）。

**Chirami の `SystemAudioCapture.start(processes:)` が `processes.isEmpty` の場合に例外を投げず `isRunning` も
立てずに黙って `return` する（`SystemAudioCapture.swift:113-115`）という挙動について**: Kikimi は4節の通り
包含リスト方式（`processes:` に何を渡すかで対象が決まる方式）を採用しないため、この「対象プロセスが1つもない」
という状態そのものが構造的に発生しない（除外リスト方式では除外対象が空＝「全プロセスを対象にする」という
最も一般的な正常系になる）。したがってこの失敗モードは Kikimi の設計では表内の項目として個別に存在せず、
唯一対応する残存ケースは上記 #11（除外リストの中身＝自プロセス自体が決められない場合）である。

---

## 10. テスト容易性

### レイヤ1（単体テスト, swift-testing）で狙う対象

- `WavHeader.encode()`（5.2節、ファイル I/O から独立した純粋関数）が、サンプルデータサイズ → 44バイトヘッダの
  バイト列を正しく生成すること。実ファイルを介さず値の入出力だけで検証できる
- `WavFileWriter`（実ファイル I/O を伴う統合的な単体テスト、一時ディレクトリを使用）で、
  「途中経過のヘッダ」（`append` 後・`headerFlushInterval` 到達前）と「クローズ後の最終ヘッダ」を
  実際に読み出して突き合わせ、data size が一致すること
- `AudioCaptureConfig` の既定値・`Equatable` 性
- `AudioCapture` の状態遷移（`idle → running → stopping → stopped`、縮退時の `activeSources` 更新）を、
  `AudioSourceCapturing` のフェイク実装（実ハードウェアなし）で検証
- `elapsed` 計算（`AVAudioTime.seconds(forHostTime:)` の差分計算）を固定ホスト時刻値で検証

### レイヤ2（`kikimi-verify` skill）向け: `KIKIMI_TEST_INPUT`

- 環境変数 `KIKIMI_TEST_INPUT=/path/to/dummy.wav` が設定されている場合、`AudioCapture` は
  `MicrophoneSource` / `SystemAudioSource` の**両方**を `TestFileAudioSource` に差し替える
  （実際の TCC 許可ダイアログや Process Tap 生成を一切経由しないため、CI・自動操作環境でも決定的に動く）
- `TestFileAudioSource` の仕様:
  - 指定 WAV ファイルを読み込み、`micTapBufferSize`（既定 1024 フレーム、16kHz なら約64ms）単位のチャンクに分割
  - 実時間ペースで（`DispatchSourceTimer` により約64ms間隔で）バッファを供給し、実運用に近いタイミング特性を再現する
  - ファイル終端に到達したら**先頭にループ**して供給を継続する（`stop()` が呼ばれるまで供給し続けるため、
    「録音開始 → N秒待機 → 停止」という `kikimi-verify` の待機時間に依存せず動作する）
  - マイク用インスタンスとシステム音声用インスタンスは独立した2つの `TestFileAudioSource` とし、
    同じファイルをそれぞれ `source: .mic` / `source: .system` としてタグ付けして供給する（2ストリーム独立処理の検証に使える）
- `KIKIMI_STUB_LLM` は整形（Haiku 呼び出し）側の関心事であり本コンポーネントの範囲外（`03-refinement-batch.md` 参照）

### DI ポイント

`AudioCapture.init` は `microphoneSource` / `systemAudioSource` を明示的に注入できる
（`nil` の場合のみ内部で `KIKIMI_TEST_INPUT` の有無を見て本番実装 or `TestFileAudioSource` を解決する）。
これにより単体テストからは本番のハードウェア依存コードを経由せずにフェイクを差し込める。

---

## 11. 設定との対応

`config.yaml` の `audio` セクション（12章）は、**`AudioCaptureConfig` にそのまま1:1で写像されるわけではない**。
`format` は `AudioCaptureConfig` にフィールドとして存在しないため、`AudioCaptureConfig` を組み立てる**手前**の
設定読み込み層（`07-session-store.md` が担当する config.yaml のロード処理）で検証・消費し切ってから、
残りのフィールドだけを `AudioCaptureConfig` に渡す。この層分担を対応表として明記する。

```yaml
audio:
  format: wav        # MVP では wav 固定。将来 flac 等に対応する場合の拡張ポイントとして残す
  sample_rate: 16000
  channels: 1
```

| `config.yaml` キー | 担当層 | `AudioCaptureConfig` フィールド | 扱い |
|---|---|---|---|
| `audio.format` | 設定読み込み層（`07-session-store.md`） | **対応フィールドなし** | `wav` 以外の値が指定された場合、設定読み込み層が `.warning` ログを出し `wav` にフォールバックする。検証・フォールバック後の値は `AudioCaptureConfig` へは伝播しない（`WavFileWriter` が WAV 固定で実装されているため、値を保持する必要自体がない） |
| `audio.sample_rate` | 設定読み込み層 → `AudioCaptureConfig` | `sampleRate` | 検証なしでそのまま代入（Kikimi 全体・sherpa-onnx モデルが16kHz前提のため実質固定値） |
| `audio.channels` | 設定読み込み層 → `AudioCaptureConfig` | `channels` | 検証なしでそのまま代入（`Int` → `AVAudioChannelCount` へのキャストのみ） |
| （`config.yaml` に対応キーなし） | — | `micTapBufferSize` | `config.yaml` からは設定不可。コード上のデフォルト値（1024）固定。将来 UI 等から調整可能にする場合は `audio` セクションにキーを追加する |
| （`config.yaml` に対応キーなし） | — | `headerFlushInterval` | 同上（デフォルト5.0秒固定） |

- `sample_rate` / `channels` は Kikimi 全体の前提（sherpa-onnx モデルも16kHz mono 前提）と密結合しているため、
  実質固定値として扱う。設定ファイルに残すのは「将来の拡張性を閉じない」ため
- `format` のバリデーション・フォールバックの実装詳細（ログ文言・失敗時の扱い等）は `07-session-store.md` に委譲する。
  本ドキュメントが保証するのは「`AudioCaptureConfig` に `format` フィールドは存在せず、`WavFileWriter` が WAV 決め打ちで
  実装される」という契約のみ

---

## 12. 他ドキュメントとの境界（インターフェース契約まとめ）

| 相手 | 契約 |
|---|---|
| `02-stt-pipeline.md` | `AudioCaptureDelegate.audioCapture(_:didCapture:source:elapsed:)` から Float32/16kHz/mono の `AVAudioPCMBuffer` を `source` と `elapsed`（秒）付きで受け取る。呼び出しはリアルタイム経路に近いため、受け取り側は即座に自前のキュー（Ring Buffer）に積んで返すこと（ブロック厳禁） |
| `07-session-store.md` | `AudioCapture.init(sessionDirectory:)` に渡す `sessionDirectory` は `~/.local/state/kikimi/sessions/<id>/` であること、`audio/` サブフォルダの作成は `AudioCapture` 側で行う。Recording の全体排他制御・`meta.json` の `duration_ms` 更新は呼び出し元の責務 |
| `06-ui-panels.md` | `didDegrade` / `didUpdateLevel` / `audioCaptureDidStop` を購読してバナー表示・レベルメーター・録音ボタン状態を更新する。`start()` の `throw` はダイアログ表示に使う。**これらのコールバックは `AudioCapture` 内部の `eventQueue`（5.1節）上で発火し、メインスレッドではない**ため、UI 更新側は自分で `DispatchQueue.main` / `@MainActor` へホップすること。`state` を UI からポーリングする場合も、ロックで保護された読み出し（5.1節）のためスレッドを問わず安全だが、UI 表示への反映自体は呼び出し側でメインスレッドへ持ち込む必要がある |
| `kikimi-verify` skill | `KIKIMI_TEST_INPUT` 環境変数のみが契約。skill 側はこの環境変数をセットしてアプリを起動し、録音開始 → 待機 → 停止 → `audio/mic_000.wav` / `audio/system_000.wav` の生成確認、という手順を踏める |

---

## 13. Open Questions（実装着手前に確認したい事項）

- **システム音声デバイス変更の検出方法**: 録音中に既定出力デバイスが変わった場合、Process Tap のコールバックが
  静かに止まるのか、エラーが飛んでくるのかを実機検証していない。タイムアウトベースの「無音検出」を保険として入れるかは
  実装フェーズで判断する（失敗モード表 #5）
- **Process Tap 権限が拒否された場合の System Settings 遷移先**: マイクは `NSMicrophoneUsageDescription` で
  従来通り「システム設定 > プライバシーとセキュリティ > マイク」に誘導できるが、Process Tap
  （システムオーディオ録音）の権限ペインへの deep link（`x-apple.systempreferences:` スキーム等）は
  Chirami 側でも確認できていない。実機で確認して `06-ui-panels.md` 側のエラーダイアログに反映する
- **マイク必須方針の妥当性**: 本設計は「マイクが無ければ録音自体を開始しない」としたが、
  「システム音声だけでも録音したい」（例: 自分は発言せず聞くだけの大人数ウェビナー）というユースケースが
  将来出てきた場合はこの方針を緩める必要がある。現時点では kikimi.md に明記が無いため MVP は保守的な側に倒した
- **ディスク容量の事前警告閾値**: 失敗モード表 #7 は「書き込み失敗が起きてから」の後手対応。
  長時間会議前にディスク空き容量をチェックして事前警告するかどうかは UI 側 (`06-ui-panels.md`) と合わせて要検討
  （kikimi.md 15章の既存 Open Question と同一）
- **除外リスト方式 Process Tap の動的プロセス捕捉の実機検証（重要・4節）**: 4節で採用した
  `CATapDescription(monoGlobalTapButExcludingProcesses:)` が、「録音開始後に新しく起動したアプリの音声も
  動的に捕捉できる」という前提は Apple のヘッダコメントからの推論であり、**Chirami に前例がなく実機未検証**。
  `kikimi-verify` での検証手順案: ①録音開始、②検証開始**後に**別プロセス（例: `afplay` でテスト音源を再生、
  または Zoom/Meet 等を起動）から音を出す、③その音が `system_000.wav` に含まれているかを確認、という順序で
  「開始前に存在しなかったプロセスの音声」が拾えることを明示的に確認する（通常の統合テストが「開始前から
  鳴っている音」だけを確認して見落としがちな観点）
  - **フォールバック案（もし動的捕捉が確認できなかった場合）**: (a) 一定間隔（例: 30秒）で
    `AudioHardwareCreateProcessTap` / aggregate device を再生成して除外リスト自体は変えずに対象を
    リフレッシュする、(b) Chirami 方式（包含リストの定期的な再スナップショット＋再生成）に戻し
    「新しいプロセスの検出まで最大 N 秒のタイムラグがある」ことをユーザーに明示する、のいずれかを
    実装フェーズで選択する
- **Kikimi で先に録音を開始してから会議アプリに参加する操作順序そのもののリスク**: 上記の動的捕捉が
  期待通りに機能したとしても、「録音開始 → 会議アプリ起動 → 会議アプリで音声出力デバイスが変更される」等の
  複合的なタイミング要因は残り得る。またこの操作順序では「マイクの権限確認・エンジン起動」に数秒かかる間、
  会議の冒頭発言を録り逃す可能性も別途ある（`starting` 状態の滞在時間、6節）。これらはユーザー教育（オンボーディング
  で「会議アプリを開いてから録音を開始してください」等の案内）で緩和する余地があるが、`06-ui-panels.md` 側の
  検討事項としてここに記録しておく
