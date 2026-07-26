import Foundation
import OSLog

// MARK: - SessionHandle + Prep (context.md / summary_template.md lifecycle)

/// `context.md`/`summary_template.md` read/write and cross-session copy (kikimi.md 4 章 "context.md /
/// summary_template.md のライフサイクル", 7 章 "事前知識（Context Prime）の構成", 8 章 "view template
/// （Mustache）"; `docs/design/07-session-store.md` section 8).
///
/// Split into its own file, alongside `SessionHandle+Transcript.swift`/`SessionStore+CrashRecovery.swift`
/// and friends, to keep the primary `SessionHandle` declaration (`sessionId`/`directoryURL`/`meta`/
/// `updateMeta`, defined elsewhere) focused on the actor's core lifecycle. Only uses `SessionHandle`'s
/// already-`internal` `sessionId`/`directoryURL` — no access to anything `private` on the primary
/// declaration is required.
extension SessionHandle {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SessionHandle.Prep")

    /// `context.md`'s size limit (kikimi.md 7 章: "ファイルサイズ上限は 32KB。超過時は warning（内容は使う）").
    private static let contextSizeLimitBytes = 32 * 1_024
    /// `summary_template.md`'s size limit (kikimi.md 8 章: "ファイルサイズ上限 16KB").
    private static let summaryTemplateSizeLimitBytes = 16 * 1_024

    /// kikimi.md 8 章's default view template (Mustache), embedded verbatim as the fallback content
    /// used whenever `summary_template.md` is missing/unreadable: `readSummaryTemplate()`'s own
    /// missing-file fallback, `copyPrepFiles`'s missing-source-file fallback, and (per
    /// `docs/design/07-session-store.md` section 8's table) `createDraftSession()`'s fallback when
    /// the global `defaults.summary_template_file` itself can't be read. Kept `internal` (not
    /// `private`) so other files in this module — most notably the `SessionStore` registry that owns
    /// `createDraftSession()` — can reuse the exact same constant instead of duplicating it.
    static let defaultSummaryTemplate = """
    # {{title}}

    ## 概要

    {{overview}}

    **参加者:** {{#participants}}{{name}}{{^is_last}}、{{/is_last}}{{/participants}}

    ## 決定事項

    {{#decisions}}- {{text}}
    {{/decisions}}

    ## アクションアイテム

    | タスク | 担当 | 期限 |
    |--------|------|------|
    {{#action_items}}| {{task}} | {{assignee}} | {{#due}}{{due}}{{/due}}{{^due}}—{{/due}} |
    {{/action_items}}
    """

    /// `.context`/`.summaryTemplate` never throw from `SessionFile.relativePath()` (only the
    /// `watcherDefinition`/`watcherState` cases validate an `id` and can fail); the `try?` fallback
    /// to the literal name only exists so these computed properties can stay non-throwing themselves.
    private var contextFileURL: URL {
        directoryURL.appendingPathComponent((try? SessionFile.context.relativePath()) ?? "context.md")
    }

    private var summaryTemplateFileURL: URL {
        directoryURL.appendingPathComponent((try? SessionFile.summaryTemplate.relativePath()) ?? "summary_template.md")
    }

    // MARK: context.md

    /// Reads `context.md`. If the file is missing or unreadable, treats it as empty and continues
    /// (kikimi.md 7 章 "ファイル未存在時（削除された場合）は起動時 warning、その context を空文字扱いで継続").
    func readContext() async -> String {
        guard let text = try? String(contentsOf: contextFileURL, encoding: .utf8) else {
            Self.logger.warning(
                "context.md is missing or unreadable for session \(self.sessionId, privacy: .public); treating it as empty (kikimi.md 7 章)."
            )
            return ""
        }
        return text
    }

    /// Overwrites `context.md` atomically. Content exceeding the 32KB limit is still saved in full;
    /// only a `.warning` is logged (kikimi.md 7 章, failure mode #12 of
    /// `docs/design/07-session-store.md` section 12).
    func writeContext(_ text: String) async throws {
        let byteCount = text.utf8.count
        if byteCount > Self.contextSizeLimitBytes {
            Self.logger.warning(
                """
                context.md for session \(self.sessionId, privacy: .public) is \(byteCount) bytes, exceeding \
                the \(Self.contextSizeLimitBytes)-byte limit; saving it anyway (kikimi.md 7 章).
                """
            )
        }
        try text.write(to: contextFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: summary_template.md

    /// Reads `summary_template.md`. If the file is missing or unreadable, falls back to the built-in
    /// default view template (kikimi.md 8 章 "ファイル未存在時は内蔵デフォルト template にフォールバック").
    func readSummaryTemplate() async -> String {
        guard let text = try? String(contentsOf: summaryTemplateFileURL, encoding: .utf8) else {
            Self.logger.warning(
                """
                summary_template.md is missing or unreadable for session \(self.sessionId, privacy: .public); \
                falling back to the built-in default template (kikimi.md 8 章).
                """
            )
            return Self.defaultSummaryTemplate
        }
        return text
    }

    /// Overwrites `summary_template.md` atomically. Content exceeding the 16KB limit is still saved
    /// in full; only a `.warning` is logged (kikimi.md 8 章, failure mode #12).
    func writeSummaryTemplate(_ text: String) async throws {
        let byteCount = text.utf8.count
        if byteCount > Self.summaryTemplateSizeLimitBytes {
            Self.logger.warning(
                """
                summary_template.md for session \(self.sessionId, privacy: .public) is \(byteCount) bytes, \
                exceeding the \(Self.summaryTemplateSizeLimitBytes)-byte limit; saving it anyway (kikimi.md 8 章).
                """
            )
        }
        try text.write(to: summaryTemplateFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: Cross-session copy ("他セッションから複製")

    /// Overwrites this session's `context.md`/`summary_template.md` (per `scope`) with the
    /// corresponding file(s) from another session (kikimi.md 10 章 "他セッションから複製";
    /// `docs/design/07-session-store.md` section 8's table, last row). Distinct from
    /// `SessionStore.createDraftSession(basedOn:)`, which seeds a brand-new session's initial Prep
    /// files — this overwrites an *already-open* session's files after the fact.
    ///
    /// `sourceSessionId`'s directory is resolved as a sibling of this session's own `directoryURL`
    /// (`docs/design/07-session-store.md` section 3: every session directory lives directly under the
    /// same `sessionsRootDirectory`), without going through `SessionStore.openSession(_:)` — reading
    /// the source is a plain, best-effort file read, not a full session open. If the source session's
    /// file can't be read (folder missing, file missing, or any other read failure), this falls back
    /// to the same global defaults `readContext()`/`readSummaryTemplate()` use (empty string / the
    /// built-in default template) and logs `.warning`, rather than throwing — copying should never
    /// fail outright just because the source happens to be incomplete
    /// (`docs/design/07-session-store.md` section 12, failure mode #2's "処理は継続" spirit applied here
    /// too). Only a failure while writing to *this* session's own files propagates as a thrown error.
    func copyPrepFiles(from sourceSessionId: String, scope: PrepCopyScope) async throws {
        try SessionIdValidation.validate(sourceSessionId)
        let sourceDirectoryURL = directoryURL
            .deletingLastPathComponent()
            .appendingPathComponent(sourceSessionId, isDirectory: true)

        switch scope {
        case .contextOnly:
            try await copyContext(fromSourceDirectory: sourceDirectoryURL, sourceSessionId: sourceSessionId)
        case .templateOnly:
            try await copySummaryTemplate(fromSourceDirectory: sourceDirectoryURL, sourceSessionId: sourceSessionId)
        case .both:
            try await copyContext(fromSourceDirectory: sourceDirectoryURL, sourceSessionId: sourceSessionId)
            try await copySummaryTemplate(fromSourceDirectory: sourceDirectoryURL, sourceSessionId: sourceSessionId)
        }
    }

    private func copyContext(fromSourceDirectory sourceDirectoryURL: URL, sourceSessionId: String) async throws {
        let sourceURL = sourceDirectoryURL.appendingPathComponent((try? SessionFile.context.relativePath()) ?? "context.md")
        guard let text = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            Self.logger.warning(
                """
                Could not read context.md from source session \(sourceSessionId, privacy: .public) to copy into \
                \(self.sessionId, privacy: .public); falling back to the global default (empty).
                """
            )
            try await writeContext("")
            return
        }
        try await writeContext(text)
    }

    private func copySummaryTemplate(fromSourceDirectory sourceDirectoryURL: URL, sourceSessionId: String) async throws {
        let sourceURL = sourceDirectoryURL
            .appendingPathComponent((try? SessionFile.summaryTemplate.relativePath()) ?? "summary_template.md")
        guard let text = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            Self.logger.warning(
                """
                Could not read summary_template.md from source session \(sourceSessionId, privacy: .public) to copy \
                into \(self.sessionId, privacy: .public); falling back to the built-in default template.
                """
            )
            try await writeSummaryTemplate(Self.defaultSummaryTemplate)
            return
        }
        try await writeSummaryTemplate(text)
    }
}
