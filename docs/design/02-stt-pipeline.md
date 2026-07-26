# 02. STT Pipeline 詳細設計

> 本ドキュメントは **`TranscriptPipeline`**（`AudioCapture` の出力を2つの `SttEngine` インスタンスへ配線し、
> `SessionHandle` へ書き込むまでを束ねる接着コンポーネント）の詳細設計である。
> `SttEngine` 内部（streaming 認識・モデル選定・タイムスタンプ算出・confidence 算出）の正は
> [`11-streaming-stt.md`](11-streaming-stt.md)。

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `kikimi.md` 4章（ディレクトリ構造）, 5章（`transcript.jsonl`）, 6章（録音・書き起こしパイプライン）,
8.5章（バックプレッシャ）, 12章（`config.yaml`）, 13章（アーキテクチャ）,
`docs/development-process.md` 2.7/2.9（`kikimi-verify` / テスト方式）。
Chirami 参照実装: `docs/references/chirami-map.md` 1章。
`AudioCapture` との契約: `docs/design/01-audio-capture.md` 5章・7章・12章。
`SessionStore`/`SessionHandle` との契約: `docs/design/07-session-store.md` 5.2章・7章・15章。

## 1. 目的とスコープ

このドキュメントが担当するのは **`TranscriptPipeline`**（`AudioCapture` の delegate イベントを mic/system
2つの `SttEngine` インスタンスへ配線し、その出力を `SessionHandle` へ書き込むまでを束ねる接着コンポーネント。
kikimi.md 13章の component 表には現れないが、`AudioCapture`/`SessionHandle` と同じ粒度で存在する）と、
`TranscriptPipeline` が依存する `SttEngine` の外部契約（型・状態遷移・呼び出し順序）である。

すなわち以下の責務のみ。

- `AudioCapture` から届く Float32/16kHz/mono の PCM バッファ（1ソースぶん）を、順序を保ったまま各 `SttEngine`
  へ受け渡す（3.3節のバッファ供給順序保証）
- 各 `SttEngine` が確定したセグメントを `SessionHandle.appendTranscriptSegment(source:startMs:endMs:text:confidence:)`
  （`07-session-store.md` 5.2章、実装済み）へ渡し、`transcript.jsonl` に反映させる
- マイク/システム音声の **2ストリームを独立に**処理する（kikimi.md 6章「2ストリーム独立処理」、diarization はしない）
- `SttEngine` の外部契約（状態遷移・呼び出し順序、9章）を定義する

**スコープ外**（他ドキュメントに委譲）:

| 関心事 | 担当ドキュメント |
|---|---|
| `SttEngine` 内部実装（streaming 認識・モデル選定・タイムスタンプ算出・confidence 算出） | `11-streaming-stt.md` |
| マイク/システム音声の実際のキャプチャ・PCM バッファ変換・`elapsed` の算出 | `01-audio-capture.md` |
| `transcript.jsonl` への実際の書き込み・`seg_id` 採番・`meta.segmentCount` 更新 | `07-session-store.md`（本ドキュメントは `SessionHandle` の既存 API を呼ぶだけ） |
| セグメント整形（Haiku バッチ）・`refined.jsonl` | `03-refinement-batch.md` |
| Transcript タブの表示・生/整形色分け・自動追従スクロール、モデルダウンロードの進捗 UI | `06-ui-panels.md` |

`TranscriptPipeline` は「PCM バッファ → 確定した書き起こしセグメント」までを提供する接着層であり、
UI 状態・整形・サマリは持たない。

## 3. 全体構成（このドキュメントの範囲）

```
AudioCapture (01-audio-capture.md, 実装済み)
  │ AudioCaptureDelegate.audioCapture(_:didCapture:source:elapsed:) — eventQueue 上で呼ばれる
  ▼
TranscriptPipeline（本ドキュメントで定義。AudioCaptureDelegate 準拠）
  │ eventQueue 上で同期的に bufferContinuation.yield(...)（Task は生成しない。3.3節）。
  │ ソースごとに1本ずつ用意した専用 Task が for await で逐次 engine.feed(...) を呼ぶ
  │
  ├──▶ SttEngine(source: .mic)     ──┐  独立した actor インスタンス。streaming 認識器を1個保持
  │       feed() → chunk 蓄積・decode → セグメント確定 → finalizedSegments (AsyncStream) へ yield
  │       （内部実装は `11-streaming-stt.md` 3.2〜3.4節）
  │
  └──▶ SttEngine(source: .system)  ──┘  同上（mic とは完全に独立、streaming 認識器も別インスタンス）
          │
          │ TranscriptPipeline が各エンジンの finalizedSegments を
          │ `for await` で消費するフォワーディング Task を1つずつ持つ
          ▼
  SessionHandle.appendTranscriptSegment(source:startMs:endMs:text:confidence:)
  （07-session-store.md 5.2章、実装済み。actor のメールボックスが
   kikimi.md 6章の「Segment Queue」の役割を果たす — 3.1節参照）
          │
          ▼
  transcript.jsonl 追記（seg_id はここで採番される。呼び出し順 = 投入順）
```

### 3.1 「Segment Queue」の実体

kikimi.md 6章の全体フロー図にある `[Segment Queue]` は、本設計では**独立したデータ構造を新規実装しない**。
`SessionHandle` は `actor` であり、`appendTranscriptSegment` への並行呼び出しは自動的に FIFO で直列化される
（`07-session-store.md` 4章）。mic 用・system 用の2つの `SttEngine` が確定した順に
`SessionHandle.appendTranscriptSegment` を呼ぶことで、

- 2ストリームの確定順マージ（kikimi.md 5章「`id` は投入順に採番される」）
- 追記の直列化（同時に2本の `write(2)` が競合しない）

の両方が `SessionHandle` の actor 分離だけで達成される。「Segment Queue」という独立コンポーネントは
Kikimi のコード上には存在せず、`SessionHandle` の actor メールボックスがその役割を代替する。

### 3.2 なぜ delegate プロトコルではなく `AsyncStream` か

`SttEngine` は `actor` であるため、actor 内部（チャンク処理・デコード完了ハンドラ）から**同期的に**
delegate メソッドを呼び出すと、呼び出し先が「actor 分離境界の中で実行されているのか外なのか」が曖昧になる。
`AsyncStream`（`var finalizedSegments: AsyncStream<SttFinalizedSegment>` / `var volatileTranscripts:
AsyncStream<String>`）は、この問題を「actor 内から `continuation.yield()` するだけ（同期的・スレッドセーフ）、
消費側は `for await` で好きな文脈から読む」という形で回避している。本設計もこのパターンをそのまま踏襲し、
独自の delegate プロトコルは定義しない（5.2章）。

### 3.3 バッファ供給の順序保証（実装上必須の追加）

`01-audio-capture.md` 5.1章は「actor にすると executor へのhopがランタイム任せになり順序を明示的に
固定できない」という理由で `AudioCapture` 自体を actor にせず、生の serial `DispatchQueue`（`eventQueue`）
で FIFO を保証している。この設計方針は、`TranscriptPipeline` から `SttEngine` actor への受け渡し側にも
一貫して適用する必要がある。

`didCapture` のたびに `Task { await engine.feed(...) }` という**使い捨て Task を生成する実装は採用しない**。
Swift のデフォルト actor executor は排他制御は保証するが、複数の独立した Task から enqueue されたジョブの
実行順序（FIFO）までは仕様上保証しない。`feed()` は `SttEngine` 内部の chunk バッファ（`11-streaming-stt.md`
3.2節・3.4節）へ「バッファが到着順に処理される」前提で単調増加的に蓄積するため、連続する2回の `didCapture`
呼び出しから生成された Task（buffer N の Task A、buffer N+1 の Task B）が actor 上で B → A の順に実行されると、
経過時刻の逆行・非単調化が起こり、タイムスタンプ算出（`11-streaming-stt.md` 3.4節）やセグメント確定ロジック
（同 3.3節）が壊れ、`start_ms`/`end_ms` が逆転・破損しうる。

代わりに、**ソースごとに1本の `AsyncStream` バッファキュー + 1本の専用消費 Task**を用いる（5.2章の
`TranscriptPipeline` 型定義に反映済み）。

- `didCapture` は `Task {}` を生成せず、`eventQueue` 上で同期的に `bufferContinuation.yield(pending)`
  するだけにする。`yield` は non-blocking であり、`eventQueue` の FIFO 順序がそのままキューへ
  引き継がれる
- キューを消費する Task は起動時（`startForwarding()`）に1本だけ生成し、`for await pending in
  bufferStream { await engine.feed(...) }` で逐次呼び出す。ある `feed()` の `await` が actor 上で
  完了するまで、次の `feed()` は enqueue すらされない。したがって「単一の Task が逐次 `await` で
  actor を呼ぶ」構成そのものによって、mic/system それぞれの内部で FIFO が構造的に保証される
  （mic と system の間の相互順序は kikimi.md 6章の通り関知しない。両ソースは独立ストリームであり、
  時系列参照は必ず `start_ms` を使う前提は変わらない）
- `stopAndDrain()`（5.2章）はキューを `finish()` してこの消費 Task の完了を待ってから `engine.stop()`
  を呼ぶ。これにより「`AudioCapture.stop()` 時点までに届いた全バッファが `feed()` に渡り終わってから
  停止時の残余確定処理（`11-streaming-stt.md` 3.2/3.3節）に入る」ことも合わせて保証される

## 5. 型定義

`SttEngine` 側の型定義（`SttEngineConfig`/`SttEngineState`/`SttFinalizedSegment` 等）は
`11-streaming-stt.md` 3.2節が正。本書は接着層である `TranscriptPipeline` の型定義のみを扱う。

### 5.2 `TranscriptPipeline`（2インスタンスの束ね役）

kikimi.md 13章の component 表には現れないが、`AudioCapture` の delegate イベントを2つの `SttEngine` に
配線し、その出力を `SessionHandle` へ書き込むための**接着コンポーネント**が必要になる。`07-session-store.md`
が `SessionHandle` を、`01-audio-capture.md` が `AudioCapture` を定義したのと同じ粒度で、本ドキュメントが
この接着層を定義する。

```swift
final class TranscriptPipeline: AudioCaptureDelegate {
    /// `didCapture` から `SttEngine.feed()` へ渡すまでの一時的な運搬用。3.3節参照。
    private struct PendingBuffer: Sendable {
        var buffer: AVAudioPCMBuffer
        var elapsedAtBufferStart: TimeInterval
    }

    private let sessionHandle: SessionHandle
    private let micEngine: SttEngine
    private let systemEngine: SttEngine
    private var micForwardingTask: Task<Void, Never>?
    private var systemForwardingTask: Task<Void, Never>?

    // 3.3節: ソースごとに1本のバッファキュー + 1本の専用消費 Task で feed() の呼び出し順序を保証する。
    private let micBufferStream: AsyncStream<PendingBuffer>
    private let micBufferContinuation: AsyncStream<PendingBuffer>.Continuation
    private let systemBufferStream: AsyncStream<PendingBuffer>
    private let systemBufferContinuation: AsyncStream<PendingBuffer>.Continuation
    private var micFeedTask: Task<Void, Never>?
    private var systemFeedTask: Task<Void, Never>?

    init(
        sessionHandle: SessionHandle,
        config: SttEngineConfig = SttEngineConfig()
    ) {
        self.sessionHandle = sessionHandle
        self.micEngine = SttEngine(source: .mic, config: config)
        self.systemEngine = SttEngine(source: .system, config: config)
        (micBufferStream, micBufferContinuation) = AsyncStream.makeStream()
        (systemBufferStream, systemBufferContinuation) = AsyncStream.makeStream()
    }

    /// 両エンジンのモデル準備（`11-streaming-stt.md` 3.7節）。呼び出し元（Session Window ViewModel,
    /// `06-ui-panels.md`）はこれが成功してから `AudioCapture.start()` を呼ぶこと（14章）。
    func prepare(
        downloadProgress: (@Sendable (AudioSourceKind, SttModelDownloadProgress) -> Void)? = nil
    ) async throws {
        async let mic: Void = micEngine.prepare { downloadProgress?(.mic, $0) }
        async let system: Void = systemEngine.prepare { downloadProgress?(.system, $0) }
        try await mic
        try await system
        startForwarding()
    }

    private func startForwarding() {
        micForwardingTask = Task { [micEngine, sessionHandle] in
            for await segment in micEngine.finalizedSegments {
                await Self.appendOrLog(segment, source: .mic, to: sessionHandle)
            }
        }
        systemForwardingTask = Task { [systemEngine, sessionHandle] in
            for await segment in systemEngine.finalizedSegments {
                await Self.appendOrLog(segment, source: .system, to: sessionHandle)
            }
        }
        // 3.3節: バッファ供給側の専用消費 Task。1本の Task が for await で逐次 feed() を呼ぶことで、
        // actor へのジョブ enqueue 順序が「到着した順」から絶対にずれないことを保証する。
        micFeedTask = Task { [micEngine, micBufferStream] in
            for await pending in micBufferStream {
                await micEngine.feed(buffer: pending.buffer, elapsedAtBufferStart: pending.elapsedAtBufferStart)
            }
        }
        systemFeedTask = Task { [systemEngine, systemBufferStream] in
            for await pending in systemBufferStream {
                await systemEngine.feed(buffer: pending.buffer, elapsedAtBufferStart: pending.elapsedAtBufferStart)
            }
        }
        // failures/volatileTranscripts の転送（UI・ログ向け）は 06-ui-panels.md 側の購読に委ねるため、
        // ここでは finalizedSegments の転送のみを必須動作として定義する。
    }

    private static func appendOrLog(
        _ segment: SttFinalizedSegment,
        source: AudioSourceKind,
        to sessionHandle: SessionHandle
    ) async {
        do {
            try await sessionHandle.appendTranscriptSegment(
                source: source,
                startMs: segment.startMs,
                endMs: segment.endMs,
                text: segment.text,
                confidence: segment.confidence
            )
        } catch {
            // 11章 失敗モード表を参照。transcript.jsonl への書き込み失敗は SessionHandle 側の責務であり、
            // ここでは `.error` ログのみ出して次のセグメントの処理を継続する（8.5章「録音は絶対に止めない」）。
        }
    }

    // MARK: - AudioCaptureDelegate

    func audioCapture(_ capture: AudioCapture, didCapture buffer: AVAudioPCMBuffer, source: AudioSourceKind, elapsed: TimeInterval) {
        // eventQueue 上（01-audio-capture.md 5.1節）。3.3節: Task を生成せず、同期的に yield するだけ。
        // yield は non-blocking であり、eventQueue の FIFO 順序がそのままバッファキューへ引き継がれる。
        let pending = PendingBuffer(buffer: buffer, elapsedAtBufferStart: elapsed)
        switch source {
        case .mic: micBufferContinuation.yield(pending)
        case .system: systemBufferContinuation.yield(pending)
        }
    }

    func audioCapture(_ capture: AudioCapture, didDegrade source: AudioSourceKind, error: AudioCaptureError) {
        // 縮退したソース側の SttEngine を止める。残る側（通常は mic）は継続する（8.5章）。
        let engine = source == .mic ? micEngine : systemEngine
        Task { await engine.stop() }
    }

    func audioCapture(_ capture: AudioCapture, didUpdateLevel level: Double, source: AudioSourceKind) {
        // 本ドキュメントの関心事ではない（06-ui-panels.md がレベルメーター用に別途 AudioCaptureDelegate を購読する）。
    }

    func audioCaptureDidStop(_ capture: AudioCapture) {
        // 通常の停止フローでは呼び出し元が明示的に stopAndDrain() を呼ぶため、このコールバック自体は
        // 追加の後始末を必要としない（9章）。
    }

    /// `AudioCapture.stop()` の**後**、`SessionStore.endRecording(_:)` の**前**に呼ぶ（9章・14章）。
    func stopAndDrain() async {
        // 3.3節: バッファキューを finish して消費 Task の完了を待ってから engine.stop() を呼ぶことで、
        // `AudioCapture.stop()` 時点までに didCapture 済みの全バッファが feed() に渡り終わってから
        // 停止時の残余確定処理に入ることを保証する（バッファキュー化の直接的な帰結）。
        micBufferContinuation.finish()
        systemBufferContinuation.finish()
        _ = await micFeedTask?.value
        _ = await systemFeedTask?.value

        await micEngine.stop()
        await systemEngine.stop()
        _ = await micForwardingTask?.value
        _ = await systemForwardingTask?.value
    }
}
```

**`liveSegments`（`06-ui-panels.md` 4章・6.3章からの追加要請、実装済み）**: 上記コード例は本ドキュメント起草時点のものであり、
`06-ui-panels.md` 6.3章「Transcript タブのライブ更新」向けに `nonisolated var liveSegments: AsyncStream<TranscriptSegment>`
が追加されている（実装: `Kikimi/Stt/TranscriptPipeline.swift`）。要点:

- `appendOrLog(...)` が `SessionHandle.appendTranscriptSegment(...)` の戻り値（`id` 確定済みの `TranscriptSegment`）を、
  追記が実際に成功した場合のみ `liveSegmentsContinuation` に `yield` する。失敗時は本節既存の「`.error` ログのみ出して
  次のセグメントへ進む」という挙動を変えず、`liveSegments` へは何も流さない（kikimi.md 8.5章「リアルタイム表示は
  生 JSONL の内容で行われる」との整合）
- `stopAndDrain()` は、両 `ForwardingTask` の完了を待った**後**に `liveSegmentsContinuation.finish()` を呼ぶ。これにより
  `for await` で `liveSegments` を購読する側（`06-ui-panels.md` の `MeetingWorkspaceViewModel`）のループは、録音停止後に
  ハングせず自然に終了する

## 9. 状態遷移

### 9.1 `SttEngine`（1インスタンスあたり）

```
idle ──prepare() 成功──▶ ready ──stop()──▶ stopped
  │                        (feed() を受け付ける。
  │                         内部で chunk 蓄積→デコードキュー
  │                         が並行して動く。`11-streaming-stt.md` 3.2/3.4節)
  └─prepare() 中（ダウンロード）──▶ preparing ──成功──▶ ready
                                        └─失敗（throw）──▶ idle（再試行可能）
```

- `stopped` は再利用不可（`AudioCapture` の `stopped` と同じ方針、`01-audio-capture.md` 6章）。次の録音では
  新しい `SttEngine` を生成する
- `feed()` は `state == .ready` のときのみ実際に chunk バッファへ投入する。それ以外（`.idle`/`.preparing`/`.stopped`）
  の場合は黙って無視する（11章 失敗モード#1）

### 9.2 `TranscriptPipeline`（呼び出し順序の契約）

録音開始・停止のシーケンスは以下の順序を守ることが**呼び出し元（Session Window ViewModel,
`06-ui-panels.md`）の責務**である。

```
① SessionStore.beginRecording(_:)         （07-session-store.md 9章。排他制御・meta.json 更新）
② TranscriptPipeline.prepare(...)          （本ドキュメント5.2章。モデル未インストールならここでダウンロード）
③ AudioCapture(sessionDirectory:).start()  （01-audio-capture.md 5章。WAV書き込み開始）
④ audioCapture.delegate = transcriptPipeline を設定済みにしておく（③の前でよい）

… 録音中 …

⑤ AudioCapture.stop()                      （01-audio-capture.md）
⑥ TranscriptPipeline.stopAndDrain()        （本ドキュメント5.2章。最後のセグメントまで appendTranscriptSegment 完了を待つ）
⑦ SessionStore.endRecording(_:)            （07-session-store.md 9章。state=ended 確定）
```

**この順序契約は `07-session-store.md` 15章の境界表には未記載の追加事項である**。特に ⑥ を ⑦ より前に
置かないと、`meta.json.state` が `ended` に確定した後で `transcript.jsonl` に行が追記される（＝
`segmentCount` と実ファイルの行数が一瞬ずれる）可能性がある。`07-session-store.md` 13章のレイヤ1テストで
「`appendTranscriptSegment` 後の `segmentCount` と実行数の一致」を検証しているが、この契約を守らない
呼び出し順序ではその不変条件が崩れ得ることに注意（15章 Open Questions にも記載）。

## 11. 失敗モード一覧

| # | 状況 | `SttEngine`/`TranscriptPipeline` の挙動 | ログレベル | ユーザー可視性 |
|---|---|---|---|---|
| 1 | `state != .ready` のときに `feed()` が呼ばれる（`.preparing` 中に `AudioCapture.start()` が先に走った等の呼び出し順序ミス） | 該当バッファは黙って破棄される（＝その区間は書き起こしから欠落する）。9.2章の呼び出し順序契約を守れば通常発生しない | `.warning`（初回のみ。連続で出さない） | 非表示（呼び出し順序のバグ検出用） |
| 2 | `TranscriptPipeline` から `SessionHandle.appendTranscriptSegment` が失敗（ディスクフル等） | 5.2章の通り `.error` ログのみで次のセグメントの処理を継続する。**実際の失敗時挙動（以後の追記を諦める等）は `07-session-store.md` 12章 失敗モード#5 側の責務**であり、本ドキュメントはその失敗を握りつぶさずログすることだけを担保する | `.error` | `07-session-store.md` 側のバナー表示に従う |
| 3 | `AudioCapture.didDegrade(source:)` を受けてエンジンを `stop()` した後、そのソースの残りバッファが届く | `state == .stopped` になっているため手順1と同じく無視される | `.debug` | 非表示 |

`SttEngine` 内部（chunk 処理失敗・モデル準備失敗・confidence 算出等）の失敗モードは `11-streaming-stt.md` 3.10章が正。

## 12. テスト容易性

### レイヤ1（単体テスト, swift-testing）で狙う対象

- `TranscriptPipeline` のバッファ供給（3.3章）が FIFO を保つことを、フェイクの `SttEngine`（`feed()` 呼び出し
  引数を記録できる形に DI ポイントを用意する）に対して、`didCapture` を連続呼び出した順序と `feed()` が
  実際に呼ばれた順序が常に一致することを検証する
- `TranscriptPipeline.stopAndDrain()` が、フェイクの `SttEngine`（`finalizedSegments` に人工的な
  `AsyncStream` を注入できる形に DI ポイントを用意する）に対して、全セグメントの
  `appendTranscriptSegment` 呼び出しが完了してから返ることを検証する

`SttEngine` 内部ロジック（セグメント確定・タイムスタンプ算出等）のテスト方針は `11-streaming-stt.md` 3.12章が正。

### レイヤ2（`kikimi-verify` skill）向け

- `KIKIMI_STUB_LLM=1`（`docs/development-process.md` 2.9章）は整形（Haiku 呼び出し）側の関心事であり、STT 自体は
  オンデバイス処理のためこの環境変数の影響を受けない（本ドキュメントの範囲外だが誤解を避けるため明記する）
- `verify_session.py`（`07-session-store.md` 13章）が `transcript.jsonl` の内容検証を担う。本ドキュメントの
  契約により、少なくとも1行以上のセグメントが `confidence` フィールド（0.0〜1.0の範囲。`11-streaming-stt.md`
  3.5節の通り現状は常に1.0）を持って存在することを追加の検証項目として提案する

`KIKIMI_TEST_INPUT` ダミー音源の要件・初回モデルダウンロードを踏まえた検証フロー設計は `11-streaming-stt.md`
3.12章を参照。

## 14. 他ドキュメントとの境界（インターフェース契約まとめ）

| 相手 | 契約 |
|---|---|
| `01-audio-capture.md` | `TranscriptPipeline` は `AudioCaptureDelegate` に準拠し、`didCapture`/`didDegrade`/`didUpdateLevel`/`audioCaptureDidStop` を購読する（複数の delegate を持てるかは `AudioCapture` 側の実装依存だが、少なくとも `TranscriptPipeline` と `06-ui-panels.md`（レベルメーター用）の2者が同時に購読できる必要がある — `weak var delegate`単数のままなら `06-ui-panels.md` 側でマルチキャストする仕組みが必要になる点は Open Questions に記載）。バッファは Float32/16kHz/mono、`elapsed` は `AudioCapture.start()` 起点の経過秒という契約をそのまま利用する |
| `07-session-store.md` | `TranscriptPipeline` は `SessionHandle.appendTranscriptSegment(source:startMs:endMs:text:confidence:)` のみを呼ぶ。9.2章で定義した呼び出し順序契約（`AudioCapture.stop()` → `TranscriptPipeline.stopAndDrain()` → `SessionStore.endRecording(_:)`）は `07-session-store.md` 15章の境界表に追記済み |
| `03-refinement-batch.md` | 直接の依存関係はない。`SessionHandle.readTranscriptSegments()` 経由で `transcript.jsonl` を非同期に読み出す側であり、本ドキュメントはその読み出し対象を書き込むだけ |
| `06-ui-panels.md` | `TranscriptPipeline.prepare(downloadProgress:)` を呼んでモデルダウンロード進捗 UI を出す。`SttEngine.volatileTranscripts`/`failures` ストリームを購読して進行中テキスト表示やエラーバナーに使ってよい（本ドキュメントは stream を提供するのみで UI 実装は行わない）。9.2章の呼び出し順序契約を実装する責務も `06-ui-panels.md`（Session Window ViewModel）側にある |
| `kikimi-verify` skill | 初回モデルダウンロードの所要時間を考慮した検証フロー設計が必要であることを申し送る（`KIKIMI_TEST_INPUT` の要件は `11-streaming-stt.md` 3.12章参照） |

## 15. Open Questions（実装着手前に確認したい事項）

- **2エンジン独立方式のメモリコスト**: kikimi.md 6章「2ストリーム独立処理」の方針により、mic/system 用に
  独立した `SttEngine` を2つ生成する。共有可能なモデル資産（`11-streaming-stt.md` 3.7節）を除き、推論に
  必要なメモリフットプリントが2重にならないか実機で確認する必要がある
- **`AudioCaptureDelegate` の複数購読**: 14章で触れた通り、`TranscriptPipeline`（STT用）と
  `06-ui-panels.md`（レベルメーター用）が同時に `AudioCapture` の delegate を必要とする可能性がある。
  `01-audio-capture.md` 5章の `weak var delegate: AudioCaptureDelegate?` は単一の delegate しか
  保持できない実装になっているため、`06-ui-panels.md` 側でマルチキャスト delegate（複数の購読者に
  ブロードキャストする薄いラッパー）を用意する必要があるかもしれない。`01-audio-capture.md` の改訂が
  必要かどうかは実装フェーズで判断する
- **モデル準備（`11-streaming-stt.md` 3.7節）のタイミング**: アプリ起動時に先回りしてダウンロードするか、
  初回録音開始時にブロッキングでダウンロードするかは `06-ui-panels.md` 側の UX 判断に委ねる。後者の場合、
  「● 録音開始」を押してから実際に `AudioCapture.start()` が走るまでに数十秒〜分のダウンロード待ちが
  発生し得る点をユーザーに明示する必要がある
- **ホットワード/レキシコンの扱い**: Chirami にある `TranscriptLexicon`（固有名詞のホットワード登録）は
  kikimi.md に対応する記載がなく MVP スコープ外としたが、会議では社内固有名詞・製品名の誤認識が
  refinement（`03-refinement-batch.md`）の `context.md` だけでは補正しきれない可能性がある。
  Phase 4 実戦テストの結果次第で Phase 3 以降に再検討する余地がある
