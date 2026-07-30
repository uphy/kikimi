# 38. セッションチャット（会話への ad-hoc 質問）詳細設計

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `kikimi.md` 10 章（Session Window）, 9 章（Watchers）, 12 章（config）, 15 章（LLM コスト）,
`docs/design/17-session-window-redesign.md` §3/§4.1（タブ構成と `activeTab` の永続化）,
`docs/design/12-llm-client.md`（`LLMCompleting` / `LLMRequest`）,
`docs/design/05-watcher-runner.md` §6（`input_scope` と `{{recent_segments}}`）,
`docs/design/16-llm-usage-stats.md`（セッション別 LLM 課金集計）,
`docs/design/37-transcript-markdown-copy.md` §3.2(b)（`TranscriptMarkdownSource`）,
`docs/design/07-session-store.md`（`SessionFile` / JSONL 追記）。

**実装状況**: 実装済み。§8.1 の前提修正 (a)〜(c) は先行 PR、(d) とチャット本体は後続 PR で入れた。

実装で設計から変えた点は 2 つ:

- **`SIGPIPE` を `SIG_IGN` にする場所**（§8.1(a)）を `KikimiApp` の起動処理ではなく
  `ClaudeCLIProcessRunner` 内（初回のプロセス起動前に 1 度だけ）にした。回帰テスト（64KB 超の stdin を
  読まない子に渡して SIGKILL する）はテストターゲットで走るので、`KikimiApp` に置くとテスト側が無防備になる
- **`ChatTurn` の追加フィールド**: 画面のコピー用チェックマークを出すため、ViewModel 側に
  `chatCopyFeedbackTurnId` を持たせた（`copyFeedbackRowId` と同じ流儀）。`ChatTurn` 自体は §3.4 のまま

実装後にユーザー要望で足したもの:

- **履歴のクリア**（`clearChatHistory()` / `SessionHandle.deleteChatTurns()`）。履歴がある時だけ出る
  ゴミ箱ボタン + 確認ダイアログで `chat.jsonl` を削除する。CH8 の「追記のみ」はレコードを**書き換えない**
  という不変条件であって、ユーザーが明示的に捨てた履歴をこっそり残すほうが筋が悪い。チャットは会議の記録
  ではなく Kikimi の操作履歴（CH14）なので、消えて困る下流も無い。回答待ちの間は無効化する
  （その呼び出しは結果を追記するので、消した直後に履歴が復活する）

**経緯**: ユーザー要件は「ad-hoc にチャット形式で最新の会話について質問したい」。Watcher が
「あらかじめ決めた観点を継続的に見る」のに対し、チャットは**その場で思いついたことを 1 回聞く**ための
経路で、両者は補完関係にある。

要点は以下のとおり。

- **書き起こしの読み出しは 37 の資産がそのまま使える**。`TranscriptMarkdownSource`
  （`Kikimi/Markdown/TranscriptMarkdownSource.swift`）は「セッション全体を話者名付きの
  `TranscriptMarkdownRenderer.Input` にする」もので、整形済みも未整形（`*(raw)*`）も欠落なく拾う。
  録音中に質問する場合に必要な性質がすでに揃っている。ただし**文書の組み立ては Chat 専用**
  （`ChatContextBuilder`）で持つ — 既存の `TranscriptMarkdownRenderer.Scope` に「frontmatter なし・
  サマリ + 書き起こし末尾のみ・予算付き切り詰め」を表せるケースが無いため（CH2）
- **既存の LLM 層に 2 つの前提修正が要る**（§8.1）。(a) `LLMProcessRunner` の stdin 同期 write は
  64KB を超えるプロンプトでブロックしタイムアウトより先にハングし得る（CH20）、(b) `LLMRequest` の
  既定タイムアウト 60 秒はチャットの入力規模に対して根拠が無い（CH19）。どちらもチャットが初めて
  踏む経路なので、**チャットの実装に先立って直す**
- **4 つ目のタブ**（`準備 / 会議 / Watchers / チャット`）。`MeetingWorkspaceTab`
  （`Kikimi/Config/AppState.swift:19`）に 1 ケース足し、**`WorkspaceWindowState.init(from:)` の
  手書き `switch` にも 1 ケース足す**（足さないと `chat` が復元されない。CH1）
- **履歴は `chat.jsonl` としてセッションに保存**する。開き直しても残り、会議終了後も続きを聞ける
- ~~**図（mermaid）は初版では出させない**~~ → 初版はそうしたが、`docs/design/39-webview-markdown.md`
  （サマリ / Watchers / チャットを横断する WebView 描画）が入って**撤回**した。当時の理由は MarkdownUI が
  CommonMark レンダラで mermaid を描けず、`docs/design/06-ui-panels.md:71` が WKWebView を使わないと
  決めていたこと
- **ストリーミングはしない**。`LLMBackend`（`Kikimi/LLM/LLMBackend.swift:10`）は 1 発の
  `complete` しか持たない。回答が出るまでスピナーを出す（§9 の将来拡張）

## 1. 目的とスコープ

**やること**:

- 会議ワークスペースに「チャット」タブを追加し、そのセッションの会話について自由に質問できるようにする
- 質問・回答を `chat.jsonl` に保存し、ウィンドウを開き直しても履歴を復元する
- セッション全体（整形済み書き起こし + サマリ）をコンテキストとして渡す。長すぎるときは
  サマリ + 直近セグメントへ自動で切り替える
- 直前の数ターンを踏まえた追い質問（マルチターン）
- 回答の Markdown コピー
- LLM 課金の既存集計（16 章）に乗せる（`purpose` は `chat`）
- 前提として既存 LLM 層を直す（§8.1）: `LLMProcessRunner` の stdin 非同期化、`LLMRequest.messages`
  の追加、stub 応答とコスト表示ラベルへの `chat` 登録、`active_tab: chat` の復元

**やらないこと（§9 も参照）**:

- ~~mermaid をはじめとする図の描画~~ → `docs/design/39-webview-markdown.md` で実装済み
- ストリーミング表示
- 複数セッション横断の質問（「先週の A 社との会議では何と言っていたか」）
- チャットからの編集操作（話者リネーム・サマリ書き換え・Watcher 生成などの副作用）
- Wiki export への履歴の同梱
- 音声での質問（ディクテーションで入力欄に喋ることは既存機能でできる）

## 2. 決定事項

| # | 決定 |
|---|------|
| CH1 | **4 つ目のタブ**。`MeetingWorkspaceTab` に `case chat`（title `"チャット"`）を追加する。**`WorkspaceWindowState.init(from:)`（`Kikimi/Config/AppState.swift`）は合成デコーダではなく手書きの `switch rawActiveTab` なので、`case MeetingWorkspaceTab.chat.rawValue` を明示的に足さないと `chat` が `default:` に落ちて毎回「準備」タブに戻る**（§8.1(d)）。旧バイナリへのロールバックは `default:` があるので安全（`chat` は `prep` として読まれる）。Draft はそもそもタブバーを出さない（design 17 §3.1）ので、チャットも Recording 以降にだけ現れる — 会話が 1 行も無い状態で質問する意味がなく、Draft 専用画面に何かを足す必要もない |
| CH2 | **行の整形は 37 と共有し、文書の組み立ては Chat 専用に持つ**。読み出しは `TranscriptMarkdownSource.load(sessionHandle:)`（37 §3.2(b)）、1 行の整形は `TranscriptMarkdownRenderer.renderLine(_:meta:)`（公開済み）をそのまま使う。一方 `TranscriptMarkdownRenderer.Scope` は `.full`（frontmatter 付き）/ `.transcript`（サマリ非表示）/ `.summary`（書き起こし非表示）の 3 つしかなく、**チャットが要る「frontmatter なし・サマリ + 書き起こし末尾のみ・文字数予算で切り詰め」を表現できない**。`Scope` にケースを足すと Wiki export とコピー機能が共有する型に実行時概念が混ざるため、**`ChatContextBuilder` を新設する**（§3.2）。`.summary` と `.transcript` を単純連結すると `# タイトル` が 2 回出る問題もこれで消える |
| CH3 | **既定スコープはセッション全体**、`maxContextChars` を超えたら**サマリ + 直近セグメント**へ自動降格する。**予算は書き起こしだけでなく、サマリ・質問文・プロンプトに載せる会話履歴の合計で測る**（§3.2 の `resolve`）。降格したことは回答の上に控えめなラベル（「会議が長いため、サマリと直近の会話をもとに回答しています」）で示す — 黙って範囲を狭めると、答えが薄い理由がユーザーに分からない。閾値は文字数ベース（トークン数はクライアント側で測れない） |
| CH4 | **マルチターンは直近 6 ターン（3 往復）まで**。全履歴を毎回積むと、長い会議のコンテキストと合わさってコストが線形に膨らむ。6 ターンを超える履歴は画面には残るがプロンプトには載せない（画面とプロンプトの食い違いは §4.2 のラベルで示さない — 追い質問の文脈が切れるのは体感で分かるため過剰）。切り出しは**件数ではなく往復ペア単位**で行う（CH22） |
| CH5 | **出力は JSON schema 経由で受け取る**。`LLMRequest.schema`（`Kikimi/LLM/LLMTypes.swift:35`）は必須で、既存の全経路が `--json-schema` を通る。チャットの回答は自由記述の Markdown なので `{"answer": "<markdown>"}` の 1 フィールドスキーマで包む。新しい非構造化経路（`completeRaw` の直叩き）は作らない |
| CH6 | ~~**図は初版では出させない**~~ → **撤回**（`docs/design/39-webview-markdown.md` Phase C）。当初はシステムプロンプトに「図表は mermaid ではなく表と箇条書きで表現する」と書いていた。描画側の対応と独立に切り替えられるようプロンプト側に閉じ込めておいた判断は狙いどおり機能し、WebView 化が入った時点で 1 行の削除で済んだ |
| CH7 | **ストリーミングしない**。`LLMBackend` は `complete` 1 発で、Claude CLI バックエンドは 1 プロセス 1 応答。送信中は入力欄を disabled にし、回答枠にスピナーと経過秒数を出す |
| CH8 | **履歴は `chat.jsonl`**（`SessionFile.chatJSONL` を追加）。1 行 = 1 ターン（§3.4）。追記のみで、既存の `transcript.jsonl` / `llm_usage.jsonl` と同じ流儀（`SessionHandle` の JSONL 追記 API を使う）。**usage は `LLMUsage` ではなく `LLMUsageRecord` として持つ** — `LLMUsage` は `Codable` ですらなく、素朴に `Codable` を足しても `totalCostUSD` が `SessionJSONCoding` の `.convertToSnakeCase` / `.convertFromSnakeCase` で非可逆（encode `total_cost_usd` → decode 候補 `totalCostUsd`）で、非 optional なため decode が throw して行ごと壊れる。`LLMUsageRecord` は明示 `CodingKeys` でこの罠を回避済みで、`DictationHistoryEntry.llmUsage`（design 29）が同じ理由で同じ型を永続化している |
| CH9 | **質問と回答を別の行として書く**。1 行に往復をまとめない — 回答が失敗したとき、質問だけが残って再送できる形が自然（失敗は `role: assistant` + `error` の行として残す。§6） |
| CH10 | **`ChatConfig` を新設**（`chat.model` / `chat.max_context_chars` / `chat.history_turns` / `chat.timeout_seconds`）。37 では config を足さなかったが、ここはモデル選択が要る（既定 `claude-haiku-4-5-20251001` = `WatchersConfig.defaultModel` と同じ。長い会議の要約質問で賢いモデルに変えたい要求は自然に出る） |
| CH11 | **課金は既存の `UsageRecordingLLM` を通す**（16 章）。そのために **`LLMRequest.stubKey` に `"chat"` を必ず指定する** — `UsageRecordingLLM.recordUsage` は `purpose: request.stubKey ?? "unknown"` で記録するので、指定しないとチャットのコストがバッジ内訳の `unknown` に他の呼び出しと混ざって識別できない。あわせて **`LLMUsageBadge.displayLabel(forPurpose:)` に `case "chat": return "チャット"` を足す**（`refinement`/`summary_patch`/`final_title`/`dictation` と同じ扱い）。専用の集計は作らない |
| CH11b | **stub モードに `"chat"` の応答を登録する**。`LLMClient.complete` は `stubProvider.isEnabled`（`KIKIMI_STUB_LLM=1`）のとき全リクエストを `LLMStubProvider` に回し、`resolveRawJSON` は未登録キーに `missingStructuredOutput` を throw する。`builtinDefaults` は現在空、動的生成は `"refinement"` だけなので、**CH11 の `stubKey: "chat"` を入れた瞬間、`mise run verify-smoke` / `kikimi-verify`（レイヤ 2）でチャット送信が 100% 失敗する**。`LLMStubProvider.builtinDefaults` に `"chat": "{\"answer\": \"[stub] ...\"}"` を追加する（§8.1(c)）。`KIKIMI_STUB_LLM_FILE` での上書きは従来どおり効く |
| CH12 | **副作用を持たない**。チャットは読むだけで、話者リネーム・サマリ更新・Watcher 生成のような書き込みはしない。LLM に tool を渡さない（`LLMRequest` にそもそも tool の口がない） |
| CH13 | **Ended でも使える**。録音の状態を一切見ない（`recordingButtonState` に依存しない）。会議後に「あの件どうなった」と聞くのはむしろ主用途 |
| CH14 | **Wiki export には含めない**。export は「会議で何が話されたか」の記録で、チャットは Kikimi の操作履歴。混ぜない（将来 §9） |
| CH15 | **会話履歴は `LLMRequest.messages` として渡し、平坦化が要るかどうかはバックエンドが決める**（§4.1）。`LLMRequest` に `messages: [LLMMessage]? = nil` を追加する（既存の呼び出し元は `nil` のまま無改修）。OpenAI 互換バックエンドは配列をそのまま送り、Claude CLI バックエンドは自分で 1 本の user 文字列へ畳む。**平坦化をプロンプト組み立て側に置かない**のが要点 — 置くと、CLI が将来 `--input-format stream-json` に対応したときにプロンプト構築から作り直しになる |
| CH16 | **プロンプトは「安定した大きい塊 → 伸びる部分 → 最新の質問」の順に並べる**（§4.2）。会議の記録・これまでのやりとり・質問の順。逆順（やりとりが先）だと毎ターンの追記が書き起こしより前に入り、キャッシュのプレフィックスが毎回崩れる |
| CH17 | **プロンプトキャッシュは前提にしない**（§4.3）。録音中は書き起こしが伸びるため毎回ミスする。CLI の stdin 側がキャッシュされるかも未計測で、実装スパイクで `LLMUsage.cacheReadInputTokens` を見て確認する |
| CH18 | **1 質問ごとに書き起こし全文を再送する**ことを許容する（§4.4）。1 時間の会議で 1 質問あたり約 $0.03。既存のセッション別コスト集計に乗るので、専用の警告・レート制限は初版では持たない |
| CH19 | **タイムアウトは `chat.timeout_seconds`（既定 180）で明示的に渡す**。`LLMRequest.timeout` の既定 60 秒は、バッチ／直近セグメント単位の小さいプロンプトしか送らない既存の呼び出し元（`RefinementQueue` / `SummaryUpdater` / `WatcherRunner` はいずれも上書きしていない）に合わせて決まった値で、`max_context_chars: 120000` を許すチャットには根拠が引き継げない（入力規模が 1 桁違い、加えて claude CLI の起動時間が乗る）。`DictationRefiner` が `dictation.refine_timeout_ms` を `LLMRequest(timeout:)` に渡している前例に倣い、`ChatRunner` が `config.timeoutSeconds` を渡す。180 秒は実測前の暫定値で、§4.3 の実装スパイクで実時間を測って調整する |
| CH20 | **`LLMProcessRunner` の stdin write を非同期化してからチャットを実装する**（§8.1(a)）。現行の `stdinPipe.fileHandleForWriting.write(stdinData)` は同期ブロッキング write で、タイムアウトの race はその**次の行**で初めて始まる。macOS のパイプバッファは最大 64KB、既存の呼び出し元のプロンプトはすべてそれ未満なので write はバッファに収まって即座に返っており、**この経路は今まで一度も踏まれていない**。`max_context_chars: 120000` は日本語 UTF-8 で約 360KB なので確実に超え、(a) claude が stdin を読む前に固まる／起動に失敗すると write が返らず、race に到達していないため**タイムアウトが一切効かずチャットが永久に応答待ちになる**、(b) 正常系でも協調スレッドプールのスレッドを数百 ms〜数秒ブロックする（Swift Concurrency の forward-progress 規約違反。録音中は STT / 整形と同居する）。**代案の「`max_context_chars` を 64KB 相当（日本語で約 2 万字）まで下げる」は採らない** — 30 分程度の会議で常に降格することになり CH3 の「通常の会議は降格しない」が成立せず、しかも 64KB 超のプロンプトを送る次の機能が同じ地雷を踏み直す |
| CH21 | **再送は `replaces_turn_id` で畳む**。`chat.jsonl` は追記のみ（CH8）で失敗も行として残る（CH9）ため、再送が成功したあとウィンドウを開き直すと失敗行と成功行の両方が復元されて履歴が二重に見える。`ChatTurn` に `parentTurnId`（どの user ターンへの回答か）と `replacesTurnId`（どの失敗ターンを置き換えたか）を持たせ、**読み込み時に純粋関数で畳む**（§3.4）。ファイル形式は追記のみのまま、表示だけが畳まれる |
| CH22 | **プロンプトに載せる履歴は往復ペア単位で正規化する**。§4.2 が `messages[1]` にダミー assistant を置くのは「役割が交互でないことを嫌うバックエンドがある」ためだが、単純な「末尾 N 件」では交互性が壊れる: (a) `error` ターンを除外すると user が連続する、(b) 回答前にクラッシュ／close した「回答の無い user ターン」が残る、(c) 除外後の列が奇数長だと切り出しが assistant から始まり、ダミー assistant の直後に assistant が並ぶ。`(user, assistant)` の隣接ペアだけを残し、末尾から `historyTurns / 2` 組を取る（§3.3 の `normalizeHistory`） |

## 3. コンポーネント構成

```mermaid
flowchart TB
    UI[ChatTabView<br/>履歴リスト + 入力欄] --> VM[MeetingWorkspaceViewModel<br/>@Published は本体、メソッドは +Chat.swift]
    VM -->|送信| RUN[ChatRunner<br/>nonisolated + Sendable]
    RUN -->|読み出し| SRC[TranscriptMarkdownSource<br/>design 37 §3.2b]
    SRC --> CB[ChatContextBuilder<br/>純粋・scope 決定と切り詰め]
    RUN --> CB
    RUN -->|履歴の正規化| NORM[ChatHistoryNormalizer<br/>純粋・往復ペア化]
    RUN -->|メッセージ列組み立て| PB[ChatPromptBuilder<br/>純粋]
    RUN -->|complete| LLM[LLMCompleting<br/>UsageRecordingLLM 経由]
    VM -->|追記| STORE[SessionHandle<br/>chat.jsonl]
    STORE -->|起動時ロード| FOLD[ChatTurnLog.fold<br/>純粋・再送の畳み込み]
    FOLD --> VM
```

### 3.1 `ChatPromptBuilder`（`Kikimi/Chat/ChatPromptBuilder.swift` 新設）

純粋関数のみ。`WatcherPromptBuilder`（`Kikimi/Watchers/WatcherPromptBuilder.swift`）と同じ流儀で、
I/O も config も見ず、渡された値を組み立てるだけ。

```swift
enum ChatPromptBuilder {
    /// 送信 1 回分の入力。`contextMarkdown` は `ChatContextBuilder` の出力（`# タイトル` を含む
    /// 完成した本文）、`history` は `ChatHistoryNormalizer` を通した**交互・偶数長**のターン列
    /// （古い順）。
    struct Input {
        var contextMarkdown: String
        var history: [ChatTurn]
        var question: String
    }

    static func buildSystem() -> String

    /// `LLMRequest.user` に入れる文字列。**最新の質問だけ**を返す（§4.2 の末尾 user）。
    /// コンテキストも履歴もここには入らない。
    static func buildUser(_ input: Input) -> String

    /// `LLMRequest.messages` に入れる列（§4.2）。返り値は必ず
    /// `[user(コンテキスト), assistant(確認応答)] + history` で、偶数長・role 交互・先頭は `.user`。
    /// 末尾の質問は含まない（それは `buildUser(_:)` の担当）。
    static func buildMessages(_ input: Input) -> [LLMMessage]

    /// `{"answer": "<markdown>"}` の 1 フィールドスキーマ（CH5）。
    static let answerSchema: String

    /// `messages[1]` に置く固定のダミー assistant 応答（CH22 / §4.2）。
    static let contextAcknowledgement: String
}
```

`buildUser` と `buildMessages` は必ずペアで使う。`ChatRunner` は
`LLMRequest(system: buildSystem(), user: buildUser(input), messages: buildMessages(input), ...)` と
組み立てるだけで、**どちらの関数もコンテキストと履歴の配置を独自に決めない**（§4.2 の並びは
`buildMessages` の実装 1 箇所にだけ書かれる）。

システムプロンプトに書くこと:

- 役割（この会議の書き起こしについて答えるアシスタント）
- **書き起こしは音声認識と LLM 整形を経ており、誤変換や話者の取り違えがあり得る**こと。断定できない
  ときは「書き起こしからは読み取れない」と答えること（推測で埋めない）
- `*(raw)*` が付いた行は未整形の生テキストであること
- 回答は Markdown。**図は mermaid のコードブロックで**（CH6 は `docs/design/39-webview-markdown.md` で撤回済み）
- 引用するときは `HH:MM:SS` と話者名を添えること

### 3.2 `ChatContextScope` / `ChatContextBuilder`（CH2 / CH3）

```swift
enum ChatContextScope: String, Codable, Sendable {
    /// セッション全体の書き起こし。
    case full
    /// サマリ + 直近セグメント（`full` が長すぎたときの降格先）。
    case summaryAndRecent
}

/// `resolve` の結果。`.summaryAndRecent` のときだけ `transcriptBudget` が意味を持つ。
struct ChatContextResolution: Sendable, Equatable {
    var scope: ChatContextScope
    /// 書き起こし行に割り当てられる文字数（0 以上）。`.full` のときは書き起こし全体の長さ。
    var transcriptBudget: Int
}
```

**予算はプロンプト全体で測る**（CH3）。純粋関数のシグネチャは以下で、書き起こしの長さだけでなく
サマリ・質問文・プロンプトに載せる履歴の長さも受け取る。

```swift
extension ChatContextScope {
    static func resolve(
        transcriptLength: Int,
        summaryLength: Int,
        questionLength: Int,
        historyLength: Int,
        maxContextChars: Int
    ) -> ChatContextResolution
}
```

判定:

1. `fixed = summaryLength + questionLength + historyLength`（降格しても縮まない部分）
2. `transcriptLength + fixed <= maxContextChars` なら `.full`（`transcriptBudget = transcriptLength`）
3. 超えていたら `.summaryAndRecent`、`transcriptBudget = max(0, maxContextChars - fixed)`

4 つの長さの測り方も設計で固定する（実装が推測しないように）:

| 引数 | 測り方 |
|---|---|
| `transcriptLength` | `ChatContextBuilder.measure(_:)` が返す「全行を `renderLine` で整形して連結したときの文字数」。実際に送る文字列と同じ尺度で測るため、生のセグメント本文の長さではない |
| `summaryLength` | `input.summaryMarkdown.count`（見出し `## サマリ` の分は誤差として無視する） |
| `questionLength` | trim 後の質問文の `count` |
| `historyLength` | `ChatHistoryNormalizer` を**通したあと**の各ターンの `text` の合計 `count` |

`ChatContextBuilder.measure(_ input:) -> (transcriptLength: Int, summaryLength: Int)` を
`build(_:resolution:)` と同じファイルに置き、**整形と計測が同じコードを共有する**ようにする
（別々に数えると、予算計算と実際の出力が静かにずれる）。`historyLength` は**正規化の前後で変わるので、
必ず正規化してから測る**。`fixed` 自体が `maxContextChars` を超える極端なケース
（12 万字の書き起こし + 3 万字の貼り付け質問など）では `transcriptBudget` が 0 になり、書き起こし
セクションは見出しごと省かれる。**質問文と履歴は切り詰めない** — ユーザーが書いたものを黙って削るより、
材料が足りないことを降格ラベルで示すほうが誠実。それでもモデル側のコンテキスト上限を超えるなら
§5 の「LLM 呼び出しの失敗」に落ちる。

`WatcherInputScope`（`Kikimi/Watchers/WatcherDefinition.swift:57`）と概念は近いが**別の型にする**。
あちらは Watcher 定義ファイルのフロントマターに書かれるユーザー設定値で、パーサ・シリアライザ・
`SimpleWatcher` の UI が紐づいている。チャットの降格は実行時に自動で決まる内部状態で、設定でもなければ
永続化される定義でもない。同じ名前の型に 2 つの意味を持たせない。

**`ChatContextBuilder`**（`Kikimi/Chat/ChatContextBuilder.swift` 新設、純粋）が実際の Markdown を組む。

```swift
enum ChatContextBuilder {
    struct Output: Sendable, Equatable {
        var markdown: String
        var scope: ChatContextScope
    }

    /// `input` は `TranscriptMarkdownSource.load(sessionHandle:)` の出力そのまま。
    /// `resolution` は上の `ChatContextScope.resolve(...)` の結果。
    static func build(
        _ input: TranscriptMarkdownRenderer.Input,
        resolution: ChatContextResolution
    ) -> Output
}
```

出力の形（`# タイトル` は**必ず 1 回だけ**。空セクションは見出しごと省く — 37 TC14 と同じ規則）:

```
# {meta.title}

## サマリ                        ← summaryMarkdown が空なら省略
{summaryMarkdown}

## 書き起こし                    ← .summaryAndRecent のときは「## 書き起こし（直近）」
{行}
```

各行は `TranscriptMarkdownRenderer.renderLine(_:meta:)` をそのまま呼ぶ（`**HH:MM:SS 話者** 本文
`*(raw)*`）。**行の整形規則は 37 と 1 箇所を共有する**ので、書式がドリフトしない。

切り詰めの規則（`.summaryAndRecent`）:

- `startMs` 昇順に整列したうえで、**末尾の行から順に採用**し、採用済みの文字数合計が
  `resolution.transcriptBudget` を超える 1 行手前で止める
- **行の途中で切らない**（切れた行は話者と時刻の対応が壊れて誤読の元になる）
- 1 行も入らない場合は `## 書き起こし（直近）` の見出しごと省く
- サマリは切り詰めない（`resolve` が `fixed` に丸ごと入れている前提を崩さない）

### 3.3 `ChatRunner`（`Kikimi/Chat/ChatRunner.swift` 新設）

`struct ChatRunner: Sendable`。`@MainActor` を付けない（コンテキスト組み立てが
`TranscriptMarkdownSource` 経由でセグメント数 × turn 数の話者解決を回すため。37 §3.2(b) と同じ理由）。

```swift
struct ChatRunner: Sendable {
    var llm: any LLMCompleting
    var source: TranscriptMarkdownSource
    var config: ChatConfig

    /// 1 往復。`history` は保存済みの全ターン（切り詰めはこの中で行う）。
    func ask(
        question: String,
        history: [ChatTurn],
        sessionHandle: SessionHandle
    ) async throws -> ChatAnswer
}

struct ChatAnswer: Sendable {
    var markdown: String
    var contextScope: ChatContextScope
    var usage: LLMUsage
    /// `LLMResult.respondedModel ?? request.model`。
    var model: String
}
```

`ask` の手順:

1. `source.load(sessionHandle:)` で `TranscriptMarkdownRenderer.Input` を読む
2. `ChatHistoryNormalizer.normalize(history, maxTurns: config.historyTurns)` で履歴を正規化
3. `ChatContextBuilder.measure(input)` と質問長・正規化済み履歴長から
   `ChatContextScope.resolve(...)` を呼び、scope と `transcriptBudget` を決める（§3.2 の表）
4. `ChatContextBuilder.build(input, resolution:)` でコンテキスト本文を組む
5. `ChatPromptBuilder.buildSystem()` / `buildMessages(_:)` / `buildUser(_:)` で
   `LLMRequest(system:user:messages:schema:model:timeout:stubKey:)` を組む
   （`model: config.model`、`timeout: .seconds(config.timeoutSeconds)`（CH19）、
   `stubKey: "chat"`（CH11））
6. `llm.complete(_:)` を await し、`{"answer": ...}` を `ChatAnswer` に詰め替える

**履歴の正規化**（`ChatHistoryNormalizer`、`Kikimi/Chat/ChatHistoryNormalizer.swift` 新設、純粋。CH22）:

```swift
enum ChatHistoryNormalizer {
    /// 戻り値は必ず偶数長・role 交互・先頭 `.user`・末尾 `.assistant`。
    static func normalize(_ turns: [ChatTurn], maxTurns: Int) -> [ChatTurn]
}
```

1. 先頭から走査し、`(user, assistant)` の**隣接ペア**だけを組む。ペアにならない行は捨てる:
   - `assistant` が `error` を持つペア（失敗の痕跡を次の質問の文脈に混ぜない）
   - `assistant` が続かない `user`（回答待ちのままクラッシュ／close した行、§3.6 手順 2）
   - `user` が先行しない `assistant`（畳み込み漏れに対する防御）
2. 残ったペア列の**末尾から `maxTurns / 2` 組**を取る（`historyTurns: 6` なら 3 組 = 6 ターン。
   奇数を設定されたら整数除算で切り捨て — 交互性のほうを優先する）
3. 平坦化して返す

これで §4.2 の `messages` は
`[user(コンテキスト), assistant(確認応答)] + 正規化済み履歴 + [user(最新の質問)]` となり、
**role は常に交互**になる（OpenAI 互換バックエンドの `messages` 配列にそのまま渡せる）。

### 3.4 `ChatTurn` と `chat.jsonl`（CH8 / CH9）

```swift
struct ChatTurn: Codable, Sendable, Equatable, Identifiable {
    var id: String            // EntryIdNaming.makeId(for:) の既存流儀に合わせる
    var role: ChatRole        // .user / .assistant
    var text: String          // user は質問、assistant は回答 Markdown（失敗時は空）
    var createdAt: Date
    /// assistant のみ。どの user ターンへの回答か（CH21）。
    var parentTurnId: String?
    /// assistant のみ。再送で作られたターンが置き換える、失敗した assistant ターンの id（CH21）。
    var replacesTurnId: String?
    /// assistant のみ。`LLMUsage` ではなく `LLMUsageRecord`（CH8 の理由）。`model` もこの中にある。
    var usage: LLMUsageRecord?
    var contextScope: ChatContextScope?
    /// assistant のみ。非 nil なら失敗ターン（§6）。
    var error: String?
}
```

**`LLMUsage` を直接持たない**（CH8）。`LLMUsage` は `Codable` ですらなく、素朴に `Codable` を足しても
`totalCostUSD` が `SessionJSONCoding` の `.convertToSnakeCase` / `.convertFromSnakeCase` の往復で
非可逆（encode `total_cost_usd` → decode 候補 `totalCostUsd`）。非 optional なので decode が throw し、
その行が「壊れた行」として丸ごとスキップされる。`LLMUsageRecord` は明示 `CodingKeys`
（`case reportedCostUSD = "reportedCostUsd"`）でこの罠を回避済みで、`DictationHistoryEntry.llmUsage`
（design 29）が同じ理由で同じ型を永続化している。`ChatRunner` が返した `LLMUsage` は
ViewModel が `LLMUsageRecord.make(usage:respondedModel:requestedModel:purpose:timestamp:)`
（`purpose: "chat"`）で詰め替えてから書く。

`ChatTurn` 自身の `CodingKeys` は暗黙のまま（プロパティ名と一致）でよい — 全フィールドが
`SessionJSONCoding` の往復に対して不動点（末尾に全大文字の略語を持つ名前が無い）。`SessionParticipants`
と同じ規約で、**明示的な snake_case 文字列 rawValue を書いてはいけない**（二重変換になる）。

`SessionFile` に `case chatJSONL`（パスは `chat.jsonl`）を追加する。読み書きは
`SessionHandle+Transcript.swift` の JSONL 追記・全読みと同じ形で `SessionHandle+Chat.swift` に置く。

**読み込み時の畳み込み**（`ChatTurnLog.fold(_:)`、純粋。CH21）:

```swift
enum ChatTurnLog {
    /// 追記順に読んだ行を、表示用の履歴に畳む。
    static func fold(_ turns: [ChatTurn]) -> [ChatTurn]
}
```

1. `replacesTurnId` が非 nil のターンについて、その値を「置き換えられた id」の集合に入れる
2. その集合に含まれる id を持つターンを取り除く
3. 残りを追記順のまま返す（`createdAt` で並べ替えない — 追記順が唯一の全順序で、
   同一秒内の 2 行が入れ替わるのを避ける）

これで「失敗した assistant 行」と「再送で成功した assistant 行」が二重に表示されない。`chat.jsonl`
自体は追記のみのまま（CH8/CH9 は不変）で、畳むのは表示だけ。まだ再送していない失敗ターンは畳み込みで
残り、プロンプトからは `ChatHistoryNormalizer` が外す（§3.3）。

### 3.5 UI（`Kikimi/Views/MeetingWorkspace/ChatTabView.swift` 新設）

```
┌────────────────────────────────────┐
│ ▲ 会議が長いため、サマリと直近の      │  ← 降格ラベル（該当時のみ）
│   会話をもとに回答しています          │
├────────────────────────────────────┤
│                    ┌──────────────┐│
│                    │ 決まったことは？││  ← user（右寄せ）
│                    └──────────────┘│
│ ┌────────────────────────────────┐ │
│ │ ## 決定事項                     │ │  ← assistant（`ChatWebView`）
│ │ - リリースは来週火曜            │ │
│ │             [コピー] [00:12:03]│ │
│ └────────────────────────────────┘ │
├────────────────────────────────────┤
│ ┌────────────────────────────────┐ │
│ │ 質問を入力…                     │ │  ← 複数行、⌘⏎ で送信
│ └────────────────────────────────┘ │
│                          [送信 ⌘⏎] │
└────────────────────────────────────┘
```

- 履歴リストは**下が最新**で、送信・回答のたびに末尾へ自動スクロールする。
  `TranscriptAutoFollow`（`Kikimi/Views/MeetingWorkspace/TranscriptAutoFollow.swift`）の
  ピン留め規則をそのまま使う — 同じ「末尾に張り付いている間は追従する」問題であり、
  同じ解を 2 つ実装しない
- 回答の描画は `ChatWebView`（`docs/design/39-webview-markdown.md` §3.6）。履歴全体を 1 つの WebView で
  描き、吹き出し・コピー/再送ボタン・自動追従は `web/src/chat.ts` が持つ。**質問の吹き出しは Markdown として
  解釈しない**（`# 確認` が見出しに化けるため）
- 各回答に「コピー」ボタン。37 の `PasteboardWriting` を注入して使う
- 入力欄は複数行。**⌘⏎ で送信**（⏎ は改行 — 会議中に長い質問を書くことがあるため）
- 送信中は入力欄と送信ボタンを disabled にし、回答枠にスピナーと経過秒数を出す（CH7）
- 空のときは「この会議について質問できます（例: ここまでの決定事項は？）」のプレースホルダ

### 3.6 ViewModel

**`@Published` は本体（`Kikimi/ViewModels/MeetingWorkspaceViewModel.swift`）に宣言し、メソッドだけを
`MeetingWorkspaceViewModel+Chat.swift` に置く**。Swift の extension は格納プロパティを追加できないため
（`SessionHandle+Transcript.swift` の doc comment が同じ制約を明記している）、既存の
`MeetingWorkspaceViewModel+*.swift` 22 ファイルも 1 つも格納プロパティを宣言しておらず、`@Published` は
すべて本体に集約されている。その流儀に従う。

本体に足すプロパティ:

```swift
@Published private(set) var chatTurns: [ChatTurn] = []
@Published private(set) var isChatResponding = false
@Published var chatDraft: String = ""
```

`+Chat.swift` に置くメソッド:

```swift
func loadChatHistory() async          // onAppear（既存の初期ロード列に足す）
func sendChatMessage() async          // chatDraft を送信
func retryChatTurn(id: String) async  // 失敗ターンの再送
func copyChatAnswer(id: String)       // 37 の PasteboardWriting
```

送信の手順:

1. `chatDraft` を trim。空なら何もしない
2. `ChatTurn(role: .user)` を作って `chatTurns` に追加 + `chat.jsonl` へ追記。`chatDraft` を空にする
3. `isChatResponding = true`
4. `chatRunner.ask(...)` を await
5. 成功なら `ChatTurn(role: .assistant, parentTurnId: <手順 2 の id>, usage: LLMUsageRecord.make(...))`
   を、失敗なら同じ `parentTurnId` を持つ `error` 付き assistant ターンを追加 + 追記
6. `isChatResponding = false`

**質問を先に永続化する**（手順 2）のは、回答待ちの間にクラッシュ・アプリ終了が起きても質問が消えない
ようにするため。`transcript.jsonl` が確定ごとに追記されるのと同じ考え方。回答が書かれないまま残った
user ターンは、次回ロード時も表示され（畳み込みの対象ではない）、プロンプトからは
`ChatHistoryNormalizer` が外す。

再送（`retryChatTurn(id:)`）の手順（CH21）:

1. `id` は**失敗した assistant ターン**の id。その `parentTurnId` が指す user ターンの `text` を
   質問として `chatRunner.ask(...)` を呼ぶ
2. 成功・失敗どちらでも、`parentTurnId: <同じ user ターン>` と `replacesTurnId: id` を持つ
   **新しい** assistant ターンを追加 + 追記する（失敗行を書き換えない = 追記のみを保つ）
3. 画面上は `ChatTurnLog.fold` と同じ規則で、置き換えられたターンを配列から除く

`loadChatHistory()` は `SessionHandle` から全行を読み、`ChatTurnLog.fold(_:)` を通してから
`chatTurns` に入れる。

## 4. プロンプトとコンテキスト管理

### 4.1 会話履歴は `messages` で渡し、平坦化はバックエンドが担う（CH15）

**なぜ役割つきの配列で渡したいのか**（採用の根拠なので明記する）:

- **過去の回答が「自分の発話」としてモデルに届く**。平坦化して `Q:` / `A:` のテキストにすると、
  自分の過去の回答まで user の発話として渡ることになり、「さっきの答えは違うのでは」という追い質問で
  訂正するより追従しやすくなる
- **書き起こし本文と会話履歴が構造で分かれる**。同じ user メッセージに同居していると、`Q:` / `A:` の
  行が会議の発言として読まれる余地が残る
- **キャッシュの区切りが自然に置ける**（§4.3）

差は劇的ではない — 見出しで区切れば平坦化でもおおむね動く。堅牢さの問題として採る。

**バックエンドごとの対応可否**（調査結果）:

| バックエンド | 会話配列 |
|---|---|
| OpenAI 互換 | そのまま渡せる（`OpenAIChatBackend.swift:232` の `messages` を組み立て直すだけ） |
| Claude CLI | 現行の `--output-format json` + `--json-schema`（`ClaudeCLIBackend.swift:48`）は単発。`--input-format stream-json` は存在するが `--output-format stream-json` とセットが前提で、応答パースの全面書き換えを伴う。**当面は平坦化する** |
| スタブ | `stubKey` でディスパッチするだけなので無関係 |

**設計**: `LLMRequest` に `messages: [LLMMessage]? = nil` を追加する（`LLMMessage` は
`role: .user/.assistant` + `text: String`）。既存の呼び出し元（整形・サマリ・タイトル・Watcher）は
`nil` のままで 1 バイトも挙動が変わらない。`nil` でないとき、各バックエンドは自分の流儀で扱う:

- OpenAI 互換: `[system] + messages + [user]` を `messages` 配列として送る
- Claude CLI: `messages` を `Q:` / `A:` 形式のテキストへ畳み、`user` の前に連結して stdin に渡す
  （**畳んだ結果は 64KB を優に超えるので、CH20 の stdin 非同期化が前提になる**）

**平坦化をプロンプト組み立て（`ChatPromptBuilder`）側に置かない**のがこの決定の要点。置いてしまうと、
CLI が stream-json 入力に対応した日にプロンプト構築から作り直しになる。バックエンドに置けば、
その日の変更は `ClaudeCLIBackend` 1 ファイルに閉じる。

### 4.2 プロンプトの並び順（CH16）

**安定した大きい塊を前、ターンごとに伸びる部分を後ろ**に置く。

```
system:      役割・書き起こしの信頼性・出力規則（毎回同一・小さい）

messages[0]: user      # {title}              ← ChatContextBuilder.build(...).markdown
                       ## サマリ               そのまま。大きく、質問間で比較的安定
                       ## 書き起こし
                       （.summaryAndRecent なら「## 書き起こし（直近）」）
messages[1]: assistant （書き起こしを読んだことの短い確認 = contextAcknowledgement）
messages[2]: user      前半の議論の論点は？   ← 過去のやりとり（正規化済み、最大 6 ターン）
messages[3]: assistant （回答の Markdown）
user:                  {question}            ← 最新
```

この配置を組むのは `ChatPromptBuilder.buildMessages(_:)`（`messages[0..]`）と `buildUser(_:)`
（末尾の `user`）の 2 つだけで、`ChatRunner` は結果を `LLMRequest` に詰めるだけ（§3.1）。

書き起こしを `messages[0]` の user メッセージとして先頭に置き、以降を実際のやりとりが積み上がる形に
する。`messages[1]` の短い assistant 応答は、会話が user から始まり user/assistant が交互に並ぶ形を
保つためのもの（役割が交互でないことを嫌うバックエンドがある）。**交互性は `messages[1]` だけでは
保証されない** — 履歴側も `ChatHistoryNormalizer` で往復ペアに正規化してから連結する（CH22 / §3.3）。

初稿はやりとりを会議の記録より**前**に置いていたが、それだと毎ターン伸びるブロックが大きな書き起こしの
前に挟まり、プロンプトキャッシュのプレフィックスが毎回崩れる。この並びなら、古いターンを
`historyTurns` で切り捨てても先頭 2 メッセージは 1 バイトも変わらない。最新の質問が末尾に来るのも、
モデルの注意の当たり方として素直。

空セクションは見出しごと省く（37 TC14 と同じ規則。LLM に「該当なし」の見出しを見せない）。

Claude CLI バックエンドはこの列を 1 本のテキストへ畳んで渡すため（§4.1）、**畳んだ後も同じ順序に
なる**。並び順の意図はバックエンドをまたいで保たれる。

### 4.3 キャッシュは前提にしない（CH17）

§4.2 の並び順はキャッシュに有利だが、**効く場面は限られる**ので設計上の前提にはしない。

- **録音中は書き起こしが伸び続ける**ので、質問のたびにプレフィックスが変わり毎回ミスする。
  チャットの主用途の一つが「会議中に今までの流れを聞く」である以上、これは例外ではなく常態
- Ended セッションへの連続質問なら安定して効く
- `docs/design/12-llm-client.md:67` が計測しているのは `--system-prompt` の `cache_creation` だけで、
  **CLI に stdin で渡す user 側がキャッシュされるかは未計測**。実装スパイクで
  `LLMUsage.cacheReadInputTokens` / `cacheCreationInputTokens`（既に記録している、`:128-129`）を
  見て確認する

### 4.4 1 質問ごとに全文を再送するコスト（CH18）

会話履歴を持たない単発 API なので、**質問のたびに書き起こし全文が入力トークンになる**。

- 1 時間の会議の整形済み書き起こしはおおむね 3〜4 万字 ≒ 3 万トークン前後
- Haiku の入力単価で 1 質問あたり約 $0.03、10 往復で約 $0.3
- キャッシュが効けば読み出しは 1/10

`max_context_chars: 120000`（§6）に収まる限り降格しないので、通常の会議はこの水準で頭打ちになる。
チャットのコストは既存のセッション別集計（16 章）にそのまま乗るため、使いすぎはヘッダのバッジで
ユーザー自身が気づける。専用の警告やレート制限は初版では持たない。

### 4.5 降格ラベル（CH3）

`contextScope == .summaryAndRecent` の回答にだけ、回答枠の上に控えめな注記を出す。回答ごとの
プロパティなので、後から履歴を読み返しても「この回答は限られた材料で出た」ことが分かる。

## 5. 失敗モード

| 状況 | 挙動 |
|---|---|
| LLM 呼び出しの失敗（ネットワーク・認証・タイムアウト） | `error` 付き assistant ターンとして履歴に残し、行に「再送」ボタンを出す。入力欄の内容は失わない（質問は既に user ターンとして残っている）。タイムアウト値は `chat.timeout_seconds`（CH19）。**タイムアウトが実際に発火するには CH20 の stdin 非同期化が必要** |
| 再送が成功したあとウィンドウを開き直す | `replacesTurnId` を見て失敗ターンを畳むので二重表示にならない（CH21 / §3.4） |
| 回答 JSON のパース失敗 | 同上（`error` に「回答を解釈できませんでした」）。生の応答は `.error` ログにだけ出す |
| `chat.jsonl` への追記失敗 | 画面上の履歴はそのまま進める（回答は見えている）。`.error` ログ。次回起動時に欠ける可能性はあるが、**回答を見せないより良い** |
| `chat.jsonl` の読み込み失敗・壊れた行 | 読めた行までを表示して続行（`transcript.jsonl` の防御的デコードと同じ流儀）。`.warning` ログ |
| 書き起こしが 0 行（録音直後） | 送信自体は可能。コンテキストは空になるので、システムプロンプトの「読み取れないときはそう答える」規則で LLM が答える |
| サマリ未生成で `.summaryAndRecent` に降格 | サマリセクションを省いて直近セグメントだけで組み立てる |
| 送信中にウィンドウを閉じる | 既存の stow 規則で Recording/Paused なら stow される。Ended で本当に閉じた場合、`ask` の `Task` は ViewModel と一緒に破棄され回答は失われる（質問は残る）。**回答待ちを理由に close をブロックはしない** |
| 送信中に会議終了 | 何もしない（チャットは録音状態に依存しない、CH13） |
| 極端に長い質問（貼り付けなど） | `resolve(transcriptLength:summaryLength:questionLength:historyLength:maxContextChars:)` が質問長・履歴長も予算に含めて降格判定する（§3.2）。質問と履歴自体は切り詰めず、書き起こしの予算を 0 まで削る |
| `KIKIMI_STUB_LLM=1`（kikimi-verify / verify-smoke） | `LLMStubProvider.builtinDefaults["chat"]` の固定応答が返る（CH11b）。`KIKIMI_STUB_LLM_FILE` で上書き可能 |

## 6. config（CH10）

```yaml
chat:
  model: claude-haiku-4-5-20251001
  max_context_chars: 120000
  history_turns: 6
  timeout_seconds: 180
```

`ChatConfig`（`Kikimi/Config/ChatConfig.swift` 新設）。`KikimiConfigData` に `chat` を足す。
既存 config に `chat:` が無い場合は `.default` にフォールバックする（`KikimiConfigData` の
既存フィールドと同じ防御的デコード）。設定 UI（`ModelSettingsTab`）にモデル欄を 1 つ足す。
`max_context_chars` / `history_turns` / `timeout_seconds` は 0 以下なら既定値へフォールバックし
`.warning` ログを出す（`RefinementConfig.batchTimeoutMs` / `DictationConfig.refineTimeoutMs` と同じ流儀）。

`max_context_chars` の既定 120,000 は、日本語 1 文字 ≒ 1 トークン弱として約 10 万トークン相当で、
Claude の 200k コンテキストに対して回答生成の余裕を残した値。1 時間の会議の整形済み書き起こしは
おおむね 3〜4 万字なので、**通常の会議は降格しない**。

`timeout_seconds` の既定 180 は暫定値（CH19）。`LLMRequest.timeout` の既定 60 秒は、バッチ単位の
小さいプロンプトしか送らない既存の呼び出し元に合わせて決まったもので、12 万字を許すチャットには
根拠が引き継げない。§4.3 の実装スパイクで、`.full` の実測（12 万字入力 + 数千トークン出力 +
claude CLI の起動）を測って調整する。

## 7. テスト（レイヤ 1）

- `ChatPromptBuilderTests`（純粋）: (a) `buildUser` が**質問だけ**を返し、コンテキストも履歴も
  含まないこと、(b) `buildMessages` が `[user(context), assistant(ack)] + 履歴` を返し、
  **偶数長・role 交互・先頭 `.user`** であること（履歴なし/ありの両方）、(c) スキーマの妥当性、
  (d) システムプロンプトが図の書き方（mermaid）と「推測しない」規則に触れていること
- `ChatContextScopeTests`（純粋）: (a) 閾値の境界で `.full` / `.summaryAndRecent` が切り替わること、
  (b) **質問長・履歴長・サマリ長が予算に算入される**こと（書き起こしが閾値以下でも合計超過なら降格）、
  (c) 固定部分だけで予算を使い切ると `transcriptBudget == 0` になること
- `ChatContextBuilderTests`（純粋）: (a) `# タイトル` が**1 回だけ**出ること、(b) 降格時に
  **行の途中で切らない**こと、(c) 予算 0 で書き起こしの見出しごと省かれること、(d) サマリが空でも
  組み立てが壊れないこと（見出しごと省く）、(e) 行の書式が
  `TranscriptMarkdownRenderer.renderLine(_:meta:)` と一致すること、(f) `measure(_:)` の
  `transcriptLength` が `.full` で組んだ出力の書き起こし部分の実長と一致すること
- `ChatHistoryNormalizerTests`（純粋）: (a) `error` ターンを含む列でも user が連続しないこと、
  (b) 回答の無い user ターンが落ちること、(c) 結果が常に偶数長・先頭 `.user`・末尾 `.assistant`
  であること、(d) `maxTurns` が奇数でも交互性が崩れないこと
- `ChatTurnLogTests`（純粋）: `replacesTurnId` を持つ行があるとき、置き換えられた失敗ターンが
  畳まれて**二重に出ない**こと。未再送の失敗ターンは残ること
- `ChatRunnerTests`: フェイク `LLMCompleting` で (a) 履歴が `historyTurns / 2` 往復に切られること、
  (b) `error` 付きターンがプロンプトから除外されること、(c) 長い会議で降格が起きること、
  (d) `LLMUsage` が `ChatAnswer` に伝わること、(e) `LLMRequest.stubKey == "chat"` と
  `timeout == .seconds(config.timeoutSeconds)` が渡ること
- `SessionHandle+Chat` テスト: `chat.jsonl` の追記・全読み round-trip、壊れた行のスキップ。
  **`usage`（`LLMUsageRecord`）を持つターンが round-trip し、`reportedCostUSD` が欠落しないこと**
- `MeetingWorkspaceViewModel+Chat` テスト: (a) 送信で user ターンが**回答前に**永続化されること、
  (b) 失敗が `error` 付き assistant ターンとして残り再送できること、(c) 再送が
  `replacesTurnId` 付きの新しい行として追記され、画面から失敗行が消えること、
  (d) `isChatResponding` の遷移、(e) 履歴のロードが `onAppear` で走ること
- `ChatTabView` 相当の純粋ロジック: 送信可否（空白のみの下書きは送れない）
- 既存テストへの追加: (a) `WorkspaceWindowState` のデコードで `active_tab: chat` が `.chat` に
  復元されること（CH1）、(b) `KIKIMI_STUB_LLM=1` + `stubKey: "chat"` が
  `missingStructuredOutput` を投げずに応答を返すこと（CH11b）、(c) `LLMProcessRunner` が
  64KB を超える stdin を渡してもタイムアウトが発火すること（CH20）

## 8. 既存コードへの改修

### 8.1 チャット本体より先に直すもの

**(a) `LLMProcessRunner` の stdin write を非同期化する（CH20）** — `Kikimi/LLM/LLMProcessRunner.swift`

現行:

```swift
if let stdinData = stdin.data(using: .utf8), !stdinData.isEmpty {
    stdinPipe.fileHandleForWriting.write(stdinData)   // ← 同期ブロッキング
}
try? stdinPipe.fileHandleForWriting.close()
let outcome = await race(termination: termination, timeout: timeout)   // ← ここで初めて race
```

改修方針:

- write と close を専用の detached `Task` に移し、**その完了を待たずに** `race(...)` に入る。
  こうすると、子が stdin を読まないまま固まってもタイムアウトが正しく発火し、`.timedOut` 経路の
  SIGTERM → SIGKILL で子が死んだ時点でパイプの読み手が消え、ブロックしていた write が EPIPE で解ける
- write は `FileHandle.write(_:)`（ObjC 例外）ではなく `try fileHandle.write(contentsOf:)` を使い、
  EPIPE を Swift エラーとして受ける。子が先に終了しても例外でアプリが落ちない
- `SIGPIPE` はプロセス起動時に一度 `SIG_IGN` にする（`KikimiApp` の起動処理）。これをしないと、
  子が stdin を読まずに終了した瞬間にアプリ全体がシグナルで死ぬ
- 既存の呼び出し元（`RefinementQueue` / `SummaryUpdater` / `WatcherRunner` / `DictationRefiner`）は
  すべて 64KB 未満なので、この変更で挙動が変わらないことを既存テストで確認する
- 回帰テスト: 64KB を超える stdin を、stdin を読まない子プロセス（`sleep` 等）に渡して
  `.timedOut` が返ること

**(b) `LLMRequest` に `messages` を追加する（CH15）** — `Kikimi/LLM/LLMTypes.swift`

`var messages: [LLMMessage]? = nil` と `struct LLMMessage: Sendable, Equatable { var role: Role; var text: String }`。
既存の呼び出し元は既定値 `nil` のまま無改修。`OpenAIChatBackend.buildURLRequest` と
`ClaudeCLIBackend` が `nil` でないときの扱いを実装する（§4.1）。

**(c) stub とコスト表示に `"chat"` を登録する（CH11 / CH11b）**

- `Kikimi/LLM/LLMStubProvider.swift`: `builtinDefaults` に `"chat": "{\"answer\": \"[stub] ...\"}"`
  を追加（現在は空）
- `Kikimi/Views/MeetingWorkspace/LLMUsageBadge.swift`: `displayLabel(forPurpose:)` に
  `case "chat": return "チャット"` を追加

**(d) `active_tab: chat` を復元する（CH1）** — `Kikimi/Config/AppState.swift`

`MeetingWorkspaceTab` に `case chat` を足すだけでは足りない。`WorkspaceWindowState.init(from:)` は
手書きの `switch rawActiveTab` なので、`case MeetingWorkspaceTab.chat.rawValue:` を明示的に足す
（足さないと `default:` に落ちて毎回「準備」タブに戻る）。

### 8.2 kikimi.md / 既存設計への改訂点（実装確定後）

- kikimi.md 10 章: タブ構成を 3 タブから 4 タブに更新し、チャットタブの説明を追加
- kikimi.md 12 章: `config.yaml` サンプルに `chat:` セクションを追加
- kikimi.md 15 章: チャットのコストが既存のセッション別集計に含まれることを 1 行
- `docs/design/17-session-window-redesign.md` §3.2/§4.1/§4.3: タブ一覧・`activeTab` の取り得る値・
  デコーダの `switch` の行を更新
- `docs/design/12-llm-client.md`: `LLMRequest.messages`（§8.1(b)）、stdin 非同期化（§8.1(a)）、
  `timeout` の既定が呼び出し元ごとに上書きされうること（CH19）を追記
- `docs/design/16-llm-usage-stats.md` §5: `purpose` の一覧に `chat` を追加
- CLAUDE.md のコードマップに `Kikimi/Chat/` を追加

## 9. やらないこと・将来拡張

- ~~**WebView ベースの Markdown 描画（mermaid 対応）**~~ → `docs/design/39-webview-markdown.md` で実装済み。
  サマリ・Watchers・チャットの 3 箇所すべてが WKWebView + `markdown-it` で描画され、CH6 のプロンプト 1 文は
  撤回、MarkdownUI 依存は削除された
- **ストリーミング表示**: `LLMBackend` に streaming の口を足す必要がある（Claude CLI は
  `--output-format stream-json`、OpenAI 互換は SSE）。バックエンド 3 種すべてに影響するので別設計
- **複数セッション横断の質問**: セッションをまたぐ検索・埋め込みが要る。Wiki 側の役割との
  切り分けから議論が必要
- **チャットからの操作**（話者リネーム、Watcher 生成、サマリ修正）: tool 呼び出しの口が
  `LLMRequest` に無く、副作用を持つ経路は設計・テストの重みが跳ね上がる
- **Wiki export への同梱**: 会議の記録と Kikimi の操作履歴を混ぜるかどうかの判断が要る
- **回答への引用リンク**: `HH:MM:SS` をクリックで書き起こしの該当行へジャンプ（Watchers の
  seg ID リンク、design 05 §10.4 と同じ仕組みが使える）。初版は文字列として出すだけ
