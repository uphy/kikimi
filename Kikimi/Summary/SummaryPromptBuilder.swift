import Foundation

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
    /// Fixed system prompt (kikimi.md 8 章's system prompt example). Kept small and constant across
    /// every call so structure stays predictable; unlike refinement's system prompt (7 章), this one
    /// is *not* prompt-cached (summary updates are infrequent, and context is folded into the user
    /// prompt every time instead -- 04-summary-updater.md §4.4).
    static let systemPrompt = """
    あなたは会議サマリを更新するエディタです。前サマリ state と直近の会話を受け取り、変更差分（patch）を JSON で返してください。

    【ルール】
    - title は会議内容を表す簡潔なタイトルを毎回提案する（会議名が明確でなければ議題や会話内容から推定する）。現在の state.title が空の場合は必ず提案し、既に付いているタイトルと実質同じ内容なら null で良い
    - participants は新たに登場した発言者・出席者だけを participants_add に追加する（既出の参加者は含めない）
    - overview は必要に応じて全文書き直し
    - decisions は新規追加分のみ返す（既存には触らない）
    - action_items は add / modify / complete のいずれかの操作を返す
    - 何も変更がなければ全フィールド null で良い
    """

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

    /// `seg_00350 (mic): テキスト` (kikimi.md 8 章). `internal`, not `private`: shared with
    /// `WatcherPromptBuilder` (`docs/design/05-watcher-runner.md` §6) so both prompt builders format a
    /// transcript line identically instead of maintaining two copies of the same one-line format.
    static func formatLine(id: String, speaker: AudioSourceKind, text: String) -> String {
        "\(id) (\(speaker.rawValue)): \(text)"
    }

    private static func formatSegmentLine(_ segment: SummarySegmentInput) -> String {
        formatLine(id: segment.id, speaker: segment.speaker, text: segment.text)
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
