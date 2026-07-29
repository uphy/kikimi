import Foundation

// MARK: - ChatContextScope

/// How much of the meeting a chat answer was given to work from
/// (`docs/design/38-session-chat.md` §3.2, CH3).
///
/// Deliberately a separate type from `WatcherInputScope`, which it resembles: that one is a user
/// setting parsed out of a Watcher definition's frontmatter, with a parser, a serializer, and UI
/// behind it. This one is a runtime decision, never written by a user and never part of a definition
/// file. One name, one meaning.
enum ChatContextScope: String, Codable, Sendable, Equatable {
    /// The session's whole transcript.
    case full
    /// Summary plus the most recent lines -- where `.full` demotes to when it does not fit.
    case summaryAndRecent
}

// MARK: - ChatContextResolution

/// The outcome of budgeting one chat call (`ChatContextScope.resolve(...)`).
struct ChatContextResolution: Sendable, Equatable {
    var scope: ChatContextScope
    /// Characters the transcript section may occupy. Equals the transcript's full length when
    /// `scope == .full`; when demoted, whatever the fixed parts left over (possibly 0).
    var transcriptBudget: Int
}

extension ChatContextScope {
    /// Decides scope and transcript budget for one call.
    ///
    /// The budget covers the *whole* prompt, not the transcript alone (CH3): a 30,000-character
    /// pasted question with a modest transcript can blow the context just as easily as a long
    /// meeting, and measuring only the transcript would miss it entirely.
    ///
    /// The question and the conversation history are never trimmed -- silently deleting what the
    /// user wrote is worse than answering from less transcript and saying so via the demotion label.
    /// When the fixed parts alone exhaust the budget, `transcriptBudget` reaches 0 and the transcript
    /// section is dropped heading and all; if even that overruns the model's real context window,
    /// the call fails and lands in §5's LLM-failure row.
    ///
    /// - Parameters:
    ///   - transcriptLength: `ChatContextBuilder.measure(_:)`'s value -- the length of the *rendered*
    ///     lines, not of the raw segment texts, so the budget is measured in the same units as what
    ///     actually gets sent.
    ///   - historyLength: measured **after** `ChatHistoryNormalizer.normalize(_:maxTurns:)`, since
    ///     normalization is what decides which turns are actually sent.
    static func resolve(
        transcriptLength: Int,
        summaryLength: Int,
        questionLength: Int,
        historyLength: Int,
        maxContextChars: Int
    ) -> ChatContextResolution {
        let fixed = summaryLength + questionLength + historyLength
        if transcriptLength + fixed <= maxContextChars {
            return ChatContextResolution(scope: .full, transcriptBudget: transcriptLength)
        }
        return ChatContextResolution(
            scope: .summaryAndRecent,
            transcriptBudget: max(0, maxContextChars - fixed)
        )
    }
}

// MARK: - ChatContextBuilder

/// Builds the meeting-record Markdown a chat call is given
/// (`docs/design/38-session-chat.md` §3.2, CH2). Pure: no I/O, no config, no `SessionHandle`.
///
/// Line formatting is shared with the transcript-copy feature via
/// `TranscriptMarkdownRenderer.renderLine(_:meta:)`, so the two can never drift. Document assembly
/// is *not* shared: `TranscriptMarkdownRenderer.Scope` offers `.full` (with frontmatter),
/// `.transcript`, and `.summary`, none of which can express "no frontmatter, summary plus the tail
/// of the transcript, trimmed to a character budget". Adding a case for it would push a runtime
/// concept into a type the Wiki export and the copy feature share; concatenating `.summary` and
/// `.transcript` instead would emit `# タイトル` twice.
enum ChatContextBuilder {
    struct Output: Sendable, Equatable {
        var markdown: String
        var scope: ChatContextScope
    }

    /// Blank line between rendered transcript lines, matching `TranscriptMarkdownRenderer.render`'s
    /// own separator so a `.full` chat context is line-for-line what the copy feature produces.
    private static let lineSeparator = "\n\n"

    /// The two lengths `ChatContextScope.resolve(...)` needs from the transcript side.
    ///
    /// Lives in this file, sharing `renderedLines(_:)` with `build(_:resolution:)`, so measuring and
    /// emitting can never disagree -- counting characters one way and rendering another would let
    /// the budget drift out of sync with the actual prompt without anything failing loudly.
    ///
    /// `summaryLength` ignores the `## サマリ` heading's own handful of characters (§3.2's table).
    static func measure(_ input: TranscriptMarkdownRenderer.Input) -> (transcriptLength: Int, summaryLength: Int) {
        let joined = renderedLines(input).joined(separator: lineSeparator)
        return (transcriptLength: joined.count, summaryLength: input.summaryMarkdown.count)
    }

    /// Assembles `# タイトル` + optional `## サマリ` + optional transcript section.
    ///
    /// `# タイトル` appears exactly once, and an empty section is omitted heading and all (the same
    /// rule design 37 TC14 sets for the copy feature) -- a heading with nothing under it invites the
    /// model to treat "no content" as "no such thing happened".
    static func build(
        _ input: TranscriptMarkdownRenderer.Input,
        resolution: ChatContextResolution
    ) -> Output {
        var blocks: [String] = ["# \(input.meta.title)"]

        if !input.summaryMarkdown.isEmpty {
            blocks.append("## サマリ\n\n\(input.summaryMarkdown)")
        }

        let lines = truncatedLines(input, resolution: resolution)
        if !lines.isEmpty {
            let heading = resolution.scope == .full ? "## 書き起こし" : "## 書き起こし（直近）"
            blocks.append("\(heading)\n\n\(lines.joined(separator: lineSeparator))")
        }

        return Output(markdown: blocks.joined(separator: "\n\n"), scope: resolution.scope)
    }

    /// Every line rendered, `startMs` ascending with `id` breaking ties -- the same ordering
    /// `TranscriptMarkdownRenderer.render(_:scope:)` applies, so a chat context and a copied
    /// transcript list the same lines in the same order.
    private static func renderedLines(_ input: TranscriptMarkdownRenderer.Input) -> [String] {
        input.lines
            .sorted { lhs, rhs in
                lhs.startMs != rhs.startMs ? lhs.startMs < rhs.startMs : lhs.id < rhs.id
            }
            .map { TranscriptMarkdownRenderer.renderLine($0, meta: input.meta) }
    }

    /// Takes lines from the newest end until the next one would exceed `transcriptBudget`.
    ///
    /// A line is never cut mid-way: half a line loses the tie between its text and the speaker and
    /// timestamp printed at its start, which is worse than not sending it. The summary is not
    /// trimmed either -- `resolve(...)` already counted it whole as part of the fixed cost.
    private static func truncatedLines(
        _ input: TranscriptMarkdownRenderer.Input,
        resolution: ChatContextResolution
    ) -> [String] {
        let all = renderedLines(input)
        guard resolution.scope != .full else { return all }

        var selected: [String] = []
        var total = 0
        for line in all.reversed() {
            let addition = selected.isEmpty ? line.count : line.count + lineSeparator.count
            guard total + addition <= resolution.transcriptBudget else { break }
            total += addition
            selected.append(line)
        }
        return selected.reversed()
    }
}
