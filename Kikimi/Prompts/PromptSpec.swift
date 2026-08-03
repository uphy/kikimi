import CryptoKit
import Foundation

// MARK: - PromptID

/// One of the override-able prompts (`docs/design/42-prompt-overrides.md` §2.1's table -- originally 7,
/// plus `.summaryFinal` added by `docs/design/summary-quality-topics-and-final-pass.md` §7.4). `rawValue`
/// is also the file name stem under `prompts/` (`prompts/<rawValue>.md`, §3.1) -- `PromptRef.relativePath`
/// relies on this equivalence, so a case's `rawValue` must never diverge from its on-disk file name.
///
/// Deliberately does **not** include a case for `dictation/apps/<bundle-id>`: that id is per-app and
/// has no default body (§2.2 "per-app 文脈は「追加指示」であり default を持たない") -- it is represented
/// only by `PromptRef.dictationApp(bundleID:)`, never by a `PromptSpec`.
enum PromptID: String, CaseIterable, Sendable {
    case refinement
    case summary
    case finalTitle = "final-title"
    case chat
    case simpleWatcher = "simple-watcher"
    case glossaryHeader = "glossary-header"
    case dictation
    /// Session-end final refinement pass that rewrites overview/decisions/action_items from a
    /// whole-meeting view (`docs/design/summary-quality-topics-and-final-pass.md` §7.4). Distinct
    /// from `.summary` (the incremental patch prompt): this one runs exactly once per `endMeeting()`,
    /// never mid-session.
    case summaryFinal = "summary-final"
}

// MARK: - PromptReload

/// When an override edit takes effect for a given `PromptID` (§5.2's table). This is the *authority*
/// (`PromptSpec.reload`) -- a `.md` file's own `reload:` frontmatter field is only an informational
/// copy that `PromptValidator` checks for drift (§3.2's frontmatter table).
enum PromptReload: String, Sendable {
    /// Takes effect on the next call that reads it (summary / final-title / chat / glossary-header for
    /// dictation / dictation / dictation per-app, §5.2).
    case immediate
    /// Fixed for the lifetime of a session: the value is snapshotted once when the session's
    /// `RefinementQueue`/`WatcherRunner` is constructed, so prompt-cache-friendly fixedness (kikimi.md
    /// 7 章) survives mid-session edits (refinement, simple-watcher, and -- asymmetrically, via
    /// refinement's `glossaryBlock` -- glossary-header when it reaches the meeting transcript path;
    /// §5.2/§12 open question #3).
    case sessionStart = "session-start"
}

// MARK: - PromptRef

/// A resolvable prompt reference: either one of the 7 fixed `PromptID`s, or a per-app dictation
/// context keyed by bundle id (`prompts/dictation/apps/<bundle-id>.md`, §2.1/§3.1). Owns the id/path
/// mapping (§3.1 "id → パスの写像") so `PromptStore`/`PromptFile`/the CLI share one place that knows
/// how a ref turns into a `prompts/` relative path, instead of each re-deriving it.
enum PromptRef: Hashable, Sendable {
    case builtin(PromptID)
    /// `bundleID` must already satisfy `isValidBundleID(_:)` (§2.1 "bundle id は `[A-Za-z0-9._-]+` に
    /// に制限する（それ以外は warning + 無視）") -- constructing this case with an unchecked, attacker- or
    /// typo-controlled string is a caller bug. Use `init?(dictationAppBundleID:)` when the input hasn't
    /// been validated yet (e.g. a raw string typed into a URL scheme or CLI argument).
    case dictationApp(bundleID: String)

    /// `true` iff every character of `bundleID` is an ASCII letter, digit, `.`, `_`, or `-`, and
    /// `bundleID` is non-empty (§2.1's `[A-Za-z0-9._-]+`). Mirrors the character-class-loop style of
    /// `MeetingProfileIdValidation.validate(_:)` / `WatcherLibrary.isValidWatcherId(_:)` rather than a
    /// `NSRegularExpression`, for the same reason those chose it: no regex engine needed for a fixed
    /// ASCII character class.
    static func isValidBundleID(_ bundleID: String) -> Bool {
        !bundleID.isEmpty && bundleID.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(Character(scalar)) ||
                ("A"..."Z").contains(Character(scalar)) ||
                ("0"..."9").contains(Character(scalar)) ||
                scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    /// `prompts/<id>.md` (builtin) or `prompts/dictation/apps/<bundle-id>.md` (per-app), relative to
    /// the `prompts/` directory (§3.1's disk layout). `PromptStore` resolves this against its
    /// `directory` root; this type has no filesystem knowledge of its own.
    var relativePath: String {
        switch self {
        case .builtin(let id):
            return "\(id.rawValue).md"
        case .dictationApp(let bundleID):
            return "dictation/apps/\(bundleID).md"
        }
    }
}

extension PromptRef {
    /// Validates `bundleID` before constructing `.dictationApp` (§2.1). `nil` when `bundleID` fails
    /// `isValidBundleID(_:)` -- callers that already trust their input (e.g. enumerating file names
    /// already on disk, which can only exist there if they passed validation on write) may still
    /// construct `.dictationApp(bundleID:)` directly instead.
    init?(dictationAppBundleID bundleID: String) {
        guard PromptRef.isValidBundleID(bundleID) else { return nil }
        self = .dictationApp(bundleID: bundleID)
    }
}

// MARK: - PromptOverrideState

/// The resolved state of one `PromptRef` after reading `prompts/` (§5.1's state-machine diagram).
/// `PromptStore.overrideState(for:)` returns this; `PromptStore.policyBody(for:)` collapses it down to
/// the one `String` callers actually need (`.active`'s body, or the owning `PromptSpec.defaultBody` /
/// empty string for `.none`/`.invalid`).
enum PromptOverrideState: Equatable, Sendable {
    /// No override file exists. The built-in default is used -- the normal, expected state for most
    /// installs (§1 "ファイルなし = 組み込み default").
    case none
    /// An override file exists, parsed and validated successfully. `body` is already trimmed/clamped
    /// (§3.2's body rules); `basedOn` is the file's `based_on:` frontmatter value verbatim (`nil` if
    /// the field was absent -- itself a `PromptValidator` warning, §8 #-adjacent, but not fatal).
    case active(body: String, basedOn: String?)
    /// An override file exists but failed to parse/validate (§8's failure modes #2-#6). The caller
    /// already logged a warning once for this transition (§5.1 "invalid への遷移時に 1 回だけ warning
    /// ログを出す") and falls back to the built-in default -- recording/refinement is never blocked by
    /// a broken override file.
    case invalid(PromptFileError)
}

// MARK: - PromptSpec

/// The static, authoritative specification for one `PromptID`: its built-in default body (placeholder
/// tokens left un-expanded), which placeholders it recognizes, when an edit to it takes effect, and
/// what to write into an ejected file's frontmatter comments (`docs/design/42-prompt-overrides.md`
/// §4.1). Every field here is a fixed fact about the *app's* prompt design, independent of anything on
/// disk -- `PromptStore` is what layers a user's `prompts/*.md` override on top of `spec(for:)`'s
/// values at runtime.
struct PromptSpec: Sendable {
    var id: PromptID
    /// When an override to this prompt takes effect (§5.2's table) -- the authority `PromptValidator`
    /// checks a file's own `reload:` frontmatter copy against (§3.2's frontmatter table).
    var reload: PromptReload
    /// `{{...}}` tokens that **must** appear in the body for it to be a valid override (e.g.
    /// `["{{viewpoint}}"]` for `simple-watcher`, §2.1). An override missing one of these is
    /// `.invalid` (§8 #5) -- the built-in default always satisfies this by construction.
    var requiredPlaceholders: [String]
    /// `{{...}}` tokens the app understands and will expand if present, but whose absence does not
    /// invalidate the override (e.g. `["{{leak_dedup_rule}}"]` for `refinement`, §2.1).
    var optionalPlaceholders: [String]
    /// The built-in policy-layer body, with any recognized placeholders left as literal `{{token}}`
    /// text (not yet expanded) -- exactly the text `--eject-prompt <id>` writes out and
    /// `defaultBodyHash(id)` hashes. Contract-layer text (schema/output-format instructions the app
    /// always appends and the override file can never touch, §0/§2.2) is *not* part of this string.
    var defaultBody: String
    /// Extra lines (no leading `#`/comment marker -- that is `PromptFile.render`'s job when it writes
    /// these into frontmatter) that `--eject-prompt <id>` should surface as a warning to whoever edits
    /// the ejected file, beyond the generic override-file boilerplate every id gets. Empty for every
    /// id except `simple-watcher`, whose "根拠となる発言の seg ID を本文にそのまま書く" convention
    /// isn't something schema validation can enforce (§2.2).
    var ejectComments: [String]

    /// The authoritative spec for `id` (§4.1). A plain, allocation-cheap switch -- there is no reason
    /// to cache this; `PromptStore` calls it on every read that needs the default rather than holding
    /// its own copy, so the built-in defaults below are the single source of truth.
    static func spec(for id: PromptID) -> PromptSpec {
        switch id {
        case .refinement:
            return PromptSpec(
                id: .refinement,
                reload: .sessionStart,
                requiredPlaceholders: [],
                optionalPlaceholders: ["{{leak_dedup_rule}}"],
                defaultBody: refinementDefaultBody,
                ejectComments: []
            )
        case .summary:
            return PromptSpec(
                id: .summary,
                reload: .immediate,
                requiredPlaceholders: [],
                optionalPlaceholders: [],
                defaultBody: summaryDefaultBody,
                ejectComments: []
            )
        case .finalTitle:
            return PromptSpec(
                id: .finalTitle,
                reload: .immediate,
                requiredPlaceholders: [],
                optionalPlaceholders: [],
                defaultBody: finalTitleDefaultBody,
                ejectComments: []
            )
        case .chat:
            return PromptSpec(
                id: .chat,
                reload: .immediate,
                requiredPlaceholders: [],
                optionalPlaceholders: [],
                defaultBody: chatDefaultBody,
                ejectComments: []
            )
        case .simpleWatcher:
            return PromptSpec(
                id: .simpleWatcher,
                reload: .sessionStart,
                requiredPlaceholders: ["{{viewpoint}}"],
                optionalPlaceholders: [],
                defaultBody: simpleWatcherDefaultBody,
                ejectComments: [
                    "「根拠となる発言の seg ID（例: seg_00042）を本文にそのまま書く」のルールを消すと、" +
                        "Watcher 出力から該当発言へジャンプする UI 機能が退化します。"
                ]
            )
        case .glossaryHeader:
            return PromptSpec(
                id: .glossaryHeader,
                reload: .immediate,
                requiredPlaceholders: [],
                optionalPlaceholders: [],
                defaultBody: glossaryHeaderDefaultBody,
                ejectComments: []
            )
        case .dictation:
            return PromptSpec(
                id: .dictation,
                reload: .immediate,
                requiredPlaceholders: [],
                optionalPlaceholders: [],
                defaultBody: dictationDefaultBody,
                ejectComments: []
            )
        case .summaryFinal:
            return PromptSpec(
                id: .summaryFinal,
                reload: .immediate,
                requiredPlaceholders: [],
                optionalPlaceholders: [],
                defaultBody: summaryFinalDefaultBody,
                ejectComments: []
            )
        }
    }

    /// `SHA-256(defaultBody の UTF-8 バイト列)` の hex 先頭 12 桁 (§3.3's `based_on` hash). A function
    /// value rather than a plain `static func` per the design's `Kikimi/Prompts/` API sketch (§4.1) --
    /// exposed this way so `PromptFile.render(id:spec:body:)` and the eject CLI can pass it around as a
    /// first-class value instead of always calling through `PromptSpec` by name.
    static var defaultBodyHash: (PromptID) -> String {
        { id in sha256Hex12(spec(for: id).defaultBody) }
    }

    private static func sha256Hex12(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }
}

// MARK: - Default bodies (§2.2's policy/contract split)

/// The default bodies below are moved verbatim (or, where §2.2 explicitly calls for a restructuring --
/// `summary` -- reauthored per that section's instructions) from the builders that used to hardcode
/// them. Each builder's contract-layer text (schema/output-format instructions the override file can
/// never reach) stays put in that builder; only the policy layer moved here. Keeping them as private
/// top-level constants (rather than inline in `spec(for:)`) keeps that switch statement's structure
/// readable at a glance.
///
/// Some rules deliberately run in parallel across bodies rather than being shared through an include
/// mechanism -- each id must stay independently overridable and each file self-describing, so the
/// price of parallelism is paid in "review the sibling when editing" instead of machinery:
/// - filler / self-correction / punctuation bullets: `refinement` ↔ `dictation`
/// - "transcript may contain mis-transcriptions" caveat: `refinement`/`summary`/`chat`/
///   `simple-watcher`/`dictation`/`summary-final`, each phrased for its task
private extension PromptSpec {
    /// Moved from `RefinementPromptBuilder.buildSystemPrompt(context:glossaryBlock:dedupSystemLeakSegments:)`
    /// (§2.2 "refinement"). `{{leak_dedup_rule}}` sits exactly where that function used to
    /// conditionally interpolate the mic/system leak-dedup bullet.
    ///
    /// Three rules were added over the kikimi.md 7 章 original (which had no ASR framing at all,
    /// unlike `dictationDefaultBody` -- the same recognition engine feeds both pipelines):
    /// - Homophone mis-transcription repair ("駅存" → "既存"): without an explicit license, the
    ///   conservative "意味を変えない" rule reads as forbidding it, so obvious mishearings survived.
    /// - Self-corrections keep only the corrected reading -- the old bullets only covered dropping a
    ///   segment that is *entirely* restatement fragments, not a correction inside a sentence.
    /// - Keep the speaker's register (appended to the light-rewording bullet): a meeting record
    ///   attributes lines to speakers, so "upgrading" casual speech misrepresents who said what.
    static let refinementDefaultBody = """
    あなたは会議書き起こしを整形する専門家です。以下のルールに従ってください。

    【整形ルール】
    - フィラー（「えーと」「あの」など）を除去する
    - 言い直しがある場合は言い直した後の内容を採用し、言い直し前の断片は削除する（例:「明日、いや明後日の会議」→「明後日の会議」）
    - 句読点を補い、自然な日本語にする
    - 入力は音声認識の書き起こしのため、同音・近音の誤変換があり得る。文脈から明らかな誤変換は正しい表記に直す（例:「駅存の実装」→「既存の実装」）
    - 意味を変えない範囲での軽微な言い換えは可。話者の口調（です・ます調/常体）は変えない
    - 意味の解釈が不明瞭な箇所は元の表現を残す
    - フィラー・相槌・言い直しの断片のみで、除去すると意味のある内容が何も残らないセグメントは、refined_text を空文字にする（そのセグメントを削除する扱い）{{leak_dedup_rule}}
    """

    /// Reauthored from `SummaryPromptBuilder.systemPrompt` per §2.2 "summary": role declaration + the
    /// title-proposal/overview-rewrite editorial policy only. The patch-structure invariants that used
    /// to live in the same `【ルール】` bullet list (participants_add-only, decisions-additions-only,
    /// action_items add/modify/complete, null-when-unchanged) move to the app-owned contract layer
    /// (`SummaryPromptBuilder`'s `【patch 契約】` block, §2.2's example) instead -- they are not part of
    /// this policy body. §2.2/§10 note this makes the default wording diverge from the pre-refactor
    /// `systemPrompt` constant; that is an accepted non-breaking-in-spirit change (patch semantics
    /// unchanged, only where the instruction text for them lives).
    /// Content policy added over the original 【ルール】 list (which only carried the title rule and
    /// a bare "overview は書き直してよい"): what *qualifies* as a decision / an action item, how long
    /// the overview should stay, and that garbled transcript fragments are ignorable. Structure
    /// invariants stay in the app-owned 【patch 契約】 block -- these bullets are about content
    /// judgement, which is exactly what the policy layer is for.
    ///
    /// Four bullets were added per §5.2 of `summary-quality-topics-and-final-pass.md` (root-caused
    /// against session `2026-07-31T03-51-26_d7deac6b`, which had 23 decisions -- mostly non-decisions
    /// -- and no topic-level detail): what disqualifies a decision (shared understanding / status
    /// updates / mere possibilities), that a superseded decision must be revised or withdrawn rather
    /// than left to accumulate (`decisions_modify`/`decisions_remove` -- structural keywords for those
    /// operations live in the app-owned contract layer, `SummaryPromptBuilder.patchContract`; these
    /// bullets only judge *when* a decision qualifies or needs correction), how a topic should be
    /// scoped and written, and that an in-progress topic's continuation folds into the existing topic
    /// (`topics_update`) instead of spawning a new one.
    static let summaryDefaultBody = """
    あなたは会議サマリを更新するエディタです。前サマリ state と直近の会話を受け取り、変更差分（patch）を JSON で返してください。

    【編集方針】
    - title: 現在の state.title が空の場合は、会議内容を表す簡潔なタイトルを必ず提案する（会議名が明確でなければ議題や会話内容から推定する）。既に付いているタイトルは、明確に良くなる場合だけ新しい title を返し、実質同じ内容の言い換えなら null を返す
    - overview は必要に応じて全文書き直す。会議の流れと現時点の論点が短時間で掴める要約に保ち、発言の羅列にしない
    - decisions は会話で明確に合意・決定された事項だけを追加する。提案・検討段階のものを決定として書かない
    - decisions は「これをやる / やらない / この方針で進める」と明確に合意された事項だけにする。認識共有・現状理解の確認・可能性やアイデアの言及・単なる進捗報告は decision に入れない
    - 一度追加した decision が後の会話で覆された・条件付きに変わった・誤りと分かった場合は、decisions_modify で書き直すか decisions_remove で取り下げる
    - action_items は担当や期限が発言から読み取れる場合のみ埋める。読み取れないときは assignee は空文字、due は null にする（推測で埋めない）
    - topics は会議の話題のまとまりごとに時系列で作る。見出しは内容が特定できる短い名詞句にする。body は要点の箇条書きで、結論・数値・固有名詞・対立した意見の両論を残す。発言の逐語再現はしない
    - 直近の会話が既存トピックの続きなら新トピックを作らず topics_update で該当トピックに統合する
    - 書き起こしには誤変換があり得る。意味の取れない断片は無理にサマリへ反映しない
    """

    /// Moved from `SummaryUpdater+FinalTitle.swift`'s `finalTitleSystemPrompt` (§2.2
    /// "final-title": all of it is policy layer -- structured output enforces the shape, so there is
    /// no contract-layer text to hold back). The two bullets were added later: the original
    /// one-liner gave no specificity or length guidance, so a generic session yielded titles like
    /// 「定例ミーティング」 that identify nothing in a session list.
    static let finalTitleDefaultBody = """
    あなたは会議サマリからタイトルを提案する専門家です。会議の内容を最もよく表す簡潔なタイトルを日本語で1つ返してください。

    - 主要な議題や結論が分かる具体的な語を含める（「定例ミーティング」のような、どの会議にも当てはまるタイトルにしない）
    - 30字程度までに収め、かぎ括弧・絵文字などの装飾を付けない
    """

    /// Moved verbatim from `ChatPromptBuilder.buildSystem()` (§2.2 "chat": all of it is policy layer,
    /// same reasoning as `final-title`).
    static let chatDefaultBody = """
    あなたは、ある会議の書き起こしについて質問に答えるアシスタントです。与えられた会議の記録だけを根拠に、簡潔に答えてください。

    書き起こしの性質:

    - 音声認識と LLM 整形を経ているため、誤変換・話者の取り違えがあり得ます
    - `*(raw)*` が付いた行は未整形の生テキストです
    - 記録から読み取れないことは推測で埋めず、「書き起こしからは読み取れない」と答えてください

    回答の形式:

    - Markdown で書いてください
    - 図で示したほうが分かりやすいときは mermaid のコードブロックを使ってください
    - 発言を引用するときは `HH:MM:SS` と話者名を添えてください
    """

    /// Moved from `SimpleWatcherSpec.systemPrompt(forViewpoint:)` (§2.2 "simple-watcher": all of it is
    /// policy layer -- the `markdown` schema field is structured-output-enforced, so there is no
    /// contract-layer text). `prompt`'s interpolation site becomes the required `{{viewpoint}}`
    /// placeholder. Two rules were added over the original: the "nothing yet" instruction (a watcher
    /// refires all session long, and without it a model pads empty rounds with speculation) and the
    /// ASR-unreliability caveat shared with the chat prompt.
    static let simpleWatcherDefaultBody = """
    あなたは会議のリアルタイム書き起こしを観察するアシスタントです。
    次の【観点】に従って、与えられた会議内容から分かることを Markdown で簡潔にまとめてください。

    【観点】
    {{viewpoint}}

    【出力ルール】
    - markdown フィールドに結果の Markdown 本文を入れて返す
    - 会議内容から判断できないことは推測で書かない
    - 書き起こしには誤変換・話者の取り違えがあり得る。不確かな根拠で断定しない
    - 観点に該当する内容がまだ無い場合は、その旨を一言だけ書く（無理にひねり出さない）
    - 根拠となる発言を参照するときは、その発言の seg ID（例: seg_00042）を本文にそのまま書く
    """

    /// Moved verbatim from `GlossaryRenderer.defaultHeader` (§2.2 "glossary-header": only the header
    /// text is policy layer -- the term bullets/category headings `GlossaryRenderer.render` generates
    /// stay code-owned, §2.2). `GlossaryRenderer.defaultHeader` now forwards here, so this constant is
    /// the single source of truth for both the render-time default and the `based_on` staleness hash.
    ///
    /// Field-tuning history (moved with the text from `GlossaryRenderer`):
    ///
    /// Deliberately framed as a **substitution rule**, not as mis-transcription repair. The earlier
    /// wording ("音声認識でよく誤変換される〜。文中に読みが似た誤変換が含まれている場合は置換してください")
    /// only ever fired on readings that were obviously broken Japanese: 「デブ環境」→「dev環境」 worked,
    /// but 「ステージング環境」→「stg環境」 never did, because the LLM correctly judged「ステージング環境」
    /// to be a faithful transcription and therefore not a 誤変換 to repair (2026-07 実戦フィードバック).
    /// Notation normalization and mis-transcription repair are the same operation from the model's
    /// side -- "if you see A, write B" -- so the rule now says exactly that, and explicitly covers the
    /// correctly-transcribed case.
    ///
    /// The bare-term case (`reading` empty) also gets an explicit line. It previously had none: its
    /// meaning ("this is a real proper noun, do not 'correct' it into a commoner word") lived only in
    /// `GlossaryEntry`'s doc comment, i.e. nowhere the LLM could read it.
    ///
    /// Bullets render as `A → B` (arrow), not the original `A: B` (colon): with a colon, small
    /// models fall back on the dictionary prior "headword: gloss" and emit the *left* side --
    /// 「根建さん」 came out as 「こんけんさん」 (the reading) instead of 「konkenさん」, and before
    /// that as 「ねこかく」, a *different* entry's reading force-matched onto a then-unlisted name
    /// (2026-07-10 実戦フィードバック, gpt-5.4-nano). The arrow matches the header's own examples,
    /// the direction is restated outright ("必ず「→」の右側"), and force-matching unlisted words
    /// onto some nearby entry is explicitly forbidden.
    ///
    /// The final clause still lets the LLM decline a replacement the surrounding context clearly
    /// doesn't call for -- a glossary hit is a strong hint, not an unconditional find-and-replace.
    static let glossaryHeaderDefaultBody = """
    # Glossary

    以下は、この書き起こしに登場する固有名詞・専門用語の一覧です。

    - 「A → B」形式の行は、文中に A（またはそれに近い表記・誤変換）が現れたら B に置換してください。A が正しく書き起こされていても、B の表記に統一してください。
      (例:「猫助」→「nekosuke」、「デブ環境」→「dev環境」、「ステージング環境」→「stg環境」)
    - 「A1, A2 → B」のようにカンマ区切りで複数並ぶ行は、そのいずれの表記が現れても B に置換してください。
    - 置換結果として出力してよいのは、必ず「→」の右側の表記です。左側（読み・誤変換の側）を出力に使わないでください。
    - 用語のみの行は、実在の固有名詞です。別の一般語に「訂正」しないでください。
    - どの行の A とも読みが明確に一致しない語は、そのまま残してください。一覧のどれかへ無理に寄せてはいけません。
    - ただし、文脈上明らかに無関係な語だと分かる場合は、無理に置換しないでください。
    """

    /// Moved from `DictationContextConfig.default.global` (§2.2 "dictation": the contract
    /// layer -- `DictationRefiner.preamble` / output-format suffix -- stays a Swift constant, §2.2's
    /// "現状のまま"). Unlike every other id, an *empty* override of this body is a valid, deliberate
    /// `.active` state (§3.2/§8 #6: "文脈を一切注入しない", design 25 R17's escape hatch) -- that
    /// exception is enforced by `PromptValidator`/`PromptFile`, not encoded here.
    ///
    /// Three rules were added after the config.yaml era (so this is no longer verbatim R17 text; the
    /// R17 body lives on in `DictationPromptMigration.legacyDefaultBodies`):
    /// - Never *answer* the dictated text: dictating a question ("これどう思いますか") must come back
    ///   refined, not replied to -- the most common failure mode of small-model dictation refiners.
    /// - Self-corrections keep only the corrected reading ("明日、いや明後日" → "明後日"): spoken
    ///   utterances routinely contain them, and the old body only covered fillers.
    /// - Keep the speaker's register (です・ます/常体, casual phrasing): "自然な日本語にする" alone
    ///   left small models free to "upgrade" casual dictation into polite prose; per-app 追加指示 is
    ///   the right place to *change* register, so the global default preserves it.
    ///
    /// The self-correction rule was later promoted from one bullet inside 【整形ルール】 to its own
    /// 【言い直しの処理】 block (2026-08 実戦フィードバック, root-caused against
    /// `~/.local/state/kikimi/dictation/history/`: of the marker-less self-corrections in 100 recorded
    /// utterances, none were removed -- the refiner only added punctuation, occasionally producing
    /// text worse than the input). Five things were wrong with the single-bullet form:
    /// - Its only example ("明日、いや明後日") carried an explicit marker (「いや」). Real utterances
    ///   almost never do: they restart from the top, swap a word, or break mid-word.
    ///   `reasoning_effort: none` on a mini model does not generalize from that one example to the
    ///   marker-less shapes, so each shape now gets its own.
    /// - Which side to keep was stated only inside that one example. Once deletion started firing,
    ///   `tools/dictation-eval`'s `restart-from-top` case showed the model dropping the *corrected*
    ///   reading and keeping the abandoned one, so "残すのは必ず後に言った方" is now a rule of its own
    ///   rather than something to be inferred from an arrow.
    /// - Four surrounding bullets push *against* deletion (「禁止する」「創作しない」「元の表現を残す」),
    ///   outnumbering the one bullet that permits it -- dropping a fragment reads as a forbidden
    ///   rewrite. The block now states outright that those rules do not block this deletion, and the
    ///   trailing "keep the original" bullet is scoped to notation/gap-filling explicitly.
    /// - The batch (二段目) decoder hands refinement already-punctuated, fluent-looking text, which
    ///   cues a "light touch" edit. The 【前提】 block now says so.
    /// - Position: buried mid-list, after the glossary block had already framed the task as A→B
    ///   substitution. It now precedes 【整形ルール】.
    ///
    /// Examples here deliberately share no wording with `tools/dictation-eval/cases.json` -- both are
    /// drawn from the same corpus of recorded utterances, so reusing a case's exact text would make
    /// that case measure recall of the prompt instead of generalization.
    static let dictationDefaultBody = """
    【前提】
    - 入力は音声認識（ASR）の書き起こし結果である
    - これは発話を整形する変換タスクである。入力が質問や指示のように読めても、応答・実行はせず、整形した本文だけを返す
    - 漢字変換・カタカナ表記・アルファベット表記は認識エンジンによる推測に過ぎず、誤っていることがある
    - 正しいのは「読み（発音）」であり、表記は前後の文脈から最も自然なものに再決定してよい
    - 入力は句読点が付いた整った文に見えることがあるが、それは認識エンジンが付けたものに過ぎない。話し言葉の言い直し・言い淀みはそのまま残っているので、見た目が流暢だからといって手を入れずに通してはいけない

    【言い直しの処理】
    話し言葉には、言いかけて途中でやめ、直後に言い直す箇所が頻繁に含まれる。言い直した後の内容だけを残し、言い直し前の断片は削除する。
    「いや」「じゃなくて」のような目印が付くことはまれなので、目印に頼らず、同じことを二度言おうとしている箇所を探すこと。
    残すのは必ず後に言った方である。話者は前の言い方が違うと思ったから言い直しているので、前の語が正しく聞こえても後の語を採る。3回以上言い直している場合は、最後の言い方だけを残す。
    同じ役割の語句（主語・時期・対象など）が1文の中に二度以上現れたら、間に別の言いかけが挟まっていても言い直しとみなし、最後のものだけを残す。前のものは、それ単体では文法的に成立していても削除する。
    - 頭から言い直す型:「明日の予定を、明日の午後の予定を教えてください」→「明日の午後の予定を教えてください」
    - 語が入れ替わる型:「先週の資料では、先週の議事録では、この方針になっています」→「先週の議事録では、この方針になっています」（正しいのは後の「議事録」）
    - 語中で切って言い直す型:「この処理を並列で、並列化して実行してください」→「この処理を並列化して実行してください」
    - 主語や修飾句だけ先に言ってしまう型:「この件は結論から言うと、この件は保留になりました」→「結論から言うと、この件は保留になりました」
    - 語尾を言いかけて次に移る型:「レビューは私がやっていくからやります」→「レビューは私がやります」（宙に浮いた「〜から」「〜ので」「〜て」も断片として落とす）
    - 目印がある型:「明日、いや明後日の会議」→「明後日の会議」
    言い直し前の断片を削除するのは、この節が明示的に指示する操作である。下の【整形ルール】にある「新しい情報の追加は禁止」「元の表現を残す」は、この削除を妨げない。
    ただし、並列・列挙・強調として話者が意図的に繰り返している箇所（「AとBとC」「何度も何度も」など）は言い直しではないので残す。

    【整形ルール】
    - フィラー（「えーと」「あの」など）を除去する
    - 句読点を補い、自然な日本語にする
    - 話者の文体（です・ます調/常体、カジュアルな言い回し）は維持し、書き言葉への言い換えはしない（ただし、アプリ向けの追加指示がある場合はそちらを優先する）
    - 表記の置換は「読みが同じ・近い範囲」に限り自由に行ってよい。読みから離れた書き換えや新しい情報の追加は禁止する（ただし、アプリ向けの追加指示がある場合はそちらを優先する）
    - 同音・近音の誤変換は積極的に正しい表記へ修正する（例:「駅存」→「既存」、「支持」→「指示」）
    - 技術用語は文脈から判断できる場合、正式な表記に直す（例:「エルエルエム」→「LLM」、「ピーディエフ」→「PDF」）
    - 良い例:「駅存の実装」→「既存の実装」（読みが近く、文脈上「既存」が妥当）。悪い例:「ピーディf」→「prデータ」（読みが一致しない、ただの推測でしてはいけない）
    - 音声認識により助詞や単語が部分的に欠落し、文法的に不自然な箇所がある場合は、前後の文脈から自然に補って文法的に整った文章にする（例:「明日 会議 資料」→「明日の会議の資料」）
    - 欠落補完はあくまで文法的な穴埋めに留め、話者が言っていない新しい情報や結論を創作しない
    - 表記の候補に自信が持てない場合、または欠落補完で文意が推測できない場合は、その箇所の元の表現を残す（この指示は表記と欠落補完についてのものであり、【言い直しの処理】による断片の削除には適用しない）
    """

    /// Session-end final refinement pass (`docs/design/summary-quality-topics-and-final-pass.md`
    /// §7.4): rewrites overview/decisions/action_items once, from a whole-meeting view, to fix the
    /// structural drift the incremental `.summary` prompt cannot avoid (it only ever sees the latest
    /// ~20 segments) -- overview bias toward recent topics, uneven decision granularity, and
    /// raw-transcript mis-transcriptions that got locked in early. `topics` is deliberately excluded
    /// (§7.2's (a)-(c): rewriting it scales output with meeting length, its incremental accretion is
    /// itself the value, and the existing full-regeneration rescue path already covers degradation);
    /// so are `title` (final-title proposal) and `participants` (diarization merge).
    ///
    /// The contract layer (app-owned, not in this string) requires the JSON response to include all
    /// three of overview/decisions/action_items, and forbids the LLM from returning `id`s -- the app
    /// renumbers `dc_00N`/`ai_00N` from scratch on apply (`applyFinalRevision`, §7.3), so there is no
    /// id-collision bookkeeping to get right.
    static let summaryFinalDefaultBody = """
    あなたは会議の議事録を仕上げる編集者です。会議全体の書き起こしと、会議中に自動生成されたサマリ state を受け取り、overview / decisions / action_items を最終版に書き直してください。

    【編集方針】
    - overview は会議全体を俯瞰した要約にする。冒頭の議題から結論までの流れが掴めるようにし、終盤の話題に偏らせない
    - decisions は会議終了時点で有効な決定だけを残す。途中で覆された決定・認識共有・現状理解・可能性の言及は含めない。同じ決定の重複や言い換えは1件に統合する
    - action_items は重複を統合し、担当・期限は発言から読み取れる場合のみ埋める（推測で埋めない）
    - 既存 state で status が done の action item は、最終版でも done を維持する
    - 書き起こしには誤変換があり得る。文脈から明らかな誤変換は正しい表記で書く
    """
}
