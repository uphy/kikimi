import Foundation
import OSLog

private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SummaryPromptBuilder")

// MARK: - SummarySegmentInput

/// One segment's worth of information the summary prompt needs to render a `seg_XXXXX (mic): text`
/// line (kikimi.md 8 章's user prompt example). Deliberately narrower than `TranscriptSegment`/
/// `RefinedSegment` so `SummaryPromptBuilder` stays pure and does not need to know about the
/// refined/raw fallback file-reading concern itself (`docs/design/04-summary-updater.md` §1's scope
/// note: "refined があれば refined、無ければ raw" is resolved by the caller before building this).
struct SummarySegmentInput: Sendable, Equatable {
    var id: String
    var startMs: Int
    var speaker: AudioSourceKind
    /// Already resolved to `refinedText` when available, `rawText`/`text` otherwise (kikimi.md 8.5
    /// "整形失敗は raw_text にフォールバック").
    var text: String
}

// MARK: - SummaryPromptBuilder

/// Builds the fixed system prompt and per-call user prompt for a summary-update LLM call
/// (`docs/design/04-summary-updater.md` §4.4, kikimi.md 8 章「LLM への入出力の例」).
///
/// Pure by construction: callers pass `now`/`contextMarkdown` in explicitly rather than this type
/// reading `Date()` or touching the filesystem (04-summary-updater.md §4.4's task instruction).
enum SummaryPromptBuilder {
    /// Contract layer (`docs/design/42-prompt-overrides.md` §2.2/§4.2): the structural invariants of
    /// the patch response that hold regardless of the policy layer's wording, so they are fixed
    /// across every call and never editable via a `prompts/summary.md` override. Unlike
    /// `refinement`'s system prompt (7 章), the summary system prompt is *not* prompt-cached
    /// (summary updates are infrequent, and context is folded into the user prompt every time
    /// instead -- 04-summary-updater.md §4.4), so re-deriving it per call via `systemPrompt(policyBody:)`
    /// costs nothing.
    static let patchContract = """
    - 出力は変更差分（patch）の JSON
    - participants は新たに登場した発言者・出席者だけを participants_add に追加する（既出の参加者は含めない）
    - (mic) / (system) は音声チャネルのラベルであり発言者名ではない。participants_add に入れない
    - decisions は decisions_add（新規）/ decisions_modify（既存の text 修正）/ decisions_remove（撤回・誤登録の削除）の 3 操作
    - topics は「議事詳細」の時系列トピック列。新しい話題が始まったときだけ topics_add で追加し、進行中の話題への追記・修正は topics_update で該当 id の body を全文書き直して返す
    - topics の id は "tp_001" 形式、decisions の id は "dc_001" 形式で採番する
    - action_items は add / modify / complete のいずれかの操作を返す
    - 何も変更がなければ全フィールド null で良い
    """

    /// Combines the policy layer -- role declaration + editing policy (title proposal / overview
    /// rewrite guidance), sourced from `PromptStore.policyBody(for: .builtin(.summary))` /
    /// `PromptSpec.defaultBody` when there is no override file -- with the fixed `patchContract`
    /// above to produce the final system prompt (42-prompt-overrides.md §4.2).
    static func systemPrompt(policyBody: String) -> String {
        policyBody + "\n\n【patch 契約】\n" + patchContract
    }

    /// Builds the per-call user prompt (04-summary-updater.md §4.4's "現在の state（JSON）＋直近の
    /// 会話（`start_ms` 昇順、未反映分）＋現在時刻". `context.md` is folded in too (kikimi.md 7 章:
    /// summary 側は毎回全文を組み立て直すので即時反映).
    ///
    /// - Parameters:
    ///   - state: The current `summary.state.json` contents.
    ///   - segments: Not-yet-summarized segments, expected to already be sorted `startMs` ascending
    ///     by the caller (04-summary-updater.md §4.2's high-water-mark cursor).
    ///   - now: Current time, passed in explicitly so this function stays pure.
    ///   - contextMarkdown: The session's `context.md` contents (empty string if none).
    static func buildUserPrompt(
        state: SummaryState,
        segments: [SummarySegmentInput],
        now: Date,
        contextMarkdown: String
    ) throws -> String {
        let stateJSON = try encodeStateForPrompt(state)
        let segmentsBlock = segments.map(formatSegmentLine).joined(separator: "\n")
        let timestamp = ISO8601DateFormatter().string(from: now)

        return """
        【現在の state】
        \(stateJSON)

        【事前知識】
        \(contextMarkdown)

        【直近の会話】
        \(segmentsBlock)

        【現在時刻】 \(timestamp)

        patch を返してください。
        """
    }

    /// Character budget for the transcript block in `buildFinalRevisionUserPrompt`
    /// (`docs/design/summary-quality-topics-and-final-pass.md` §7.4). `state` (passed to that
    /// function) is always sent in full and is never subject to this budget -- only the
    /// `【会議全体の書き起こし】` block is.
    ///
    /// Paired with `SummaryUpdater.finalPassTimeout` (`Kikimi/Summary/SummaryUpdater+FinalPass.swift`,
    /// 300s): a larger transcript takes the LLM longer to both read and turn into structured output,
    /// so raising this bound requires raising that timeout too. Kept here rather than beside
    /// `finalPassTimeout` per §7.5's "同じファイルに隣接して定義しコメントで相互参照" -- since the
    /// two constants can't literally live in the same file (this one is consumed by the pure prompt
    /// builder, that one by the LLM-calling `SummaryUpdater` extension), this doc comment is the
    /// cross-reference; `finalPassTimeout`'s doc comment points back here.
    ///
    /// Value derivation (§7.4): the default `claude-haiku-4-5` context is ~200K tokens. Reserving
    /// ~50K tokens of headroom for the state JSON (topics included), 事前知識/participants block,
    /// fixed prompt text, and the structured JSON response leaves ~150K tokens -- approximated 1:1
    /// as characters for Japanese text (conservative). Do not raise this toward something like 600K:
    /// that would exceed the 200K-token context outright, so the LLM call would fail on context
    /// overflow *before* this budget's truncation ever kicks in -- silently skipping the final pass
    /// on long meetings instead of degrading gracefully.
    static let finalPassMaxTranscriptChars = 150_000

    /// Builds the per-call user prompt for the session-end final refinement pass
    /// (`docs/design/summary-quality-topics-and-final-pass.md` §7.4):
    /// 【事前知識】＋【現在の state】（浄化済み・`topics` 込みの全量 JSON）＋【会議全体の書き起こし】
    /// （`seg_XXXXX (mic): text` 形式、`startMs` 昇順）＋指示文. Pure, like `buildUserPrompt`: the
    /// caller sanitizes `state` and sorts `segments` before calling this.
    ///
    /// - Parameters:
    ///   - state: The current (already-sanitized) `summary.state.json` contents. Sent in full --
    ///     never truncated by `finalPassMaxTranscriptChars`, which only bounds the transcript block.
    ///   - segments: All of the session's segments (refined-preferred, raw fallback -- resolved by
    ///     the caller), expected to already be sorted `startMs` ascending.
    ///   - contextMarkdown: The session's `context.md` contents (empty string if none).
    static func buildFinalRevisionUserPrompt(
        state: SummaryState,
        segments: [SummarySegmentInput],
        contextMarkdown: String
    ) throws -> String {
        let stateJSON = try encodeStateForPrompt(state)
        let transcriptBlock = truncatedTranscriptBlock(from: segments, maxChars: finalPassMaxTranscriptChars)

        return """
        【事前知識】
        \(contextMarkdown)

        【現在の state】
        \(stateJSON)

        【会議全体の書き起こし】
        \(transcriptBlock)

        会議全体を俯瞰したうえで、overview / decisions / action_items の最終版を JSON で返してください。
        """
    }

    /// `seg_00350 (mic): テキスト` (kikimi.md 8 章). `internal`, not `private`: shared with
    /// `WatcherPromptBuilder` (`docs/design/05-watcher-runner.md` §6) so both prompt builders format a
    /// transcript line identically instead of maintaining two copies of the same one-line format.
    static func formatLine(id: String, speaker: AudioSourceKind, text: String) -> String {
        "\(id) (\(speaker.rawValue)): \(text)"
    }

    private static func formatSegmentLine(_ segment: SummarySegmentInput) -> String {
        formatLine(id: segment.id, speaker: segment.speaker, text: segment.text)
    }

    /// Formats `segments` as `seg_XXXXX (mic): text` lines joined by newlines (`startMs` ascending,
    /// per the caller's sort). If the joined block exceeds `maxChars`, drops whole lines from the
    /// *front* (the oldest segments) until it fits, so the most recent conversation -- what a
    /// wrap-up pass cares about most -- survives (`docs/design/summary-quality-topics-and-final-pass.md`
    /// §7.4/§8: "古い側から超過分を切り捨てて warn").
    private static func truncatedTranscriptBlock(from segments: [SummarySegmentInput], maxChars: Int) -> String {
        let lines = segments.map(formatSegmentLine)
        guard !lines.isEmpty else { return "" }

        let separatorLength = 1 // "\n"
        var totalLength = lines.reduce(0) { $0 + $1.count } + (lines.count - 1) * separatorLength
        guard totalLength > maxChars else {
            return lines.joined(separator: "\n")
        }

        // Drop oldest (front) lines until the remainder fits, always keeping at least the newest
        // line even if that single line alone still exceeds the budget (unavoidable; §7.4's
        // "final pass 自体は必ず実行される" takes priority over strict budget enforcement).
        var startIndex = 0
        while startIndex < lines.count - 1, totalLength > maxChars {
            totalLength -= lines[startIndex].count + separatorLength
            startIndex += 1
        }

        logger.warning(
            "Final pass transcript exceeded \(maxChars, privacy: .public)-char budget; dropped \(startIndex, privacy: .public) of \(lines.count, privacy: .public) oldest segment line(s)"
        )
        return lines[startIndex...].joined(separator: "\n")
    }

    /// Encodes `state` as pretty-printed JSON for embedding in the prompt, using the same
    /// snake_case/ISO8601 conventions as on-disk `summary.state.json`
    /// (`Kikimi/SessionStore/SessionModels.swift`'s `SessionJSONCoding`) so the LLM sees the same
    /// shape it would if it read the file directly.
    private static func encodeStateForPrompt(_ state: SummaryState) throws -> String {
        let encoder = SessionJSONCoding.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        // JSONEncoder output is always valid UTF-8, so the failable initializer never returns nil
        // here; `?? ""` just satisfies the optional_data_string_conversion lint rule without a force
        // unwrap.
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}
